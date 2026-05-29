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

    private let rows = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    var body: some View {
        VStack(spacing: 7) {
            recordBar
            letterRow(rows[0])
            letterRow(rows[1])
                .padding(.horizontal, 18)

            HStack(spacing: 6) {
                KeyboardKey(title: "shift", systemImage: isShifted ? "shift.fill" : "shift", style: .utility, action: onShift)
                    .frame(width: 42)
                letterRow(rows[2])
                KeyboardKey(title: "delete", systemImage: "delete.left", style: .utility, action: onBackspace)
                    .frame(width: 42)
            }

            HStack(spacing: 6) {
                KeyboardKey(title: "next keyboard", systemImage: "globe", style: .utility, action: onNextKeyboard)
                    .frame(width: 44)
                KeyboardKey(title: "space", text: "space", style: .space, action: onSpace)
                KeyboardKey(title: "return", text: "return", style: .utility, action: onReturn)
                    .frame(width: 76)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .background(Color(uiColor: KeyboardPalette.backgroundColor))
    }

    private var recordBar: some View {
        HStack(spacing: 8) {
            Button(action: onPrimaryAction) {
                HStack(spacing: 8) {
                    Image(systemName: recordIcon)
                        .font(.system(size: 15, weight: .semibold))
                    Text(recordTitle)
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .foregroundColor(.white)
                .background(recordColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.state == .processing)

            if model.state == .recording || model.state == .paused {
                Button(action: onPauseAction) {
                    Image(systemName: model.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .foregroundColor(.primary)
                        .background(Color(uiColor: KeyboardPalette.utilityKeyColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func letterRow(_ keys: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                KeyboardKey(
                    title: key,
                    text: isShifted ? key.uppercased() : key,
                    style: .letter,
                    action: { onKeyPress(isShifted ? key.uppercased() : key) }
                )
            }
        }
    }

    private var recordTitle: String {
        switch model.state {
        case .idle: return "Record"
        case .recording: return "Stop"
        case .paused: return "Resume"
        case .processing: return "Transcribing"
        @unknown default: return "Record"
        }
    }

    private var recordIcon: String {
        switch model.state {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .paused: return "play.fill"
        case .processing: return "waveform"
        @unknown default: return "mic.fill"
        }
    }

    private var recordColor: Color {
        switch model.state {
        case .recording: return .red
        case .paused: return .orange
        case .processing: return .gray
        case .idle: return Color(uiColor: .systemOrange)
        @unknown default: return Color(uiColor: .systemOrange)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
        .accessibilityLabel(title)
    }

    private var backgroundColor: Color {
        switch style {
        case .letter, .space:
            return Color(uiColor: KeyboardPalette.keyColor)
        case .utility:
            return Color(uiColor: KeyboardPalette.utilityKeyColor)
        }
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
