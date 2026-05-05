import AppKit
import ApplicationServices
import CoreGraphics

class ClipboardManager {
    private static var previousApp: NSRunningApplication?
    private static var clipboardRestoreWorkItem: DispatchWorkItem?
    private static var clipboardRestoreState: ClipboardRestoreState?
    private static let appActivationDelay: TimeInterval = 0.3
    private static let clipboardRestoreDelay: TimeInterval = 0.8
    private static let pasteKeyEventDelay: useconds_t = 10_000

    static func storePreviousApp() {
        let workspace = NSWorkspace.shared
        if let activeApp = workspace.frontmostApplication {
            previousApp = activeApp
            DebugLog.info("Stored previous app: \(activeApp.localizedName ?? "unknown")", context: "ClipboardManager")
        }
    }

    /// Insert dictated text through one cross-app path: temporary pasteboard + Cmd+V + guarded restore.
    static func copyAndPaste(_ text: String) {
        DebugLog.info("========================================", context: "ClipboardManager")
        DebugLog.info("copyAndPaste called; using guarded pasteboard insertion", context: "ClipboardManager")
        insertText(text, addBoundarySpaces: true)
    }

    /// Replace the current selection exactly, without adding boundary spaces.
    static func replaceSelectionAndPaste(_ text: String) {
        DebugLog.info("========================================", context: "ClipboardManager")
        DebugLog.info("replaceSelectionAndPaste called; using guarded pasteboard insertion", context: "ClipboardManager")
        insertText(text, addBoundarySpaces: false)
    }

    // MARK: - Pasteboard Insertion

    private static func insertText(_ text: String, addBoundarySpaces: Bool) {
        DebugLog.info("Text length: \(text.count) characters", context: "ClipboardManager")

        guard !text.isEmpty else {
            DebugLog.info("No text to insert", context: "ClipboardManager")
            previousApp = nil
            return
        }

        guard AXIsProcessTrusted() else {
            DebugLog.warning("Accessibility permission missing; cannot send Cmd+V", context: "ClipboardManager")
            previousApp = nil
            return
        }

        guard let app = previousApp ?? NSWorkspace.shared.frontmostApplication else {
            DebugLog.warning("No target app available for paste", context: "ClipboardManager")
            previousApp = nil
            return
        }

        let pasteboard = NSPasteboard.general
        let originalSnapshot = originalSnapshotForNewPaste(from: pasteboard)
        let element = getFocusedTextElement(preferredApp: app)
        let focusedTextContext = focusedTextContext(from: element)
        if addBoundarySpaces, focusedTextContext == nil {
            DebugLog.info("Could not read focused text context, inserting with trailing separator only", context: "ClipboardManager")
        }

        let textToPaste = TextInsertionFormatter.payload(
            for: text,
            existingText: focusedTextContext?.text,
            selectedRange: focusedTextContext?.range,
            addBoundarySpaces: addBoundarySpaces
        )

        DebugLog.info("Target app for paste: \(app.localizedName ?? "unknown")", context: "ClipboardManager")
        _ = writePasteText(textToPaste, to: pasteboard)
        app.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + appActivationDelay) {
            let pasteboardChangeCount = writePasteText(textToPaste, to: pasteboard)
            simulatePaste()
            scheduleClipboardRestore(
                originalSnapshot,
                expectedChangeCount: pasteboardChangeCount,
                pasteboard: pasteboard
            )
            previousApp = nil
        }
    }

    @discardableResult
    private static func writePasteText(_ text: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        DebugLog.info("Pasteboard set success: \(success), changeCount: \(pasteboard.changeCount)", context: "ClipboardManager")
        return pasteboard.changeCount
    }

    private static func originalSnapshotForNewPaste(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        if let state = clipboardRestoreState, state.stillOwns(pasteboard) {
            DebugLog.info("Reusing pending original pasteboard snapshot", context: "ClipboardManager")
            cancelClipboardRestore()
            return state.originalSnapshot
        }

        cancelClipboardRestore()
        return PasteboardSnapshot.capture(from: pasteboard)
    }

    private static func cancelClipboardRestore() {
        clipboardRestoreWorkItem?.cancel()
        clipboardRestoreWorkItem = nil
        clipboardRestoreState = nil
    }

    private static func scheduleClipboardRestore(
        _ originalSnapshot: PasteboardSnapshot,
        expectedChangeCount: Int,
        pasteboard: NSPasteboard
    ) {
        let state = ClipboardRestoreState(
            originalSnapshot: originalSnapshot,
            expectedChangeCount: expectedChangeCount
        )
        clipboardRestoreState = state

        let workItem = DispatchWorkItem {
            guard let currentState = clipboardRestoreState,
                  currentState.expectedChangeCount == expectedChangeCount
            else {
                return
            }

            guard currentState.stillOwns(pasteboard) else {
                DebugLog.info("Skipping pasteboard restore because pasteboard changed after paste", context: "ClipboardManager")
                clipboardRestoreWorkItem = nil
                clipboardRestoreState = nil
                return
            }

            originalSnapshot.restore(to: pasteboard)
            DebugLog.info("Restored original pasteboard contents", context: "ClipboardManager")
            clipboardRestoreWorkItem = nil
            clipboardRestoreState = nil
        }

        clipboardRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay, execute: workItem)
    }

    private static func simulatePaste() {
        DebugLog.info("simulatePaste started", context: "ClipboardManager")
        HotkeyManager.shared.suppressFnKeyDetection()

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            DebugLog.info("ERROR: Failed to create CGEventSource", context: "ClipboardManager")
            return
        }

        let commandKeyCode: CGKeyCode = 0x37
        let vKeyCode: CGKeyCode = 0x09
        let eventTap = CGEventTapLocation.cghidEventTap

        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else {
            DebugLog.info("ERROR: Failed to create paste key events", context: "ClipboardManager")
            return
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        commandDown.post(tap: eventTap)
        usleep(pasteKeyEventDelay)
        vDown.post(tap: eventTap)
        usleep(pasteKeyEventDelay)
        vUp.post(tap: eventTap)
        usleep(pasteKeyEventDelay)
        commandUp.post(tap: eventTap)

        DebugLog.info("Paste key events posted", context: "ClipboardManager")
    }

    private struct ClipboardRestoreState {
        let originalSnapshot: PasteboardSnapshot
        let expectedChangeCount: Int

        func stillOwns(_ pasteboard: NSPasteboard) -> Bool {
            pasteboard.changeCount == expectedChangeCount
        }
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
            let capturedItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
                var itemData: [NSPasteboard.PasteboardType: Data] = [:]

                for type in item.types {
                    if let data = item.data(forType: type) {
                        itemData[type] = data
                    }
                }

                return itemData.isEmpty ? nil : itemData
            } ?? []

            DebugLog.info("Captured pasteboard snapshot with \(capturedItems.count) item(s)", context: "ClipboardManager")
            return PasteboardSnapshot(items: capturedItems)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()

            guard !items.isEmpty else {
                return
            }

            let pasteboardItems = items.map { storedItem -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in storedItem {
                    _ = item.setData(data, forType: type)
                }
                return item
            }

            _ = pasteboard.writeObjects(pasteboardItems)
        }
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

    private static func focusedTextContext(from element: AXUIElement?) -> (text: String, range: NSRange)? {
        guard let element,
              let text = getTextFromElement(element),
              let range = getSelectedTextRange(from: element)
        else {
            return nil
        }

        return (text, NSRange(location: range.location, length: range.length))
    }
}
