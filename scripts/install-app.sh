#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
TASK_APP="$TASK_ROOT/dist/Capture DualLink.app"
TASK_DEST="$HOME/Applications/Capture DualLink.app"
if [[ ! -d "$TASK_APP" ]]; then
    "$TASK_ROOT/scripts/build-app.sh"
fi
if [[ -e "$TASK_DEST" ]]; then
    TASK_EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TASK_DEST/Contents/Info.plist")
    if [[ "$TASK_EXISTING_ID" != com.captureduallink.mac ]]; then
        print -u2 "Another app already exists at $TASK_DEST; leaving it intact."
        exit 1
    fi
fi
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "$TASK_APP" "$TASK_DEST"
codesign --verify --strict "$TASK_DEST"
print "Installed: $TASK_DEST"
