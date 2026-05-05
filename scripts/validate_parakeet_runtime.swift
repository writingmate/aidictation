import Foundation

func fail(_ message: String) -> Never {
    fputs("offline validation failed: \(message)\n", stderr)
    exit(1)
}

func run(_ executable: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail("could not run \(executable): \(error.localizedDescription)")
    }

    guard process.terminationStatus == 0 else {
        fail("\(executable) exited with status \(process.terminationStatus)")
    }
}

func generateAudio(at url: URL) {
    let tmpAiff = url.deletingPathExtension().appendingPathExtension("aiff")
    run("/usr/bin/say", [
        "-v",
        "Samantha",
        "-o",
        tmpAiff.path,
        "AIDictation release smoke test.",
    ])
    run("/usr/bin/afconvert", [
        "-f",
        "m4af",
        "-d",
        "aac",
        tmpAiff.path,
        url.path,
    ])

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size > 1_000 else {
        fail("generated audio is empty")
    }
}

func loadBridge(from appURL: URL) -> NSObject {
    let frameworkURL = appURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Frameworks", isDirectory: true)
        .appendingPathComponent("ParakeetRuntime.framework", isDirectory: true)

    guard FileManager.default.fileExists(atPath: frameworkURL.path) else {
        fail("ParakeetRuntime.framework is missing from \(appURL.path)")
    }

    guard let bundle = Bundle(url: frameworkURL) else {
        fail("could not create bundle for \(frameworkURL.path)")
    }

    if !bundle.isLoaded {
        do {
            try bundle.loadAndReturnError()
        } catch {
            fail("could not load ParakeetRuntime.framework: \(error.localizedDescription)")
        }
    }

    let runtimeClass: AnyClass? = NSClassFromString("ParakeetRuntime.ParakeetRuntimeBridge")
        ?? NSClassFromString("ParakeetRuntimeBridge")
    guard let bridgeClass = runtimeClass as? NSObject.Type else {
        fail("could not find ParakeetRuntimeBridge class")
    }

    return bridgeClass.init()
}

func initialize(_ bridge: NSObject) {
    let selector = NSSelectorFromString("initializeWithCompletion:")
    guard bridge.responds(to: selector),
          let method = bridge.method(for: selector)
    else {
        fail("Parakeet runtime does not expose initializeWithCompletion:")
    }

    let semaphore = DispatchSemaphore(value: 0)
    var failure: String?

    let completion: @convention(block) (Bool, NSString?) -> Void = { success, message in
        if !success {
            failure = (message as String?) ?? "initialization failed"
        }
        semaphore.signal()
    }

    typealias Function = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool, NSString?) -> Void) -> Void
    unsafeBitCast(method, to: Function.self)(bridge, selector, completion)

    if semaphore.wait(timeout: .now() + 360) == .timedOut {
        fail("timed out initializing Parakeet runtime")
    }

    if let failure {
        fail(failure)
    }
}

func transcribe(_ bridge: NSObject, audioURL: URL) -> String {
    let selector = NSSelectorFromString("transcribeAudioAtPath:completion:")
    guard bridge.responds(to: selector),
          let method = bridge.method(for: selector)
    else {
        fail("Parakeet runtime does not expose transcribeAudioAtPath:completion:")
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: String?
    var failure: String?

    let completion: @convention(block) (NSString?, NSString?) -> Void = { text, message in
        if let text {
            result = text as String
        } else {
            failure = (message as String?) ?? "transcription failed"
        }
        semaphore.signal()
    }

    typealias Function = @convention(c) (AnyObject, Selector, NSString, @escaping @convention(block) (NSString?, NSString?) -> Void) -> Void
    unsafeBitCast(method, to: Function.self)(bridge, selector, audioURL.path as NSString, completion)

    if semaphore.wait(timeout: .now() + 120) == .timedOut {
        fail("timed out transcribing with Parakeet runtime")
    }

    if let failure {
        fail(failure)
    }

    guard let text = result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        fail("Parakeet runtime returned empty transcription")
    }

    return text
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: validate_parakeet_runtime.swift /path/to/AIDictation.app")
}

if #available(macOS 14.0, *) {
    let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("aidictation-offline-smoke-\(UUID().uuidString).m4a")

    generateAudio(at: audioURL)
    let bridge = loadBridge(from: appURL)
    initialize(bridge)
    let text = transcribe(bridge, audioURL: audioURL)
    let lowered = text.lowercased()

    guard lowered.contains("aidictation") || lowered.contains("release") || lowered.contains("smoke") || lowered.contains("test") else {
        fail("unexpected Parakeet text: \(text)")
    }

    print("offline Parakeet transcription ok: \(text)")
} else {
    fail("macOS 14 or later is required for offline transcription validation")
}
