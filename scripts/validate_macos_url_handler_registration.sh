#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDLER_VERIFIER="$SCRIPT_DIR/verify_macos_url_handler.swift"
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
USER_APPLICATIONS_DIR="${HOME}/Applications"
WORK_PREFIX="${TMPDIR:-/tmp}/aidictation-url-handler-contract."
INSTALL_PREFIX="$USER_APPLICATIONS_DIR/AIDictationURLHandlerContract."
WORK_DIR=""
INSTALL_ROOT=""
INSTALLED_APP=""

cleanup() {
  if [[ -n "$INSTALL_ROOT" \
      && "$INSTALL_ROOT" == "$INSTALL_PREFIX"* \
      && "$(dirname "$INSTALL_ROOT")" == "$USER_APPLICATIONS_DIR" \
      && "$INSTALLED_APP" == "$INSTALL_ROOT/CallbackProbe.app" ]]; then
    "$LSREGISTER_PATH" -u "$INSTALLED_APP" >/dev/null 2>&1 || true
    if [[ -d "$INSTALL_ROOT" ]]; then
      rm -rf -- "$INSTALL_ROOT"
    fi
  fi
  if [[ -n "$WORK_DIR" && "$WORK_DIR" == "$WORK_PREFIX"* && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

test -x "$LSREGISTER_PATH"
test -f "$HANDLER_VERIFIER"
mkdir -p "$USER_APPLICATIONS_DIR"

WORK_DIR="$(mktemp -d "${WORK_PREFIX}XXXXXX")"
INSTALL_ROOT="$(mktemp -d "${INSTALL_PREFIX}XXXXXX")"
SOURCE_APP="$WORK_DIR/CallbackProbe.app"
INSTALLED_APP="$INSTALL_ROOT/CallbackProbe.app"
SCHEME="aidictationhandlercontract${RANDOM}${RANDOM}"

mkdir -p "$SOURCE_APP/Contents/MacOS"
cat > "$WORK_DIR/CallbackProbe.swift" <<'SWIFT'
import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
            as? [[String: Any]]
        let expectedScheme = (urlTypes?.first?["CFBundleURLSchemes"] as? [String])?.first
        guard urls.contains(where: { url in
            guard let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
                components.scheme == expectedScheme,
                components.host == "auth-callback",
                components.user == nil,
                components.password == nil,
                components.port == nil,
                components.path.isEmpty,
                components.query == nil,
                let fragment = components.fragment,
                let items = URLComponents(string: "?\(fragment)")?.queryItems
            else {
                return false
            }
            var params: [String: String] = [:]
            for item in items {
                params[item.name] = item.value ?? ""
            }
            return params == [
                "access_token": "synthetic-access",
                "refresh_token": "synthetic-refresh",
                "token_type": "bearer",
                "expires_in": "3600",
            ]
        }) else {
            return
        }

        let sentinel = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("callback-received")
        try? Data("received\n".utf8).write(to: sentinel, options: .atomic)
        application.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NSApplication.shared.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
SWIFT

cat > "$SOURCE_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CallbackProbe</string>
  <key>CFBundleIdentifier</key>
  <string>com.writingmate.aidictation.release-handler-contract</string>
  <key>CFBundleName</key>
  <string>CallbackProbe</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>$SCHEME</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

swiftc "$WORK_DIR/CallbackProbe.swift" -o "$SOURCE_APP/Contents/MacOS/CallbackProbe"
codesign --force --deep --sign - "$SOURCE_APP" >/dev/null

if swift "$HANDLER_VERIFIER" "$SOURCE_APP" "$SCHEME" 0.25 >/dev/null 2>&1; then
  echo "Synthetic callback unexpectedly resolved to the uninstalled source app." >&2
  exit 1
fi

ditto "$SOURCE_APP" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
"$LSREGISTER_PATH" -f "$INSTALLED_APP"
swift "$HANDLER_VERIFIER" "$INSTALLED_APP" "$SCHEME"
if ! open "$SCHEME://auth-callback#access_token=synthetic-access&refresh_token=synthetic-refresh&token_type=bearer&expires_in=3600" >/dev/null 2>&1; then
  echo "macOS could not deliver the synthetic callback to the registered app." >&2
  exit 1
fi
for attempt in {1..20}; do
  if [[ -s "$INSTALL_ROOT/callback-received" ]]; then
    break
  fi
  if [[ "$attempt" -eq 20 ]]; then
    echo "The registered synthetic app did not receive the callback." >&2
    exit 1
  fi
  sleep 0.25
done

cleanup
trap - EXIT
if [[ -e "$INSTALL_ROOT" || -e "$WORK_DIR" ]]; then
  echo "Synthetic callback verification did not clean up its temporary apps." >&2
  exit 1
fi

echo "Verified exact LaunchServices registration, callback fragment receipt, and cleanup."
