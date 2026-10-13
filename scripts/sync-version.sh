#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [ "$#" -ne 1 ] || [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "用法: $0 <版本号>（例如 1.0.0 或 1.0.0-beta.2）" >&2
    exit 2
fi

printf '%s\n' "$VERSION" > "$ROOT_DIR/VERSION"
echo "已更新版本号: $VERSION"
