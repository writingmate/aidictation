import Combine
import SwiftUI

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

public enum AIDictationRecordingState: Equatable {
    case idle
    case recording
    case paused
    case processing

    public var isActive: Bool {
        self != .idle
    }

    public var showsWave: Bool {
        self == .recording || self == .paused
    }

    public var showsPauseButton: Bool {
        self == .recording || self == .paused
    }
}

public final class AIDictationRecordingViewModel: ObservableObject {
    @Published public var state: AIDictationRecordingState
    @Published public var audioLevel: Float
    @Published public var frequencyBands: [Float]

    public init(
        state: AIDictationRecordingState = .idle,
        audioLevel: Float = 0.0,
        frequencyBands: [Float] = Array(repeating: 0.0, count: 10)
    ) {
        self.state = state
        self.audioLevel = audioLevel
        self.frequencyBands = frequencyBands
    }
}

public struct AIDictationRecordingSurface: View {
    @ObservedObject public var model: AIDictationRecordingViewModel
    public let onPrimaryAction: () -> Void
    public let onPauseAction: () -> Void

    private let customBackgroundColor: Color?
    private let visualizerHeight: CGFloat = 86
    private let visualizerWidth: CGFloat = 170
    private let primaryButtonSize: CGFloat = 80
    private let secondaryButtonSize: CGFloat = 54
    private let buttonGap: CGFloat = 14
    private let visualColor = Color.white
    private let stateAnimation = Animation.spring(response: 0.32, dampingFraction: 0.82, blendDuration: 0.06)
    private let fadeAnimation = Animation.easeInOut(duration: 0.18)

    public init(
        model: AIDictationRecordingViewModel,
        backgroundColor: Color? = nil,
        onPrimaryAction: @escaping () -> Void,
        onPauseAction: @escaping () -> Void
    ) {
        self.model = model
        self.customBackgroundColor = backgroundColor
        self.onPrimaryAction = onPrimaryAction
        self.onPauseAction = onPauseAction
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                backgroundColor
                    .ignoresSafeArea()

                visualizer
                    .frame(width: visualizerWidth, height: visualizerHeight)
                    .position(x: proxy.size.width / 2, y: visualizerCenterY(in: proxy.size))
                    .opacity(state.isActive ? 1 : 0)
                    .scaleEffect(state.isActive ? 1 : 0.72)
                    .offset(y: state.isActive ? 0 : 16)

                controls
                    .position(x: proxy.size.width / 2, y: controlCenterY(in: proxy.size))
            }
        }
        .animation(stateAnimation, value: state)
    }

    private var state: AIDictationRecordingState {
        model.state
    }

    private var backgroundColor: Color {
        if let customBackgroundColor {
            return customBackgroundColor
        }

        #if canImport(UIKit)
            return Color(uiColor: UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
                    : UIColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 1.0)
            })
        #elseif canImport(AppKit)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return dark
                    ? NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
                    : NSColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 1.0)
            })
        #else
            return Color(red: 0.88, green: 0.90, blue: 0.92)
        #endif
    }

    private func visualizerCenterY(in size: CGSize) -> CGFloat {
        size.height * 0.44
    }

    private func controlCenterY(in size: CGSize) -> CGFloat {
        size.height * 0.74
    }

    private var visualizer: some View {
        ZStack {
            AudioVisualizationView(audioLevel: model.audioLevel, color: visualColor, frequencyBands: model.frequencyBands)
                .opacity(state.showsWave ? 1 : 0)
                .scaleEffect(state.showsWave ? 1 : 0.94)

            ProcessingWaveView(color: visualColor)
                .opacity(state == .processing ? 1 : 0)
                .scaleEffect(state == .processing ? 1 : 0.94)
        }
        .animation(fadeAnimation, value: state)
    }

    private var controls: some View {
        ZStack {
            primaryButton
                .opacity(state == .processing ? 0 : 1)
                .scaleEffect(state == .processing ? 0.82 : 1)
                .allowsHitTesting(state != .processing)

            pauseButton
                .offset(x: state.showsPauseButton ? primaryButtonSize / 2 + buttonGap + secondaryButtonSize / 2 : 20)
                .opacity(state.showsPauseButton ? 1 : 0)
                .scaleEffect(state.showsPauseButton ? 1 : 0.72)
                .allowsHitTesting(state.showsPauseButton)
        }
        .frame(width: primaryButtonSize + buttonGap + secondaryButtonSize, height: primaryButtonSize)
    }

    private var primaryButton: some View {
        Button(action: onPrimaryAction) {
            AIDictationMicButtonVisual(
                state: state,
                audioLevel: model.audioLevel,
                frequencyBands: model.frequencyBands,
                size: primaryButtonSize
            )
            .shadow(color: .black.opacity(state.isActive ? 0.45 : 0.18), radius: state.isActive ? 10 : 8, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .idle ? "Start recording" : "Stop recording")
    }

    private var pauseButton: some View {
        Button(action: onPauseAction) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: secondaryButtonSize, height: secondaryButtonSize)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )

                Image(systemName: state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .paused ? "Resume recording" : "Pause recording")
    }
}
