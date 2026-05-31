import SwiftUI
import UIKit
import WhisperMateShared

typealias KeyboardRecordingState = AIDictationRecordingState
typealias KeyboardRecordingViewModel = AIDictationRecordingViewModel

struct KeyboardRecordingView: View {
    @ObservedObject var model: KeyboardRecordingViewModel
    let isShifted: Bool
    let onPrimaryAction: () -> Void
    let onPauseAction: () -> Void
    let onKeyPress: (String) -> Void
    let onBackspace: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onShift: () -> Void
    let onNextKeyboard: () -> Void
    @ObservedObject private var toneStyleManager = ToneStyleManager.shared

    private let rows = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.state == .idle {
                keyRows
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                recordingStateView
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            recordButton
                .padding(.top, 3)
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 6)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .background(Color.clear)
        .animation(.spring(response: 0.32, dampingFraction: 0.84, blendDuration: 0.06), value: model.state)
    }

    private var keyRows: some View {
        VStack(spacing: 7) {
            HStack {
                if toneStyleManager.isNotesModeActive() {
                    Label("Notes", systemImage: "note.text")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
                Spacer()
            }
            .frame(height: 42)

            letterRow(rows[0])
            letterRow(rows[1])
                .padding(.horizontal, 18)

            HStack(spacing: 6) {
                KeyboardKey(title: "shift", systemImage: isShifted ? "shift.fill" : "shift", style: .utility, action: onShift)
                    .frame(width: 42)
                letterRow(rows[2])
                KeyboardKey(title: "delete", systemImage: "delete.left", style: .utility, repeatsWhilePressed: true, action: onBackspace)
                    .frame(width: 42)
            }

            HStack(spacing: 6) {
                KeyboardKey(title: "next keyboard", systemImage: "globe", style: .utility, action: onNextKeyboard)
                    .frame(width: 44)
                KeyboardKey(title: "space", text: "space", style: .space, repeatsWhilePressed: true, action: onSpace)
                KeyboardKey(title: "return", text: "return", style: .utility, repeatsWhilePressed: true, action: onReturn)
                    .frame(width: 76)
            }
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

    private func letterRow(_ keys: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                KeyboardKey(
                    title: key,
                    text: isShifted ? key.uppercased() : key,
                    style: .letter,
                    repeatsWhilePressed: true,
                    action: { onKeyPress(isShifted ? key.uppercased() : key) }
                )
            }
        }
    }

    private var recordTitle: String {
        switch model.state {
        case .idle: return "AI Dictation"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .processing: return "Transcribing"
        @unknown default: return "AI Dictation"
        }
    }

    private var accessibilityLabel: String {
        switch model.state {
        case .idle:
            return "Start recording"
        case .recording, .paused:
            return "Finish recording"
        case .processing:
            return "Transcribing"
        @unknown default:
            return "Start recording"
        }
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
