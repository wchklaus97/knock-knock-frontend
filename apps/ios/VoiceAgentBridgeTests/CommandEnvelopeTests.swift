import XCTest
@testable import VoiceAgentBridge

final class CommandEnvelopeTests: XCTestCase {
    func testStrictV1EnvelopeDecodes() throws {
        let envelope = try CommandEnvelope.decodeStrict(from: Data(
            """
            {
              "version": 1,
              "id": "9a7947a3-80b7-47be-9510-fd9fb6f13058",
              "issued_at": "2026-08-09T10:11:12.123Z",
              "command": {
                "name": "session.report_event",
                "arguments": {
                  "summary": "Ready",
                  "forcePush": true,
                  "actions": ["ack"]
                }
              }
            }
            """.utf8
        ))

        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.command.name, "session.report_event")
        XCTAssertEqual(envelope.command.arguments["forcePush"], .bool(true))
    }

    func testUnknownEnvelopeAndCommandKeysAreRejected() {
        let unknownEnvelope = validJSON.replacingOccurrences(
            of: #""version": 1,"#,
            with: #""version": 1, "debug": true,"#
        )
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(unknownEnvelope.utf8)))

        let unknownCommand = validJSON.replacingOccurrences(
            of: #""arguments": {}"#,
            with: #""arguments": {}, "execute": true"#
        )
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(unknownCommand.utf8)))
    }

    func testUnsupportedVersionAndInvalidNamesAreRejected() {
        let wrongVersion = validJSON.replacingOccurrences(of: #""version": 1"#, with: #""version": 2"#)
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(wrongVersion.utf8)))

        let unsafeName = validJSON.replacingOccurrences(of: #""voice.cancel""#, with: #""../../shell""#)
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(unsafeName.utf8)))
    }

    func testMissingRequiredFieldAndOversizedInputAreRejected() {
        let missingID = validJSON.replacingOccurrences(
            of: #""id": "9a7947a3-80b7-47be-9510-fd9fb6f13058","#,
            with: ""
        )
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(missingID.utf8)))

        let oversized = Data(repeating: 0x20, count: CommandEnvelope.maximumEncodedSize + 1)
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: oversized)) { error in
            XCTAssertEqual(error as? CommandEnvelopeError, .encodedSizeOutOfRange)
        }
    }

    private var validJSON: String {
        """
        {
          "version": 1,
          "id": "9a7947a3-80b7-47be-9510-fd9fb6f13058",
          "issued_at": "2026-08-09T10:11:12Z",
          "command": {"name": "voice.cancel", "arguments": {}}
        }
        """
    }
}
