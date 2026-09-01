#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_DIR="$PROJECT_DIR/dist/Town Sheriff.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
VERSION="${TOWN_DOCK_VERSION:-$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")}"
BUILD_NUMBER="${TOWN_DOCK_BUILD_NUMBER:-1}"
SIGN_IDENTITY="${TOWN_DOCK_SIGN_IDENTITY:--}"
FEED_URL="${TOWN_DOCK_FEED_URL:-}"
PUBLIC_ED_KEY="${TOWN_DOCK_PUBLIC_ED_KEY:-$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PROJECT_DIR/Resources/Info.plist")}"
UNIVERSAL_BUILD="${TOWN_DOCK_UNIVERSAL:-0}"

cd "$PROJECT_DIR"

# Some Command Line Tools releases expose a newer default SDK than their Swift
# overlays can consume. Prefer the installed 15.4 compatibility SDK when it is
# available; full Xcode users can override SDKROOT explicitly.
if [[ -z "${SDKROOT:-}" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/town-dock-clang-cache}"

if [[ "$UNIVERSAL_BUILD" == "1" ]]; then
  swift build -c "$CONFIGURATION" --disable-sandbox --triple arm64-apple-macosx14.0
  ARM_BIN_DIR="$(swift build -c "$CONFIGURATION" --disable-sandbox --triple arm64-apple-macosx14.0 --show-bin-path)"
  swift build -c "$CONFIGURATION" --disable-sandbox --triple x86_64-apple-macosx14.0
  X86_BIN_DIR="$(swift build -c "$CONFIGURATION" --disable-sandbox --triple x86_64-apple-macosx14.0 --show-bin-path)"
  BIN_DIR="$ARM_BIN_DIR"
else
  swift build -c "$CONFIGURATION" --disable-sandbox
  BIN_DIR="$(swift build -c "$CONFIGURATION" --disable-sandbox --show-bin-path)"
fi

if [[ -e "$APP_DIR" ]]; then
  rm -rf "$APP_DIR"
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
if [[ "$UNIVERSAL_BUILD" == "1" ]]; then
  lipo -create "$ARM_BIN_DIR/TownDock" "$X86_BIN_DIR/TownDock" -output "$MACOS_DIR/TownDock"
else
  cp "$BIN_DIR/TownDock" "$MACOS_DIR/TownDock"
fi
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/Phosphor-LICENSE.txt" "$RESOURCES_DIR/Phosphor-LICENSE.txt"
cp "$PROJECT_DIR/Resources/SwiftTerm-LICENSE.txt" "$RESOURCES_DIR/SwiftTerm-LICENSE.txt"
ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORKS_DIR/Sparkle.framework"
ditto "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$RESOURCES_DIR/SwiftTerm_SwiftTerm.bundle"
swift "$PROJECT_DIR/scripts/generate-app-icon.swift" "$RESOURCES_DIR/TownSheriff.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

if [[ -n "$FEED_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$CONTENTS_DIR/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_ED_KEY" "$CONTENTS_DIR/Info.plist"

# SwiftPM links binary frameworks using @rpath. Point the executable at the
# conventional app Frameworks directory used by Sparkle and notarization.
install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS_DIR/TownDock"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # Local development build. Sparkle remains vendor-signed and the host uses
  # an ad-hoc signature without Hardened Runtime/library validation.
  codesign --force --sign - --timestamp=none "$APP_DIR"
else
  SPARKLE_VERSION_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    "$SPARKLE_VERSION_DIR/Autoupdate"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    "$SPARKLE_VERSION_DIR/Updater.app"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    "$FRAMEWORKS_DIR/Sparkle.framework"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/Resources/TownDock.entitlements" \
    "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"

printf 'Packaged Town Sheriff %s (%s) at %s\n' "$VERSION" "$BUILD_NUMBER" "$APP_DIR"
