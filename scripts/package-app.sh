#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
"$TASK_ROOT/scripts/build-app.sh" --universal
TASK_APP="$TASK_ROOT/dist/Capture DualLink.app"
TASK_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_APP/Contents/Info.plist")
[[ "$TASK_VERSION" == <->.<->.<-> ]]
TASK_IMAGE="$TASK_ROOT/dist/Capture-DualLink-$TASK_VERSION-universal.dmg"
# Synced Documents folders can attach Finder metadata that invalidates app signatures.
TASK_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/duallink-share.XXXXXX")
TASK_MOUNT=""
cleanup() {
    if [[ -n "$TASK_MOUNT" ]]; then
        hdiutil detach "$TASK_MOUNT" >/dev/null 2>&1 || true
        rmdir "$TASK_MOUNT" 2>/dev/null || true
    fi
    rm -rf "$TASK_STAGE"
}
trap cleanup EXIT
lipo "$TASK_APP/Contents/MacOS/CaptureDualLink" -verify_arch arm64
lipo "$TASK_APP/Contents/MacOS/CaptureDualLink" -verify_arch x86_64
ditto --norsrc --noextattr "$TASK_APP" "$TASK_STAGE/Capture DualLink.app"
xattr -dr com.apple.FinderInfo "$TASK_STAGE/Capture DualLink.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$TASK_STAGE/Capture DualLink.app" 2>/dev/null || true
codesign --verify --strict "$TASK_STAGE/Capture DualLink.app"
ln -s /Applications "$TASK_STAGE/Applications"
cp "$TASK_ROOT/Resources/START HERE.txt" "$TASK_STAGE/START HERE.txt"
# Only the app and its instructions are staged; preferences and home Wi-Fi stay local.
[[ $(find "$TASK_STAGE" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') == 3 ]]
hdiutil create -ov -format UDZO -volname "Capture DualLink" -srcfolder "$TASK_STAGE" "$TASK_IMAGE"
hdiutil verify "$TASK_IMAGE"
TASK_MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/duallink-verify.XXXXXX")
hdiutil attach -readonly -nobrowse -mountpoint "$TASK_MOUNT" "$TASK_IMAGE" >/dev/null
codesign --verify --strict "$TASK_MOUNT/Capture DualLink.app"
cmp -s "$TASK_APP/Contents/MacOS/CaptureDualLink" "$TASK_MOUNT/Capture DualLink.app/Contents/MacOS/CaptureDualLink"
cmp -s "$TASK_ROOT/Resources/START HERE.txt" "$TASK_MOUNT/START HERE.txt"
[[ -L "$TASK_MOUNT/Applications" && $(readlink "$TASK_MOUNT/Applications") == /Applications ]]
hdiutil detach "$TASK_MOUNT" >/dev/null
rmdir "$TASK_MOUNT"
TASK_MOUNT=""
(
    cd "$TASK_ROOT/dist"
    shasum -a 256 "${TASK_IMAGE:t}" > "${TASK_IMAGE:t}.sha256"
)
print "Share this file: $TASK_IMAGE"
