import Foundation
#if canImport(AppKit)
    import AppKit
    public typealias InstalledAppIcon = NSImage
#else
    public struct InstalledAppIcon: Hashable {
        public init() {}
    }
#endif

public struct InstalledApp: Identifiable, Hashable {
    public let id: String // bundle ID
    public let name: String
    public let bundleID: String
    public let icon: InstalledAppIcon?

    public init(name: String, bundleID: String, icon: InstalledAppIcon? = nil) {
        id = bundleID
        self.name = name
        self.bundleID = bundleID
        self.icon = icon
    }

    public static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.bundleID == rhs.bundleID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(bundleID)
    }
}

public class AppDiscoveryManager {
    public static let shared = AppDiscoveryManager()

    private var cachedApps: [InstalledApp]?

    public init() {}

    /// Get all installed applications from /Applications and /System/Applications
    public func getInstalledApps() -> [InstalledApp] {
        #if canImport(AppKit)
            if let cached = cachedApps {
                return cached
            }

            var apps: [InstalledApp] = []
            var seenBundleIDs = Set<String>()
            let fileManager = FileManager.default

            // Scan user, main, and system Applications directories
            let directories = [
                "/Applications",
                "/System/Applications",
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
            ]

            for directory in directories {
                let applicationsURL = URL(fileURLWithPath: directory)

                guard let contents = try? fileManager.contentsOfDirectory(
                    at: applicationsURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    DebugLog.info("Failed to read \(directory) directory", context: "AppDiscoveryManager")
                    continue
                }

                for appURL in contents where appURL.pathExtension == "app" {
                    if let app = extractAppInfo(from: appURL) {
                        // Only add if we haven't seen this bundle ID before (avoid duplicates)
                        if !seenBundleIDs.contains(app.bundleID) {
                            apps.append(app)
                            seenBundleIDs.insert(app.bundleID)
                        }
                    }
                }
            }

            // Sort by name
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            cachedApps = apps
            DebugLog.info("Discovered \(apps.count) installed applications", context: "AppDiscoveryManager")

            return apps
        #else
            return []
        #endif
    }

    /// Clear the cache to force re-scan on next call
    public func refreshCache() {
        cachedApps = nil
    }

    #if canImport(AppKit)
        private func extractAppInfo(from appURL: URL) -> InstalledApp? {
            // Read Info.plist
            let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")

            guard let plistData = try? Data(contentsOf: infoPlistURL),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: plistData,
                      options: [],
                      format: nil
                  ) as? [String: Any]
            else {
                return nil
            }

            // Get bundle ID
            guard let bundleID = plist["CFBundleIdentifier"] as? String else {
                return nil
            }

            // Get app name (prefer display name, fall back to bundle name)
            let name = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? appURL.deletingPathExtension().lastPathComponent

            // Try to get app icon
            var icon: NSImage?
            if let iconFileName = plist["CFBundleIconFile"] as? String {
                let iconURL = appURL.appendingPathComponent("Contents/Resources/\(iconFileName)")
                // Try with and without .icns extension
                if FileManager.default.fileExists(atPath: iconURL.path) {
                    icon = NSImage(contentsOf: iconURL)
                } else {
                    let iconWithExtURL = iconURL.appendingPathExtension("icns")
                    if FileManager.default.fileExists(atPath: iconWithExtURL.path) {
                        icon = NSImage(contentsOf: iconWithExtURL)
                    }
                }
            }

            // If no icon found via Info.plist, try using NSWorkspace
            if icon == nil {
                icon = NSWorkspace.shared.icon(forFile: appURL.path)
            }

            return InstalledApp(name: name, bundleID: bundleID, icon: icon)
        }
    #endif

    /// Get commonly used messaging/productivity apps bundle IDs for defaults
    public static let commonAppBundleIDs: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.apple.mail": "Mail",
        "com.discord.Discord": "Discord",
        "com.apple.iChat": "Messages",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Chrome",
        "com.microsoft.VSCode": "VS Code",
        "com.apple.Notes": "Notes",
        "com.notion.id": "Notion",
    ]
}
