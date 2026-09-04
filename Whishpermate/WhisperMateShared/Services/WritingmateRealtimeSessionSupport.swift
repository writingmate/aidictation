import Foundation

/// Shared Writingmate realtime session resolution used by macOS and iOS.
public enum WritingmateRealtimeSessionSupport {
    public static let defaultModel = OpenAIRealtimeTranscriptionClient.defaultTranscriptionModel
    public static let finishTimeout: TimeInterval = 6

    public static func isWebSocketURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "ws" || scheme == "wss"
    }

    public static func isWritingmateSessionEndpoint(_ endpoint: URL) -> Bool {
        let host = endpoint.host?.lowercased()
        return endpoint.scheme?.lowercased() == "https"
            && (host == "writingmate.ai" || host == "www.writingmate.ai")
            && endpoint.path == "/api/openai/v1/realtime/client_secrets"
    }

    public static func configuredOverrideEndpoint() -> URL? {
        guard let configured = SecretsLoader.customTranscriptionRealtimeEndpoint()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        else {
            return nil
        }
        return URL(string: configured)
    }

    public static func configuredOverrideModel() -> String? {
        guard let configured = SecretsLoader.customTranscriptionRealtimeModel()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        else {
            return nil
        }
        return configured
    }

    public static func sessionEndpoint(
        configuredEndpoint: String,
        overrideEndpoint: URL?
    ) -> URL? {
        if let overrideEndpoint, !isWebSocketURL(overrideEndpoint) {
            return overrideEndpoint
        }
        return WritingmateRealtimeClientSecretProvider.endpoint(from: configuredEndpoint)
    }

    public static func webSocketURL(
        configuredEndpoint: String,
        overrideEndpoint: URL?
    ) -> URL? {
        if let overrideEndpoint, isWebSocketURL(overrideEndpoint) {
            return overrideEndpoint
        }
        guard let endpoint = URL(string: configuredEndpoint),
              isWebSocketURL(endpoint)
        else {
            return nil
        }
        return endpoint
    }

    public static func resolvedModel(
        configuredModel: String,
        overrideModel: String?
    ) -> String {
        if let overrideModel {
            return overrideModel
        }

        let model = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              !model.contains("/"),
              model != TranscriptionProvider.custom.defaultModel
        else {
            return defaultModel
        }
        return model
    }

    /// Bearer token for minting a Writingmate realtime `client_secret`.
    /// Prefers a signed-in user access token; otherwise uses the bundled app
    /// API key already used for unsigned cloud transcription.
    public static func resolveClientSecretAPIKey(
        fallbackAPIKey: String? = nil
    ) async throws -> String {
        if let userToken = await userAccessTokenIfAvailable() {
            return userToken
        }

        if let fallback = usableClientSecretAPIKey(fallbackAPIKey) {
            return fallback
        }

        if let keychainKey = usableClientSecretAPIKey(
            KeychainHelper.get(key: TranscriptionProvider.custom.apiKeyName)
        ) {
            return keychainKey
        }

        if let bundledKey = usableClientSecretAPIKey(
            SecretsLoader.transcriptionKey(for: .custom)
        ) {
            return bundledKey
        }

        throw OpenAIRealtimeTranscriptionClientError.clientSecretRequestFailed(
            Self.missingClientSecretCredentialsMessage
        )
    }

    public static let missingClientSecretCredentialsMessage =
        "Cloud transcription credentials are unavailable"

    public static func usableClientSecretAPIKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "not-needed" else {
            return nil
        }
        return trimmed
    }

    private static func userAccessTokenIfAvailable() async -> String? {
        guard AuthManager.shared.isAuthenticated else {
            return nil
        }
        do {
            let token = try await AuthManager.shared.accessToken()
            return usableClientSecretAPIKey(token)
        } catch {
            DebugLog.warning(
                "User access token unavailable for realtime mint; using app key if configured",
                context: "WritingmateRealtime"
            )
            return nil
        }
    }
}
