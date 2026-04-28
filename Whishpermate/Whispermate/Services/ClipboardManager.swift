import AppKit
import CoreGraphics

class ClipboardManager {
    private static var previousApp: NSRunningApplication?
    private static var clipboardRestoreWorkItem: DispatchWorkItem?

    static func storePreviousApp() {
        // Store the currently active app (before WhisperMate gets focus)
        let workspace = NSWorkspace.shared
        if let activeApp = workspace.frontmostApplication {
            previousApp = activeApp
            DebugLog.info("Stored previous app: \(activeApp.localizedName ?? "unknown")", context: "ClipboardManager")
        }
    }

    /// Schedule clipboard restore, cancelling any pending restore from previous operation
    private static func scheduleClipboardRestore(_ original: String?, pasteboard: NSPasteboard) {
        // Cancel any pending restore from previous operation to prevent race conditions
        clipboardRestoreWorkItem?.cancel()
        clipboardRestoreWorkItem = nil

        guard let original = original else {
            DebugLog.info("No original clipboard content to restore", context: "ClipboardManager")
            return
        }

        let workItem = DispatchWorkItem {
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
            DebugLog.info("Restored original clipboard content", context: "ClipboardManager")
        }
        clipboardRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    static func copyAndPaste(_ text: String) {
        DebugLog.info("========================================", context: "ClipboardManager")
        DebugLog.info("copyAndPaste called", context: "ClipboardManager")
        DebugLog.info("Text length: \(text.count) characters", context: "ClipboardManager")

        // Cancel any pending clipboard restore from previous operation
        clipboardRestoreWorkItem?.cancel()
        clipboardRestoreWorkItem = nil

        // Check accessibility permissions early
        let trusted = AXIsProcessTrusted()
        DebugLog.info("Accessibility trusted: \(trusted)", context: "ClipboardManager")

        if !trusted {
            DebugLog.info("⚠️ WARNING: Accessibility permissions not granted!", context: "ClipboardManager")
            // Just copy to clipboard without pasting (prevents beep)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            DebugLog.info("⚠️ Only copied to clipboard (no paste - permissions needed)", context: "ClipboardManager")
            return
        }

        // Check if we need to add a space before pasting.
        // Only add it when Accessibility can prove there is non-whitespace text
        // immediately before the insertion point. Unknown context should paste as-is.
        var textToPaste = text
        let focusedElement = getFocusedTextElement()
        if focusedElement == nil {
            DebugLog.info("⚠️ No focused text element detected (may be web contenteditable), will attempt paste anyway", context: "ClipboardManager")
        }

        if let focusedElement {
            if shouldAddLeadingSpaceBeforePaste(in: focusedElement) {
                textToPaste = " " + text
                DebugLog.info("✅ Added space before text", context: "ClipboardManager")
            } else {
                DebugLog.info("ℹ️ No leading space added", context: "ClipboardManager")
            }
        } else {
            DebugLog.info("ℹ️ Could not get focused element, pasting without leading space", context: "ClipboardManager")
        }

        let pasteboard = NSPasteboard.general

        // Store original clipboard content
        let originalContent = pasteboard.string(forType: .string)
        DebugLog.info("Stored original clipboard content: \(originalContent != nil ? "yes (\(originalContent!.count) chars)" : "none")", context: "ClipboardManager")

        // Copy transcription to clipboard (use the prepared text with space if needed)
        pasteboard.clearContents()
        let success = pasteboard.setString(textToPaste, forType: .string)
        DebugLog.info("Clipboard set success: \(success)", context: "ClipboardManager")

        // Verify clipboard contents
        if let clipboardContent = pasteboard.string(forType: .string) {
            DebugLog.info("Clipboard verification: \(clipboardContent.prefix(50))...", context: "ClipboardManager")
        } else {
            DebugLog.info("ERROR: Failed to verify clipboard contents!", context: "ClipboardManager")
        }

        // Get the app to paste into
        let targetApp = previousApp ?? NSWorkspace.shared.frontmostApplication
        DebugLog.info("Target app for paste: \(targetApp?.localizedName ?? "unknown")", context: "ClipboardManager")

        // Activate the target app first
        if let app = targetApp {
            DebugLog.info("Activating target app: \(app.localizedName ?? "unknown")", context: "ClipboardManager")
            app.activate(options: [])

            // Wait for app to become active, then paste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                DebugLog.info("Delay complete, simulating paste...", context: "ClipboardManager")
                simulatePaste()

                // Schedule clipboard restore (cancellable if another paste starts)
                scheduleClipboardRestore(originalContent, pasteboard: pasteboard)
                previousApp = nil // Clear stored app
            }
        } else {
            DebugLog.info("⚠️ No target app - skipping paste to avoid beep", context: "ClipboardManager")
            previousApp = nil
        }
    }

    private static func simulatePaste() {
        DebugLog.info("simulatePaste started", context: "ClipboardManager")

        // Suppress Fn key detection to avoid spurious events from Cmd+V
        HotkeyManager.shared.suppressFnKeyDetection()

        // Check accessibility permissions
        let trusted = AXIsProcessTrusted()
        DebugLog.info("Accessibility trusted: \(trusted)", context: "ClipboardManager")

        if !trusted {
            DebugLog.info("⚠️ WARNING: Accessibility permissions not granted!", context: "ClipboardManager")
            DebugLog.info("Paste may not work without accessibility access", context: "ClipboardManager")
        }

        // Simulate Cmd+V keypress
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            DebugLog.info("ERROR: Failed to create CGEventSource", context: "ClipboardManager")
            return
        }

        DebugLog.info("Creating keyboard events...", context: "ClipboardManager")

        // Key codes
        let cmdKeyCode: CGKeyCode = 0x37 // Left Command
        let vKeyCode: CGKeyCode = 0x09 // V key

        // Create Cmd key down event
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true) else {
            DebugLog.info("ERROR: Failed to create cmdDown event", context: "ClipboardManager")
            return
        }
        cmdDown.flags = .maskCommand

        // Create V key down event with Cmd modifier
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else {
            DebugLog.info("ERROR: Failed to create vDown event", context: "ClipboardManager")
            return
        }
        vDown.flags = .maskCommand

        // Create V key up event with Cmd modifier
        guard let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            DebugLog.info("ERROR: Failed to create vUp event", context: "ClipboardManager")
            return
        }
        vUp.flags = .maskCommand

        // Create Cmd key up event
        guard let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false) else {
            DebugLog.info("ERROR: Failed to create cmdUp event", context: "ClipboardManager")
            return
        }

        DebugLog.info("Events created successfully", context: "ClipboardManager")
        DebugLog.info("Posting events to system...", context: "ClipboardManager")

        // Post events in sequence with small delays
        let loc = CGEventTapLocation.cghidEventTap

        cmdDown.post(tap: loc)
        DebugLog.info("Posted: Cmd down", context: "ClipboardManager")

        usleep(1000) // 1ms delay
        vDown.post(tap: loc)
        DebugLog.info("Posted: V down", context: "ClipboardManager")

        usleep(1000) // 1ms delay
        vUp.post(tap: loc)
        DebugLog.info("Posted: V up", context: "ClipboardManager")

        usleep(1000) // 1ms delay
        cmdUp.post(tap: loc)
        DebugLog.info("Posted: Cmd up", context: "ClipboardManager")

        DebugLog.info("All events posted successfully", context: "ClipboardManager")
        DebugLog.info("========================================", context: "ClipboardManager")
    }

    /// Move cursor forward N characters (Right Arrow N times), then delete N characters backwards
    /// Used to replace previously selected text (selection lost when switching apps)
    static func moveForwardAndDelete(characterCount: Int, completion: @escaping () -> Void) {
        DebugLog.info("moveForwardAndDelete: Moving \(characterCount) chars forward then deleting", context: "ClipboardManager")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            DebugLog.info("ERROR: Failed to create CGEventSource", context: "ClipboardManager")
            completion()
            return
        }

        let rightArrowKeyCode: CGKeyCode = 0x7C // Right arrow
        let deleteKeyCode: CGKeyCode = 0x33 // Backspace/Delete
        let loc = CGEventTapLocation.cghidEventTap

        // CGEvent must be posted from main thread for thread safety
        DispatchQueue.main.async {
            // First, move cursor forward to the end of the original selection
            for _ in 0 ..< characterCount {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: rightArrowKeyCode, keyDown: true) else { continue }
                keyDown.post(tap: loc)

                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: rightArrowKeyCode, keyDown: false) else { continue }
                keyUp.post(tap: loc)

                usleep(300) // 0.3ms between each key
            }

            usleep(10000) // 10ms pause before deleting

            // Now delete backwards the same number of characters
            for _ in 0 ..< characterCount {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true) else { continue }
                keyDown.post(tap: loc)

                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false) else { continue }
                keyUp.post(tap: loc)

                usleep(300) // 0.3ms between each key
            }

            DebugLog.info("moveForwardAndDelete: Delete complete", context: "ClipboardManager")
            completion()
        }
    }

    /// Delete N characters backwards from cursor (Backspace N times)
    /// Used to delete the last dictation text before pasting replacement
    static func deleteBackwards(characterCount: Int, completion: @escaping () -> Void) {
        DebugLog.info("deleteBackwards: Deleting \(characterCount) characters", context: "ClipboardManager")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            DebugLog.info("ERROR: Failed to create CGEventSource", context: "ClipboardManager")
            completion()
            return
        }

        let deleteKeyCode: CGKeyCode = 0x33 // Backspace/Delete
        let loc = CGEventTapLocation.cghidEventTap

        // CGEvent must be posted from main thread for thread safety
        DispatchQueue.main.async {
            for _ in 0 ..< characterCount {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true) else { continue }
                keyDown.post(tap: loc)

                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false) else { continue }
                keyUp.post(tap: loc)

                usleep(300) // 0.3ms between each key
            }

            DebugLog.info("deleteBackwards: Delete complete", context: "ClipboardManager")
            completion()
        }
    }

    /// Paste text replacing any selected text (used for command mode transformations)
    /// Unlike copyAndPaste, this doesn't add leading space - just replaces selection directly
    static func replaceSelectionAndPaste(_ text: String) {
        DebugLog.info("========================================", context: "ClipboardManager")
        DebugLog.info("replaceSelectionAndPaste called", context: "ClipboardManager")
        DebugLog.info("Text length: \(text.count) characters", context: "ClipboardManager")

        // Cancel any pending clipboard restore from previous operation
        clipboardRestoreWorkItem?.cancel()
        clipboardRestoreWorkItem = nil

        // Check accessibility permissions early
        let trusted = AXIsProcessTrusted()
        DebugLog.info("Accessibility trusted: \(trusted)", context: "ClipboardManager")

        if !trusted {
            DebugLog.info("⚠️ WARNING: Accessibility permissions not granted!", context: "ClipboardManager")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            DebugLog.info("⚠️ Only copied to clipboard (no paste - permissions needed)", context: "ClipboardManager")
            return
        }

        let pasteboard = NSPasteboard.general

        // Store original clipboard content
        let originalContent = pasteboard.string(forType: .string)
        DebugLog.info("Stored original clipboard content: \(originalContent != nil ? "yes (\(originalContent!.count) chars)" : "none")", context: "ClipboardManager")

        // Copy text to clipboard (no space added - we're replacing selection)
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        DebugLog.info("Clipboard set success: \(success)", context: "ClipboardManager")

        // Get the app to paste into
        let targetApp = previousApp ?? NSWorkspace.shared.frontmostApplication
        DebugLog.info("Target app for paste: \(targetApp?.localizedName ?? "unknown")", context: "ClipboardManager")

        // Activate the target app first
        if let app = targetApp {
            DebugLog.info("Activating target app: \(app.localizedName ?? "unknown")", context: "ClipboardManager")
            app.activate(options: [])

            // Wait for app to become active, then paste
            // Cmd+V on selected text will replace it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                DebugLog.info("Delay complete, simulating paste (will replace selection)...", context: "ClipboardManager")
                simulatePaste()

                // Schedule clipboard restore (cancellable if another paste starts)
                scheduleClipboardRestore(originalContent, pasteboard: pasteboard)
                previousApp = nil
            }
        } else {
            DebugLog.info("⚠️ No target app - skipping paste", context: "ClipboardManager")
            previousApp = nil
        }
    }

    // MARK: - Accessibility Helpers

    private static func getFocusedTextElement() -> AXUIElement? {
        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()

        // Get the focused application
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute as CFString, &focusedApp)

        guard appResult == .success, let appElement = focusedApp else {
            DebugLog.info("Could not get focused application", context: "ClipboardManager")
            return nil
        }

        // Get the focused UI element in that application
        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(appElement as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard elementResult == .success else {
            DebugLog.info("Could not get focused UI element", context: "ClipboardManager")
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private static func getTextFromElement(_ element: AXUIElement) -> String? {
        // Try to get the value (text content) from the element
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)

        if result == .success, let text = value as? String {
            return text
        }

        DebugLog.info("Could not get text from element", context: "ClipboardManager")
        return nil
    }

    private static func getSelectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)

        guard result == .success,
              let value,
              AXValueGetType(value as! AXValue) == .cfRange
        else {
            return nil
        }

        var range = CFRange()
        let axValue = value as! AXValue
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func shouldAddLeadingSpaceBeforePaste(in element: AXUIElement) -> Bool {
        guard let existingText = getTextFromElement(element) else {
            DebugLog.info("Could not read focused text, pasting without leading space", context: "ClipboardManager")
            return false
        }

        let nsText = existingText as NSString
        guard nsText.length > 0 else {
            return false
        }

        guard let selectedRange = getSelectedTextRange(from: element) else {
            DebugLog.info("Could not read insertion point, pasting without leading space", context: "ClipboardManager")
            return false
        }
        let insertionLocation = max(0, min(selectedRange.location, nsText.length))

        guard insertionLocation > 0 else {
            return false
        }

        let textBeforeCursor = nsText.substring(to: insertionLocation)
        guard let previousScalar = textBeforeCursor.unicodeScalars.last else {
            return false
        }

        return !CharacterSet.whitespacesAndNewlines.contains(previousScalar)
    }
}
