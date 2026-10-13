#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${FLUIDMOUSE_BUILD_DIR:-$ROOT_DIR/.build}"
APP_BUNDLE="${FLUIDMOUSE_APP_PATH:-$ROOT_DIR/dist/FluidMouse.app}"
CONFIG=debug
if [[ "$MODE" == "--package" ]]; then CONFIG=release; fi
mkdir -p "$BUILD_DIR/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache"
# Stop only this app before replacing its executable, leaving other utilities alone.
/usr/bin/pkill -x Fluido >/dev/null 2>&1 || true
/usr/bin/pkill -x FluidMouse >/dev/null 2>&1 || true
cd "$ROOT_DIR"
swift build -c "$CONFIG" --scratch-path "$BUILD_DIR"
BUILD_BINARY="$(swift build -c "$CONFIG" --scratch-path "$BUILD_DIR" --show-bin-path)/FluidMouse"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/FluidMouse"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
mkdir -p "$BUILD_DIR/IconModuleCache"
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/IconModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/IconModuleCache" \
swift -module-cache-path "$BUILD_DIR/IconModuleCache" \
    "$ROOT_DIR/Resources/generate-icon.swift" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
chmod +x "$APP_BUNDLE/Contents/MacOS/FluidMouse"
# Remove only signing-incompatible metadata on the generated bundle.
/usr/bin/xattr -dr com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP_BUNDLE" 2>/dev/null || true
codesign --force --sign - --identifier br.com.douglas.fluido "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
case "$MODE" in
  --package) echo "$APP_BUNDLE" ;;
  run) /usr/bin/open "$APP_BUNDLE" ;;
  --verify) /usr/bin/open "$APP_BUNDLE"; sleep 2; /usr/bin/pgrep -x FluidMouse ;;
  --logs) /usr/bin/open "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "FluidMouse"' ;;
  --telemetry) /usr/bin/open "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "br.com.douglas.fluido"' ;;
  --debug) /usr/bin/lldb -- "$APP_BUNDLE/Contents/MacOS/FluidMouse" ;;
  *) echo "usage: $0 [run|--package|--verify|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac
