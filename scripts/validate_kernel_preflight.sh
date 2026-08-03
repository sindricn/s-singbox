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

# 已下载工具链必须被直接复用，且函数标准输出只能有一条可执行路径。
SINGBOX_GO_DIR="$TMP_DIR/toolchain/go"
mkdir -p "$SINGBOX_GO_DIR/bin"
cat > "$SINGBOX_GO_DIR/bin/go" <<'EOF'
#!/bin/sh
echo 'go version go99.0.0 linux/amd64'
EOF
chmod +x "$SINGBOX_GO_DIR/bin/go"
# 使用远高于 CI 预装 Go 的最低版本，确保覆盖“复用项目工具链”分支。
resolved_go=$(ensure_singbox_go '99.0.0')
[[ "$resolved_go" == "$SINGBOX_GO_DIR/bin/go" ]]

# 兼容官方逗号格式、旧换行/空格格式，并输出 Go 1.25 接受的单一逗号列表。
cat > "$TMP_DIR/build-tags" <<'EOF'
with_gvisor,with_quic
with_dhcp with_gvisor
EOF
normalized_tags=$(normalize_singbox_build_tags "$TMP_DIR/build-tags")
[[ "$normalized_tags" == 'with_gvisor,with_quic,with_dhcp,with_v2ray_api,with_clash_api' ]]
[[ "$normalized_tags" != *' '* ]]
echo 'with_gvisor,with_naive_outbound,with_quic' > "$TMP_DIR/build-tags-full"
safe_tags=$(normalize_singbox_build_tags "$TMP_DIR/build-tags-full" 'with_naive_outbound')
[[ "$safe_tags" == 'with_gvisor,with_quic,with_v2ray_api,with_clash_api' ]]
mkdir -p "$TMP_DIR/fake-release/release"
echo '-s -w' > "$TMP_DIR/fake-release/release/LDFLAGS"
[[ "$(compose_singbox_build_ldflags "$TMP_DIR/fake-release" '1.13.15')" == '-s -w -X github.com/sagernet/sing-box/constant.Version=1.13.15' ]]
echo 'with_gvisor,@invalid' > "$TMP_DIR/invalid-build-tags"
if normalize_singbox_build_tags "$TMP_DIR/invalid-build-tags" >/dev/null 2>&1; then
    echo "非法构建标签未被拒绝" >&2
    exit 1
fi

# 构建包装器必须创建候选文件，并支持可见进度参数。
mkdir -p "$TMP_DIR/fake-source"
cat > "$TMP_DIR/build-go" <<'EOF'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-o' ]; then
        shift
        output=$1
    fi
    shift
done
echo 'fixture/package'
sleep 1
: > "$output"
EOF
chmod +x "$TMP_DIR/build-go"
SINGBOX_BUILD_HEARTBEAT_SECONDS=1 SINGBOX_BUILD_TIMEOUT=10s \
    run_singbox_go_build "$TMP_DIR/fake-source" "$TMP_DIR/build-go" 'with_v2ray_api' '' "$TMP_DIR/fake-candidate"
[[ -f "$TMP_DIR/fake-candidate" ]]

cat > "$TMP_DIR/plain-singbox" <<'EOF'
#!/bin/sh
echo 'sing-box version 1.13.15'
EOF
cat > "$TMP_DIR/stats-singbox" <<'EOF'
#!/bin/sh
echo 'sing-box version 1.13.15 Tags: with_v2ray_api'
EOF
cat > "$TMP_DIR/full-singbox" <<'EOF'
#!/bin/sh
echo 'sing-box version 1.13.15 Tags: with_v2ray_api,with_naive_outbound'
EOF
cat > "$TMP_DIR/project-singbox" <<'EOF'
#!/bin/sh
echo 'sing-box version 1.13.15 Tags: with_v2ray_api,with_clash_api'
EOF
chmod +x "$TMP_DIR/plain-singbox" "$TMP_DIR/stats-singbox" "$TMP_DIR/full-singbox" "$TMP_DIR/project-singbox"

(
    uname() { echo x86_64; }
    [[ "$(resolve_singbox_prebuilt_arch)" == amd64 ]]
)
(
    uname() { echo aarch64; }
    [[ "$(resolve_singbox_prebuilt_arch)" == arm64 ]]
)

get_singbox_bin() { echo "$TMP_DIR/project-singbox"; }
SINGBOX_PROJECT_KERNEL_METADATA="$TMP_DIR/project-kernel.json"
write_project_kernel_metadata "$TMP_DIR/project-singbox" '1.13.15' 'validation-fixture'
singbox_has_online_user_capability
printf '\n# changed\n' >> "$TMP_DIR/project-singbox"
! singbox_has_online_user_capability

(
    download_and_install_prebuilt_singbox() { printf '%s' "$1|$2" > "$TMP_DIR/prebuilt-call"; }
    build_singbox_from_source_and_install() { return 99; }
    build_and_install_singbox '1.13.15' false
    [[ "$(cat "$TMP_DIR/prebuilt-call")" == '1.13.15|false' ]]
)
(
    local_build_called=0
    download_and_install_prebuilt_singbox() { return 1; }
    build_singbox_from_source_and_install() { local_build_called=1; }
    SINGBOX_LOCAL_BUILD_FALLBACK=never
    ! build_and_install_singbox '1.13.15' true >/dev/null 2>&1
    [[ "$local_build_called" == 0 ]]
    SINGBOX_LOCAL_BUILD_FALLBACK=always
    build_and_install_singbox '1.13.15' true
    [[ "$local_build_called" == 1 ]]
)

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
resolve_singbox_version() { echo '1.13.15'; }
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
! singbox_has_build_tag with_naive_outbound

get_singbox_bin() { echo "$TMP_DIR/full-singbox"; }
singbox_has_build_tag with_v2ray_api
singbox_has_build_tag with_naive_outbound

# 已具备能力时不得重复构建。
get_singbox_bin() {
    if [[ "$kernel_state" == stats ]]; then
        echo "$TMP_DIR/stats-singbox"
    else
        echo "$TMP_DIR/plain-singbox"
    fi
}
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
    echo "禁用自动修复后仍错误放行不兼容内核" >&2
    exit 1
fi

echo "内核能力预检回归检查通过"
