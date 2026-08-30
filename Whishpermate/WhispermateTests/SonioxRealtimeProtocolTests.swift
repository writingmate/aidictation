import XCTest

final class SonioxRealtimeProtocolTests: XCTestCase {
    func testConfigurationUsesRawPCMAndCarriesLanguageAndVocabularyContext() throws {
        let data = try SonioxRealtimeProtocol.configurationData(
            temporaryAPIKey: "temporary-key",
            languages: ["en", "ru"],
            keywords: ["AIDictation", "Writingmate"],
            prompt: "Product dictation context"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["api_key"] as? String, "temporary-key")
        XCTAssertEqual(object["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(object["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(object["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(object["num_channels"] as? Int, 1)
        XCTAssertEqual(object["language_hints"] as? [String], ["en", "ru"])
        XCTAssertEqual(object["enable_language_identification"] as? Bool, true)
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        XCTAssertEqual(context["terms"] as? [String], ["AIDictation", "Writingmate"])
        XCTAssertEqual(context["text"] as? String, "Product dictation context")
    }

    func testIncrementalTokensPreserveTheFinalTailAndExcludeFinalizeMarker() throws {
        var state = SonioxRealtimeTranscriptState()

        let first = try state.consume(Self.payload(tokens: [
            ["text": "Hello", "is_final": true],
            ["text": " wor", "is_final": false],
        ]))
        XCTAssertEqual(first?.transcript, "Hello wor")
        XCTAssertEqual(first?.isFinalizationComplete, false)

        let second = try state.consume(Self.payload(tokens: [
            ["text": " ", "is_final": true],
            ["text": "world", "is_final": true],
            ["text": "!", "is_final": false],
        ]))
        XCTAssertEqual(second?.transcript, "Hello world!")
        XCTAssertEqual(second?.isFinalizationComplete, false)

        let final = try state.consume(Self.payload(tokens: [
            ["text": "!", "is_final": true],
            ["text": "<fin>", "is_final": true],
        ]))
        XCTAssertEqual(final?.transcript, "Hello world!")
        XCTAssertEqual(final?.isFinalizationComplete, true)
    }

    func testBilingualTokensStayInProviderOrder() throws {
        var state = SonioxRealtimeTranscriptState()
        let update = try state.consume(Self.payload(tokens: [
            ["text": "Hello", "is_final": true, "language": "en"],
            ["text": ", ", "is_final": true, "language": "en"],
            ["text": "привет", "is_final": true, "language": "ru"],
            ["text": "!", "is_final": true, "language": "ru"],
            ["text": "<fin>", "is_final": true],
        ]))

        XCTAssertEqual(update?.transcript, "Hello, привет!")
        XCTAssertEqual(update?.isFinalizationComplete, true)
    }

    func testErrorResponseIsRejectedInsteadOfReturningAPartialTranscript() throws {
        var state = SonioxRealtimeTranscriptState()
        _ = try state.consume(Self.payload(tokens: [
            ["text": "unsafe partial", "is_final": false],
        ]))

        XCTAssertThrowsError(try state.consume(Self.payload(
            tokens: [],
            extra: [
                "error_code": 503,
                "error_type": "service_unavailable",
                "error_message": "Try again",
            ]
        ))) { error in
            XCTAssertEqual(
                error as? SonioxRealtimeProtocolError,
                .upstream(type: "service_unavailable", message: "Try again")
            )
        }
    }

    private static func payload(
        tokens: [[String: Any]],
        extra: [String: Any] = [:]
    ) throws -> Data {
        var object = extra
        object["tokens"] = tokens
        return try JSONSerialization.data(withJSONObject: object)
    }
}
