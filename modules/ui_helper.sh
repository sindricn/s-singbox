#!/bin/bash

# =============================================================================
# ui_helper.sh - UI增强模块
# 提供美化的界面显示、状态信息、进度条等功能
# =============================================================================

# 依赖检查
if [[ -z "${SCRIPT_DIR}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# 加载依赖模块
if ! declare -f print_error &>/dev/null; then
    source "${SCRIPT_DIR}/modules/common.sh"
fi

# =============================================================================
# 颜色和样式定义
# =============================================================================

# 状态指示器
readonly STATUS_RUNNING="●"
readonly STATUS_STOPPED="○"
readonly STATUS_WARNING="▲"
readonly STATUS_ERROR="✖"
readonly STATUS_OK="✔"

# 框线字符
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

    # 显示标题
    draw_title_box "sing-box Manager v2.0" 68

    # 显示状态面板
    show_status_panel

    # 显示快捷工具（如果快速向导可用）
    if declare -f run_quick_wizard &>/dev/null; then
        show_menu_group "快捷工具"
        show_menu_item "Q" "🚀" "快速部署向导" "5分钟快速配置"
    fi

    # 显示菜单分组
    show_menu_group "核心管理"
    show_menu_item "1" "📦" "节点管理" "配置代理节点"
    show_menu_item "2" "👥" "用户管理" "管理用户账号"
    show_menu_item "3" "🔗" "绑定管理" "用户节点绑定"
    show_menu_item "4" "⚙️" "配置管理" "生成和管理配置"
    show_menu_item "5" "🚀" "服务控制" "启动/停止服务"

    show_menu_group "高级功能"
    show_menu_item "6" "🔐" "证书管理" "SSL/TLS证书"
    show_menu_item "7" "🌐" "域名管理" "域名配置和关联"
    show_menu_item "8" "📡" "订阅管理" "订阅链接管理"
    show_menu_item "9" "📊" "监控统计" "流量和性能监控"
    show_menu_item "10" "🛡️" "防火墙管理" "端口和规则配置"
    show_menu_item "11" "🔌" "API管理" "API接口配置"

    show_menu_group "系统工具"
    show_menu_item "12" "🔍" "查看状态" "服务运行状态"
    show_menu_item "13" "📋" "查看日志" "系统运行日志"
    show_menu_item "14" "💡" "智能提示" "系统健康检查"

    echo ""
    draw_separator 68
    show_menu_item "0" "🚪" "退出程序"
    echo ""
    draw_separator 68

    # 显示快捷提示
    show_quick_tips
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

log_debug "ui_helper.sh 模块已加载"
