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
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.defaultTaskHint = .dictation
        super.init()
    }

    func startListening(onResult: @escaping (String, Bool) -> Void) {
        self.onResult = onResult
        guard !isStarting, !isListening else { return }
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
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: begin(.authorized)
        case .notDetermined: SFSpeechRecognizer.requestAuthorization(begin)
        case .denied, .restricted: begin(SFSpeechRecognizer.authorizationStatus())
        @unknown default: begin(.restricted)
        }
    }

    private func doStart() {
        guard !isListening else { return }
        silenceTask?.cancel()
        silenceTask = nil
        latestTranscript = ""

        do {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            // If on-device recognition is supported by this Mac's offline model, use it;
            // otherwise allow network recognition to avoid throwing an immediate error.
            if let recognizer = recognizer, recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            } else {
                req.requiresOnDeviceRecognition = false
            }
            self.request = req

            let inputNode = audioEngine.inputNode
            // Enable macOS hardware acoustic echo cancellation & noise suppression
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                print("[SpeechEngine] Voice processing unavailable: \(error.localizedDescription)")
            }

            // Ensure previous tap is cleared before installing a new one
            inputNode.removeTap(onBus: 0)

            let hwFormat = inputNode.outputFormat(forBus: 0)
            let format: AVAudioFormat
            if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
                format = hwFormat
            } else if let std = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) {
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
            try audioEngine.start()
            isListening = true

            task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                if let r = result {
                    let text = r.bestTranscription.formattedString
                    let isFinal = r.isFinal
                    DispatchQueue.main.async {
                        self.latestTranscript = text
                        if isFinal {
                            self.stopListening()
                            self.onResult?(text, true)
                        } else {
                            self.onResult?(text, false)
                            self.armSilenceTimer(for: text)
                        }
                    }
                }
                if let err {
                    DispatchQueue.main.async {
                        print("[SpeechEngine] Recognition task ended: \(err.localizedDescription)")
                        let transcript = self.latestTranscript
                        let wasListening = self.isListening
                        self.stopListening()
                        if !transcript.isEmpty {
                            self.onResult?(transcript, true)
                        } else if wasListening {
                            // If stopped without transcript, notify so caller resets UI
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
        if audioEngine.isRunning { audioEngine.inputNode.removeTap(onBus: 0) }
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        isStarting = false
        voiceActivityActive = false
        loudFrameCount = 0
        quietFrameCount = 0
        onAudioLevel?(0)
    }
}

// ─── TTS Engine (AVSpeechSynthesizer) ────────────────────────────────────────

@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var voiceId: String = ""
    var rate:    Float  = 0.50
    var pitch:   Float  = 0.92
    var onFinish: (() -> Void)?
    var isSpeaking: Bool { synth.isSpeaking }
    private var activeUtterance: AVSpeechUtterance?
    private var speechContinuation: CheckedContinuation<Void, Never>?

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
        await withCheckedContinuation { cont in
            let utterance = makeUtterance(text)
            activeUtterance = utterance
            speechContinuation = cont
            synth.speak(utterance)
        }
    }

    func speak(_ text: String) {
        stop()
        let utterance = makeUtterance(text)
        activeUtterance = utterance
        synth.speak(utterance)
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceId.isEmpty ? AVSpeechSynthesisVoice(language: "en-US")
                                          : AVSpeechSynthesisVoice(identifier: voiceId)
        utterance.rate = rate
        utterance.volume = 1.0
        utterance.pitchMultiplier = pitch
        return utterance
    }

    func stop() {
        activeUtterance = nil
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume()
        }
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard activeUtterance === utterance else { return }
            activeUtterance = nil
            if let continuation = speechContinuation {
                speechContinuation = nil
                continuation.resume()
            }
            onFinish?()
            onFinish = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard activeUtterance === utterance else { return }
            activeUtterance = nil
            if let continuation = speechContinuation {
                speechContinuation = nil
                continuation.resume()
            }
            onFinish?()
            onFinish = nil
        }
    }
}
