import SwiftUI
import UIKit
import WhisperMateShared

typealias KeyboardRecordingState = AIDictationRecordingState
typealias KeyboardRecordingViewModel = AIDictationRecordingViewModel

struct KeyboardRecordingView: View {
    @ObservedObject var model: KeyboardRecordingViewModel
    let handoffPhase: KeyboardDictationHandoff.Phase?
    let isShifted: Bool
    let layout: KeyboardTypingLayout
    let showsGlobeKey: Bool
    let onPrimaryAction: () -> Void
    let onPauseAction: () -> Void
    let onCancelAction: () -> Void
    let onKeyPress: (String) -> Void
    let onAccentPick: (String) -> Void
    let onBackspace: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onShift: () -> Void
    let onToggleLayout: () -> Void
    let onSelectLanguage: (String) -> Void
    let onNextKeyboard: () -> Void
    @ObservedObject private var toneStyleManager = ToneStyleManager.shared
    @State private var accentKey: KeyboardTypingKey?
    @State private var showLanguagePicker = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if showLanguagePicker {
                languagePicker
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.state == .idle {
                keyRows
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                recordingStateView
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if !showLanguagePicker {
                recordButton
                    .padding(.top, 3)
                    .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .background(Color.clear)
        .animation(.spring(response: 0.32, dampingFraction: 0.84, blendDuration: 0.06), value: model.state)
        .onChange(of: layout) { _ in
            accentKey = nil
        }
    }

    private var keyRows: some View {
        VStack(spacing: 7) {
            HStack {
                if let accentKey {
                    accentBar(for: accentKey)
                } else if toneStyleManager.isNotesModeActive() {
                    Label("Notes", systemImage: "note.text")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
                Spacer()
            }
            .frame(height: 42)

            letterRow(layout.rows[0])
            letterRow(layout.rows[1])
                .padding(.horizontal, middleRowPadding)

            HStack(spacing: 6) {
                if layout.hasCase {
                    KeyboardKey(title: "shift", systemImage: isShifted ? "shift.fill" : "shift", style: .utility, action: onShift)
                        .frame(width: 42)
                }
                letterRow(layout.rows[2])
                KeyboardKey(title: "delete", systemImage: "delete.left", style: .utility, repeatsWhilePressed: true, action: onBackspace)
                    .frame(width: 42)
            }

            HStack(spacing: 6) {
                LanguageKey(
                    label: layout.toggleLabel,
                    onTap: onToggleLayout,
                    onHold: { showLanguagePicker = true }
                )
                .frame(width: 44)
                if showsGlobeKey {
                    KeyboardKey(title: "next keyboard", systemImage: "globe", style: .utility, action: onNextKeyboard)
                        .frame(width: 44)
                }
                KeyboardKey(title: "space", text: "space", style: .space, repeatsWhilePressed: true, action: onSpace)
                KeyboardKey(title: "return", text: "return", style: .utility, repeatsWhilePressed: true, action: onReturn)
                    .frame(width: 76)
            }
        }
        // Row data is already in visual order; keep it stable under RTL locales.
        .environment(\.layoutDirection, .leftToRight)
    }

    /// Center a short middle row the way the system keyboard does.
    private var middleRowPadding: CGFloat {
        layout.rows[1].count < layout.rows[0].count ? 18 : 0
    }

    private var languagePicker: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Language")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showLanguagePicker = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close language picker")
            }
            .padding(.horizontal, 10)
            .frame(height: 42)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(KeyboardLayoutData.layouts) { candidate in
                        Button {
                            showLanguagePicker = false
                            onSelectLanguage(candidate.code)
                        } label: {
                            HStack {
                                Text(candidate.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(candidate.toggleLabel)
                                    .foregroundColor(.secondary)
                                if candidate.code == layout.code {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(candidate.code == layout.code
                                        ? Color(uiColor: KeyboardPalette.utilityKeyColor)
                                        : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
        }
    }

    private func accentBar(for key: KeyboardTypingKey) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(layout.alternates(for: key, shifted: isShifted), id: \.self) { alt in
                    Button {
                        accentKey = nil
                        onAccentPick(alt)
                    } label: {
                        Text(alt)
                            .font(.system(size: 20))
                            .foregroundColor(.primary)
                            .frame(minWidth: 38)
                            .frame(height: 38)
                            .background(Color(uiColor: KeyboardPalette.keyColor))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    accentKey = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss accents")
            }
            .padding(.leading, 8)
        }
    }

    private var recordingStateView: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
            }
            .frame(height: 42)

            Spacer(minLength: 0)

            AIDictationActiveRecordingVisual(
                state: model.state,
                audioLevel: model.audioLevel,
                frequencyBands: model.frequencyBands,
                color: .primary
            )
            .frame(width: 190, height: 82)
            .padding(.horizontal, 28)

            HStack(spacing: 12) {
                Text(recordTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if showsCancelAction {
                    Button("Cancel", action: onCancelAction)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .accessibilityHint("Keeps any recording already saved in the app")
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordButton: some View {
        Button(action: onPrimaryAction) {
            AIDictationMicButtonVisual(
                state: model.state,
                audioLevel: model.audioLevel,
                frequencyBands: model.frequencyBands,
                size: 34,
                style: .keyboard
            )
            .frame(width: 44, height: 44, alignment: .topTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.state == .processing)
        .accessibilityLabel(accessibilityLabel)
    }

    private func letterRow(_ keys: [KeyboardTypingKey]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                KeyboardKey(
                    title: key.label(shifted: isShifted),
                    text: key.label(shifted: isShifted),
                    style: .letter,
                    repeatsWhilePressed: true,
                    onHold: layout.popups[key.lower] != nil ? { accentKey = key } : nil,
                    action: { onKeyPress(key.label(shifted: isShifted)) }
                )
            }
        }
    }

    private var recordTitle: String {
        switch handoffPhase {
        case .preparing:
            return "Starting recording…"
        case .recording:
            return "Recording"
        case .finalizing:
            return "Finishing recording…"
        case .processing:
            return "Transcribing…"
        case .succeeded:
            return "Ready"
        case .failed:
            return "Couldn't transcribe"
        case .cancelled:
            return "Cancelled"
        case .none:
            return "AI Dictation"
        @unknown default:
            return "AI Dictation"
        }
    }

    private var showsCancelAction: Bool {
        switch handoffPhase {
        case .preparing, .finalizing, .processing:
            return true
        case .recording, .succeeded, .failed, .cancelled, .none:
            return false
        @unknown default:
            return false
        }
    }

    private var accessibilityLabel: String {
        switch handoffPhase {
        case .none, .failed, .cancelled, .succeeded:
            return "Start recording"
        case .recording:
            return "Finish recording"
        case .preparing:
            return "Starting recording"
        case .finalizing:
            return "Finishing recording"
        case .processing:
            return "Transcribing"
        @unknown default:
            return "Start recording"
        }
    }

}

private struct LanguageKey: View {
    let label: String
    let onTap: () -> Void
    let onHold: () -> Void

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .foregroundColor(.primary)
            .background(Color(uiColor: KeyboardPalette.utilityKeyColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.4, perform: onHold)
            .accessibilityLabel("switch keyboard language")
            .accessibilityHint("Double tap to switch, touch and hold to pick a language")
    }
}

private struct KeyboardKey: View {
    enum Style {
        case letter
        case utility
        case space
    }

    let title: String
    var text: String?
    var systemImage: String?
    let style: Style
    var repeatsWhilePressed = false
    var onHold: (() -> Void)?
    let action: () -> Void
    @State private var isPressing = false
    @State private var initialRepeatTimer: Timer?
    @State private var repeatTimer: Timer?

    var body: some View {
        Button(action: {
            if !repeatsWhilePressed {
                action()
            }
        }) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                } else {
                    Text(text ?? title)
                        .font(.system(size: style == .letter ? 22 : 15, weight: style == .letter ? .regular : .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: style == .space ? 40 : 42)
            .foregroundColor(.primary)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(repeatGesture)
        .accessibilityLabel(title)
        .onDisappear(perform: stopRepeating)
    }

    private var backgroundColor: Color {
        switch style {
        case .letter, .space:
            return Color(uiColor: KeyboardPalette.keyColor)
        case .utility:
            return Color(uiColor: KeyboardPalette.utilityKeyColor)
        }
    }

    private var repeatGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                startRepeatingIfNeeded()
            }
            .onEnded { _ in
                stopRepeating()
            }
    }

    private func startRepeatingIfNeeded() {
        guard repeatsWhilePressed, !isPressing else { return }

        isPressing = true
        action()

        let initialTimer = Timer(timeInterval: 0.42, repeats: false) { _ in
            if let onHold {
                onHold()
                return
            }
            repeatTimer?.invalidate()
            let repeatingTimer = Timer(timeInterval: 0.075, repeats: true) { _ in
                action()
            }
            RunLoop.main.add(repeatingTimer, forMode: .common)
            repeatTimer = repeatingTimer
        }
        RunLoop.main.add(initialTimer, forMode: .common)
        initialRepeatTimer = initialTimer
    }

    private func stopRepeating() {
        isPressing = false
        initialRepeatTimer?.invalidate()
        initialRepeatTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

enum KeyboardPalette {
    static let backgroundColor = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1.0)
            : UIColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 1.0)
    }

    static let keyColor = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.36, green: 0.36, blue: 0.38, alpha: 1.0)
            : UIColor.white
    }

    static let utilityKeyColor = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.27, green: 0.27, blue: 0.29, alpha: 1.0)
            : UIColor(red: 0.68, green: 0.71, blue: 0.76, alpha: 1.0)
    }
}
