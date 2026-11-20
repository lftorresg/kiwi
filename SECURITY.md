# Security

Kiwi can see your screen, so it is built to hold as little power as possible and to make that easy to check.

## What Kiwi can do

| Capability | Status | Why |
| --- | --- | --- |
| Screen Recording | Required | Screenshots, scrolling capture, recording |
| Network access | Never used | No update checks, telemetry, uploads or web views. `make verify` fails if the binary references a networking API |
| Accessibility | Not requested | Hotkeys use Carbon; drag detection reads only the drag pasteboard's change count and types |
| Input Monitoring | Not requested | Same as above |
| Microphone | Optional, off by default | Used only when you turn on *Record microphone*, and only while a recording runs. macOS asks for permission first and shows its indicator. The audio goes straight from ScreenCaptureKit to the file; Kiwi never handles it |
| Camera | Not requested | |
| Apple Events / automation | Not requested | |
| Files | Only what you hand it | Dropped files, the save folder you choose, and its own cache |

## How it is built

- **Hardened runtime, one entitlement.** The app is signed with `--options runtime` and an entitlements file that grants a single thing: microphone input, for the optional voice track in recordings. `make verify` fails if any other entitlement appears. The hardened runtime blocks code injection through `DYLD_INSERT_LIBRARIES`, loading of libraries that Apple did not sign, JIT and writable-executable memory, and debugger attachment. This matters because any code running inside Kiwi would inherit its Screen Recording permission.
- **No dependencies.** `Package.swift` declares none. Everything linked ships with macOS. There is no bundled framework, plug-in, helper, or auto-updater.
- **Memory safety.** Swift with bounds and overflow checks on in release builds (`-Ounchecked` is never used). Strict memory safety checking (SE-0458) is enabled, so every unsafe construct is reported at build time. The few that remain are confined to `App/HotKey.swift` (the Carbon hotkey bridge) and `App/Bridging.swift`, each marked `unsafe` with the reason it is safe as used.
- **Verified builds.** `make verify` checks the signature, hardened runtime, entitlements, linked libraries, networking symbols, PIE, dependencies and Info.plist, and prints the binary's SHA-256. CI runs the same script on every push, with a read-only token and actions pinned to commit hashes.
- **One subprocess.** The only process Kiwi starts is `/usr/bin/open`, by absolute path, to relaunch itself after you grant Screen Recording.

## How it handles your data

- Captures live in memory and in `~/Library/Caches/Kiwi/Captures`, a directory only your account can read (mode 700, files 600). The cache is wiped when Kiwi quits, and anything older than a day is pruned at launch.
- Saved screenshots are written with mode 600. Nothing is saved outside the folder you choose.
- Delete removes the working copy, moves any saved copy to the Trash, and clears the clipboard if it still holds that capture.
- Exported PNGs carry pixel data and DPI only. *Strip info* on the wheel removes location, camera and software metadata from existing images.
- Kiwi logs errors, never screen content or recognised text.
- Image inputs are size-checked before decoding (150 megapixel limit) to stop decompression bombs.

## Redaction

- Auto-redact reads text on-device with Apple's Vision framework and matches it against patterns for emails, phone numbers, payment cards (Luhn-checked), CPF and SSN, credentials and tokens, and IP/MAC addresses. Faces are optional.
- Redactions are **solid fills** burned into the exported pixels. Blur and pixelation can be partially reversed; solid fills cannot.
- With *Redact every capture* on, the scan runs before the image reaches the clipboard or disk. If the scan fails, Kiwi fails closed: nothing is copied or saved automatically.
- Closing the editor applies your edits to the clipboard copy, so the unredacted original is not left behind there.
- Detection is best effort. Text recognition can misread characters, and a secret in an unusual format will not match a pattern. Always look at the result before sharing.
- The Pixelate tool is cosmetic. Use Redact for anything sensitive.

## Known limits

- **No App Sandbox.** The wheel writes results next to the files you drop, which the sandbox does not allow without a folder prompt per location. The hardened runtime and the absence of network code are the compensating controls.
- **Not notarized.** Local builds are ad hoc signed, or signed with your own local certificate. Gatekeeper treats them as software you built yourself.
- **Clipboard history tools** keep whatever was copied. If you use one, turn on *Redact every capture* so the unredacted image never reaches the clipboard.
- **Ad hoc signatures change on every build**, so macOS asks for Screen Recording again after a rebuild. `scripts/setup-signing.sh` creates a stable local identity instead: a self-signed certificate trusted for code signing only, for your user only, whose private key stays in your login keychain. The trade-off: whatever can sign with that key can produce an app macOS treats as Kiwi, grant included, so the key is imported without pre-authorising any app and macOS asks before each use unless you choose Always Allow.

## Reporting a problem

Open a private security advisory on the repository, or contact the maintainer directly. Please do not include real secrets or personal data in reports.
