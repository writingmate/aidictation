import SwiftUI

public enum AIDictationMicButtonStyle {
    case app
    case keyboard
}

public struct AIDictationMicButtonVisual: View {
    public let state: AIDictationRecordingState
    public let audioLevel: Float
    public let frequencyBands: [Float]?
    public var size: CGFloat
    public var style: AIDictationMicButtonStyle

    public init(
        state: AIDictationRecordingState,
        audioLevel: Float = 0,
        frequencyBands: [Float]? = nil,
        size: CGFloat = 100,
        style: AIDictationMicButtonStyle = .app
    ) {
        self.state = state
        self.audioLevel = audioLevel
        self.frequencyBands = frequencyBands
        self.size = size
        self.style = style
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: MicButtonMetrics.processingDuration)
                / MicButtonMetrics.processingDuration

            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: size, height: size)

                if style == .keyboard, state == .recording {
                    Image(systemName: "checkmark")
                        .font(.system(size: 23 * scale, weight: .bold))
                        .foregroundColor(iconColor)
                        .transition(.opacity.combined(with: .scale(scale: 0.76)))
                } else if state == .recording {
                    RoundedRectangle(cornerRadius: MicButtonMetrics.stopCornerRadius * scale, style: .continuous)
                        .fill(iconColor)
                        .frame(width: MicButtonMetrics.stopSize * scale, height: MicButtonMetrics.stopSize * scale)
                        .transition(.opacity.combined(with: .scale(scale: 0.76)))
                } else {
                    HStack(spacing: MicButtonMetrics.barSpacing * scale) {
                        ForEach(0 ..< MicButtonMetrics.barCount, id: \.self) { index in
                            RoundedRectangle(cornerRadius: MicButtonMetrics.barWidth * scale / 2)
                                .fill(iconColor)
                                .frame(
                                    width: MicButtonMetrics.barWidth * scale,
                                    height: barHeight(at: index, phase: phase)
                                )
                                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: audioLevel)
                                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: frequencyBands ?? [])
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.84)))
                }
            }
            .frame(width: size, height: size)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: state)
        }
    }

    private var backgroundColor: Color {
        switch (style, state) {
        case (.keyboard, .recording):
            return .primary
        case (.keyboard, .processing):
            return .secondary
        default:
            return Color.dsPrimary
        }
    }

    private var iconColor: Color {
        switch (style, state) {
        case (.keyboard, .recording), (.keyboard, .processing):
            return Color(uiColor: .systemBackground)
        default:
            return .white
        }
    }

    private var scale: CGFloat {
        size / MicButtonMetrics.referenceSize
    }

    private func barHeight(at index: Int, phase: TimeInterval) -> CGFloat {
        let dotSize = MicButtonMetrics.barWidth * scale
        let maxHeight = MicButtonMetrics.maxBarHeight * scale
        let heightRange = maxHeight - dotSize
        let normalizedHeight: CGFloat

        switch state {
        case .idle, .paused:
            normalizedHeight = MicButtonMetrics.frozenHeights[index]
        case .recording:
            normalizedHeight = recordingHeight(at: index)
        case .processing:
            let progress = CGFloat(phase)
            let normalizedIndex = CGFloat(index) / CGFloat(MicButtonMetrics.barCount - 1)
            let wavePosition = (normalizedIndex * 2 * .pi) - (progress * 2 * .pi)
            let sineValue = (sin(wavePosition) + 1) / 2
            normalizedHeight = sineValue * MicButtonMetrics.circleEnvelopeHeights[index]
        }

        return dotSize + (heightRange * normalizedHeight)
    }

    private func recordingHeight(at index: Int) -> CGFloat {
        let boostedLevel = boostWaveformLevel(CGFloat(audioLevel))
        let activeBarCount = min(
            MicButtonMetrics.barCount,
            max(MicButtonMetrics.minimumActiveBars, MicButtonMetrics.minimumActiveBars + Int(CGFloat(MicButtonMetrics.barCount - MicButtonMetrics.minimumActiveBars) * boostedLevel * 2.5))
        )
        let barsFromEdge = (MicButtonMetrics.barCount - activeBarCount) / 2
        let minimumDistanceFromEdge = min(index, MicButtonMetrics.barCount - 1 - index)

        guard minimumDistanceFromEdge >= barsFromEdge else {
            return 0
        }

        let bandValue = recordingBandValue(at: index)
        let boostedBand = boostWaveformLevel(bandValue, overallLevel: CGFloat(audioLevel))
        return boostedBand * MicButtonMetrics.circleEnvelopeHeights[index]
    }

    private func recordingBandValue(at index: Int) -> CGFloat {
        guard let frequencyBands, !frequencyBands.isEmpty else {
            return CGFloat(audioLevel).clamped(to: 0 ... 1)
        }

        let sourcePosition = CGFloat(index) * CGFloat(frequencyBands.count - 1) / CGFloat(MicButtonMetrics.barCount - 1)
        let lowerIndex = min(max(Int(sourcePosition), 0), frequencyBands.count - 1)
        let upperIndex = min(lowerIndex + 1, frequencyBands.count - 1)
        let fraction = sourcePosition - CGFloat(lowerIndex)
        let lower = CGFloat(frequencyBands[lowerIndex]).clamped(to: 0 ... 1)
        let upper = CGFloat(frequencyBands[upperIndex]).clamped(to: 0 ... 1)
        let interpolated = lower + ((upper - lower) * fraction)
        let average = frequencyBands
            .map { CGFloat($0).clamped(to: 0 ... 1) }
            .reduce(0, +) / CGFloat(frequencyBands.count)
        let contrasted = interpolated + ((interpolated - average) * MicButtonMetrics.waveformContrast)
        let floor = audioLevel > Float(MicButtonMetrics.waveformFloorThreshold) ? CGFloat(audioLevel) * 0.18 : 0
        return max(contrasted, floor).clamped(to: 0 ... 1)
    }

    private func boostWaveformLevel(_ level: CGFloat, overallLevel: CGFloat? = nil) -> CGFloat {
        let mixedOverallLevel = overallLevel ?? level
        let mixed = ((level * MicButtonMetrics.waveformLevelGain) + (mixedOverallLevel * MicButtonMetrics.waveformLevelMix)).clamped(to: 0 ... 1)
        let eased = sqrt(mixed)
        let floor = mixedOverallLevel > MicButtonMetrics.waveformFloorThreshold ? MicButtonMetrics.waveformActiveFloor : 0
        return max(eased, floor).clamped(to: 0 ... 1)
    }
}

private enum MicButtonMetrics {
    static let referenceSize: CGFloat = 100
    static let barCount = 5
    static let minimumActiveBars = 3
    static let barWidth: CGFloat = 9.2
    static let barSpacing: CGFloat = 4.4
    static let maxBarHeight: CGFloat = 49.6
    static let stopSize: CGFloat = 34
    static let stopCornerRadius: CGFloat = 6
    static let processingDuration: TimeInterval = 0.9
    static let frozenHeights: [CGFloat] = [0.56, 1, 0.56, 1, 0.56]
    static let circleEnvelopeHeights: [CGFloat] = [0.72, 0.94, 1, 0.94, 0.72]
    static let waveformLevelGain: CGFloat = 1.35
    static let waveformLevelMix: CGFloat = 0.08
    static let waveformContrast: CGFloat = 0.8
    static let waveformFloorThreshold: CGFloat = 0.045
    static let waveformActiveFloor: CGFloat = 0.16
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

public struct AudioVisualizationView: View {
    public let audioLevel: Float
    public let frequencyBands: [Float]?
    public var color: Color = .blue

    public init(audioLevel: Float, color: Color = .blue, frequencyBands: [Float]? = nil) {
        self.audioLevel = audioLevel
        self.color = color
        self.frequencyBands = frequencyBands
    }

    private func barHeight(for index: Int) -> CGFloat {
        if let bands = frequencyBands, bands.count == AIDictationWaveMetrics.count {
            let magnitude = max(0, min(1, CGFloat(bands[index])))
            return AIDictationWaveMetrics.dotSize + ((AIDictationWaveMetrics.maxBarHeight - AIDictationWaveMetrics.dotSize) * magnitude)
        }

        let center = CGFloat(AIDictationWaveMetrics.count - 1) / 2
        let distanceFromCenter = abs(CGFloat(index) - center) / center
        let waveformFactor = 1.0 - (distanceFromCenter * distanceFromCenter)
        let level = max(0, min(1, CGFloat(audioLevel)))
        return AIDictationWaveMetrics.dotSize + ((AIDictationWaveMetrics.maxBarHeight - AIDictationWaveMetrics.dotSize) * level * waveformFactor)
    }

    public var body: some View {
        GeometryReader { proxy in
            let scale = AIDictationWaveMetrics.scale(for: proxy.size)

            HStack(spacing: AIDictationWaveMetrics.spacing * scale) {
                ForEach(0 ..< AIDictationWaveMetrics.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: AIDictationWaveMetrics.cornerRadius * scale)
                        .fill(color)
                        .frame(
                            width: AIDictationWaveMetrics.dotSize * scale,
                            height: max(AIDictationWaveMetrics.dotSize, barHeight(for: index)) * scale
                        )
                }
            }
            .frame(width: AIDictationWaveMetrics.rowWidth * scale, height: AIDictationWaveMetrics.maxBarHeight * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.12), value: audioLevel)
        .animation(.easeOut(duration: 0.12), value: frequencyBands ?? [])
    }
}

public struct AIDictationActiveRecordingVisual: View {
    public let state: AIDictationRecordingState
    public let audioLevel: Float
    public let frequencyBands: [Float]
    public var color: Color

    public init(
        state: AIDictationRecordingState,
        audioLevel: Float,
        frequencyBands: [Float],
        color: Color = .white
    ) {
        self.state = state
        self.audioLevel = audioLevel
        self.frequencyBands = frequencyBands
        self.color = color
    }

    public var body: some View {
        ZStack {
            AudioVisualizationView(
                audioLevel: audioLevel,
                color: color,
                frequencyBands: frequencyBands
            )
            .opacity(state.showsWave ? 1 : 0)

            ProcessingWaveView(color: color)
                .opacity(state == .processing ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.18), value: state)
    }
}

// MARK: - Processing Wave Animation

public struct ProcessingWaveView: View {
    public var color: Color = .white

    public init(color: Color = .white) {
        self.color = color
    }

    private let cycleDuration: TimeInterval = 1.45

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration

            GeometryReader { proxy in
                let scale = AIDictationWaveMetrics.scale(for: proxy.size)

                HStack(spacing: AIDictationWaveMetrics.spacing * scale) {
                    ForEach(0 ..< AIDictationWaveMetrics.count, id: \.self) { index in
                        let highlight = AIDictationWaveMetrics.processingHighlight(for: index, progress: progress)
                        Circle()
                            .fill(color)
                            .frame(
                                width: AIDictationWaveMetrics.dotSize * scale,
                                height: AIDictationWaveMetrics.dotSize * scale
                            )
                            .opacity(0.28 + (highlight * 0.72))
                            .scaleEffect(0.86 + (highlight * 0.18))
                    }
                }
                .frame(width: AIDictationWaveMetrics.rowWidth * scale, height: AIDictationWaveMetrics.maxBarHeight * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private enum AIDictationWaveMetrics {
    static let count = 10
    static let dotSize: CGFloat = 4
    static let spacing: CGFloat = 4.75
    static let rowWidth: CGFloat = (dotSize * CGFloat(count)) + (spacing * CGFloat(count - 1))
    static let maxBarHeight: CGFloat = 18 * 0.75
    static let cornerRadius: CGFloat = dotSize / 2

    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else {
            return 1
        }

        let fittingScale = min(size.width / rowWidth, size.height / maxBarHeight)
        return max(1, min(3.2, fittingScale * 0.48))
    }

    static func processingHighlight(for index: Int, progress: Double) -> Double {
        let lastIndex = count - 1
        let travelProgress = progress < 0.5
            ? easeInOut(progress * 2)
            : easeInOut((1 - progress) * 2)
        let center = travelProgress * Double(lastIndex)
        let distance = abs(Double(index) - center)
        return max(0, 1 - (distance / 2.2))
    }

    static func litRange(for progress: Double) -> ClosedRange<Int> {
        let lastIndex = count - 1

        if progress < 0.32 {
            let local = easeInOut(progress / 0.32)
            return 0 ... Int(round(local * Double(lastIndex)))
        }

        if progress < 0.5 {
            let local = easeInOut((progress - 0.32) / 0.18)
            return Int(round(local * Double(lastIndex))) ... lastIndex
        }

        if progress < 0.82 {
            let local = easeInOut((progress - 0.5) / 0.32)
            return Int(round((1 - local) * Double(lastIndex))) ... lastIndex
        }

        let local = easeInOut((progress - 0.82) / 0.18)
        return 0 ... Int(round((1 - local) * Double(lastIndex)))
    }

    private static func easeInOut(_ value: Double) -> Double {
        if value < 0.5 {
            return 2 * value * value
        }
        return 1 - pow(-2 * value + 2, 2) / 2
    }
}

#Preview {
    VStack(spacing: 20) {
        AudioVisualizationView(audioLevel: 0.3)
            .frame(height: 40)
            .padding()

        AudioVisualizationView(audioLevel: 0.7)
            .frame(height: 40)
            .padding()

        AudioVisualizationView(audioLevel: 1.0)
            .frame(height: 40)
            .padding()

        ProcessingWaveView(color: .orange)
            .frame(height: 40)
            .padding()
            .background(Color.black.opacity(0.8))
    }
}
