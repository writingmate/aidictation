import AppKit
import Foundation
import PermissionFlow

@available(macOS 13.0, *)
@MainActor
@objc(PermissionFlowRuntimeBridge)
public final class PermissionFlowRuntimeBridge: NSObject {
    private var controller: PermissionFlowController?

    @objc(openAccessibility)
    public func openAccessibility() {
        open(.accessibility)
    }

    @objc(openScreenRecording)
    public func openScreenRecording() {
        open(.screenRecording)
    }

    private func open(_ pane: PermissionFlowPane) {
        controller?.closePanel()
        controller = PermissionFlow.makeController(
            configuration: .init(
                requiredAppURLs: [Bundle.main.bundleURL],
                promptForAccessibilityTrust: false
            )
        )
        controller?.authorize(
            pane: pane,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: clickSourceFrameInScreen()
        )
    }

    private func clickSourceFrameInScreen() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
    }
}
