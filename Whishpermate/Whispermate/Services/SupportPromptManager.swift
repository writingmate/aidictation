import AppKit
import Foundation

// MARK: - Support Content

/// User-facing support material shown in Settings → Support.
enum SupportContent {
    static let email = "hello@aidictation.com"

    static var mailURL: URL? {
        URL(string: "mailto:\(email)")
    }

    /// Prompt users hand to an AI coding agent (Cursor, Claude, etc.) so it
    /// investigates a problem on this machine in a safe, step-by-step way.
    /// This wording is locked by Support; do not edit without their sign-off.
    static let agentPrompt = """
    You are helping me fix AI Dictation on this computer.

    ## Hard rules (do these in order)

    1. **Prove you have local access to THIS computer** before anything else.
       - Run a real local command (for example: `hostname`, `sw_vers` on Mac, or `systeminfo` on Windows) and show the output.
       - If you are a cloud-only agent with no local shell/desktop on my machine, STOP. Tell me to paste this same prompt into Cursor, Claude Code, or Grok Bot running on my laptop. Do not guess.

    2. **Ask me what problem we are trying to solve**, then wait for my answer.
       - One short question. Do not start diagnosing yet.

    3. **After I answer, explain your plan in plain English** (what you will check or change, and why).
       - Get my **explicit yes** before you change anything (settings, permissions, files, reinstalls, kills).
       - Read-only checks are fine after I describe the problem; writes need yes.

    4. **Then diagnose with tools.** Prefer facts over questions.
       - Ask at most one short clarifying question only when you are blocked.
       - Prefer updating AI Dictation to the **latest available version** when an update might help. Do **not** hardcode or recommend a specific build number; just make sure I am on the newest release the app offers (or the official download site).

    ## Useful places (Mac)
    - App: `/Applications/AIDictation.app` (or wherever it is installed)
    - Logs: `~/Library/Logs/AIDictation`
    - Permissions: System Settings → Privacy & Security (Microphone, Accessibility, Input Monitoring, Screen Recording if relevant)

    ## Useful places (Windows)
    - Installed app folder / Start Menu entry for AI Dictation
    - App logs under the user’s AppData if present
    - Privacy settings for microphone / accessibility equivalents

    ## When you are done
    Summarize: what was wrong, what you changed (if anything), and what I should try next. If you cannot fix it, package a short tech dump (OS version, app version, relevant logs, permission state) I can email to support.
    """
}

// MARK: - Support Prompt Manager

/// Opens the support troubleshooting prompt in an installed chat app (native
/// app or browser-installed web app), falling back to the default browser only
/// when nothing is installed. The prompt is always copied to the clipboard
/// first so the user can paste it if a destination ignores the prefill.
final class SupportPromptManager {
    // MARK: - Types

    /// Chat services the troubleshooting prompt can be opened in.
    enum Destination: String, CaseIterable, Identifiable {
        case chatGPT = "ChatGPT"
        case claude = "Claude"
        case writingmate = "Writingmate"
        case gemini = "Gemini"

        var id: String { rawValue }
    }

    /// How the prompt was delivered, so the UI can word its confirmation.
    enum Outcome {
        case openedApp
        case openedBrowser
        case failed
    }

    /// One place an installed destination may be found, tried in order.
    private enum AppLocator {
        /// Registered bundle. `appName` further requires the resolved bundle
        /// to carry that name, for identifiers shared with other products.
        case bundleIdentifier(String, appName: String? = nil)
        case path(String)
        /// A web app shortcut (Chrome, Edge, Brave) in the user's Applications folder.
        case webApp(named: String)
    }

    // MARK: - Constants

    private enum Constants {
        static let context = "SupportPromptManager"

        /// Folders browsers use for installed web app shortcuts under ~/Applications.
        static let webAppFolders = [
            "Chrome Apps.localized",
            "Chrome Apps",
            "Edge Apps.localized",
            "Brave Browser Apps.localized",
        ]

        /// Unreserved characters only (RFC 3986). `.urlQueryAllowed` leaves `&`,
        /// `=`, and `+` unescaped, which would cut the prompt off at its first
        /// ampersand when it travels as a query value.
        static let queryValueAllowed: CharacterSet = {
            var set = CharacterSet.alphanumerics
            set.insert(charactersIn: "-._~")
            return set
        }()
    }

    // MARK: - Initialization

    static let shared = SupportPromptManager()

    private init() {}

    // MARK: - Public API

    /// Puts the locked prompt on the clipboard.
    func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SupportContent.agentPrompt, forType: .string)
    }

    /// Copies the prompt, then opens `destination`, preferring an installed app
    /// over the browser. `completion` runs on the main actor.
    func open(_ destination: Destination, completion: @escaping @MainActor (Outcome) -> Void) {
        copyPrompt()

        if let appURL = installedApplicationURL(for: destination) {
            DebugLog.info("Opening \(destination.rawValue) app at \(appURL.path)", context: Constants.context)
            openInApplication(at: appURL, url: inAppURL(for: destination), completion: completion)
            return
        }

        guard let webURL = webURL(for: destination) else {
            DebugLog.error("No app or web URL for \(destination.rawValue)", context: Constants.context)
            completion(.failed)
            return
        }

        DebugLog.info("\(destination.rawValue) app not installed; opening in browser", context: Constants.context)
        NSWorkspace.shared.open(webURL)
        completion(.openedBrowser)
    }

    // MARK: - Private Methods

    /// Hands `url` to the app so a browser cannot claim it. If the app rejects
    /// the URL (for example an unregistered scheme), the app is launched on its
    /// own and the clipboard copy carries the prompt.
    private func openInApplication(at appURL: URL, url: URL?, completion: @escaping @MainActor (Outcome) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let url else {
            launchApplication(at: appURL, configuration: configuration, completion: completion)
            return
        }

        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    DebugLog.warning("App declined URL (\(error.localizedDescription)); launching app without it", context: Constants.context)
                    self.launchApplication(at: appURL, configuration: configuration, completion: completion)
                } else {
                    completion(.openedApp)
                }
            }
        }
    }

    private func launchApplication(at appURL: URL, configuration: NSWorkspace.OpenConfiguration, completion: @escaping @MainActor (Outcome) -> Void) {
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    DebugLog.error("Could not launch \(appURL.lastPathComponent): \(error.localizedDescription)", context: Constants.context)
                    completion(.failed)
                } else {
                    completion(.openedApp)
                }
            }
        }
    }

    private func installedApplicationURL(for destination: Destination) -> URL? {
        for locator in locators(for: destination) {
            switch locator {
            case let .bundleIdentifier(identifier, appName):
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { continue }
                if let appName, url.deletingPathExtension().lastPathComponent != appName { continue }
                return url
            case let .path(path):
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            case let .webApp(name):
                if let url = webAppURL(named: name) {
                    return url
                }
            }
        }
        return nil
    }

    private func webAppURL(named name: String) -> URL? {
        let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        for folder in Constants.webAppFolders {
            let candidate = applications.appendingPathComponent(folder).appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func locators(for destination: Destination) -> [AppLocator] {
        switch destination {
        case .chatGPT:
            // Some installs of ChatGPT.app report the Codex bundle identifier,
            // so that identifier only counts when the bundle is actually ChatGPT.
            return [
                .path("/Applications/ChatGPT.app"),
                .bundleIdentifier("com.openai.chat"),
                .bundleIdentifier("com.openai.codex", appName: "ChatGPT"),
                .webApp(named: "ChatGPT"),
            ]
        case .claude:
            return [
                .bundleIdentifier("com.anthropic.claudefordesktop"),
                .path("/Applications/Claude.app"),
                .webApp(named: "Claude"),
            ]
        case .writingmate:
            return [.webApp(named: "Writingmate")]
        case .gemini:
            return [.webApp(named: "Gemini"), .webApp(named: "Google Gemini")]
        }
    }

    private var percentEncodedPrompt: String? {
        SupportContent.agentPrompt.addingPercentEncoding(withAllowedCharacters: Constants.queryValueAllowed)
    }

    /// URL handed to the installed app: the app's own scheme for native apps,
    /// the web app's origin for browser-installed apps. Nil opens the app bare.
    private func inAppURL(for destination: Destination) -> URL? {
        switch destination {
        case .chatGPT:
            return percentEncodedPrompt.flatMap { URL(string: "chatgpt://?q=\($0)") }
        case .claude:
            return percentEncodedPrompt.flatMap { URL(string: "claude://new?q=\($0)") }
        case .writingmate:
            return percentEncodedPrompt.flatMap { URL(string: "https://new.writingmate.ai/new?q=\($0)") }
        case .gemini:
            // No documented prefill parameter; the clipboard carries the prompt.
            return URL(string: "https://gemini.google.com/app")
        }
    }

    /// Browser URL, used only when no app is installed.
    private func webURL(for destination: Destination) -> URL? {
        switch destination {
        case .chatGPT:
            return percentEncodedPrompt.flatMap { URL(string: "https://chatgpt.com/?q=\($0)") }
        case .claude:
            return percentEncodedPrompt.flatMap { URL(string: "https://claude.ai/new?q=\($0)") }
        case .writingmate:
            return percentEncodedPrompt.flatMap { URL(string: "https://new.writingmate.ai/new?q=\($0)") }
        case .gemini:
            return URL(string: "https://gemini.google.com/app")
        }
    }
}
