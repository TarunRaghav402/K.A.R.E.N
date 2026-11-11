import XCTest
@testable import KarenApp

@MainActor
final class Phase6AuthoritativeInteractionStateMachineTests: XCTestCase {

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

    // MARK: - 1. Initial State Consistency

    func testInitialStateIsIdleAndConsistent() {
        XCTAssertEqual(core.interactionState, .idle)
        XCTAssertEqual(core.orbState, .idle)
        XCTAssertFalse(core.isListening)
        XCTAssertFalse(core.isSpeaking)
        XCTAssertFalse(core.isInterrupting)
        XCTAssertFalse(core.showResponsePanel)
        XCTAssertFalse(core.isVoiceInteractionActive)
        XCTAssertEqual(core.menuBarIcon, "sparkles")
    }

    // MARK: - 2. Valid State Transitions

    func testValidStateTransitions() {
        // IDLE -> LISTENING
        XCTAssertTrue(core.transition(to: .listening, reason: "Test: wake word or listen tap"))
        XCTAssertEqual(core.interactionState, .listening)
        XCTAssertEqual(core.orbState, .listening)
        XCTAssertTrue(core.isListening)
        XCTAssertTrue(core.isVoiceInteractionActive)

        // LISTENING -> PROCESSING
        XCTAssertTrue(core.transition(to: .processing, reason: "Test: user finished speaking"))
        XCTAssertEqual(core.interactionState, .processing)
        XCTAssertEqual(core.orbState, .processing)
        XCTAssertFalse(core.isListening)
        XCTAssertTrue(core.isVoiceInteractionActive)

        // PROCESSING -> RESPONDING
        XCTAssertTrue(core.transition(to: .responding, reason: "Test: Gemini reply arrived"))
        XCTAssertEqual(core.interactionState, .responding)
        XCTAssertEqual(core.orbState, .responding)
        XCTAssertTrue(core.isVoiceInteractionActive)

        // RESPONDING -> SPEAKING
        XCTAssertTrue(core.transition(to: .speaking, reason: "Test: TTS readout starts"))
        XCTAssertEqual(core.interactionState, .speaking)
        XCTAssertEqual(core.orbState, .speaking)
        XCTAssertTrue(core.isSpeaking)
        XCTAssertTrue(core.isVoiceInteractionActive)

        // SPEAKING -> IDLE
        XCTAssertTrue(core.transition(to: .idle, reason: "Test: Speech readout completed"))
        XCTAssertEqual(core.interactionState, .idle)
        XCTAssertEqual(core.orbState, .idle)
        XCTAssertFalse(core.isSpeaking)

        // IDLE -> PROCESSING (direct typed query)
        XCTAssertTrue(core.transition(to: .processing, reason: "Test: Typed message submitted"))
        XCTAssertEqual(core.interactionState, .processing)

        // PROCESSING -> ERROR
        XCTAssertTrue(core.transition(to: .error, reason: "Test: Network failure"))
        XCTAssertEqual(core.interactionState, .error)
        XCTAssertEqual(core.orbState, .error)

        // ERROR -> IDLE
        XCTAssertTrue(core.transition(to: .idle, reason: "Test: Error acknowledged"))
        XCTAssertEqual(core.interactionState, .idle)
    }

    // MARK: - 3. Invalid State Transitions Rejected

    func testInvalidStateTransitionsRejected() {
        // IDLE cannot jump directly to RESPONDING
        XCTAssertFalse(core.transition(to: .responding, reason: "Invalid jump"))
        XCTAssertEqual(core.interactionState, .idle, "State must remain unchanged upon rejected transition")

        // IDLE cannot jump directly to INTERRUPTING
        XCTAssertFalse(core.transition(to: .interrupting, reason: "Invalid jump"))
        XCTAssertEqual(core.interactionState, .idle)

        // Move to LISTENING
        core.transition(to: .listening)

        // LISTENING cannot jump directly to SPEAKING
        XCTAssertFalse(core.transition(to: .speaking, reason: "Invalid jump"))
        XCTAssertEqual(core.interactionState, .listening)

        // LISTENING cannot jump directly to RESPONDING
        XCTAssertFalse(core.transition(to: .responding, reason: "Invalid jump"))
        XCTAssertEqual(core.interactionState, .listening)

        // Move to PROCESSING
        core.transition(to: .processing)

        // PROCESSING cannot jump directly to SPEAKING
        XCTAssertFalse(core.transition(to: .speaking, reason: "Invalid jump"))
        XCTAssertEqual(core.interactionState, .processing)

        // Clean up to IDLE
        core.transition(to: .idle)
    }

    // MARK: - 4. Authoritative State Controls Camera Gestures

    func testAuthoritativeInteractionStateControlsGestures() {
        core.enableGestureMode()
        XCTAssertTrue(core.gestureMode)
        XCTAssertFalse(core.isGesturePaused, "Gestures start active when idle")

        // LISTENING pauses gestures
        core.transition(to: .listening)
        XCTAssertTrue(core.isGesturePaused)

        // PROCESSING keeps gestures paused
        core.transition(to: .processing)
        XCTAssertTrue(core.isGesturePaused)

        // RESPONDING keeps gestures paused
        core.transition(to: .responding)
        XCTAssertTrue(core.isGesturePaused)

        // SPEAKING keeps gestures paused
        core.transition(to: .speaking)
        XCTAssertTrue(core.isGesturePaused)

        // INTERRUPTING keeps gestures paused
        core.transition(to: .interrupting)
        XCTAssertTrue(core.isGesturePaused)

        // Return to LISTENING after interruption
        core.transition(to: .listening)
        XCTAssertTrue(core.isGesturePaused)

        // Once back in IDLE and response panel is dismissed, gestures resume
        core.showResponsePanel = false
        core.transition(to: .idle)
        core.updateGestureCoordination()
        XCTAssertFalse(core.isGesturePaused, "Gestures resume when back in IDLE with no panel open")
    }

    // MARK: - 5. Barge-in Interruption Full Workflow

    func testBargeInInterruptionWorkflow() {
        core.replyText = "This is a long sentence being spoken by the assistant."
        core.showResponsePanel = true
        core.transition(to: .responding)
        core.transition(to: .speaking)
        XCTAssertTrue(core.isSpeaking)
        XCTAssertEqual(core.interactionState, .speaking)

        // User speaks or clicks Interrupt
        core.handleInterrupt()

        // handleInterrupt immediately transitions to INTERRUPTING then to LISTENING
        XCTAssertFalse(core.isSpeaking, "Speech must halt immediately on interrupt")
        XCTAssertEqual(core.interactionState, .listening, "Must immediately be ready for user's voice")
        XCTAssertEqual(core.orbState, .listening)
        XCTAssertTrue(core.isListening)

        // User finishes speaking new query
        core.lastUserQuery = "What time is it now?"
        core.transition(to: .processing)
        XCTAssertEqual(core.interactionState, .processing)

        // New answer arrives
        core.presentResponse(text: "It is 5:50 PM.", speechText: "It is 5:50 PM.", speak: false)
        XCTAssertEqual(core.interactionState, .responding, "State transitions to .responding while staging the presentation")
        XCTAssertEqual(core.replyText, "It is 5:50 PM.")
    }

    // MARK: - 6. Follow-up Preserves Conversation Context

    func testFollowUpConversationContextPreservation() {
        let firstQuery = "What is quantum computing?"
        let firstReply = "Quantum computing harnesses the phenomena of quantum mechanics."
        core.lastUserQuery = firstQuery
        core.replyText = firstReply
        core.showResponsePanel = true
        core.orbTopProgress = 1.0

        // User asks a follow-up
        core.askFollowUp()

        XCTAssertEqual(core.interactionState, .listening)
        XCTAssertEqual(core.orbState, .listening)
        XCTAssertTrue(core.showResponsePanel, "Visual response panel must remain visible")
        XCTAssertEqual(core.lastUserQuery, firstQuery, "Prior query must remain preserved for visual context")
        XCTAssertEqual(core.replyText, firstReply, "Prior answer must remain visible while listening for follow-up")

        // User finishes follow-up speech
        core.transition(to: .processing)
        XCTAssertEqual(core.interactionState, .processing)
    }

    // MARK: - 7. Safe Stop & Stuck Listening Prevention

    func testSafeStopListeningPreventsStuckState() {
        core.transition(to: .listening)
        XCTAssertTrue(core.isListening)
        XCTAssertEqual(core.interactionState, .listening)

        // Safe stop
        core.stopListening()
        XCTAssertFalse(core.isListening)
        XCTAssertEqual(core.interactionState, .idle)
        XCTAssertEqual(core.orbState, .idle)
        XCTAssertFalse(core.isVoiceInteractionActive)
    }
}
