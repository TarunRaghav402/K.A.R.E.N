import Foundation
import AVFoundation
import Combine
import AppKit
import Speech

// ─── Orb State ────────────────────────────────────────────────────────────────

enum OrbState: String, Equatable {
    case idle, listening, processing, speaking, permission, error
}

// ─── Core Controller ──────────────────────────────────────────────────────────

/// Central observable state shared across all views and the Metal renderer.
@MainActor
final class KarenCore: ObservableObject {

    // Orb state drives Metal rendering
    @Published var orbState: OrbState = .idle
    @Published var audioLevel: Float  = 0.0   // 0–1, microphone amplitude

    // UI state
    @Published var replyText: String   = ""
    @Published var isTextOnly: Bool    = false
    @Published var isMuted: Bool       = false
    @Published var isListening: Bool   = false
    @Published var wakeWordEnabled: Bool = true
    @Published var gestureMode: Bool   = false
    @Published var cameraActive: Bool  = false
    @Published var orbZoom: Float      = 1.0   // 0.3 … 8.0
    @Published var orbYaw: Float       = 0.0
    @Published var orbPitch: Float     = 0.0
    @Published var orbOffsetX: Float   = 0.0
    @Published var orbOffsetY: Float   = 0.0

    // Sheet/panel state
    @Published var showSettings: Bool     = false
    @Published var showPermissions: Bool  = false
    @Published var showMemory: Bool       = false
    @Published var pendingConfirm: ConfirmRequest? = nil

    // Permissions observed state
    @Published var micGranted: Bool      = false
    @Published var cameraGranted: Bool   = false
    @Published var speechGranted: Bool   = false

    // Menu bar icon reflects state
    var menuBarIcon: String {
        switch orbState {
        case .listening:  return "mic.fill"
        case .processing: return "circle.dotted"
        case .speaking:   return "waveform"
        case .error:      return "exclamationmark.circle"
        default:          return "sparkle"
        }
    }

    // Sub-systems (initialised lazily after permission grants)
    var sidecarBridge: SidecarBridge?
    var speechEngine: SpeechEngine?
    var wakeWordDetector: WakeWordDetector?
    var gestureProcessor: GestureProcessor?
    var ttsEngine: TTSEngine?

    private var cancellables = Set<AnyCancellable>()
    private var zoomTarget: Float = 1.0
    private var zoomAnimationTask: Task<Void, Never>?
    private var rotationTargetYaw: Float = 0
    private var rotationTargetPitch: Float = 0
    private var rotationAnimationTask: Task<Void, Never>?
    private var isLocalSpeechActive = false
    private var continuousConversation = false
    private var conversationGeneration = 0
    private var isHandlingUtterance = false
    private var zoomBeforeMemory: Float?

    init() {
        setupSidecar()
        ttsEngine = TTSEngine()
    }

    // ── Sidecar ──────────────────────────────────────────────────────────────

    func setupSidecar() {
        sidecarBridge = SidecarBridge()
        sidecarBridge?.onReply = { [weak self] id, text, speak in
            Task { @MainActor in
                guard let self else { return }
                self.replyText = text
                if speak && !self.isMuted && !self.isTextOnly {
                    self.replyText = ""
                    self.isLocalSpeechActive = true
                    self.orbState = .speaking
                    await self.ttsEngine?.speak(text)
                    self.isLocalSpeechActive = false
                }
                guard self.continuousConversation else {
                    self.orbState = .idle
                    self.resumeWakeWordIfNeeded()
                    return
                }
                self.orbState = .idle
                self.startListening()
            }
        }
        sidecarBridge?.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.isLocalSpeechActive else { return }
                // Speech and idle events from the sidecar can arrive while
                // AVSpeechSynthesizer is starting. The app owns those phases;
                // only let the sidecar announce request processing/errors.
                switch OrbState(rawValue: state) {
                case .processing where !self.isListening:
                    self.orbState = .processing
                case .error:
                    self.orbState = .error
                case .permission:
                    self.orbState = .permission
                default:
                    break
                }
            }
        }
        sidecarBridge?.onError = { [weak self] _, msg in
            Task { @MainActor in
                self?.orbState = .error
                self?.replyText = "Error: \(msg)"
            }
        }
        sidecarBridge?.connect()
    }

    // ── Listening controls ───────────────────────────────────────────────────

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    func startListening() {
        guard micGranted else {
            requestMic(); return
        }
        guard speechGranted else {
            requestSpeechRecognition(); return
        }
        // The wake-word engine and command recognizer share the microphone;
        // stop the background listener while the user is speaking a request.
        wakeWordDetector?.stop()
        continuousConversation = true
        conversationGeneration += 1
        isListening = true
        orbState = .listening
        speechEngine?.startListening { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                if isFinal {
                    guard !self.isHandlingUtterance else { return }
                    self.isHandlingUtterance = true
                    defer { self.isHandlingUtterance = false }
                    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?;, "))
                    if normalized == "quit" || normalized == "quit karen" {
                        self.continuousConversation = false
                        self.conversationGeneration += 1
                        self.isListening = false
                        self.speechEngine?.stopListening()
                        self.orbState = .idle
                        self.resumeWakeWordIfNeeded()
                        return
                    }
                    guard let bridge = self.sidecarBridge else {
                        self.replyText = "The voice assistant service is unavailable. Restart K.A.R.E.N. to reconnect."
                        self.isListening = false
                        self.continuousConversation = false
                        self.orbState = .error
                        self.resumeWakeWordIfNeeded()
                        return
                    }
                    if text.hasPrefix("Speech recognition is disabled") || text == "Speech recognition is not available." {
                        self.replyText = text
                        self.isListening = false
                        self.continuousConversation = false
                        self.orbState = .permission
                        return
                    }
                    do {
                        try await bridge.sendTranscript(id: UUID().uuidString, text: text, final: true)
                    } catch {
                        self.replyText = "I couldn't send that request. Please try again."
                        self.orbState = .error
                        self.isListening = false
                        if self.continuousConversation { self.startListening() }
                        else { self.resumeWakeWordIfNeeded() }
                        return
                    }
                    if self.orbState != .error && self.orbState != .permission {
                        self.orbState = .processing
                    }
                    self.isListening = false
                }
            }
        }
    }

    func stopListening() {
        continuousConversation = false
        conversationGeneration += 1
        isListening = false
        speechEngine?.stopListening()
        if orbState == .listening { orbState = .idle }
        resumeWakeWordIfNeeded()
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted { ttsEngine?.stop() }
    }

    func stopSpeaking() {
        ttsEngine?.stop()
        orbState = .idle
        if continuousConversation { startListening() }
        else { resumeWakeWordIfNeeded() }
    }

    func toggleWakeWord() {
        wakeWordEnabled.toggle()
        if wakeWordEnabled {
            wakeWordDetector?.start()
        } else {
            wakeWordDetector?.stop()
        }
    }

    // ── Permissions ──────────────────────────────────────────────────────────

    func requestMic() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            micGranted = status == .authorized
            if micGranted {
                initSpeech()
                requestSpeechRecognition()
            }
            else { replyText = "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone." }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.micGranted = granted
                if granted {
                    self?.initSpeech()
                    self?.requestSpeechRecognition()
                }
                else { self?.replyText = "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone." }
            }
        }
    }

    func requestCamera() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .notDetermined else {
            cameraGranted = status == .authorized
            if cameraGranted && gestureMode { startCameraGestures() }
            else if !cameraGranted { replyText = "Camera access is off. Turn it on in System Settings > Privacy & Security > Camera." }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                self?.cameraGranted = granted
                if granted && (self?.gestureMode ?? false) {
                    self?.startCameraGestures()
                } else if !granted {
                    self?.replyText = "Camera access is off. Turn it on in System Settings > Privacy & Security > Camera."
                }
            }
        }
    }

    func requestSpeechRecognition() {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else {
            speechGranted = status == .authorized
            if speechGranted { initSpeech() }
            else { replyText = "Speech Recognition access is off. Turn it on in System Settings > Privacy & Security > Speech Recognition." }
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.speechGranted = status == .authorized
                if self.speechGranted { self.initSpeech() }
                else { self.replyText = "Speech Recognition access is off. Turn it on in System Settings > Privacy & Security > Speech Recognition." }
            }
        }
    }

    func initSpeech() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        guard micGranted else { return }
        if speechEngine != nil, wakeWordDetector != nil {
            if wakeWordEnabled && speechGranted { wakeWordDetector?.start() }
            return
        }
        speechEngine = SpeechEngine()
        wakeWordDetector = WakeWordDetector(onWake: { [weak self] in
            Task { @MainActor in self?.onWakeWord() }
        })
        if wakeWordEnabled && speechGranted { wakeWordDetector?.start() }
    }

    func openMemoryMap() {
        if zoomBeforeMemory == nil { zoomBeforeMemory = orbZoom }
        showMemory = true
        applyZoom(3.6 / max(orbZoom, 0.3))
    }

    func closeMemoryMap() {
        showMemory = false
        guard let previous = zoomBeforeMemory else { return }
        zoomBeforeMemory = nil
        applyZoom(previous / max(orbZoom, 0.3))
    }

    func onWakeWord() {
        guard !isListening else { return }
        NSApp.activate(ignoringOtherApps: true)
        wakeWordDetector?.stop()
        continuousConversation = true
        conversationGeneration += 1
        let generation = conversationGeneration
        guard !isMuted && !isTextOnly else {
            startListening()
            return
        }
        isLocalSpeechActive = true
        orbState = .speaking
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.ttsEngine?.speak("I'm here. What can I help you with?")
            guard self.continuousConversation, self.conversationGeneration == generation else { return }
            self.isLocalSpeechActive = false
            self.startListening()
        }
    }

    private func resumeWakeWordIfNeeded() {
        guard wakeWordEnabled, speechGranted, !isListening, !continuousConversation else { return }
        wakeWordDetector?.start()
    }

    func enableGestureMode() {
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { requestCamera(); return }
        cameraGranted = true
        gestureMode = true
        startCameraGestures()
    }

    private func startCameraGestures() {
        guard cameraGranted, gestureMode else { return }
        gestureProcessor = GestureProcessor(core: self)
        gestureProcessor?.start()
        cameraActive = true
    }

    func disableGestureMode() {
        gestureMode = false
        gestureProcessor?.stop()
        gestureProcessor = nil
        cameraActive = false
    }

    // ── Zoom / Rotate / Translate (from gestures OR mouse/keyboard) ──────────

    func applyZoom(_ factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        zoomTarget = max(0.3, min(8.0, zoomTarget * factor))
        guard zoomAnimationTask == nil else { return }

        zoomAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let remaining = self.zoomTarget - self.orbZoom
                if abs(remaining) < 0.0007 {
                    self.orbZoom = self.zoomTarget
                    break
                }
                // Ease toward the latest requested zoom at display-frame pace.
                self.orbZoom += remaining * 0.18
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self.zoomAnimationTask = nil
        }
    }

    func applyRotation(yaw: Float, pitch: Float) {
        guard yaw.isFinite, pitch.isFinite else { return }
        rotationTargetYaw = Self.wrappedAngle(rotationTargetYaw + yaw)
        rotationTargetPitch = Self.wrappedAngle(rotationTargetPitch + pitch)
        guard rotationAnimationTask == nil else { return }

        rotationAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let yawDelta = Self.shortestAngle(from: self.orbYaw, to: self.rotationTargetYaw)
                let pitchDelta = Self.shortestAngle(from: self.orbPitch, to: self.rotationTargetPitch)
                if abs(yawDelta) < 0.0004 && abs(pitchDelta) < 0.0004 {
                    self.orbYaw = self.rotationTargetYaw
                    self.orbPitch = self.rotationTargetPitch
                    break
                }
                // Ease toward the latest hand/trackpad input at display-frame pace.
                self.orbYaw = Self.wrappedAngle(self.orbYaw + yawDelta * 0.38)
                self.orbPitch = Self.wrappedAngle(self.orbPitch + pitchDelta * 0.38)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self.rotationAnimationTask = nil
        }
    }

    private static func wrappedAngle(_ angle: Float) -> Float {
        let fullTurn = 2 * Float.pi
        let wrapped = angle.truncatingRemainder(dividingBy: fullTurn)
        return wrapped < 0 ? wrapped + fullTurn : wrapped
    }

    private static func shortestAngle(from current: Float, to target: Float) -> Float {
        var delta = (target - current).truncatingRemainder(dividingBy: 2 * Float.pi)
        if delta > Float.pi { delta -= 2 * Float.pi }
        if delta < -Float.pi { delta += 2 * Float.pi }
        return delta
    }

    func applyTranslation(dx: Float, dy: Float) {
        orbOffsetX = max(-1.5, min(1.5, orbOffsetX + dx))
        orbOffsetY = max(-1.5, min(1.5, orbOffsetY + dy))
    }

    func resetOrb() {
        zoomTarget = 1.0
        zoomAnimationTask?.cancel()
        zoomAnimationTask = nil
        rotationTargetYaw = 0
        rotationTargetPitch = 0
        orbZoom = 1.0; orbYaw = 0; orbPitch = 0; orbOffsetX = 0; orbOffsetY = 0
    }
}

// ─── Confirm Request ─────────────────────────────────────────────────────────

struct ConfirmRequest: Identifiable {
    let id: String
    let description: String
    let skill: String
    var onConfirm: () -> Void
    var onCancel: () -> Void
}
