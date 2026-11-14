import Foundation
import Speech
import AVFoundation

// ─── Wake Word Detector ───────────────────────────────────────────────────────
//
// Strategy: Use SFSpeechRecognizer in a continuous recognition loop.
// When "karen" or common phonetic misrecognitions appear in the transcription,
// fire the wake callback with any trailing query text spoken in the same breath.
// All audio stays in memory — never written to disk.
// Falls back gracefully if speech recognition is unavailable.

final class WakeWordDetector: NSObject, SFSpeechRecognizerDelegate {
    var onWake: ((String?) -> Void)?
    var onInterrupt: ((String) -> Void)?
    var isBargeInMode: Bool = false {
        didSet {
            if isBargeInMode {
                bargeInStartTime = Date()
            }
        }
    }
    var currentSpokenText: String = ""
    private var bargeInStartTime: Date = .distantPast
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isRunning = false
    private var shouldRun = false
    private var isStarting = false
    private var lastWake = Date.distantPast
    private let cooldown: TimeInterval = 1.5

    // Regex: matches "karen" or common phonetic misrecognitions with optional prefixes (English & Tamil)
    let wakePattern = try! NSRegularExpression(
        pattern: #"(?:\b|^)(?:hey|hi|hello|ok|okay|yo|vanakkam|வணக்கம்|ஹே)?[\s,.]*(?:karen|caring|carin|karin|caren|carren|karren|keren|karon|caron|karyn|corinne|curran|karan|kiran|kareem|cairn|care[\s-]in|car[\s-]in|care[\s-]and|கரேன்)(?:\b|$)"#,
        options: .caseInsensitive
    )

    // Regex: matches wake phrase with explicit prefix: "hey karen", "hi karen", "ok karen", "வணக்கம் கரேன்", etc.
    let wakeWithPrefixPattern = try! NSRegularExpression(
        pattern: #"(?:\b|^)(?:hey|hi|hello|ok|okay|yo|vanakkam|வணக்கம்|ஹே)[\s,.]+(?:karen|caring|carin|karin|caren|carren|karren|keren|karon|caron|karyn|corinne|curran|karan|kiran|kareem|cairn|care[\s-]in|car[\s-]in|care[\s-]and|கரேன்)(?:\b|$)"#,
        options: .caseInsensitive
    )

    // Regex: matches explicit interruption/stop commands (English & Tamil)
    let stopPattern = try! NSRegularExpression(
        pattern: #"(?:\b|^)(?:stop|stop\s+speaking|shut\s+up|be\s+quiet|pause|cancel|hold\s+on|hold\s+it|போதும்|நில்|நிறுத்து|பேசாதே)(?:\b|$)"#,
        options: .caseInsensitive
    )

    // Legacy alias for compatibility with existing tests
    var interruptPattern: NSRegularExpression { stopPattern }

    init(onWake: (() -> Void)? = nil) {
        if let onWake = onWake {
            self.onWake = { _ in onWake() }
        }
        let indianLocale = Locale(identifier: "en-IN")
        if SFSpeechRecognizer.supportedLocales().contains(indianLocale) {
            self.recognizer = SFSpeechRecognizer(locale: indianLocale)
        } else {
            self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        super.init()
        self.recognizer?.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }

    convenience init(onWakeWithTranscript: ((String?) -> Void)?) {
        self.init()
        self.onWake = onWakeWithTranscript
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }

    @objc private func handleAudioEngineConfigurationChange(notification: Notification) {
        print("[WakeWordDetector] Audio engine configuration changed (route or device update)")
        if isRunning {
            restart()
        } else {
            audioEngine.reset()
        }
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        print("[WakeWordDetector] Speech recognizer availability changed: \(available)")
        if available && shouldRun && !isRunning {
            restart()
        }
    }

    func start() {
        shouldRun = true
        guard !isRunning, !isStarting else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            print("[WakeWordDetector] NSSpeechRecognitionUsageDescription not present; skipping live capture.")
            return
        }
        isStarting = true
        let begin: (SFSpeechRecognizerAuthorizationStatus) -> Void = { [weak self] status in
            guard let self else { return }
            let execute = {
                self.isStarting = false
                guard self.shouldRun, status == .authorized else { return }
                self.doStart()
            }
            if Thread.isMainThread {
                execute()
            } else {
                DispatchQueue.main.async(execute: execute)
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
            if recognizer?.supportsOnDeviceRecognition == true {
                req.requiresOnDeviceRecognition = true
            } else {
                req.requiresOnDeviceRecognition = false
            }
            req.contextualStrings = [
                "Karen",
                "Hey Karen",
                "Hi Karen",
                "Hello Karen",
                "OK Karen",
                "Okay Karen"
            ]
            if #available(macOS 13.0, *) {
                req.addsPunctuation = true
            }
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
            do {
                try audioEngine.start()
            } catch {
                print("[WakeWordDetector] First start failed: \(error), resetting engine and retrying...")
                audioEngine.reset()
                Thread.sleep(forTimeInterval: 0.08)
                try audioEngine.start()
            }

            task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                if let r = result {
                    let txt = r.bestTranscription.formattedString
                    let range = NSRange(txt.startIndex..., in: txt)

                    if self.isBargeInMode {
                        // Allow brief initial audio route switch (0.15s) before evaluating barge-in
                        if Date().timeIntervalSince(self.bargeInStartTime) < 0.15 {
                            return
                        }

                        let shouldInterrupt = self.evaluateBargeIn(recognizedText: txt)
                        print("[WakeWordDetector:Diag] Barge-in evaluation: txt='\(txt)', shouldInterrupt=\(shouldInterrupt)")

                        if shouldInterrupt {
                            print("[WakeWordDetector:Diag] Barge-in threshold passed! Triggering onInterrupt with '\(txt)'")
                            self.isBargeInMode = false
                            DispatchQueue.main.async {
                                self.onInterrupt?(txt)
                            }
                        }
                    } else {
                        // Standard wake-word listening
                        if let match = self.wakePattern.firstMatch(in: txt, range: range) {
                            let now = Date()
                            if now.timeIntervalSince(self.lastWake) > self.cooldown {
                                self.lastWake = now
                                let trailingQuery = self.extractTrailingQuery(from: txt, matchRange: match.range)
                                print("[WakeWordDetector:Diag] Wake word matched in '\(txt)'! Trailing query: '\(trailingQuery ?? "<none>")'")
                                DispatchQueue.main.async { self.onWake?(trailingQuery) }
                            }
                        }
                    }
                    // Restart recognition after long silence to keep it fresh
                    if r.isFinal {
                        print("[WakeWordDetector:Diag] Recognition task isFinal; restarting loop...")
                        self.restart()
                    }
                }
                if let err = err {
                    let nsErr = err as NSError
                    let isCancelled = nsErr.code == 216 || nsErr.code == 3072 ||
                        (nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 216) ||
                        nsErr.domain == "kLSRErrorDomain"
                    if isCancelled || !self.shouldRun {
                        print("[WakeWordDetector:Diag] Recognition task cancelled cleanly.")
                        return
                    }
                    print("[WakeWordDetector:Diag] Recognition task ended with error: \(err.localizedDescription); restarting loop...")
                    self.restart()
                }
            }
        } catch {
            print("[WakeWordDetector] Failed to start: \(error)")
            isRunning = false
            if shouldRun {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.shouldRun, !self.isRunning else { return }
                    self.doStart()
                }
            }
        }
    }

    func extractTrailingQuery(from txt: String, matchRange: NSRange) -> String? {
        guard let stringRange = Range(matchRange, in: txt) else { return nil }
        let trailing = txt[stringRange.upperBound...]
        let trimmed = trailing.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!:;"))
        return trimmed.isEmpty ? nil : trimmed
    }

    func evaluateBargeIn(recognizedText txt: String) -> Bool {
        let range = NSRange(txt.startIndex..., in: txt)
        let normalizedTxt = txt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenTextLower = self.currentSpokenText.lowercased()

        // 1. User explicitly called Karen with a prefix: "Hey Karen", "Hi Karen", "OK Karen", "வணக்கம் கரேன்", etc.
        // Karen never speaks a wake phrase with prefix in her own TTS readout.
        if self.wakeWithPrefixPattern.firstMatch(in: txt, range: range) != nil {
            return true
        }

        // 2. Interruption / stop commands: "stop", "shut up", "be quiet", "pause", "cancel", "போதும்", "நில்", etc.
        if let match = self.stopPattern.firstMatch(in: txt, range: range),
           let strRange = Range(match.range, in: txt) {
            let matchedCmd = String(txt[strRange]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !matchedCmd.isEmpty && !spokenTextLower.contains(matchedCmd) {
                return true
            }
            if matchedCmd == "stop" && (normalizedTxt == "stop" || normalizedTxt == "stop." || normalizedTxt.contains("karen stop") || normalizedTxt.contains("hey karen stop")) {
                return true
            }
        }

        // 3. User said bare wake word (e.g. "Karen" or "கரேன்")
        if self.wakePattern.firstMatch(in: txt, range: range) != nil {
            let karenPhrases = ["karen", "caring", "carin", "karin", "caren", "கரேன்"]
            let karenInTTS = karenPhrases.contains { spokenTextLower.contains($0) }
            if !karenInTTS {
                return true
            } else {
                let isEcho = !spokenTextLower.isEmpty && spokenTextLower.contains(normalizedTxt)
                if !isEcho {
                    return true
                }
            }
        }

        return false
    }

    private func stopSession() {
        isRunning = false
        isStarting = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    func stop() {
        shouldRun = false
        stopSession()
    }

    private func restart() {
        guard shouldRun else { return }
        stopSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.shouldRun, !self.isRunning else { return }
            self.doStart()
        }
    }
}
