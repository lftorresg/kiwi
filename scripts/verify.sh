#!/bin/bash
# Verifies a built Kiwi.app against the security properties the project promises.
# Usage: scripts/verify.sh build/Kiwi.app
set -euo pipefail

APP="${1:?usage: verify.sh path/to/Kiwi.app}"
BIN="$APP/Contents/MacOS/Kiwi"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

echo "Verifying $APP"
[ -x "$BIN" ] || { echo "No executable at $BIN"; exit 1; }

# 1. Signature is intact and strict-valid.
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    pass "code signature is valid"
else
    fail "code signature is invalid"
fi

# 2. Hardened runtime is on.
signing_info="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
if [[ "$signing_info" =~ CodeDirectory[^[:cntrl:]]*runtime ]]; then
    pass "hardened runtime is enabled"
else
    fail "hardened runtime is not enabled"
fi

# 3. No entitlement that weakens the hardened runtime, and none at all beyond
#    the single one Kiwi declares: microphone input, for optional voice recording.
entitlements="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
weak=""
for key in get-task-allow disable-library-validation allow-dyld-environment-variables \
           allow-unsigned-executable-memory allow-jit disable-executable-page-protection \
           device.camera network.client network.server automation.apple-events; do
    if [[ "$entitlements" == *"$key"* ]]; then weak="$weak $key"; fi
done
allowed="com.apple.security.device.audio-input"
extra="$(printf '%s\n' "$entitlements" | grep -o -E 'com\.apple\.[A-Za-z0-9._-]+' | sort -u | grep -v -x -F "$allowed" | tr '\n' ' ' || true)"
if [ -z "$weak" ] && [ -z "$extra" ]; then
    pass "no runtime-weakening entitlements; at most microphone input"
else
    fail "unexpected entitlements:$weak $extra"
fi

# 4. Only system libraries are linked: nothing bundled, nothing third-party.
foreign="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/System/Library/|/usr/lib/)' || true)"
if [ -z "$foreign" ]; then
    pass "links only macOS system libraries"
else
    fail "links non-system libraries: $foreign"
fi
if [ -d "$APP/Contents/Frameworks" ] || [ -d "$APP/Contents/PlugIns" ]; then
    fail "bundle contains embedded frameworks or plug-ins"
else
    pass "no embedded frameworks or plug-ins"
fi

# 5. The executable references no networking API.
network="$(nm -u "$BIN" 2>/dev/null | grep -E 'NSURLSession|NSURLConnection|NSURLDownload|_nw_connection|_nw_listener|CFSocket|CFStreamCreatePairWithSocket|_getaddrinfo$|_socket$|_connect$|WKWebView' || true)"
if [ -z "$network" ]; then
    pass "no networking symbols referenced"
else
    fail "networking symbols referenced: $(printf '%s' "$network" | tr '\n' ' ')"
fi

# 6. Position independent (ASLR).
header="$(otool -hv "$BIN" 2>/dev/null || true)"
if [[ "$header" == *PIE* ]]; then
    pass "position-independent executable"
else
    fail "executable is not PIE"
fi

# 7. No package dependencies.
if grep -q '\.package(' "$ROOT/Package.swift"; then
    fail "Package.swift declares dependencies"
elif [ -f "$ROOT/Package.resolved" ] && grep -q '"identity"' "$ROOT/Package.resolved"; then
    fail "Package.resolved pins dependencies"
else
    pass "zero package dependencies"
fi

# 8. Optimised build keeps Swift's runtime safety checks.
if grep -R -q -- '-Ounchecked' "$ROOT/Package.swift" "$ROOT/Makefile"; then
    fail "build uses -Ounchecked"
else
    pass "bounds and overflow checks are kept"
fi

# 9. Info.plist is well formed and the bundle stays an agent with no URL schemes.
if plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    pass "Info.plist is well formed"
else
    fail "Info.plist is malformed"
fi
if grep -q -E 'CFBundleURLTypes|NSAppleEventsUsageDescription|NSAllowsArbitraryLoads' "$APP/Contents/Info.plist"; then
    fail "Info.plist declares URL schemes, Apple Events or ATS exceptions"
else
    pass "no URL schemes, Apple Events or ATS exceptions"
fi

# Informational: every place the source starts another process.
echo "  info  subprocess call sites:"
grep -R -n 'Process()' "$ROOT/Sources" | sed 's/^/          /' || echo "          none"

echo "  info  SHA-256 $(shasum -a 256 "$BIN" | awk '{print $1}')"

if [ "$failures" -gt 0 ]; then
    echo "Verification failed: $failures check(s)."
    exit 1
fi
echo "All checks passed."
