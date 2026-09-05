import AppKit
import AuthenticationServices

@MainActor
final class GoogleCalendarAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var browserSession: ASWebAuthenticationSession?
    private var attempt: UUID?
    private weak var window: NSWindow?

    func signIn(url: URL, nonce: UUID, presenting window: NSWindow) async throws {
        guard GoogleCalendarSync.isManagedAuthorizationURL(url) else { throw GoogleCalendarError.signIn }
        attempt = nonce
        self.window = window
        let scheme = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "aidictation-dev" : "aidictation"
        let operation = MacBoundedNativeOperation<Bool>(cancelNative: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel(nonce) }
        })
        _ = try await operation.run(timeoutNanoseconds: 180_000_000_000) { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == nonce else { completion(.failure(CancellationError())); return }
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callback, error in
                    Task { @MainActor [weak self] in
                        guard let self, self.attempt == nonce else { return }
                        self.browserSession = nil
                        self.attempt = nil
                        if let callback, GoogleCalendarSync.isAuthorizationCallback(callback, scheme: scheme, nonce: nonce) {
                            completion(.success(true))
                        } else { completion(.failure(error ?? GoogleCalendarError.signIn)) }
                    }
                }
                browser.presentationContextProvider = self
                self.browserSession = browser
                if !browser.start() {
                    self.browserSession = nil
                    self.attempt = nil
                    completion(.failure(GoogleCalendarError.signIn))
                }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? NSWindow()
    }

    func cancel() { if let attempt { cancel(attempt) } }

    private func cancel(_ id: UUID) {
        guard attempt == id else { return }
        attempt = nil
        let session = browserSession
        browserSession = nil
        session?.cancel()
    }
}
