#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
if [ ! -d "$TASK_ROOT/dist/Capture DualLink.app" ]; then
    "$TASK_ROOT/scripts/build-app.sh"
fi
open "$TASK_ROOT/dist/Capture DualLink.app"
