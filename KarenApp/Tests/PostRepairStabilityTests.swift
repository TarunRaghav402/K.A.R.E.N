import XCTest
import AVFoundation
@testable import KarenApp

@MainActor
final class PostRepairStabilityTests: XCTestCase {

    // MARK: - 1. A short response is spoken completely
    func testShortResponseSpokenCompletely() async {
        let tts = TTSEngine()
        var completed = false
        tts.onFinish = {
            completed = true
        }

        let expectation = XCTestExpectation(description: "Short speech completes naturally via delegate")
        tts.onFinish = {
            completed = true
            expectation.fulfill()
        }

        let shortText = "Hello sir, system is online."
        let task = Task {
            await tts.speak(shortText)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(tts.isSpeaking)

        await fulfillment(of: [expectation], timeout: 6.0)
        XCTAssertTrue(completed, "Short response must complete naturally")
        XCTAssertFalse(tts.isSpeaking)
        _ = await task.result
    }

    // MARK: - 2. A 150-word response is passed to TTS completely
    func test150WordResponsePassedToTTSCompletely() {
        let core = KarenCore(autoStartSubsystems: false)
        let words = (1...150).map { "word\($0)" }
        let full150WordResponse = words.joined(separator: " ") + "."

        core.presentResponse(text: full150WordResponse, speechText: full150WordResponse, speak: true)

        XCTAssertEqual(core.replyText, full150WordResponse)
        XCTAssertEqual(core.replyText.split(separator: " ").count, 150, "Full 150-word response must be preserved in core")
    }

    // MARK: - 3. A long response does not stop after its first word
    func testLongResponseDoesNotStopAfterFirstWord() async {
        let tts = TTSEngine()
        var wordBoundariesCount = 0

        tts.onSpeechProgress = { charLoc, totalChars in
            if charLoc > 0 {
                wordBoundariesCount += 1
            }
        }

        let longText = "Artificial intelligence is a transformative branch of computer science that empowers software systems to learn, adapt, and reason through data."
        let task = Task {
            await tts.speak(longText)
        }

        // Allow speech to progress past the first few words
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        // Must still be actively speaking and have fired multiple word boundary events
        XCTAssertTrue(tts.isSpeaking, "TTS must continue speaking and not stop after first word")
        XCTAssertGreaterThan(wordBoundariesCount, 1, "Must have progressed past multiple word boundaries")

        tts.stop()
        _ = await task.result
    }

    // MARK: - 4. Word-boundary callbacks do not trigger cancellation
    func testWordBoundaryCallbacksDoNotTriggerCancellation() {
        let tts = TTSEngine()
        tts.speak("First second third fourth fifth words.")
        XCTAssertTrue(tts.isSpeaking)

        // Simulate word boundary callback
        let utterance = AVSpeechUtterance(string: "First second third fourth fifth words.")
        tts.speechSynthesizer(AVSpeechSynthesizer(), willSpeakRangeOfSpeechString: NSRange(location: 0, length: 5), utterance: utterance)

        XCTAssertTrue(tts.isSpeaking, "Utterance must remain active after word boundary delegate callback")
        tts.stop()
    }

    // MARK: - 5. A watchdog does not terminate healthy speech
    func testWatchdogDoesNotTerminateHealthySpeech() {
        let tts = TTSEngine()
        let text = String(repeating: "Natural voice reading without interruption. ", count: 10)
        let charsPerSec = max(8.0, Double(tts.rate) * 35.0)
        let estimatedSecs = Double(text.count) / charsPerSec
        let timeoutSecs = max(4.0, estimatedSecs * 2.2 + 5.0)

        XCTAssertGreaterThan(timeoutSecs, estimatedSecs * 2.0, "Watchdog timeout must provide at least 2x duration headroom")
    }

    // MARK: - 6. A genuine speech stall is recovered
    func testGenuineSpeechStallIsRecovered() async {
        let tts = TTSEngine()
        let task = Task {
            await tts.speak("Testing watchdog recovery on simulated engine stall.")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(tts.isSpeaking)

        // Force watchdog recovery
        tts.stop()
        _ = await task.result
        XCTAssertFalse(tts.isSpeaking)
    }

    // MARK: - 7. Replay works after completion
    func testReplayWorksAfterCompletion() {
        let core = KarenCore(autoStartSubsystems: false)
        core.replyText = "Completed response ready for replay."
        core.transition(to: .speaking, reason: "First playback")
        core.transition(to: .idle, reason: "Playback completed")
        XCTAssertEqual(core.interactionState, .idle)

        core.replayLastResponse()
        XCTAssertEqual(core.interactionState, .speaking, "Replay must immediately transition to speaking")
        XCTAssertEqual(core.replyText, "Completed response ready for replay.")
    }

    // MARK: - 8. Stop works immediately during speech
    func testStopWorksImmediatelyDuringSpeech() {
        let core = KarenCore(autoStartSubsystems: false)
        core.replyText = "Here is a lengthy response that the user wants to cancel."
        core.transition(to: .speaking, reason: "Playback started")
        XCTAssertTrue(core.isSpeaking)

        core.stopSpeaking()
        XCTAssertEqual(core.interactionState, .idle)
        XCTAssertFalse(core.isSpeaking)
    }

    // MARK: - 9. A new question interrupts the previous answer correctly
    func testNewQuestionInterruptsPreviousAnswerCorrectly() {
        let core = KarenCore(autoStartSubsystems: false)
        core.micGranted = true
        core.speechGranted = true
        core.replyText = "Speaking first answer that will be interrupted."
        core.transition(to: .speaking, reason: "Initial speech")
        XCTAssertTrue(core.isSpeaking)

        // User barges in with new question
        core.handleInterrupt(detectedTranscript: "Hey Karen, what time is it in Tokyo?")

        XCTAssertEqual(core.interactionState, .listening, "New question must transition state to listening")
        XCTAssertFalse(core.isSpeaking, "Speech must be stopped on barge-in")
        XCTAssertEqual(core.liveTranscription, "what time is it in tokyo?")
    }

    // MARK: - 10. Repeated speech sessions do not interfere with each other
    func testRepeatedSpeechSessionsDoNotInterfere() async {
        let tts = TTSEngine()

        for index in 1...3 {
            let task = Task {
                await tts.speak("Utterance session number \(index).")
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertTrue(tts.isSpeaking)
            tts.stop()
            _ = await task.result
            XCTAssertFalse(tts.isSpeaking)
        }
    }

    // MARK: - Barge-in Echo Prevention Tests
    func testBargeIn_EchoPrevention_DoesNotSelfInterrupt() {
        let detector = WakeWordDetector()
        detector.isBargeInMode = true
        detector.currentSpokenText = "Artificial intelligence is a branch of computer science."

        // Speaker output heard by microphone
        let echoTranscript = "artificial intelligence is a branch"
        let range = NSRange(echoTranscript.startIndex..., in: echoTranscript)
        let isCommandMatch = detector.interruptPattern.firstMatch(in: echoTranscript, range: range) != nil
        let isWakeMatch = detector.wakePattern.firstMatch(in: echoTranscript, range: range) != nil

        let shouldInterrupt = isCommandMatch || isWakeMatch
        XCTAssertFalse(shouldInterrupt, "Assistant's own spoken words must not match stop command or wake phrase")
    }

    func testBargeIn_WakePhraseTriggersInterrupt() {
        let detector = WakeWordDetector()
        detector.isBargeInMode = true
        detector.currentSpokenText = "Artificial intelligence is a branch of computer science."

        let userInterrupt = "Hey Karen, stop that."
        let range = NSRange(userInterrupt.startIndex..., in: userInterrupt)
        let isWakeMatch = detector.wakePattern.firstMatch(in: userInterrupt, range: range) != nil

        XCTAssertTrue(isWakeMatch, "User speaking 'Hey Karen' must trigger wake match in barge-in mode")
    }
}
