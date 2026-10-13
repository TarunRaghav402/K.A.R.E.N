import Foundation
import Speech
import AVFoundation

// ─── Wake Word Detector ───────────────────────────────────────────────────────
//
// Strategy: Use SFSpeechRecognizer in a continuous recognition loop.
// When "karen" or "hey karen" appears in the transcription, fire the wake callback.
// All audio stays in memory — never written to disk.
// Falls back gracefully if speech recognition is unavailable.

final class WakeWordDetector: NSObject {
    var onWake: (() -> Void)?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isRunning = false
    private var shouldRun = false
    private var isStarting = false
    private var lastWake = Date.distantPast
    private let cooldown: TimeInterval = 3.0

    // Regex: matches "karen" or "hey karen" (case-insensitive)
    private let wakePattern = try! NSRegularExpression(
        pattern: #"(\bkaren\b|hey\s+karen)"#,
        options: .caseInsensitive
    )

    init(onWake: (() -> Void)? = nil) {
        self.onWake = onWake
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
    }

    func start() {
        shouldRun = true
        guard !isRunning, !isStarting else { return }
        isStarting = true
        let begin: (SFSpeechRecognizerAuthorizationStatus) -> Void = { [weak self] status in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isStarting = false
                guard self.shouldRun, status == .authorized else { return }
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
        guard shouldRun, !isRunning else { return }
        do {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true
            self.request = req
            isRunning = true

            let inputNode = audioEngine.inputNode
            let fmt = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
                req.append(buf)
            }
            audioEngine.prepare()
            try audioEngine.start()

            task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                if let r = result {
                    let txt = r.bestTranscription.formattedString
                    let range = NSRange(txt.startIndex..., in: txt)
                    if self.wakePattern.firstMatch(in: txt, range: range) != nil {
                        let now = Date()
                        if now.timeIntervalSince(self.lastWake) > self.cooldown {
                            self.lastWake = now
                            DispatchQueue.main.async { self.onWake?() }
                        }
                    }
                    // Restart recognition after long silence to keep it fresh
                    if r.isFinal { self.restart() }
                }
                if err != nil { self.restart() }
            }
        } catch {
            print("[WakeWordDetector] Failed to start: \(error)")
            isRunning = false
        }
    }

    private func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.shouldRun else { return }
            self.doStart()
        }
    }

    func stop() {
        shouldRun = false
        isStarting = false
        guard isRunning else { return }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}
