import AppKit
import Foundation
import ScreenCaptureKit
import Vision
import WhisperMateShared
internal import Combine

/// Manages screen capture and OCR text extraction for providing visual context to LLM
@MainActor
class ScreenCaptureManager: ObservableObject {
    static let shared = ScreenCaptureManager()

    // MARK: - Published Properties

    @Published var isCapturing = false
    @Published var lastCapturedText: String?

    /// Whether to include screen context in LLM prompts
    /// This is now tied directly to screen recording permission
    nonisolated var includeScreenContext: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Check if screen recording permission is granted
    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission - opens System Settings
    func requestScreenRecordingPermission() {
        // CGRequestScreenCaptureAccess() only works once per app install
        // After that, we need to direct users to System Settings
        if !CGPreflightScreenCaptureAccess() {
            // First attempt - try the API
            let _ = CGRequestScreenCaptureAccess()

            // Also open System Settings since the API prompt may not show
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Capture the active window and extract text via OCR
    func captureAndExtractText() async -> String? {
        guard !isCapturing else {
            DebugLog.warning("Already capturing", context: "ScreenCaptureManager")
            return nil
        }

        isCapturing = true
        defer { isCapturing = false }

        guard let windowInfo = getActiveWindowInfo() else {
            DebugLog.warning("No active window found", context: "ScreenCaptureManager")
            return nil
        }

        DebugLog.info("Capturing: \(windowInfo.title) (\(windowInfo.ownerName))", context: "ScreenCaptureManager")

        var contextText = """
        Active Window: \(windowInfo.title)
        Application: \(windowInfo.ownerName)

        """

        if let capturedImage = await captureActiveWindow(windowInfo: windowInfo) {
            let extractedText = await extractText(from: capturedImage)

            if let extractedText = extractedText, !extractedText.isEmpty {
                contextText += "Window Content:\n\(extractedText)"
                let preview = String(extractedText.prefix(100))
                DebugLog.info("Text extracted: \(preview)\(extractedText.count > 100 ? "..." : "")", context: "ScreenCaptureManager")
            } else {
                contextText += "Window Content:\nNo text detected via OCR"
                DebugLog.info("No text extracted from window", context: "ScreenCaptureManager")
            }

            lastCapturedText = contextText
            return contextText
        }

        DebugLog.warning("Window capture failed", context: "ScreenCaptureManager")
        return nil
    }

    // MARK: - Private Methods

    private func getActiveWindowInfo() -> (title: String, ownerName: String, windowID: CGWindowID)? {
        let windowListInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

        guard let frontWindow = windowListInfo.first(where: { info in
            let layer = info[kCGWindowLayer as String] as? Int32 ?? 0
            return layer == 0
        }) else {
            return nil
        }

        guard let windowID = frontWindow[kCGWindowNumber as String] as? CGWindowID,
              let ownerName = frontWindow[kCGWindowOwnerName as String] as? String,
              let title = frontWindow[kCGWindowName as String] as? String
        else {
            return nil
        }

        return (title: title, ownerName: ownerName, windowID: windowID)
    }

    private func captureActiveWindow(windowInfo: (title: String, ownerName: String, windowID: CGWindowID)) async -> NSImage? {
        guard #available(macOS 14.0, *) else {
            DebugLog.warning("Screen capture requires macOS 14.0+", context: "ScreenCaptureManager")
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let targetWindow = content.windows.first(where: { $0.windowID == windowInfo.windowID }) else {
                DebugLog.warning("Target window not found in shareable content", context: "ScreenCaptureManager")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: targetWindow)

            let configuration = SCStreamConfiguration()
            configuration.width = Int(targetWindow.frame.width) * 2
            configuration.height = Int(targetWindow.frame.height) * 2

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        } catch {
            DebugLog.error("Screen capture failed: \(error.localizedDescription)", context: "ScreenCaptureManager")
            return nil
        }
    }

    private func extractText(from image: NSImage) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            DebugLog.warning("Failed to get CGImage from NSImage", context: "ScreenCaptureManager")
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }

            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try requestHandler.perform([request])
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    return nil
                }

                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                return text.isEmpty ? nil : text
            } catch {
                Task { @MainActor in
                    DebugLog.error("Text recognition failed: \(error.localizedDescription)", context: "ScreenCaptureManager")
                }
                return nil
            }
        }.value
    }
}
