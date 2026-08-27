import SwiftUI
import WhisperMateShared

struct RecordingOverlayView: View {
    @ObservedObject var manager: OverlayWindowManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var shouldShowExpandedPill = false
    @State private var shouldShowContent = false
    @State private var expansionWorkItem: DispatchWorkItem?
    @State private var contentWorkItem: DispatchWorkItem?
    @State private var buttonRevealWorkItem: DispatchWorkItem?
    @State private var shouldShowRecordingButtons = false
    @State private var isPointingHandCursorActive = false
    @State private var isCancelButtonHovering = false
    @State private var isStopButtonHovering = false

    // MARK: - Size Constants (single source of truth)

    private static let overlayScale: CGFloat = 0.75

    // Recording/Processing state
    private let activeStateWidth: CGFloat = 118 * RecordingOverlayView.overlayScale
    private let recordingControlsStateWidth: CGFloat = 182 * RecordingOverlayView.overlayScale
    private let activeStateHeight: CGFloat = 30 * RecordingOverlayView.overlayScale
    private let waveSpanWidth: CGFloat = OverlayWaveMetrics.rowWidth

    // Idle state
    private let idleStateWidth: CGFloat = 21
    private let idleStateHeight: CGFloat = 1
    private let idleHoverHitSlop: CGFloat = 16

    // Spacing and padding
    private let activePadding: CGFloat = 15 * RecordingOverlayView.overlayScale
    private let recordingControlsPadding: CGFloat = 6 * RecordingOverlayView.overlayScale
    private let idlePaddingNormal: CGFloat = 16
    private let edgeMargin: CGFloat = 2 * RecordingOverlayView.overlayScale
    private let buttonSize: CGFloat = 28 * RecordingOverlayView.overlayScale
    private let cancelIconSize: CGFloat = 12 * RecordingOverlayView.overlayScale
    private let stopIconSize: CGFloat = 11 * RecordingOverlayView.overlayScale

    // MARK: - Computed Properties

    private var recordingWithControls: Bool {
        manager.isRecording && manager.showsRecordingControls
    }

    private var usesExpandedGeometry: Bool {
        shouldShowExpandedPill || manager.isProcessing || recordingWithControls
    }

    private var isCollapsedIdleState: Bool {
        !manager.isRecording && !manager.isProcessing && !shouldShowExpandedPill
    }

    private var idleHoverTopHitPadding: CGFloat {
        if usesExpandedGeometry {
            return 0
        }
        return idleHoverHitSlop
    }

    private var verticalPadding: CGFloat {
        usesExpandedGeometry ? 4.5 * RecordingOverlayView.overlayScale : 3
    }

    private var backgroundColor: Color {
        if manager.isCommandMode {
            return Color.blue // System blue for command mode
        }
        if manager.isRecording || manager.isProcessing || shouldShowExpandedPill {
            return themedColor
        }
        return Color.dsMuted.opacity(0.94)
    }

    private var idleBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.16)
    }

    private var themedColor: Color {
        manager.colorTheme.color
    }

    // MARK: - Animation Constants

    private let collapseDuration: TimeInterval = 0.15
    private let contentRevealDelay: TimeInterval = 0.26
    private let contentFadeDuration: TimeInterval = 0.14

    /// Content leaves faster than it arrives. The pill collapse runs for
    /// `collapseDuration`; fading the dots on the same clock (and with
    /// easeInOut, which holds opacity high through the first half) left them
    /// visibly sitting in a pill that had already shrunk away.
    private let contentHideDuration: TimeInterval = 0.06
    private let buttonRevealDelay: TimeInterval = 0.09

    private var morphAnimation: Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.26)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: manager.position == .top ? .top : .bottom) {
                overlayContent(geometry: geometry)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
        }
        .onAppear {
            // Handle view appearing while already active
            if manager.isRecording || manager.isProcessing {
                shouldShowExpandedPill = true
                shouldShowContent = true
                shouldShowRecordingButtons = manager.isRecording && manager.showsRecordingControls
            }
        }
        .onChange(of: manager.isRecording) { newValue in
            if newValue {
                updateHoverCursor(isActive: false)
                if manager.showsRecordingControls {
                    scheduleRecordingButtonsIfNeeded()
                    expandUsingRecordingPath(revealContent: true)
                }
            } else if !manager.isProcessing {
                hideRecordingButtons()
                // Cancel any pending expansion work items
                expansionWorkItem?.cancel()
                contentWorkItem?.cancel()
                expansionWorkItem = nil
                contentWorkItem = nil

                // Drop the dots on their own short curve so they are gone
                // before the pill finishes collapsing around them.
                withAnimation(.easeOut(duration: contentHideDuration)) {
                    shouldShowContent = false
                }
                withAnimation(.easeOut(duration: collapseDuration)) {
                    shouldShowExpandedPill = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration) {
                    manager.onCollapseAnimationComplete()
                }
            }
        }
        .onChange(of: manager.isProcessing) { newValue in
            if newValue {
                updateHoverCursor(isActive: false)
                hideRecordingButtons()
                if !manager.isRecording {
                    expandUsingRecordingPath(revealContent: true)
                } else if manager.isRecording {
                    // Already expanded from recording, just keep expanded and keep showing content
                    shouldShowExpandedPill = true
                    shouldShowContent = true
                }
            } else if !manager.isRecording {
                hideRecordingButtons()
                // Cancel any pending work items
                expansionWorkItem?.cancel()
                contentWorkItem?.cancel()
                expansionWorkItem = nil
                contentWorkItem = nil

                // Drop the dots on their own short curve so they are gone
                // before the pill finishes collapsing around them.
                withAnimation(.easeOut(duration: contentHideDuration)) {
                    shouldShowContent = false
                }
                withAnimation(.easeOut(duration: collapseDuration)) {
                    shouldShowExpandedPill = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration) {
                    manager.onCollapseAnimationComplete()
                }
            }
        }
        .onChange(of: manager.showsRecordingControls) { visible in
            if manager.isRecording && visible {
                scheduleRecordingButtonsIfNeeded()
            } else {
                hideRecordingButtons()
            }
        }
        .onDisappear {
            hideRecordingButtons()
            updateHoverCursor(isActive: false)
        }
    }

    @ViewBuilder
    private func overlayContent(geometry _: GeometryProxy) -> some View {
        Group {
            if let permissionIssue = manager.permissionIssue {
                HStack(spacing: OverlayPermissionCalloutMetrics.spacing) {
                    Color.clear
                        .frame(
                            width: OverlayPermissionCalloutMetrics.width,
                            height: OverlayPermissionCalloutMetrics.height
                        )
                        .allowsHitTesting(false)

                    contentView

                    permissionCallout(permissionIssue)
                }
            } else {
                contentView
            }
        }
        .padding(.top, idleHoverTopHitPadding)
        .fixedSize()
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .center) // Center horizontally only
        .onHover { hovering in
            isHovering = hovering || manager.isHoverExpanded
            updateHoverCursor(isActive: hovering && !manager.isRecording && !manager.isProcessing)
        }
        .onTapGesture {
            if !manager.isRecording && !manager.isProcessing {
                updateHoverCursor(isActive: false)
                manager.startRecordingFromOverlay()
            }
        }
        .padding(manager.position == .top ? .top : .bottom, edgeMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: manager.position == .top ? .top : .bottom) // Position vertically
        .onChange(of: manager.isHoverExpanded) { expanded in
            guard !manager.isProcessing, !manager.showsRecordingControls else { return }
            isHovering = expanded
            if expanded {
                expandUsingRecordingPath(revealContent: true, delayed: false, contentDelay: 0)
            } else {
                collapseIdleHover()
            }
        }
    }

    private func permissionCallout(_ issue: OverlayPermissionIssue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: issue.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text(issue.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("Set Up") {
                updateHoverCursor(isActive: false)
                manager.setUpPermission()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color.orange)
            .accessibilityLabel("Set up \(issue.message.lowercased())")
        }
        .padding(.horizontal, 10)
        .frame(
            width: OverlayPermissionCalloutMetrics.width,
            height: OverlayPermissionCalloutMetrics.height
        )
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.86))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
                }
        }
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var contentView: some View {
        let targetContentWidth = shouldShowExpandedPill ? (recordingWithControls ? recordingControlsStateWidth : activeStateWidth) : idleStateWidth
        let targetContentHeight = shouldShowExpandedPill ? activeStateHeight : idleStateHeight
        let targetHorizontalPadding = shouldShowExpandedPill ? (recordingWithControls ? recordingControlsPadding : activePadding) : idlePaddingNormal
        let targetVerticalPadding = verticalPadding
        let targetPillWidth = targetContentWidth + (targetHorizontalPadding * 2)
        let targetPillHeight = targetContentHeight + (targetVerticalPadding * 2)

        ZStack {
            Capsule()
                .fill(backgroundColor)
                .shadow(
                    color: .black.opacity(0.08),
                    radius: 2 * RecordingOverlayView.overlayScale,
                    x: 0,
                    y: 1 * RecordingOverlayView.overlayScale
                )
                .frame(width: targetPillWidth, height: targetPillHeight)
                .overlay {
                    if isCollapsedIdleState {
                        Capsule()
                            .stroke(idleBorderColor, lineWidth: 0.75)
                    }
                }

            // Overlay the actual content only when expanded and showing
            if manager.isRecording && manager.showsRecordingControls && shouldShowContent {
                ZStack {
                    centeredWaveContent(
                        OverlayLiveWaveView(audioLevel: manager.audioLevel, frequencyBands: manager.frequencyBands, color: .white.opacity(0.95)),
                        targetWidth: targetPillWidth,
                        targetHeight: targetPillHeight
                    )

                    HStack(spacing: 0) {
                        cancelButton
                            .opacity(shouldShowRecordingButtons ? 1 : 0)
                            .scaleEffect(shouldShowRecordingButtons ? 1 : 0.74)
                        Spacer(minLength: 0)
                        stopButton
                            .opacity(shouldShowRecordingButtons ? 1 : 0)
                            .scaleEffect(shouldShowRecordingButtons ? 1 : 0.74)
                    }
                    .padding(.horizontal, recordingControlsPadding)
                    .frame(width: targetPillWidth, height: targetPillHeight)
                    .allowsHitTesting(shouldShowRecordingButtons)
                    .animation(morphAnimation, value: shouldShowRecordingButtons)
                }
                .frame(width: targetPillWidth, height: targetPillHeight)
            } else if manager.isRecording && shouldShowContent {
                centeredWaveContent(
                    OverlayLiveWaveView(audioLevel: manager.audioLevel, frequencyBands: manager.frequencyBands, color: .white.opacity(0.95)),
                    targetWidth: targetPillWidth,
                    targetHeight: targetPillHeight
                )
            } else if manager.isProcessing && shouldShowContent {
                centeredWaveContent(
                    OverlayLoadingDotsView(color: .white.opacity(0.72)),
                    targetWidth: targetPillWidth,
                    targetHeight: targetPillHeight
                )
            } else if shouldShowExpandedPill && shouldShowContent {
                centeredWaveContent(
                    OverlayIdleDotsView(color: .white.opacity(0.92)),
                    targetWidth: targetPillWidth,
                    targetHeight: targetPillHeight
                )
            }
        }
        .frame(width: targetPillWidth, height: targetPillHeight)
        .animation(morphAnimation, value: shouldShowExpandedPill)
        .animation(morphAnimation, value: manager.isRecording)
        .animation(morphAnimation, value: manager.showsRecordingControls)
        .animation(
            shouldShowContent
                ? .easeOut(duration: contentFadeDuration)
                : .easeOut(duration: contentHideDuration),
            value: shouldShowContent
        )
    }

    private func centeredWaveContent<Wave: View>(
        _ wave: Wave,
        targetWidth: CGFloat,
        targetHeight: CGFloat
    ) -> some View {
        HStack(spacing: 8 * RecordingOverlayView.overlayScale) {
            Spacer(minLength: 0)
            wave
                .frame(width: waveSpanWidth, height: activeStateHeight)
            Spacer(minLength: 0)
        }
        .frame(width: targetWidth, height: targetHeight)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96)),
                removal: .opacity
            )
        )
    }

    private var cancelButton: some View {
        Button(action: {
            updateHoverCursor(isActive: false)
            AppState.shared.cancelRecording()
        }) {
            Image(systemName: "xmark")
                .font(.system(size: cancelIconSize, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: buttonSize, height: buttonSize)
                .background(Circle().fill(Color.white.opacity(isCancelButtonHovering ? 0.28 : 0.18)))
        }
        .buttonStyle(.plain)
        .scaleEffect(isCancelButtonHovering ? 1.06 : 1)
        .contentShape(Circle())
        .onHover { hovering in
            isCancelButtonHovering = hovering
            updateHoverCursor(isActive: hovering)
        }
        .animation(.easeInOut(duration: 0.12), value: isCancelButtonHovering)
        .accessibilityLabel("Cancel recording")
    }

    private var stopButton: some View {
        Button(action: {
            updateHoverCursor(isActive: false)
            AppState.shared.stopRecording()
        }) {
            Image(systemName: "stop.fill")
                .font(.system(size: stopIconSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: buttonSize, height: buttonSize)
                .background(Circle().fill(Color.black.opacity(isStopButtonHovering ? 0.4 : 0.28)))
        }
        .buttonStyle(.plain)
        .scaleEffect(isStopButtonHovering ? 1.06 : 1)
        .contentShape(Circle())
        .onHover { hovering in
            isStopButtonHovering = hovering
            updateHoverCursor(isActive: hovering)
        }
        .animation(.easeInOut(duration: 0.12), value: isStopButtonHovering)
        .accessibilityLabel("Stop recording")
    }

    private func expandUsingRecordingPath(revealContent: Bool, delayed: Bool = true, contentDelay: TimeInterval? = nil) {
        expansionWorkItem?.cancel()
        contentWorkItem?.cancel()

        if shouldShowExpandedPill {
            if revealContent {
                revealContentAfterDelay(shouldShowContent ? 0 : 0.02)
            } else {
                withAnimation(.easeInOut(duration: contentFadeDuration)) {
                    shouldShowContent = false
                }
            }
            return
        }

        shouldShowContent = false
        let expand = { [self] in
            withAnimation(morphAnimation) {
                shouldShowExpandedPill = true
            }

            if revealContent {
                revealContentAfterDelay(contentDelay ?? contentRevealDelay)
            }
        }

        if delayed {
            let expansionWork = DispatchWorkItem(block: expand)
            expansionWorkItem = expansionWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: expansionWork)
        } else {
            expand()
        }
    }

    private func revealContentAfterDelay(_ delay: TimeInterval) {
        contentWorkItem?.cancel()
        let contentWork = DispatchWorkItem {
            withAnimation(.easeInOut(duration: contentFadeDuration)) {
                shouldShowContent = true
            }
        }
        contentWorkItem = contentWork
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: contentWork)
    }

    private func scheduleRecordingButtonsIfNeeded() {
        guard manager.isRecording, manager.showsRecordingControls else { return }
        buttonRevealWorkItem?.cancel()
        shouldShowRecordingButtons = false
        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.16)) {
                shouldShowRecordingButtons = true
            }
        }
        buttonRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + buttonRevealDelay, execute: workItem)
    }

    private func hideRecordingButtons() {
        buttonRevealWorkItem?.cancel()
        buttonRevealWorkItem = nil
        shouldShowRecordingButtons = false
        isCancelButtonHovering = false
        isStopButtonHovering = false
    }

    private func collapseIdleHover() {
        expansionWorkItem?.cancel()
        contentWorkItem?.cancel()
        buttonRevealWorkItem?.cancel()
        expansionWorkItem = nil
        contentWorkItem = nil
        buttonRevealWorkItem = nil
        shouldShowRecordingButtons = false
        shouldShowContent = false
        withAnimation(.easeOut(duration: collapseDuration)) {
            shouldShowExpandedPill = false
        }
    }

    private func updateHoverCursor(isActive: Bool) {
        guard isActive != isPointingHandCursorActive else { return }
        if isActive {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
        isPointingHandCursorActive = isActive
    }
}

private enum OverlayWaveMetrics {
    static let count = 10
    static let dotSize: CGFloat = 4
    static let spacing: CGFloat = 4.75
    static let rowWidth: CGFloat = (dotSize * CGFloat(count)) + (spacing * CGFloat(count - 1))
    static let maxBarHeight: CGFloat = 18 * 0.75
    static let cornerRadius: CGFloat = dotSize / 2
}

private struct OverlayIdleDotsView: View {
    let color: Color

    var body: some View {
        HStack(spacing: OverlayWaveMetrics.spacing) {
            ForEach(0 ..< OverlayWaveMetrics.count, id: \.self) { _ in
                Circle()
                    .fill(color)
                    .frame(width: OverlayWaveMetrics.dotSize, height: OverlayWaveMetrics.dotSize)
            }
        }
    }
}

private struct OverlayLiveWaveView: View {
    let audioLevel: Float
    let frequencyBands: [Float]
    let color: Color

    private var normalizedAudioLevel: CGFloat {
        max(0, min(1, CGFloat(audioLevel)))
    }

    private var shouldUseFrequencyBands: Bool {
        guard frequencyBands.count == OverlayWaveMetrics.count else { return false }
        let peak = frequencyBands.map { abs($0) }.max() ?? 0
        return peak > 0.015 || normalizedAudioLevel <= 0.015
    }

    private func height(for index: Int) -> CGFloat {
        if shouldUseFrequencyBands {
            let magnitude = max(0, min(1, CGFloat(frequencyBands[index])))
            return OverlayWaveMetrics.dotSize + ((OverlayWaveMetrics.maxBarHeight - OverlayWaveMetrics.dotSize) * magnitude)
        }

        let center = CGFloat(OverlayWaveMetrics.count - 1) / 2
        let distanceFromCenter = abs(CGFloat(index) - center) / center
        let waveformFactor = 1 - (distanceFromCenter * distanceFromCenter)
        return OverlayWaveMetrics.dotSize + ((OverlayWaveMetrics.maxBarHeight - OverlayWaveMetrics.dotSize) * normalizedAudioLevel * waveformFactor)
    }

    var body: some View {
        HStack(spacing: OverlayWaveMetrics.spacing) {
            ForEach(0 ..< OverlayWaveMetrics.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: OverlayWaveMetrics.cornerRadius)
                    .fill(color)
                    .frame(width: OverlayWaveMetrics.dotSize, height: max(OverlayWaveMetrics.dotSize, height(for: index)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: audioLevel)
        .animation(.easeOut(duration: 0.12), value: frequencyBands)
    }
}

private struct OverlayLoadingDotsView: View {
    let color: Color
    private let cycleDuration: TimeInterval = 2.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
            let litRange = litRange(for: progress)

            HStack(spacing: OverlayWaveMetrics.spacing) {
                ForEach(0 ..< OverlayWaveMetrics.count, id: \.self) { index in
                    let isLit = litRange.contains(index)
                    Circle()
                        .fill(color)
                        .frame(width: OverlayWaveMetrics.dotSize, height: OverlayWaveMetrics.dotSize)
                        .opacity(isLit ? 1 : 0.28)
                        .scaleEffect(isLit ? 1.04 : 1)
                }
            }
        }
    }

    private func litRange(for progress: Double) -> ClosedRange<Int> {
        let lastIndex = OverlayWaveMetrics.count - 1

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

    private func easeInOut(_ value: Double) -> Double {
        if value < 0.5 {
            return 2 * value * value
        }
        return 1 - pow(-2 * value + 2, 2) / 2
    }
}

#Preview {
    let manager = OverlayWindowManager.shared
    manager.isRecording = true
    manager.isProcessing = false
    return RecordingOverlayView(manager: manager)
        .frame(width: 400, height: 200)
}
