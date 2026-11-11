import XCTest
@testable import KarenApp

@MainActor
final class Phase3GestureCoordinationTests: XCTestCase {

    var core: KarenCore!

    override func setUp() async throws {
        core = KarenCore(autoStartSubsystems: false)
        // Provide simulated permission grants for testing
        core.micGranted = true
        core.speechGranted = true
        core.cameraGranted = true
    }

    override func tearDown() async throws {
        core.disableGestureMode()
        core = nil
    }

    // MARK: - 1. Authoritative Voice Interaction State

    func testAuthoritativeVoiceInteractionState() {
        // Initially idle
        core.orbState = .idle
        core.isListening = false
        core.isSpeaking = false
        core.isInterrupting = false
        core.showResponsePanel = false
        XCTAssertFalse(core.isVoiceInteractionActive, "Idle state without response panel should not be active voice interaction")

        // 1. Listening
        core.isListening = true
        XCTAssertTrue(core.isVoiceInteractionActive, "isListening should mark voice interaction active")
        core.isListening = false

        core.orbState = .listening
        XCTAssertTrue(core.isVoiceInteractionActive, "orbState .listening should mark voice interaction active")
        core.orbState = .idle

        // 2. Processing
        core.orbState = .processing
        XCTAssertTrue(core.isVoiceInteractionActive, "orbState .processing should mark voice interaction active")
        core.orbState = .idle

        // 3. Responding / Speaking
        core.orbState = .speaking
        XCTAssertTrue(core.isVoiceInteractionActive, "orbState .speaking should mark voice interaction active")
        core.orbState = .idle

        core.isSpeaking = true
        XCTAssertTrue(core.isVoiceInteractionActive, "isSpeaking should mark voice interaction active")
        core.isSpeaking = false

        // 4. Interrupting
        core.isInterrupting = true
        XCTAssertTrue(core.isVoiceInteractionActive, "isInterrupting should mark voice interaction active")
        core.isInterrupting = false

        // 5. Active Response Panel
        core.showResponsePanel = true
        XCTAssertTrue(core.isVoiceInteractionActive, "showResponsePanel should mark voice interaction active")
        core.showResponsePanel = false

        XCTAssertFalse(core.isVoiceInteractionActive)
    }

    // MARK: - 2. Coordination and Pipeline Preservation

    func testCameraPipelinePreservedAcrossPauseAndResume() {
        core.gestureMode = true
        let processor = GestureProcessor(core: core)
        core.gestureProcessor = processor
        core.cameraActive = true

        let initialProcessor = core.gestureProcessor
        XCTAssertNotNil(initialProcessor)
        XCTAssertFalse(core.isGesturePaused)

        // Enter listening -> Gestures should be paused
        core.isListening = true
        core.updateGestureCoordination()

        XCTAssertTrue(core.isGesturePaused, "Gesture should be paused during listening")
        XCTAssertTrue(processor.isPaused, "GestureProcessor.isPaused must be true")
        XCTAssertTrue(core.gestureProcessor === initialProcessor, "Camera pipeline / processor must not be destroyed on pause")

        // Finish listening and return to idle
        core.isListening = false
        core.updateGestureCoordination()

        XCTAssertFalse(core.isGesturePaused, "Gesture should resume after listening ends and idle")
        XCTAssertFalse(processor.isPaused, "GestureProcessor.isPaused must be false")
        XCTAssertTrue(core.gestureProcessor === initialProcessor, "Camera pipeline / processor must not be recreated on resume")
    }

    // MARK: - 3. Cannot Resume While TTS is Still Speaking

    func testCameraGesturesCannotResumeWhileTTSIsSpeaking() {
        core.gestureMode = true
        let processor = GestureProcessor(core: core)
        core.gestureProcessor = processor
        core.cameraActive = true

        // Simulate speaking state
        core.isSpeaking = true
        core.orbState = .speaking
        core.showResponsePanel = true
        core.updateGestureCoordination()

        XCTAssertTrue(core.isGesturePaused)

        // Dismiss the response panel while TTS is still speaking
        core.showResponsePanel = false
        core.resumeCameraGestures()

        // Must NOT resume because TTS is still speaking (isSpeaking == true)
        XCTAssertTrue(core.isGesturePaused, "Gestures must NOT resume while isSpeaking is true")

        // Stop speaking
        core.isSpeaking = false
        core.orbState = .idle
        core.updateGestureCoordination()

        // Now gestures should resume
        XCTAssertFalse(core.isGesturePaused, "Gestures should resume once TTS speaking is complete")
    }

    // MARK: - 4. Orb Manipulation Blocked During Voice Interaction

    func testOrbManipulationBlockedDuringVoiceInteraction() {
        core.resetOrb()
        let initialZoom = core.orbZoom
        let initialYaw = core.orbYaw
        let initialOffset = core.orbOffsetX

        // Active voice interaction
        core.isListening = true

        // Attempting to apply zoom, rotation, or translation should be blocked
        core.applyZoom(1.5)
        core.applyRotation(yaw: 1.0, pitch: 0.5)
        core.applyTranslation(dx: 0.5, dy: 0.5)

        XCTAssertEqual(core.orbZoom, initialZoom, "Zoom must not change during active voice interaction")
        XCTAssertEqual(core.orbYaw, initialYaw, "Rotation must not change during active voice interaction")
        XCTAssertEqual(core.orbOffsetX, initialOffset, "Translation must not change during active voice interaction")

        // End voice interaction
        core.isListening = false

        // Now manipulation should be accepted
        core.applyTranslation(dx: 0.2, dy: -0.2)
        XCTAssertNotEqual(core.orbOffsetX, initialOffset, "Translation should work when voice interaction is inactive")
    }

    // MARK: - 5. Prevent Multiple Camera Sessions

    func testPreventMultipleCameraSessions() {
        core.gestureMode = true
        core.cameraGranted = true

        // First start
        core.startCameraGestures()
        let firstProcessor = core.gestureProcessor

        // Attempt second start while already running/allocated
        core.startCameraGestures()
        let secondProcessor = core.gestureProcessor

        XCTAssertTrue(firstProcessor === secondProcessor, "Must not create a new GestureProcessor or camera session if one already exists")
    }

    // MARK: - 6. Camera Unavailable Error Handling

    func testCameraUnavailableErrorHandling() {
        core.gestureMode = true
        core.cameraActive = true
        core.gestureProcessor = GestureProcessor(core: core)

        core.handleCameraError("Camera device failed to start")

        XCTAssertEqual(core.cameraError, "Camera device failed to start")
        XCTAssertFalse(core.cameraActive, "cameraActive must be false on camera error")
        XCTAssertFalse(core.gestureMode, "gestureMode must be reset to false on camera error")
        XCTAssertNil(core.gestureProcessor, "gestureProcessor must be cleaned up on camera error")
        XCTAssertEqual(core.replyText, "Camera device failed to start")
    }

    // MARK: - 7. Repeated Voice Interaction and Pause/Resume Cycles

    func testRepeatedVoiceInteractionsAndPauseResumeCycles() {
        core.gestureMode = true
        let processor = GestureProcessor(core: core)
        core.gestureProcessor = processor
        core.cameraActive = true

        let originalProcessor = core.gestureProcessor

        // Run 5 full interaction cycles
        for cycle in 1...5 {
            // Step 1: Wake word / Listening
            core.isListening = true
            core.orbState = .listening
            core.updateGestureCoordination()
            XCTAssertTrue(core.isGesturePaused, "Cycle \(cycle): Must be paused while listening")

            // Step 2: Processing transcription
            core.isListening = false
            core.orbState = .processing
            core.showResponsePanel = true
            core.updateGestureCoordination()
            XCTAssertTrue(core.isGesturePaused, "Cycle \(cycle): Must be paused while processing")

            // Step 3: Responding & Speaking
            core.orbState = .speaking
            core.isSpeaking = true
            core.updateGestureCoordination()
            XCTAssertTrue(core.isGesturePaused, "Cycle \(cycle): Must be paused while speaking")

            // Step 4: Speech completes, but response panel still open
            core.isSpeaking = false
            core.orbState = .idle
            core.updateGestureCoordination()
            XCTAssertTrue(core.isGesturePaused, "Cycle \(cycle): Must remain paused while response panel is active")

            // Step 5: User dismisses response panel
            core.dismissResponsePanel()
            XCTAssertFalse(core.isGesturePaused, "Cycle \(cycle): Must resume when response panel is dismissed")
            XCTAssertFalse(processor.isPaused, "Cycle \(cycle): Processor must not be paused")

            // Verify pipeline was never torn down and rebuilt
            XCTAssertTrue(core.gestureProcessor === originalProcessor, "Cycle \(cycle): Camera pipeline must be preserved")
        }

        // Interruption cycle test
        core.orbState = .speaking
        core.isSpeaking = true
        core.updateGestureCoordination()
        XCTAssertTrue(core.isGesturePaused)

        // Interruption detected
        core.handleInterrupt()

        // handleInterrupt halts speech and switches to listening
        XCTAssertTrue(core.isListening)
        XCTAssertFalse(core.isSpeaking)
        XCTAssertTrue(core.isGesturePaused, "Gestures must remain paused during interruption transition to listening")

        // Stop listening and idle
        core.stopListening()
        XCTAssertFalse(core.isGesturePaused, "Gestures resume after interruption sequence settles")
    }
}
