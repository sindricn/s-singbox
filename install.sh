#!/bin/bash

# =============================================================================
# s-singbox 一键安装脚本
# =============================================================================

set -e

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo bash install.sh"
        exit 1
    fi
}

# 检测操作系统
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        print_error "无法检测操作系统"
        exit 1
    fi

    print_info "检测到系统: $OS $VER"
}

# 安装依赖
install_dependencies() {
    print_header "安装依赖"

    case $OS in
        ubuntu|debian)
            print_info "更新软件包列表..."
            apt-get update -qq
            print_info "安装依赖包..."
            apt-get install -y curl wget tar jq systemctl >/dev/null 2>&1
            ;;
        centos|rhel|rocky|alma)
            print_info "安装依赖包..."
            yum install -y curl wget tar jq systemd >/dev/null 2>&1
            ;;
        fedora)
            print_info "安装依赖包..."
            dnf install -y curl wget tar jq systemd >/dev/null 2>&1
            ;;
        arch|manjaro)
            print_info "安装依赖包..."
            pacman -Sy --noconfirm curl wget tar jq systemd >/dev/null 2>&1
            ;;
        *)
            print_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac

    print_success "依赖安装完成"
}

# 初始化数据目录
init_data_directory() {
    print_header "初始化数据目录"

    local data_dir="${SCRIPT_DIR}/data"

    if [[ ! -d "$data_dir" ]]; then
        mkdir -p "$data_dir"
        print_info "创建数据目录: $data_dir"
    fi

    # 创建示例数据文件
    if [[ ! -f "${data_dir}/users.json" ]]; then
        cat > "${data_dir}/users.json" <<'EOF'
{
  "users": []
}
EOF
        print_info "创建 users.json"
    fi

    if [[ ! -f "${data_dir}/nodes.json" ]]; then
        cat > "${data_dir}/nodes.json" <<'EOF'
{
  "nodes": []
}
EOF
        print_info "创建 nodes.json"
    fi

    if [[ ! -f "${data_dir}/node_users.json" ]]; then
        cat > "${data_dir}/node_users.json" <<'EOF'
{
  "bindings": []
}
EOF
        print_info "创建 node_users.json"
    fi

    if [[ ! -f "${data_dir}/domains.json" ]]; then
        cat > "${data_dir}/domains.json" <<'EOF'
{
  "domains": []
}
EOF
        print_info "创建 domains.json"
    fi

    if [[ ! -f "${data_dir}/outbounds.json" ]]; then
        cat > "${data_dir}/outbounds.json" <<'EOF'
{
  "outbounds": []
}
EOF
        print_info "创建 outbounds.json"
    fi

    if [[ ! -f "${data_dir}/route_rules.json" ]]; then
        cat > "${data_dir}/route_rules.json" <<'EOF'
{
  "rules": []
}
EOF
        print_info "创建 route_rules.json"
    fi

    print_success "数据目录初始化完成"
}

# 安装 sing-box 内核
install_singbox_core() {
    print_header "安装 sing-box 内核"

    # 加载 core.sh 模块
    if [[ -f "${SCRIPT_DIR}/modules/common.sh" ]]; then
        source "${SCRIPT_DIR}/modules/common.sh"
    fi

    if [[ -f "${SCRIPT_DIR}/modules/core.sh" ]]; then
        source "${SCRIPT_DIR}/modules/core.sh"

        # 调用安装函数
        if install_singbox; then
            print_success "sing-box 内核安装完成"
        else
            print_error "sing-box 内核安装失败"
            exit 1
        fi
    else
        print_error "找不到 core.sh 模块"
        exit 1
    fi
}

# 创建命令链接
create_symlink() {
    print_header "创建命令链接"

    local target="/usr/local/bin/singbox-manager"

    if [[ -L "$target" ]]; then
        rm -f "$target"
    fi

    ln -s "${SCRIPT_DIR}/singbox-manager.sh" "$target"
    chmod +x "${SCRIPT_DIR}/singbox-manager.sh"

    print_info "创建符号链接: $target"
    print_success "可以使用 'singbox-manager' 命令启动管理工具"
}

# 配置防火墙
configure_firewall() {
    print_header "配置防火墙"

    if command -v ufw &>/dev/null; then
        print_info "检测到 ufw 防火墙"
        print_info "请稍后手动配置需要开放的端口"
    elif command -v firewall-cmd &>/dev/null; then
        print_info "检测到 firewalld 防火墙"
        print_info "请稍后手动配置需要开放的端口"
    else
        print_info "未检测到防火墙，跳过配置"
    fi
}

# 显示安装完成信息
show_completion() {
    print_header "安装完成"

    echo -e "${GREEN}s-singbox 安装成功！${NC}"
    echo ""
    echo -e "使用方法："
    echo -e "  ${CYAN}singbox-manager${NC}          # 启动管理工具"
    echo -e "  ${CYAN}cd ${SCRIPT_DIR}${NC}"
    echo -e "  ${CYAN}./singbox-manager.sh${NC}    # 或直接运行脚本"
    echo ""
    echo -e "下一步："
    echo -e "  1. 运行管理工具"
    echo -e "  2. 添加节点"
    echo -e "  3. 添加用户"
    echo -e "  4. 绑定用户到节点"
    echo -e "  5. 生成配置并启动服务"
    echo ""
    echo -e "文档："
    echo -e "  ${BLUE}https://github.com/sindricn/s-singbox${NC}"
    echo ""
}

# 主函数
main() {
    print_header "s-singbox 安装向导"

    # 检查权限
    check_root

    # 检测系统
    detect_os

    # 安装依赖
    install_dependencies

    # 初始化数据目录
    init_data_directory

    # 安装 sing-box 内核
    install_singbox_core

    # 创建命令链接
    create_symlink

    # 配置防火墙
    configure_firewall

    # 显示完成信息
    show_completion
}

# 运行主函数
main
