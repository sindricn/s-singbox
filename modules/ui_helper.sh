#!/bin/bash

# =============================================================================
# ui_helper.sh - UI增强模块
# 提供美化的界面显示、状态信息、进度条等功能
# =============================================================================

# 依赖检查（严格模式兼容）
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# NOTE: 依赖模块已在主文件中加载
# 依赖: common.sh (print_error, log_debug 等函数)

# =============================================================================
# 颜色和样式定义
# =============================================================================

# 字体样式与灰色
if [[ -z "${BOLD:-}" ]]; then
    readonly BOLD='\033[1m'
fi

if [[ -z "${GRAY:-}" ]]; then
    readonly GRAY='\033[0;37m'
fi

# 状态指示器
readonly STATUS_RUNNING="●"
readonly STATUS_STOPPED="○"
readonly STATUS_WARNING="▲"
readonly STATUS_ERROR="✖"
readonly STATUS_OK="✔"

# 框线字符 - 单线框
readonly BOX_H="─"
readonly BOX_V="│"
readonly BOX_TL="┌"
readonly BOX_TR="┐"
readonly BOX_BL="└"
readonly BOX_BR="┘"
readonly BOX_ML="├"
readonly BOX_MR="┤"
readonly BOX_MT="┬"
readonly BOX_MB="┴"
readonly BOX_MC="┼"

# 框线字符 - 双线框
readonly DBOX_H="═"
readonly DBOX_V="║"
readonly DBOX_TL="╔"
readonly DBOX_TR="╗"
readonly DBOX_BL="╚"
readonly DBOX_BR="╝"

# =============================================================================
# 状态获取函数
# =============================================================================

# 获取服务状态
get_service_status() {
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 获取服务状态描述
get_service_status_display() {
    local status=$(get_service_status)
    if [[ "$status" == "running" ]]; then
        echo -e "${GREEN}${STATUS_RUNNING} 运行中${NC}"
    else
        echo -e "${RED}${STATUS_STOPPED} 已停止${NC}"
    fi
}

# 获取节点数量
get_nodes_count() {
    local nodes_file="${DATA_DIR}/nodes.json"
    if [[ -f "$nodes_file" ]]; then
        jq '.nodes | length' "$nodes_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# 获取用户数量
get_users_count() {
    local users_file="${DATA_DIR}/users.json"
    if [[ -f "$users_file" ]]; then
        jq '.users | length' "$users_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# 获取启用用户数量
get_enabled_users_count() {
    local users_file="${DATA_DIR}/users.json"
    if [[ -f "$users_file" ]]; then
        jq '[.users[] | select(.enabled == true)] | length' "$users_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# 获取绑定数量
get_bindings_count() {
    local bindings_file="${DATA_DIR}/node_users.json"
    if [[ -f "$bindings_file" ]]; then
        jq '.bindings | length' "$bindings_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# 获取系统运行时间
get_system_uptime() {
    if command -v uptime &>/dev/null; then
        uptime -p 2>/dev/null | sed 's/up //' || echo "未知"
    else
        echo "未知"
    fi
}

# 获取系统负载
get_system_load() {
    if [[ -f /proc/loadavg ]]; then
        cut -d' ' -f1-3 /proc/loadavg
    else
        echo "未知"
    fi
}

# 获取内存使用率
get_memory_usage() {
    if command -v free &>/dev/null; then
        free | grep Mem | awk '{printf "%.1f%%", $3/$2 * 100.0}'
    else
        echo "未知"
    fi
}

# 获取磁盘使用率
get_disk_usage() {
    if command -v df &>/dev/null; then
        df -h / | tail -1 | awk '{print $5}'
    else
        echo "未知"
    fi
}

# =============================================================================
# 框线绘制函数
# =============================================================================

# 绘制水平线
draw_line() {
    local width=${1:-80}
    local char=${2:-${BOX_H}}
    printf "%${width}s" | tr ' ' "$char"
}

# 绘制带边框的标题
draw_title_box() {
    local title="$1"
    local width=${2:-80}

    # 计算标题居中
    local title_len=${#title}
    local padding=$(( (width - title_len - 4) / 2 ))
    local padding_str=$(printf "%${padding}s" "")

    echo -e "${CYAN}${BOX_TL}$(draw_line $((width-2)))${BOX_TR}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}${padding_str}  ${YELLOW}${BOLD}${title}${NC}${padding_str}  ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_BL}$(draw_line $((width-2)))${BOX_BR}${NC}"
}

# 绘制分隔线
draw_separator() {
    local width=${1:-80}
    echo -e "${CYAN}$(draw_line $width)${NC}"
}

# =============================================================================
# 信息面板显示
# =============================================================================

# 显示系统状态面板
show_status_panel() {
    local service_status=$(get_service_status_display)
    local nodes_count=$(get_nodes_count)
    local users_count=$(get_users_count)
    local enabled_users=$(get_enabled_users_count)
    local bindings_count=$(get_bindings_count)

    echo ""
    echo -e "${CYAN}┌─ 系统状态 ─────────────────────────────────────────────────────┐${NC}"
    printf "${CYAN}│${NC} 服务状态: %-45s ${CYAN}│${NC}\n" "$service_status"
    printf "${CYAN}│${NC} 节点数量: ${YELLOW}%-4s${NC} 用户数量: ${YELLOW}%-4s${NC} (启用: ${GREEN}%-4s${NC}) 绑定数: ${YELLOW}%-4s${NC} ${CYAN}│${NC}\n" \
        "$nodes_count" "$users_count" "$enabled_users" "$bindings_count"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# 显示系统资源面板
show_resource_panel() {
    local uptime=$(get_system_uptime)
    local load=$(get_system_load)
    local memory=$(get_memory_usage)
    local disk=$(get_disk_usage)

    echo -e "${CYAN}┌─ 系统资源 ─────────────────────────────────────────────────────┐${NC}"
    printf "${CYAN}│${NC} 运行时间: ${GREEN}%-50s${NC} ${CYAN}│${NC}\n" "$uptime"
    printf "${CYAN}│${NC} 系统负载: ${YELLOW}%-50s${NC} ${CYAN}│${NC}\n" "$load"
    printf "${CYAN}│${NC} 内存使用: ${YELLOW}%-50s${NC} ${CYAN}│${NC}\n" "$memory"
    printf "${CYAN}│${NC} 磁盘使用: ${YELLOW}%-50s${NC} ${CYAN}│${NC}\n" "$disk"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# 显示快捷提示
show_quick_tips() {
    # 如果智能提示系统可用，显示智能提示
    if declare -f show_quick_tips_panel &>/dev/null; then
        show_quick_tips_panel
    else
        # 降级到静态提示
        echo -e "${CYAN}┌─ 快捷提示 ─────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${NC} ${YELLOW}提示:${NC} 首次使用请先配置节点和用户，然后绑定关系后生成配置 ${CYAN}│${NC}"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
        echo ""
    fi
}

# =============================================================================
# 进度条显示
# =============================================================================

# 显示进度条
show_progress_bar() {
    local current=$1
    local total=$2
    local width=${3:-50}
    local label=${4:-"进度"}

    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    # 绘制进度条
    printf "\r${CYAN}%s:${NC} [" "$label"
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] ${YELLOW}%3d%%${NC}" "$percentage"

    # 完成时换行
    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# 显示旋转加载动画
show_spinner() {
    local pid=$1
    local message=${2:-"处理中"}
    local delay=0.1
    local spinstr='|/-\'

    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf "\r${CYAN}[${YELLOW}%c${CYAN}]${NC} %s..." "$spinstr" "$message"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\r${GREEN}[${STATUS_OK}]${NC} %s 完成\n" "$message"
}

# =============================================================================
# 菜单项显示
# =============================================================================

# 显示菜单项（带编号和图标）
show_menu_item() {
    local number=$1
    local icon=$2
    local title=$3
    local description=${4:-""}

    if [[ -n "$description" ]]; then
        printf " ${CYAN}%2s)${NC} ${icon} ${YELLOW}%-18s${NC} ${GRAY}%s${NC}\n" "$number" "$title" "$description"
    else
        printf " ${CYAN}%2s)${NC} ${icon} ${YELLOW}%s${NC}\n" "$number" "$title"
    fi
}

# 显示菜单分组标题
show_menu_section() {
    local title=$1
    shift
    local items=("$@")

    echo ""
    echo -e "${CYAN}${BOLD}▶ ${title}${NC}"
    echo ""

    for entry in "${items[@]}"; do
        local number icon label description
        IFS='|' read -r number icon label description <<< "$entry"
        show_menu_item "$number" "$icon" "$label" "$description"
    done
}

# 显示分组标题
show_menu_group() {
    local title=$1
    echo ""
    echo -e "${CYAN}┌─ ${BOLD}${title}${NC} ${CYAN}$(draw_line $((60 - ${#title})))${NC}"
}

# =============================================================================
# 增强的主菜单显示
# =============================================================================

# 显示增强版主菜单
show_enhanced_main_menu() {
    clear

    # 获取状态信息
    local service_status=$(get_service_status)
    local status_display
    if [[ "$service_status" == "running" ]]; then
        status_display="${GREEN}${STATUS_RUNNING} 运行中${NC}    "
    else
        status_display="${RED}${STATUS_STOPPED} 已停止${NC}    "
    fi

    local nodes_count=$(get_nodes_count)
    local users_count=$(get_users_count)
    local enabled_users=$(get_enabled_users_count)
    local bindings_count=$(get_bindings_count)

    # 获取内核版本（如果安装）
    local version="未安装"
    if [[ -x "$SINGBOX_BIN" ]]; then
        version=$($SINGBOX_BIN version 2>/dev/null | head -1 | awk '{print $3}' || echo "未知")
    fi

    # 标题栏
    echo -e "${CYAN}${DBOX_TL}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_TR}${NC}"
    echo -e "${CYAN}${DBOX_V}${NC}   ${YELLOW}sing-box 一键管理脚本 V2.0.0${NC}    ${CYAN}${DBOX_V}${NC}"
    echo -e "${CYAN}${DBOX_BL}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_H}${DBOX_BR}${NC}"
    echo ""

    # 系统状态区
    echo -e "${CYAN}${BOX_TL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_TR}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${YELLOW}系统状态${NC}                            ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_ML}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_MR}${NC}"
    printf "${CYAN}${BOX_V}${NC}  内核版本: ${YELLOW}%-22s${NC} ${CYAN}${BOX_V}${NC}\n" "$version"
    printf "${CYAN}${BOX_V}${NC}  运行状态: %-22s ${CYAN}${BOX_V}${NC}\n" "$status_display"
    printf "${CYAN}${BOX_V}${NC}  节点数量: ${BLUE}%-22s${NC} ${CYAN}${BOX_V}${NC}\n" "$nodes_count"
    printf "${CYAN}${BOX_V}${NC}  用户总数: ${BLUE}%-22s${NC} ${CYAN}${BOX_V}${NC}\n" "$users_count"
    printf "${CYAN}${BOX_V}${NC}  启用用户: ${GREEN}%-2s${NC}/${BLUE}%-18s${NC} ${CYAN}${BOX_V}${NC}\n" "$enabled_users" "$users_count"
    printf "${CYAN}${BOX_V}${NC}  绑定总数: ${BLUE}%-22s${NC} ${CYAN}${BOX_V}${NC}\n" "$bindings_count"
    echo -e "${CYAN}${BOX_BL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_BR}${NC}"
    echo ""

    # 功能菜单区
    echo -e "${CYAN}${BOX_TL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_TR}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${YELLOW}功能菜单${NC}                            ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_ML}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_MR}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}1.${NC}  节点管理                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}2.${NC}  用户管理                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}3.${NC}  绑定管理                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}4.${NC}  订阅管理                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}5.${NC}  配置管理                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}6.${NC}  内核管理                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}7.${NC}  出站规则                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}8.${NC}  域名管理                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}9.${NC}  证书管理                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}10.${NC} 防火墙管理                    ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_ML}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_MR}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}11.${NC} 服务控制                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}12.${NC} API 管理                      ${CYAN}${BOX_V}${NC}"
    if declare -f smart_tips_menu &>/dev/null; then
        echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}13.${NC} 智能提示                      ${CYAN}${BOX_V}${NC}"
    fi
    echo -e "${CYAN}${BOX_V}${NC}  ${GREEN}0.${NC}  退出脚本                      ${CYAN}${BOX_V}${NC}"
    echo -e "${CYAN}${BOX_BL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_BR}${NC}"
    echo ""
}

# =============================================================================
# 确认对话框
# =============================================================================

# 显示确认对话框
confirm_action() {
    local message=$1
    local default=${2:-n}

    local prompt
    if [[ "$default" == "y" ]]; then
        prompt="${message} ${CYAN}[Y/n]${NC}: "
    else
        prompt="${message} ${CYAN}[y/N]${NC}: "
    fi

    read -p "$(echo -e $prompt)" response
    response=${response:-$default}

    case "$response" in
        [Yy]|[Yy][Ee][Ss])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# =============================================================================
# 等待和暂停
# =============================================================================

# 等待用户按键继续
wait_for_key() {
    local message=${1:-"按回车键继续"}
    echo ""
    read -p "$(echo -e ${CYAN}${message}...${NC})"
}

# 倒计时显示
countdown() {
    local seconds=$1
    local message=${2:-"倒计时"}

    for ((i=seconds; i>0; i--)); do
        printf "\r${CYAN}%s:${NC} ${YELLOW}%d${NC} 秒..." "$message" "$i"
        sleep 1
    done
    printf "\r${GREEN}%s完成!${NC}\n" "$message"
}

# =============================================================================
# 模块初始化
# =============================================================================

# NOTE: 模块加载成功（主程序会验证函数存在性）
# 移除 log_debug 调用，避免在某些环境下导致加载失败
