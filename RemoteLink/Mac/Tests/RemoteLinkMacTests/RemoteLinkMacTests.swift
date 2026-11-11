import XCTest
@testable import RemoteLinkMac

final class RemoteLinkMacTests: XCTestCase {

    func testNotificationRequestRecordEncodingAndDecoding() throws {
        let json = """
        {
            "request_id": "test-123",
            "type": "approval",
            "title": "K.A.R.E.N. Request",
            "message": "K.A.R.E.N. is waiting for your decision.",
            "details": "Terminal execution prompt",
            "actions": ["APPROVE", "DENY"],
            "status": "SENT",
            "created_at": 1700000000.0,
            "sent_at": 1700000001.0,
            "delivered_at": null,
            "responded_at": null,
            "expires_at": 1700000120.0,
            "outcome": null,
            "reply_text": null,
            "responder_device_id": null
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let record = try decoder.decode(NotificationRequestRecord.self, from: json)

        XCTAssertEqual(record.requestId, "test-123")
        XCTAssertEqual(record.type, "approval")
        XCTAssertEqual(record.title, "K.A.R.E.N. Request")
        XCTAssertEqual(record.message, "K.A.R.E.N. is waiting for your decision.")
        XCTAssertEqual(record.status, .sent)
        XCTAssertEqual(record.actions, ["APPROVE", "DENY"])
        XCTAssertNil(record.outcome)
    }

    func testRespondedRecordWithOutcomeAndReply() throws {
        let json = """
        {
            "request_id": "req-456",
            "type": "question",
            "title": "K.A.R.E.N. Needs Your Response",
            "message": "Should I continue with this task?",
            "details": null,
            "actions": ["YES", "NO", "REPLY"],
            "status": "RESPONDED",
            "created_at": 1700000000.0,
            "sent_at": 1700000001.0,
            "delivered_at": 1700000002.0,
            "responded_at": 1700000005.0,
            "expires_at": 1700000120.0,
            "outcome": "REPLIED",
            "reply_text": "Proceed with caution",
            "responder_device_id": "samsung-galaxy-s24"
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(NotificationRequestRecord.self, from: json)

        XCTAssertEqual(record.status, .responded)
        XCTAssertEqual(record.outcome, .replied)
        XCTAssertEqual(record.replyText, "Proceed with caution")
        XCTAssertEqual(record.responderDeviceId, "samsung-galaxy-s24")
    }

    func testPairingSessionResponseDecoding() throws {
        let json = """
        {
            "session_id": "sess-abc",
            "pairing_code": "7K9P2X",
            "qr_payload": "{\\"karen_remote\\":true}",
            "mac_id": "mac-001",
            "mac_name": "Tarun's MacBook",
            "expires_at": 1700000300.0,
            "is_paired": true,
            "paired_device_id": "dev-xyz"
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(PairingSessionResponse.self, from: json)

        XCTAssertEqual(session.sessionId, "sess-abc")
        XCTAssertEqual(session.pairingCode, "7K9P2X")
        XCTAssertEqual(session.macName, "Tarun's MacBook")
        XCTAssertTrue(session.isPaired)
        XCTAssertEqual(session.pairedDeviceId, "dev-xyz")
    }
}

