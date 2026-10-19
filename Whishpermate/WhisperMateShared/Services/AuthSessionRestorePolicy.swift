import Foundation

/// Decides what a failed session restore means for the signed-in state.
///
/// Restoring the session at launch can fail for reasons that say nothing about
/// whether the user is still signed in: no network yet (a login-item launch),
/// the auth backend returning 5xx, a request timing out, or the keychain not
/// handing the stored session back on this attempt. Treating every one of
/// those as "signed out" is what showed a Lifetime customer as
/// "Not signed in / Free" after a relaunch, and it also pushed them onto the
/// anonymous word limit until a retry happened to succeed.
///
/// Only two things prove the user is signed out: there is no persisted session
/// at all, or the server rejected the refresh token for good (the SDK then
/// deletes the stored session itself). Everything else keeps the current
/// state and, on a cold launch, restores the last profile the backend gave us
/// so the plan display does not regress while we retry.
public enum AuthSessionRestorePolicy {
    /// What went wrong while validating or refreshing the stored session.
    public enum Failure: Equatable, Sendable {
        /// The SDK found no session to work with. This is also what it
        /// reports after deleting a session the server rejected for good, so
        /// on its own it does not tell "never signed in" from "could not read
        /// the keychain just now"; `hasPersistedSession` does.
        case sessionMissing
        /// The server answered and refused the refresh token: 4xx other than
        /// rate limiting. The session is gone.
        case rejectedByServer
        /// Network, timeout, rate limit, 5xx, decoding: try again later.
        case transient
    }

    public enum Resolution: Equatable, Sendable {
        /// Clear the signed-in state and the cached profile.
        case signOut
        /// Leave the signed-in state alone. When `restoreCachedProfile` is
        /// true nothing is loaded yet and the cached profile should stand in
        /// until the backend answers.
        case keepSignedIn(restoreCachedProfile: Bool)
    }

    public static func resolve(
        failure: Failure,
        hasPersistedSession: Bool,
        hasCurrentUser: Bool,
        hasCachedProfile: Bool
    ) -> Resolution {
        switch failure {
        case .rejectedByServer:
            return .signOut
        case .sessionMissing, .transient:
            guard hasPersistedSession else { return .signOut }
            return .keepSignedIn(restoreCachedProfile: !hasCurrentUser && hasCachedProfile)
        }
    }

    /// Maps an HTTP status from the auth server to a failure kind. Rate
    /// limiting and server errors are retryable; any other client error means
    /// the server looked at the token and said no.
    public static func failure(forHTTPStatus statusCode: Int) -> Failure {
        switch statusCode {
        case 429:
            return .transient
        case 400 ..< 500:
            return .rejectedByServer
        default:
            return .transient
        }
    }
}
