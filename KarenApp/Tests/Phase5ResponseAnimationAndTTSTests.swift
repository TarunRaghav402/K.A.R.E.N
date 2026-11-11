import XCTest
@testable import KarenApp

@MainActor
final class Phase5ResponseAnimationAndTTSTests: XCTestCase {

    var core: KarenCore!

    override func setUp() async throws {
        core = KarenCore(autoStartSubsystems: false)
        core.micGranted = true
        core.speechGranted = true
    }

    override func tearDown() async throws {
        core.stopSpeaking()
        core.dismissResponsePanel()
        core = nil
    }

    // MARK: - 1. Short Answer Progressive Synchronisation

    func testShortAnswerProgressiveSync() {
        let answer = "All systems operational, sir."
        core.lastUserQuery = "Status check"
        core.replyText = answer
        core.responseTextRevealedCount = 0
        core.isSpeaking = true
        core.orbState = .speaking
        core.showResponsePanel = true

        XCTAssertEqual(core.replyText, answer)
        XCTAssertEqual(core.responseTextRevealedCount, 0)

        // Simulate TTS progress through delegate
        core.ttsEngine?.onSpeechProgress?(11, answer.count) // "All systems"
        XCTAssertEqual(core.responseTextRevealedCount, 11)

        core.ttsEngine?.onSpeechProgress?(23, answer.count) // "All systems operational"
        XCTAssertEqual(core.responseTextRevealedCount, 23)

        // Complete speech
        core.ttsEngine?.onSpeechProgress?(answer.count, answer.count)
        core.isSpeaking = false
        core.orbState = .idle
        XCTAssertEqual(core.responseTextRevealedCount, answer.count)
    }

    // MARK: - 2. Long Answer Formatting and Paragraph Preservation

    func testLongAnswerFormattingAndParagraphPreservation() {
        let longAnswer = """
        Here is your requested briefing, sir:

        • Neural orb rendering pipeline: Metal shader with Canvas procedural fallback.
        • Vision gesture pipeline: 2-hand and 1-hand tracking via Apple Vision.
        • Natural voice interaction: Low-latency speech recognition and TTS.

        All subsystems are running optimally.
        """
        core.lastUserQuery = "Give me a full briefing"
        core.replyText = longAnswer
        core.responseTextRevealedCount = 0
        core.showResponsePanel = true

        // Verify paragraphs, newlines, and bullets are preserved in full text
        XCTAssertTrue(core.replyText.contains("\n\n• Neural orb"))
        XCTAssertTrue(core.replyText.contains("\n\nAll subsystems"))

        // Simulate progressive reveal across multiple paragraphs
        let halfLength = longAnswer.count / 2
        core.ttsEngine?.onSpeechProgress?(halfLength, longAnswer.count)
        XCTAssertEqual(core.responseTextRevealedCount, halfLength)

        // End of speech
        core.ttsEngine?.onSpeechProgress?(longAnswer.count, longAnswer.count)
        XCTAssertEqual(core.responseTextRevealedCount, longAnswer.count)
    }

    // MARK: - 3. Stop Speaking Immediately Halts TTS & Displays Complete Text

    func testStopSpeakingImmediatelyHaltsTTSAndDisplaysCompleteText() {
        let answer = "This is a detailed answer that the user decides to stop listening to halfway through."
        core.replyText = answer
        core.responseTextRevealedCount = 20
        core.isSpeaking = true
        core.orbState = .speaking
        core.showResponsePanel = true

        // User clicks "Stop Speaking"
        core.stopSpeaking()

        XCTAssertFalse(core.isSpeaking, "isSpeaking must be false after stopSpeaking")
        XCTAssertFalse(core.ttsEngine?.isSpeaking ?? false, "TTSEngine must not be speaking")
        XCTAssertEqual(core.orbState, .idle, "Orb state must return to idle")
        XCTAssertTrue(core.showResponsePanel, "Response panel must remain visible after stopping speech")
        XCTAssertEqual(core.responseTextRevealedCount, answer.count, "Full text must be displayed when speech is stopped")
    }

    // MARK: - 4. Replay Current Answer Without Re-submitting Query

    func testReplayCurrentAnswer() {
        let answer = "Replaying this answer for you, sir."
        core.replyText = answer
        core.responseTextRevealedCount = answer.count
        core.isSpeaking = false
        core.orbState = .idle
        core.showResponsePanel = true

        core.replayLastResponse()

        XCTAssertTrue(core.isSpeaking, "Replay should start speaking")
        XCTAssertEqual(core.orbState, .speaking, "Orb state should be speaking during replay")
        XCTAssertEqual(core.responseTextRevealedCount, 0, "Revealed count must reset to 0 at the start of replay")
        XCTAssertEqual(core.replyText, answer, "Answer text must remain the same without re-querying")

        // Progress advances
        core.ttsEngine?.onSpeechProgress?(10, answer.count)
        XCTAssertEqual(core.responseTextRevealedCount, 10)

        core.stopSpeaking()
        XCTAssertEqual(core.responseTextRevealedCount, answer.count)
    }

    // MARK: - 5. Ask Follow-up Activates Listening & Preserves Context

    func testAskFollowUpActivatesListeningAndPreservesContext() {
        let answer = "The current weather in San Francisco is 65 degrees and sunny."
        core.lastUserQuery = "What is the weather?"
        core.replyText = answer
        core.showResponsePanel = true
        core.isSpeaking = true
        core.orbState = .speaking

        core.askFollowUp()

        XCTAssertFalse(core.isSpeaking, "Speech must stop when asking a follow-up")
        XCTAssertTrue(core.isListening, "isListening must be true when asking follow-up")
        XCTAssertEqual(core.orbState, .listening, "Orb state must be .listening")
        XCTAssertTrue(core.showResponsePanel, "Response panel must remain visible to preserve visual context")
        XCTAssertEqual(core.lastUserQuery, "What is the weather?", "Original query context must be preserved")
        XCTAssertEqual(core.replyText, answer, "Previous answer must remain visible while listening for follow-up")
    }

    // MARK: - 6. Dismiss Response Panel

    func testDismissResponsePanel() {
        core.lastUserQuery = "Test question"
        core.replyText = "Test answer"
        core.showResponsePanel = true
        core.orbOffsetY = 0.48
        core.isSpeaking = true
        core.orbState = .speaking

        core.dismissResponsePanel()

        XCTAssertFalse(core.showResponsePanel, "Response panel must be dismissed")
        XCTAssertFalse(core.isSpeaking, "Speech must stop on dismiss")
        XCTAssertEqual(core.orbState, .idle, "Orb state must return to idle")
        XCTAssertEqual(core.orbOffsetY, 0.0, "Orb offset must return to centre")
        XCTAssertEqual(core.replyText, "", "Reply text should be cleared on dismiss")
        XCTAssertEqual(core.responseTextRevealedCount, 0, "Revealed count must reset to 0")
    }

    // MARK: - 7. Interruption Clears Stale State

    func testInterruptionClearsStaleSpeechState() {
        core.lastUserQuery = "First question"
        core.replyText = "First answer being spoken..."
        core.isSpeaking = true
        core.orbState = .speaking
        core.showResponsePanel = true

        // Interruption detected
        core.handleInterrupt()

        XCTAssertFalse(core.isSpeaking, "Speech must be stopped on interruption")
        XCTAssertTrue(core.isListening, "Interruption transitions immediately to listening")
        XCTAssertEqual(core.orbState, .listening)
    }

    // MARK: - 8. No Overlapping TTS Sessions

    func testNoOverlappingTTSSessions() {
        let tts = core.ttsEngine!
        XCTAssertNotNil(tts)

        // Trigger two speaks in quick succession
        tts.speak("First utterance that should be superseded")
        XCTAssertTrue(tts.isSpeaking)

        tts.speak("Second utterance that takes priority")
        XCTAssertTrue(tts.isSpeaking)

        tts.stop()
        XCTAssertFalse(tts.isSpeaking)
    }

    // MARK: - 9. Voice Settings Preserved

    func testVoiceSettingsPreserved() {
        let tts = core.ttsEngine!
        let customRate: Float = 0.62
        let customPitch: Float = 1.15
        let customVoice = "com.apple.speech.synthesis.voice.samantha"

        tts.rate = customRate
        tts.pitch = customPitch
        tts.voiceId = customVoice

        XCTAssertEqual(tts.rate, customRate)
        XCTAssertEqual(tts.pitch, customPitch)
        XCTAssertEqual(tts.voiceId, customVoice)
    }
}

