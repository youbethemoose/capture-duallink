#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
mkdir -p .build/ModuleCache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/ModuleCache"
SWIFT_OPTIONS=(--disable-sandbox --build-system native -debug-info-format none --cache-path "$TASK_ROOT/.build/cache" --config-path "$TASK_ROOT/.build/config" --security-path "$TASK_ROOT/.build/security" --scratch-path "$TASK_ROOT/.build" --manifest-cache local -Xswiftc -module-cache-path -Xswiftc "$TASK_ROOT/.build/ModuleCache")
swift build "${SWIFT_OPTIONS[@]}" --configuration release
TASK_BIN_DIR=$(swift build "${SWIFT_OPTIONS[@]}" --configuration release --show-bin-path)
TASK_APP="$TASK_ROOT/dist/Capture DualLink.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN_DIR/CaptureDualLink" "$TASK_APP/Contents/MacOS/CaptureDualLink"
cp "$TASK_ROOT/Resources/Info.plist" "$TASK_APP/Contents/Info.plist"
if [[ ! -f "$TASK_ROOT/.build/DualLink.icns" || "$TASK_ROOT/scripts/make-icon.swift" -nt "$TASK_ROOT/.build/DualLink.icns" ]]; then
    swift "$TASK_ROOT/scripts/make-icon.swift" "$TASK_ROOT/.build/DualLink.iconset"
    iconutil -c icns "$TASK_ROOT/.build/DualLink.iconset" -o "$TASK_ROOT/.build/DualLink.icns"
fi
cp "$TASK_ROOT/.build/DualLink.icns" "$TASK_APP/Contents/Resources/DualLink.icns"
# Finder can attach display metadata to generated bundles in synced Documents folders.
# Remove only metadata that codesign disallows; preserve security attributes.
xattr -dr com.apple.FinderInfo "$TASK_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$TASK_APP" 2>/dev/null || true
# Stable local identity lets Screen Recording permission survive local rebuilds.
codesign --force --sign - --identifier com.captureduallink.mac -r='designated => identifier "com.captureduallink.mac"' "$TASK_APP"
codesign --verify --strict "$TASK_APP"
print "Built: $TASK_APP"
