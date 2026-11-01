#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE_NAME="${1:-}"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-}"
if [[ -z "$BUNDLE_ID" ]]; then
    echo "Set PRODUCT_BUNDLE_IDENTIFIER to your own unique reverse-DNS identifier." >&2
    exit 2
fi

if [[ -z "$DEVICE_NAME" ]]; then
    echo "Usage: DEVELOPMENT_TEAM=YOURTEAMID $0 'Your iPhone name'" >&2
    echo "Connected devices:" >&2
    xcrun devicectl list devices >&2 || true
    exit 2
fi

if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' | head -n 1)"
fi

if [[ -z "$TEAM_ID" ]]; then
    echo "No Apple Development signing team was found." >&2
    echo "Create one once in Xcode > Settings > Accounts, then set DEVELOPMENT_TEAM." >&2
    exit 2
fi

DERIVED_DATA="$SCRIPT_DIR/.build"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/PrismCamera.app"

# Compile the exact bundled shader on the Mac before installing. No Metal Toolchain download needed.
VALIDATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prism-metal-check.XXXXXX")"
trap 'rm -rf "$VALIDATION_DIR"' EXIT
xcrun swiftc -module-cache-path "$VALIDATION_DIR/cache" "$SCRIPT_DIR/tests/validate-metal.swift" -o "$VALIDATION_DIR/validate"
"$VALIDATION_DIR/validate" "$SCRIPT_DIR/PrismCamera/Optics.metal"

xcodebuild \
    -project "$SCRIPT_DIR/PrismCamera.xcodeproj" \
    -scheme PrismCamera \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS,name=$DEVICE_NAME" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    build

xcrun devicectl device install app --device "$DEVICE_NAME" "$APP_PATH"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_NAME" "$BUNDLE_ID"
