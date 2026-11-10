import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationFailure.failed(message) }
}

private struct CachedProfile: Equatable {
    let subscriptionStatus: String
}

/// Guards the account state shown while a stored session restores: a paid plan
/// must not read as "Free" or signed out because the app relaunched (for
/// example after a recording ended on a microphone change) or because the
/// keychain was briefly unreadable.
@main
private struct AuthSessionRestoreValidator {
    static func main() throws {
        try validateKeychainLookup()
        try validateLaunchState()
        try validateSourceContract()
        print("Auth session restore contract: PASS")
    }

    private static func validateKeychainLookup() throws {
        try require(
            AuthSessionRestorePolicy.indicatesStoredSession(.found),
            "a readable session is stored"
        )
        try require(
            AuthSessionRestorePolicy.indicatesStoredSession(.temporarilyUnreadable),
            "a locked keychain must not read as signed out"
        )
        try require(
            !AuthSessionRestorePolicy.indicatesStoredSession(.notFound),
            "a missing session is signed out"
        )
    }

    private static func validateLaunchState() throws {
        let lifetime = CachedProfile(subscriptionStatus: "lifetime")

        let restored = AuthSessionRestorePolicy.launchState(
            hasPersistedSession: true,
            cachedProfile: lifetime
        )
        try require(restored.profile == lifetime, "launch must show the cached paid plan")
        try require(restored.isAuthenticated, "launch must stay signed in while restoring")
        try require(restored.isRestorePending, "launch must keep restore retries running")

        let signedOut = AuthSessionRestorePolicy.launchState(
            hasPersistedSession: false,
            cachedProfile: lifetime
        )
        try require(signedOut.profile == nil, "a stale cache must not sign in a signed-out user")
        try require(!signedOut.isAuthenticated, "no stored session means signed out")

        let neverCached = AuthSessionRestorePolicy.launchState(
            hasPersistedSession: true,
            cachedProfile: CachedProfile?.none
        )
        try require(neverCached.profile == nil, "nothing cached means nothing to show")
        try require(
            !neverCached.isAuthenticated,
            "without a profile the network restore decides the account state"
        )
    }

    private static func validateSourceContract() throws {
        let workspaceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let servicesURL = workspaceRoot.appendingPathComponent("Whishpermate/WhisperMateShared/Services")
        let authSource = try String(
            contentsOf: servicesURL.appendingPathComponent("AuthManager.swift"),
            encoding: .utf8
        )
        let supabaseSource = try String(
            contentsOf: servicesURL.appendingPathComponent("SupabaseManager.swift"),
            encoding: .utf8
        )

        guard let initStart = authSource.range(of: "private init() {"),
              let initEnd = authSource.range(of: "observeSessionRestoreTriggers()", range: initStart.upperBound ..< authSource.endIndex)
        else {
            throw ValidationFailure.failed("AuthManager.init must be present")
        }
        let initBody = authSource[initStart.upperBound ..< initEnd.lowerBound]
        try require(
            initBody.contains("AuthSessionRestorePolicy.launchState(")
                && initBody.contains("loadCachedUserProfile()")
                && initBody.contains("currentUser = launchState.profile"),
            "AuthManager must show the cached plan before the first restore finishes"
        )

        try require(
            supabaseSource.contains("AuthSessionRestorePolicy.indicatesStoredSession(lookup)")
                && supabaseSource.contains("case errSecInteractionNotAllowed:\n            return .temporarilyUnreadable"),
            "hasStoredSession must treat a locked keychain as a stored session"
        )
    }
}
