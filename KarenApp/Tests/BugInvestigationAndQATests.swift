import XCTest
@testable import KarenApp
import AVFoundation

@MainActor
final class BugInvestigationAndQATests: XCTestCase {

    var core: KarenCore!

    override func setUp() async throws {
        core = KarenCore(autoStartSubsystems: false)
        core.micGranted = true
        core.speechGranted = true
        core.cameraGranted = true
    }

    override func tearDown() async throws {
        core.stopSpeaking()
        core.dismissResponsePanel()
        core.disableGestureMode()
        core = nil
    }

    // MARK: - 1. TTS Lifecycle & Hang Fixes

    func testTTS_EmptyAndWhitespaceNeverHangs() async {
        let tts = TTSEngine()
        
        // Speaking empty string must complete immediately without deadlocking
        await tts.speak("")
        XCTAssertFalse(tts.isSpeaking)

        // Speaking whitespace-only string must also complete immediately
        await tts.speak("   \n\t  ")
        XCTAssertFalse(tts.isSpeaking)
    }

    func testTTS_StopImmediatelyHaltsAndResetsState() async {
        let tts = TTSEngine()
        
        let speakTask = Task {
            await tts.speak("This is a longer test sentence to verify immediate stopping of audio playback.")
        }
        
        // Small delay to allow initiation
        try? await Task.sleep(nanoseconds: 20_000_000)
        tts.stop()
        
        _ = await speakTask.result
        XCTAssertFalse(tts.isSpeaking)
    }

    // MARK: - 2. Barge-in & Interruption Intelligence

    func testBargeIn_ExplicitStopCommandHaltsSpeechToIdle() {
        core.transition(to: .speaking, reason: "Testing barge-in")
        XCTAssertTrue(core.isSpeaking)

        // User says "Karen stop"
        core.handleInterrupt(detectedTranscript: "karen stop")

        // Must transition to idle (NOT listening), silence speech
        XCTAssertEqual(core.interactionState, .idle)
        XCTAssertFalse(core.isSpeaking)
        XCTAssertFalse(core.isListening)
    }

    func testBargeIn_AlternativeStopPhrasesHaltToIdle() {
        for phrase in ["stop speaking", "shut up", "be quiet", "wait", "cancel", "pause", "hold on"] {
            core.transition(to: .speaking, reason: "Testing barge-in with \(phrase)")
            XCTAssertTrue(core.isSpeaking)

            core.handleInterrupt(detectedTranscript: phrase)

            XCTAssertEqual(core.interactionState, .idle, "Failed to halt to idle on phrase: \(phrase)")
            XCTAssertFalse(core.isSpeaking)
        }
    }

    func testBargeIn_QueryCommandTransitionsToListeningAndSetsLiveTranscript() {
        core.transition(to: .speaking, reason: "Testing barge-in with query")
        XCTAssertTrue(core.isSpeaking)

        // User interrupts with a new query
        core.handleInterrupt(detectedTranscript: "Hey Karen what is the current weather outside?")

        // Must transition through interrupting to listening and prime liveTranscription
        XCTAssertEqual(core.interactionState, .listening)
        XCTAssertTrue(core.isListening)
        XCTAssertFalse(core.isSpeaking)
        XCTAssertEqual(core.liveTranscription, "what is the current weather outside?")
    }

    // MARK: - 3. State Machine Transitions & Processing Safety

    func testStateMachine_ValidNewTransitions() {
        // Error -> Responding (displaying error cards)
        core.transition(to: .error, reason: "Simulate error")
        XCTAssertEqual(core.interactionState, .error)
        XCTAssertTrue(InteractionState.isValidTransition(from: .error, to: .responding))
        XCTAssertTrue(core.transition(to: .responding, reason: "Present error response"))
        XCTAssertEqual(core.interactionState, .responding)

        // Processing -> Interrupting (user barging in while processing)
        core.transition(to: .idle, reason: "Reset")
        core.transition(to: .listening, reason: "Start")
        core.transition(to: .processing, reason: "Processing transcript")
        XCTAssertEqual(core.interactionState, .processing)
        XCTAssertTrue(InteractionState.isValidTransition(from: .processing, to: .interrupting))
        XCTAssertTrue(core.transition(to: .interrupting, reason: "Barge in during processing"))
        XCTAssertEqual(core.interactionState, .interrupting)
    }

    // MARK: - 4. Response Animation & Dismissal Safety

    func testResponsePanel_DismissalInvalidatesPendingAsyncBlocks() async {
        // Trigger response presentation
        core.presentResponse(text: "Here is an answer.", speechText: "Here is an answer.", speak: false)
        XCTAssertEqual(core.interactionState, .responding)

        // Immediately dismiss panel
        core.dismissResponsePanel()
        XCTAssertEqual(core.interactionState, .idle)
        XCTAssertFalse(core.showResponsePanel)
        XCTAssertEqual(core.responsePhase, .dismissed)

        // Wait past the asyncAfter deadlines (0.26s + 0.08s)
        try? await Task.sleep(nanoseconds: 400_000_000)

        // The pending closures must NOT have reopened the panel or altered dismissed state
        XCTAssertFalse(core.showResponsePanel)
        XCTAssertEqual(core.responsePhase, .dismissed)
        XCTAssertEqual(core.interactionState, .idle)
    }

    // MARK: - 5. Repeated Interactions and Recovery

    func testRepeatedVoiceCycleReliability() {
        for cycle in 1...5 {
            XCTAssertTrue(core.transition(to: .listening, reason: "Cycle \(cycle) listen"))
            XCTAssertTrue(core.isListening)
            XCTAssertTrue(core.isVoiceInteractionActive)

            XCTAssertTrue(core.transition(to: .processing, reason: "Cycle \(cycle) process"))
            XCTAssertFalse(core.isListening)

            XCTAssertTrue(core.transition(to: .responding, reason: "Cycle \(cycle) respond"))
            XCTAssertTrue(core.transition(to: .speaking, reason: "Cycle \(cycle) speak"))
            XCTAssertTrue(core.isSpeaking)

            core.stopSpeaking()
            XCTAssertEqual(core.interactionState, .idle)
            XCTAssertFalse(core.isSpeaking)
        }
    }
}

