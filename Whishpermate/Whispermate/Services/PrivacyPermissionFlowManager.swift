import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class PrivacyPermissionFlowManager {
    static let shared = PrivacyPermissionFlowManager()

    enum Pane {
        case accessibility
        case microphone
        case screenRecording

        var settingsURL: URL? {
            let urlString: String
            switch self {
            case .accessibility:
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .microphone:
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .screenRecording:
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            }
            return URL(string: urlString)
        }

        var supportsPermissionFlow: Bool {
            switch self {
            case .accessibility, .screenRecording: return true
            case .microphone: return false
            }
        }
    }

    private var runtimeBridge: NSObject?

    private init() {}

    func open(
        _ pane: Pane,
        promptForAccessibilityTrust: Bool = false,
        showDragHelper: Bool = true,
        permissionGranted _: (() -> Bool)? = nil
    ) {
        if promptForAccessibilityTrust {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options)
        }

        if #available(macOS 13.0, *),
           showDragHelper,
           pane.supportsPermissionFlow,
           openWithPermissionFlowRuntime(pane)
        {
            return
        }

        if let url = pane.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    func closeDragHelper() {
        guard #available(macOS 13.0, *), let bridge = loadRuntimeBridge() else {
            return
        }

        let selector = NSSelectorFromString("closePermissionFlow")
        guard bridge.responds(to: selector), let method = bridge.method(for: selector) else {
            return
        }

        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method, to: Function.self)(bridge, selector)
    }

    @available(macOS 13.0, *)
    private func openWithPermissionFlowRuntime(_ pane: Pane) -> Bool {
        guard let bridge = loadRuntimeBridge() else { return false }

        let selectorName: String
        switch pane {
        case .accessibility:
            selectorName = "openAccessibility"
        case .screenRecording:
            selectorName = "openScreenRecording"
        case .microphone:
            return false
        }

        let selector = NSSelectorFromString(selectorName)
        guard bridge.responds(to: selector), let method = bridge.method(for: selector) else {
            return false
        }

        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method, to: Function.self)(bridge, selector)
        return true
    }

    @available(macOS 13.0, *)
    private func loadRuntimeBridge() -> NSObject? {
        if let runtimeBridge {
            return runtimeBridge
        }

        guard let frameworkURL = Bundle.main.privateFrameworksURL?.appendingPathComponent("PermissionFlowRuntime.framework"),
              let bundle = Bundle(url: frameworkURL)
        else {
            return nil
        }

        if !bundle.isLoaded {
            do {
                try bundle.loadAndReturnError()
            } catch {
                DebugLog.warning("Failed to load PermissionFlow runtime: \(error.localizedDescription)", context: "PrivacyPermissionFlowManager")
                return nil
            }
        }

        let runtimeClass: AnyClass? = NSClassFromString("PermissionFlowRuntime.PermissionFlowRuntimeBridge")
            ?? NSClassFromString("PermissionFlowRuntimeBridge")
        guard let bridgeClass = runtimeClass as? NSObject.Type else {
            DebugLog.warning("Could not find PermissionFlow runtime bridge", context: "PrivacyPermissionFlowManager")
            return nil
        }

        let bridge = bridgeClass.init()
        runtimeBridge = bridge
        return bridge
    }
}
