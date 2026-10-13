import Vision
import AVFoundation
import simd

// ─── Hand Gesture Processor ───────────────────────────────────────────────────
//
// Uses VNDetectHumanHandPoseRequest to track up to 2 hands from the camera.
// Gesture mapping:
//   Spread two index fingertips apart       → zoom (two hands)
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
        s.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                        ?? AVCaptureDevice.default(for: .video) else {
            print("[GestureProcessor] No camera available")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if s.canAddInput(input) { s.addInput(input) }

            let output = AVCaptureVideoDataOutput()
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
                self?.prevIndexSpan = nil
                self?.smoothedIndexSpan = nil
                self?.prevPalmCenter = nil
                self?.smoothedPalmCenter = nil
                self?.prevPinchCenter = nil
                self?.smoothedPinchCenter = nil
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.dispatchGestures(observations: observations)
        }
    }

    @MainActor
    private func dispatchGestures(observations: [VNHumanHandPoseObservation]) {
        // Two-hand zoom: spread the index fingertips apart to zoom in and
        // bring them together to zoom out.
        let indexTips = observations.compactMap { point(.indexTip, in: $0) }
        if observations.count >= 2, indexTips.count == 2 {
            handleIndexPinch(indexTips[0], indexTips[1])
            return
        }

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
        guard let wrist = point(.wrist, in: observation) else { return false }
        let fingerJoints: [(VNHumanHandPoseObservation.JointName,
                            VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexPIP),
            (.middleTip, .middlePIP),
            (.ringTip, .ringPIP),
            (.littleTip, .littlePIP),
        ]
        let extendedCount = fingerJoints.reduce(into: 0) { count, joints in
            guard let tip = point(joints.0, in: observation),
                  let pip = point(joints.1, in: observation) else { return }
            if distance(wrist, tip) > distance(wrist, pip) * 1.12 { count += 1 }
        }
        return extendedCount >= 3
    }

    @MainActor
    private func handleIndexPinch(_ first: CGPoint, _ second: CGPoint) {
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
        let span = smoothedIndexSpan.map { $0 + (measuredSpan - $0) * 0.42 } ?? measuredSpan
        defer {
            prevIndexSpan = span
            smoothedIndexSpan = span
        }
        guard let previous = prevIndexSpan, previous > 0.001 else { return }

        let rawFactor = span / previous
        guard abs(rawFactor - 1) > 0.0012 else { return }
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
        guard abs(dx) > 0.00035 || abs(dy) > 0.00035 else { return }
        core?.applyTranslation(dx: -Float(dx) * 4.4, dy: Float(dy) * 4.4)
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
        guard abs(dx) > 0.00035 || abs(dy) > 0.00035 else { return }
        core?.applyRotation(yaw: -Float(dx) * 6.0, pitch: Float(dy) * 6.0)
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
}

// ─── AVCaptureVideoDataOutputSampleBufferDelegate ─────────────────────────────

extension GestureProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                    didOutput sampleBuffer: CMSampleBuffer,
                                    from connection: AVCaptureConnection) {
        processFrame(sampleBuffer)
    }
}
