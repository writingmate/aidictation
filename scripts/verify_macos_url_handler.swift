import CoreServices
import Foundation

guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
    fputs("Usage: verify_macos_url_handler.swift <app-path> <scheme> [timeout-seconds]\n", stderr)
    exit(2)
}

let expectedApp = URL(fileURLWithPath: CommandLine.arguments[1])
    .resolvingSymlinksInPath()
    .standardizedFileURL
let scheme = CommandLine.arguments[2]
let timeout = CommandLine.arguments.count == 4
    ? (Double(CommandLine.arguments[3]) ?? 10)
    : 10

guard let callbackURL = URL(string: "\(scheme)://auth-callback") else {
    fputs("The release callback scheme is invalid.\n", stderr)
    exit(2)
}

let deadline = Date().addingTimeInterval(max(timeout, 0))
repeat {
    var lookupError: Unmanaged<CFError>?
    if let unmanagedHandler = LSCopyDefaultApplicationURLForURL(
        callbackURL as CFURL,
        .all,
        &lookupError
    ) {
        let actualApp = (unmanagedHandler.takeRetainedValue() as URL)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        if actualApp == expectedApp {
            print("LaunchServices resolves the callback to the exact release app.")
            exit(0)
        }
    }

    if Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
    }
} while Date() < deadline

fputs("LaunchServices does not resolve the callback to the exact release app.\n", stderr)
exit(1)
