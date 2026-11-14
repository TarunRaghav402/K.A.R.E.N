import Foundation
import Speech
import AVFoundation

// ─── Speech Engine (STT) ──────────────────────────────────────────────────────

final class SpeechEngine: NSObject {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var onResult: ((String, Bool) -> Void)?
    private var isStarting = false
    private(set) var isListening = false
    private var silenceTask: DispatchWorkItem?
    private var latestTranscript = ""
    private var initialTranscriptSeed: String?
    private var estimatedNoiseFloor: Float = 0.012
    private var loudFrameCount = 0
    private var quietFrameCount = 0
    private var voiceActivityActive = false
    private var meterFrameCount = 0
    var microphoneSensitivity: Float = 0.7
    var onVoiceActivity: (() -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    // Allow natural pauses so the recognizer is less likely to submit a
    // partial phrase before the user finishes speaking.
    private let silenceTimeout: TimeInterval = 1.3

    override init() {
        let indianLocale = Locale(identifier: "en-IN")
        if SFSpeechRecognizer.supportedLocales().contains(indianLocale) {
            recognizer = SFSpeechRecognizer(locale: indianLocale)
        } else {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        recognizer?.defaultTaskHint = .dictation
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAudioEngineConfigurationChange(notification: Notification) {
        print("[SpeechEngine] Audio engine configuration changed (route or device update)")
        if isListening {
            guard let resultHandler = onResult else { return }
            stopListening()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.startListening(onResult: resultHandler)
            }
        } else {
            audioEngine.reset()
        }
    }

    func startListening(initialTranscript: String? = nil, onResult: @escaping (String, Bool) -> Void) {
        self.onResult = onResult
        self.initialTranscriptSeed = initialTranscript
        guard !isStarting, !isListening else { return }

        let auth = SFSpeechRecognizer.authorizationStatus()
        if auth == .authorized {
            self.doStart()
            return
        }

        isStarting = true
        let begin: (SFSpeechRecognizerAuthorizationStatus) -> Void = { [weak self] status in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isStarting = false
                guard status == .authorized else {
                    let msg = status == .denied
                        ? "Microphone or Speech Recognition is disabled. Enable it in System Settings > Privacy & Security."
                        : "Speech recognition is currently unavailable."
                    self.onError?(msg)
                    return
                }
                self.doStart()
            }
        }
        if auth == .notDetermined {
            SFSpeechRecognizer.requestAuthorization(begin)
        } else {
            begin(auth)
        }
    }

    private func doStart() {
        guard !isListening else { return }
        silenceTask?.cancel()
        silenceTask = nil
        let seed = initialTranscriptSeed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        initialTranscriptSeed = nil
        latestTranscript = seed
        if !seed.isEmpty {
            armSilenceTimer(for: seed)
        }

        do {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if #available(macOS 13.0, *) {
                req.addsPunctuation = true
            }
            req.requiresOnDeviceRecognition = false
            self.request = req

            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0)

            let hwFormat = inputNode.outputFormat(forBus: 0)
            let format: AVAudioFormat
            if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
                format = hwFormat
            } else if let std = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) {
                format = std
            } else {
                format = hwFormat
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let self else { return }
                self.processLevel(buf)
                self.request?.append(buf)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                print("[SpeechEngine] First start failed: \(error), resetting engine and retrying...")
                audioEngine.reset()
                Thread.sleep(forTimeInterval: 0.08)
                try audioEngine.start()
            }
            isListening = true

            task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                if let r = result {
                    let text = r.bestTranscription.formattedString
                    let isFinal = r.isFinal
                    DispatchQueue.main.async {
                        guard self.isListening else { return }
                        self.latestTranscript = text
                        if isFinal {
                            let finalText = text
                            self.stopListening()
                            self.onResult?(finalText, true)
                        } else {
                            self.onResult?(text, false)
                            self.armSilenceTimer(for: text)
                        }
                    }
                }
                if let err {
                    DispatchQueue.main.async {
                        guard self.isListening else { return }
                        let nsErr = err as NSError
                        // Ignore standard client cancellation errors (code 216 / 3072)
                        let isCancelled = nsErr.code == 216 || nsErr.code == 3072 || nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 216
                        if isCancelled {
                            self.stopListening()
                            return
                        }
                        print("[SpeechEngine] Recognition task ended: \(err.localizedDescription)")
                        let transcript = self.latestTranscript
                        self.stopListening()
                        if !transcript.isEmpty {
                            self.onResult?(transcript, true)
                        } else {
                            self.onError?("Didn't catch any speech. Try speaking again.")
                        }
                    }
                }
            }
        } catch {
            print("[SpeechEngine] Failed to start: \(error)")
            stopListening()
            onError?("Could not activate microphone: \(error.localizedDescription)")
        }
    }

    /// Lightweight adaptive energy VAD for fast barge-in detection and orb
    /// metering. Apple's speech recognizer still determines the transcript.
    private func processLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = channel
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        let sensitivity = min(1, max(0, microphoneSensitivity))
        let threshold = max(0.004, estimatedNoiseFloor * (2.5 - sensitivity * 1.35))

        if !voiceActivityActive {
            if rms < threshold {
                estimatedNoiseFloor = min(0.08, estimatedNoiseFloor * 0.96 + rms * 0.04)
                loudFrameCount = 0
            } else {
                loudFrameCount += 1
                if loudFrameCount >= 3 {
                    voiceActivityActive = true
                    quietFrameCount = 0
                    DispatchQueue.main.async { [weak self] in self?.onVoiceActivity?() }
                }
            }
        } else if rms < threshold * 0.62 {
            quietFrameCount += 1
            if quietFrameCount >= 12 {
                voiceActivityActive = false
                loudFrameCount = 0
                quietFrameCount = 0
            }
        } else {
            quietFrameCount = 0
        }

        meterFrameCount += 1
        if meterFrameCount >= 4 {
            meterFrameCount = 0
            let level = min(1, max(0, rms * 12))
            DispatchQueue.main.async { [weak self] in self?.onAudioLevel?(level) }
        }
    }

    private func armSilenceTimer(for text: String) {
        guard isListening else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        latestTranscript = cleaned
        silenceTask?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            let transcript = self.latestTranscript
            guard !transcript.isEmpty else { return }
            self.stopListening()
            self.onResult?(transcript, true)
        }
        silenceTask = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceTimeout, execute: timer)
    }

    func stopListening() {
        silenceTask?.cancel()
        silenceTask = nil
        latestTranscript = ""
        initialTranscriptSeed = nil
        isListening = false
        isStarting = false
        voiceActivityActive = false
        loudFrameCount = 0
        quietFrameCount = 0
        onAudioLevel?(0)

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        request?.endAudio()
        let activeTask = task
        task = nil
        request = nil
        activeTask?.cancel()
    }
}

// ─── TTS Engine (AVSpeechSynthesizer) ────────────────────────────────────────

@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    private var synth = AVSpeechSynthesizer()
    var voiceId: String = ""
    var rate:    Float  = 0.50
    var pitch:   Float  = 0.92
    var onFinish: (() -> Void)?
    var onSpeechStateChanged: ((Bool) -> Void)?
    var onSpeechProgress: ((_ characterLocation: Int, _ totalLength: Int) -> Void)?
    var isSpeaking: Bool { activeUtterance != nil }
    private var activeUtterance: AVSpeechUtterance?
    private var speechContinuation: CheckedContinuation<Void, Never>?
    private var activeSessionId = UUID()
    private var watchdogTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastProgressTime: Date = Date()
    private var lastCharacterLocation: Int = 0

    override init() {
        super.init()
        synth.delegate = self
        // Default: Samantha or first English female voice
        if let v = AVSpeechSynthesisVoice.speechVoices()
            .first(where: { $0.language.hasPrefix("en") && ($0.name.contains("Samantha") || $0.name.contains("Ava")) }) {
            voiceId = v.identifier
        }
    }

    func speak(_ text: String) async {
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onSpeechProgress?(text.count, text.count)
            return
        }

        let sessionId = UUID()
        activeSessionId = sessionId
        onSpeechStateChanged?(true)
        onSpeechProgress?(0, text.count)
        lastProgressTime = Date()
        lastCharacterLocation = 0

        // Calculate expected duration based on speech rate (approx 15-20 chars/sec at 0.50 rate)
        let charsPerSec = max(8.0, Double(rate) * 35.0)
        let estimatedSecs = Double(trimmed.count) / charsPerSec
        let timeoutSecs = max(4.0, estimatedSecs * 2.2 + 5.0)
        print("[TTSEngine:Diag] [Session: \(sessionId)] Utterance created for \(trimmed.count) chars. Estimated duration: \(String(format: "%.1f", estimatedSecs))s, watchdog timeout: \(String(format: "%.1f", timeoutSecs))s.")

        startWatchdog(timeout: timeoutSecs, sessionId: sessionId, expectedChars: text.count)
        startHeartbeat(sessionId: sessionId, expectedChars: text.count)

        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                guard self.activeSessionId == sessionId else {
                    cont.resume()
                    return
                }
                let utterance = self.makeUtterance(trimmed)
                self.activeUtterance = utterance
                self.speechContinuation = cont
                self.synth.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in
                if self.activeSessionId == sessionId {
                    self.stop()
                }
            }
        }
    }

    func speak(_ text: String) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onSpeechProgress?(text.count, text.count)
            return
        }

        let sessionId = UUID()
        activeSessionId = sessionId
        onSpeechStateChanged?(true)
        onSpeechProgress?(0, text.count)
        lastProgressTime = Date()
        lastCharacterLocation = 0

        let charsPerSec = max(8.0, Double(rate) * 35.0)
        let estimatedSecs = Double(trimmed.count) / charsPerSec
        let timeoutSecs = max(4.0, estimatedSecs * 2.2 + 5.0)

        startWatchdog(timeout: timeoutSecs, sessionId: sessionId, expectedChars: text.count)
        startHeartbeat(sessionId: sessionId, expectedChars: text.count)

        let utterance = makeUtterance(trimmed)
        activeUtterance = utterance
        synth.speak(utterance)
    }

    private func startWatchdog(timeout: TimeInterval, sessionId: UUID, expectedChars: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            let nanos = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self, self.activeSessionId == sessionId else { return }

            // If speech is actively playing or synthesizer is speaking, NEVER abort healthy speech!
            if self.synth.isSpeaking || self.isSpeaking {
                print("[TTSEngine:Diag] [Session: \(sessionId)] Speech is still actively playing in synthesizer; extending watchdog...")
                self.startWatchdog(timeout: 10.0, sessionId: sessionId, expectedChars: expectedChars)
                return
            }

            print("[TTSEngine:Diag] [Session: \(sessionId)] Watchdog timeout reached (\(timeout)s). Forcing completion to prevent speech hang.")
            self.completeSpeech(sessionId: sessionId, textCount: expectedChars, forceReset: true)
        }
    }

    private func startHeartbeat(sessionId: UUID, expectedChars: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            // Heartbeat safely monitors end-of-speech:
            // It only intervenes if all words have completed being spoken
            // and audio playback is finished, but didFinish was not delivered by AVFoundation.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.activeSessionId == sessionId else { return }

                let lastCharLoc = self.lastCharacterLocation
                let hasReachedEnd = expectedChars > 0 && lastCharLoc >= expectedChars

                if hasReachedEnd && !self.synth.isSpeaking && self.activeUtterance != nil {
                    let quietTime = Date().timeIntervalSince(self.lastProgressTime)
                    if quietTime > 3.0 {
                        print("[TTSEngine:Diag] [Session: \(sessionId)] All words spoken (\(lastCharLoc)/\(expectedChars)) and audio finished; completing speech.")
                        self.completeSpeech(sessionId: sessionId, textCount: expectedChars, forceReset: false)
                        return
                    }
                }
            }
        }
    }

    private func completeSpeech(sessionId: UUID, textCount: Int, forceReset: Bool) {
        guard activeSessionId == sessionId else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        onSpeechProgress?(textCount, textCount)
        activeUtterance = nil

        if forceReset {
            synth.stopSpeaking(at: .immediate)
            synth = AVSpeechSynthesizer()
            synth.delegate = self
        }

        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume()
        }
        let finishBlock = onFinish
        onFinish = nil
        finishBlock?()
        onSpeechStateChanged?(false)
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        var spoken = text
        spoken = spoken.replacingOccurrences(of: "K.A.R.E.N.", with: "Karen")
        spoken = spoken.replacingOccurrences(of: "K.A.R.E.N", with: "Karen")
        let utterance = AVSpeechUtterance(string: spoken)

        let hasTamil = spoken.unicodeScalars.contains { $0.value >= 0x0B80 && $0.value <= 0x0BFF }
        if hasTamil {
            // Select native Indian Tamil voice (Vani / ta-IN)
            if let tamilVoice = AVSpeechSynthesisVoice(language: "ta-IN")
                ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "ta-IN" || $0.language.hasPrefix("ta") }) {
                utterance.voice = tamilVoice
            } else {
                utterance.voice = voiceId.isEmpty ? AVSpeechSynthesisVoice(language: "en-US")
                                                  : AVSpeechSynthesisVoice(identifier: voiceId)
            }
            utterance.rate = min(rate, 0.48) // Natural Indian Tamil pacing
        } else {
            utterance.voice = voiceId.isEmpty ? AVSpeechSynthesisVoice(language: "en-US")
                                              : AVSpeechSynthesisVoice(identifier: voiceId)
            utterance.rate = rate
        }
        utterance.volume = 1.0
        utterance.pitchMultiplier = pitch
        return utterance
    }

    func stop(reason: String = "Explicit stop") {
        activeSessionId = UUID() // Invalidate any in-flight session
        watchdogTask?.cancel()
        watchdogTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let wasActive = activeUtterance != nil || synth.isSpeaking
        print("[TTSEngine:Diag] stop() called. Reason: \(reason). wasActive: \(wasActive), isSpeaking: \(synth.isSpeaking).")
        activeUtterance = nil
        lastCharacterLocation = 0
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume()
        }
        synth.stopSpeaking(at: .immediate)
        if wasActive {
            onSpeechStateChanged?(false)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard self.activeUtterance === utterance else { return }
            self.lastProgressTime = Date()
            let progress = min(utterance.speechString.count, characterRange.location + characterRange.length)
            self.lastCharacterLocation = progress
            let word = (utterance.speechString as NSString).substring(with: characterRange)
            print("[TTSEngine:Diag] [Session: \(self.activeSessionId)] Word boundary: [\(word)] at \(characterRange.location)..\(characterRange.location + characterRange.length) of \(utterance.speechString.count).")
            self.onSpeechProgress?(progress, utterance.speechString.count)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            print("[TTSEngine:Diag] [Session: \(self.activeSessionId)] didFinish received for utterance (\(utterance.speechString.count) chars). activeUtterance matches: \(self.activeUtterance === utterance)")
            guard self.activeUtterance === utterance else { return }
            self.completeSpeech(sessionId: self.activeSessionId, textCount: utterance.speechString.count, forceReset: false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            print("[TTSEngine:Diag] [Session: \(self.activeSessionId)] didCancel received for utterance. activeUtterance matches: \(self.activeUtterance === utterance)")
            guard self.activeUtterance === utterance else { return }
            self.watchdogTask?.cancel()
            self.watchdogTask = nil
            self.heartbeatTask?.cancel()
            self.heartbeatTask = nil
            self.activeUtterance = nil
            if let continuation = self.speechContinuation {
                self.speechContinuation = nil
                continuation.resume()
            }
            let finishBlock = self.onFinish
            self.onFinish = nil
            finishBlock?()
            self.onSpeechStateChanged?(false)
        }
    }
}
