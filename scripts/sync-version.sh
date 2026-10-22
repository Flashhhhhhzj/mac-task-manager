#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [ "$#" -ne 1 ] || [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "用法: $0 <版本号>（例如 1.0.0 或 1.0.0-beta.2）" >&2
    exit 2
fi

if [[ "$(<"$ROOT_DIR/VERSION")" != "$VERSION" ]]; then
    build_number="$(<"$ROOT_DIR/BUILD_NUMBER")"
    [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo "BUILD_NUMBER 无效" >&2; exit 1; }
    printf '%s\n' "$((build_number + 1))" > "$ROOT_DIR/BUILD_NUMBER"
    printf '%s\n' "$VERSION" > "$ROOT_DIR/VERSION"
fi
echo "版本: ${VERSION}，构建: $(<"$ROOT_DIR/BUILD_NUMBER")"
