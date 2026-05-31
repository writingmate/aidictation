import Combine
import Foundation
import Supabase
#if canImport(AuthenticationServices) && canImport(AppKit)
    import AuthenticationServices
#endif
#if canImport(AppKit)
    import AppKit
#endif

/// Manages user authentication state and session lifecycle via Supabase
public class AuthManager: ObservableObject {
    public static let shared = AuthManager()

    // MARK: - Constants

    private enum Constants {
        static let authCallbackScheme = "aidictation://auth-callback"
        static let authCallbackURLScheme = "aidictation"
        static let userAuthChangedNotification = "UserAuthenticationChanged"
    }

    // MARK: - Published Properties

    @Published public var currentUser: User?
    @Published public var isAuthenticated: Bool = false
    @Published public var isLoading: Bool = false
    @Published public private(set) var isAuthenticationSessionActive: Bool = false
    @Published public var error: String?

    // MARK: - Private Properties

    private let supabase = SupabaseManager.shared
    private var didStartAutoRefresh = false
    #if canImport(AuthenticationServices) && canImport(AppKit)
        private let authPresentationContextProvider = AuthPresentationContextProvider()
        private var authSession: ASWebAuthenticationSession?
    #endif

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
        guard !didStartAutoRefresh, let client = supabase.client else { return }
        didStartAutoRefresh = true
        await client.auth.startAutoRefresh()
    }

    private func ensureValidSession() async -> Bool {
        guard let client = supabase.client else { return false }
        do {
            _ = try await client.auth.session
            await startAutoRefreshIfNeeded()
            return true
        } catch {
            DebugLog.info("No active session, attempting refresh: \(error.localizedDescription)", context: "AuthManager")
            do {
                _ = try await client.auth.refreshSession()
                await startAutoRefreshIfNeeded()
                return true
            } catch {
                DebugLog.info("Session refresh failed: \(error.localizedDescription)", context: "AuthManager")
                return false
            }
        }
    }

    // MARK: - Public API

    public func loginURL() -> URL? {
        guard let authWebURL = SecretsLoader.getValue(for: "AUTH_WEB_URL") else {
            error = "Missing auth web URL configuration"
            DebugLog.info("Missing auth web URL configuration", context: "AuthManager")
            return nil
        }

        let separator = authWebURL.contains("?") ? "&" : "?"
        let authURLString = "\(authWebURL)\(separator)redirect_to=\(Constants.authCallbackScheme.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Constants.authCallbackScheme)"
        guard let authURL = URL(string: authURLString) else {
            error = "Invalid auth URL configuration"
            DebugLog.warning("Invalid auth URL configuration: \(authURLString)", context: "AuthManager")
            return nil
        }

        return authURL
    }

    public func openSignUp() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.openSignUp()
            }
            return
        }

        guard !isAuthenticationSessionActive else {
            DebugLog.info("Auth popup already active, ignoring duplicate request", context: "AuthManager")
            return
        }

        guard let authURL = loginURL() else { return }
        openAuthenticationURL(authURL)
    }

    private func openAuthenticationURL(_ url: URL) {
        #if canImport(AuthenticationServices) && canImport(AppKit)
            if Thread.isMainThread {
                startWebAuthenticationSession(url)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.startWebAuthenticationSession(url)
                }
            }
        #elseif canImport(AppKit)
            openAuthURLInBrowser(url)
        #endif
    }

    #if canImport(AuthenticationServices) && canImport(AppKit)
        private func startWebAuthenticationSession(_ url: URL) {
            guard authSession == nil, !isAuthenticationSessionActive else {
                DebugLog.info("Auth popup already active, ignoring duplicate request", context: "AuthManager")
                return
            }

            isAuthenticationSessionActive = true

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Constants.authCallbackURLScheme
            ) { [weak self] callbackURL, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    self.authSession = nil
                    self.isAuthenticationSessionActive = false

                    if let callbackURL {
                        Task {
                            await self.handleAuthCallback(url: callbackURL)
                        }
                        return
                    }

                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin
                    {
                        DebugLog.info("Auth popup canceled", context: "AuthManager")
                        return
                    }

                    if let error {
                        DebugLog.warning("Auth popup failed: \(error.localizedDescription)", context: "AuthManager")
                        self.error = "Authentication failed: \(error.localizedDescription)"
                    }
                }
            }

            session.presentationContextProvider = authPresentationContextProvider
            session.prefersEphemeralWebBrowserSession = false
            authSession = session

            guard session.start() else {
                DebugLog.warning("Auth popup could not start, falling back to browser", context: "AuthManager")
                authSession = nil
                isAuthenticationSessionActive = false
                openAuthURLInBrowser(url)
                return
            }
        }
    #endif

    #if canImport(AppKit)
        private func openAuthURLInBrowser(_ url: URL) {
            NSWorkspace.shared.open(url)
        }
    #endif

    public func openLogin() {
        openSignUp()
    }

    public func handleAuthCallback(url: URL) async {
        DebugLog.info("Handling auth callback: \(url.absoluteString)", context: "AuthManager")

        do {
            guard let client = supabase.client else { return }
            let session = try await client.auth.session(from: url)
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
            try await supabase.client?.auth.signOut()
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

    public func ensureReferralCode() async throws -> User {
        let updatedUser = try await supabase.ensureReferralCode()
        await MainActor.run {
            self.currentUser = updatedUser
        }
        return updatedUser
    }

    public func redeemReferralCode(_ code: String) async throws -> User {
        let updatedUser = try await supabase.redeemReferralCode(code)
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

#if canImport(AuthenticationServices) && canImport(AppKit)
    private final class AuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        private let fallbackWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: false
        )

        override init() {
            super.init()
            fallbackWindow.identifier = NSUserInterfaceItemIdentifier("authPresentation")
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApplication.shared.keyWindow ??
                NSApplication.shared.mainWindow ??
                NSApplication.shared.windows.first(where: { $0.isVisible }) ??
                fallbackWindow
        }
    }
#endif
