import SwiftUI

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

// MARK: - Processing Wave Animation

public struct ProcessingWaveView: View {
    public var color: Color = .white

    public init(color: Color = .white) {
        self.color = color
    }

    private let cycleDuration: TimeInterval = 2.2

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
            let litRange = AIDictationWaveMetrics.litRange(for: progress)

            GeometryReader { proxy in
                let scale = AIDictationWaveMetrics.scale(for: proxy.size)

                HStack(spacing: AIDictationWaveMetrics.spacing * scale) {
                    ForEach(0 ..< AIDictationWaveMetrics.count, id: \.self) { index in
                        let isLit = litRange.contains(index)
                        Circle()
                            .fill(color)
                            .frame(
                                width: AIDictationWaveMetrics.dotSize * scale,
                                height: AIDictationWaveMetrics.dotSize * scale
                            )
                            .brightness(isLit ? 0 : -0.34)
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
