#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-}"
EXPECTED_VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
BUILD_NUMBER="${TOWN_DOCK_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
SIGN_IDENTITY="${TOWN_DOCK_SIGN_IDENTITY:-}"
FEED_URL="${TOWN_DOCK_FEED_URL:-}"
DOWNLOAD_PREFIX="${TOWN_DOCK_DOWNLOAD_URL_PREFIX:-}"
NOTARY_PROFILE="${TOWN_DOCK_NOTARY_PROFILE:-TownDock}"
UPDATES_DIR="$PROJECT_DIR/dist/updates"
ARCHIVE_NAME="Town-Dock-$VERSION.zip"
ARCHIVE_PATH="$UPDATES_DIR/$ARCHIVE_NAME"
SPARKLE_TOOLS="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  printf 'Usage: %s VERSION (for example, 0.2.0)\n' "$0" >&2
  exit 2
fi
if [[ "$VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'VERSION contains %s; update it before releasing %s.\n' "$EXPECTED_VERSION" "$VERSION" >&2
  exit 2
fi
if [[ -z "$SIGN_IDENTITY" || -z "$FEED_URL" || -z "$DOWNLOAD_PREFIX" ]]; then
  printf 'Set TOWN_DOCK_SIGN_IDENTITY, TOWN_DOCK_FEED_URL, and TOWN_DOCK_DOWNLOAD_URL_PREFIX.\n' >&2
  exit 2
fi
if [[ ! -x "$SPARKLE_TOOLS/generate_appcast" ]]; then
  printf 'Sparkle tools are missing; run swift package resolve first.\n' >&2
  exit 2
fi

cd "$PROJECT_DIR"
TOWN_DOCK_VERSION="$VERSION" \
TOWN_DOCK_BUILD_NUMBER="$BUILD_NUMBER" \
TOWN_DOCK_SIGN_IDENTITY="$SIGN_IDENTITY" \
TOWN_DOCK_FEED_URL="$FEED_URL" \
TOWN_DOCK_UNIVERSAL=1 \
  "$SCRIPT_DIR/package-app.sh" release

mkdir -p "$UPDATES_DIR"
find "$UPDATES_DIR" -maxdepth 1 -type f -name 'Town-Dock-*.zip' -delete
ditto -c -k --sequesterRsrc --keepParent "dist/Town Dock.app" "$ARCHIVE_PATH"

xcrun notarytool submit "$ARCHIVE_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "dist/Town Dock.app"
xcrun stapler validate "dist/Town Dock.app"

# Rebuild the archive so the distributed app contains its stapled ticket.
ditto -c -k --sequesterRsrc --keepParent "dist/Town Dock.app" "$ARCHIVE_PATH"

"$SPARKLE_TOOLS/generate_appcast" \
  --account com.tony.towndock \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  "$UPDATES_DIR"

printf 'Release artifacts ready:\n  %s\n  %s\n' \
  "$ARCHIVE_PATH" "$UPDATES_DIR/appcast.xml"
