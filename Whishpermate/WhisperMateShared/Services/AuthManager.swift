import Combine
import Foundation
import Supabase
#if canImport(AppKit)
    import AppKit
#endif

/// Manages user authentication state and session lifecycle via Supabase
public class AuthManager: ObservableObject {
    public static let shared = AuthManager()

    // MARK: - Constants

    private enum Constants {
        static let authCallbackScheme = "aidictation://auth-callback"
        static let userAuthChangedNotification = "UserAuthenticationChanged"
    }

    // MARK: - Published Properties

    @Published public var currentUser: User?
    @Published public var isAuthenticated: Bool = false
    @Published public var isLoading: Bool = false
    @Published public var error: String?

    // MARK: - Private Properties

    private let supabase = SupabaseManager.shared
    private var didStartAutoRefresh = false

    // MARK: - Initialization

    private init() {
        Task {
            await checkSession()
        }
    }

    // MARK: - Session Management

    private func checkSession() async {
        await refreshUser()
    }

    private func startAutoRefreshIfNeeded() async {
        guard !didStartAutoRefresh else { return }
        didStartAutoRefresh = true
        await supabase.client.auth.startAutoRefresh()
    }

    private func ensureValidSession() async -> Bool {
        do {
            _ = try await supabase.client.auth.session
            await startAutoRefreshIfNeeded()
            return true
        } catch {
            DebugLog.info("No active session, attempting refresh: \(error.localizedDescription)", context: "AuthManager")
            do {
                _ = try await supabase.client.auth.refreshSession()
                await startAutoRefreshIfNeeded()
                return true
            } catch {
                DebugLog.info("Session refresh failed: \(error.localizedDescription)", context: "AuthManager")
                return false
            }
        }
    }

    // MARK: - Public API

    public func openSignUp() {
        guard let authWebURL = SecretsLoader.getValue(for: "AUTH_WEB_URL") else {
            error = "Missing auth web URL configuration"
            DebugLog.info("Missing auth web URL configuration", context: "AuthManager")
            return
        }

        let authURL = "\(authWebURL)?redirect_to=\(Constants.authCallbackScheme.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Constants.authCallbackScheme)"

        #if canImport(AppKit)
            if let url = URL(string: authURL) {
                NSWorkspace.shared.open(url)
            }
        #endif
    }

    public func openLogin() {
        openSignUp()
    }

    public func handleAuthCallback(url: URL) async {
        DebugLog.info("Handling auth callback: \(url.absoluteString)", context: "AuthManager")

        do {
            let session = try await supabase.client.auth.session(from: url)
            DebugLog.info("Session established for user: \(session.user.id)", context: "AuthManager")
            await refreshUser()
        } catch {
            DebugLog.info("Auth callback failed: \(error.localizedDescription)", context: "AuthManager")
            await MainActor.run {
                self.error = "Authentication failed: \(error.localizedDescription)"
            }
        }
    }

    public func refreshUser() async {
        DebugLog.info("Fetching user data...", context: "AuthManager")
        await MainActor.run {
            self.isLoading = true
            self.error = nil
        }

        let hasSession = await ensureValidSession()
        guard hasSession else {
            await MainActor.run {
                self.currentUser = nil
                self.isAuthenticated = false
                self.isLoading = false
            }
            return
        }

        await MainActor.run {
            self.isAuthenticated = true
        }

        do {
            let user = try await supabase.fetchUser()
            DebugLog.info("User fetched: \(user.email), tier: \(user.subscriptionTier), words: \(user.totalWordsUsed)", context: "AuthManager")
            await MainActor.run {
                self.objectWillChange.send()
                self.currentUser = user
                self.isAuthenticated = true
                self.isLoading = false

                NotificationCenter.default.post(name: NSNotification.Name(Constants.userAuthChangedNotification), object: nil)
            }
            DebugLog.info("Auth state updated - isAuthenticated: true", context: "AuthManager")
        } catch {
            DebugLog.info("Failed to fetch user: \(error.localizedDescription)", context: "AuthManager")
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    public func logout() async {
        DebugLog.info("Logging out...", context: "AuthManager")
        do {
            try await supabase.client.auth.signOut()
            await MainActor.run {
                self.currentUser = nil
                self.isAuthenticated = false
            }
            DebugLog.info("Logged out successfully", context: "AuthManager")
        } catch {
            DebugLog.info("Logout failed: \(error.localizedDescription)", context: "AuthManager")
            await MainActor.run {
                self.error = "Logout failed: \(error.localizedDescription)"
            }
        }
    }

    public func updateWordCount(wordsToAdd: Int) async throws -> User {
        let updatedUser = try await supabase.updateUserWordCount(wordsToAdd: wordsToAdd)
        await MainActor.run {
            self.currentUser = updatedUser
        }
        return updatedUser
    }

    public func checkCanTranscribe() -> (canTranscribe: Bool, reason: String?) {
        guard isAuthenticated, let user = currentUser else {
            return (false, "Please create an account to start transcribing")
        }

        if user.hasReachedLimit {
            return (false, "You've reached your word limit. Upgrade to Pro for unlimited transcriptions.")
        }

        return (true, nil)
    }
}
