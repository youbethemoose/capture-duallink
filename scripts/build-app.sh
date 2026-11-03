#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
mkdir -p .build/ModuleCache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/ModuleCache"
SWIFT_OPTIONS=(--disable-sandbox --build-system native -debug-info-format none --cache-path "$TASK_ROOT/.build/cache" --config-path "$TASK_ROOT/.build/config" --security-path "$TASK_ROOT/.build/security" --scratch-path "$TASK_ROOT/.build" --manifest-cache local -Xswiftc -module-cache-path -Xswiftc "$TASK_ROOT/.build/ModuleCache")
TASK_ARCHITECTURES=("$(uname -m)")
if [[ "${1:-}" == --universal ]]; then
    TASK_ARCHITECTURES=(arm64 x86_64)
elif [[ $# -gt 0 ]]; then
    print -u2 "Usage: $0 [--universal]"
    exit 1
fi
TASK_BINARIES=()
for TASK_ARCH in "${TASK_ARCHITECTURES[@]}"; do
    swift build "${SWIFT_OPTIONS[@]}" --arch "$TASK_ARCH" --configuration release
    TASK_BIN_DIR=$(swift build "${SWIFT_OPTIONS[@]}" --arch "$TASK_ARCH" --configuration release --show-bin-path)
    TASK_BINARIES+=("$TASK_BIN_DIR/CaptureDualLink")
done
# Sign outside synced Documents folders, which can reattach Finder metadata mid-signature.
TASK_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/duallink-build.XXXXXX")
trap 'rm -rf "$TASK_STAGE"' EXIT
TASK_APP="$TASK_STAGE/Capture DualLink.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
lipo -create "${TASK_BINARIES[@]}" -output "$TASK_APP/Contents/MacOS/CaptureDualLink"
cp "$TASK_ROOT/Resources/Info.plist" "$TASK_APP/Contents/Info.plist"
if [[ ! -f "$TASK_ROOT/.build/DualLink.icns" || "$TASK_ROOT/scripts/make-icon.swift" -nt "$TASK_ROOT/.build/DualLink.icns" || "$TASK_ROOT/Sources/CaptureDualLink/MenuBarIcon.swift" -nt "$TASK_ROOT/.build/DualLink.icns" ]]; then
    cat "$TASK_ROOT/Sources/CaptureDualLink/MenuBarIcon.swift" "$TASK_ROOT/scripts/make-icon.swift" > "$TASK_ROOT/.build/make-icon.swift"
    swift "$TASK_ROOT/.build/make-icon.swift" "$TASK_ROOT/.build/DualLink.iconset"
    iconutil -c icns "$TASK_ROOT/.build/DualLink.iconset" -o "$TASK_ROOT/.build/DualLink.icns"
fi
cp "$TASK_ROOT/.build/DualLink.icns" "$TASK_APP/Contents/Resources/DualLink.icns"
# Finder can attach display metadata to generated bundles in synced Documents folders.
# Remove only metadata that codesign disallows; preserve security attributes.
xattr -dr com.apple.FinderInfo "$TASK_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$TASK_APP" 2>/dev/null || true
# Prefer an Apple Development certificate (free with any Apple ID in Xcode → Settings → Accounts).
# Its designated requirement is tied to that certificate, so Screen Recording permission survives
# rebuilds without letting any other program that reuses this identifier inherit it.
# Override with DUALLINK_SIGN_IDENTITY="<identity>".
TASK_IDENTITY="${DUALLINK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -n "$TASK_IDENTITY" ]]; then
    codesign --force --sign "$TASK_IDENTITY" --identifier com.captureduallink.mac "$TASK_APP"
else
    print -u2 "warning: no Apple Development certificate found; using an ad-hoc signature."
    print -u2 "warning: macOS may ask for Screen Recording permission again after each rebuild."
    codesign --force --sign - --identifier com.captureduallink.mac "$TASK_APP"
fi
codesign --verify --strict "$TASK_APP"
mkdir -p "$TASK_ROOT/dist"
ditto --norsrc --noextattr "$TASK_APP" "$TASK_ROOT/dist/Capture DualLink.app"
print "Built: $TASK_ROOT/dist/Capture DualLink.app"
