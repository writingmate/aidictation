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
    private var previousFnState = false
    private var suppressUntil: Date?
    private var consumePureFnEvents = false

    private enum Constants {
        static let suppressionDuration: TimeInterval = 0.5
        static let eventTapHealthInterval: TimeInterval = 5.0
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

        startEventTapHealthTimer()
        DebugLog.info("Fn key monitors registered", context: "FnKeyMonitor")
    }

    /// Stop monitoring the Fn key
    func stopMonitoring() {
        DebugLog.info("Stopping Fn key monitoring", context: "FnKeyMonitor")

        stopEventTapHealthTimer()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
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

        previousFnState = false
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
                    monitor.enableEventTap(reason: "callback disabled event \(type.rawValue)")
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
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
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
            DebugLog.error("Fn event tap health check: Accessibility permission is missing", context: "FnKeyMonitor")
            return
        }

        guard let tap = eventTap else {
            DebugLog.error("Fn event tap missing during health check; recreating", context: "FnKeyMonitor")
            setupConsumingEventTap()
            return
        }

        if !CGEvent.tapIsEnabled(tap: tap) {
            enableEventTap(reason: "health check")
        }
    }

    private func enableEventTap(reason: String) {
        guard let tap = eventTap else { return }

        previousFnState = false
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.error("Re-enabled Fn event tap after \(reason)", context: "FnKeyMonitor")
    }

    @discardableResult
    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        let isFnPressed = event.modifierFlags.contains(.function)
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Log all events for debugging
        DebugLog.info("handleFlagsChanged: keyCode=\(keyCode), isFnPressed=\(isFnPressed), modifiers=\(modifiers.rawValue)", context: "FnKeyMonitor")

        // Check if suppression is active (e.g., right after a paste operation)
        if let suppressUntil = suppressUntil, Date() < suppressUntil {
            DebugLog.info("Fn detection suppressed (until \(suppressUntil)), ignoring event", context: "FnKeyMonitor")
            return false
        }

        // Only respond to actual Fn key events (keyCode 63 or 179/globe key)
        // AND only if no other modifiers are pressed (to filter out synthetic events from paste)
        let isFnKeyCode = keyCode == 63 || keyCode == 179
        let hasOtherModifiers = modifiers.contains(.command) || modifiers.contains(.option) ||
            modifiers.contains(.control) || modifiers.contains(.shift)

        guard isFnKeyCode, !hasOtherModifiers else {
            // Not a pure Fn key event, ignore
            return false
        }

        DebugLog.info("Pure Fn key event detected, previousFnState=\(previousFnState)", context: "FnKeyMonitor")

        // Detect state transitions
        if isFnPressed, !previousFnState {
            // Fn key was just pressed
            DebugLog.info("⚡️ STATE CHANGE: Fn key PRESSED ⚡️", context: "FnKeyMonitor")
            DebugLog.info("Calling onFnPressed callback...", context: "FnKeyMonitor")
            previousFnState = true
            onFnPressed?()
            DebugLog.info("onFnPressed callback completed", context: "FnKeyMonitor")
            return true
        } else if !isFnPressed, previousFnState {
            // Fn key was just released
            DebugLog.info("⚡️ STATE CHANGE: Fn key RELEASED ⚡️", context: "FnKeyMonitor")
            DebugLog.info("Calling onFnReleased callback...", context: "FnKeyMonitor")
            previousFnState = false
            onFnReleased?()
            DebugLog.info("onFnReleased callback completed", context: "FnKeyMonitor")
            return true
        }

        return true
    }

    deinit {
        stopMonitoring()
    }
}
