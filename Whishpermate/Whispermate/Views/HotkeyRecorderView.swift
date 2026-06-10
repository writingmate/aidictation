import AppKit
import SwiftUI

// MARK: - Hotkey Type

enum HotkeyType {
    case dictation
    case command
}

// MARK: - Predefined Hotkey Options

enum HotkeyOption: String, CaseIterable, Identifiable {
    case fn
    case fnSpace = "fn_space"
    case f4
    case f5
    case controlSpace = "ctrl_space"
    case optionSpace = "opt_space"
    case shiftF9 = "shift_f9"
    case optionF7 = "opt_f7"
    case leftControl = "left_ctrl"
    case rightCommand = "right_cmd"
    case rightOption = "right_opt"
    case rightShift = "right_shift"
    case rightControl = "right_ctrl"
    case optionCommand = "opt_cmd"
    case controlCommand = "ctrl_cmd"
    case controlOption = "ctrl_opt"
    case shiftCommand = "shift_cmd"
    case optionShift = "opt_shift"
    case controlShift = "ctrl_shift"
    case optionR = "opt_r"
    // Mouse buttons
    case mouseMiddle = "mouse_middle"
    case mouseSide1 = "mouse_side1"
    case mouseSide2 = "mouse_side2"

    var id: String { rawValue }

    var conflictHelp: HotkeyConflictHelp? {
        switch self {
        case .fnSpace:
            return .fnKeyConflict
        case .f4, .f5:
            return .functionKeyConflict
        case .controlSpace:
            return .inputSourceConflict
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .fnSpace: return "Fn + Space"
        case .f4: return "F4"
        case .f5: return "F5"
        case .controlSpace: return "⌃ + Space"
        case .optionSpace: return "⌥ + Space"
        case .shiftF9: return "⇧ + F9"
        case .optionF7: return "⌥ + F7"
        case .leftControl: return "Left ⌃"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightShift: return "Right ⇧"
        case .rightControl: return "Right ⌃"
        case .optionCommand: return "⌥ + ⌘"
        case .controlCommand: return "⌃ + ⌘"
        case .controlOption: return "⌃ + ⌥"
        case .shiftCommand: return "⇧ + ⌘"
        case .optionShift: return "⌥ + ⇧"
        case .controlShift: return "⌃ + ⇧"
        case .optionR: return "⌥ + R"
        case .mouseMiddle: return "Middle Click"
        case .mouseSide1: return "Side Button 1"
        case .mouseSide2: return "Side Button 2"
        }
    }

    var hotkey: Hotkey {
        switch self {
        case .fn:
            return Hotkey(keyCode: 63, modifiers: .function)
        case .fnSpace:
            return Hotkey(keyCode: 49, modifiers: .function)
        case .f4:
            // F4 key code is 118
            return Hotkey(keyCode: 118, modifiers: [])
        case .f5:
            // F5 key code is 96
            return Hotkey(keyCode: 96, modifiers: [])
        case .controlSpace:
            // Space key code is 49
            return Hotkey(keyCode: 49, modifiers: .control)
        case .optionSpace:
            return Hotkey(keyCode: 49, modifiers: .option)
        case .shiftF9:
            // F9 key code is 101
            return Hotkey(keyCode: 101, modifiers: .shift)
        case .optionF7:
            // F7 key code is 98
            return Hotkey(keyCode: 98, modifiers: .option)
        case .leftControl:
            // Left Control key code is 59
            return Hotkey(keyCode: 59, modifiers: .control)
        case .rightCommand:
            // Right Command key code is 54
            return Hotkey(keyCode: 54, modifiers: .command)
        case .rightOption:
            // Right Option key code is 61
            return Hotkey(keyCode: 61, modifiers: .option)
        case .rightShift:
            // Right Shift key code is 60
            return Hotkey(keyCode: 60, modifiers: .shift)
        case .rightControl:
            // Right Control key code is 62
            return Hotkey(keyCode: 62, modifiers: .control)
        case .optionCommand:
            // Use Space as placeholder key with modifiers
            return Hotkey(keyCode: 49, modifiers: [.option, .command])
        case .controlCommand:
            return Hotkey(keyCode: 49, modifiers: [.control, .command])
        case .controlOption:
            return Hotkey(keyCode: 49, modifiers: [.control, .option])
        case .shiftCommand:
            return Hotkey(keyCode: 49, modifiers: [.shift, .command])
        case .optionShift:
            return Hotkey(keyCode: 49, modifiers: [.option, .shift])
        case .controlShift:
            return Hotkey(keyCode: 49, modifiers: [.control, .shift])
        case .optionR:
            // R key code is 15
            return Hotkey(keyCode: 15, modifiers: .option)
        case .mouseMiddle:
            // Middle click is button 2
            return Hotkey(keyCode: 0, modifiers: [], mouseButton: 2)
        case .mouseSide1:
            // Side button 1 (back) is button 3
            return Hotkey(keyCode: 0, modifiers: [], mouseButton: 3)
        case .mouseSide2:
            // Side button 2 (forward) is button 4
            return Hotkey(keyCode: 0, modifiers: [], mouseButton: 4)
        }
    }

    static func from(hotkey: Hotkey?) -> HotkeyOption? {
        guard let hotkey = hotkey else { return nil }

        // Check for mouse buttons first
        if let mouseButton = hotkey.mouseButton {
            switch mouseButton {
            case 2: return .mouseMiddle
            case 3: return .mouseSide1
            case 4: return .mouseSide2
            default: return nil
            }
        }

        // Check for Fn key
        if hotkey.modifiers == .function, (hotkey.keyCode == 63 || hotkey.keyCode == 179) {
            return .fn
        }

        // Check for Fn + Space
        if hotkey.keyCode == 49, hotkey.modifiers == .function {
            return .fnSpace
        }

        // Check for F4 key
        if hotkey.keyCode == 118, hotkey.modifiers.isEmpty {
            return .f4
        }

        // Check for F5 key
        if hotkey.keyCode == 96, hotkey.modifiers.isEmpty {
            return .f5
        }

        // Check for control/option + space
        if hotkey.keyCode == 49, hotkey.modifiers == .control {
            return .controlSpace
        }
        if hotkey.keyCode == 49, hotkey.modifiers == .option {
            return .optionSpace
        }

        // Check for shift + F9 and option + F7
        if hotkey.keyCode == 101, hotkey.modifiers == .shift {
            return .shiftF9
        }
        if hotkey.keyCode == 98, hotkey.modifiers == .option {
            return .optionF7
        }

        // Check for left Control (keyCode 59)
        if hotkey.keyCode == 59, hotkey.modifiers.contains(.control) {
            return .leftControl
        }

        // Check for right-side modifier keys
        if hotkey.keyCode == 54, hotkey.modifiers.contains(.command) {
            return .rightCommand
        }
        if hotkey.keyCode == 61, hotkey.modifiers.contains(.option) {
            return .rightOption
        }
        if hotkey.keyCode == 60, hotkey.modifiers.contains(.shift) {
            return .rightShift
        }
        if hotkey.keyCode == 62, hotkey.modifiers.contains(.control) {
            return .rightControl
        }

        // Check for Option+R
        if hotkey.keyCode == 15, hotkey.modifiers == .option {
            return .optionR
        }

        // Check for modifier combinations (with Space as placeholder)
        if hotkey.keyCode == 49 {
            if hotkey.modifiers == [.option, .command] {
                return .optionCommand
            }
            if hotkey.modifiers == [.control, .command] {
                return .controlCommand
            }
            if hotkey.modifiers == [.control, .option] {
                return .controlOption
            }
            if hotkey.modifiers == [.shift, .command] {
                return .shiftCommand
            }
            if hotkey.modifiers == [.option, .shift] {
                return .optionShift
            }
            if hotkey.modifiers == [.control, .shift] {
                return .controlShift
            }
        }

        return nil
    }
}

struct HotkeyConflictHelp {
    let title: String
    let summary: String
    let steps: [HotkeyConflictHelpStep]

    private static let keyboardPaneURLs = [
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.keyboard"
    ]

    private static let keyboardShortcutsURLs = [
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?KeyboardShortcuts",
        "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts",
        "x-apple.systempreferences:com.apple.preference.keyboard"
    ]

    private static let dictationURLs = [
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation",
        "x-apple.systempreferences:com.apple.preference.keyboard?Dictation",
        "x-apple.systempreferences:com.apple.preference.keyboard"
    ]

    private static let inputSourcesURLs = [
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources",
        "x-apple.systempreferences:com.apple.preference.keyboard?InputSources",
        "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts",
        "x-apple.systempreferences:com.apple.preference.keyboard"
    ]

    static let functionKeyConflict = HotkeyConflictHelp(
        title: "Function Key Setup Required",
        summary: "This key may be reserved by macOS.",
        steps: [
            HotkeyConflictHelpStep(
                text: "System Settings > Keyboard > Keyboard Shortcuts > Function Keys: turn on \"Use F1, F2, etc. keys as standard function keys\".",
                action: HotkeyConflictHelpAction(title: "Open Function Keys", urlCandidates: keyboardShortcutsURLs)
            ),
            HotkeyConflictHelpStep(
                text: "System Settings > Keyboard > Dictation: change Dictation shortcut or turn Dictation off.",
                action: HotkeyConflictHelpAction(title: "Open Dictation", urlCandidates: dictationURLs)
            ),
            HotkeyConflictHelpStep(
                text: "System Settings > Keyboard: set \"Press fn key to\" / \"Press Globe key to\" to Do Nothing (or Change Input Source).",
                action: HotkeyConflictHelpAction(title: "Open Keyboard", urlCandidates: keyboardPaneURLs)
            ),
            HotkeyConflictHelpStep(
                text: "Test in another app (for example TextEdit) while AIDictation is in the background.",
                action: nil
            )
        ]
    )

    static let fnKeyConflict = HotkeyConflictHelp(
        title: "Fn/Globe Key Setup Required",
        summary: "Fn/Globe is often mapped to emoji, Dictation, or input switching.",
        steps: [
            HotkeyConflictHelpStep(
                text: "System Settings > Keyboard: set \"Press fn key to\" / \"Press Globe key to\" to Do Nothing (or Change Input Source).",
                action: HotkeyConflictHelpAction(title: "Open Keyboard", urlCandidates: keyboardPaneURLs)
            ),
            HotkeyConflictHelpStep(
                text: "System Settings > Keyboard > Dictation: change Dictation shortcut or turn Dictation off.",
                action: HotkeyConflictHelpAction(title: "Open Dictation", urlCandidates: dictationURLs)
            ),
            HotkeyConflictHelpStep(
                text: "Test in another app while AIDictation is in the background.",
                action: nil
            )
        ]
    )

    static let inputSourceConflict = HotkeyConflictHelp(
        title: "Input Source Shortcut Conflict",
        summary: "Ctrl + Space is commonly used by macOS to switch input source.",
        steps: [
            HotkeyConflictHelpStep(
                text: "System Settings > Keyboard > Keyboard Shortcuts > Input Sources.",
                action: HotkeyConflictHelpAction(title: "Open Input Sources", urlCandidates: inputSourcesURLs)
            ),
            HotkeyConflictHelpStep(
                text: "Change or disable the Ctrl + Space shortcut.",
                action: nil
            ),
            HotkeyConflictHelpStep(
                text: "Test in another app while AIDictation is in the background.",
                action: nil
            )
        ]
    )
}

struct HotkeyConflictHelpStep: Identifiable {
    let text: String
    let action: HotkeyConflictHelpAction?
    var id: String { text + "|" + (action?.title ?? "") }
}

struct HotkeyConflictHelpAction: Identifiable {
    let title: String
    let urlCandidates: [String]
    var id: String { title }
}

private enum HotkeyConflictDetector {
    private static let symbolicHotkeysDomain = "com.apple.symbolichotkeys"

    static func shouldShowWarning(for option: HotkeyOption) -> Bool {
        switch option {
        case .f4, .f5:
            return shouldShowFunctionKeyWarning(for: option.hotkey)
        case .controlSpace:
            let hasConflict = hasEnabledSymbolicHotkey(exactMatch: option.hotkey)
            DebugLog.error("Ctrl+Space conflict check showWarning=\(hasConflict)", context: "HotkeyDiagnostics")
            return hasConflict
        default:
            return true
        }
    }

    private static func shouldShowFunctionKeyWarning(for hotkey: Hotkey) -> Bool {
        let standardFunctionKeysEnabled = isStandardFunctionKeysEnabled() ?? false
        let matchingSymbolicHotkeys = enabledSymbolicHotkeyIDs(withKeyCode: Int(hotkey.keyCode))
        let keycodeConflict = !matchingSymbolicHotkeys.isEmpty
        let shouldShow = !standardFunctionKeysEnabled || keycodeConflict
        DebugLog.error(
            "F-key conflict check keyCode=\(hotkey.keyCode) fnStateEnabled=\(standardFunctionKeysEnabled) symbolicMatches=\(matchingSymbolicHotkeys) showWarning=\(shouldShow)",
            context: "HotkeyDiagnostics"
        )
        return shouldShow
    }

    private static func isStandardFunctionKeysEnabled() -> Bool? {
        guard let domain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) else {
            return nil
        }
        return boolValue(from: domain["com.apple.keyboard.fnState"])
    }

    private static func enabledSymbolicHotkeyIDs(withKeyCode keyCode: Int) -> [String] {
        guard let hotkeys = symbolicHotkeysDictionary() else { return [] }

        var matches: [String] = []

        for (identifier, value) in hotkeys {
            guard let entry = value as? [String: Any],
                  isEnabled(entry),
                  let parameters = extractParameters(from: entry)
            else {
                continue
            }

            if parameters.keyCode == keyCode {
                matches.append(identifier)
            }
        }

        return matches.sorted()
    }

    private static func hasEnabledSymbolicHotkey(exactMatch hotkey: Hotkey) -> Bool {
        guard !hotkey.isMouseButton, let hotkeys = symbolicHotkeysDictionary() else { return false }

        let targetKeyCode = Int(hotkey.keyCode)
        let targetModifiers = carbonModifierMask(for: hotkey.modifiers)

        for value in hotkeys.values {
            guard let entry = value as? [String: Any],
                  isEnabled(entry),
                  let parameters = extractParameters(from: entry)
            else {
                continue
            }

            if parameters.keyCode == targetKeyCode && parameters.modifiers == targetModifiers {
                return true
            }
        }

        return false
    }

    private static func symbolicHotkeysDictionary() -> [String: Any]? {
        UserDefaults(suiteName: symbolicHotkeysDomain)?.dictionary(forKey: "AppleSymbolicHotKeys")
    }

    private static func isEnabled(_ entry: [String: Any]) -> Bool {
        boolValue(from: entry["enabled"]) ?? false
    }

    private static func extractParameters(from entry: [String: Any]) -> (keyCode: Int, modifiers: Int)? {
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCode = intValue(from: parameters[1]),
              let modifiers = intValue(from: parameters[2])
        else {
            return nil
        }

        return (keyCode: keyCode, modifiers: modifiers)
    }

    private static func carbonModifierMask(for modifiers: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if modifiers.contains(.shift) { mask |= 131072 }
        if modifiers.contains(.control) { mask |= 262144 }
        if modifiers.contains(.option) { mask |= 524288 }
        if modifiers.contains(.command) { mask |= 1048576 }
        if modifiers.contains(.function) { mask |= 8388608 }
        return mask
    }

    private static func boolValue(from value: Any?) -> Bool? {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let intValue = intValue(from: value) {
            return intValue != 0
        }
        return nil
    }

    private static func intValue(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

// MARK: - Hotkey Picker View

struct HotkeyRecorderView: View {
    @ObservedObject var hotkeyManager: HotkeyManager
    var hotkeyType: HotkeyType = .dictation
    var showsConflictHelp: Bool = false
    @State private var selectedOption: HotkeyOption = .fn
    @State private var currentConflictHelp: HotkeyConflictHelp?
    @State private var showConflictHelpPopover = false
    @State private var didInitializeSelection = false

    private func shouldShowConflictHelp(for option: HotkeyOption) -> Bool {
        HotkeyConflictDetector.shouldShowWarning(for: option)
    }

    private func updateConflictHelp(for option: HotkeyOption) {
        guard showsConflictHelp, let help = option.conflictHelp else {
            currentConflictHelp = nil
            showConflictHelpPopover = false
            return
        }

        if shouldShowConflictHelp(for: option) {
            currentConflictHelp = help
        } else {
            currentConflictHelp = nil
            showConflictHelpPopover = false
            DebugLog.error("Conflict help skipped for \(option.displayName) (requirements already satisfied)", context: "HotkeyDiagnostics")
        }
    }

    private func openSettings(_ action: HotkeyConflictHelpAction) {
        for candidate in action.urlCandidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private var currentHotkey: Hotkey? {
        switch hotkeyType {
        case .dictation: return hotkeyManager.currentHotkey
        case .command: return hotkeyManager.commandHotkey
        }
    }

    private var defaultOption: HotkeyOption {
        switch hotkeyType {
        case .dictation: return .fn
        case .command: return .leftControl
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $selectedOption) {
                ForEach(HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            if let help = currentConflictHelp {
                Button {
                    showConflictHelpPopover.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("This hotkey may conflict with macOS. Hover to view setup steps.")
                .onHover { hovering in
                    if hovering {
                        showConflictHelpPopover = true
                    }
                }
                .popover(isPresented: $showConflictHelpPopover, arrowEdge: .bottom) {
                    HotkeyConflictPopoverContent(help: help) {
                        showConflictHelpPopover = false
                    } onOpenSettings: { action in
                        openSettings(action)
                    }
                    .frame(width: 440)
                    .padding(14)
                }
            }
        }
        .onAppear {
            // Load current selection
            if let option = HotkeyOption.from(hotkey: currentHotkey) {
                selectedOption = option
            } else {
                selectedOption = defaultOption
            }
            updateConflictHelp(for: selectedOption)
            didInitializeSelection = true
        }
        .onChange(of: selectedOption) { newValue in
            guard didInitializeSelection else { return }

            switch hotkeyType {
            case .dictation:
                hotkeyManager.setHotkey(newValue.hotkey)
            case .command:
                hotkeyManager.setCommandHotkey(newValue.hotkey)
            }

            updateConflictHelp(for: newValue)
        }
    }
}

private struct HotkeyConflictPopoverContent: View {
    let help: HotkeyConflictHelp
    let onClose: () -> Void
    let onOpenSettings: (HotkeyConflictHelpAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(help.title)
                        .font(.headline)
                    Text(help.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(help.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            if let action = step.action {
                                Button(action.title) {
                                    onOpenSettings(action)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Got it") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }
}
