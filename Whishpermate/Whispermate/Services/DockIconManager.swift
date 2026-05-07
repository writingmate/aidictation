import AppKit
internal import Combine
import Foundation
import WhisperMateShared

extension NSNotification.Name {
    static let dockIconVisibilityChanged = NSNotification.Name("DockIconVisibilityChanged")
}

final class DockIconManager: ObservableObject {
    static let shared = DockIconManager()

    private struct VisibleWindowSnapshot {
        let windows: [NSWindow]
        let keyWindow: NSWindow?
    }

    private enum Keys {
        static let showDockIcon = "showDockIcon"
    }

    @Published private(set) var isDockIconVisible: Bool

    static var isDockIconVisible: Bool {
        shared.isDockIconVisible
    }

    private static var savedDockIconVisibility: Bool {
        AppDefaults.shared.object(forKey: Keys.showDockIcon) as? Bool ?? true
    }

    private init() {
        isDockIconVisible = Self.savedDockIconVisibility
    }

    static func requestDockIconVisibility(_ visible: Bool) {
        shared.setDockIconVisible(visible, persist: true, restoreVisibleWindows: true)
    }

    func applySavedPreference() {
        setDockIconVisible(Self.savedDockIconVisibility, persist: false, restoreVisibleWindows: false)
    }

    private func setDockIconVisible(_ visible: Bool, persist: Bool, restoreVisibleWindows: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setDockIconVisible(visible, persist: persist, restoreVisibleWindows: restoreVisibleWindows)
            }
            return
        }

        let windowSnapshot = restoreVisibleWindows ? currentVisibleWindowSnapshot() : nil

        if persist {
            AppDefaults.shared.set(visible, forKey: Keys.showDockIcon)
        }

        if !visible, !StatusBarManager.isMenuBarIconVisible {
            StatusBarManager.requestMenuBarIconVisibility(true)
        }

        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        let applied = NSApp.setActivationPolicy(policy)
        let actualVisibility = applied ? visible : (NSApp.activationPolicy() == .regular)

        isDockIconVisible = actualVisibility
        NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: actualVisibility)

        if applied {
            DebugLog.info("Dock icon visibility set to \(actualVisibility)", context: "DockIconManager")
        } else {
            DebugLog.error("Failed to set Dock icon visibility to \(visible)", context: "DockIconManager")
        }

        if restoreVisibleWindows, let windowSnapshot {
            restore(windowSnapshot)
            DispatchQueue.main.async { [weak self] in
                self?.restore(windowSnapshot)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.restore(windowSnapshot)
            }
        }
    }

    private func currentVisibleWindowSnapshot() -> VisibleWindowSnapshot {
        let windows = NSApp.windows.filter { window in
            window.isVisible
                && !window.isMiniaturized
                && window.level == .normal
                && window.canBecomeKey
        }
        return VisibleWindowSnapshot(windows: windows, keyWindow: NSApp.keyWindow)
    }

    private func restore(_ snapshot: VisibleWindowSnapshot) {
        guard !snapshot.windows.isEmpty else { return }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        for window in snapshot.windows {
            window.setIsVisible(true)
            window.orderFrontRegardless()
        }

        let keyWindow = snapshot.keyWindow.flatMap { snapshot.windows.contains($0) ? $0 : nil }
        (keyWindow ?? snapshot.windows.first)?.makeKeyAndOrderFront(nil)
    }
}
