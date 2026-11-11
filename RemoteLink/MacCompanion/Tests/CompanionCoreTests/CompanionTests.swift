import XCTest
@testable import CompanionCore

final class CompanionTests: XCTestCase {

    func testConfigStore() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configPath = tempDir.appendingPathComponent("test_config.json")

        let store = ConfigStore(customPath: configPath)
        var initial = store.load()
        XCTAssertEqual(initial.pollIntervalSeconds, 15.0)

        initial.macName = "Custom Test Mac"
        initial.pollIntervalSeconds = 30.0
        try store.save(initial)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.macName, "Custom Test Mac")
        XCTAssertEqual(reloaded.pollIntervalSeconds, 30.0)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResponseJournal() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let journalPath = tempDir.appendingPathComponent("test_journal.jsonl")

        let journal = ResponseJournal(customPath: journalPath)
        let entry1 = JournalEntry(
            requestId: "req_1",
            title: "Permission Test",
            outcome: .approved,
            replyText: nil,
            responderDeviceId: "device_abc"
        )
        let entry2 = JournalEntry(
            requestId: "req_2",
            title: "Question Test",
            outcome: .replied,
            replyText: "Looks good!",
            responderDeviceId: "device_abc"
        )

        journal.append(entry: entry1)
        journal.append(entry: entry2)

        // Allow async write to complete
        Thread.sleep(forTimeInterval: 0.1)

        let entries = journal.readRecent(limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].requestId, "req_2") // Most recent first
        XCTAssertEqual(entries[0].replyText, "Looks good!")
        XCTAssertEqual(entries[1].requestId, "req_1")
        XCTAssertEqual(entries[1].outcome, .approved)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLaunchAgentPlistGeneration() {
        let service = LaunchAgentService()
        let plist = service.generatePlist(binaryPath: "/Applications/KarenCompanion")

        XCTAssertTrue(plist.contains("<string>com.karen.remote.companion</string>"))
        XCTAssertTrue(plist.contains("<string>/Applications/KarenCompanion</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<key>KeepAlive</key>"))
    }

    func testModelCodable() throws {
        let json = """
        {
            "request_id": "req_123",
            "type": "ACTION_PROMPT",
            "title": "Camera Access",
            "message": "Allow camera?",
            "actions": ["APPROVE", "DENY"],
            "status": "STORED",
            "created_at": 1700000000.0,
            "expires_at": 1700000300.0,
            "idempotency_key": "key_xyz"
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(NotificationRequestRecord.self, from: json)
        XCTAssertEqual(record.requestId, "req_123")
        XCTAssertEqual(record.status, .stored)
        XCTAssertEqual(record.actions, ["APPROVE", "DENY"])
        XCTAssertEqual(record.idempotencyKey, "key_xyz")
    }
}

