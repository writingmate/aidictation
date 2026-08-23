import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Monitors the Fn key state using NSEvent.flagsChanged
/// This works globally (even when app is in background)
class FnKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var eventTapHealthTimer: Timer?
    private var resolver = FnKeyGestureResolver()
    private var suppressUntil: Date?
    private(set) var consumePureFnEvents = false
    private var screenWakeObserver: NSObjectProtocol?
    private var systemWakeObserver: NSObjectProtocol?
    private var wakeRecoveryGeneration = 0
    private var wakeRecoveryWorkItem: DispatchWorkItem?
    private var lastTapCreationTime: Date?

    private enum Constants {
        static let suppressionDuration: TimeInterval = 0.5
        static let eventTapHealthInterval: TimeInterval = 5.0
        static let wakeRecoveryDelays: [TimeInterval] = [0.5, 1.5, 3.0, 5.0, 8.0]
        static let tapRecreationCooldown: TimeInterval = 2.0
    }

    var onFnPressed: (() -> Void)?
    var onFnReleased: (() -> Void)?

    /// Temporarily suppress Fn key detection (e.g., after simulated paste to avoid spurious events)
    func suppressTemporarily() {
        suppressUntil = Date().addingTimeInterval(Constants.suppressionDuration)
        DebugLog.info("Suppressing Fn detection for \(Constants.suppressionDuration)s", context: "FnKeyMonitor")
    }

    /// Start monitoring the Fn key state
    func startMonitoring(pollInterval _: TimeInterval = 0.016, consumePureFnEvents: Bool = false) {
        DebugLog.info("========================================", context: "FnKeyMonitor")
        DebugLog.info("STARTING Fn key monitoring", context: "FnKeyMonitor")
        DebugLog.info("Using NSEvent.flagsChanged monitoring", context: "FnKeyMonitor")
        DebugLog.info("========================================", context: "FnKeyMonitor")

        stopMonitoring() // Stop any existing monitors
        self.consumePureFnEvents = consumePureFnEvents

        if consumePureFnEvents {
            setupConsumingEventTap()
        } else {
            // Monitor global flags changed events. This is passive and cannot prevent
            // the system Fn/Globe action, so onboarding uses the event-tap mode instead.
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        }

        // Monitor local flags changed events
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let handled = self?.handleFlagsChanged(event) ?? false
            if handled, self?.consumePureFnEvents == true {
                return nil
            }
            return event
        }

        setupWakeObservers()
        startEventTapHealthTimer()
        DebugLog.info("Fn key monitors registered", context: "FnKeyMonitor")
    }

    private func setupWakeObservers() {
        removeWakeObservers()

        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleWakeRecovery(reason: "screens did wake")
        }

        systemWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleWakeRecovery(reason: "system did wake")
        }
    }

    private func removeWakeObservers() {
        if let observer = screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            screenWakeObserver = nil
        }
        if let observer = systemWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            systemWakeObserver = nil
        }
    }

    private func scheduleWakeRecovery(reason: String) {
        guard consumePureFnEvents else { return }

        wakeRecoveryGeneration += 1
        wakeRecoveryWorkItem?.cancel()
        DebugLog.info("Scheduling Fn event tap wake recovery: \(reason)", context: "FnKeyMonitor")

        runWakeRecoveryAttempt(reason: reason, generation: wakeRecoveryGeneration, attempt: 0)
    }

    private func runWakeRecoveryAttempt(reason: String, generation: Int, attempt: Int) {
        guard attempt < Constants.wakeRecoveryDelays.count else {
            DebugLog.info("Fn event tap wake recovery exhausted after \(attempt) attempts", context: "FnKeyMonitor")
            return
        }

        let delay = Constants.wakeRecoveryDelays[attempt]
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, generation == self.wakeRecoveryGeneration else { return }

            interruptGesture(reason: "wake recovery attempt \(attempt + 1)")
            forceRecreateTap(reason: "wake recovery (\(reason))")

            if self.eventTap != nil, let tap = self.eventTap, CGEvent.tapIsEnabled(tap: tap) {
                DebugLog.info("Fn event tap wake recovery succeeded on attempt \(attempt + 1)", context: "FnKeyMonitor")
            } else {
                DebugLog.info("Fn event tap wake recovery attempt \(attempt + 1) failed, scheduling retry", context: "FnKeyMonitor")
                self.runWakeRecoveryAttempt(reason: reason, generation: generation, attempt: attempt + 1)
            }
        }
        wakeRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Tears down and recreates the event tap from scratch. Used for wake recovery
    /// and when the tap appears non-functional despite being "enabled".
    private func forceRecreateTap(reason: String) {
        guard consumePureFnEvents else { return }

        if let cooldownStart = lastTapCreationTime,
           Date().timeIntervalSince(cooldownStart) < Constants.tapRecreationCooldown
        {
            DebugLog.info("Skipping tap recreation due to cooldown", context: "FnKeyMonitor")
            return
        }

        DebugLog.info("Force recreating Fn event tap: \(reason)", context: "FnKeyMonitor")

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                eventTapRunLoopSource = nil
            }
            eventTap = nil
        }

        setupConsumingEventTap()
    }

    /// Stop monitoring the Fn key
    func stopMonitoring() {
        DebugLog.info("Stopping Fn key monitoring", context: "FnKeyMonitor")

        stopEventTapHealthTimer()
        removeWakeObservers()
        wakeRecoveryWorkItem?.cancel()
        wakeRecoveryWorkItem = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                eventTapRunLoopSource = nil
            }
            eventTap = nil
        }

        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        interruptGesture(reason: "monitoring stopped")
        consumePureFnEvents = false
    }

    private func setupConsumingEventTap() {
        guard AXIsProcessTrusted() else {
            DebugLog.info("Skipping consuming Fn event tap because accessibility is not trusted", context: "FnKeyMonitor")
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let eventMask = 1 << CGEventType.flagsChanged.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.interruptGesture(reason: "tap disabled event \(type.rawValue)")
                    monitor.forceRecreateTap(reason: "callback disabled event \(type.rawValue)")
                    return Unmanaged.passUnretained(event)
                }

                guard type == .flagsChanged else {
                    return Unmanaged.passUnretained(event)
                }

                if let nsEvent = NSEvent(cgEvent: event), monitor.handleFlagsChanged(nsEvent), monitor.consumePureFnEvents {
                    return nil
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            DebugLog.info("Failed to create consuming Fn event tap", context: "FnKeyMonitor")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = eventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        lastTapCreationTime = Date()
        DebugLog.info("Consuming Fn event tap created and enabled", context: "FnKeyMonitor")
    }

    private func startEventTapHealthTimer() {
        stopEventTapHealthTimer()

        let timer = Timer(timeInterval: Constants.eventTapHealthInterval, repeats: true) { [weak self] _ in
            self?.validateEventTapHealth()
        }
        eventTapHealthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopEventTapHealthTimer() {
        eventTapHealthTimer?.invalidate()
        eventTapHealthTimer = nil
    }

    private func validateEventTapHealth() {
        guard consumePureFnEvents else { return }

        guard AXIsProcessTrusted() else {
            DebugLog.info("Fn event tap health check skipped because Accessibility permission is missing", context: "FnKeyMonitor")
            return
        }

        guard let tap = eventTap else {
            DebugLog.info("Fn event tap missing during health check; recreating", context: "FnKeyMonitor")
            forceRecreateTap(reason: "health check (nil tap)")
            return
        }

        if !CGEvent.tapIsEnabled(tap: tap) {
            forceRecreateTap(reason: "health check (tap disabled)")
        }
    }

    private func enableEventTap(reason: String) {
        guard let tap = eventTap else { return }

        interruptGesture(reason: reason)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.info("Re-enabled Fn event tap after \(reason)", context: "FnKeyMonitor")
    }

    /// Ends an in-flight gesture and tells the app about it. Without the callback a
    /// recording started by a press whose release we never saw would never stop.
    ///
    /// Only ever call this from an event-driven signal (the tap being disabled, or
    /// monitoring stopping). Never from a timer that samples `NSEvent.modifierFlags`:
    /// that snapshot does not reliably report `.function` while Fn/Globe is
    /// physically held, so polling it cuts off a recording mid-sentence.
    private func interruptGesture(reason: String) {
        guard resolver.interrupt() else { return }

        DebugLog.info("Releasing in-flight Fn gesture: \(reason)", context: "FnKeyMonitor")
        let callback = onFnReleased
        DispatchQueue.main.async { callback?() }
    }

    @discardableResult
    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasOtherModifiers = modifiers.contains(.command) || modifiers.contains(.option) ||
            modifiers.contains(.control) || modifiers.contains(.shift)
        let isSuppressed = suppressUntil.map { Date() < $0 } ?? false

        let outcome = resolver.resolve(
            FnKeyGestureResolver.Event(
                keyCode: event.keyCode,
                isFnFlagSet: modifiers.contains(.function),
                hasOtherModifiers: hasOtherModifiers,
                isSuppressed: isSuppressed
            )
        )

        if outcome.pressed {
            DebugLog.info("Fn key PRESSED", context: "FnKeyMonitor")
            onFnPressed?()
        } else if outcome.released {
            DebugLog.info("Fn key RELEASED", context: "FnKeyMonitor")
            onFnReleased?()
        }

        return outcome.handled
    }

    deinit {
        stopMonitoring()
        removeWakeObservers()
    }
}
