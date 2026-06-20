#!/bin/sh
#
# make-app.sh — wrap the release build of HDRViewer into a real macOS .app
# bundle so it gets a Dock icon, a Cmd-Tab entry, and a proper menu bar.
#
# Usage:
#   tools/make-app.sh                # builds release, produces ./HDRViewer.app
#   OUTPUT_DIR=/some/dir tools/make-app.sh
#
# The resulting bundle is self-contained; point ~/darktable-hdr.command at
#   /Users/mayk/darktable-hdr-viewer/HDRViewer.app/Contents/MacOS/HDRViewer
# (or `open -a HDRViewer.app`) instead of the bare .build/release binary.
#
# POSIX sh, no bashisms. Safe to re-run: the .app is rebuilt from scratch.

set -eu

# Resolve the repository root from this script's location so it works no matter
# the caller's working directory.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

APP_NAME="HDRViewer"
EXECUTABLE="HDRViewer"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

PLIST_SRC="$REPO_ROOT/Resources/Info.plist"
ICON_SRC="$REPO_ROOT/Resources/AppIcon.icns"

echo "==> Building release product"
( cd "$REPO_ROOT" && swift build -c release )

BUILD_BIN=$( cd "$REPO_ROOT" && swift build -c release --show-bin-path )/$EXECUTABLE
if [ ! -x "$BUILD_BIN" ]; then
    echo "error: built executable not found at $BUILD_BIN" >&2
    exit 1
fi

if [ ! -f "$PLIST_SRC" ]; then
    echo "error: Info.plist not found at $PLIST_SRC" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the (possibly symlinked) build product as a real file.
cp -f "$BUILD_BIN" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

cp -f "$PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"

# PkgInfo is optional but expected by Launch Services for a tidy bundle.
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Bundle the icon if one has been generated (see note below). The Info.plist
# references "AppIcon"; without the .icns the app simply falls back to a generic
# icon, which is harmless.
if [ -f "$ICON_SRC" ]; then
    cp -f "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "note: $ICON_SRC missing — bundle will use a generic icon."
    echo "      To add one: place an AppIcon.icns in Resources/ (e.g. via"
    echo "      'iconutil -c icns AppIcon.iconset') and re-run this script."
fi

# Ad-hoc codesign so Gatekeeper/launchd treat the bundle as a stable identity
# (lets it keep TCC/window-position state across rebuilds). Ignore failure on
# machines without the codesign toolchain.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || \
        echo "note: ad-hoc codesign skipped (codesign returned non-zero)."
fi

# Refresh Launch Services so the Dock icon/Cmd-Tab entry register immediately.
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> Done: $APP_BUNDLE"
echo "    Launch with:  open \"$APP_BUNDLE\""
