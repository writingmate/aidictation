# Sources and claim ledger

All checks and captures were performed on 2026-08-02. Repository paths are relative to the project root unless stated otherwise.

## Live first-party sources

- Product website: <https://aidictation.com>
- Public repository: <https://github.com/writingmate/aidictation>
- Current README: <https://github.com/writingmate/aidictation/blob/main/README.md>
- MIT License: <https://github.com/writingmate/aidictation/blob/main/LICENSE>
- Third-party notices: <https://github.com/writingmate/aidictation/blob/main/THIRD_PARTY_NOTICES.md>
- Contribution guide: <https://github.com/writingmate/aidictation/blob/main/CONTRIBUTING.md>
- Security policy: <https://github.com/writingmate/aidictation/blob/main/SECURITY.md>

GitHub API verification on the capture date:

- Repository visibility: public
- Default branch: `main`
- Root license SPDX identifier: `MIT`
- Captured main commit: `9a3db1eaa2b1df84a0d02f3d5827a44bc6c06c3a`
- README blob: `5b7d65539b8ae67b90eb6af78362886ed469fbe2`
- LICENSE blob: `1bea9f7139506b40b25d6123b983e1b6ffe22a52`
- THIRD_PARTY_NOTICES blob: `6e70fc098d6881596a28c93c09aa199b43e4b1bf`

## Narration and on-screen claims

| Claim | Evidence | Constraint |
| --- | --- | --- |
| AI Dictation client code is public on GitHub | Live repository/API and `README.md` | Say “client code” or “repository code,” not that every hosted service is open source. |
| Apple, Windows, and Android projects are in one repository | Root folders `Whishpermate/`, `AIDictation.Windows/`, and `AIDictationAndroid/`; README repository layout | Do not imply feature parity across platforms. |
| The repository uses the MIT License | Root `LICENSE`; GitHub license API and license page | Third-party components are not automatically MIT licensed. |
| Bundled third-party components preserve their own licenses | `THIRD_PARTY_NOTICES.md` and referenced license files | Do not claim every dependency is covered by the root MIT License. |
| The clients can be inspected or built from source | Current README “Build from source” section | Local cloud mode may require configuration; do not claim every feature works without setup. |
| Offline recognition and cloud transcription are separate choices | Current README processing table and platform implementations | Offline availability varies by supported device and language. |
| Offline recognition is not necessarily a fully offline workflow | Current README offline/cloud and privacy sections | Enabled cloud cleanup can still send transcript text for processing. |
| Official downloads are linked at aidictation.com | Current website and README project links | No price, quota, or “free forever” claim appears in the video. |

## Visual provenance

All GitHub pages were captured signed out in Google Chrome 150 at 1920×1080. The repository and file pages contain no customer data, credentials, private notifications, or account identifiers.

| File | Source | SHA-256 |
| --- | --- | --- |
| `shot-repo-home.png` | Live repository root showing Public, platform folders, and MIT license | `f8d952e424b7fb0b2da9e376b054112865331b3be317e64e9ec427e987e45b82` |
| `shot-license.png` | Live GitHub MIT License page | `efeac259fd67034749554a5dc3a9fe2c4b1e084cdce4af0f7664e299e338791b` |
| `shot-third-party.png` | Live GitHub rendered third-party notices | `d96a07cd2999dcb565c1f32a8e792e8925fa9f259d8d75fb90f836b0ef7c661e` |
| `shot-offline-cloud.png` | Current rendered README processing table, cropped from a full-height browser capture | `cca66550acc6c328d1cdd2e60a63c944c6619f2e35fa8e75cda2314c6065f24a` |
| `shot-build.png` | Current rendered README build instructions, cropped from the same live capture | `a90ad7a08228416053802988e277a22f2202d19addd9228d925f4f523b4d610a` |
| `shot-privacy.png` | Current rendered README privacy and open-source FAQ, cropped from the same live capture | `0248472dc203d27a24d3524106f0323501a81057779cd7ab14fcb37214714cc3` |
| `shot-layout.png` | Current rendered README repository layout and project links, cropped from the same live capture | `7a49a77e53de4156d936fc26dc37ab6fc87e3600955ef5d23eca03a5ddf1cce8` |
| `aidictation-icon.png` | First-party Android/Play product icon in the repository | `c24d70964c9761911aeae53d30fe8abb7bad73218afe1525dabac5ab888b233b` |

Cropping only removes browser whitespace and enlarges the unchanged live README content. No repository text, UI label, or product behavior was reconstructed.

## Explicit exclusions

- Do not say the hosted cloud service, every model, or every dependency is MIT licensed or self-hostable.
- Do not imply equal features or release versions on Apple, Windows, and Android.
- Do not show environment, configuration, token, or credential files.
- Do not use the website homepage hero, testimonials, pricing, customer photos, or marketing composites; they contain claims outside this video’s dated evidence.
- Do not claim “works everywhere,” “fully offline,” “best,” “perfect,” a language count, a speed multiple, security certification, or current pricing.
- Do not use third-party product logos, stock media, music, or customer content.
