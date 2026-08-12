import AppKit
import ApplicationServices
import CoreGraphics

class ClipboardManager {
    private static var previousApp: NSRunningApplication?
    private static var clipboardRestoreWorkItem: DispatchWorkItem?
    private static var clipboardRestoreState: ClipboardRestoreState?
    private static var liveInsertionState: LiveInsertionState?
    private static let appActivationDelay: TimeInterval = 0.3
    private static let liveAppActivationDelay: TimeInterval = 0.06
    private static let liveInsertionThrottle: TimeInterval = 0.22
    private static let clipboardRestoreDelay: TimeInterval = 0.8
    private static let pasteKeyEventDelay: useconds_t = 10_000
    private static let deleteKeyEventDelay: useconds_t = 300

    static var hasActiveLiveDictationInsertion: Bool {
        liveInsertionState != nil
    }

    static func storePreviousApp() {
        let workspace = NSWorkspace.shared
        if let activeApp = workspace.frontmostApplication {
            previousApp = activeApp
            DebugLog.info(
                "Stored previous app: \(activeApp.localizedName ?? "unknown") pid=\(activeApp.processIdentifier) bundle=\(activeApp.bundleIdentifier ?? "unknown")",
                context: "ClipboardManager"
            )
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

    /// Stream dictated text into the original focused app while recording.
    static func updateLiveDictationInsertion(_ text: String) {
        let logicalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !logicalText.isEmpty else { return }

        DispatchQueue.main.async {
            guard ensureLiveInsertionState() else { return }
            guard var state = liveInsertionState else { return }
            guard state.pendingLogicalText != logicalText || state.currentLogicalText != logicalText else { return }

            state.pendingLogicalText = logicalText
            liveInsertionState = state
            DebugLog.info(
                "Live dictation update queued logicalLength=\(logicalText.count) insertedLength=\(state.insertedText.count)",
                context: "ClipboardManager"
            )
            scheduleLiveInsertionApply()
        }
    }

    /// Apply the final transcription to the same live-inserted text, or perform a normal paste if live insertion never started.
    static func finishLiveDictationInsertion(finalText: String) {
        let logicalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !logicalText.isEmpty else {
            cancelLiveDictationInsertion(removeInsertedText: false)
            return
        }

        DispatchQueue.main.async {
            guard ensureLiveInsertionState() else {
                copyAndPaste(logicalText)
                return
            }
            guard var state = liveInsertionState else {
                copyAndPaste(logicalText)
                return
            }

            state.pendingLogicalText = logicalText
            state.finishAfterApply = true
            liveInsertionState = state
            DebugLog.info(
                "Live dictation finish queued logicalLength=\(logicalText.count) insertedLength=\(state.insertedText.count)",
                context: "ClipboardManager"
            )
            scheduleLiveInsertionApply()
        }
    }

    static func cancelLiveDictationInsertion(removeInsertedText: Bool = true) {
        DispatchQueue.main.async {
            guard var state = liveInsertionState else { return }

            state.pendingLogicalText = removeInsertedText ? "" : state.currentLogicalText
            state.finishAfterApply = true
            liveInsertionState = state
            DebugLog.info(
                "Live dictation cancel queued removeInsertedText=\(removeInsertedText) insertedLength=\(state.insertedText.count)",
                context: "ClipboardManager"
            )
            scheduleLiveInsertionApply()
        }
    }

    // MARK: - Pasteboard Insertion

    private static func insertText(_ text: String, addBoundarySpaces: Bool) {
        DebugLog.info("Text length: \(text.count) characters", context: "ClipboardManager")
        DebugLog.info(
            "Insert requested addBoundarySpaces=\(addBoundarySpaces) AXTrusted=\(AXIsProcessTrusted()) previousApp=\(previousApp?.localizedName ?? "nil") frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")",
            context: "ClipboardManager"
        )

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
        DebugLog.info(
            "Resolved paste target app=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "unknown") active=\(app.isActive)",
            context: "ClipboardManager"
        )

        let pasteboard = NSPasteboard.general
        let originalSnapshot = originalSnapshotForNewPaste(from: pasteboard)
        let element = getFocusedTextElement(preferredApp: app)
        let focusedTextContext = focusedTextContext(from: element)
        DebugLog.info(
            "Focused text element found=\(element != nil) contextAvailable=\(focusedTextContext != nil)",
            context: "ClipboardManager"
        )
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
        app.activate(options: [.activateIgnoringOtherApps])
        DebugLog.info("Paste target activation requested", context: "ClipboardManager")

        DispatchQueue.main.asyncAfter(deadline: .now() + appActivationDelay) {
            DebugLog.info(
                "Paste delay elapsed frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil") targetActive=\(app.isActive)",
                context: "ClipboardManager"
            )
            let pasteboardChangeCount = writePasteText(textToPaste, to: pasteboard)
            simulatePaste()
            scheduleClipboardRestore(
                originalSnapshot,
                expectedChangeCount: pasteboardChangeCount,
                pasteboard: pasteboard
            )
            previousApp = nil
            DebugLog.info("Paste flow completed; previous app cleared", context: "ClipboardManager")
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
        DebugLog.info(
            "Scheduled pasteboard restore expectedChangeCount=\(expectedChangeCount) delay=\(clipboardRestoreDelay)s",
            context: "ClipboardManager"
        )

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

    // MARK: - Live Dictation Insertion

    private static func ensureLiveInsertionState() -> Bool {
        if liveInsertionState != nil {
            return true
        }

        guard AXIsProcessTrusted() else {
            DebugLog.warning("Accessibility permission missing; cannot live-insert dictation", context: "ClipboardManager")
            return false
        }

        guard let app = previousApp ?? NSWorkspace.shared.frontmostApplication else {
            DebugLog.warning("No target app available for live dictation insertion", context: "ClipboardManager")
            return false
        }

        let pasteboard = NSPasteboard.general
        let originalSnapshot = originalSnapshotForNewPaste(from: pasteboard)
        let element = getFocusedTextElement(preferredApp: app)
        let focusedTextContext = focusedTextContext(from: element)

        liveInsertionState = LiveInsertionState(
            targetApp: app,
            originalSnapshot: originalSnapshot,
            originalContext: focusedTextContext,
            currentLogicalText: "",
            pendingLogicalText: nil,
            insertedText: "",
            isApplying: false,
            finishAfterApply: false,
            lastAppliedAt: .distantPast,
            lastPasteboardChangeCount: pasteboard.changeCount
        )

        DebugLog.info(
            "Live dictation session started target=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier) contextAvailable=\(focusedTextContext != nil)",
            context: "ClipboardManager"
        )
        return true
    }

    private static func scheduleLiveInsertionApply() {
        guard var state = liveInsertionState, !state.isApplying else { return }

        let elapsed = Date().timeIntervalSince(state.lastAppliedAt)
        let delay = max(0, liveInsertionThrottle - elapsed)
        state.isApplying = true
        liveInsertionState = state

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            applyLatestLiveInsertion()
        }
    }

    private static func applyLatestLiveInsertion() {
        guard var state = liveInsertionState else { return }
        guard let logicalText = state.pendingLogicalText else {
            state.isApplying = false
            liveInsertionState = state
            finishLiveInsertionIfNeeded()
            return
        }

        state.pendingLogicalText = nil
        liveInsertionState = state

        state.targetApp.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + liveAppActivationDelay) {
            guard var currentState = liveInsertionState else { return }
            let isFinalApply = currentState.finishAfterApply && currentState.pendingLogicalText == nil
            let payload = liveInsertionPayload(for: logicalText, state: currentState, isFinal: isFinalApply)
            let previousInsertedText = currentState.insertedText
            let pasteboard = NSPasteboard.general

            if payload == previousInsertedText {
                currentState.currentLogicalText = logicalText
                currentState.lastAppliedAt = Date()
                currentState.isApplying = false
                liveInsertionState = currentState
                DebugLog.info(
                    "Live dictation apply skipped unchanged insertedLength=\(payload.count)",
                    context: "ClipboardManager"
                )
                finishLiveInsertionIfNeeded()
                scheduleLiveInsertionApply()
                return
            }

            let replacement = replacementOperation(previous: previousInsertedText, next: payload)
            if replacement.deleteCount > 0 {
                postDeleteBackwards(characterCount: replacement.deleteCount)
                usleep(5_000)
            }

            var pasteboardChangeCount = currentState.lastPasteboardChangeCount
            if !replacement.textToPaste.isEmpty {
                pasteboardChangeCount = writePasteText(replacement.textToPaste, to: pasteboard)
                simulatePaste()
            }

            currentState.currentLogicalText = logicalText
            currentState.insertedText = payload
            currentState.lastAppliedAt = Date()
            currentState.lastPasteboardChangeCount = pasteboardChangeCount
            currentState.isApplying = false
            liveInsertionState = currentState

            DebugLog.info(
                "Live dictation applied deleteCount=\(replacement.deleteCount) pasteLength=\(replacement.textToPaste.count) insertedLength=\(payload.count) final=\(isFinalApply)",
                context: "ClipboardManager"
            )

            finishLiveInsertionIfNeeded()
            scheduleLiveInsertionApply()
        }
    }

    private static func finishLiveInsertionIfNeeded() {
        guard let state = liveInsertionState,
              state.finishAfterApply,
              state.pendingLogicalText == nil,
              !state.isApplying
        else {
            return
        }

        let pasteboard = NSPasteboard.general
        scheduleClipboardRestore(
            state.originalSnapshot,
            expectedChangeCount: state.lastPasteboardChangeCount,
            pasteboard: pasteboard
        )
        liveInsertionState = nil
        previousApp = nil
        DebugLog.info("Live dictation session finished; previous app cleared", context: "ClipboardManager")
    }

    private static func liveInsertionPayload(
        for logicalText: String,
        state: LiveInsertionState,
        isFinal: Bool
    ) -> String {
        let payload = TextInsertionFormatter.payload(
            for: logicalText,
            existingText: state.originalContext?.text,
            selectedRange: state.originalContext?.range,
            addBoundarySpaces: true
        )

        guard !isFinal,
              payload.last?.isWhitespace == true,
              logicalText.last?.isWhitespace != true
        else {
            return payload
        }

        return String(payload.dropLast())
    }

    private static func replacementOperation(previous: String, next: String) -> (deleteCount: Int, textToPaste: String) {
        guard !previous.isEmpty else {
            return (0, next)
        }

        let unchangedPrefixLength = commonPrefixLength(previous, next)
        let deleteCount = previous.count - unchangedPrefixLength
        let textToPaste = String(next.dropFirst(unchangedPrefixLength))
        return (deleteCount, textToPaste)
    }

    private static func commonPrefixLength(_ previous: String, _ next: String) -> Int {
        var previousIndex = previous.startIndex
        var nextIndex = next.startIndex
        var count = 0

        while previousIndex < previous.endIndex,
              nextIndex < next.endIndex,
              previous[previousIndex] == next[nextIndex]
        {
            count += 1
            previous.formIndex(after: &previousIndex)
            next.formIndex(after: &nextIndex)
        }

        return count
    }

    private static func postDeleteBackwards(characterCount: Int) {
        guard characterCount > 0 else { return }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            DebugLog.info("ERROR: Failed to create CGEventSource for live deletion", context: "ClipboardManager")
            return
        }

        let deleteKeyCode: CGKeyCode = 0x33
        let loc = CGEventTapLocation.cghidEventTap

        for _ in 0 ..< characterCount {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false)
            else {
                continue
            }

            keyDown.post(tap: loc)
            usleep(deleteKeyEventDelay)
            keyUp.post(tap: loc)
            usleep(deleteKeyEventDelay)
        }
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

    private struct LiveInsertionState {
        let targetApp: NSRunningApplication
        let originalSnapshot: PasteboardSnapshot
        let originalContext: (text: String, range: NSRange)?
        var currentLogicalText: String
        var pendingLogicalText: String?
        var insertedText: String
        var isApplying: Bool
        var finishAfterApply: Bool
        var lastAppliedAt: Date
        var lastPasteboardChangeCount: Int
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
