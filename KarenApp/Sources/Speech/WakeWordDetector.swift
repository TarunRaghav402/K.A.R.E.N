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
    var onInterrupt: ((String) -> Void)?
    var isBargeInMode: Bool = false
    var currentSpokenText: String = ""
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isRunning = false
    private var shouldRun = false
    private var isStarting = false
    private var lastWake = Date.distantPast
    private let cooldown: TimeInterval = 2.0

    // Regex: matches "karen" or "hey karen" (case-insensitive)
    let wakePattern = try! NSRegularExpression(
        pattern: #"(\bkaren\b|hey\s+karen)"#,
        options: .caseInsensitive
    )

    // Regex for barge-in interruption phrases while speaking
    let interruptPattern = try! NSRegularExpression(
        pattern: #"(\bkaren\b|hey\s+karen|\bwait\b|\bstop\b|\bcancel\b|\bquiet\b|\bhold\s+on\b|\blisten\b|\bexcuse\s+me\b|\bshut\s+up\b|\bpause\b|\bstop\s+speaking\b)"#,
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
            req.requiresOnDeviceRecognition = false
            self.request = req
            isRunning = true

            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0)

            let hwFormat = inputNode.outputFormat(forBus: 0)
            let fmt: AVAudioFormat
            if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
                fmt = hwFormat
            } else if let std = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) {
                fmt = std
            } else {
                fmt = hwFormat
            }

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

                    if self.isBargeInMode {
                        // In barge-in mode, check for interruption commands or wake phrase
                        let isCommandMatch = self.interruptPattern.firstMatch(in: txt, range: range) != nil
                        let isWakeMatch = self.wakePattern.firstMatch(in: txt, range: range) != nil
                        let normalizedTxt = txt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

                        // Split into words, stripping punctuation
                        let punct = CharacterSet.punctuationCharacters
                        let txtWords = normalizedTxt.components(separatedBy: .whitespacesAndNewlines)
                            .map { $0.trimmingCharacters(in: punct) }
                            .filter { !$0.isEmpty }

                        let spokenWords = Set(
                            self.currentSpokenText.lowercased()
                                .components(separatedBy: .whitespacesAndNewlines)
                                .map { $0.trimmingCharacters(in: punct) }
                                .filter { !$0.isEmpty }
                        )

                        let novelWordsCount = txtWords.filter { !spokenWords.contains($0) }.count
                        let spokenTextLower = self.currentSpokenText.lowercased()
                        // Echo prevention: ignore recognition if all words are identical to Karen's current speech,
                        // or if the recognized phrase is a substring of Karen's current utterance.
                        let isEcho = (novelWordsCount == 0 && !spokenWords.isEmpty) ||
                                     (!spokenTextLower.isEmpty && spokenTextLower.contains(normalizedTxt))

                        // Barge-in requires either an explicit stop command or a wake phrase with a question:
                        // Arbitrary room sounds or speaker echoes that do not contain a command or wake word
                        // must NEVER halt active speech readout!
                        let shouldInterrupt = !isEcho && (isCommandMatch || isWakeMatch)

                        print("[WakeWordDetector:Diag] Barge-in evaluation: txt='\(txt)', isCmd=\(isCommandMatch), isWake=\(isWakeMatch), isEcho=\(isEcho), shouldInterrupt=\(shouldInterrupt)")

                        if shouldInterrupt {
                            let now = Date()
                            if now.timeIntervalSince(self.lastWake) > 1.0 {
                                self.lastWake = now
                                print("[WakeWordDetector:Diag] Barge-in threshold passed! Triggering onInterrupt with '\(txt)'")
                                DispatchQueue.main.async {
                                    self.onInterrupt?(txt)
                                }
                            }
                        }
                    } else {
                        // Standard wake-word listening
                        if self.wakePattern.firstMatch(in: txt, range: range) != nil {
                            let now = Date()
                            if now.timeIntervalSince(self.lastWake) > self.cooldown {
                                self.lastWake = now
                                DispatchQueue.main.async { self.onWake?() }
                            }
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
