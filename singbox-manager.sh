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

    # 获取在线用户数量
    local online_count=$(get_online_users_count 2>/dev/null || echo "0")

    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   sing-box 一键管理脚本 V2.0.0      ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}系统状态${NC}                           ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  内核版本: ${YELLOW}${version}${NC}"
    echo -e "${CYAN}│${NC}  运行状态: ${status}"
    echo -e "${CYAN}│${NC}  用户数量: ${BLUE}${user_count}${NC}"
    echo -e "${CYAN}│${NC}  节点总数: ${BLUE}${node_count}${NC}"
    echo -e "${CYAN}│${NC}  在线用户: ${GREEN}${online_count}${NC}/${BLUE}${user_count}${NC}"
    echo -e "${CYAN}└─────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}功能菜单${NC}                           ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}1.${NC}  sing-box 管理                  ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}2.${NC}  用户管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}3.${NC}  节点管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}4.${NC}  订阅管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}5.${NC}  域名管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}6.${NC}  证书管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}7.${NC}  出站规则                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}8.${NC}  防火墙管理                     ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}9.${NC}  脚本管理                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}10.${NC} 关于脚本                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}0.${NC}  退出脚本                       ${CYAN}│${NC}"
    echo -e "${CYAN}└─────────────────────────────────────┘${NC}"
    echo ""
}

# sing-box 管理菜单
menu_core() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║          sing-box 管理               ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}1.${NC} 安装 sing-box"
        echo -e "${GREEN}2.${NC} 启动 sing-box"
        echo -e "${GREEN}3.${NC} 停止 sing-box"
        echo -e "${GREEN}4.${NC} 重启 sing-box"
        echo -e "${GREEN}5.${NC} 卸载 sing-box"
        echo -e "${GREEN}6.${NC} 更新 sing-box"
        echo -e "${GREEN}7.${NC} 查看日志"
        echo -e "${GREEN}8.${NC} 查看版本"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作 [0-8]: " choice

        case $choice in
            1)
                install_sing-box
                read -p "按回车键继续..."
                ;;
            2)
                start_sing-box
                read -p "按回车键继续..."
                ;;
            3)
                stop_sing-box
                read -p "按回车键继续..."
                ;;
            4)
                restart_sing-box
                read -p "按回车键继续..."
                ;;
            5)
                uninstall_sing-box
                read -p "按回车键继续..."
                ;;
            6)
                update_sing-box
                read -p "按回车键继续..."
                ;;
            7)
                # 查看日志
                clear
                echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
                echo -e "${CYAN}║          sing-box 日志               ║${NC}"
                echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${GREEN}1.${NC} 实时日志（最新50行）"
                echo -e "${GREEN}2.${NC} 完整日志"
                echo -e "${GREEN}3.${NC} 错误日志"
                echo -e "${GREEN}0.${NC} 返回"
                echo ""
                read -p "请选择 [0-3]: " log_choice

                case $log_choice in
                    1)
                        echo ""
                        echo -e "${CYAN}实时日志（Ctrl+C退出）:${NC}"
                        echo ""
                        journalctl -u sing-box -f -n 50
                        ;;
                    2)
                        echo ""
                        echo -e "${CYAN}完整日志:${NC}"
                        echo ""
                        journalctl -u sing-box --no-pager | less
                        ;;
                    3)
                        echo ""
                        echo -e "${CYAN}错误日志:${NC}"
                        echo ""
                        journalctl -u sing-box -p err --no-pager | less
                        ;;
                    0) ;;
                    *) print_error "无效选择" ;;
                esac
                read -p "按回车键继续..."
                ;;
            8)
                # 查看版本
                show_version
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
                # 添加节点（显示协议选择菜单）
                menu_node_add
                ;;
            2)
                # 删除节点
                delete_node
                read -p "按回车键继续..."
                ;;
            3)
                # 列出节点
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

# 添加节点菜单（协议选择）
menu_node_add() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║          添加节点                    ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 主流代理协议 ━━━━━━━${NC}"
        echo -e "${GREEN}1.${NC}  VLESS    - 通用代理（支持 XTLS）"
        echo -e "${GREEN}2.${NC}  VMess    - V2Ray 经典协议"
        echo -e "${GREEN}3.${NC}  Trojan   - TLS 伪装代理"
        echo -e "${GREEN}4.${NC}  Shadowsocks - 轻量级代理"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 高性能协议 ━━━━━━━${NC}"
        echo -e "${GREEN}5.${NC}  Hysteria2 - 基于 QUIC 高性能（推荐）"
        echo -e "${GREEN}6.${NC}  TUIC      - QUIC 协议代理"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 抗审查/本地代理 ━━━━━━━${NC}"
        echo -e "${GREEN}7.${NC}  Naive     - 强抗审查代理"
        echo -e "${GREEN}8.${NC}  Mixed     - HTTP + SOCKS5 混合"
        echo -e "${GREEN}9.${NC}  HTTP      - HTTP 代理"
        echo -e "${GREEN}10.${NC} SOCKS     - SOCKS5 代理"
        echo -e "${GREEN}11.${NC} AnyTLS    - 流量填充混淆（sing-box 1.12.0+）"
        echo ""
        echo -e "${GREEN}0.${NC}  返回上级菜单"
        echo ""
        read -p "请选择协议 [0-11]: " choice

        case $choice in
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
            0) break ;;
            *) print_error "无效选择" ;;
        esac

        read -p "按 Enter 键继续..."
    done
}

handle_user_menu() {
    while true; do
        show_user_menu
        read -p "请选择: " choice

        case "$choice" in
            1)
                # 添加用户
                add_global_user
                read -p "按回车键继续..."
                ;;
            2)
                # 删除用户
                delete_global_user
                read -p "按回车键继续..."
                ;;
            3)
                # 列出用户
                list_global_users
                read -p "按回车键继续..."
                ;;
            4)
                # 修改用户
                show_user_detail
                read -p "按回车键继续..."
                ;;
            5)
                # 查看用户详情
                show_user_detail
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
                # 绑定用户到节点
                bind_users_to_node_smart
                read -p "按回车键继续..."
                ;;
            2)
                # 解绑用户与节点
                unbind_user_from_node
                read -p "按回车键继续..."
                ;;
            3)
                # 批量绑定用户
                batch_bind_users_to_node
                read -p "按回车键继续..."
                ;;
            4)
                # 列出所有绑定
                show_user_node_bindings
                read -p "按回车键继续..."
                ;;
            5)
                # 列出用户的绑定
                show_user_node_bindings
                read -p "按回车键继续..."
                ;;
            6)
                # 列出节点的用户
                show_user_node_bindings
                read -p "按回车键继续..."
                ;;
            7)
                # 清理空绑定
                log_info "清理空绑定功能待实现"
                read -p "按回车键继续..."
                ;;
            8)
                # 验证绑定完整性
                log_info "验证绑定功能待实现"
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
                # 生成配置
                generate_singbox_config
                read -p "按回车键继续..."
                ;;
            2)
                # 查看配置
                show_config
                read -p "按回车键继续..."
                ;;
            3)
                # 验证配置
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
                read -p "按回车键继续..."
                ;;
            4)
                # 恢复备份
                restore_config
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
# 脚本管理和关于信息
# =============================================================================

# 关于脚本
show_about() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          关于脚本                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}脚本名称：${NC}sing-box 一键管理脚本"
    echo -e "${YELLOW}脚本版本：${NC}V2.0.0"
    echo ""
    echo -e "${YELLOW}功能简介：${NC}"
    echo -e "  • sing-box 内核安装、更新、卸载"
    echo -e "  • 多协议节点管理（VLESS、VMess、Trojan、Shadowsocks、Hysteria2等）"
    echo -e "  • 用户管理与流量统计"
    echo -e "  • 订阅链接生成（支持Base64、Clash、SingBox格式）"
    echo -e "  • 域名与证书管理（自动申请SSL证书）"
    echo -e "  • 出站规则管理（代理链、分流规则）"
    echo -e "  • 防火墙与端口管理"
    echo ""
    echo -e "${YELLOW}项目地址：${NC}${BLUE}https://github.com/sindricn/s-singbox${NC}"
    echo -e "${YELLOW}作者博客：${NC}${BLUE}blog.nbvil.com${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "按 Enter 键返回主菜单..."
}

# 脚本管理菜单
menu_script() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║          脚本管理                    ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}1.${NC} 更新脚本"
        echo -e "${GREEN}2.${NC} 卸载管理"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作 [0-2]: " choice

        case $choice in
            1)
                # 更新脚本
                clear
                echo -e "${CYAN}正在更新脚本...${NC}"

                local script_path="${BASH_SOURCE[0]}"
                if [[ -L "$script_path" ]]; then
                    script_path="$(readlink -f "$script_path")"
                fi
                local script_dir="$(cd "$(dirname "$script_path")" && pwd)"

                cd "$script_dir" || {
                    log_error "无法进入脚本目录"
                    read -p "按 Enter 键继续..."
                    continue
                }

                if [[ -d ".git" ]]; then
                    git pull || log_error "更新失败"
                    log_info "脚本更新完成"
                else
                    log_warn "当前不是Git仓库，无法自动更新"
                    echo -e "${YELLOW}请手动下载最新版本${NC}"
                fi
                read -p "按 Enter 键继续..."
                ;;
            2)
                # 卸载管理
                clear
                echo -e "${RED}╔═══════════════════════════════════════╗${NC}"
                echo -e "${RED}║          卸载管理                    ║${NC}"
                echo -e "${RED}╚═══════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${YELLOW}卸载选项：${NC}"
                echo -e "  ${CYAN}1.${NC} 仅卸载管理脚本（保留 sing-box 核心与配置）"
                echo -e "  ${CYAN}2.${NC} 仅卸载 sing-box 核心与配置文件（保留管理脚本）"
                echo -e "  ${CYAN}3.${NC} 完全卸载（同时卸载脚本和 sing-box）"
                echo ""
                read -p "请选择卸载方式 [1-3] (0 取消): " uninstall_choice

                case $uninstall_choice in
                    1)
                        log_warn "仅卸载管理脚本功能尚未实现"
                        ;;
                    2)
                        log_warn "仅卸载 sing-box 核心功能尚未实现"
                        ;;
                    3)
                        log_warn "完全卸载功能尚未实现"
                        ;;
                    0|*)
                        log_info "已取消卸载"
                        ;;
                esac
                read -p "按 Enter 键继续..."
                ;;
            0)
                break
                ;;
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
                print_warning "订阅管理功能开发中..."
                read -p "按回车键继续..."
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
                print_warning "出站规则功能开发中..."
                read -p "按回车键继续..."
                ;;
            8)
                # 防火墙管理
                print_warning "防火墙管理功能开发中..."
                read -p "按回车键继续..."
                ;;
            9)
                # 脚本管理
                menu_script
                ;;
            10)
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
