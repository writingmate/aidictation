import Foundation

/// Decides which account state the app shows while a stored session is being
/// restored, so a paying user is never shown as signed out or on the free trial
/// just because restoring has not finished or the keychain is briefly unreadable.
enum AuthSessionRestorePolicy {
    // MARK: - Types

    /// Result of asking one keychain whether a session item exists.
    enum KeychainLookup: Equatable, Sendable {
        case found
        case notFound
        /// The item exists but cannot be read yet (keychain locked, or the app
        /// launched before the user unlocked it).
        case temporarilyUnreadable
    }

    struct LaunchState<Profile> {
        let profile: Profile?
        let isAuthenticated: Bool
        let isRestorePending: Bool
    }

    // MARK: - Public API

    /// A temporarily unreadable item still counts as stored: treating it as
    /// missing signs the user out and stops the restore retries for good.
    static func indicatesStoredSession(_ lookup: KeychainLookup) -> Bool {
        switch lookup {
        case .found, .temporarilyUnreadable:
            return true
        case .notFound:
            return false
        }
    }

    /// State to show before the first restore finishes. The cached profile is
    /// only ever what the backend last returned for this session; it is
    /// replaced by the restore result or cleared on sign-out and rejection.
    static func launchState<Profile>(
        hasPersistedSession: Bool,
        cachedProfile: Profile?
    ) -> LaunchState<Profile> {
        guard hasPersistedSession, let cachedProfile else {
            return LaunchState(profile: nil, isAuthenticated: false, isRestorePending: false)
        }
        return LaunchState(profile: cachedProfile, isAuthenticated: true, isRestorePending: true)
    }
}
