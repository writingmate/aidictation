import Combine
import Foundation
import Supabase
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif
#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

public enum AuthCallbackFailurePhase: String, Sendable {
    case none
    case callbackShape = "callback_shape"
    case sessionValidation = "session_validation"
    case profileFetch = "profile_fetch"
}

public enum AuthCallbackFailureCategory: String, Sendable {
    case none
    case missingRequiredFields = "missing_required_fields"
    case noncanonicalFields = "noncanonical_fields"
    case configurationUnavailable = "configuration_unavailable"
    case implicitGrantRejected = "implicit_grant_rejected"
    case jwtRejected = "jwt_rejected"
    case sessionMissing = "session_missing"
    case apiUnauthorized = "api_401"
    case apiForbidden = "api_403"
    case apiNotFound = "api_404"
    case apiClientRejected = "api_client_rejected"
    case apiServerRejected = "api_server_rejected"
    case apiOtherRejected = "api_other_rejected"
    case authOther = "auth_other"
    case sessionUnavailableAfterCallback = "session_unavailable_after_callback"
    case profileRequestRejected = "profile_request_rejected"
    case unknown
}

public struct AuthCallbackOutcome: Sendable {
    public let hasAccessToken: Bool
    public let hasRefreshToken: Bool
    public let hasTokenType: Bool
    public let hasExpiresIn: Bool
    public let sessionEstablished: Bool
    public let profileRequestStarted: Bool
    public let profileLoaded: Bool
    public let failurePhase: AuthCallbackFailurePhase
    public let failureCategory: AuthCallbackFailureCategory
}

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
    #if canImport(AuthenticationServices) && (canImport(AppKit) || canImport(UIKit))
        private let authPresentationContextProvider = AuthPresentationContextProvider()
        private var authSession: ASWebAuthenticationSession?
    #endif

    private struct CallbackShape {
        let hasAccessToken: Bool
        let hasRefreshToken: Bool
        let hasTokenType: Bool
        let hasExpiresIn: Bool
        let hasAuthFieldsInQuery: Bool
        let tokenTypeIsBearer: Bool

        init(url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                hasAccessToken = false
                hasRefreshToken = false
                hasTokenType = false
                hasExpiresIn = false
                hasAuthFieldsInQuery = false
                tokenTypeIsBearer = false
                return
            }

            let requiredNames = Set([
                "access_token",
                "refresh_token",
                "token_type",
                "expires_in",
            ])
            hasAuthFieldsInQuery = (components.queryItems ?? []).contains {
                requiredNames.contains($0.name)
            }

            var items: [URLQueryItem] = []
            if let fragment = components.fragment,
               let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems
            {
                items.append(contentsOf: fragmentItems)
            }

            func hasValue(_ name: String) -> Bool {
                items.contains { $0.name == name && !($0.value ?? "").isEmpty }
            }

            hasAccessToken = hasValue("access_token")
            hasRefreshToken = hasValue("refresh_token")
            hasTokenType = hasValue("token_type")
            hasExpiresIn = hasValue("expires_in")
            tokenTypeIsBearer = items.last(where: { $0.name == "token_type" })?
                .value?.lowercased() == "bearer"
        }

        var isComplete: Bool {
            hasAccessToken && hasRefreshToken && hasTokenType && hasExpiresIn
        }

        var isCanonical: Bool {
            !hasAuthFieldsInQuery && tokenTypeIsBearer
        }
    }

    private enum UserRefreshOutcome {
        case sessionUnavailable
        case profileLoaded
        case profileRequestRejected
    }

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
            DebugLog.info("No active session; attempting refresh", context: "AuthManager")
            do {
                _ = try await client.auth.refreshSession()
                await startAutoRefreshIfNeeded()
                return true
            } catch {
                DebugLog.info("Session refresh failed", context: "AuthManager")
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
        #if canImport(AuthenticationServices) && (canImport(AppKit) || canImport(UIKit))
            if Thread.isMainThread {
                startWebAuthenticationSession(url)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.startWebAuthenticationSession(url)
                }
            }
        #elseif canImport(AppKit)
            openAuthURLInBrowser(url)
        #else
            error = "Login is unavailable on this device."
        #endif
    }

    #if canImport(AuthenticationServices) && (canImport(AppKit) || canImport(UIKit))
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

                    if error != nil {
                        DebugLog.warning("Authentication popup failed", context: "AuthManager")
                        self.error = "Authentication failed. Please try again or contact support."
                    }
                }
            }

            session.presentationContextProvider = authPresentationContextProvider
            session.prefersEphemeralWebBrowserSession = false
            authSession = session

            guard session.start() else {
                DebugLog.warning("Auth popup could not start", context: "AuthManager")
                authSession = nil
                isAuthenticationSessionActive = false
                handleAuthenticationSessionStartFailure(url)
                return
            }
        }

        private func handleAuthenticationSessionStartFailure(_ url: URL) {
            #if canImport(AppKit)
                openAuthURLInBrowser(url)
            #else
                error = "Login could not open. Please try again."
            #endif
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

    @MainActor
    public func signIn(email: String, password: String) async throws {
        guard let client = supabase.client else {
            throw NSError(domain: "AuthManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Login is not configured in this build.",
            ])
        }

        isLoading = true
        error = nil

        do {
            _ = try await client.auth.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            await refreshUser()
        } catch {
            isLoading = false
            self.error = error.localizedDescription
            throw error
        }
    }

    @MainActor
    public func createAccount(email: String, password: String) async throws {
        guard let client = supabase.client else {
            throw NSError(domain: "AuthManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Login is not configured in this build.",
            ])
        }

        isLoading = true
        error = nil

        do {
            _ = try await client.auth.signUp(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            await refreshUser()
        } catch {
            isLoading = false
            self.error = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    public func handleAuthCallback(url: URL) async -> AuthCallbackOutcome {
        DebugLog.info("Handling authentication callback", context: "AuthManager")
        let shape = CallbackShape(url: url)

        guard shape.isComplete else {
            DebugLog.warning(
                "Authentication callback is missing required session fields",
                context: "AuthManager"
            )
            await setSupportSafeCallbackError()
            return callbackOutcome(
                shape: shape,
                failurePhase: .callbackShape,
                failureCategory: .missingRequiredFields
            )
        }
        guard shape.isCanonical else {
            DebugLog.warning(
                "Authentication callback session fields are not canonical",
                context: "AuthManager"
            )
            await setSupportSafeCallbackError()
            return callbackOutcome(
                shape: shape,
                failurePhase: .callbackShape,
                failureCategory: .noncanonicalFields
            )
        }

        do {
            guard let client = supabase.client else {
                await setSupportSafeCallbackError()
                return callbackOutcome(
                    shape: shape,
                    failurePhase: .sessionValidation,
                    failureCategory: .configurationUnavailable
                )
            }
            _ = try await client.auth.session(from: url)
            DebugLog.info("Authentication callback established a session", context: "AuthManager")

            switch await refreshUserWithOutcome() {
            case .profileLoaded:
                return callbackOutcome(
                    shape: shape,
                    sessionEstablished: true,
                    profileRequestStarted: true,
                    profileLoaded: true
                )
            case .sessionUnavailable:
                await setSupportSafeCallbackError()
                return callbackOutcome(
                    shape: shape,
                    sessionEstablished: true,
                    failurePhase: .sessionValidation,
                    failureCategory: .sessionUnavailableAfterCallback
                )
            case .profileRequestRejected:
                return callbackOutcome(
                    shape: shape,
                    sessionEstablished: true,
                    profileRequestStarted: true,
                    failurePhase: .profileFetch,
                    failureCategory: .profileRequestRejected
                )
            }
        } catch {
            let category = callbackFailureCategory(error)
            DebugLog.warning(
                "Authentication callback session validation failed (\(category.rawValue))",
                context: "AuthManager"
            )
            await setSupportSafeCallbackError()
            return callbackOutcome(
                shape: shape,
                failurePhase: .sessionValidation,
                failureCategory: category
            )
        }
    }

    @discardableResult
    public func refreshUser() async -> Bool {
        switch await refreshUserWithOutcome() {
        case .profileLoaded:
            return true
        case .sessionUnavailable, .profileRequestRejected:
            return false
        }
    }

    private func refreshUserWithOutcome() async -> UserRefreshOutcome {
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
            return .sessionUnavailable
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
            return .profileLoaded
        } catch {
            DebugLog.warning("Failed to fetch authenticated profile", context: "AuthManager")
            await MainActor.run {
                self.error = "We could not load your account. Please try again."
                self.isLoading = false
            }
            return .profileRequestRejected
        }
    }

    private func callbackOutcome(
        shape: CallbackShape,
        sessionEstablished: Bool = false,
        profileRequestStarted: Bool = false,
        profileLoaded: Bool = false,
        failurePhase: AuthCallbackFailurePhase = .none,
        failureCategory: AuthCallbackFailureCategory = .none
    ) -> AuthCallbackOutcome {
        AuthCallbackOutcome(
            hasAccessToken: shape.hasAccessToken,
            hasRefreshToken: shape.hasRefreshToken,
            hasTokenType: shape.hasTokenType,
            hasExpiresIn: shape.hasExpiresIn,
            sessionEstablished: sessionEstablished,
            profileRequestStarted: profileRequestStarted,
            profileLoaded: profileLoaded,
            failurePhase: failurePhase,
            failureCategory: failureCategory
        )
    }

    private func callbackFailureCategory(_ error: Error) -> AuthCallbackFailureCategory {
        guard let authError = error as? AuthError else {
            return .unknown
        }

        switch authError {
        case .implicitGrantRedirect:
            return .implicitGrantRejected
        case .jwtVerificationFailed:
            return .jwtRejected
        case .sessionMissing:
            return .sessionMissing
        case let .api(_, _, _, response):
            switch response.statusCode {
            case 401:
                return .apiUnauthorized
            case 403:
                return .apiForbidden
            case 404:
                return .apiNotFound
            case 400 ... 499:
                return .apiClientRejected
            case 500 ... 599:
                return .apiServerRejected
            default:
                return .apiOtherRejected
            }
        case .weakPassword, .pkceGrantCodeExchange:
            return .authOther
        default:
            return .authOther
        }
    }

    private func setSupportSafeCallbackError() async {
        await MainActor.run {
            self.error = "Authentication failed. Please try again or contact support."
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

#if canImport(AuthenticationServices) && (canImport(AppKit) || canImport(UIKit))
    private final class AuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        #if canImport(AppKit)
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
        #elseif canImport(UIKit)
        private let fallbackWindow = UIWindow(frame: .zero)
        #endif

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            #if canImport(AppKit)
            NSApplication.shared.keyWindow ??
                NSApplication.shared.mainWindow ??
                NSApplication.shared.windows.first(where: { $0.isVisible }) ??
                fallbackWindow
            #elseif canImport(UIKit)
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: { $0.isKeyWindow }) ??
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: { !$0.isHidden }) ??
                fallbackWindow
            #endif
        }
    }
#endif
