import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private func requireContains(_ source: String, _ fragment: String, _ message: String) throws {
    guard source.contains(fragment) else {
        throw ValidationFailure.assertion(message)
    }
}

private func run() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let pickerSource = try String(
        contentsOf: root.appendingPathComponent(
            "Whishpermate/Whispermate/Views/HotkeyRecorderView.swift"
        ),
        encoding: .utf8
    )
    let managerSource = try String(
        contentsOf: root.appendingPathComponent(
            "Whishpermate/Whispermate/Services/HotkeyManager.swift"
        ),
        encoding: .utf8
    )

    try requireContains(
        pickerSource,
        "ForEach(HotkeyOption.allCases)",
        "the hotkey picker no longer exposes every declared option"
    )

    let leftModifierContracts = [
        ("leftCommand", "left_cmd", "Left ⌘", 55, "command"),
        ("leftOption", "left_opt", "Left ⌥", 58, "option"),
        ("leftShift", "left_shift", "Left ⇧", 56, "shift"),
    ]

    for (name, rawValue, label, keyCode, modifier) in leftModifierContracts {
        try requireContains(
            pickerSource,
            "case \(name) = \"\(rawValue)\"",
            "missing picker case for \(label)"
        )
        try requireContains(
            pickerSource,
            "case .\(name): return \"\(label)\"",
            "missing user-facing label for \(label)"
        )
        try requireContains(
            pickerSource,
            "return Hotkey(keyCode: \(keyCode), modifiers: .\(modifier))",
            "\(label) does not map to the expected macOS keycode"
        )
        try requireContains(
            pickerSource,
            "if hotkey.keyCode == \(keyCode), hotkey.modifiers.contains(.\(modifier)) {\n            return .\(name)\n        }",
            "\(label) does not round-trip from a saved hotkey"
        )
    }

    try requireContains(
        managerSource,
        "let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63, 179]",
        "the event path does not recognize all left modifier-only keycodes"
    )
    try requireContains(
        managerSource,
        "(1 << CGEventType.flagsChanged.rawValue)",
        "the global event tap no longer observes modifier-only key changes"
    )
    try requireContains(
        managerSource,
        "flagsChangedKeyMatchesHotkey(eventKeyCode: keyCode, hotkey: hotkey)",
        "modifier-only events are not matched by their physical keycode"
    )
    try requireContains(
        managerSource,
        "return eventKeyCode == hotkey.keyCode",
        "left and right modifier keys are no longer distinguished"
    )
    try requireContains(
        managerSource,
        "let isModifierPressed = isRequiredModifierPressed(for: hotkey, eventModifiers: modifiers)",
        "modifier press and release state is no longer derived from event flags"
    )
    try requireContains(
        managerSource,
        "handled = handleModifierFlagsStateChange(isModifierPressed: isModifierPressed, isDictation: true) || handled",
        "modifier-only dictation no longer reaches the press/release state machine"
    )

    let existingCombinationContracts = [
        "return Hotkey(keyCode: 49, modifiers: [.option, .command])",
        "return Hotkey(keyCode: 49, modifiers: [.control, .command])",
        "return Hotkey(keyCode: 49, modifiers: [.control, .option])",
        "return Hotkey(keyCode: 49, modifiers: [.shift, .command])",
        "return Hotkey(keyCode: 49, modifiers: [.option, .shift])",
        "return Hotkey(keyCode: 49, modifiers: [.control, .shift])",
        "return Hotkey(keyCode: 15, modifiers: .option)",
    ]

    for contract in existingCombinationContracts {
        try requireContains(
            pickerSource,
            contract,
            "an existing hotkey combination mapping was removed"
        )
    }

    let existingCombinationRoundTrips = [
        ("if hotkey.modifiers == [.option, .command]", "return .optionCommand"),
        ("if hotkey.modifiers == [.control, .command]", "return .controlCommand"),
        ("if hotkey.modifiers == [.control, .option]", "return .controlOption"),
        ("if hotkey.modifiers == [.shift, .command]", "return .shiftCommand"),
        ("if hotkey.modifiers == [.option, .shift]", "return .optionShift"),
        ("if hotkey.modifiers == [.control, .shift]", "return .controlShift"),
    ]

    for (condition, result) in existingCombinationRoundTrips {
        try requireContains(
            pickerSource,
            "\(condition) {\n                \(result)",
            "an existing hotkey combination no longer round-trips from saved settings"
        )
    }

    print("macOS hotkey option contracts passed")
}

do {
    try run()
} catch {
    fputs("macOS hotkey option validation failed: \(error)\n", stderr)
    exit(1)
}
