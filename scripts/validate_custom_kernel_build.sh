#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=${SINGBOX_BUILD_TEST_VERSION:-1.13.15}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

export RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY='' NC=''
export LOG_FILE="$TMP_DIR/manager.log" LOG_LEVEL=3
DATA_DIR="$TMP_DIR/data"
SINGBOX_CONFIG="$TMP_DIR/config.json"
mkdir -p "$DATA_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/modules/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/zz_singbox_114.sh"

echo "克隆 sing-box v${VERSION}..."
git -c advice.detachedHead=false clone --depth 1 --single-branch --branch "v${VERSION}" \
    https://github.com/SagerNet/sing-box.git "$TMP_DIR/source"

TAGS_FILE="$TMP_DIR/source/release/DEFAULT_BUILD_TAGS_OTHERS"
[[ -f "$TAGS_FILE" ]] || {
    echo "官方本地构建标签文件不存在: $TAGS_FILE" >&2
    exit 1
}
TAGS=$(normalize_singbox_build_tags "$TAGS_FILE" 'with_naive_outbound')
[[ "$TAGS" == *with_v2ray_api* && "$TAGS" != *with_naive_outbound* && "$TAGS" != *' '* ]]

LDFLAGS=$(tr '\n' ' ' < "$TMP_DIR/source/release/LDFLAGS")
echo "执行真实 Linux 编译，标签: $TAGS"
run_singbox_go_build "$TMP_DIR/source" "$(command -v go)" "$TAGS" "$LDFLAGS" "$TMP_DIR/sing-box"

VERSION_OUTPUT=$($TMP_DIR/sing-box version)
echo "$VERSION_OUTPUT"
grep -q 'with_v2ray_api' <<< "$VERSION_OUTPUT"
if [[ -n "${SINGBOX_BUILD_TEST_OUTPUT:-}" ]]; then
    install -m 0755 "$TMP_DIR/sing-box" "$SINGBOX_BUILD_TEST_OUTPUT"
fi
echo "定制 sing-box Linux 编译检查通过"
