import AppKit
import ApplicationServices
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

/// Opens the support troubleshooting prompt in an installed desktop AI app
/// that has local access to this Mac, then pastes the prompt into its composer
/// once the app is frontmost. Web chat sites are never opened: the prompt only
/// works for an agent that can read logs, permissions, and the app install on
/// this computer. The prompt is always copied to the clipboard first so the
/// user can paste it themselves if the automatic paste cannot run.
final class SupportPromptManager {
    // MARK: - Types

    /// Desktop AI apps the troubleshooting prompt can be opened in.
    enum Destination: String, CaseIterable, Identifiable {
        case chatGPT = "ChatGPT"
        case claude = "Claude"

        var id: String { rawValue }
    }

    /// How the prompt was delivered, so the UI can word its confirmation.
    enum Outcome {
        /// The app is open; `pasted` says whether the prompt landed in its composer.
        case openedApp(pasted: Bool)
        /// No desktop app found. The website is deliberately not opened.
        case appNotInstalled
        case failed
    }

    /// One place an installed destination may be found, tried in order.
    private enum AppLocator {
        /// Registered bundle. `appName` further requires the resolved bundle
        /// to carry that name, for identifiers shared with other products.
        case bundleIdentifier(String, appName: String? = nil)
        case path(String)
    }

    // MARK: - Constants

    private enum Constants {
        static let context = "SupportPromptManager"

        /// How long to wait for the opened app to become frontmost. Cold
        /// launches of Electron apps can take a couple of seconds.
        static let activationTimeout: TimeInterval = 4.0
        static let activationPollInterval: TimeInterval = 0.1
        /// Extra time after activation for the window and composer to take focus.
        static let composerSettleDelay: TimeInterval = 0.7
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

    /// Copies the prompt, then opens the installed desktop app for
    /// `destination` and pastes the prompt into it once it is frontmost. If the
    /// app is not installed nothing is opened; the prompt stays on the
    /// clipboard. `completion` runs on the main actor, after the paste attempt.
    func open(_ destination: Destination, completion: @escaping @MainActor (Outcome) -> Void) {
        copyPrompt()

        guard let appURL = installedApplicationURL(for: destination) else {
            DebugLog.info("\(destination.rawValue) desktop app not installed; leaving prompt on clipboard", context: Constants.context)
            completion(.appNotInstalled)
            return
        }

        DebugLog.info("Launching \(destination.rawValue) app at \(appURL.path)", context: Constants.context)
        launchApplication(at: appURL, completion: completion)
    }

    // MARK: - Private Methods

    /// Launches the app with no URL at all. Handing the app a web URL is what
    /// let the prompt leak into the default browser: apps that register https
    /// forward URLs they do not show in-window to the system browser. The paste
    /// after activation is the only way the prompt reaches the composer, which
    /// also means it can never be inserted twice.
    private func launchApplication(at appURL: URL, completion: @escaping @MainActor (Outcome) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { runningApp, error in
            Task { @MainActor in
                if let error {
                    DebugLog.error("Could not launch \(appURL.lastPathComponent): \(error.localizedDescription)", context: Constants.context)
                    completion(.failed)
                } else {
                    self.pasteWhenFrontmost(runningApp, appURL: appURL, completion: completion)
                }
            }
        }
    }

    /// Waits for the opened app to become frontmost, lets its composer take
    /// focus, then pastes the prompt through `ClipboardManager`. The target is
    /// pinned only once the chat app is in front, so the paste can never land
    /// back in AI Dictation or in an app left over from an earlier dictation.
    private func pasteWhenFrontmost(_ runningApp: NSRunningApplication?, appURL: URL, completion: @escaping @MainActor (Outcome) -> Void) {
        let deadline = Date().addingTimeInterval(Constants.activationTimeout)

        Task { @MainActor in
            while !self.isFrontmost(runningApp, appURL: appURL) {
                guard Date() < deadline else {
                    DebugLog.warning("\(appURL.lastPathComponent) did not come to the front in time; leaving prompt on clipboard", context: Constants.context)
                    completion(.openedApp(pasted: false))
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(Constants.activationPollInterval * 1_000_000_000))
            }

            try? await Task.sleep(nanoseconds: UInt64(Constants.composerSettleDelay * 1_000_000_000))

            guard self.isFrontmost(runningApp, appURL: appURL) else {
                DebugLog.warning("\(appURL.lastPathComponent) lost focus before paste; leaving prompt on clipboard", context: Constants.context)
                completion(.openedApp(pasted: false))
                return
            }

            guard AXIsProcessTrusted() else {
                DebugLog.warning("Accessibility permission missing; cannot paste prompt into \(appURL.lastPathComponent)", context: Constants.context)
                completion(.openedApp(pasted: false))
                return
            }

            ClipboardManager.storePreviousApp()
            ClipboardManager.replaceSelectionAndPaste(SupportContent.agentPrompt)
            DebugLog.info("Pasted support prompt into \(appURL.lastPathComponent)", context: Constants.context)
            completion(.openedApp(pasted: true))
        }
    }

    /// True when the opened app owns the front window. Matches by process
    /// first, then by bundle location in case the launch handed back a
    /// different process than the one now in front.
    private func isFrontmost(_ runningApp: NSRunningApplication?, appURL: URL) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != NSRunningApplication.current.processIdentifier
        else {
            return false
        }
        if let runningApp, frontmost.processIdentifier == runningApp.processIdentifier {
            return true
        }
        return frontmost.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
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
            ]
        case .claude:
            return [
                .bundleIdentifier("com.anthropic.claudefordesktop"),
                .path("/Applications/Claude.app"),
            ]
        }
    }
}
