#!/bin/bash

#================================================================
# sing-box Manager - 主入口脚本
# 功能：sing-box 服务管理工具
# 版本：V1.0.0
# 项目地址：https://github.com/sindricn/s-singbox
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

# 全局变量（使用官方标准路径）
# 官方标准路径参考: https://sing-box.sagernet.org/
readonly SINGBOX_DIR="/etc/sing-box"                    # 配置目录（官方标准）
readonly SINGBOX_CONFIG="${SINGBOX_DIR}/config.json"   # 配置文件（官方标准）
readonly SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
readonly DATA_DIR="/var/lib/sing-box"                  # 数据目录（官方标准）
readonly USERS_FILE="${DATA_DIR}/users.json"
readonly NODES_FILE="${DATA_DIR}/nodes.json"
readonly NODE_USERS_FILE="${DATA_DIR}/node_users.json"
readonly SUBSCRIPTION_DIR="${DATA_DIR}/subscriptions"

# 动态查找 sing-box 二进制文件位置
# 优先使用系统中实际安装的位置，而不是固定路径
if command -v sing-box &>/dev/null; then
    # sing-box 已安装，获取实际路径
    readonly SINGBOX_BIN="$(command -v sing-box)"
else
    # 未安装，使用默认路径（用于安装过程）
    readonly SINGBOX_BIN="/usr/local/bin/sing-box"
fi

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
        fi
    done

    log_info "所有模块加载完成"
}

# 初始化数据目录 (数据结构规范)
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
        print_warning "sing-box 服务已在运行"
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
        print_warning "sing-box 服务未运行"
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
        print_warning "sing-box 服务未运行，无法重载"
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

    # 动态查找 sing-box 二进制位置（而不是只检查固定路径）
    if command -v sing-box &>/dev/null; then
        # 获取版本信息
        version=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}')
        [[ -z "$version" ]] && version="unknown"

        # 检查服务运行状态
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
    # 注: 在线用户统计需要实际运行环境和数据支持
    # 开发环境暂时返回0
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
    local node_count=$(get_nodes_count 2>/dev/null || echo "0")
    local user_count=$(get_users_count 2>/dev/null || echo "0")
    local online_count=$(get_online_users_count 2>/dev/null || echo "0")

    # 使用统一的UI函数
    print_header "s-singbox 一键管理脚本 V1.0.0"
    echo ""

    print_section_start
    print_menu_info "  ${YELLOW}系统状态${NC}" ""
    print_divider
    print_menu_info "  内核版本" "${YELLOW}${version}${NC}"
    print_menu_info "  运行状态" "${status}"
    print_menu_info "  用户数量" "${BLUE}${user_count}${NC}"
    print_menu_info "  节点总数" "${BLUE}${node_count}${NC}"
    print_menu_info "  在线用户" "${GREEN}${online_count}${NC}/${BLUE}${user_count}${NC}"
    print_section_end
    echo ""

    print_section_start
    print_menu_info "  ${YELLOW}功能菜单${NC}" ""
    print_divider
    print_menu_item "1" "sing-box 管理"
    print_menu_item "2" "用户管理"
    print_menu_item "3" "节点管理"
    print_menu_item "4" "订阅管理"
    print_menu_item "5" "域名管理"
    print_menu_item "6" "证书管理"
    print_menu_item "7" "出站规则"
    print_menu_item "8" "防火墙管理"
    print_divider
    print_menu_item "9" "CF 隧道管理" " ${YELLOW}[NEW]${NC}"
    print_menu_item "10" "BBR 加速管理" " ${YELLOW}[NEW]${NC}"
    print_divider
    print_menu_item "11" "脚本管理"
    print_menu_item "12" "关于脚本"
    print_section_end

    print_nav_options "false" "false"
    echo ""
}

# sing-box 管理菜单
menu_core() {
    while true; do
        clear
        print_header "sing-box 管理"
        echo ""

        print_section_start
        print_menu_item "1" "安装 sing-box"
        print_menu_item "2" "启动 sing-box"
        print_menu_item "3" "停止 sing-box"
        print_menu_item "4" "重启 sing-box"
        print_menu_item "5" "卸载 sing-box"
        print_menu_item "6" "更新 sing-box"
        print_menu_item "7" "查看日志"
        print_menu_item "8" "查看版本"
        echo ""
        print_menu_info "  ${YELLOW}数据管理${NC}" ""
        print_menu_item "9" "重置用户数据" " ${GRAY}(保留节点)${NC}"
        print_menu_item "10" "重置节点数据" " ${GRAY}(保留用户)${NC}"
        print_menu_item "11" "重置所有数据" " ${RED}(删除所有)${NC}"
        echo ""
        print_menu_info "  ${YELLOW}配置查看${NC}" ""
        print_menu_item "12" "查看配置信息"
        print_section_end

        print_nav_options "false" "true"
        choice=$(read_menu_choice "请选择操作 [0-12]")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case $choice in
            1) install_sing-box; wait_for_input ;;
            2) start_sing-box; wait_for_input ;;
            3) stop_sing-box; wait_for_input ;;
            4) restart_sing-box; wait_for_input ;;
            5) uninstall_sing-box; wait_for_input ;;
            6) update_sing-box; wait_for_input ;;
            7)
                # 查看日志
                clear
                print_header "sing-box 日志"
                echo ""
                print_menu_item "1" "实时日志(最新50行)"
                print_menu_item "2" "完整日志"
                print_menu_item "3" "错误日志"
                echo ""
                print_nav_options "true" "true"

                log_choice=$(read_menu_choice "请选择 [0-3]")
                case $log_choice in
                    1) echo ""; echo -e "${CYAN}实时日志(Ctrl+C退出):${NC}"; echo ""; journalctl -u sing-box -f -n 50 ;;
                    2) echo ""; echo -e "${CYAN}完整日志:${NC}"; echo ""; journalctl -u sing-box --no-pager | less ;;
                    3) echo ""; echo -e "${CYAN}错误日志:${NC}"; echo ""; journalctl -u sing-box -p err --no-pager | less ;;
                    0) ;;
                    *) print_error "无效选择" ;;
                esac
                wait_for_input
                ;;
            8) show_version; wait_for_input ;;
            9)
                if declare -f reset_users &>/dev/null; then
                    reset_users
                else
                    print_error "reset_users 函数未加载"
                fi
                wait_for_input
                ;;
            10)
                if declare -f reset_nodes &>/dev/null; then
                    reset_nodes
                else
                    print_error "reset_nodes 函数未加载"
                fi
                wait_for_input
                ;;
            11)
                if declare -f reset_all_data &>/dev/null; then
                    reset_all_data
                else
                    print_error "reset_all_data 函数未加载"
                fi
                wait_for_input
                ;;
            12)
                # 查看配置信息
                clear
                print_header "sing-box 配置信息"
                echo ""
                if [[ -f "$SINGBOX_CONFIG" ]]; then
                    echo -e "${YELLOW}配置文件路径:${NC} $SINGBOX_CONFIG"
                    echo ""
                    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                    cat "$SINGBOX_CONFIG" | jq '.' 2>/dev/null || cat "$SINGBOX_CONFIG"
                    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                else
                    print_error "配置文件不存在: $SINGBOX_CONFIG"
                fi
                wait_for_input
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 节点管理菜单
show_node_menu() {
    clear
    local nodes_count=$(get_nodes_count 2>/dev/null || echo "0")

    print_header "节点管理"
    echo ""
    print_section_start
    print_menu_info "  当前节点数" "${YELLOW}${nodes_count}${NC} 个"
    print_divider
    print_menu_item "1" "添加节点"
    print_menu_item "2" "删除节点"
    print_menu_item "3" "查看节点"
    print_menu_item "4" "修改节点"
    print_section_end
    print_nav_options "false" "true"
}

# 用户管理菜单
show_user_menu() {
    clear
    local users_count=$(get_users_count 2>/dev/null || echo "0")
    local enabled_count=$(get_enabled_users_count 2>/dev/null || echo "0")

    print_header "用户管理"
    echo ""
    print_section_start
    print_menu_info "  当前用户数" "${YELLOW}${users_count}${NC} 个 ${CYAN}(启用: ${GREEN}${enabled_count}${NC}${CYAN})${NC}"
    print_divider
    print_menu_item "1" "查看用户"
    print_menu_item "2" "添加用户"
    print_menu_item "3" "修改用户"
    print_menu_item "4" "删除用户"
    print_section_end
    print_nav_options "false" "true"
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

    print_header "绑定管理"
    echo ""
    print_section_start
    print_menu_info "  当前绑定数" "${YELLOW}${bindings_count}${NC} 个"
    print_divider
    print_menu_item "1" "绑定用户到节点"
    print_menu_item "2" "解绑用户与节点"
    print_menu_item "3" "批量绑定用户"
    print_menu_item "4" "列出所有绑定"
    print_menu_item "5" "列出用户的绑定"
    print_menu_item "6" "列出节点的用户"
    print_menu_item "7" "清理空绑定"
    print_menu_item "8" "验证绑定完整性"
    print_section_end
    print_nav_options "false" "true"
}

# 配置管理菜单（已废弃，功能移至singbox管理）
show_config_menu() {
    clear

    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          配置管理"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} 生成配置"
    echo -e "${GREEN}2.${NC} 查看配置"
    echo -e "${GREEN}3.${NC} 验证配置"
    echo -e "${GREEN}4.${NC} 恢复备份"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo ""
    echo -e "${YELLOW}提示: 配置重置功能已移至【sing-box管理】菜单${NC}"
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
    echo -e "${CYAN}║${NC}          服务控制"
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
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case "$choice" in
            1)
                menu_node_add
                [[ $? -eq 98 ]] && return  # 传播返回主菜单
                ;;
            2) delete_node; wait_for_input ;;
            3)
                # 合并列出节点和查看节点详情
                list_nodes true
                echo ""
                read -p "请输入要查看的节点序号 (直接按Enter返回): " node_idx
                if [[ -n "$node_idx" && "$node_idx" != "0" ]]; then
                    local port=$(get_node_port_by_index "$node_idx")
                    if [[ -n "$port" && "$port" != "null" ]]; then
                        show_node_detail "$port"
                    else
                        print_error "无效的节点序号"
                    fi
                fi
                wait_for_input
                ;;
            4) modify_node_config; wait_for_input ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 添加节点菜单（协议选择）
menu_node_add() {
    while true; do
        clear
        print_header "添加节点"
        echo ""

        print_section_start
        print_menu_info "  ${YELLOW}🚀 快速搭建（推荐）${NC}" ""
        print_menu_item "Q" "快速搭建" " - 一键配置常用节点"
        print_divider
        print_menu_info "  ${YELLOW}主流代理协议${NC}" ""
        print_menu_item "1" "VLESS" " - 通用代理（支持 XTLS）"
        print_menu_item "2" "VMess" " - V2Ray 经典协议"
        print_menu_item "3" "Trojan" " - TLS 伪装代理"
        print_menu_item "4" "Shadowsocks" " - 轻量级代理"
        print_divider
        print_menu_info "  ${YELLOW}高性能协议${NC}" ""
        print_menu_item "5" "Hysteria2" " - 基于 QUIC 高性能（推荐）"
        print_menu_item "6" "TUIC" " - QUIC 协议代理"
        print_divider
        print_menu_info "  ${YELLOW}抗审查/本地代理${NC}" ""
        print_menu_item "7" "Naive" " - 强抗审查代理"
        print_menu_item "8" "Mixed" " - HTTP + SOCKS5 混合"
        print_menu_item "9" "HTTP" " - HTTP 代理"
        print_menu_item "10" "SOCKS" " - SOCKS5 代理"
        print_menu_item "11" "AnyTLS" " - 流量填充混淆（sing-box 1.12.0+）"
        print_section_end

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择协议")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return 0  # 返回上级
        [[ $ret -eq 98 ]] && return 98  # 返回主菜单

        case $choice in
            q|Q)
                menu_quick_setup
                [[ $? -eq 98 ]] && return 98  # 传播返回主菜单
                ;;
            1) add_vless_node ;;
            2) add_vmess_node ;;
            3) add_trojan_node ;;
            4) add_shadowsocks_node ;;
            5) add_hysteria2_node ;;
            6) add_tuic_node ;;
            7) add_naive_node ;;
            8) add_mixed_node ;;
            9) add_http_inbound_node ;;
            10) add_socks_inbound_node ;;
            11) add_anytls_node ;;
            *) print_error "无效选择" ;;
        esac

        read -p "按 Enter 键继续..."
    done
}

handle_user_menu() {
    while true; do
        show_user_menu
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case "$choice" in
            1)
                view_users_menu
                [[ $? -eq 98 ]] && return  # 传播返回主菜单
                ;;
            2) add_global_user; wait_for_input ;;
            3)
                modify_user_menu
                [[ $? -eq 98 ]] && return  # 传播返回主菜单
                ;;
            4) delete_users_batch; wait_for_input ;;
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
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case "$choice" in
            1) bind_users_to_node_smart; wait_for_input ;;
            2) unbind_user_from_node; wait_for_input ;;
            3) batch_bind_users_to_node; wait_for_input ;;
            4|5|6) show_user_node_bindings; wait_for_input ;;
            7) log_info "清理空绑定功能待实现"; wait_for_input ;;
            8) log_info "验证绑定功能待实现"; wait_for_input ;;
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
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case "$choice" in
            1) generate_singbox_config; wait_for_input ;;
            2) show_config; wait_for_input ;;
            3)
                if [[ -f "$SINGBOX_CONFIG" ]] && command -v sing-box &>/dev/null; then
                    print_info "验证配置文件..."
                    if sing-box check -c "$SINGBOX_CONFIG"; then
                        print_success "配置文件验证通过"
                    else
                        print_error "配置文件验证失败"
                    fi
                else
                    print_error "配置文件不存在或 sing-box 未安装"
                fi
                wait_for_input
                ;;
            4) restore_config; wait_for_input ;;
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
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case "$choice" in
            1) start_singbox; wait_for_input ;;
            2) stop_singbox; wait_for_input ;;
            3) restart_singbox; wait_for_input ;;
            4) reload_singbox; wait_for_input ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# 脚本管理和关于信息
# =============================================================================

# 关于脚本
show_about() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          关于脚本"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}脚本名称：${NC}s-singbox 一键管理脚本"
    echo -e "${YELLOW}脚本版本：${NC}V1.0.0"
    echo ""
    echo -e "${YELLOW}功能简介：${NC}"
    echo -e "  ${GREEN}核心功能${NC}"
    echo -e "  • sing-box 内核安装、更新、卸载"
    echo -e "  • 多协议节点管理（VLESS、VMess、Trojan、Shadowsocks、Hysteria2、TUIC等）"
    echo -e "  • 用户管理与流量统计"
    echo -e "  • 订阅链接生成（支持Base64、Clash、SingBox格式）"
    echo ""
    echo -e "  ${GREEN}高级功能${NC}"
    echo -e "  • Cloudflare 隧道管理（Argo临时/专用隧道、WARP隧道）"
    echo -e "  • BBR 网络加速优化（TCP拥塞控制算法）"
    echo -e "  • 域名与证书管理（自动申请SSL证书、Reality伪装域名优选）"
    echo -e "  • 出站规则管理（WARP出站、代理链、分流规则）"
    echo -e "  • 防火墙与端口管理（自动配置端口跳跃）"
    echo ""
    echo -e "${YELLOW}项目地址：${NC}${BLUE}https://github.com/sindricn/s-singbox${NC}"
    echo -e "${YELLOW}作者博客：${NC}${BLUE}blog.nbvil.com${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "按 Enter 键返回主菜单..."
}

# 脚本管理菜单
#================================================================
# 卸载功能
#================================================================

# 仅卸载管理脚本
uninstall_script_only() {
    clear
    print_warning "仅卸载管理脚本"
    echo ""
    print_info "此操作将："
    echo "  • 删除管理脚本及相关模块"
    echo "  • 保留 sing-box 核心程序"
    echo "  • 保留所有配置和数据"
    echo ""

    read -p "确认卸载管理脚本？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "已取消卸载"
        return 0
    fi

    echo ""
    # 获取脚本目录
    local script_path="${BASH_SOURCE[0]}"
    if [[ -L "$script_path" ]]; then
        script_path="$(readlink -f "$script_path")"
    fi
    local script_dir="$(cd "$(dirname "$script_path")" && pwd)"
    local script_name="$(basename "$script_path")"

    # 删除脚本目录
    print_info "删除脚本目录: $script_dir"

    # 如果在脚本目录中，先退出到上级目录
    cd /tmp || cd /

    rm -rf "$script_dir"
    print_success "管理脚本已卸载"

    echo ""
    print_info "sing-box 核心和配置已保留"
    print_info "您仍可使用 systemctl 管理 sing-box 服务"
    echo ""

    exit 0
}

# 仅卸载 sing-box 核心
uninstall_singbox_only() {
    clear
    print_warning "仅卸载 sing-box 核心"
    echo ""
    print_info "此操作将："
    echo "  • 卸载 sing-box 核心程序"
    echo "  • 可选择是否删除配置和数据"
    echo "  • 保留管理脚本"
    echo ""

    # 调用 core.sh 中的卸载函数
    if declare -f uninstall_sing-box &>/dev/null; then
        uninstall_sing-box
    else
        print_error "未找到卸载函数，请确保 modules/core.sh 已加载"
        return 1
    fi
}

# 完全卸载
uninstall_complete() {
    clear
    print_warning "完全卸载 sing-box 和管理脚本"
    echo ""
    print_info "此操作将："
    echo "  • 卸载 sing-box 核心程序"
    echo "  • 删除所有配置和数据"
    echo "  • 删除管理脚本"
    echo ""

    read -p "确认完全卸载？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "已取消卸载"
        return 0
    fi

    echo ""

    # 1. 停止服务
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        print_info "停止 sing-box 服务..."
        systemctl stop sing-box
    fi

    # 2. 禁用服务
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        print_info "禁用 sing-box 服务..."
        systemctl disable sing-box 2>/dev/null
    fi

    # 3. 卸载 sing-box
    print_info "卸载 sing-box 核心..."
    local uninstall_success=false

    if command -v apt-get &>/dev/null; then
        apt-get remove -y sing-box 2>/dev/null
        apt-get purge -y sing-box 2>/dev/null
        apt-get autoremove -y 2>/dev/null
        uninstall_success=true
    elif command -v dnf &>/dev/null; then
        dnf remove -y sing-box 2>/dev/null
        uninstall_success=true
    elif command -v yum &>/dev/null; then
        yum remove -y sing-box 2>/dev/null
        uninstall_success=true
    elif command -v pacman &>/dev/null; then
        pacman -R --noconfirm sing-box 2>/dev/null
        uninstall_success=true
    fi

    # 手动删除
    if command -v sing-box &>/dev/null; then
        local singbox_path=$(which sing-box)
        rm -f "$singbox_path" 2>/dev/null
    fi

    # 4. 删除配置和数据
    print_info "删除配置和数据..."
    rm -rf /etc/sing-box 2>/dev/null
    rm -rf /var/lib/sing-box 2>/dev/null
    rm -rf /etc/systemd/system/sing-box.service 2>/dev/null
    rm -rf /lib/systemd/system/sing-box.service 2>/dev/null

    systemctl daemon-reload

    print_success "sing-box 核心已卸载"

    # 5. 删除管理脚本
    print_info "删除管理脚本..."

    local script_path="${BASH_SOURCE[0]}"
    if [[ -L "$script_path" ]]; then
        script_path="$(readlink -f "$script_path")"
    fi
    local script_dir="$(cd "$(dirname "$script_path")" && pwd)"

    cd /tmp || cd /
    rm -rf "$script_dir"

    print_success "完全卸载完成"
    echo ""

    exit 0
}

menu_script() {
    while true; do
        clear
        print_header "脚本管理"
        echo ""
        print_section_start
        print_menu_item "1" "更新脚本"
        print_menu_item "2" "卸载管理"
        print_section_end
        print_nav_options "false" "true"

        choice=$(read_menu_choice "请选择操作 [0-2]")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case $choice in
            1)
                # 更新脚本
                clear
                echo -e "${CYAN}正在更新脚本...${NC}"
                echo ""

                local script_path="${BASH_SOURCE[0]}"
                if [[ -L "$script_path" ]]; then
                    script_path="$(readlink -f "$script_path")"
                fi
                local script_dir="$(cd "$(dirname "$script_path")" && pwd)"

                # 查找 Git 仓库目录（向上查找）
                local git_dir=""
                local current_dir="$script_dir"
                while [[ "$current_dir" != "/" ]]; do
                    if [[ -d "$current_dir/.git" ]]; then
                        git_dir="$current_dir"
                        break
                    fi
                    current_dir="$(dirname "$current_dir")"
                done

                if [[ -n "$git_dir" ]]; then
                    cd "$git_dir" || {
                        log_error "无法进入 Git 目录"
                        wait_for_input
                        continue
                    }

                    print_info "Git 仓库目录: $git_dir"
                    echo ""

                    # 检查是否有未提交的更改
                    if ! git diff-index --quiet HEAD 2>/dev/null; then
                        print_warning "检测到本地修改的文件"
                        echo ""
                        read -p "是否暂存本地修改并继续更新? [y/N]: " stash_confirm
                        if [[ "$stash_confirm" == "y" || "$stash_confirm" == "Y" ]]; then
                            git stash
                            print_info "已暂存本地修改"
                        else
                            print_info "已取消更新"
                            wait_for_input
                            continue
                        fi
                    fi

                    # 执行更新
                    print_info "正在从远程仓库拉取更新..."
                    if git pull; then
                        print_success "脚本更新完成"
                        echo ""
                        print_info "如果之前暂存了修改，可使用 'git stash pop' 恢复"
                    else
                        log_error "更新失败，请检查网络连接或手动更新"
                    fi
                else
                    log_warn "未检测到 Git 仓库"
                    echo ""
                    print_info "可能的原因："
                    echo "  1. 使用了在线安装但未保留 .git 目录"
                    echo "  2. 手动下载了脚本文件"
                    echo ""
                    print_info "解决方案："
                    echo "  方案1 (推荐): 重新使用在线安装"
                    echo -e "    ${YELLOW}bash <(curl -fsSL https://raw.githubusercontent.com/sindricn/s-singbox/main/install.sh)${NC}"
                    echo ""
                    echo "  方案2: 手动下载最新版本"
                    echo -e "    ${YELLOW}https://github.com/sindricn/s-singbox${NC}"
                fi
                wait_for_input
                ;;
            2)
                # 卸载管理
                clear
                print_header "卸载管理"
                echo ""
                echo -e "${YELLOW}卸载选项:${NC}"
                echo -e "  ${CYAN}1.${NC} 仅卸载管理脚本(保留 sing-box 核心与配置)"
                echo -e "  ${CYAN}2.${NC} 仅卸载 sing-box 核心与配置文件(保留管理脚本)"
                echo -e "  ${CYAN}3.${NC} 完全卸载(同时卸载脚本和 sing-box)"
                echo ""
                read -p "请选择卸载方式 [1-3] (0 取消): " uninstall_choice

                case $uninstall_choice in
                    1) uninstall_script_only ;;
                    2) uninstall_singbox_only ;;
                    3) uninstall_complete ;;
                    0|*) log_info "已取消卸载" ;;
                esac
                wait_for_input
                ;;
            0) break ;;
            *)
                log_error "无效选择"
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
                # sing-box 管理
                menu_core
                ;;
            2)
                # 用户管理
                handle_user_menu
                ;;
            3)
                # 节点管理
                handle_node_menu
                ;;
            4)
                # 订阅管理
                menu_subscription
                ;;
            5)
                # 域名管理
                domain_management_menu
                ;;
            6)
                # 证书管理
                certificate_management_menu
                ;;
            7)
                # 出站规则
                if declare -f outbound_management_menu &>/dev/null; then
                    outbound_management_menu
                else
                    print_error "出站规则模块未加载"
                    wait_for_input
                fi
                ;;
            8)
                # 防火墙管理
                if declare -f firewall_management_menu &>/dev/null; then
                    firewall_management_menu
                else
                    print_error "防火墙管理模块未加载"
                    wait_for_input
                fi
                ;;
            9)
                # CF 隧道管理
                menu_cf_tunnel
                ;;
            10)
                # BBR 加速管理
                menu_bbr
                ;;
            11)
                # 脚本管理
                menu_script
                ;;
            12)
                # 关于脚本
                show_about
                ;;
            0)
                log_info "用户退出程序"
                echo -e "${GREEN}感谢使用 sing-box 管理脚本！${NC}"
                exit 0
                ;;
            *)
                log_warn "无效选择: $choice"
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 运行主程序
main
