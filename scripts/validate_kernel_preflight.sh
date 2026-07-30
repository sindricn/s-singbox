#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

cat > "$TMP_DIR/plain-singbox" <<'EOF'
#!/bin/sh
echo 'sing-box version 1.14.0'
EOF
cat > "$TMP_DIR/stats-singbox" <<'EOF'
#!/bin/sh
echo 'sing-box version 1.14.0 Tags: with_v2ray_api'
EOF
chmod +x "$TMP_DIR/plain-singbox" "$TMP_DIR/stats-singbox"

kernel_state=plain
build_count=0
last_start_mode=''
get_singbox_bin() {
    if [[ "$kernel_state" == stats ]]; then
        echo "$TMP_DIR/stats-singbox"
    else
        echo "$TMP_DIR/plain-singbox"
    fi
}
resolve_singbox_version() { echo '1.14.0'; }
build_and_install_singbox() {
    last_start_mode=${2:-true}
    kernel_state=stats
    build_count=$((build_count + 1))
}

SINGBOX_AUTO_REPAIR_STATS_KERNEL=1
ensure_singbox_stats_capability
[[ "$kernel_state" == stats && "$build_count" -eq 1 ]]
[[ "$last_start_mode" == false ]]
singbox_has_stats_capability

# 已具备能力时不得重复构建。
ensure_singbox_stats_capability
[[ "$build_count" -eq 1 ]]

# 已有配置时修复完成后应恢复服务，随后由原操作应用新配置。
echo '{}' > "$SINGBOX_CONFIG"
kernel_state=plain
ensure_singbox_stats_capability
[[ "$kernel_state" == stats && "$build_count" -eq 2 ]]
[[ "$last_start_mode" == true ]]

# 明确禁用自动修复时必须安全失败。
kernel_state=plain
SINGBOX_AUTO_REPAIR_STATS_KERNEL=0
if ensure_singbox_stats_capability >/dev/null 2>&1; then
    echo "禁用自动修复后仍错误放行普通内核" >&2
    exit 1
fi

echo "内核能力预检回归检查通过"
