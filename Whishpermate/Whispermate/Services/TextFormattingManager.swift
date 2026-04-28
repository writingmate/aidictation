import AppKit
import ApplicationServices
import Foundation

class TextFormattingManager {
    static let shared = TextFormattingManager()

    private var isProcessing = false
    private let openAIClient: OpenAIClient

    private init() {
        // Initialize with default configuration
        let transcriptionProviderManager = TranscriptionProviderManager.shared
        let llmProviderManager = LLMProviderManager.shared

        let config = OpenAIClient.Configuration(
            transcriptionEndpoint: transcriptionProviderManager.effectiveEndpoint,
            transcriptionModel: transcriptionProviderManager.effectiveModel,
            chatCompletionEndpoint: llmProviderManager.effectiveEndpoint,
            chatCompletionModel: llmProviderManager.effectiveModel,
            apiKey: llmProviderManager.effectiveApiKey ?? ""
        )

        openAIClient = OpenAIClient(config: config)
    }

    /// Update the OpenAI client configuration (e.g., when settings change)
    func updateConfiguration(_ config: OpenAIClient.Configuration) {
        openAIClient.updateConfig(config)
    }

    /// Main entry point: Get selected text, format it, and replace
    func formatSelectedText() async {
        guard !isProcessing else {
            DebugLog.warning("Text formatting already in progress", context: "TextFormattingManager")
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        do {
            // Step 1: Get selected text from active app
            guard let selectedText = try await getSelectedText() else {
                DebugLog.warning("No text selected", context: "TextFormattingManager")
                showNotification(title: "No Text Selected", message: "Please select some text first")
                return
            }

            guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DebugLog.warning("Selected text is empty", context: "TextFormattingManager")
                showNotification(title: "Empty Selection", message: "Selected text is empty")
                return
            }

            DebugLog.info("Got selected text: \(selectedText.prefix(50))...", context: "TextFormattingManager")

            // Step 2: Get enabled formatting rules
            let enabledRules = PromptRulesManager.shared.rules.filter { $0.isEnabled }.map { $0.text }

            guard !enabledRules.isEmpty else {
                DebugLog.warning("No formatting rules enabled", context: "TextFormattingManager")
                showNotification(title: "No Rules Enabled", message: "Enable formatting rules in Settings first")
                return
            }

            DebugLog.info("Applying \(enabledRules.count) formatting rules", context: "TextFormattingManager")

            // Step 3: Send to LLM for formatting
            let formattedText = try await openAIClient.applyFormattingRules(
                transcription: selectedText,
                rules: enabledRules
            )

            DebugLog.info("Got formatted text: \(formattedText.prefix(50))...", context: "TextFormattingManager")

            // Step 4: Replace selected text with formatted version
            try await replaceSelectedText(with: formattedText)

            DebugLog.info("Successfully replaced text", context: "TextFormattingManager")

        } catch {
            DebugLog.error("Text formatting failed: \(error)", context: "TextFormattingManager")
            showNotification(title: "Formatting Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Text Selection via Accessibility API

    private func getSelectedText() async throws -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                // Get the system-wide focused element
                var focusedApp: AXUIElement?

                // Get the frontmost application
                if let frontApp = NSWorkspace.shared.frontmostApplication {
                    focusedApp = AXUIElementCreateApplication(frontApp.processIdentifier)
                }

                guard let app = focusedApp else {
                    DebugLog.warning("No focused app found", context: "TextFormattingManager")
                    continuation.resume(returning: nil)
                    return
                }

                // Get focused UI element
                var focusedElement: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement)

                guard result == .success, let element = focusedElement else {
                    DebugLog.warning("No focused element found", context: "TextFormattingManager")
                    continuation.resume(returning: nil)
                    return
                }

                // Try to get selected text
                var selectedText: CFTypeRef?
                let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)

                if textResult == .success, let text = selectedText as? String {
                    continuation.resume(returning: text)
                } else {
                    DebugLog.warning("Could not get selected text, result: \(textResult.rawValue)", context: "TextFormattingManager")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Text Replacement

    private func replaceSelectedText(with newText: String) async throws {
        // Method 1: Try using Accessibility API to set selected text range
        let success = await tryReplaceViaAccessibility(with: newText)

        if !success {
            await replaceViaDirectInsertion(with: newText)
        }
    }

    private func tryReplaceViaAccessibility(with newText: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                // Get the frontmost application
                guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                    continuation.resume(returning: false)
                    return
                }

                let app = AXUIElementCreateApplication(frontApp.processIdentifier)

                // Get focused UI element
                var focusedElement: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement)

                guard result == .success, let element = focusedElement else {
                    continuation.resume(returning: false)
                    return
                }

                // Try to set the selected text value directly
                let setResult = AXUIElementSetAttributeValue(
                    element as! AXUIElement,
                    kAXSelectedTextAttribute as CFString,
                    newText as CFString
                )

                if setResult == .success {
                    DebugLog.info("Successfully replaced text via Accessibility API", context: "TextFormattingManager")
                    continuation.resume(returning: true)
                } else {
                    DebugLog.warning("Could not replace via Accessibility API, code: \(setResult.rawValue)", context: "TextFormattingManager")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func replaceViaDirectInsertion(with newText: String) async {
        await MainActor.run {
            ClipboardManager.replaceSelectionAndPaste(newText)
        }

        DebugLog.info("Replaced text via direct insertion fallback", context: "TextFormattingManager")
    }

    // MARK: - Notifications

    private func showNotification(title: String, message: String) {
        DispatchQueue.main.async {
            let notification = NSUserNotification()
            notification.title = title
            notification.informativeText = message
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
}
