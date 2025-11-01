#!/bin/bash

# =============================================================================
# sing-box Manager - 主入口脚本
# sing-box 服务管理工具
# =============================================================================

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# 数据目录
DATA_DIR="${SCRIPT_DIR}/data"
MODULES_DIR="${SCRIPT_DIR}/modules"

# 配置文件
SINGBOX_CONFIG_DIR="/usr/local/singbox"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config.json"
SINGBOX_BINARY="/usr/local/bin/sing-box"

# =============================================================================
# 加载公共库模块（最高优先级）
# =============================================================================

# 加载 common.sh（日志系统、工具函数）
if [[ -f "${MODULES_DIR}/common.sh" ]]; then
    source "${MODULES_DIR}/common.sh"
else
    # 如果 common.sh 不存在，使用基础打印函数
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
    print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    print_header() {
        echo ""
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}  $1${NC}"
        echo -e "${GREEN}======================================${NC}"
        echo ""
    }

    # 日志函数（备用版本，仅输出到控制台）
    log_error() { print_error "$1"; }
    log_success() { print_success "$1"; }
    log_warn() { print_warn "$1"; }
    log_info() { print_info "$1"; }
    log_debug() { : ; }  # 空操作

    print_error "找不到 common.sh 模块: ${MODULES_DIR}/common.sh"
    print_warn "使用备用打印函数，部分功能可能不可用"
fi

# 加载核心增强模块（UI、输入验证、安全JSON）
[[ -f "${MODULES_DIR}/input-validation.sh" ]] && source "${MODULES_DIR}/input-validation.sh"
[[ -f "${MODULES_DIR}/safe_json.sh" ]] && source "${MODULES_DIR}/safe_json.sh"
[[ -f "${MODULES_DIR}/ui_helper.sh" ]] && source "${MODULES_DIR}/ui_helper.sh"
[[ -f "${MODULES_DIR}/smart_tips.sh" ]] && source "${MODULES_DIR}/smart_tips.sh"
[[ -f "${MODULES_DIR}/quick_wizard.sh" ]] && source "${MODULES_DIR}/quick_wizard.sh"

# =============================================================================
# 环境检查
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()

    # 检查必需的命令
    for cmd in jq systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "缺少必需的依赖: ${missing_deps[*]}"
        print_info "请安装后重试"
        exit 1
    fi
}

check_data_files() {
    # 检查数据目录
    if [[ ! -d "$DATA_DIR" ]]; then
        print_warn "数据目录不存在，正在创建..."
        mkdir -p "$DATA_DIR"
    fi

    # 检查并初始化数据文件
    if [[ ! -f "${DATA_DIR}/users.json" ]]; then
        print_warn "users.json 不存在，正在初始化..."
        init_users_file
    fi

    if [[ ! -f "${DATA_DIR}/nodes.json" ]]; then
        print_warn "nodes.json 不存在，正在初始化..."
        init_nodes_file
    fi

    if [[ ! -f "${DATA_DIR}/node_users.json" ]]; then
        print_warn "node_users.json 不存在，正在初始化..."
        init_bindings_file
    fi
}

# =============================================================================
# 数据文件初始化
# =============================================================================

init_users_file() {
    # 生成 admin 用户的 UUID 和密码
    local admin_uuid=$(generate_uuid)
    local admin_password=$(generate_random_password 16)
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "${DATA_DIR}/users.json" <<EOF
{
  "users": [
    {
      "id": "$admin_uuid",
      "username": "admin",
      "email": "admin@local",
      "password": "$admin_password",
      "level": 0,
      "enabled": true,
      "created_at": "$timestamp",
      "traffic_limit": 0,
      "expire_time": ""
    }
  ]
}
EOF

    print_success "users.json 初始化完成"
    print_info "admin 用户已创建"
    print_warn "admin 密码: $admin_password (请妥善保存)"
}

init_nodes_file() {
    cat > "${DATA_DIR}/nodes.json" <<EOF
{
  "nodes": []
}
EOF

    print_success "nodes.json 初始化完成"
}

init_bindings_file() {
    cat > "${DATA_DIR}/node_users.json" <<EOF
{
  "bindings": []
}
EOF

    print_success "node_users.json 初始化完成"
}

# =============================================================================
# UUID 和密码生成
# =============================================================================

generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || \
        echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 8 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-4$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 3 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 12 | head -n 1)"
    fi
}

generate_random_password() {
    local length=${1:-16}
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "$length"
}

# =============================================================================
# sing-box 服务控制
# =============================================================================

start_singbox() {
    print_info "启动 sing-box 服务..."

    if ! systemctl is-active --quiet sing-box; then
        systemctl start sing-box

        if systemctl is-active --quiet sing-box; then
            print_success "sing-box 服务已启动"
        else
            print_error "sing-box 服务启动失败"
            print_info "查看日志: journalctl -u sing-box -n 50"
            return 1
        fi
    else
        print_warn "sing-box 服务已在运行"
    fi
}

stop_singbox() {
    print_info "停止 sing-box 服务..."

    if systemctl is-active --quiet sing-box; then
        systemctl stop sing-box

        if ! systemctl is-active --quiet sing-box; then
            print_success "sing-box 服务已停止"
        else
            print_error "sing-box 服务停止失败"
            return 1
        fi
    else
        print_warn "sing-box 服务未运行"
    fi
}

restart_singbox() {
    print_info "重启 sing-box 服务..."

    systemctl restart sing-box

    if systemctl is-active --quiet sing-box; then
        print_success "sing-box 服务已重启"
    else
        print_error "sing-box 服务重启失败"
        print_info "查看日志: journalctl -u sing-box -n 50"
        return 1
    fi
}

reload_singbox() {
    print_info "重载 sing-box 配置..."

    if systemctl is-active --quiet sing-box; then
        systemctl reload sing-box

        if [[ $? -eq 0 ]]; then
            print_success "sing-box 配置已重载"
        else
            print_error "sing-box 配置重载失败"
            return 1
        fi
    else
        print_warn "sing-box 服务未运行，无法重载"
        return 1
    fi
}

status_singbox() {
    print_info "sing-box 服务状态:"
    systemctl status sing-box --no-pager
}

view_logs() {
    print_info "sing-box 服务日志 (最近 50 行):"
    journalctl -u sing-box -n 50 --no-pager
}

# =============================================================================
# 主菜单
# =============================================================================

show_main_menu() {
    clear
    print_header "sing-box Manager V2.0.0"

    echo "【功能菜单】"
    echo "1)  节点管理"
    echo "2)  用户管理"
    echo "3)  绑定管理"
    echo "4)  订阅管理"
    echo "5)  配置管理"
    echo "6)  内核管理"
    echo "7)  出站规则"
    echo "8)  域名管理"
    echo "9)  证书管理"
    echo "10) 防火墙管理"
    echo ""
    echo "【系统工具】"
    echo "11) 服务控制"
    echo "12) API 管理"
    echo "13) 智能提示"
    echo ""
    echo "0)  退出脚本"
    echo ""
}

# 节点管理菜单
show_node_menu() {
    clear

    # 使用增强UI（如果可用）
    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "节点管理" 68
        local nodes_count=$(get_nodes_count 2>/dev/null || echo "0")
        echo -e "${CYAN}当前节点数:${NC} ${YELLOW}${nodes_count}${NC} 个"
        echo ""
        if declare -f show_menu_item &>/dev/null; then
            show_menu_item "1" "➕" "添加节点" "配置新的代理节点"
            show_menu_item "2" "🗑️" "删除节点" "移除现有节点"
            show_menu_item "3" "📋" "列出节点" "查看所有节点"
            echo ""
            draw_separator 68
            show_menu_item "0" "↩️" "返回主菜单"
            echo ""
        else
            echo "1)  添加节点"
            echo "2)  删除节点"
            echo "3)  列出节点"
            echo ""
            echo "0)  返回主菜单"
            echo ""
        fi
    else
        print_header "节点管理"
        echo "1)  添加节点"
        echo "2)  删除节点"
        echo "3)  列出节点"
        echo ""
        echo "0)  返回主菜单"
        echo ""
    fi
}

# 用户管理菜单
show_user_menu() {
    clear

    # 使用增强UI（如果可用）
    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "用户管理" 68
        local users_count=$(get_users_count 2>/dev/null || echo "0")
        local enabled_count=$(get_enabled_users_count 2>/dev/null || echo "0")
        echo -e "${CYAN}当前用户数:${NC} ${YELLOW}${users_count}${NC} 个 ${CYAN}(启用:${NC} ${GREEN}${enabled_count}${NC}${CYAN})${NC}"
        echo ""
        if declare -f show_menu_item &>/dev/null; then
            show_menu_item "1" "👤" "添加用户" "创建新用户账号"
            show_menu_item "2" "🗑️" "删除用户" "移除用户账号"
            show_menu_item "3" "📋" "列出用户" "查看所有用户"
            show_menu_item "4" "✏️" "修改用户" "编辑用户信息"
            show_menu_item "5" "🔍" "查看用户详情" "查看完整信息"
            echo ""
            draw_separator 68
            show_menu_item "0" "↩️" "返回主菜单"
            echo ""
        else
            echo "1)  添加用户"
            echo "2)  删除用户"
            echo "3)  列出用户"
            echo "4)  修改用户"
            echo "5)  查看用户详情"
            echo ""
            echo "0)  返回主菜单"
            echo ""
        fi
    else
        print_header "用户管理"
        echo "1)  添加用户"
        echo "2)  删除用户"
        echo "3)  列出用户"
        echo "4)  修改用户"
        echo "5)  查看用户详情"
        echo ""
        echo "0)  返回主菜单"
        echo ""
    fi
}

# 绑定管理菜单
show_binding_menu() {
    clear

    # 使用增强UI（如果可用）
    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "绑定管理" 68
        local bindings_count=$(get_bindings_count 2>/dev/null || echo "0")
        echo -e "${CYAN}当前绑定数:${NC} ${YELLOW}${bindings_count}${NC} 个"
        echo ""
        if declare -f show_menu_item &>/dev/null; then
            show_menu_item "1" "🔗" "绑定用户到节点"
            show_menu_item "2" "🔓" "解绑用户与节点"
            show_menu_item "3" "📦" "批量绑定用户"
            show_menu_item "4" "📋" "列出所有绑定"
            show_menu_item "5" "👤" "列出用户的绑定"
            show_menu_item "6" "📡" "列出节点的用户"
            show_menu_item "7" "🧹" "清理空绑定"
            show_menu_item "8" "✔️" "验证绑定完整性"
            echo ""
            draw_separator 68
            show_menu_item "0" "↩️" "返回主菜单"
            echo ""
        else
            echo "1)  绑定用户到节点"
            echo "2)  解绑用户与节点"
            echo "3)  批量绑定用户"
            echo "4)  列出所有绑定"
            echo "5)  列出用户的绑定"
            echo "6)  列出节点的用户"
            echo "7)  清理空绑定"
            echo "8)  验证绑定完整性"
            echo ""
            echo "0)  返回主菜单"
            echo ""
        fi
    else
        print_header "绑定管理"
        echo "1)  绑定用户到节点"
        echo "2)  解绑用户与节点"
        echo "3)  批量绑定用户"
        echo "4)  列出所有绑定"
        echo "5)  列出用户的绑定"
        echo "6)  列出节点的用户"
        echo "7)  清理空绑定"
        echo "8)  验证绑定完整性"
        echo ""
        echo "0)  返回主菜单"
        echo ""
    fi
}

# 配置管理菜单
show_config_menu() {
    clear

    # 使用增强UI（如果可用）
    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "配置管理" 68
        echo ""
        if declare -f show_menu_item &>/dev/null; then
            show_menu_item "1" "⚙️" "生成配置" "根据节点和用户生成"
            show_menu_item "2" "📄" "查看配置" "查看当前配置文件"
            show_menu_item "3" "✔️" "验证配置" "检查配置有效性"
            show_menu_item "4" "💾" "恢复备份" "从备份恢复配置"
            echo ""
            draw_separator 68
            show_menu_item "0" "↩️" "返回主菜单"
            echo ""
        else
            echo "1)  生成配置"
            echo "2)  查看配置"
            echo "3)  验证配置"
            echo "4)  恢复备份"
            echo ""
            echo "0)  返回主菜单"
            echo ""
        fi
    else
        print_header "配置管理"
        echo "1)  生成配置"
        echo "2)  查看配置"
        echo "3)  验证配置"
        echo "4)  恢复备份"
        echo ""
        echo "0)  返回主菜单"
        echo ""
    fi
}

# 服务控制菜单
show_service_menu() {
    clear

    # 使用增强UI（如果可用）
    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "服务控制" 68
        local service_status=$(get_service_status_display 2>/dev/null || echo "未知")
        echo -e "${CYAN}服务状态:${NC} $service_status"
        echo ""
        if declare -f show_menu_item &>/dev/null; then
            show_menu_item "1" "▶️" "启动服务" "启动 sing-box"
            show_menu_item "2" "⏹️" "停止服务" "停止 sing-box"
            show_menu_item "3" "🔄" "重启服务" "重启 sing-box"
            show_menu_item "4" "♻️" "重载配置" "重新加载配置文件"
            echo ""
            draw_separator 68
            show_menu_item "0" "↩️" "返回主菜单"
            echo ""
        else
            echo "1)  启动服务"
            echo "2)  停止服务"
            echo "3)  重启服务"
            echo "4)  重载配置"
            echo ""
            echo "0)  返回主菜单"
            echo ""
        fi
    else
        print_header "服务控制"
        echo "1)  启动服务"
        echo "2)  停止服务"
        echo "3)  重启服务"
        echo "4)  重载配置"
        echo ""
        echo "0)  返回主菜单"
        echo ""
    fi
}

# =============================================================================
# 菜单处理函数
# =============================================================================

handle_node_menu() {
    while true; do
        show_node_menu
        read -p "请选择: " choice

        case "$choice" in
            1)
                source "${MODULES_DIR}/node.sh"
                add_node
                read -p "按回车键继续..."
                ;;
            2)
                source "${MODULES_DIR}/node.sh"
                delete_node
                read -p "按回车键继续..."
                ;;
            3)
                source "${MODULES_DIR}/node.sh"
                list_nodes
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

handle_user_menu() {
    while true; do
        show_user_menu
        read -p "请选择: " choice

        case "$choice" in
            1)
                source "${MODULES_DIR}/user.sh"
                add_user
                read -p "按回车键继续..."
                ;;
            2)
                source "${MODULES_DIR}/user.sh"
                delete_user
                read -p "按回车键继续..."
                ;;
            3)
                source "${MODULES_DIR}/user.sh"
                list_users
                read -p "按回车键继续..."
                ;;
            4)
                source "${MODULES_DIR}/user.sh"
                modify_user
                read -p "按回车键继续..."
                ;;
            5)
                source "${MODULES_DIR}/user.sh"
                show_user_info
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

handle_binding_menu() {
    while true; do
        show_binding_menu
        read -p "请选择: " choice

        case "$choice" in
            1)
                source "${MODULES_DIR}/user_node_binding.sh"
                bind_user_to_node
                read -p "按回车键继续..."
                ;;
            2)
                source "${MODULES_DIR}/user_node_binding.sh"
                unbind_user_from_node
                read -p "按回车键继续..."
                ;;
            3)
                source "${MODULES_DIR}/user_node_binding.sh"
                batch_bind_users
                read -p "按回车键继续..."
                ;;
            4)
                source "${MODULES_DIR}/user_node_binding.sh"
                list_all_bindings
                read -p "按回车键继续..."
                ;;
            5)
                source "${MODULES_DIR}/user_node_binding.sh"
                list_user_bindings
                read -p "按回车键继续..."
                ;;
            6)
                source "${MODULES_DIR}/user_node_binding.sh"
                list_node_users
                read -p "按回车键继续..."
                ;;
            7)
                source "${MODULES_DIR}/user_node_binding.sh"
                cleanup_empty_bindings
                read -p "按回车键继续..."
                ;;
            8)
                source "${MODULES_DIR}/user_node_binding.sh"
                validate_bindings
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

handle_config_menu() {
    while true; do
        show_config_menu
        read -p "请选择: " choice

        case "$choice" in
            1)
                source "${MODULES_DIR}/config_generator.sh"
                generate_singbox_config
                read -p "按回车键继续..."
                ;;
            2)
                source "${MODULES_DIR}/config_generator.sh"
                show_current_config
                read -p "按回车键继续..."
                ;;
            3)
                if [[ -f "$SINGBOX_CONFIG_FILE" ]] && command -v sing-box &>/dev/null; then
                    print_info "验证配置文件..."
                    if sing-box check -c "$SINGBOX_CONFIG_FILE"; then
                        print_success "配置文件验证通过"
                    else
                        print_error "配置文件验证失败"
                    fi
                else
                    print_error "配置文件不存在或 sing-box 未安装"
                fi
                read -p "按回车键继续..."
                ;;
            4)
                source "${MODULES_DIR}/config_generator.sh"
                restore_config_backup
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

handle_service_menu() {
    while true; do
        show_service_menu
        read -p "请选择: " choice

        case "$choice" in
            1)
                start_singbox
                read -p "按回车键继续..."
                ;;
            2)
                stop_singbox
                read -p "按回车键继续..."
                ;;
            3)
                restart_singbox
                read -p "按回车键继续..."
                ;;
            4)
                reload_singbox
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# 模块加载（优先级加载）
# =============================================================================

load_modules() {
    log_info "加载系统模块..."

    # 第一优先级：基础模块（已在顶部加载 common.sh）
    # common.sh 已在文件开头加载

    # 第二优先级：安全和验证模块
    local priority_modules=(
        "input-validation.sh"
        "safe_json.sh"
    )

    for module in "${priority_modules[@]}"; do
        if [[ -f "${MODULES_DIR}/${module}" ]]; then
            source "${MODULES_DIR}/${module}"
            log_debug "已加载: $module"
        else
            log_warn "模块不存在: $module"
        fi
    done

    # 第三优先级：选择器模块
    if [[ -f "${MODULES_DIR}/selector.sh" ]]; then
        source "${MODULES_DIR}/selector.sh"
        log_debug "已加载: selector.sh"
    fi

    # UI增强模块
    if [[ -f "${MODULES_DIR}/ui_helper.sh" ]]; then
        source "${MODULES_DIR}/ui_helper.sh"
        log_debug "已加载: ui_helper.sh"
    fi

    # 快速部署向导模块
    if [[ -f "${MODULES_DIR}/quick_wizard.sh" ]]; then
        source "${MODULES_DIR}/quick_wizard.sh"
        log_debug "已加载: quick_wizard.sh"
    fi

    # 智能提示系统模块
    if [[ -f "${MODULES_DIR}/smart_tips.sh" ]]; then
        source "${MODULES_DIR}/smart_tips.sh"
        log_debug "已加载: smart_tips.sh"
    fi

    # 第四优先级：业务模块
    local business_modules=(
        "core.sh"
        "node.sh"
        "user.sh"
        "user_node_binding.sh"
        "config_generator.sh"
        "subscription.sh"
        "outbound.sh"
        "domain.sh"
        "cert.sh"
        "firewall.sh"
        "monitor.sh"
        "singbox_api.sh"
        "config.sh"
    )

    for module in "${business_modules[@]}"; do
        if [[ -f "${MODULES_DIR}/${module}" ]]; then
            source "${MODULES_DIR}/${module}"
            log_debug "已加载: $module"
        else
            log_warn "模块不存在: $module"
        fi
    done

    log_success "模块加载完成"
}

# =============================================================================
# 主程序
# =============================================================================

main() {
    # 检查 root 权限
    check_root

    # 检查依赖
    check_dependencies

    # 加载所有模块（优先级加载）
    load_modules

    # 检查数据文件
    check_data_files

    # 主循环
    while true; do
        # 使用增强版主菜单（如果ui_helper模块已加载）
        if declare -f show_enhanced_main_menu &>/dev/null; then
            show_enhanced_main_menu
        else
            show_main_menu
        fi
        read -p "$(echo -e ${CYAN}请选择${NC}: )" choice

        case "$choice" in
            1)
                # 节点管理
                handle_node_menu
                ;;
            2)
                # 用户管理
                handle_user_menu
                ;;
            3)
                # 绑定管理
                handle_binding_menu
                ;;
            4)
                # 订阅管理
                if declare -f subscription_menu &>/dev/null; then
                    subscription_menu
                else
                    source "${MODULES_DIR}/subscription.sh"
                    subscription_menu
                fi
                ;;
            5)
                # 配置管理
                handle_config_menu
                ;;
            6)
                # 内核管理
                if declare -f core_management_menu &>/dev/null; then
                    core_management_menu
                else
                    source "${MODULES_DIR}/core.sh"
                    core_management_menu
                fi
                ;;
            7)
                # 出站规则
                if declare -f outbound_menu &>/dev/null; then
                    outbound_menu
                else
                    source "${MODULES_DIR}/outbound.sh"
                    outbound_menu
                fi
                ;;
            8)
                # 域名管理
                if declare -f domain_menu &>/dev/null; then
                    domain_menu
                else
                    source "${MODULES_DIR}/domain.sh"
                    domain_menu
                fi
                ;;
            9)
                # 证书管理
                if declare -f cert_management_menu &>/dev/null; then
                    cert_management_menu
                else
                    source "${MODULES_DIR}/cert.sh"
                    cert_management_menu
                fi
                ;;
            10)
                # 防火墙管理
                if declare -f firewall_menu &>/dev/null; then
                    firewall_menu
                else
                    source "${MODULES_DIR}/firewall.sh"
                    firewall_menu
                fi
                ;;
            11)
                # 服务控制
                handle_service_menu
                ;;
            12)
                # API 管理
                if declare -f api_menu &>/dev/null; then
                    api_menu
                else
                    source "${MODULES_DIR}/singbox_api.sh"
                    api_menu
                fi
                ;;
            13)
                # 智能提示
                if declare -f smart_tips_menu &>/dev/null; then
                    smart_tips_menu
                else
                    print_error "智能提示系统模块未加载"
                    sleep 2
                fi
                ;;
            0)
                print_info "退出程序"
                exit 0
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 运行主程序
main
