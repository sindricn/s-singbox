#!/bin/bash

#================================================================
# sing-box Manager - 主入口脚本
# 功能：sing-box 服务管理工具
# 版本：V2.0.0 (重构版)
# 项目地址：https://github.com/yourusername/s-singbox
#================================================================

# 严格模式
set -uo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# 全局变量
readonly SINGBOX_DIR="/usr/local/singbox"
readonly SINGBOX_BIN="/usr/local/bin/sing-box"
readonly SINGBOX_CONFIG="${SINGBOX_DIR}/config.json"
readonly SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
readonly DATA_DIR="${SINGBOX_DIR}/data"
readonly USERS_FILE="${DATA_DIR}/users.json"
readonly NODES_FILE="${DATA_DIR}/nodes.json"
readonly NODE_USERS_FILE="${DATA_DIR}/node_users.json"
readonly SUBSCRIPTION_DIR="${DATA_DIR}/subscriptions"

# 日志配置
export LOG_FILE="/var/log/singbox-manager.log"
export LOG_LEVEL=${LOG_LEVEL:-1}  # 默认 INFO 级别

# 加载模块
source_modules() {
    # 解析真实脚本路径（处理软链接）
    local script_path="${BASH_SOURCE[0]}"

    # 如果是软链接，解析真实路径
    if [[ -L "$script_path" ]]; then
        script_path="$(readlink -f "$script_path")"
    fi

    local script_dir="$(cd "$(dirname "$script_path")" && pwd)"

    # 导出 MODULES_DIR 为全局变量
    export MODULES_DIR="${script_dir}/modules"

    if [[ ! -d "$MODULES_DIR" ]]; then
        echo -e "${RED}[ERROR]${NC} 模块目录不存在: $MODULES_DIR"
        echo -e "${RED}[ERROR]${NC} 脚本路径: $script_path"
        echo -e "${RED}[ERROR]${NC} 脚本目录: $script_dir"
        exit 1
    fi

    # 优先加载公共库
    if [[ -f "${MODULES_DIR}/common.sh" ]]; then
        source "${MODULES_DIR}/common.sh"
    else
        echo -e "${RED}[ERROR]${NC} 公共库不存在: ${MODULES_DIR}/common.sh"
        exit 1
    fi

    # 加载输入验证模块
    if [[ -f "${MODULES_DIR}/input-validation.sh" ]]; then
        source "${MODULES_DIR}/input-validation.sh"
    fi

    # 加载安全JSON模块
    if [[ -f "${MODULES_DIR}/safe_json.sh" ]]; then
        source "${MODULES_DIR}/safe_json.sh"
    fi

    # 加载其他模块
    for module in "${MODULES_DIR}"/*.sh; do
        if [[ -f "$module" ]] && \
           [[ "$module" != */common.sh ]] && \
           [[ "$module" != */input-validation.sh ]] && \
           [[ "$module" != */safe_json.sh ]]; then
            source "$module"
            log_debug "已加载模块: $(basename "$module")"
        fi
    done

    log_info "所有模块加载完成"
}

# 初始化数据目录 (使用xray的数据结构规范)
init_data_dir() {
    mkdir -p "$DATA_DIR"
    mkdir -p "$SUBSCRIPTION_DIR"

    # 核心数据文件初始化，缺失时写入空结构
    ensure_json_file "$USERS_FILE" '{"users":[]}'
    ensure_json_file "$NODES_FILE" '{"nodes":[]}'
    ensure_json_file "$NODE_USERS_FILE" '{"bindings":[]}'
    ensure_json_file "${DATA_DIR}/subscriptions.json" '{"subscriptions":[]}'
    ensure_json_file "${DATA_DIR}/subscription_metadata.json" '{"subscriptions":[]}'
    ensure_json_file "${DATA_DIR}/outbounds.json" '{"outbounds":[]}'
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
# 状态信息获取函数
# =============================================================================

# 获取 sing-box 状态信息
get_singbox_status() {
    local version="未安装"
    local status="${RED}未运行${NC}"

    if [[ -f "$SINGBOX_BIN" ]]; then
        version=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $3}')
        [[ -z "$version" ]] && version="unknown"

        if systemctl is-active --quiet sing-box; then
            status="${GREEN}运行中${NC}"
        else
            status="${RED}已停止${NC}"
        fi
    fi

    echo "$version|$status"
}

# 获取节点数量
get_nodes_count() {
    local count=0
    if [[ -f "${DATA_DIR}/nodes.json" ]]; then
        count=$(jq -r '.nodes | length' "${DATA_DIR}/nodes.json" 2>/dev/null || echo "0")
        if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
            count=0
        fi
    fi
    echo "$count"
}

# 获取用户数量
get_users_count() {
    local count=0
    if [[ -f "${DATA_DIR}/users.json" ]]; then
        count=$(jq -r '.users | length' "${DATA_DIR}/users.json" 2>/dev/null || echo "0")
        if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
            count=0
        fi
    fi
    echo "$count"
}

# 获取启用的用户数量
get_enabled_users_count() {
    local count=0
    if [[ -f "${DATA_DIR}/users.json" ]]; then
        count=$(jq -r '[.users[] | select(.enabled == true)] | length' "${DATA_DIR}/users.json" 2>/dev/null || echo "0")
        if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
            count=0
        fi
    fi
    echo "$count"
}

# 获取在线用户数量
get_online_users_count() {
    local online=0
    # TODO: 实现实际的在线用户统计逻辑
    # 暂时返回0
    echo "$online"
}

# =============================================================================
# 主菜单
# =============================================================================

show_main_menu() {
    clear

    # 获取状态信息
    local status_info=$(get_singbox_status)
    local version=$(echo "$status_info" | cut -d'|' -f1)
    local status=$(echo "$status_info" | cut -d'|' -f2)

    # 获取节点数量
    local node_count=$(get_nodes_count 2>/dev/null || echo "0")

    # 获取用户数量
    local user_count=$(get_users_count 2>/dev/null || echo "0")

    # 获取启用的用户数量
    local enabled_count=$(get_enabled_users_count 2>/dev/null || echo "0")

    # 获取在线用户数量
    local online_count=$(get_online_users_count 2>/dev/null || echo "0")

    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   sing-box Manager V2.0.0           ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}系统状态${NC}                           ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  内核版本: ${YELLOW}${version}${NC}"
    echo -e "${CYAN}│${NC}  运行状态: ${status}"
    echo -e "${CYAN}│${NC}  用户数量: ${BLUE}${user_count}${NC} ${CYAN}(启用:${NC} ${GREEN}${enabled_count}${NC}${CYAN})${NC}"
    echo -e "${CYAN}│${NC}  节点总数: ${BLUE}${node_count}${NC}"
    echo -e "${CYAN}│${NC}  在线用户: ${GREEN}${online_count}${NC}/${BLUE}${user_count}${NC}"
    echo -e "${CYAN}└─────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}功能菜单${NC}                           ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}1.${NC}  节点管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}2.${NC}  用户管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}3.${NC}  绑定管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}4.${NC}  订阅管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}5.${NC}  配置管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}6.${NC}  内核管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}7.${NC}  出站规则                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}8.${NC}  域名管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}9.${NC}  证书管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}10.${NC} 防火墙管理                     ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}11.${NC} 服务控制                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}12.${NC} API 管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}13.${NC} 智能提示                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}0.${NC}  退出脚本                       ${CYAN}│${NC}"
    echo -e "${CYAN}└─────────────────────────────────────┘${NC}"
    echo ""
}

# 节点管理菜单
show_node_menu() {
    clear

    local nodes_count=$(get_nodes_count 2>/dev/null || echo "0")

    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          节点管理                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}当前节点数:${NC} ${YELLOW}${nodes_count}${NC} 个"
    echo ""
    echo -e "${GREEN}1.${NC} 添加节点"
    echo -e "${GREEN}2.${NC} 删除节点"
    echo -e "${GREEN}3.${NC} 列出节点"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo ""
}

# 用户管理菜单
show_user_menu() {
    clear

    local users_count=$(get_users_count 2>/dev/null || echo "0")
    local enabled_count=$(get_enabled_users_count 2>/dev/null || echo "0")

    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          用户管理                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}当前用户数:${NC} ${YELLOW}${users_count}${NC} 个 ${CYAN}(启用:${NC} ${GREEN}${enabled_count}${NC}${CYAN})${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} 添加用户"
    echo -e "${GREEN}2.${NC} 删除用户"
    echo -e "${GREEN}3.${NC} 列出用户"
    echo -e "${GREEN}4.${NC} 修改用户"
    echo -e "${GREEN}5.${NC} 查看用户详情"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo ""
}

# 获取绑定数量
get_bindings_count() {
    local count=0
    if [[ -f "${DATA_DIR}/node_users.json" ]]; then
        count=$(jq -r '.bindings | length' "${DATA_DIR}/node_users.json" 2>/dev/null || echo "0")
        if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
            count=0
        fi
    fi
    echo "$count"
}

# 绑定管理菜单
show_binding_menu() {
    clear

    local bindings_count=$(get_bindings_count 2>/dev/null || echo "0")

    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          绑定管理                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}当前绑定数:${NC} ${YELLOW}${bindings_count}${NC} 个"
    echo ""
    echo -e "${GREEN}1.${NC} 绑定用户到节点"
    echo -e "${GREEN}2.${NC} 解绑用户与节点"
    echo -e "${GREEN}3.${NC} 批量绑定用户"
    echo -e "${GREEN}4.${NC} 列出所有绑定"
    echo -e "${GREEN}5.${NC} 列出用户的绑定"
    echo -e "${GREEN}6.${NC} 列出节点的用户"
    echo -e "${GREEN}7.${NC} 清理空绑定"
    echo -e "${GREEN}8.${NC} 验证绑定完整性"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo ""
}

# 配置管理菜单
show_config_menu() {
    clear

    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          配置管理                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} 生成配置"
    echo -e "${GREEN}2.${NC} 查看配置"
    echo -e "${GREEN}3.${NC} 验证配置"
    echo -e "${GREEN}4.${NC} 恢复备份"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo ""
}

# 获取服务状态显示
get_service_status_display() {
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}已停止${NC}"
    fi
}

# 服务控制菜单
show_service_menu() {
    clear

    local service_status=$(get_service_status_display 2>/dev/null || echo "未知")

    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          服务控制                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}服务状态:${NC} $service_status"
    echo ""
    echo -e "${GREEN}1.${NC} 启动服务"
    echo -e "${GREEN}2.${NC} 停止服务"
    echo -e "${GREEN}3.${NC} 重启服务"
    echo -e "${GREEN}4.${NC} 重载配置"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo ""
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
# 主程序
# =============================================================================

main() {
    # 先加载所有模块（必须在调用模块函数之前）
    source_modules

    # 检查 root 权限
    require_root

    # 初始化数据目录
    init_data_dir

    # 初始化默认admin用户
    init_admin_user

    log_info "sing-box 管理脚本启动 (V2.0.0)"

    # 主循环
    while true; do
        show_main_menu
        read -p "请选择操作: " choice

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
