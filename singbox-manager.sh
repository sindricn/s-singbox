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
# 颜色定义
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# 通用打印函数
# =============================================================================

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_header() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
}

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
    print_header "sing-box Manager"

    echo "1)  节点管理"
    echo "2)  用户管理"
    echo "3)  绑定管理"
    echo "4)  配置管理"
    echo "5)  服务控制"
    echo "6)  证书管理"
    echo "7)  订阅管理"
    echo "8)  监控统计"
    echo "9)  防火墙管理"
    echo "10) API 管理"
    echo "11) 查看状态"
    echo "12) 查看日志"
    echo ""
    echo "0)  退出"
    echo ""
}

# 节点管理菜单
show_node_menu() {
    clear
    print_header "节点管理"

    echo "1)  添加节点"
    echo "2)  删除节点"
    echo "3)  列出节点"
    echo ""
    echo "0)  返回主菜单"
    echo ""
}

# 用户管理菜单
show_user_menu() {
    clear
    print_header "用户管理"

    echo "1)  添加用户"
    echo "2)  删除用户"
    echo "3)  列出用户"
    echo "4)  修改用户"
    echo "5)  查看用户详情"
    echo ""
    echo "0)  返回主菜单"
    echo ""
}

# 绑定管理菜单
show_binding_menu() {
    clear
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
}

# 配置管理菜单
show_config_menu() {
    clear
    print_header "配置管理"

    echo "1)  生成配置"
    echo "2)  查看配置"
    echo "3)  验证配置"
    echo "4)  恢复备份"
    echo ""
    echo "0)  返回主菜单"
    echo ""
}

# 服务控制菜单
show_service_menu() {
    clear
    print_header "服务控制"

    echo "1)  启动服务"
    echo "2)  停止服务"
    echo "3)  重启服务"
    echo "4)  重载配置"
    echo ""
    echo "0)  返回主菜单"
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
    # 检查 root 权限
    check_root

    # 检查依赖
    check_dependencies

    # 检查数据文件
    check_data_files

    # 主循环
    while true; do
        show_main_menu
        read -p "请选择: " choice

        case "$choice" in
            1)
                handle_node_menu
                ;;
            2)
                handle_user_menu
                ;;
            3)
                handle_binding_menu
                ;;
            4)
                handle_config_menu
                ;;
            5)
                handle_service_menu
                ;;
            6)
                source "${MODULES_DIR}/cert.sh"
                cert_management_menu
                ;;
            7)
                source "${MODULES_DIR}/subscription.sh"
                echo ""
                echo "1) 添加订阅"
                echo "2) 更新订阅"
                echo "3) 删除订阅"
                echo "4) 列出订阅"
                echo "5) 更新所有订阅"
                echo "0) 返回"
                echo ""
                read -p "请选择: " sub_choice
                case "$sub_choice" in
                    1) add_subscription ;;
                    2) update_subscription "" ;;
                    3) delete_subscription ;;
                    4) list_subscriptions ;;
                    5) update_all_subscriptions ;;
                esac
                read -p "按回车键继续..."
                ;;
            8)
                source "${MODULES_DIR}/monitor.sh"
                monitor_menu
                ;;
            9)
                source "${MODULES_DIR}/firewall.sh"
                firewall_menu
                ;;
            10)
                source "${MODULES_DIR}/singbox_api.sh"
                api_menu
                ;;
            11)
                status_singbox
                read -p "按回车键继续..."
                ;;
            12)
                view_logs
                read -p "按回车键继续..."
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
