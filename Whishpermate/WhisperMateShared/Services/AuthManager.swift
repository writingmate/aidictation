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
    private var backendUser: User?
    private var revenueCatEntitlement: RevenueCatEntitlementStatus?
    private var revenueCatEntitlementUserID: UUID?
    private var revenueCatReconciliationUserIDs = Set<UUID>()
    private var authStateGeneration: UInt64 = 0
    private var authIdentityGeneration: UInt64 = 0
    private var backendProfileRevision: UInt64 = 0
    private var isLoggingOut = false
    private let backendMutationGate = BackendMutationGate()

    private struct BackendMutationContext: Sendable {
        let userID: UUID
        let identityGeneration: UInt64
    }

    #if canImport(AuthenticationServices) && (canImport(AppKit) || canImport(UIKit))
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

    private func ensureValidSession() async -> UUID? {
        guard let client = supabase.client else { return nil }
        do {
            let session = try await client.auth.session
            await startAutoRefreshIfNeeded()
            return session.user.id
        } catch {
            DebugLog.info("No active session, attempting refresh: \(error.localizedDescription)", context: "AuthManager")
            do {
                let session = try await client.auth.refreshSession()
                await startAutoRefreshIfNeeded()
                return session.user.id
            } catch {
                DebugLog.info("Session refresh failed: \(error.localizedDescription)", context: "AuthManager")
                return nil
            }
        }
    }

    private func activeSessionUserID() async -> UUID? {
        guard let client = supabase.client else { return nil }
        do {
            return try await client.auth.session.user.id
        } catch {
            return nil
        }
    }

    public func hasActiveSession(for userID: UUID) async -> Bool {
        await activeSessionUserID() == userID
    }

    static func shouldClearPublishedUser(
        publishedUserID: UUID?,
        sessionUserID: UUID
    ) -> Bool {
        guard let publishedUserID else { return false }
        return publishedUserID != sessionUserID
    }

    static func backendUpdateMatchesActiveIdentity(
        expectedUserID: UUID,
        expectedIdentityGeneration: UInt64,
        currentIdentityGeneration: UInt64,
        publishedUserID: UUID?,
        resultUserID: UUID,
        isAuthenticated: Bool
    ) -> Bool {
        backendMutationContextMatchesActiveIdentity(
            expectedUserID: expectedUserID,
            expectedIdentityGeneration: expectedIdentityGeneration,
            currentIdentityGeneration: currentIdentityGeneration,
            publishedUserID: publishedUserID,
            isAuthenticated: isAuthenticated
        )
            && resultUserID == expectedUserID
    }

    static func backendMutationContextMatchesActiveIdentity(
        expectedUserID: UUID,
        expectedIdentityGeneration: UInt64,
        currentIdentityGeneration: UInt64,
        publishedUserID: UUID?,
        isAuthenticated: Bool
    ) -> Bool {
        isAuthenticated
            && expectedIdentityGeneration == currentIdentityGeneration
            && publishedUserID == expectedUserID
    }

    static func refreshCanPublishBackendProfile(
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        expectedProfileRevision: UInt64,
        currentProfileRevision: UInt64
    ) -> Bool {
        expectedGeneration == currentGeneration
            && expectedProfileRevision == currentProfileRevision
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

                    if let error {
                        DebugLog.warning("Auth popup failed: \(error.localizedDescription)", context: "AuthManager")
                        self.error = "Authentication failed: \(error.localizedDescription)"
                    }
                }
            }

            session.presentationContextProvider = authPresentationContextProvider
            session.prefersEphemeralWebBrowserSession = true
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

    public func handleAuthCallback(url: URL) async {
        DebugLog.info("Handling authentication callback", context: "AuthManager")

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

    @discardableResult
    public func refreshUser() async -> UInt64? {
        DebugLog.info("Fetching user data...", context: "AuthManager")
        let refreshContext: (generation: UInt64, profileRevision: UInt64)? = await MainActor.run {
            guard !self.isLoggingOut else { return nil }
            self.authStateGeneration &+= 1
            self.isLoading = true
            self.error = nil
            return (self.authStateGeneration, self.backendProfileRevision)
        }
        guard let refreshContext else { return nil }
        let refreshGeneration = refreshContext.generation

        guard let sessionUserID = await ensureValidSession() else {
            await MainActor.run {
                guard self.authStateGeneration == refreshGeneration else { return }
                self.resetPublishedUser()
                self.isLoading = false
            }
            return refreshGeneration
        }

        let shouldContinue = await MainActor.run {
            guard self.authStateGeneration == refreshGeneration else { return false }
            if Self.shouldClearPublishedUser(
                publishedUserID: self.backendUser?.userId,
                sessionUserID: sessionUserID
            ) {
                // Never expose one account's access while another account loads.
                self.resetPublishedUser()
                self.isLoading = true
            }
            return true
        }
        guard shouldContinue else { return refreshGeneration }

        do {
            let user = try await supabase.fetchUser()
            guard user.userId == sessionUserID else {
                throw AuthManagerError.sessionChanged
            }

            let initialIdentification = await RevenueCatManager.shared.identify(
                userID: user.userId,
                email: user.email
            )
            let identification = await reconcileLegacyLifetimeIfNeeded(
                for: user,
                identification: initialIdentification
            )
            guard await activeSessionUserID() == user.userId else {
                throw AuthManagerError.sessionChanged
            }

            DebugLog.info("User fetched: \(user.email), tier: \(user.subscriptionTier), words: \(user.totalWordsUsed)", context: "AuthManager")
            let didPublish = await MainActor.run {
                guard Self.refreshCanPublishBackendProfile(
                    expectedGeneration: refreshGeneration,
                    currentGeneration: self.authStateGeneration,
                    expectedProfileRevision: refreshContext.profileRevision,
                    currentProfileRevision: self.backendProfileRevision
                ) else {
                    if self.authStateGeneration == refreshGeneration {
                        self.isLoading = false
                    }
                    return false
                }
                self.acceptBackendUser(user, identification: identification)
                self.isAuthenticated = true
                self.isLoading = false

                NotificationCenter.default.post(name: NSNotification.Name(Constants.userAuthChangedNotification), object: nil)
                return true
            }
            if didPublish {
                DebugLog.info("Auth state updated - isAuthenticated: true", context: "AuthManager")
            }
        } catch {
            DebugLog.info("Failed to fetch user: \(error.localizedDescription)", context: "AuthManager")
            await MainActor.run {
                guard self.authStateGeneration == refreshGeneration else { return }
                if error is AuthManagerError {
                    self.resetPublishedUser()
                }
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
        return refreshGeneration
    }

    public func logout() async {
        DebugLog.info("Logging out...", context: "AuthManager")
        let logoutGeneration: UInt64? = await MainActor.run {
            guard !self.isLoggingOut else { return nil }
            self.authStateGeneration &+= 1
            self.isLoggingOut = true
            self.resetPublishedUser()
            self.isLoading = true
            self.error = nil
            return self.authStateGeneration
        }
        guard let logoutGeneration else { return }

        do {
            try await supabase.client?.auth.signOut()
            await RevenueCatManager.shared.signOut()
            await MainActor.run {
                guard self.authStateGeneration == logoutGeneration else { return }
                self.isLoggingOut = false
                self.resetPublishedUser()
                self.isLoading = false
            }
            DebugLog.info("Logged out successfully", context: "AuthManager")
        } catch {
            DebugLog.info("Logout failed: \(error.localizedDescription)", context: "AuthManager")
            // RevenueCat identity cleanup is compensating work: perform it even
            // when Supabase sign-out fails or the caller is cancelled.
            await RevenueCatManager.shared.signOut()
            let shouldRecover = await MainActor.run {
                guard self.authStateGeneration == logoutGeneration else { return false }
                self.isLoggingOut = false
                self.isLoading = false
                return true
            }
            guard shouldRecover else { return }

            let recoveryGeneration = await refreshUser()
            await MainActor.run {
                guard let recoveryGeneration,
                      self.authStateGeneration == recoveryGeneration
                else { return }
                self.error = "Logout failed: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    @MainActor
    public func applyRevenueCatEntitlement(
        _ entitlement: RevenueCatEntitlementStatus,
        for userID: UUID
    ) {
        guard backendUser?.userId == userID else { return }
        revenueCatEntitlement = entitlement
        revenueCatEntitlementUserID = userID
        publishEffectiveUser()
    }

    /// Applies RevenueCat updates only after legacy lifetime/AppSumo profiles
    /// have had a chance to grant or revoke their authoritative entitlement.
    public func reconcileAndApplyRevenueCatEntitlement(
        _ entitlement: RevenueCatEntitlementStatus,
        for userID: UUID
    ) async {
        let user: User? = await MainActor.run {
            guard self.backendUser?.userId == userID else { return nil }
            return self.backendUser
        }
        guard let user else { return }

        let identification = await reconcileLegacyLifetimeIfNeeded(
            for: user,
            identification: .confirmed(entitlement)
        )
        guard case let .confirmed(resolvedEntitlement) = identification else {
            // Keep the last paid profile/cache on network or configuration failure.
            return
        }

        await MainActor.run {
            self.applyRevenueCatEntitlement(resolvedEntitlement, for: userID)
        }
    }

    public func updateWordCount(wordsToAdd: Int) async throws -> User {
        try await performBackendMutation { expectedUserID in
            try await self.supabase.updateUserWordCount(
                wordsToAdd: wordsToAdd,
                expectedUserID: expectedUserID
            )
        }
    }

    public func ensureReferralCode() async throws -> User {
        try await performBackendMutation { expectedUserID in
            try await self.supabase.ensureReferralCode(expectedUserID: expectedUserID)
        }
    }

    public func redeemReferralCode(_ code: String) async throws -> User {
        try await performBackendMutation { expectedUserID in
            try await self.supabase.redeemReferralCode(
                code,
                expectedUserID: expectedUserID
            )
        }
    }

    private func performBackendMutation(
        _ operation: (UUID) async throws -> User
    ) async throws -> User {
        let context = try await MainActor.run {
            try self.makeBackendMutationContext()
        }
        await backendMutationGate.acquire()

        do {
            try Task.checkCancellation()
            let contextIsCurrent = await MainActor.run {
                Self.backendMutationContextMatchesActiveIdentity(
                    expectedUserID: context.userID,
                    expectedIdentityGeneration: context.identityGeneration,
                    currentIdentityGeneration: self.authIdentityGeneration,
                    publishedUserID: self.backendUser?.userId,
                    isAuthenticated: self.isAuthenticated
                )
            }
            guard contextIsCurrent else {
                throw AuthManagerError.sessionChanged
            }
            guard await activeSessionUserID() == context.userID else {
                throw AuthManagerError.sessionChanged
            }

            // The server compares this original identity with auth.uid() before
            // performing any side effect, closing the account-switch race.
            let updatedUser = try await operation(context.userID)
            guard await activeSessionUserID() == context.userID else {
                throw AuthManagerError.sessionChanged
            }

            let acceptedUser = try await MainActor.run {
                try self.acceptBackendUpdate(updatedUser, context: context)
            }
            await backendMutationGate.release()
            return acceptedUser
        } catch {
            await backendMutationGate.release()
            throw error
        }
    }

    @MainActor
    private func makeBackendMutationContext() throws -> BackendMutationContext {
        guard isAuthenticated, let userID = backendUser?.userId else {
            throw AuthManagerError.sessionChanged
        }
        return BackendMutationContext(
            userID: userID,
            identityGeneration: authIdentityGeneration
        )
    }

    @MainActor
    private func acceptBackendUser(
        _ user: User,
        identification: RevenueCatIdentificationResult
    ) {
        if backendUser?.userId != user.userId {
            revenueCatEntitlement = nil
            revenueCatEntitlementUserID = nil
        }

        backendUser = user
        backendProfileRevision &+= 1
        if case let .confirmed(entitlement) = identification {
            revenueCatEntitlement = entitlement
            revenueCatEntitlementUserID = user.userId
        }
        // A lookup failure intentionally leaves a same-user confirmed state intact.
        publishEffectiveUser()
    }

    @MainActor
    @discardableResult
    private func acceptBackendUpdate(
        _ user: User,
        context: BackendMutationContext
    ) throws -> User {
        guard Self.backendUpdateMatchesActiveIdentity(
            expectedUserID: context.userID,
            expectedIdentityGeneration: context.identityGeneration,
            currentIdentityGeneration: authIdentityGeneration,
            publishedUserID: backendUser?.userId,
            resultUserID: user.userId,
            isAuthenticated: isAuthenticated
        ) else {
            throw AuthManagerError.sessionChanged
        }
        backendUser = user
        backendProfileRevision &+= 1
        publishEffectiveUser()
        return currentUser ?? user
    }

    private func reconcileLegacyLifetimeIfNeeded(
        for user: User,
        identification: RevenueCatIdentificationResult
    ) async -> RevenueCatIdentificationResult {
        guard user.subscriptionStatus == "lifetime",
              identification == .confirmed(.inactive)
        else {
            return identification
        }

        guard await beginRevenueCatReconciliation(for: user.userId) else {
            // Another refresh is already establishing the authoritative state.
            return .failed
        }

        do {
            try await supabase.reconcileSubscription(expectedUserID: user.userId)
            guard await activeSessionUserID() == user.userId else {
                throw AuthManagerError.sessionChanged
            }

            let refreshedIdentification = await RevenueCatManager.shared.identify(
                userID: user.userId,
                email: user.email
            )
            guard await activeSessionUserID() == user.userId else {
                throw AuthManagerError.sessionChanged
            }

            await endRevenueCatReconciliation(for: user.userId)
            return refreshedIdentification
        } catch {
            await endRevenueCatReconciliation(for: user.userId)
            DebugLog.warning(
                "Lifetime access reconciliation failed: \(error.localizedDescription)",
                context: "AuthManager"
            )
            return .failed
        }
    }

    @MainActor
    private func beginRevenueCatReconciliation(for userID: UUID) -> Bool {
        revenueCatReconciliationUserIDs.insert(userID).inserted
    }

    @MainActor
    private func endRevenueCatReconciliation(for userID: UUID) {
        revenueCatReconciliationUserIDs.remove(userID)
    }

    @MainActor
    private func publishEffectiveUser() {
        guard var user = backendUser else {
            currentUser = nil
            return
        }

        if revenueCatEntitlementUserID == user.userId,
           let revenueCatEntitlement
        {
            switch revenueCatEntitlement {
            case .inactive:
                user.subscriptionStatus = "free"
            case .pro, .lifetime:
                user.subscriptionStatus = revenueCatEntitlement.subscriptionStatus ?? "free"
            }
        }

        currentUser = user
    }

    @MainActor
    private func resetPublishedUser() {
        authIdentityGeneration &+= 1
        backendUser = nil
        currentUser = nil
        isAuthenticated = false
        revenueCatEntitlement = nil
        revenueCatEntitlementUserID = nil
        revenueCatReconciliationUserIDs.removeAll()
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

actor BackendMutationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        waiters.removeFirst().resume()
    }
}

private enum AuthManagerError: LocalizedError {
    case sessionChanged

    var errorDescription: String? {
        "Your login changed while the account was loading. Please try again."
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
