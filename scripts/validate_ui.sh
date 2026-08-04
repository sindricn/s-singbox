#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

export RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY='' NC=''
export LOG_FILE="${TMPDIR:-/tmp}/singbox-ui-validation.log" LOG_LEVEL=4
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/selector.sh"

if [[ -n "${1:-}" ]]; then
    WORK_DIR="$1"
else
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
fi
mkdir -p "$WORK_DIR"

if grep -RInE 'local[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\$\(read_menu_choice|local[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\$\(select_(single|multiple)|local[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\(\$\(select_(single|multiple)' \
    "$ROOT_DIR/modules" "$ROOT_DIR/singbox-manager.sh" --include='*.sh' \
    --exclude='*.bak' --exclude='*.backup*' --exclude='*_backup*'; then
    echo "菜单命令替换仍存在返回码被 local 掩盖的风险" >&2
    exit 1
fi

grep -q 'readonly APP_VERSION="1.1.1"' "$ROOT_DIR/singbox-manager.sh"
! grep -qE 'V1\.0\.0|V2\.0\.0|get_online_users_count' "$ROOT_DIR/singbox-manager.sh"
grep -q 'get_realtime_online_users_count' "$ROOT_DIR/singbox-manager.sh"
grep -q '在线用户' "$ROOT_DIR/singbox-manager.sh"
grep -q '活动连接' "$ROOT_DIR/singbox-manager.sh"
grep -q 'print_menu_item "5" "当前在线用户"' "$ROOT_DIR/singbox-manager.sh"
grep -q '5) show_online_users; wait_for_input ;;' "$ROOT_DIR/singbox-manager.sh"
! grep -qE 'get_user_recent_activity_status|check_port_has_connections|get_active_traffic_users_count' \
    "$ROOT_DIR/singbox-manager.sh" "$ROOT_DIR/modules/user.sh"

selector_stdout=$(select_single "请选择" "选项A" "选项B" 2>"$WORK_DIR/selector-single-ui.txt" <<< "2")
[[ "$selector_stdout" == "1" ]]
grep -q '选项A' "$WORK_DIR/selector-single-ui.txt"
[[ $(wc -l <<< "$selector_stdout") -eq 1 ]]

selector_stdout=$(select_multiple "请选择" "选项A" "选项B" "选项C" 2>"$WORK_DIR/selector-multiple-ui.txt" <<< "1,3")
[[ "$selector_stdout" == "0 2" ]]
grep -q '支持格式' "$WORK_DIR/selector-multiple-ui.txt"

set +e
select_single "请选择" "选项A" >/dev/null 2>/dev/null <<< "b"
selector_status=$?
set -e
[[ $selector_status -eq $UI_BACK ]]

set +e
select_multiple "请选择" "选项A" >/dev/null 2>/dev/null <<< "m"
selector_status=$?
set -e
[[ $selector_status -eq $UI_MAIN_MENU ]]

set +e
select_single "请选择" "选项A" >/dev/null 2>/dev/null <<< "q"
selector_status=$?
set -e
[[ $selector_status -eq $UI_CANCEL ]]

choice=$(read_menu_choice "请选择" <<< "q")
[[ "$choice" == "q" ]]

set +e
read_menu_choice "请选择" true >/dev/null <<< "q"
selector_status=$?
set -e
[[ $selector_status -eq $UI_CANCEL ]]

echo "UI 交互回归检查通过"
