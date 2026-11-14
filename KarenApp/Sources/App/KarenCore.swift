import Foundation
import SwiftUI
import AVFoundation
import Combine
import AppKit
import Speech
import Vision
import UniformTypeIdentifiers

// ─── Authoritative Interaction State Machine ───────────────────────────────────

enum InteractionState: String, Equatable, CaseIterable, CustomStringConvertible {
    case idle         = "IDLE"
    case listening    = "LISTENING"
    case processing   = "PROCESSING"
    case responding   = "RESPONDING"
    case speaking     = "SPEAKING"
    case interrupting = "INTERRUPTING"
    case error        = "ERROR"
    case permission   = "PERMISSION"

    var description: String { rawValue }

    var visualOrbState: OrbState {
        switch self {
        case .idle:         return .idle
        case .listening:    return .listening
        case .processing:   return .processing
        case .responding:   return .responding
        case .speaking:     return .speaking
        case .interrupting: return .interrupting
        case .error:        return .error
        case .permission:   return .permission
        }
    }

    /// Determines whether a state transition from `current` to `target` is valid.
    static func isValidTransition(from current: InteractionState, to target: InteractionState) -> Bool {
        if current == target { return true }
        switch current {
        case .idle:
            // From IDLE, can start listening, begin processing typed text, replay last response (.speaking), or encounter error/permission
            return target == .listening || target == .processing || target == .speaking || target == .error || target == .permission
        case .listening:
            // From LISTENING, can process speech, return to idle (canceled/timeout), or encounter error/interrupt
            return target == .processing || target == .idle || target == .error || target == .interrupting
        case .processing:
            // From PROCESSING, can transition to responding with result, idle (cancel), error, or barge-in interrupt
            return target == .responding || target == .idle || target == .error || target == .interrupting
        case .responding:
            // From RESPONDING, can begin speaking, interrupt, complete to idle, ask follow-up (listening), or error
            return target == .speaking || target == .interrupting || target == .idle || target == .listening || target == .error
        case .speaking:
            // From SPEAKING, can complete to idle, interrupt (barge-in), ask follow-up (listening), or error
            return target == .idle || target == .interrupting || target == .listening || target == .error
        case .interrupting:
            // From INTERRUPTING, immediately transitions to listening (for new query), idle (if user said stop), or error
            return target == .listening || target == .idle || target == .error
        case .error:
            // From ERROR, can reset to idle, retry listening/processing, or show responding error view
            return target == .idle || target == .listening || target == .processing || target == .responding
        case .permission:
            // From PERMISSION, can return to idle or proceed to listening once granted
            return target == .idle || target == .listening
        }
    }
}

// ─── Orb State ────────────────────────────────────────────────────────────────

enum OrbState: String, Equatable, CaseIterable {
    case idle, listening, processing, responding, speaking, interrupting, permission, error
}

enum ResponseAnimationPhase: String, Equatable {
    case dismissed     // Orb centered at normal scale, panel hidden
    case movingOrb     // Step 1 & 2: shrinking and traveling upwards to top-center
    case orbSettled    // Step 3: settled in top position
    case connectorLit  // Step 4: subtle glowing connector illuminated
    case panelEmerging // Step 5: response panel emerges and expands
    case contentReveal // Step 6: question & response revealed, speaking active
}

// ─── Core Controller ──────────────────────────────────────────────────────────

/// Central observable state shared across all views and the Metal renderer.
@MainActor
final class KarenCore: ObservableObject {
    static let shared = KarenCore()

    // Authoritative interaction state machine
    @Published var interactionState: InteractionState = .idle
    @Published var orbState: OrbState = .idle {
        didSet {
            // Keep interactionState aligned if orbState is updated directly
            if let matching = InteractionState(rawValue: orbState.rawValue.uppercased()),
               interactionState != matching {
                interactionState = matching
            }
        }
    }
    @Published var audioLevel: Float  = 0.0   // 0–1, microphone amplitude

    // Phase 4: Coordinated Siri-inspired dynamic response animation
    @Published var orbTopProgress: CGFloat = 0.0     // 0 = centered, 1 = top-center
    @Published var orbScaleProgress: CGFloat = 1.0   // 1.0 = normal, 0.44 = compact top size
    @Published var showConnector: Bool = false
    @Published var responsePhase: ResponseAnimationPhase = .dismissed

    // UI state
    @Published var replyText: String   = ""
    @Published var responseTextRevealedCount: Int = 0
    @Published var liveTranscription: String = ""
    @Published var lastUserQuery: String = ""
    @Published var showResponsePanel: Bool = false
    @Published var isSpeaking: Bool    = false
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
    @Published var memoryNodeLabels: [String] = []
    @Published var selectedImageLabels: [String] = []

    // Sheet/panel state
    @Published var showSettings: Bool     = false
    @Published var showPermissions: Bool  = false
    @Published var showMemory: Bool       = false
    @Published var pendingConfirm: ConfirmRequest? = nil
    @Published var isRemoteApprovalPending: Bool = false
    private var activeRemoteApprovalTask: Task<Void, Never>? = nil

    // Permissions observed state
    @Published var micGranted: Bool      = false
    @Published var cameraGranted: Bool   = false
    @Published var speechGranted: Bool   = false

    // Gesture coordination & camera lifecycle
    @Published var isGesturePaused: Bool = false
    @Published var isInterrupting: Bool = false
    @Published var cameraError: String? = nil

    /// Authoritative property indicating whether an active assistant voice/dialog interaction is occurring.
    /// When true, camera gesture actions and accidental orb manipulation are paused.
    var isVoiceInteractionActive: Bool {
        (interactionState != .idle && interactionState != .permission) ||
        isListening ||
        orbState == .listening ||
        orbState == .processing ||
        orbState == .speaking ||
        orbState == .responding ||
        orbState == .interrupting ||
        isSpeaking ||
        isLocalSpeechActive ||
        isInterrupting ||
        showResponsePanel ||
        responsePhase != .dismissed ||
        (ttsEngine?.isSpeaking ?? false)
    }

    // Menu bar icon reflects state
    var menuBarIcon: String {
        switch orbState {
        case .listening:    return "mic.fill"
        case .processing:   return "circle.dotted"
        case .speaking:     return "waveform"
        case .responding:   return "sparkles"
        case .interrupting: return "bolt.fill"
        case .error:        return "exclamationmark.circle"
        default:            return "sparkles"
        }
    }

    func showAssistantWindow() {
        let app = NSApplication.shared
        if let window = app.windows.first(where: { $0.title == "K.A.R.E.N." }) {
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
        }
        windowOpener?()
        app.activate(ignoringOtherApps: true)
    }

    func setWindowOpener(_ opener: @escaping () -> Void) {
        windowOpener = opener
    }

    func hideAssistantWindow() {
        stopSpeaking()
        dismissResponsePanel()
        let app = NSApplication.shared
        app.windows
            .filter { $0.title == "K.A.R.E.N." && $0.isVisible }
            .forEach {
                $0.isReleasedWhenClosed = false
                $0.orderOut(nil)
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
    private var windowOpener: (() -> Void)?
    private var continuousConversation = false
    private var conversationGeneration = 0
    private var isHandlingUtterance = false
    private var zoomBeforeMemory: Float?
    private let autoStartSubsystems: Bool
    private var speechTask: Task<Void, Never>?
    private var activeResponseId: UUID = UUID()
    private var processingTimeoutTask: Task<Void, Never>?
    private var currentRequestId: String = ""
    private var processingSessionId: UUID = UUID()

    init(autoStartSubsystems: Bool = true) {
        self.autoStartSubsystems = autoStartSubsystems
        if autoStartSubsystems {
            setupSidecar()
        }
        refreshMemoryNodeLabels()
        let tts = TTSEngine()
        tts.onSpeechStateChanged = { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.updateGestureCoordination()
                }
            } else {
                DispatchQueue.main.async {
                    self?.updateGestureCoordination()
                }
            }
        }
        tts.onSpeechProgress = { [weak self] currentChars, totalChars in
            let update: @MainActor @Sendable () -> Void = {
                guard let self else { return }
                guard totalChars > 0 else { return }
                let fullCount = self.replyText.count
                let targetCount: Int
                if totalChars == fullCount {
                    targetCount = currentChars
                } else {
                    let ratio = Double(currentChars) / Double(totalChars)
                    targetCount = min(fullCount, Int(Double(fullCount) * ratio))
                }
                self.responseTextRevealedCount = max(self.responseTextRevealedCount, targetCount)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    update()
                }
            } else {
                DispatchQueue.main.async {
                    update()
                }
            }
        }
        ttsEngine = tts

        if autoStartSubsystems {
            // Eagerly query existing permission grants so audio & wake-word pipelines
            // are activated immediately on startup without requiring extra clicks.
            let micAuth = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let speechAuth = SFSpeechRecognizer.authorizationStatus() == .authorized
            micGranted = micAuth
            speechGranted = speechAuth
            if micAuth && speechAuth {
                initSpeech()
            }
        }
    }

    // ── Sidecar ──────────────────────────────────────────────────────────────

    func setupSidecar() {
        sidecarBridge = SidecarBridge()
        sidecarBridge?.onReply = { [weak self] id, text, speechText, speak in
            Task { @MainActor in
                guard let self else { return }
                guard !self.currentRequestId.isEmpty, self.currentRequestId == id else {
                    print("[KarenCore] Stale or cancelled reply ignored (received: \(id), active: \(self.currentRequestId))")
                    return
                }
                self.currentRequestId = ""
                self.presentResponse(text: text, speechText: speechText, speak: speak)
            }
        }
        sidecarBridge?.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.isLocalSpeechActive else { return }
                switch state {
                case "processing" where self.interactionState != .listening:
                    self.transition(to: .processing, reason: "Sidecar processing query")
                case "error":
                    self.transition(to: .error, reason: "Sidecar reported error")
                default:
                    break
                }
            }
        }
        sidecarBridge?.onError = { [weak self] id, msg in
            Task { @MainActor in
                guard let self else { return }
                if !id.isEmpty && !self.currentRequestId.isEmpty && self.currentRequestId != id {
                    print("[KarenCore] Stale or cancelled error ignored (received: \(id), active: \(self.currentRequestId))")
                    return
                }
                self.currentRequestId = ""
                self.transition(to: .error, reason: "Sidecar error: \(msg)")
                self.presentResponse(text: "Error: \(msg)", speechText: "", speak: false)
            }
        }
        sidecarBridge?.onAction = { [weak self] id, skill, payload in
            Task { @MainActor in
                guard let self else { return }
                if skill == "karen_settings" || payload["action"] as? String == "open_settings" {
                    self.requestOpenSettings()
                    return
                }
                guard skill == "open_application",
                      let applicationName = payload["application_name"] as? String,
                      !applicationName.isEmpty else {
                    self.presentResponse(text: "I can’t perform that action yet.", speechText: "", speak: false)
                    return
                }
                self.openApplication(named: applicationName)
            }
        }
        sidecarBridge?.connect()
    }

    // MARK: - Phase 6 Authoritative Interaction State Machine Transitions

    /// Single authoritative method to transition the interaction state machine.
    /// Manages subsystem coordination (speech, wake word, TTS, gestures, animation).
    @discardableResult
    func transition(to newState: InteractionState, reason: String = "") -> Bool {
        guard InteractionState.isValidTransition(from: interactionState, to: newState) else {
            print("[KarenCore] Rejected invalid state transition: \(interactionState) -> \(newState) (\(reason))")
            return false
        }
        let oldState = interactionState
        if oldState == newState {
            updateGestureCoordination()
            return true
        }

        print("[KarenCore] State transition: \(oldState) -> \(newState) [\(reason)]")
        interactionState = newState
        orbState = newState.visualOrbState

        if newState != .processing {
            processingTimeoutTask?.cancel()
            processingTimeoutTask = nil
        }

        switch newState {
        case .idle:
            activeResponseId = UUID()
            isListening = false
            isSpeaking = false
            isLocalSpeechActive = false
            isInterrupting = false
            continuousConversation = false
            liveTranscription = ""
            speechEngine?.stopListening()
            ttsEngine?.stop()
            speechTask?.cancel()
            speechTask = nil
            wakeWordDetector?.isBargeInMode = false
            resumeWakeWordIfNeeded()

        case .listening:
            isListening = true
            isSpeaking = false
            isLocalSpeechActive = false
            isInterrupting = false
            // Wake word detector stopped during active speech recognition to avoid audio tap conflict
            wakeWordDetector?.stop()
            ttsEngine?.stop()
            speechTask?.cancel()
            speechTask = nil

        case .processing:
            isListening = false
            isSpeaking = false
            isLocalSpeechActive = false
            isInterrupting = false
            speechEngine?.stopListening()
            wakeWordDetector?.stop()
            ttsEngine?.stop()
            speechTask?.cancel()
            speechTask = nil

            // 35-second watchdog to recover from hung/delayed sidecar requests
            let sessionId = UUID()
            self.processingSessionId = sessionId
            processingTimeoutTask?.cancel()
            processingTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                guard let self, !Task.isCancelled,
                      self.processingSessionId == sessionId,
                      self.interactionState == .processing else { return }
                print("[KarenCore] Processing watchdog triggered after 35s; transitioning to error")
                if !self.currentRequestId.isEmpty {
                    self.sidecarBridge?.sendCancel(id: self.currentRequestId)
                    self.currentRequestId = ""
                }
                self.transition(to: .error, reason: "Processing request timed out")
                self.presentResponse(text: "Karen took too long to respond. Please try again.", speechText: "", speak: false)
            }

        case .responding:
            isListening = false
            isSpeaking = false
            isLocalSpeechActive = false
            isInterrupting = false
            speechEngine?.stopListening()
            wakeWordDetector?.stop()

        case .speaking:
            isListening = false
            isSpeaking = true
            isLocalSpeechActive = true
            isInterrupting = false
            speechEngine?.stopListening()

        case .interrupting:
            activeResponseId = UUID()
            isInterrupting = true
            isSpeaking = false
            isLocalSpeechActive = false
            ttsEngine?.stop()
            speechTask?.cancel()
            speechTask = nil
            wakeWordDetector?.isBargeInMode = false
            wakeWordDetector?.stop()

        case .error, .permission:
            isListening = false
            isSpeaking = false
            isLocalSpeechActive = false
            isInterrupting = false
            speechEngine?.stopListening()
            ttsEngine?.stop()
            speechTask?.cancel()
            speechTask = nil
            wakeWordDetector?.stop()
        }

        updateGestureCoordination()
        return true
    }

    // MARK: - Phase 4 & Phase 6 Coordinated Siri-inspired Response Animation

    func presentResponse(text: String, speechText: String, speak: Bool) {
        let responseId = UUID()
        self.activeResponseId = responseId
        print("[KarenCore:Diag] [Session: \(responseId)] presentResponse. text chars: \(text.count), speechText chars: \(speechText.count), speak: \(speak).")
        self.speechTask?.cancel()
        self.replyText = text
        self.responseTextRevealedCount = 0
        if self.interactionState == .idle {
            self.transition(to: .processing, reason: "Preparing response presentation")
        }
        self.transition(to: .responding, reason: "Presenting response")

        // If the response panel is already open (e.g. follow-up query),
        // keep orb at top and reveal new content smoothly without re-running orb travel
        if self.showResponsePanel && self.orbTopProgress >= 0.95 {
            self.responsePhase = .contentReveal
            self.startSpeakingIfNeeded(speechText: speechText, speak: speak)
            return
        }

        // STEP 1 & 2: Smoothly shrink central orb (scale 1.0 -> 0.44) and travel to top-centre
        self.responsePhase = .movingOrb
        withAnimation(.spring(response: 0.60, dampingFraction: 0.82)) {
            self.orbTopProgress = 1.0
            self.orbScaleProgress = 0.44
        }

        // STEP 3 & 4: Settle orb at top-centre & illuminate subtle glowing connector
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.activeResponseId == responseId else { return }
            self.responsePhase = .orbSettled
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                self.showConnector = true
                self.responsePhase = .connectorLit
            }

            // STEP 5: Response panel emerges directly beneath orb with a smooth spring pop-up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.activeResponseId == responseId else { return }
                self.responsePhase = .panelEmerging
                withAnimation(.spring(response: 0.54, dampingFraction: 0.80)) {
                    self.showResponsePanel = true
                }

                // STEP 6: User's question and response appear inside the panel
                self.responsePhase = .contentReveal
                self.updateGestureCoordination()
                self.startSpeakingIfNeeded(speechText: speechText, speak: speak)
            }
        }
    }

    private func startSpeakingIfNeeded(speechText: String, speak: Bool) {
        let textToSpeak = speechText.isEmpty ? replyText : speechText
        print("[KarenCore:Diag] [Session: \(self.activeResponseId)] startSpeakingIfNeeded. textToSpeak count: \(textToSpeak.count). Initial words: '\(textToSpeak.prefix(60))...'")
        if speak && !self.isMuted && !self.isTextOnly && !textToSpeak.isEmpty {
            self.transition(to: .speaking, reason: "Starting TTS readout")
            self.speechTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Activate barge-in interrupt detector while speaking
                self.wakeWordDetector?.isBargeInMode = true
                self.wakeWordDetector?.currentSpokenText = textToSpeak
                self.wakeWordDetector?.start()

                print("[KarenCore:Diag] [Session: \(self.activeResponseId)] Commencing ttsEngine.speak...")
                await self.ttsEngine?.speak(textToSpeak)
                print("[KarenCore:Diag] [Session: \(self.activeResponseId)] ttsEngine.speak completed or returned.")

                guard !Task.isCancelled, self.interactionState == .speaking else {
                    print("[KarenCore:Diag] Speech task cancelled or state changed (\(self.interactionState)); ignoring completion flow.")
                    return
                }

                self.wakeWordDetector?.isBargeInMode = false
                self.wakeWordDetector?.stop()
                self.responseTextRevealedCount = self.replyText.count
                if self.interactionState == .speaking {
                    print("[KarenCore] Speech finished; keeping conversation active in listening mode...")
                    self.continuousConversation = true
                    if self.autoStartSubsystems {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard self.interactionState == .speaking else { return }
                        self.startListening()
                    } else {
                        self.transition(to: .listening, reason: "Speech finished; keeping conversation active")
                    }
                }
            }
        } else {
            self.responseTextRevealedCount = self.replyText.count
            self.transition(to: .idle, reason: "Text response displayed without speech")
        }
    }

    @discardableResult
    func saveGeminiKey(_ value: String) -> Bool {
        guard SearchCredentialStore.saveGeminiKey(value) else { return false }
        restartSidecar()
        return true
    }

    @discardableResult
    func removeGeminiKey() -> Bool {
        guard SearchCredentialStore.removeGeminiKey() else { return false }
        restartSidecar()
        return true
    }

    func validateGeminiKey(_ key: String) async -> (isValid: Bool, message: String) {
        await SearchCredentialStore.validateGeminiKey(key)
    }

    func restartSidecar() {
        guard let bridge = sidecarBridge else {
            setupSidecar()
            return
        }
        bridge.stop { [weak self] in self?.setupSidecar() }
    }



    // ── Listening controls ───────────────────────────────────────────────────

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    func startListening(initialTranscript: String? = nil) {
        guard micGranted else {
            presentResponse(text: "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone.", speechText: "", speak: false)
            transition(to: .permission, reason: "Microphone permission required")
            requestMic()
            return
        }
        guard speechGranted else {
            presentResponse(text: "Speech Recognition access is disabled. Enable it in System Settings > Privacy & Security > Speech Recognition.", speechText: "", speak: false)
            transition(to: .permission, reason: "Speech Recognition permission required")
            requestSpeechRecognition()
            return
        }
        if autoStartSubsystems && speechEngine == nil {
            initSpeech()
        }
        continuousConversation = true
        conversationGeneration += 1
        liveTranscription = initialTranscript ?? ""
        transition(to: .listening, reason: "startListening invoked")

        guard autoStartSubsystems else { return }

        speechEngine?.startListening(initialTranscript: initialTranscript) { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                if !isFinal {
                    self.liveTranscription = text
                    return
                }

                // Final transcription received
                self.liveTranscription = ""
                self.transition(to: .processing, reason: "Final transcript received")
                guard !self.isHandlingUtterance else { return }
                self.isHandlingUtterance = true
                defer { self.isHandlingUtterance = false }

                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?;, "))
                let backgroundCommands: Set<String> = [
                    "quit", "quit karen", "exit", "exit karen", "close karen",
                    "close the app", "go offline", "terminate"
                ]
                if backgroundCommands.contains(normalized) {
                    self.continuousConversation = false
                    self.conversationGeneration += 1
                    self.speechEngine?.stopListening()
                    self.transition(to: .idle, reason: "Quit command received")
                    self.hideAssistantWindow()
                    self.resumeWakeWordIfNeeded()
                    return
                }

                self.lastUserQuery = text
                self.replyText = ""
                self.responseTextRevealedCount = 0

                guard let bridge = self.sidecarBridge else {
                    self.presentResponse(text: "The voice assistant service is unavailable. Restart K.A.R.E.N. to reconnect.", speechText: "", speak: false)
                    self.continuousConversation = false
                    self.transition(to: .error, reason: "Sidecar bridge unavailable")
                    self.resumeWakeWordIfNeeded()
                    return
                }
                if text.hasPrefix("Speech recognition is disabled") || text == "Speech recognition is not available." {
                    self.presentResponse(text: text, speechText: "", speak: false)
                    self.continuousConversation = false
                    self.transition(to: .permission, reason: "Speech recognition disabled")
                    return
                }
                let reqId = UUID().uuidString
                self.currentRequestId = reqId
                do {
                    try await bridge.sendTranscript(id: reqId, text: text, final: true,
                                                    imageLabels: self.selectedImageLabels)
                } catch {
                    self.currentRequestId = ""
                    self.presentResponse(text: "I couldn't send that request. Please try again.", speechText: "", speak: false)
                    self.transition(to: .error, reason: "Failed to send transcript: \(error)")
                    if self.continuousConversation { self.startListening() }
                    else { self.resumeWakeWordIfNeeded() }
                    return
                }
            }
        }
    }

    func stopListening() {
        continuousConversation = false
        conversationGeneration += 1
        transition(to: .idle, reason: "stopListening invoked")
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted { stopSpeaking() }
    }

    func stopSpeaking() {
        print("[KarenCore:Diag] stopSpeaking() called. Current state: \(interactionState), isSpeaking: \(isSpeaking)")
        if !currentRequestId.isEmpty {
            sidecarBridge?.sendCancel(id: currentRequestId)
            currentRequestId = ""
        }
        transition(to: .idle, reason: "stopSpeaking invoked")
        responseTextRevealedCount = replyText.count
    }

    func handleInterrupt(detectedTranscript: String? = nil) {
        print("[KarenCore:Diag] handleInterrupt() invoked. detectedTranscript: '\(detectedTranscript ?? "")'. Current state: \(interactionState), isSpeaking: \(isSpeaking), isLocalSpeechActive: \(isLocalSpeechActive)")
        guard isSpeaking || interactionState == .speaking || interactionState == .responding || interactionState == .processing || isLocalSpeechActive else { return }
        print("[KarenCore] Interruption detected! Transcript: '\(detectedTranscript ?? "")'")

        let raw = (detectedTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stopPhrases = [
            "stop", "stop speaking", "pause", "shut up", "be quiet", "wait", "cancel", "hold on", "hold it",
            "போதும்", "நில்", "நிறுத்து", "பேசாதே"
        ]
        let isExplicitStop = stopPhrases.contains { phrase in
            raw == phrase || raw.hasPrefix(phrase + " ") || raw.hasSuffix(" " + phrase) || raw.contains(" " + phrase + " ")
        }

        if isExplicitStop {
            print("[KarenCore] Interruption was a stop command; halting speech and returning to idle")
            stopSpeaking()
            return
        }

        print("[KarenCore] Halting speech output for new query barge-in...")
        if !currentRequestId.isEmpty {
            sidecarBridge?.sendCancel(id: currentRequestId)
            currentRequestId = ""
        }
        transition(to: .interrupting, reason: "User interrupted")
        ttsEngine?.stop()
        speechTask?.cancel()
        speechTask = nil
        wakeWordDetector?.isBargeInMode = false
        wakeWordDetector?.stop()

        // Extract trailing query: if user said "Hey Karen, what time is it?"
        var cleanTranscript: String? = nil
        if let detector = wakeWordDetector {
            let range = NSRange(raw.startIndex..., in: raw)
            if let match = detector.wakePattern.firstMatch(in: raw, range: range) {
                cleanTranscript = detector.extractTrailingQuery(from: raw, matchRange: match.range)
            }
        }
        if cleanTranscript == nil {
            var trimmed = raw
            for prefix in [
                "hey karen", "hi karen", "hello karen", "ok karen", "okay karen", "karen", "caring", "carin",
                "வணக்கம் கரேன்", "ஹே கரேன்", "கரேன்"
            ] {
                if trimmed.hasPrefix(prefix) {
                    trimmed = String(trimmed.dropFirst(prefix.count))
                }
            }
            trimmed = trimmed.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;- ")))
            cleanTranscript = trimmed.isEmpty ? nil : trimmed
        }

        startListening(initialTranscript: cleanTranscript)
        if let query = cleanTranscript, !query.isEmpty {
            self.liveTranscription = query
        } else {
            self.liveTranscription = "Listening..."
        }
    }

    func replayLastResponse() {
        guard !replyText.isEmpty else { return }
        speechTask?.cancel()
        ttsEngine?.stop()
        responseTextRevealedCount = 0
        transition(to: .speaking, reason: "Replaying last response")
        wakeWordDetector?.isBargeInMode = true
        wakeWordDetector?.currentSpokenText = replyText
        wakeWordDetector?.start()

        let textToSpeak = replyText
        speechTask = Task { @MainActor in
            await self.ttsEngine?.speak(textToSpeak)

            self.wakeWordDetector?.isBargeInMode = false
            self.wakeWordDetector?.stop()
            self.responseTextRevealedCount = textToSpeak.count
            if self.interactionState == .speaking {
                self.transition(to: .idle, reason: "Replay finished")
            }
        }
    }

    func askFollowUp() {
        stopSpeaking()
        startListening()
    }

    func dismissResponsePanel() {
        activeResponseId = UUID()
        stopSpeaking()
        speechTask?.cancel()
        responsePhase = .dismissed
        showResponsePanel = false
        showConnector = false
        transition(to: .idle, reason: "Response panel dismissed")
        updateGestureCoordination()

        withAnimation(.spring(response: 0.58, dampingFraction: 0.80)) {
            self.orbTopProgress = 0.0
            self.orbScaleProgress = 1.0
            self.orbOffsetY = 0.0
            self.replyText = ""
            self.responseTextRevealedCount = 0
            self.liveTranscription = ""
        }
    }

    func requestOpenSettings() {
        guard !isRemoteApprovalPending else {
            presentResponse(
                text: "A remote approval request for Settings is already pending on your phone, sir.",
                speechText: "A remote approval request for Settings is already pending on your phone, sir.",
                speak: true
            )
            return
        }

        if showSettings { return }

        isRemoteApprovalPending = true
        transition(to: .processing, reason: "Awaiting remote approval for Settings")

        presentResponse(
            text: "Request sent to your phone. Waiting for your approval to open Settings, sir.",
            speechText: "Request sent to your phone. Waiting for your approval to open Settings, sir.",
            speak: true
        )

        activeRemoteApprovalTask = Task { @MainActor in
            let result = await RemoteApprovalClient.shared.requestSettingsApproval(timeoutSeconds: 86400.0)
            guard self.isRemoteApprovalPending else { return }
            self.isRemoteApprovalPending = false
            self.activeRemoteApprovalTask = nil

            switch result {
            case .approved:
                self.transition(to: .speaking, reason: "Remote approval granted")
                self.showSettings = true
                self.presentResponse(
                    text: "Remote approval granted. Opening Settings, sir.",
                    speechText: "Remote approval granted. Opening Settings, sir.",
                    speak: true
                )
            case .rejected:
                self.transition(to: .idle, reason: "Remote approval denied")
                self.showSettings = false
                self.presentResponse(
                    text: "Remote access denied: Request was rejected from your phone, sir.",
                    speechText: "Remote access denied: Request was rejected from your phone, sir.",
                    speak: true
                )
            case .expired:
                self.transition(to: .idle, reason: "Remote approval expired")
                self.showSettings = false
                self.presentResponse(
                    text: "Remote approval expired. Settings remains locked, sir.",
                    speechText: "Remote approval expired. Settings remains locked, sir.",
                    speak: true
                )
            case .failed(let err):
                NSLog("[KarenCore] Remote approval error: %@", err)
                self.transition(to: .error, reason: "Remote approval error: \(err)")
                self.showSettings = false
                self.presentResponse(
                    text: "Remote approval error: \(err). Settings remains locked, sir.",
                    speechText: "Remote approval error: \(err), sir.",
                    speak: true
                )
            }
        }
    }

    private func openApplication(named name: String) {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "settings" || normalized == "karen settings" || normalized == "preferences" {
            requestOpenSettings()
            return
        }
        let aliases = ["chrome": "google chrome", "edge": "microsoft edge"]
        let launchName = aliases[normalized] ?? name
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", launchName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                self?.replyText = "I couldn’t find or open \(name). Check that it’s installed, then try again."
            }
        }
        do {
            try process.run()
        } catch {
            replyText = "I couldn’t open \(name): \(error.localizedDescription)"
            return
        }
    }

    func sendTextInput(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let bridge = sidecarBridge else { return }
        speechTask?.cancel()
        ttsEngine?.stop()
        lastUserQuery = value

        // If response panel is already open (follow-up query), keep orb at top and clear reply;
        // if response panel is not open, orb stays centred with thinking animation!
        if showResponsePanel {
            replyText = ""
            responseTextRevealedCount = 0
        }
        transition(to: .processing, reason: "Text input submitted")

        let reqId = UUID().uuidString
        self.currentRequestId = reqId

        Task {
            do {
                try await bridge.sendTranscript(id: reqId, text: value, final: true,
                                                source: "text", imageLabels: selectedImageLabels)
            } catch {
                self.currentRequestId = ""
                presentResponse(text: "I couldn't send that message. Please try again.", speechText: "", speak: false)
                transition(to: .error, reason: "Failed to send text input: \(error)")
            }
        }
    }

    func chooseImageInput() {
        let panel = NSOpenPanel()
        panel.title = "Choose an image for K.A.R.E.N."
        panel.prompt = "Use Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        replyText = "Looking at the selected image…"
        orbState = .processing
        updateGestureCoordination()
        Task { [weak self] in
            let labels = await Task.detached(priority: .userInitiated) { () -> [String]? in
                do {
                let request = VNClassifyImageRequest()
                try VNImageRequestHandler(url: url).perform([request])
                    return (request.results ?? [])
                    .filter { $0.confidence >= 0.08 }
                    .prefix(6)
                    .map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }
                } catch {
                    return nil
                }
            }.value

            guard let self else { return }
            guard let labels else {
                self.orbState = .error
                self.replyText = "I couldn't read that image. Try another image format."
                self.updateGestureCoordination()
                return
            }
            self.selectedImageLabels = labels
            self.orbState = .idle
            self.updateGestureCoordination()
            if labels.isEmpty {
                self.replyText = "I couldn't confidently label that image. Try a clearer picture."
            } else {
                self.replyText = "Image ready. Ask me what it shows. The image stays on your Mac."
            }
        }
    }

    func clearImageInput() {
        selectedImageLabels = []
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

        if speechEngine == nil {
            let engine = SpeechEngine()
            engine.onAudioLevel = { [weak self] level in
                Task { @MainActor in
                    self?.audioLevel = level
                }
            }
            engine.onError = { [weak self] errMsg in
                Task { @MainActor in
                    guard let self else { return }
                    self.isListening = false
                    self.liveTranscription = ""
                    self.orbState = .idle
                    if self.continuousConversation && errMsg.contains("Didn't catch any speech") {
                        // User naturally paused / finished speaking in continuous mode; return to idle cleanly
                        self.continuousConversation = false
                        self.transition(to: .idle, reason: "Continuous listening ended with silence")
                        self.resumeWakeWordIfNeeded()
                        return
                    }
                    self.presentResponse(text: errMsg, speechText: "", speak: false)
                    self.resumeWakeWordIfNeeded()
                }
            }
            speechEngine = engine
        }

        if wakeWordDetector == nil {
            let detector = WakeWordDetector(onWakeWithTranscript: { [weak self] transcript in
                Task { @MainActor in self?.onWakeWord(initialTranscript: transcript) }
            })
            detector.onInterrupt = { [weak self] transcript in
                Task { @MainActor in self?.handleInterrupt(detectedTranscript: transcript) }
            }
            wakeWordDetector = detector
        }

        if wakeWordEnabled && speechGranted && !isListening {
            wakeWordDetector?.start()
        }
    }

    func openMemoryMap() {
        refreshMemoryNodeLabels()
        if zoomBeforeMemory == nil { zoomBeforeMemory = orbZoom }
        showMemory = true
        applyZoom(3.6 / max(orbZoom, 0.3))
    }

    func refreshMemoryNodeLabels() {
        memoryNodeLabels = sidecarBridge?.memory?.list_approved().compactMap { row in
            guard let content = row["content"] as? String else { return nil }
            return content
        } ?? []
    }

    func closeMemoryMap() {
        showMemory = false
        guard let previous = zoomBeforeMemory else { return }
        zoomBeforeMemory = nil
        applyZoom(previous / max(orbZoom, 0.3))
    }

    func onWakeWord(initialTranscript: String? = nil) {
        guard interactionState != .listening else { return }
        print("[KarenCore] onWakeWord triggered. initialTranscript: '\(initialTranscript ?? "")'")
        showAssistantWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        wakeWordDetector?.stop()
        continuousConversation = false
        conversationGeneration += 1
        startListening(initialTranscript: initialTranscript)
    }

    private func resumeWakeWordIfNeeded() {
        guard wakeWordEnabled, speechGranted, !isListening else { return }
        print("[KarenCore] Resuming wake word detector...")
        wakeWordDetector?.start()
    }

    func enableGestureMode() {
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { requestCamera(); return }
        cameraGranted = true
        gestureMode = true
        startCameraGestures()
    }

    func startCameraGestures() {
        guard cameraGranted, gestureMode else { return }
        // Prevent multiple camera sessions
        guard gestureProcessor == nil else {
            updateGestureCoordination()
            return
        }
        let processor = GestureProcessor(core: self)
        processor.onError = { [weak self] errorMessage in
            Task { @MainActor in
                self?.handleCameraError(errorMessage)
            }
        }
        gestureProcessor = processor
        processor.start()
        cameraActive = processor.isRunning
        updateGestureCoordination()
    }

    func handleCameraError(_ message: String) {
        print("[KarenCore] Camera error: \(message)")
        cameraError = message
        cameraActive = false
        gestureMode = false
        gestureProcessor = nil
        isGesturePaused = false
        replyText = message
    }

    func pauseCameraGestures() {
        guard let processor = gestureProcessor else { return }
        processor.pause()
        isGesturePaused = true
    }

    func resumeCameraGestures() {
        guard gestureMode, cameraGranted, let processor = gestureProcessor else { return }
        // Requirement 6: Ensure camera gestures cannot resume while TTS is still speaking
        guard !(ttsEngine?.isSpeaking ?? false), !isSpeaking, !isLocalSpeechActive else { return }
        guard !isVoiceInteractionActive else { return }

        processor.resume()
        isGesturePaused = false
    }

    func updateGestureCoordination() {
        guard gestureMode, cameraGranted, gestureProcessor != nil else { return }

        let ttsSpeaking = (ttsEngine?.isSpeaking ?? false) || isSpeaking || isLocalSpeechActive

        if isVoiceInteractionActive || ttsSpeaking {
            if !isGesturePaused {
                pauseCameraGestures()
            }
        } else {
            if isGesturePaused {
                resumeCameraGestures()
            }
        }
    }

    func disableGestureMode() {
        gestureMode = false
        gestureProcessor?.stop()
        gestureProcessor = nil
        cameraActive = false
        isGesturePaused = false
    }

    // ── Zoom / Rotate / Translate (from gestures OR mouse/keyboard) ──────────

    func applyZoom(_ factor: Float) {
        guard !isVoiceInteractionActive else { return }
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
        guard !isVoiceInteractionActive else { return }
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
        guard !isVoiceInteractionActive else { return }
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
