#!/bin/sh
# 仓库入口复用技能内唯一实现，安装后的技能也可脱离仓库运行。
set -eu
LUMEN_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$LUMEN_SCRIPT_DIR/../skills/ios-app-logs/scripts/ios_logs.py" "$@"
