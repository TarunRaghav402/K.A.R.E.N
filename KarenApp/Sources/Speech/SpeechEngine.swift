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
    private var isListening = false
    private var silenceTask: DispatchWorkItem?
    private var latestTranscript = ""
    private let silenceTimeout: TimeInterval = 1.0

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
                    self.onResult?(status == .denied ? "Speech recognition is disabled. Enable it in System Settings > Privacy & Security > Speech Recognition." : "Speech recognition is not available.", true)
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
        do {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true  // on-device only
            self.request = req

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
                req.append(buf)
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
                        if isFinal {
                            self.stopListening()
                            self.onResult?(text, true)
                        } else {
                            self.onResult?(text, false)
                            self.armSilenceTimer(for: text)
                        }
                    }
                }
                if let _ = err { self.stopListening() }
            }
        } catch {
            print("[SpeechEngine] Failed to start: \(error)")
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
    }
}

// ─── TTS Engine (AVSpeechSynthesizer) ────────────────────────────────────────

@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var voiceId: String = ""
    var rate:    Float  = 0.50
    var pitch:   Float  = 1.05
    var onFinish: (() -> Void)?
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
