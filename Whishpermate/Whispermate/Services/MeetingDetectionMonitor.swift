import AppKit
import ApplicationServices
import CoreAudio
internal import Combine
import WhisperMateShared

@MainActor
final class MeetingDetectionMonitor: ObservableObject {
    static let shared = MeetingDetectionMonitor()
    @Published var isEnabled: Bool { didSet { AppDefaults.shared.set(isEnabled, forKey: "detectMeetingCalls"); restart() } }
    @Published var autoStop: Bool { didSet { AppDefaults.shared.set(autoStop, forKey: "stopDetectedMeetingCalls") } }
    @Published private(set) var detectedCall: MeetingDetectionPolicy.Candidate?
    @Published private(set) var status = ""
    private var policy = MeetingDetectionPolicy()
    private var task: Task<Void, Never>?
    private var recordingCall: MeetingDetectionPolicy.Candidate?
    private var recordingNoteID: UUID?

    private init() {
        isEnabled = AppDefaults.shared.object(forKey: "detectMeetingCalls") as? Bool ?? true
        autoStop = AppDefaults.shared.object(forKey: "stopDetectedMeetingCalls") as? Bool ?? true
        restart()
    }

    func takeNotes(for call: MeetingDetectionPolicy.Candidate, includeMacAudio: Bool? = nil) {
        let coordinator = MeetingNotesCoordinator.shared
        guard detectedCall?.id == call.id, coordinator.activeNoteID == nil,
              AppState.shared.recordingState == .idle, !AppState.shared.isProcessing else { return }
        let meeting = MeetingCalendar.shared.meetings.first {
            abs($0.start.timeIntervalSinceNow) < 15 * 60 && $0.end > Date()
        }
        guard let id = coordinator.create(title: meeting?.title ?? call.title) else { return }
        recordingCall = call
        recordingNoteID = id
        if let includeMacAudio { coordinator.includeSystemAudio = includeMacAudio }
        MeetingCallPrompt.dismiss()
        MeetingNoteWindowController.open(id)
        coordinator.start(id)
    }

    private func restart() {
        task?.cancel()
        policy = MeetingDetectionPolicy()
        detectedCall = nil
        guard isEnabled else { status = "Call detection is off"; MeetingCallPrompt.dismiss(); return }
        guard #available(macOS 14.2, *) else { status = "Call detection requires macOS 14.2 or later"; return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let running = NSWorkspace.shared.runningApplications.compactMap { app -> MeetingAppSnapshot? in
                    guard let id = app.bundleIdentifier, MeetingCallScanner.supportedBundles.contains(id) else { return nil }
                    return .init(bundleID: id, name: app.localizedName ?? "Meeting", pid: app.processIdentifier)
                }
                let currentApp = self.policy.current?.appBundleID
                let observation = await Task.detached(priority: .utility) {
                    MeetingCallScanner.scan(running, currentApp: currentApp)
                }.value
                guard !Task.isCancelled else { return }
                self.status = AXIsProcessTrusted() ? "Looking for calls in Zoom, Teams, Slack, and browsers" : "Allow Accessibility access in Permissions to detect call windows"
                if let event = self.policy.observe(observation, now: Date()) {
                    switch event {
                    case .detected(let call):
                        self.detectedCall = call
                        if MeetingNotesCoordinator.shared.activeNoteID == nil { MeetingCallPrompt.show(call) }
                    case .ended(let call):
                        self.detectedCall = nil
                        MeetingCallPrompt.dismiss()
                        if self.autoStop, self.recordingCall?.id == call.id,
                           self.recordingNoteID == MeetingNotesCoordinator.shared.activeNoteID {
                            MeetingNotesCoordinator.shared.stop()
                        }
                        self.recordingCall = nil
                        self.recordingNoteID = nil
                    }
                }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }
}

private nonisolated struct MeetingAppSnapshot: Sendable {
    let bundleID: String
    let name: String
    let pid: pid_t
}

private nonisolated enum MeetingCallScanner {
    static let supportedBundles: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox"]

    @available(macOS 14.2, *)
    static func scan(_ apps: [MeetingAppSnapshot], currentApp: String?) -> MeetingDetectionPolicy.Observation {
        guard AXIsProcessTrusted(), let holders = microphoneHolders() else { return .unknown }
        let deadline = Date().addingTimeInterval(0.8)
        var inaccessible = false
        for app in apps {
            let hasMic = holders.contains { $0 == app.bundleID || $0.hasPrefix(app.bundleID + ".") }
            guard hasMic || currentApp == app.bundleID else { continue }
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { inaccessible = true; continue }
            for window in windows.prefix(4) {
                let title = string(window, kAXTitleAttribute)
                var budget = 250
                var controls: [String] = []
                collectControls(window, depth: 0, deadline: deadline, budget: &budget, controls: &controls)
                if MeetingDetectionPolicy.isCallWindow(appBundleID: app.bundleID, title: title, controls: controls) {
                    return .call(.init(appBundleID: app.bundleID, appName: app.name,
                                       title: title.isEmpty ? "Meeting in \(app.name)" : title))
                }
                if budget <= 0 { inaccessible = true }
            }
        }
        return inaccessible ? .unknown : .absent
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func collectControls(_ element: AXUIElement, depth: Int, deadline: Date, budget: inout Int, controls: inout [String]) {
        guard Date() < deadline else { budget = 0; return }
        guard depth < 12, budget > 0 else { return }
        budget -= 1
        if string(element, kAXRoleAttribute) == kAXButtonRole {
            controls.append(string(element, kAXTitleAttribute))
            controls.append(string(element, kAXDescriptionAttribute))
            controls.append(string(element, kAXHelpAttribute))
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
           let children = value as? [AXUIElement] {
            for child in children.prefix(60) { collectControls(child, depth: depth + 1, deadline: deadline, budget: &budget, controls: &controls) }
        }
    }

    @available(macOS 14.2, *)
    private static func microphoneHolders() -> [String]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
        return processes.compactMap { process in
            var running: UInt32 = 0
            var count = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &count, &running) == noErr, running != 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            count = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &count, &bundle) == noErr,
                  let bundle else { return nil }
            return bundle.takeRetainedValue() as String
        }
    }
}
