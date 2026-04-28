import AppKit
import ApplicationServices
internal import Combine
import Foundation

/// Manages command mode for voice-based text transformation
/// Command mode allows users to speak instructions to transform selected text or last dictation
class CommandModeManager: ObservableObject {
    static let shared = CommandModeManager()

    // MARK: - Types

    enum TargetSource {
        case selectedText
        case none
    }

    // MARK: - Published Properties

    @Published var isActive: Bool = false
    @Published var targetText: String = ""
    @Published var isProcessing: Bool = false

    // MARK: - Public Properties

    /// Where the target text came from
    var targetSource: TargetSource = .none

    /// Length of the original selected text (for re-selecting it)
    var selectedTextLength: Int = 0

    // MARK: - Private Properties

    private let llmProviderManager = LLMProviderManager.shared

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Get target text for command mode from the selected text only.
    func getTargetText() -> (text: String, source: TargetSource)? {
        DebugLog.info("getTargetText() called", context: "CommandModeManager")

        // Try selected text via Accessibility API first
        if let selected = getSelectedTextSync(), !selected.isEmpty {
            DebugLog.info("Command mode: Using selected text (\(selected.count) chars)", context: "CommandModeManager")
            return (selected, .selectedText)
        }

        DebugLog.warning("Command mode: No selected text available", context: "CommandModeManager")
        return nil
    }

    /// Prepare for command mode recording
    func prepareForCommand() {
        // Capture target text before recording starts
        if let result = getTargetText() {
            targetText = result.text
            targetSource = result.source
            // Store length so we can re-select it after switching back to the app
            selectedTextLength = result.text.count
        } else {
            targetText = ""
            targetSource = .none
            selectedTextLength = 0
        }
        isActive = true
        DebugLog.info("Command mode prepared - source: \(targetSource), selectedTextLength: \(selectedTextLength), text: \(targetText.prefix(50))...", context: "CommandModeManager")
    }

    /// Execute an instruction - either transform selected text or generate new text
    /// - Parameters:
    ///   - instruction: The instruction (e.g., "make it shorter", "go to Downloads folder")
    ///   - selectedText: The text user has selected (can be empty)
    ///   - screenContext: OCR text extracted from the screen (can be nil)
    ///   - contextRules: Formatting rules from dictionary, shortcuts, and context rules (can be empty)
    /// - Returns: The result text, or nil on failure
    func executeInstruction(_ instruction: String, selectedText: String, screenContext: String?, contextRules: [String]) async -> String? {
        guard !instruction.isEmpty else {
            DebugLog.warning("Command mode: Empty instruction", context: "CommandModeManager")
            return nil
        }

        DebugLog.info("Command mode: Executing instruction: '\(instruction)'", context: "CommandModeManager")
        DebugLog.info("Command mode: Selected text: '\(selectedText.isEmpty ? "(empty)" : String(selectedText.prefix(100)))'", context: "CommandModeManager")
        DebugLog.info("Command mode: Screen context: '\(screenContext == nil ? "(none)" : String(screenContext!.prefix(200)))'", context: "CommandModeManager")
        DebugLog.info("Command mode: Context rules: \(contextRules.count) rules", context: "CommandModeManager")

        await MainActor.run {
            self.isProcessing = true
        }

        defer {
            Task { @MainActor in
                self.isProcessing = false
                self.isActive = false
            }
        }

        do {
            // Get LLM API key
            guard let apiKey = resolvedLLMApiKey() else {
                DebugLog.error("Command mode: No LLM API key configured", context: "CommandModeManager")
                return nil
            }

            // Build the prompt based on whether we have selected text
            let systemPrompt: String
            let userContent: String

            // Build screen context section
            let contextSection = screenContext.map { "<screen_context>\n\($0)\n</screen_context>\n\n" } ?? ""

            // Build context rules section
            let rulesSection = contextRules.isEmpty ? "" : "<formatting_rules>\n\(contextRules.joined(separator: "\n"))\n</formatting_rules>\n\n"

            if !selectedText.isEmpty {
                // Transform mode: modify selected text
                systemPrompt = """
                You are a text transformation assistant.
                The user message contains:
                - <screen_context>: Information about the user's current screen (app, window title, or OCR text)
                - <formatting_rules>: Rules for vocabulary, phrases, and formatting to follow
                - <selected_text>: The text the user has selected
                - <instruction>: The transformation to apply

                Apply the instruction to transform the selected text.
                Follow any formatting rules provided (vocabulary, phrases, style).
                Return ONLY the transformed text, nothing else.
                Do not add explanations, quotes, or formatting - just the transformed text. Keep the same voice unless stated otherwise.
                """

                userContent = """
                \(contextSection)\(rulesSection)<selected_text>
                \(selectedText)
                </selected_text>

                <instruction>
                \(instruction)
                </instruction>
                """
            } else {
                // Generation mode: create new text based on instruction and context
                systemPrompt = """
                You are a command assistant that generates text output based on user instructions.
                The user message contains:
                - <screen_context>: Information about the user's current screen (app, window title, or OCR text)
                - <formatting_rules>: Rules for vocabulary, phrases, and formatting to follow
                - <instruction>: The user's instruction for what to generate

                Use the screen context to generate the most relevant response to the instruction.
                Follow any formatting rules provided (vocabulary, phrases, style).
                Return ONLY the output text, nothing else.
                Do not add explanations, quotes, markdown formatting, or code blocks - just the raw text to be typed.
                For terminal/shell contexts, output shell commands. For code editors, output code. For text apps, output text.
                """

                userContent = """
                \(contextSection)\(rulesSection)<instruction>
                \(instruction)
                </instruction>
                """
            }

            // Create OpenAI client for LLM call - use 120B model for command mode
            let config = OpenAIClient.Configuration(
                transcriptionEndpoint: "",
                transcriptionModel: "",
                chatCompletionEndpoint: "https://api.groq.com/openai/v1/chat/completions",
                chatCompletionModel: "openai/gpt-oss-120b",
                apiKey: apiKey
            )

            let client = OpenAIClient(config: config)

            let messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ]

            // Log the full prompt being sent
            DebugLog.info("Command mode prompt - System: \(systemPrompt)", context: "CommandModeManager")
            DebugLog.info("Command mode prompt - User: \(userContent)", context: "CommandModeManager")

            let result = try await client.chatCompletion(
                messages: messages,
                temperature: 0.3,
                maxTokens: 2000
            )

            DebugLog.info("Command mode: Transformation complete (\(result.count) chars)", context: "CommandModeManager")
            DebugLog.info("Command mode result: \(result)", context: "CommandModeManager")
            return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        } catch {
            DebugLog.error("Command mode: Transformation failed - \(error.localizedDescription)", context: "CommandModeManager")
            return nil
        }
    }

    /// Reset command mode state
    func reset() {
        isActive = false
        targetText = ""
        targetSource = .none
        selectedTextLength = 0
        isProcessing = false
    }

    // MARK: - Private Methods

    private func getSelectedTextSync() -> String? {
        // Try system-wide accessibility API (fast, non-blocking)
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let errorCode = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if errorCode == .success, let element = focusedElement {
            var selectedText: AnyObject?
            let textErrorCode = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)

            if textErrorCode == .success, let text = selectedText as? String, !text.isEmpty {
                DebugLog.info("getSelectedTextSync: Got text via AX API (\(text.count) chars)", context: "CommandModeManager")
                return text
            }
        }

        // AX API didn't return text.
        DebugLog.info("getSelectedTextSync: AX API returned no text", context: "CommandModeManager")
        return nil
    }

    private func resolvedLLMApiKey() -> String? {
        let provider = llmProviderManager.selectedProvider

        // Check Secrets.plist first
        if let secretKey = SecretsLoader.llmKey(for: provider), !secretKey.isEmpty {
            return secretKey
        }

        // Then check keychain
        if let storedKey = KeychainHelper.get(key: provider.apiKeyName), !storedKey.isEmpty {
            return storedKey
        }

        return nil
    }
}
