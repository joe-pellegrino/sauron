#!/usr/bin/env bash
#
# Build Sauron.app WITHOUT Xcode or SwiftPM — compiles the sources directly with
# `swiftc` and assembles the bundle by hand. Use this when you only have the
# Command Line Tools (no Xcode.app), or when `swift build` is broken (e.g. the
# CLT shipped SwiftPM's frameworks in the wrong path). Only `swiftc` + `codesign`
# are required, both of which the Command Line Tools provide.
#
# Output: ./dist/Sauron.app (ad-hoc signed). Then: open ./dist/Sauron.app
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Sauron"
BUNDLE="dist/${APP_NAME}.app"
TARGET="arm64-apple-macos26.0"
SDK="$(xcrun --show-sdk-path)"

echo "▸ Compiling with swiftc (SDK: $SDK)…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# -parse-as-library: honor @main instead of treating files as top-level script.
# -swift-version 5: match the project's pinned language mode.
swiftc -parse-as-library -swift-version 5 -target "$TARGET" -sdk "$SDK" -O \
    $(find Sources/Sauron -name '*.swift') \
    -o "$BUNDLE/Contents/MacOS/${APP_NAME}"

cp bundle/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Ad-hoc sign (override with SAURON_SIGN_IDENTITY for a stable identity, which
# lets macOS remember the Accessibility grant across rebuilds).
# Pick a signing identity. A STABLE identity (same cert every build) keeps the
# app's code signature constant, so macOS preserves the Accessibility grant
# across rebuilds instead of invalidating it each time (which ad-hoc "-" signing
# does, because its cdhash changes every build). Preference order:
#   1. explicit SAURON_SIGN_IDENTITY override,
#   2. the first real codesigning identity in the keychain (e.g. Apple Dev),
#   3. ad-hoc "-" as a last resort.
if [ -n "${SAURON_SIGN_IDENTITY:-}" ]; then
    SIGN_ID="$SAURON_SIGN_IDENTITY"
else
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/[0-9A-F]{40}/{print $2; exit}')"
    [ -z "$SIGN_ID" ] && SIGN_ID="-"
fi
echo "▸ Signing (identity: ${SIGN_ID})…"
codesign --force --sign "$SIGN_ID" \
    --identifier "com.sauron.Sauron" \
    --timestamp=none \
    "$BUNDLE"
codesign --verify --verbose "$BUNDLE"

echo "✓ Built: $ROOT/$BUNDLE"
echo "  Run it with:  open \"$ROOT/$BUNDLE\""
