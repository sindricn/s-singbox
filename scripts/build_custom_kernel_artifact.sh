#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=${SINGBOX_BUILD_VERSION:-1.13.15}
OUTPUT=${SINGBOX_BUILD_OUTPUT:?SINGBOX_BUILD_OUTPUT is required}
TARGET_GOOS=${SINGBOX_BUILD_GOOS:-linux}
TARGET_GOARCH=${SINGBOX_BUILD_GOARCH:-amd64}
TARGET_GOARM=${SINGBOX_BUILD_GOARM:-}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

export RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY='' NC=''
export LOG_FILE="$TMP_DIR/build.log" LOG_LEVEL=3
DATA_DIR="$TMP_DIR/data"
SINGBOX_CONFIG="$TMP_DIR/config.json"
mkdir -p "$DATA_DIR" "$(dirname "$OUTPUT")"

# shellcheck source=/dev/null
source "$ROOT_DIR/modules/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/zz_singbox_114.sh"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]
[[ "$TARGET_GOOS" == linux ]]
[[ "$TARGET_GOARCH" =~ ^(amd64|arm64|arm)$ ]]
if [[ "$TARGET_GOARCH" == arm ]]; then
    [[ "$TARGET_GOARM" =~ ^(6|7)$ ]]
else
    TARGET_GOARM=''
fi

git -c advice.detachedHead=false clone --depth 1 --single-branch --branch "v${VERSION}" \
    https://github.com/SagerNet/sing-box.git "$TMP_DIR/source"

TAGS_FILE="$TMP_DIR/source/release/DEFAULT_BUILD_TAGS_OTHERS"
[[ -f "$TAGS_FILE" ]] || TAGS_FILE="$TMP_DIR/source/release/DEFAULT_BUILD_TAGS"
[[ -f "$TAGS_FILE" ]]
apply_clash_api_user_patch "$TMP_DIR/source"
(cd "$TMP_DIR/source" && "$(command -v go)" fmt ./experimental/clashapi/trafficontrol >/dev/null)

TAGS=$(normalize_singbox_build_tags "$TAGS_FILE" 'with_naive_outbound')
LDFLAGS=$(compose_singbox_build_ldflags "$TMP_DIR/source" "$VERSION")
export GOOS="$TARGET_GOOS" GOARCH="$TARGET_GOARCH" CGO_ENABLED=0
if [[ -n "$TARGET_GOARM" ]]; then
    export GOARM="$TARGET_GOARM"
else
    unset GOARM || true
fi
run_singbox_go_build "$TMP_DIR/source" "$(command -v go)" "$TAGS" "$LDFLAGS" "$OUTPUT"
chmod 755 "$OUTPUT"

go version -m "$OUTPUT" | grep -q -- '-tags=.*with_v2ray_api'
go version -m "$OUTPUT" | grep -q -- '-tags=.*with_clash_api'
grep -q '"inboundUser":[[:space:]]*t.Metadata.User' \
    "$TMP_DIR/source/experimental/clashapi/trafficontrol/tracker.go"

if [[ "$TARGET_GOARCH" == amd64 && "$(uname -m)" =~ ^(x86_64|amd64)$ ]]; then
    "$OUTPUT" version | grep -q "sing-box version ${VERSION}"
fi

echo "Built sing-box v${VERSION} for ${TARGET_GOOS}/${TARGET_GOARCH}${TARGET_GOARM:+v${TARGET_GOARM}}: $OUTPUT"
