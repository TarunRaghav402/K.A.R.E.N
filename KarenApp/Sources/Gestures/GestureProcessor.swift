import Vision
import AVFoundation
import simd

// ─── Hand Gesture Processor ───────────────────────────────────────────────────
//
// Uses VNDetectHumanHandPoseRequest to track up to 2 hands from the camera.
// Gesture mapping:
//   Spread two index fingertips apart       → zoom (two hands)
//   Twist the line between two index tips   → rotate (two hands)
//   Open/close thumb and index finger       → zoom (one hand)
//   Hold a pinch and move the hand           → move the orb
//   Move an open palm                        → rotate the orb
//
// All hand-to-orb math is unit-tested in the Python test suite (test_gesture_math.py).

@MainActor
final class GestureProcessor: NSObject {
    private weak var core: KarenCore?
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let queue = DispatchQueue(label: "karen.gesture", qos: .userInteractive)

    // Smoothing
    private var prevIndexSpan: Float?
    private var smoothedIndexSpan: Float?
    private var prevPalmCenter: CGPoint?
    private var smoothedPalmCenter: CGPoint?
    private var prevPinchCenter: CGPoint?
    private var smoothedPinchCenter: CGPoint?
    private var previousTwoHandAngle: CGFloat?
    private var closedFistFrameCount = 0
    private var fistReleaseFrameCount = 0

    init(core: KarenCore) {
        self.core = core
        super.init()
    }

    @MainActor func start() {
        setupCamera()
    }

    @MainActor func stop() {
        session?.stopRunning()
        session = nil
    }

    // MARK: - Camera setup

    @MainActor private func setupCamera() {
        let s = AVCaptureSession()
        s.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                        ?? AVCaptureDevice.default(for: .video) else {
            print("[GestureProcessor] No camera available")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if s.canAddInput(input) { s.addInput(input) }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if s.canAddOutput(output) { s.addOutput(output) }

            self.session  = s
            self.videoOutput = output
            s.startRunning()
            print("[GestureProcessor] Camera started")
        } catch {
            print("[GestureProcessor] Camera error: \(error)")
        }
    }

    // MARK: - Vision request

    nonisolated private func processFrame(_ buffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        request.revision = VNDetectHumanHandPoseRequestRevision1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results, !observations.isEmpty else {
            Task { @MainActor [weak self] in
                if let self, self.closedFistFrameCount > 0 {
                    self.fistReleaseFrameCount += 1
                    if self.fistReleaseFrameCount >= 3 {
                        self.closedFistFrameCount = 0
                        self.fistReleaseFrameCount = 0
                    }
                }
                self?.prevIndexSpan = nil
                self?.smoothedIndexSpan = nil
                self?.prevPalmCenter = nil
                self?.smoothedPalmCenter = nil
                self?.prevPinchCenter = nil
                self?.smoothedPinchCenter = nil
                self?.previousTwoHandAngle = nil
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.dispatchGestures(observations: observations)
        }
    }

    @MainActor
    private func dispatchGestures(observations: [VNHumanHandPoseObservation]) {
        let closedFistDetected = observations.contains(where: isClosedFist)
        if closedFistDetected {
            closedFistFrameCount = min(closedFistFrameCount + 1, 2)
            fistReleaseFrameCount = 0
        } else if closedFistFrameCount > 0 {
            // Hold the stop state briefly across Vision pose jitter.
            fistReleaseFrameCount += 1
            if fistReleaseFrameCount >= 3 {
                closedFistFrameCount = 0
                fistReleaseFrameCount = 0
            }
        }
        if closedFistFrameCount > 0 {
            // Fist pauses gesture input; opening the hand restores the existing gestures.
            clearGestureHistory()
            return
        }

        // Two-hand zoom: spread the index fingertips apart to zoom in and
        // bring them together to zoom out.
        let indexTips = observations.compactMap { point(.indexTip, in: $0) }
            .sorted { $0.x < $1.x }
        if observations.count >= 2, indexTips.count == 2 {
            handleTwoHandGesture(indexTips[0], indexTips[1])
            return
        }
        previousTwoHandAngle = nil

        if observations.count == 1,
           let thumb = point(.thumbTip, in: observations[0]),
           let index = point(.indexTip, in: observations[0]),
           let wrist = point(.wrist, in: observations[0]),
           let middleBase = point(.middleMCP, in: observations[0]) {
            let span = Float(distance(thumb, index))
            let palmLength = Float(distance(wrist, middleBase))
            let pinchThreshold = max(0.025, palmLength * 0.34)

            if span < pinchThreshold {
                handlePinchDrag(CGPoint(x: (thumb.x + index.x) / 2,
                                        y: (thumb.y + index.y) / 2))
                return
            }

            // A broad, open hand is reserved for rotation. With the other
            // fingers curled, changing thumb-to-index spread zooms smoothly.
            if isOpenPalm(observations[0]) {
                handleOpenPalmRotate(CGPoint(x: (wrist.x + middleBase.x) / 2,
                                             y: (wrist.y + middleBase.y) / 2))
                return
            }
            handleSingleHandZoom(span)
            return
        }

        clearZoomTracking()

        // One or two open palms rotate the orb as a shared controller.
        let openPalmCenters = observations.compactMap { observation -> CGPoint? in
            guard isOpenPalm(observation),
                  let wrist = point(.wrist, in: observation) else { return nil }
            let palmBase = point(.middleMCP, in: observation) ?? wrist
            return CGPoint(x: (wrist.x + palmBase.x) / 2,
                           y: (wrist.y + palmBase.y) / 2)
        }
        guard !openPalmCenters.isEmpty else {
            prevPalmCenter = nil
            smoothedPalmCenter = nil
            prevPinchCenter = nil
            smoothedPinchCenter = nil
            return
        }
        let center = openPalmCenters.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x / CGFloat(openPalmCenters.count),
                    y: partial.y + point.y / CGFloat(openPalmCenters.count))
        }
        handleOpenPalmRotate(center)
    }

    private func point(_ joint: VNHumanHandPoseObservation.JointName,
                       in observation: VNHumanHandPoseObservation) -> CGPoint? {
        guard let recognized = try? observation.recognizedPoint(joint),
              recognized.confidence >= 0.25 else { return nil }
        return recognized.location
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func isOpenPalm(_ observation: VNHumanHandPoseObservation) -> Bool {
        fingerExtensionCounts(in: observation).extended >= 3
    }

    private func isClosedFist(_ observation: VNHumanHandPoseObservation) -> Bool {
        let counts = fingerExtensionCounts(in: observation)
        guard counts.visible >= 2, counts.extended <= 1,
              let wrist = point(.wrist, in: observation),
              let palm = point(.middleMCP, in: observation),
              let index = point(.indexTip, in: observation),
              let middle = point(.middleTip, in: observation),
              let ring = point(.ringTip, in: observation) ?? point(.littleTip, in: observation) else { return false }
        let palmLength = distance(wrist, palm)
        guard palmLength > 0.001 else { return false }
        // Curled fingertips cluster near the palm. This works across more
        // camera angles and does not depend on thumb visibility.
        let curled = [index, middle, ring].filter { distance($0, wrist) < palmLength * 1.35 }
        return curled.count >= 2
    }

    private func fingerExtensionCounts(in observation: VNHumanHandPoseObservation)
        -> (visible: Int, extended: Int) {
        guard let wrist = point(.wrist, in: observation) else { return (0, 0) }
        let fingerJoints: [(VNHumanHandPoseObservation.JointName,
                            VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexPIP),
            (.middleTip, .middlePIP),
            (.ringTip, .ringPIP),
            (.littleTip, .littlePIP),
        ]
        var visible = 0
        var extended = 0
        for joints in fingerJoints {
            guard let tip = point(joints.0, in: observation),
                  let pip = point(joints.1, in: observation) else { continue }
            visible += 1
            if distance(wrist, tip) > distance(wrist, pip) * 1.12 { extended += 1 }
        }
        return (visible, extended)
    }

    @MainActor
    private func handleTwoHandGesture(_ first: CGPoint, _ second: CGPoint) {
        let angle = atan2(second.y - first.y, second.x - first.x)
        if let previousAngle = previousTwoHandAngle {
            // Two fingertips form an undirected axis, so treat angles half a
            // turn apart as equivalent. This prevents a detector ordering
            // swap from snapping the orb backward as hands cross.
            var delta = angle - previousAngle
            if delta > .pi / 2 { delta -= .pi }
            if delta < -.pi / 2 { delta += .pi }
            if abs(delta) > 0.003 {
                core?.applyRotation(yaw: Float(delta) * 2.6, pitch: 0)
            }
        }
        previousTwoHandAngle = angle
        handleSpanZoom(Float(distance(first, second)))
        prevPalmCenter = nil
        smoothedPalmCenter = nil
        prevPinchCenter = nil
        smoothedPinchCenter = nil
    }

    @MainActor
    private func handleSingleHandZoom(_ span: Float) {
        handleSpanZoom(span)
    }

    @MainActor
    private func handleSpanZoom(_ measuredSpan: Float) {
        let span = smoothedIndexSpan.map { $0 + (measuredSpan - $0) * 0.52 } ?? measuredSpan
        defer {
            prevIndexSpan = span
            smoothedIndexSpan = span
        }
        guard let previous = prevIndexSpan, previous > 0.001 else { return }

        let rawFactor = span / previous
        guard abs(rawFactor - 1) > 0.0007 else { return }
        let stableFactor = min(max(rawFactor, 0.90), 1.10)
        core?.applyZoom(pow(stableFactor, 1.45))
    }

    @MainActor
    private func handlePinchDrag(_ center: CGPoint) {
        let smoothed = smooth(center, previous: smoothedPinchCenter, amount: 0.38)
        smoothedPinchCenter = smoothed
        defer { prevPinchCenter = smoothed }
        prevIndexSpan = nil
        smoothedIndexSpan = nil
        prevPalmCenter = nil
        smoothedPalmCenter = nil
        guard let previous = prevPinchCenter else { return }
        let dx = smoothed.x - previous.x
        let dy = smoothed.y - previous.y
        guard abs(dx) > 0.0005 || abs(dy) > 0.0005 else { return }
        core?.applyTranslation(dx: -Float(dx) * 5.2, dy: Float(dy) * 5.2)
    }

    @MainActor
    private func handleOpenPalmRotate(_ center: CGPoint) {
        clearZoomTracking()
        let smoothed = smooth(center, previous: smoothedPalmCenter, amount: 0.36)
        smoothedPalmCenter = smoothed
        defer { prevPalmCenter = smoothed }
        guard let previous = prevPalmCenter else { return }
        let dx = smoothed.x - previous.x
        let dy = smoothed.y - previous.y
        guard abs(dx) > 0.00045 || abs(dy) > 0.00045 else { return }
        core?.applyRotation(yaw: -Float(dx) * 12.0, pitch: Float(dy) * 12.0)
        prevPinchCenter = nil
        smoothedPinchCenter = nil
    }

    private func smooth(_ point: CGPoint, previous: CGPoint?, amount: CGFloat) -> CGPoint {
        guard let previous else { return point }
        return CGPoint(x: previous.x + (point.x - previous.x) * amount,
                       y: previous.y + (point.y - previous.y) * amount)
    }

    private func clearZoomTracking() {
        prevIndexSpan = nil
        smoothedIndexSpan = nil
    }

    private func clearGestureHistory() {
        clearZoomTracking()
        prevPalmCenter = nil
        smoothedPalmCenter = nil
        prevPinchCenter = nil
        smoothedPinchCenter = nil
        previousTwoHandAngle = nil
    }
}

// ─── AVCaptureVideoDataOutputSampleBufferDelegate ─────────────────────────────

extension GestureProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                    didOutput sampleBuffer: CMSampleBuffer,
                                    from connection: AVCaptureConnection) {
        processFrame(sampleBuffer)
    }
}
