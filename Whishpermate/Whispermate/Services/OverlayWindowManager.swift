import AppKit
import SwiftUI
import WhisperMateShared
internal import Combine
import AVFoundation

enum OverlayPosition: String, CaseIterable, Codable {
    case top = "Top"
    case bottom = "Bottom"
}

enum OverlayColorTheme: String, CaseIterable, Codable {
    case primary = "Primary"
    case blue = "Blue"
    case green = "Green"
    case orange = "Orange"
    case pink = "Pink"
    case graphite = "Graphite"
}

/// Custom NSWindow that doesn't become key or main, preventing app activation on click
private class NonActivatingWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Manages the floating overlay window that shows recording state and audio visualization
class OverlayWindowManager: ObservableObject {
    static let shared = OverlayWindowManager()

    // MARK: - Keys

    private enum Keys {
        static let overlayPosition = "overlayPosition"
        static let hideIdleState = "hideIdleState"
        static let overlayColorTheme = "overlayColorTheme"
    }

    // MARK: - Constants

    private enum Constants {
        static let overlayScale: CGFloat = 0.75
        static let stateChangeAnimationDelay: TimeInterval = 0.2
        static let positionPreviewDuration: TimeInterval = 2.0
        static let windowCreationDelay: TimeInterval = 0.05
        static let activeStateWidth: CGFloat = 168 * overlayScale
        static let recordingControlsStateWidth: CGFloat = 246 * overlayScale
        static let activeStateHeight: CGFloat = 30 * overlayScale
        static let activePadding: CGFloat = 15 * overlayScale
        static let recordingControlsPadding: CGFloat = 6 * overlayScale
        static let idleStateWidth: CGFloat = 21
        static let idleStateHeight: CGFloat = 1
        static let idleHoverHitSlop: CGFloat = 16
        static let idlePaddingNormal: CGFloat = 16
        static let edgeMargin: CGFloat = 2 * overlayScale
        static let verticalPaddingActive: CGFloat = 4.5 * overlayScale
        static let verticalPaddingIdle: CGFloat = 3
        static let windowSafetyPadding: CGFloat = 10
        static let hoverFrameInset: CGFloat = 4 * overlayScale
        static let frequencyBandCount: Int = 14
        static let windowResizeAnimationDuration: TimeInterval = 0.25
        static let hoverCollapseResizeDelay: TimeInterval = 0.18
    }

    // MARK: - Published Properties (derived from overlayState for view compatibility)

    @Published var isRecording = false
    @Published var isProcessing = false

    @Published var audioLevel: Float = 0.0 {
        didSet {
            if Int(oldValue * 10) != Int(audioLevel * 10) {
                DebugLog.info("audioLevel changed: \(oldValue) -> \(audioLevel)", context: "OverlayWindowManager")
            }
        }
    }

    @Published var frequencyBands: [Float] = Array(repeating: 0.0, count: Constants.frequencyBandCount)
    @Published var isOverlayMode = true {
        didSet {
            DebugLog.info("isOverlayMode changed: \(oldValue) -> \(isOverlayMode)", context: "OverlayWindowManager")
        }
    }

    @Published var position: OverlayPosition = {
        if let savedRawValue = AppDefaults.shared.string(forKey: Keys.overlayPosition),
           let savedPosition = OverlayPosition(rawValue: savedRawValue)
        {
            return savedPosition
        }
        return .bottom
    }() {
        didSet {
            AppDefaults.shared.set(position.rawValue, forKey: Keys.overlayPosition)

            DispatchQueue.main.async { [weak self] in
                self?.repositionWindow()

                self?.showAlways()
                DispatchQueue.main.asyncAfter(deadline: .now() + Constants.positionPreviewDuration) { [weak self] in
                    if !(self?.isRecording ?? false), !(self?.isProcessing ?? false) {
                        self?.hide()
                    }
                }
            }
        }
    }

    @Published var hideIdleState: Bool = AppDefaults.shared.bool(forKey: Keys.hideIdleState) {
        didSet {
            AppDefaults.shared.set(hideIdleState, forKey: Keys.hideIdleState)

            // When hideIdleState changes and we're in idle state, update visibility
            if overlayState == .idle {
                transition(to: hideIdleState ? .hidden : .idle)
            }
        }
    }

    /// Is currently in command mode (recording voice instruction)
    @Published var isCommandMode: Bool = false
    @Published private(set) var isHoverExpanded = false
    @Published private(set) var showsRecordingControls = false

    @Published var colorTheme: OverlayColorTheme = {
        if let savedRawValue = AppDefaults.shared.string(forKey: Keys.overlayColorTheme),
           let savedTheme = OverlayColorTheme(rawValue: savedRawValue)
        {
            return savedTheme
        }
        return .primary
    }() {
        didSet {
            AppDefaults.shared.set(colorTheme.rawValue, forKey: Keys.overlayColorTheme)
        }
    }

    // MARK: - Overlay State (single source of truth)

    enum OverlayState: Equatable {
        case hidden
        case idle
        case recording(isCommandMode: Bool)
        case processing(isCommandMode: Bool)
    }

    @Published private(set) var overlayState: OverlayState = .idle

    // MARK: - Private Properties

    private var overlayWindow: NSWindow?
    private var screenChangeObserver: Any?
    private var spaceChangeObserver: Any?
    private var appActivationObserver: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hoverTrackingTimer: Timer?
    private var frameAnimationTimer: Timer?
    private var hoverCollapseResizeWorkItem: DispatchWorkItem?
    private var audioLevelCancellable: AnyCancellable?
    private var frequencyBandsCancellable: AnyCancellable?
    private var suppressHoverExpansionUntilMouseExit = false
    private var keepIdleVisibleAfterCollapse = false

    // MARK: - Initialization

    private init() {
        setupScreenChangeObserver()
        setupSpaceChangeObserver()
        setupAppActivationObserver()
        setupMouseHoverMonitor()
        setupAudioObservers()
    }

    // MARK: - Public API

    func show() {
        DebugLog.info("show() called, overlayState=\(overlayState), hideIdleState=\(hideIdleState)", context: "OverlayWindowManager")
        logWindowState("show-before")
        if overlayWindow == nil {
            createWindow()
        }
        repositionWindow()
        overlayWindow?.orderFrontRegardless()
        logWindowState("show-after-orderFront")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.logWindowState("show-post-tick")
        }
    }

    func hide() {
        DebugLog.info("hide() called, overlayState=\(overlayState)", context: "OverlayWindowManager")
        logWindowState("hide-before")
        overlayWindow?.orderOut(nil)
        logWindowState("hide-after-orderOut")
    }

    // MARK: - State Transitions (single entry point for all state changes)

    /// Transition to a new overlay state - single source of truth for state changes
    func transition(to newState: OverlayState) {
        DebugLog.info("transition: \(overlayState) -> \(newState)", context: "OverlayWindowManager")
        logWindowState("transition-before")

        // Ensure we're on main thread for UI updates
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.transition(to: newState)
            }
            return
        }

        guard newState != overlayState else {
            DebugLog.info("transition: no-op, already in state \(newState)", context: "OverlayWindowManager")
            return
        }

        let previousState = overlayState
        overlayState = newState

        // Update derived properties for backward compatibility with views
        switch newState {
        case .hidden:
            hoverCollapseResizeWorkItem?.cancel()
            keepIdleVisibleAfterCollapse = false
            isRecording = false
            isProcessing = false
            isCommandMode = false
            showsRecordingControls = false
            overlayWindow?.orderOut(nil)
            DebugLog.info("transition: window hidden", context: "OverlayWindowManager")

        case .idle:
            hoverCollapseResizeWorkItem?.cancel()
            isRecording = false
            isProcessing = false
            isCommandMode = false
            showsRecordingControls = false
            isHoverExpanded = false
            ensureWindowExists()
            overlayWindow?.orderFrontRegardless()
            // If coming from active state, keep window large for collapse animation
            // View will call onCollapseAnimationComplete() when done
            let comingFromActive = previousState == .recording(isCommandMode: true) ||
                previousState == .recording(isCommandMode: false) ||
                previousState == .processing(isCommandMode: true) ||
                previousState == .processing(isCommandMode: false)
            if !comingFromActive {
                updateWindowSizeForState(newState, animated: false)
                keepIdleVisibleAfterCollapse = false
            }

        case let .recording(commandMode):
            hoverCollapseResizeWorkItem?.cancel()
            keepIdleVisibleAfterCollapse = false
            isRecording = true
            isProcessing = false
            isCommandMode = commandMode
            ensureWindowExists()
            overlayWindow?.orderFrontRegardless()
            if showsRecordingControls {
                isHoverExpanded = false
                updateWindowSizeForState(newState, animated: false, preserveAnchor: true)
            } else {
                if !isHoverExpanded {
                    isHoverExpanded = true
                    updateWindowSizeForState(.idle, animated: false, preserveAnchor: true)
                }
            }

        case let .processing(commandMode):
            hoverCollapseResizeWorkItem?.cancel()
            keepIdleVisibleAfterCollapse = false
            isRecording = false
            isProcessing = true
            isCommandMode = commandMode
            isHoverExpanded = false
            showsRecordingControls = false
            suppressHoverExpansionUntilMouseExit = true
            ensureWindowExists()
            overlayWindow?.orderFrontRegardless()
            updateWindowSizeForState(newState, animated: true, preserveAnchor: true)
        }

        ensureWindowOnActiveSpace(reason: "transition")
        logWindowState("transition-after")
    }

    func transitionToVisibleIdle() {
        keepIdleVisibleAfterCollapse = true
        transition(to: .idle)
    }

    private func ensureWindowExists() {
        if overlayWindow == nil {
            DebugLog.info("ensureWindowExists: creating window", context: "OverlayWindowManager")
            createWindow()
        }
    }

    private func updateWindowSizeForState(_ state: OverlayState, animated: Bool, preserveAnchor: Bool = false) {
        guard let window = overlayWindow, let screen = targetScreen() else {
            DebugLog.warning("updateWindowSizeForState skipped: window or target screen missing", context: "OverlayWindowManager")
            return
        }

        let screenFrame = screen.visibleFrame
        let isActive = state == .recording(isCommandMode: true) ||
            state == .recording(isCommandMode: false) ||
            state == .processing(isCommandMode: true) ||
            state == .processing(isCommandMode: false)

        let (windowWidth, windowHeight): (CGFloat, CGFloat)
        if case .recording = state {
            // Use the same invisible max-width stage for hover, Fn-held recording, and
            // overlay-click recording. The SwiftUI pill draws the smaller no-button
            // shape inside this stage when controls are hidden.
            windowWidth = Constants.recordingControlsStateWidth + (Constants.recordingControlsPadding * 2)
            windowHeight = Constants.activeStateHeight + (Constants.verticalPaddingActive * 2) + (Constants.edgeMargin * 2)
        } else if case .processing = state {
            windowWidth = Constants.recordingControlsStateWidth + (Constants.recordingControlsPadding * 2)
            windowHeight = Constants.activeStateHeight + (Constants.verticalPaddingActive * 2) + (Constants.edgeMargin * 2)
        } else if isActive {
            windowWidth = Constants.activeStateWidth + (Constants.activePadding * 2)
            windowHeight = Constants.activeStateHeight + (Constants.verticalPaddingActive * 2) + (Constants.edgeMargin * 2)
        } else if isHoverExpanded {
            windowWidth = Constants.recordingControlsStateWidth + (Constants.recordingControlsPadding * 2)
            windowHeight = Constants.activeStateHeight + (Constants.verticalPaddingActive * 2) + (Constants.edgeMargin * 2)
        } else {
            let maxWidth = Constants.idleStateWidth + (Constants.idlePaddingNormal * 2)
            windowWidth = maxWidth + Constants.windowSafetyPadding
            windowHeight = Constants.idleStateHeight + Constants.idleHoverHitSlop + (Constants.verticalPaddingIdle * 2) + (Constants.edgeMargin * 2)
        }

        let oldFrame = window.frame
        let newFrame: NSRect
        if preserveAnchor {
            let anchorX = oldFrame.midX
            let verticalAnchor = position == .bottom ? oldFrame.minY : oldFrame.maxY
            newFrame = NSRect(
                x: anchorX - (windowWidth / 2),
                y: position == .bottom ? verticalAnchor : verticalAnchor - windowHeight,
                width: windowWidth,
                height: windowHeight
            )
        } else {
            let (xPos, yPos) = calculatePosition(for: position, screenFrame: screenFrame, windowWidth: windowWidth, windowHeight: windowHeight)
            newFrame = NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight)
        }
        DebugLog.info(
            "updateWindowSizeForState state=\(state), animated=\(animated), preserveAnchor=\(preserveAnchor), screen=\(describeScreen(screen)), oldFrame=\(formatRect(oldFrame)), newFrame=\(formatRect(newFrame))",
            context: "OverlayWindowManager"
        )

        setWindowFrame(newFrame, animated: false)
        logWindowState("updateWindowSizeForState-after-setFrame")
    }

    // MARK: - Legacy API (for backward compatibility during migration)

    func updateState(isRecording: Bool, isProcessing: Bool) {
        DebugLog.info("updateState called - isRecording: \(isRecording), isProcessing: \(isProcessing)", context: "OverlayWindowManager")

        if isRecording {
            transition(to: .recording(isCommandMode: isCommandMode))
        } else if isProcessing {
            transition(to: .processing(isCommandMode: isCommandMode))
        } else if hideIdleState {
            transition(to: .hidden)
        } else {
            transition(to: .idle)
        }
    }

    func showAlways() {
        DebugLog.info("showAlways() - initializing overlay", context: "OverlayWindowManager")
        show()
    }

    func expandToFullMode() {
        // Don't show settings while onboarding is active
        if OnboardingManager.shared.showOnboarding {
            return
        }
        DebugLog.info("expandToFullMode() - bringing app to foreground", context: "OverlayWindowManager")
        NSApp.activate(ignoringOtherApps: true)
        if let window = findMainWindow() {
            window.makeKeyAndOrderFront(nil)
        } else {
            showMainSettingsWindow()
        }
    }

    func setHoverExpanded(_ expanded: Bool) {
        guard overlayState == .idle else { return }
        guard isHoverExpanded != expanded else { return }
        hoverCollapseResizeWorkItem?.cancel()
        hoverCollapseResizeWorkItem = nil
        isHoverExpanded = expanded
        if expanded {
            updateWindowSizeForState(.idle, animated: false, preserveAnchor: true)
        } else {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.overlayState == .idle, !self.isHoverExpanded else { return }
                self.updateWindowSizeForState(.idle, animated: false, preserveAnchor: true)
            }
            hoverCollapseResizeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.hoverCollapseResizeDelay, execute: workItem)
        }
    }

    func setRecordingControlsVisible(_ visible: Bool) {
        showsRecordingControls = visible
    }

    func startRecordingFromOverlay() {
        guard overlayState == .idle else { return }
        AppState.shared.startRecording(showOverlayControls: true)
    }

    func contractToOverlay() {
        DebugLog.info("contractToOverlay() - sending app to background", context: "OverlayWindowManager")
        if let window = findMainWindow() {
            window.orderOut(nil)
        }
        NSApp.hide(nil)
    }

    /// Called by the view when collapse animation completes
    func onCollapseAnimationComplete() {
        guard overlayState == .idle else { return }
        DebugLog.info("onCollapseAnimationComplete", context: "OverlayWindowManager")
        updateWindowSizeForState(.idle, animated: false, preserveAnchor: true)
        let shouldHideIdle = hideIdleState && !keepIdleVisibleAfterCollapse
        keepIdleVisibleAfterCollapse = false
        if shouldHideIdle {
            overlayWindow?.orderOut(nil)
        }
    }

    // MARK: - Private Methods

    private func formatRect(_ rect: NSRect) -> String {
        "x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private func describeScreen(_ screen: NSScreen?) -> String {
        guard let screen else { return "nil" }
        return "\(screen.localizedName) frame=\(formatRect(screen.frame)) visible=\(formatRect(screen.visibleFrame))"
    }

    private func describeWindow(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let visible = window.isVisible
        let onActiveSpace = window.isOnActiveSpace
        let occluded = window.occlusionState.contains(.visible) ? "visible" : "notVisible"
        return "frame=\(formatRect(window.frame)) visible=\(visible) activeSpace=\(onActiveSpace) occlusion=\(occluded) level=\(window.level.rawValue) behavior=\(window.collectionBehavior.rawValue) screen=\(describeScreen(window.screen))"
    }

    private func logWindowState(_ reason: String) {
        DebugLog.info("window[\(reason)] \(describeWindow(overlayWindow))", context: "OverlayWindowManager")
    }

    private func setWindowFrame(_ targetFrame: NSRect, animated: Bool) {
        guard let window = overlayWindow else { return }
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil

        guard animated else {
            window.setFrame(targetFrame, display: true)
            return
        }

        let startFrame = window.frame
        let targetCenterX = targetFrame.midX
        let targetVerticalAnchor = position == .bottom ? targetFrame.minY : targetFrame.maxY
        let startedAt = Date.timeIntervalSinceReferenceDate
        let duration = Constants.windowResizeAnimationDuration

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak window] timer in
            guard let self, let window else {
                timer.invalidate()
                return
            }

            let elapsed = Date.timeIntervalSinceReferenceDate - startedAt
            let progress = min(1, max(0, elapsed / duration))
            let eased = self.cssMorphEase(progress)
            let width = self.interpolate(from: startFrame.width, to: targetFrame.width, progress: eased)
            let height = self.interpolate(from: startFrame.height, to: targetFrame.height, progress: eased)
            let centerX = targetCenterX
            let originY = self.position == .bottom ? targetVerticalAnchor : targetVerticalAnchor - height
            let frame = NSRect(
                x: centerX - (width / 2),
                y: originY,
                width: width,
                height: height
            )

            window.setFrame(frame, display: true)

            if progress >= 1 {
                timer.invalidate()
                self.frameAnimationTimer = nil
                window.setFrame(targetFrame, display: true)
            }
        }

        frameAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func interpolate(from start: CGFloat, to end: CGFloat, progress: Double) -> CGFloat {
        start + ((end - start) * CGFloat(progress))
    }

    private func cssMorphEase(_ progress: Double) -> Double {
        // Approximation of CSS cubic-bezier(.2, .8, .2, 1).
        let clamped = min(1, max(0, progress))
        return 1 - pow(1 - clamped, 4)
    }

    private func setupAudioObservers() {
        // Only set up audio observers if microphone permission is already granted
        // This prevents triggering the permission dialog on app launch
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        // Observe AudioRecorder's audio level and frequency bands
        let audioRecorder = AudioRecorder.shared

        audioLevelCancellable = audioRecorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }

        frequencyBandsCancellable = audioRecorder.$frequencyBands
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bands in
                self?.frequencyBands = bands
            }
    }

    /// Call this after microphone permission is granted to set up audio observers
    func initializeAudioObservers() {
        guard audioLevelCancellable == nil else { return }
        setupAudioObservers()
    }

    private func createWindow() {
        DebugLog.info("Creating overlay window", context: "OverlayWindowManager")

        guard let screen = targetScreen() else {
            DebugLog.info("ERROR: Could not get target screen", context: "OverlayWindowManager")
            return
        }
        let screensSummary = NSScreen.screens.enumerated()
            .map { index, currentScreen in
                "[\(index)] \(describeScreen(currentScreen))"
            }
            .joined(separator: " | ")
        DebugLog.info("createWindow target=\(describeScreen(screen)) screens=\(screensSummary)", context: "OverlayWindowManager")

        let screenFrame = screen.visibleFrame
        // Use idle size for initial window creation
        let maxWidth = Constants.idleStateWidth + (Constants.idlePaddingNormal * 2)
        let windowWidth = maxWidth + Constants.windowSafetyPadding
        let windowHeight = Constants.idleStateHeight + Constants.idleHoverHitSlop + (Constants.verticalPaddingIdle * 2) + (Constants.edgeMargin * 2)

        // Calculate position based on selected position
        let (xPos, yPos) = calculatePosition(for: position, screenFrame: screenFrame, windowWidth: windowWidth, windowHeight: windowHeight)

        let windowFrame = NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight)

        // Create window using custom non-activating window class
        let window = NonActivatingWindow(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Keep overlay visible above normal windows.
        window.level = NSWindow.Level.screenSaver
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.hasShadow = false
        window.ignoresMouseEvents = false // Allow mouse events for hover and clicks
        window.acceptsMouseMovedEvents = true
        var collectionBehavior: NSWindow.CollectionBehavior = [
            NSWindow.CollectionBehavior.canJoinAllSpaces,
            NSWindow.CollectionBehavior.fullScreenAuxiliary,
            NSWindow.CollectionBehavior.ignoresCycle
        ]
        if #available(macOS 13.0, *) {
            // Required for overlay/panel windows that must follow other apps' fullscreen spaces.
            collectionBehavior.insert(.canJoinAllApplications)
        }
        window.collectionBehavior = collectionBehavior
        DebugLog.info(
            "Configured collectionBehavior raw=\(window.collectionBehavior.rawValue) canJoinAllApplications=\(window.collectionBehavior.contains(.canJoinAllApplications))",
            context: "OverlayWindowManager"
        )

        // Prevent clicking from activating the app or bringing other windows forward
        window.hidesOnDeactivate = false

        // Create SwiftUI view that observes this manager
        let contentView = RecordingOverlayView(manager: self)
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = window.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]

        window.contentView = hosting
        overlayWindow = window

        DebugLog.info("Created hosting view with manager observation", context: "OverlayWindowManager")
        DebugLog.info("Window created at position: (\(xPos), \(yPos)), level: \(window.level.rawValue)", context: "OverlayWindowManager")
        logWindowState("createWindow-after")
    }

    private func setupScreenChangeObserver() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLog.info("Screen configuration changed, repositioning overlay", context: "OverlayWindowManager")
            self?.logWindowState("observer-screen-before")
            self?.repositionWindow()
            self?.logWindowState("observer-screen-after")
        }
    }

    private func setupSpaceChangeObserver() {
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLog.info("Active space changed, repositioning overlay", context: "OverlayWindowManager")
            self?.logWindowState("observer-space-before")
            self?.repositionWindow()
            guard let self else { return }
            if case .hidden = self.overlayState { return }
            self.overlayWindow?.orderFrontRegardless()
            self.ensureWindowOnActiveSpace(reason: "observer-space")
            self.logWindowState("observer-space-after-orderFront")
        }
    }

    private func setupAppActivationObserver() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLog.info("Frontmost app changed, repositioning overlay", context: "OverlayWindowManager")
            self?.logWindowState("observer-activate-before")
            self?.repositionWindow()
            guard let self else { return }
            if case .hidden = self.overlayState { return }
            self.overlayWindow?.orderFrontRegardless()
            self.ensureWindowOnActiveSpace(reason: "observer-activate")
            self.logWindowState("observer-activate-after-orderFront")
        }
    }

    private func setupMouseHoverMonitor() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateHoverExpansionFromMouseLocation()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateHoverExpansionFromMouseLocation()
        }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateHoverExpansionFromMouseLocation()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTrackingTimer = timer
    }

    private func updateHoverExpansionFromMouseLocation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateHoverExpansionFromMouseLocation()
            }
            return
        }

        guard overlayState == .idle, let overlayWindow, overlayWindow.isVisible else {
            if case .recording = overlayState, isHoverExpanded, !showsRecordingControls {
                return
            }
            if isHoverExpanded {
                isHoverExpanded = false
            }
            return
        }

        let hoverFrame = idleInteractionFrame(for: overlayWindow).insetBy(dx: -Constants.hoverFrameInset, dy: -Constants.hoverFrameInset)
        let isMouseInside = hoverFrame.contains(NSEvent.mouseLocation)
        if suppressHoverExpansionUntilMouseExit {
            if isMouseInside {
                setHoverExpanded(false)
                return
            }
            suppressHoverExpansionUntilMouseExit = false
        }

        setHoverExpanded(isMouseInside)
    }

    private func idleInteractionFrame(for window: NSWindow) -> NSRect {
        guard isHoverExpanded else { return window.frame }

        let visibleWidth = Constants.activeStateWidth + (Constants.activePadding * 2)
        let visibleHeight = Constants.activeStateHeight + (Constants.verticalPaddingActive * 2) + (Constants.edgeMargin * 2)

        let x = window.frame.midX - (visibleWidth / 2)
        let y = position == .bottom ? window.frame.minY : window.frame.maxY - visibleHeight
        return NSRect(x: x, y: y, width: visibleWidth, height: visibleHeight)
    }

    private func screenForFrontmostApplication() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            DebugLog.info("screenForFrontmostApplication: no frontmost app", context: "OverlayWindowManager")
            return nil
        }

        let pid = app.processIdentifier
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            DebugLog.info("screenForFrontmostApplication: no window list", context: "OverlayWindowManager")
            return nil
        }

        for info in windowInfoList {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, ownerPID == pid else {
                continue
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0 else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let boundsRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  boundsRect.width > 80,
                  boundsRect.height > 80
            else {
                continue
            }

            let centerPoint = NSPoint(x: boundsRect.midX, y: boundsRect.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(centerPoint) }) {
                DebugLog.info(
                    "screenForFrontmostApplication selected pid=\(pid) app=\(app.localizedName ?? "unknown") bounds=\(Int(boundsRect.origin.x)),\(Int(boundsRect.origin.y)) \(Int(boundsRect.width))x\(Int(boundsRect.height)) screen=\(describeScreen(screen))",
                    context: "OverlayWindowManager"
                )
                return screen
            }
        }

        DebugLog.info("screenForFrontmostApplication: no matching screen for pid=\(pid) app=\(app.localizedName ?? "unknown")", context: "OverlayWindowManager")
        return nil
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let allScreens = NSScreen.screens.map { describeScreen($0) }.joined(separator: " | ")
        DebugLog.info("targetScreen mouse=\(Int(mouseLocation.x)),\(Int(mouseLocation.y)) screens=\(allScreens)", context: "OverlayWindowManager")

        if let frontmostScreen = screenForFrontmostApplication() {
            DebugLog.info("targetScreen selected frontmost-app screen: \(describeScreen(frontmostScreen))", context: "OverlayWindowManager")
            return frontmostScreen
        }

        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            DebugLog.info("targetScreen selected mouse screen: \(describeScreen(mouseScreen))", context: "OverlayWindowManager")
            return mouseScreen
        }
        let fallbackScreen = NSScreen.main ?? NSScreen.screens.first
        DebugLog.info("targetScreen fallback selected: \(describeScreen(fallbackScreen))", context: "OverlayWindowManager")
        return fallbackScreen
    }

    private func repositionWindow() {
        guard overlayWindow != nil else {
            DebugLog.info("Cannot reposition - window not available", context: "OverlayWindowManager")
            return
        }
        logWindowState("reposition-before")
        updateWindowSizeForState(overlayState, animated: false)
        ensureWindowOnActiveSpace(reason: "reposition")
        logWindowState("reposition-after")
    }

    private func ensureWindowOnActiveSpace(reason: String) {
        if case .hidden = overlayState { return }
        if let window = overlayWindow,
           !window.isOnActiveSpace,
           !window.occlusionState.contains(.visible)
        {
            DebugLog.warning(
                "ensureWindowOnActiveSpace[\(reason)]: window not on active space, recreating",
                context: "OverlayWindowManager"
            )

            let currentState = overlayState
            window.orderOut(nil)
            window.close()
            overlayWindow = nil

            createWindow()
            updateWindowSizeForState(currentState, animated: false)
            if case .hidden = currentState {
                overlayWindow?.orderOut(nil)
            } else {
                overlayWindow?.orderFrontRegardless()
            }
            logWindowState("ensureWindowOnActiveSpace-after-recreate")
        }
    }

    private func calculatePosition(for position: OverlayPosition, screenFrame: NSRect, windowWidth: CGFloat, windowHeight: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let padding: CGFloat = 0 // Distance from edge

        switch position {
        case .bottom:
            let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
            let y = screenFrame.origin.y + padding
            return (x, y)
        case .top:
            let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
            let y = screenFrame.origin.y + screenFrame.height - windowHeight - padding
            return (x, y)
        }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        hoverCollapseResizeWorkItem?.cancel()
        frameAnimationTimer?.invalidate()
        hoverTrackingTimer?.invalidate()
        overlayWindow?.close()
    }
}
