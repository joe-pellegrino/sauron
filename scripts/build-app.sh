#!/usr/bin/env bash
#
# Build Sauron.app — wraps the SwiftPM executable into a signed, runnable
# macOS app bundle. Menu-bar-only (LSUIElement), unsandboxed (Accessibility
# needs to read other apps), ad-hoc signed for local use.
#
# Usage:
#   scripts/build-app.sh            # release build into ./dist/Sauron.app
#   scripts/build-app.sh --debug    # debug build
#   scripts/build-app.sh --install  # also copy into /Applications
#
set -euo pipefail

CONFIG="release"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --debug)   CONFIG="debug" ;;
        --install) INSTALL=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Sauron"
BUNDLE="dist/${APP_NAME}.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"

echo "▸ Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp "bundle/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Choose a signing identity. Accessibility (TCC) ties the grant to the app's
# code identity. An ad-hoc signature (-s -) has NO stable identity: every
# rebuild gets a fresh cdhash, so macOS treats each build as a new program and
# the Accessibility grant does not carry over — you'd have to re-grant every
# time, and the bare SPM binary (identifier "Sauron", no bundle) can't be
# matched at all. Signing with a real certificate (even a free "Apple
# Development" one) gives a stable designated requirement, so the grant sticks
# across rebuilds.
#
# Order of preference:
#   1. $SAURON_SIGN_IDENTITY if set (explicit override)
#   2. the first "Apple Development" identity in the keychain
#   3. ad-hoc as a last resort (grant won't persist across rebuilds)
if [[ -n "${SAURON_SIGN_IDENTITY:-}" ]]; then
    SIGN_ID="$SAURON_SIGN_IDENTITY"
else
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi

if [[ -n "$SIGN_ID" ]]; then
    echo "▸ Signing as: $SIGN_ID"
else
    echo "▸ Signing ad-hoc (no Developer identity found)."
    echo "  ⚠︎ Accessibility access will NOT persist across rebuilds with ad-hoc"
    echo "    signing. Re-grant after each build, or set SAURON_SIGN_IDENTITY."
    SIGN_ID="-"
fi

# No hardened runtime, no sandbox: a local-use agent that needs Accessibility
# access to other processes. The stable --identifier keeps the Accessibility
# grant and SMAppService registration consistent across rebuilds.
codesign --force --sign "$SIGN_ID" \
    --identifier "com.sauron.Sauron" \
    --timestamp=none \
    "$BUNDLE"

echo "▸ Verifying signature…"
codesign --verify --verbose "$BUNDLE"

if [[ "$INSTALL" == "1" ]]; then
    echo "▸ Installing to /Applications…"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$BUNDLE" "/Applications/${APP_NAME}.app"
    echo "  Installed: /Applications/${APP_NAME}.app"
fi

echo "✓ Built: $ROOT/$BUNDLE"
echo
echo "Run it with:"
echo "  open \"$ROOT/$BUNDLE\""
echo
echo "First launch will prompt for Accessibility access (System Settings ›"
echo "Privacy & Security › Accessibility). Grant it, and logging starts."
