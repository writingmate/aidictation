import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw ValidationFailure.assertion(message)
    }
}

private func source(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

/// The body of `func name(` up to the next declaration at the same indent.
private func functionBody(named name: String, in text: String) -> String? {
    guard let start = text.range(of: "func \(name)(") else { return nil }
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n    private func ")
        ?? rest.range(of: "\n    func ")
        ?? rest.range(of: "\n}\n")
    return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
}

@main
private enum CloudOutageFallbackValidator {
    static func main() throws {
        try validateFailureClassification()
        try validateFallbackRules()
        try validateCooldown()
        try validateWiring()
        print("macOS cloud outage fallback contracts passed")
    }

    private static func validateFailureClassification() throws {
        typealias Failure = AppleAudioHTTPRecovery.Failure

        for status in [500, 502, 503, 504, 408, 429] {
            try require(
                CloudOutageFallback.isCloudUnavailable(.transientRetriesExhausted(statusCode: status)),
                "HTTP \(status) after every retry must count as the cloud being unavailable."
            )
        }
        try require(
            CloudOutageFallback.isCloudUnavailable(.transientRetriesExhausted(statusCode: nil)),
            "Transport errors after every retry must count as the cloud being unavailable."
        )
        try require(
            CloudOutageFallback.isCloudUnavailable(.transportUnavailable),
            "A connection that cannot be made must count as the cloud being unavailable."
        )

        try require(
            CloudOutageFallback.isCloudUnavailable(
                failure: nil,
                recognitionTimedOut: true,
                networkWasConnected: true
            ),
            "A cloud attempt that ran out its deadline while online must count as the cloud being unavailable."
        )
        try require(
            !CloudOutageFallback.isCloudUnavailable(
                failure: nil,
                recognitionTimedOut: true,
                networkWasConnected: false
            ),
            "A timeout that started offline was spent on the offline model, not the cloud."
        )
        try require(
            !CloudOutageFallback.isCloudUnavailable(
                failure: nil,
                recognitionTimedOut: false,
                networkWasConnected: true
            ),
            "An error that is neither an upload failure nor a timeout must not fall back."
        )
        try require(
            !CloudOutageFallback.isCloudUnavailable(
                failure: .permanentHTTP(statusCode: 403),
                recognitionTimedOut: false,
                networkWasConnected: true
            ),
            "A classified rejection decides on its own."
        )

        let rejections: [Failure] = [
            .permanentHTTP(statusCode: 401),
            .permanentHTTP(statusCode: 403),
            .permanentHTTP(statusCode: 404),
            .permanentHTTP(statusCode: 400),
            .permanentHTTP(statusCode: 422),
            .payloadTooLarge,
            .invalidTranscriptionResponse,
            .splitLimitReached,
        ]
        for failure in rejections {
            try require(
                !CloudOutageFallback.isCloudUnavailable(failure),
                "\(failure) describes the recording or the account; the offline model must not hide it."
            )
        }
    }

    private static func validateFallbackRules() throws {
        func decide(
            isAutoMode: Bool = true,
            cloudUnavailable: Bool = true,
            runtimeSupported: Bool = true,
            modelDownloaded: Bool = true,
            recognitionTextSaved: Bool = false,
            usesSpeakerLabels: Bool = false
        ) -> Bool {
            CloudOutageFallback.shouldTranscribeOffline(
                isAutoMode: isAutoMode,
                cloudUnavailable: cloudUnavailable,
                runtimeSupported: runtimeSupported,
                modelDownloaded: modelDownloaded,
                recognitionTextSaved: recognitionTextSaved,
                usesSpeakerLabels: usesSpeakerLabels
            )
        }

        try require(decide(), "Auto mode with the model on disk must fall back when the cloud is unavailable.")
        try require(!decide(isAutoMode: false), "Online mode asked for the cloud and must not fall back.")
        try require(!decide(cloudUnavailable: false), "A rejection from the cloud must not fall back.")
        try require(!decide(runtimeSupported: false), "A Mac that cannot run the offline model must not fall back.")
        try require(
            !decide(modelDownloaded: false),
            "A fallback must never start a model download."
        )
        try require(
            !decide(recognitionTextSaved: true),
            "Once cloud text is saved, an independent offline transcript cannot replace it."
        )
        try require(!decide(usesSpeakerLabels: true), "Speaker labels already run offline.")
    }

    private static func validateCooldown() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var cooldown = CloudOutageCooldown()
        try require(!cooldown.prefersOffline(at: start), "With no outage, recordings try the cloud.")

        cooldown.recordOutage(at: start)
        try require(cooldown.prefersOffline(at: start.addingTimeInterval(59)), "The first cooldown lasts one minute.")
        try require(
            !cooldown.prefersOffline(at: start.addingTimeInterval(60)),
            "After the first cooldown the next recording must try the cloud again."
        )

        let second = start.addingTimeInterval(61)
        cooldown.recordOutage(at: second)
        try require(
            cooldown.prefersOffline(at: second.addingTimeInterval(119))
                && !cooldown.prefersOffline(at: second.addingTimeInterval(120)),
            "A second outage in a row doubles the cooldown to two minutes."
        )

        var latest = second
        for _ in 0..<20 {
            latest = latest.addingTimeInterval(1_000)
            cooldown.recordOutage(at: latest)
        }
        try require(
            cooldown.prefersOffline(at: latest.addingTimeInterval(599))
                && !cooldown.prefersOffline(at: latest.addingTimeInterval(600)),
            "The cooldown never exceeds ten minutes."
        )

        cooldown.recordCloudSuccess()
        try require(!cooldown.prefersOffline(at: latest), "A cloud success ends the cooldown at once.")
        cooldown.recordOutage(at: latest)
        try require(
            !cooldown.prefersOffline(at: latest.addingTimeInterval(60)),
            "A cloud success resets the cooldown to one minute."
        )
    }

    /// `AppState` cannot be built outside the app, so these checks cover the
    /// wiring the compiled types cannot.
    private static func validateWiring() throws {
        let appState = try source("Whishpermate/Whispermate/Services/AppState.swift")

        guard let attempt = functionBody(named: "executeTranscriptionAttempt", in: appState) else {
            throw ValidationFailure.assertion("executeTranscriptionAttempt was not found in AppState.")
        }
        try require(
            attempt.contains("CloudOutageFallback.isCloudUnavailable(\n")
                && attempt.contains("recognitionTimedOut: Self.isRecognitionTimeout(error)")
                && attempt.contains("networkWasConnected: snapshot.networkWasConnected"),
            "The fallback must decide from the classified cloud failure or a cloud timeout."
        )
        try require(
            attempt.contains("cloudOutageCooldown.recordOutage(at:"),
            "A fallback must start the outage cooldown."
        )
        try require(
            attempt.contains("cloudOutageCooldown.recordCloudSuccess()"),
            "A cloud success must end the outage cooldown."
        )
        try require(
            attempt.contains("cloudOutageCooldown.prefersOffline(at:"),
            "Recordings during the cooldown must go straight to the offline model."
        )
        try require(
            attempt.contains("cloudError: error"),
            "When the fallback cannot start, the user must see the original cloud error."
        )

        guard let decision = functionBody(named: "canTranscribeOffline", in: appState) else {
            throw ValidationFailure.assertion("canTranscribeOffline was not found in AppState.")
        }
        try require(
            decision.contains("modelDownloaded: ParakeetTranscriptionService.shared.isModelDownloaded"),
            "The fallback must check that the offline model is already on disk."
        )
        try require(
            decision.contains("snapshot.mode == .auto"),
            "Only Auto mode falls back to the offline model."
        )

        guard let offline = functionBody(named: "transcribeOfflineAfterCloudOutage", in: appState) else {
            throw ValidationFailure.assertion("transcribeOfflineAfterCloudOutage was not found in AppState.")
        }
        try require(
            !offline.contains("initialize()"),
            "The offline fallback must not call initialize(), which can start a model download."
        )
        try require(
            offline.contains("recognitionTimeoutSeconds(for:"),
            "The offline fallback needs its own recognition deadline."
        )
        guard let extend = offline.range(of: "session.extendRecognition("),
              let transcribe = offline.range(of: "ParakeetTranscriptionService.shared.transcribe(")
        else {
            throw ValidationFailure.assertion(
                "The offline fallback must extend the stored attempt's deadline and run the offline model."
            )
        }
        try require(
            extend.lowerBound < transcribe.lowerBound,
            "The stored attempt's deadline must be extended before the offline model runs."
        )
    }
}
