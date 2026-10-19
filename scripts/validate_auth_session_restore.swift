import Foundation

private enum ValidationFailure: Error {
    case assertion(String)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw ValidationFailure.assertion(message) }
}

private typealias Policy = AuthSessionRestorePolicy

@main
private enum ValidateAuthSessionRestore {
    static func main() throws {
        try transientFailuresKeepSignedIn()
        try definitiveFailuresSignOut()
        try statusMapping()
        try sourceContract()
        print("PASS: a failed session restore only signs out when the server rejects the session")
    }

    static func transientFailuresKeepSignedIn() throws {
        try require(
            Policy.resolve(failure: .transient, hasPersistedSession: true, hasCurrentUser: false, hasCachedProfile: true)
                == .keepSignedIn(restoreCachedProfile: true),
            "offline launch must restore the cached profile"
        )
        try require(
            Policy.resolve(failure: .sessionMissing, hasPersistedSession: true, hasCurrentUser: false, hasCachedProfile: true)
                == .keepSignedIn(restoreCachedProfile: true),
            "a keychain miss with a persisted session must restore the cached profile"
        )
        try require(
            Policy.resolve(failure: .transient, hasPersistedSession: true, hasCurrentUser: true, hasCachedProfile: true)
                == .keepSignedIn(restoreCachedProfile: false),
            "a loaded profile is kept as-is"
        )
        try require(
            Policy.resolve(failure: .transient, hasPersistedSession: true, hasCurrentUser: false, hasCachedProfile: false)
                == .keepSignedIn(restoreCachedProfile: false),
            "no cache still does not mean signed out"
        )
    }

    static func definitiveFailuresSignOut() throws {
        try require(
            Policy.resolve(failure: .rejectedByServer, hasPersistedSession: true, hasCurrentUser: true, hasCachedProfile: true)
                == .signOut,
            "a server rejection signs out even with a cached profile"
        )
        for failure in [Policy.Failure.sessionMissing, .transient, .rejectedByServer] {
            try require(
                Policy.resolve(failure: failure, hasPersistedSession: false, hasCurrentUser: false, hasCachedProfile: true)
                    == .signOut,
                "\(failure) with nothing persisted must sign out"
            )
        }
    }

    static func statusMapping() throws {
        for status in [400, 401, 403, 404, 422] {
            try require(Policy.failure(forHTTPStatus: status) == .rejectedByServer, "\(status) must be a rejection")
        }
        for status in [429, 500, 502, 503, 504] {
            try require(Policy.failure(forHTTPStatus: status) == .transient, "\(status) must be transient")
        }
    }

    /// Guards the two code paths that used to turn a transient failure into a
    /// permanent sign-out.
    static func sourceContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let authSource = try String(
            contentsOf: root.appendingPathComponent("Whishpermate/WhisperMateShared/Services/AuthManager.swift"),
            encoding: .utf8
        )
        let storageSource = try String(
            contentsOf: root.appendingPathComponent("Whishpermate/WhisperMateShared/Services/SupabaseManager.swift"),
            encoding: .utf8
        )

        try require(
            authSource.contains("AuthSessionRestorePolicy.resolve("),
            "AuthManager must route restore failures through AuthSessionRestorePolicy"
        )
        try require(
            authSource.contains("restoreCachedSignedInStateIfPossible()"),
            "AuthManager must show the cached profile while the session is validated"
        )
        try require(
            authSource.contains("supabase.clearPersistedSession()"),
            "sign-out must clear persisted storage even when the SDK has no session in memory"
        )
        try require(
            authSource.contains("guard !self.isAuthenticated || self.isSessionRestorePending else { return }"),
            "restore retries must keep running while the signed-in state comes from the cache"
        )

        let retrieveRange = try requireRange(of: "func retrieve(key: String) throws -> Data? {\n        let (data, status) = AuthKeychain.retrieve(key: key)", in: storageSource, through: "func remove(key: String) throws {")
        let retrieveBody = String(storageSource[retrieveRange])
        try require(
            !retrieveBody.contains("AuthKeychain.remove(key: key)"),
            "a failed keychain read must never delete the stored session"
        )
        try require(
            storageSource.contains("static func removeAll()") && storageSource.contains("func clearPersistedSession()"),
            "SupabaseManager must expose explicit persisted-session clearing"
        )
    }

    private static func requireRange(
        of start: String,
        in source: String,
        through end: String
    ) throws -> Range<String.Index> {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound ..< source.endIndex)
        else {
            throw ValidationFailure.assertion("could not locate \(start) ... \(end)")
        }
        return startRange.lowerBound ..< endRange.upperBound
    }
}
