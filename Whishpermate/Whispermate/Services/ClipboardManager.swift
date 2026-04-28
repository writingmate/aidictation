import AppKit
import ApplicationServices
import CoreGraphics

class ClipboardManager {
    private static var previousApp: NSRunningApplication?
    private static let appActivationDelay: TimeInterval = 0.25
    private static let unicodeEventChunkLimit = 180

    static func storePreviousApp() {
        let workspace = NSWorkspace.shared
        if let activeApp = workspace.frontmostApplication {
            previousApp = activeApp
            DebugLog.info("Stored previous app: \(activeApp.localizedName ?? "unknown")", context: "ClipboardManager")
        }
    }

    /// Insert dictated text without putting it on the system clipboard.
    static func copyAndPaste(_ text: String) {
        DebugLog.info("========================================", context: "ClipboardManager")
        DebugLog.info("copyAndPaste called; using clipboard-free insertion", context: "ClipboardManager")
        insertText(text, addLeadingSpace: true)
    }

    /// Insert replacement text without putting it on the system clipboard.
    static func replaceSelectionAndPaste(_ text: String) {
        DebugLog.info("========================================", context: "ClipboardManager")
        DebugLog.info("replaceSelectionAndPaste called; using clipboard-free insertion", context: "ClipboardManager")
        insertText(text, addLeadingSpace: false)
    }

    // MARK: - Direct Text Insertion

    private static func insertText(_ text: String, addLeadingSpace: Bool) {
        DebugLog.info("Text length: \(text.count) characters", context: "ClipboardManager")

        guard !text.isEmpty else {
            DebugLog.info("No text to insert", context: "ClipboardManager")
            previousApp = nil
            return
        }

        guard AXIsProcessTrusted() else {
            DebugLog.warning("Accessibility permission missing; refusing to use clipboard fallback", context: "ClipboardManager")
            previousApp = nil
            return
        }

        let targetApp = previousApp ?? NSWorkspace.shared.frontmostApplication
        DebugLog.info("Target app for direct insertion: \(targetApp?.localizedName ?? "unknown")", context: "ClipboardManager")

        guard let app = targetApp else {
            DebugLog.warning("No target app available for direct insertion", context: "ClipboardManager")
            previousApp = nil
            return
        }

        app.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + appActivationDelay) {
            let element = getFocusedTextElement(preferredApp: app)
            var textToInsert = text

            if addLeadingSpace, let element, shouldAddLeadingSpaceBeforePaste(in: element) {
                textToInsert = " " + text
                DebugLog.info("Added leading space before direct insertion", context: "ClipboardManager")
            }

            if let element, insertTextUsingSelectedRange(in: element, text: textToInsert) {
                DebugLog.info("Inserted text via AX selected range/value", context: "ClipboardManager")
                previousApp = nil
                return
            }

            let targetPid = app.processIdentifier
            if postUnicodeText(textToInsert, targetPID: targetPid) {
                DebugLog.info("Inserted text via Unicode CGEvents to PID \(targetPid)", context: "ClipboardManager")
            } else if postUnicodeText(textToInsert, targetPID: nil) {
                DebugLog.info("Inserted text via Unicode CGEvents to HID tap", context: "ClipboardManager")
            } else {
                DebugLog.error("Direct text insertion failed; clipboard fallback is disabled", context: "ClipboardManager")
            }

            previousApp = nil
        }
    }

    private static func insertTextUsingSelectedRange(in element: AXUIElement, text: String) -> Bool {
        guard let currentValue = getTextFromElement(element),
              var range = getSelectedTextRange(from: element)
        else {
            return false
        }

        let currentNSString = currentValue as NSString
        let maxLength = currentNSString.length
        let safeLocation = max(0, min(range.location, maxLength))
        let safeLength = max(0, min(range.length, maxLength - safeLocation))
        range = CFRange(location: safeLocation, length: safeLength)

        let updatedText = NSMutableString(string: currentValue)
        updatedText.replaceCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )

        let setValueResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedText as CFString
        )

        guard setValueResult == .success else {
            DebugLog.info("AX value insertion failed: \(setValueResult.rawValue)", context: "ClipboardManager")
            return false
        }

        let insertedLength = (text as NSString).length
        var newRange = CFRange(location: range.location + insertedLength, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                axRange
            )
        }

        return true
    }

    private static func postUnicodeText(_ text: String, targetPID: pid_t?) -> Bool {
        guard !text.isEmpty else { return true }

        let chunks = unicodeChunks(for: text)
        guard !chunks.isEmpty else { return false }

        for chunk in chunks {
            let utf16 = Array(chunk.utf16)
            guard !utf16.isEmpty,
                  let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

            if let targetPID {
                keyDown.postToPid(targetPID)
                usleep(2_000)
                keyUp.postToPid(targetPID)
            } else {
                keyDown.post(tap: .cghidEventTap)
                usleep(2_000)
                keyUp.post(tap: .cghidEventTap)
            }

            usleep(1_000)
        }

        return true
    }

    private static func unicodeChunks(for text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentLength = 0

        for character in text {
            let characterLength = String(character).utf16.count
            if currentLength > 0, currentLength + characterLength > unicodeEventChunkLimit {
                chunks.append(current)
                current = ""
                currentLength = 0
            }

            current.append(character)
            currentLength += characterLength
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    // MARK: - Cursor Editing Helpers

    /// Move cursor forward N characters (Right Arrow N times), then delete N characters backwards.
    /// Used to replace previously selected text when selection is lost while switching apps.
    static func moveForwardAndDelete(characterCount: Int, completion: @escaping () -> Void) {
        DebugLog.info("moveForwardAndDelete: Moving \(characterCount) chars forward then deleting", context: "ClipboardManager")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            DebugLog.info("ERROR: Failed to create CGEventSource", context: "ClipboardManager")
            completion()
            return
        }

        let rightArrowKeyCode: CGKeyCode = 0x7C
        let deleteKeyCode: CGKeyCode = 0x33
        let loc = CGEventTapLocation.cghidEventTap

        DispatchQueue.main.async {
            for _ in 0 ..< characterCount {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: rightArrowKeyCode, keyDown: true) else { continue }
                keyDown.post(tap: loc)

                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: rightArrowKeyCode, keyDown: false) else { continue }
                keyUp.post(tap: loc)

                usleep(300)
            }

            usleep(10_000)

            for _ in 0 ..< characterCount {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true) else { continue }
                keyDown.post(tap: loc)

                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false) else { continue }
                keyUp.post(tap: loc)

                usleep(300)
            }

            DebugLog.info("moveForwardAndDelete: Delete complete", context: "ClipboardManager")
            completion()
        }
    }

    /// Delete N characters backwards from cursor (Backspace N times).
    static func deleteBackwards(characterCount: Int, completion: @escaping () -> Void) {
        DebugLog.info("deleteBackwards: Deleting \(characterCount) characters", context: "ClipboardManager")

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            DebugLog.info("ERROR: Failed to create CGEventSource", context: "ClipboardManager")
            completion()
            return
        }

        let deleteKeyCode: CGKeyCode = 0x33
        let loc = CGEventTapLocation.cghidEventTap

        DispatchQueue.main.async {
            for _ in 0 ..< characterCount {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true) else { continue }
                keyDown.post(tap: loc)

                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false) else { continue }
                keyUp.post(tap: loc)

                usleep(300)
            }

            DebugLog.info("deleteBackwards: Delete complete", context: "ClipboardManager")
            completion()
        }
    }

    // MARK: - Accessibility Helpers

    private static func getFocusedTextElement(preferredApp: NSRunningApplication? = nil) -> AXUIElement? {
        if let preferredApp,
           let element = getFocusedTextElement(in: AXUIElementCreateApplication(preferredApp.processIdentifier))
        {
            return element
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            DebugLog.info("Could not get focused UI element", context: "ClipboardManager")
            return nil
        }

        return unsafeBitCast(focusedElement, to: AXUIElement.self)
    }

    private static func getFocusedTextElement(in appElement: AXUIElement) -> AXUIElement? {
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(focusedElement, to: AXUIElement.self)
    }

    private static func getTextFromElement(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)

        if result == .success, let text = value as? String {
            return text
        }

        DebugLog.info("Could not get text from element", context: "ClipboardManager")
        return nil
    }

    private static func getSelectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else {
            return nil
        }

        return range
    }

    private static func shouldAddLeadingSpaceBeforePaste(in element: AXUIElement) -> Bool {
        guard let existingText = getTextFromElement(element) else {
            DebugLog.info("Could not read focused text, inserting without leading space", context: "ClipboardManager")
            return false
        }

        let nsText = existingText as NSString
        guard nsText.length > 0 else {
            return false
        }

        guard let selectedRange = getSelectedTextRange(from: element) else {
            DebugLog.info("Could not read insertion point, inserting without leading space", context: "ClipboardManager")
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
