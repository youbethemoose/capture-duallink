#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
mkdir -p .build/ModuleCache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/ModuleCache"
swift test --disable-sandbox --build-system native -debug-info-format none \
    --cache-path "$TASK_ROOT/.build/cache" --config-path "$TASK_ROOT/.build/config" \
    --security-path "$TASK_ROOT/.build/security" --scratch-path "$TASK_ROOT/.build" \
    --manifest-cache local -Xswiftc -module-cache-path -Xswiftc "$TASK_ROOT/.build/ModuleCache"
