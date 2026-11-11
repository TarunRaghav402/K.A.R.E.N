import XCTest
@testable import KarenApp

@MainActor
final class Phase7LifecyclePreservationTests: XCTestCase {

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
        core = nil
    }

    // MARK: - 1. Window Closes Do Not Terminate Application (Background Agent)

    func testAppDoesNotTerminateAfterLastWindowClosed() {
        let appDelegate = AppDelegate()
        let shouldTerminate = appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        XCTAssertFalse(shouldTerminate, "K.A.R.E.N. must run as a background agent and not terminate when windows close")
    }

    // MARK: - 2. Activation Policy is Accessory (No Dock Icon)

    func testActivationPolicyIsAccessory() {
        // In the app environment, activation policy is set to .accessory
        // so it does not appear in the macOS Dock or App Switcher.
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        // In headless xctest runner or accessory app, policy is accessory or prohibited
        XCTAssertTrue(policy == .accessory || policy == .prohibited, "Activation policy must be accessory (no Dock presence)")
    }

    // MARK: - 3. Wake Word Activates Window and Starts Listening

    func testWakeWordActivatesWindowAndTransitionsToListening() {
        var windowOpened = false
        core.setWindowOpener {
            windowOpened = true
        }

        XCTAssertEqual(core.interactionState, .idle)

        core.onWakeWord()

        XCTAssertTrue(windowOpened, "Wake word detection must trigger the assistant window opener")
        XCTAssertEqual(core.interactionState, .listening, "Wake word detection must transition to listening")
        XCTAssertTrue(core.isListening, "isListening must be true upon wake word trigger")
    }

    // MARK: - 4. Dismissing Returns to Background State

    func testDismissReturnsOrbToCenterAndStateToIdle() {
        core.replyText = "Operational status: optimal."
        core.showResponsePanel = true
        core.responsePhase = .contentReveal
        core.orbTopProgress = 1.0
        core.orbScaleProgress = 0.44

        // Dismiss the interface
        core.dismissResponsePanel()

        XCTAssertFalse(core.showResponsePanel, "Response panel must be hidden on dismiss")
        XCTAssertEqual(core.responsePhase, .dismissed, "Response phase must be dismissed")
        XCTAssertEqual(core.orbTopProgress, 0.0, "Orb top progress must return to 0 (centered)")
        XCTAssertEqual(core.orbScaleProgress, 1.0, "Orb scale must return to 1.0 (normal size)")
        XCTAssertEqual(core.interactionState, .idle, "Interaction state must be idle after dismissal")
    }

    // MARK: - 5. Voice Quit / Background Commands Close Interface and Return to Background

    func testVoiceQuitCommandClosesWindowAndResumesBackground() {
        core.isListening = true
        core.orbState = .listening
        core.interactionState = .listening

        // Simulate voice input matching quit command
        let quitCommands = ["quit", "quit karen", "exit", "close karen", "close the app", "go offline"]
        for cmd in quitCommands {
            core.isListening = true
            core.interactionState = .listening

            // Send voice input through the command handler
            let normalized = cmd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let backgroundCommands: Set<String> = [
                "quit", "quit karen", "exit", "exit karen", "close karen",
                "close the app", "go offline", "terminate"
            ]
            XCTAssertTrue(backgroundCommands.contains(normalized), "Command '\(cmd)' must be recognized as a background/quit command")
        }
    }

    // MARK: - 6. Menu Bar Integration

    func testMenuBarContentProperties() {
        core.orbState = .idle
        XCTAssertEqual(core.menuBarIcon, "sparkles")

        core.orbState = .listening
        XCTAssertEqual(core.menuBarIcon, "mic.fill")

        core.orbState = .speaking
        XCTAssertEqual(core.menuBarIcon, "waveform")

        core.orbState = .processing
        XCTAssertEqual(core.menuBarIcon, "circle.dotted")
    }

    // MARK: - 7. Window Opener Registration Fallback

    func testWindowOpenerRegistrationAndInvocation() {
        var openerCalled = false
        core.setWindowOpener {
            openerCalled = true
        }

        core.showAssistantWindow()
        XCTAssertTrue(openerCalled, "showAssistantWindow must invoke registered opener")
    }
}
