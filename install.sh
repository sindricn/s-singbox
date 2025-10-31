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
CYAN='\033[0;36m'
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
            DEPS="curl wget tar jq"
            missing_deps=()

            for dep in $DEPS; do
                if command -v "$dep" >/dev/null 2>&1; then
                    print_info "已安装: $dep ✓"
                else
                    print_info "未检测到: $dep"
                    missing_deps+=("$dep")
                fi
            done

            if [[ ${#missing_deps[@]} -gt 0 ]]; then
                print_info "更新软件包列表..."
                apt-get update -qq 2>&1 | grep -E "^(Get:|Fetched|Reading)" || true

                for dep in "${missing_deps[@]}"; do
                    print_info "正在安装: $dep"
                    apt-get install -y "$dep" 2>&1 | grep -E "^(Setting up|Unpacking)" || true
                done
            else
                print_success "所有依赖已安装"
            fi
            ;;
        centos|rhel|rocky|alma)
            DEPS="curl wget tar jq"
            for dep in $DEPS; do
                if ! command -v $dep >/dev/null 2>&1; then
                    print_info "正在安装: $dep"
                    yum install -y $dep 2>&1 | grep -E "^(Installing|Complete)" || true
                else
                    print_info "已安装: $dep ✓"
                fi
            done
            ;;
        fedora)
            DEPS="curl wget tar jq"
            for dep in $DEPS; do
                if ! command -v $dep >/dev/null 2>&1; then
                    print_info "正在安装: $dep"
                    dnf install -y $dep 2>&1 | grep -E "^(Installing|Complete)" || true
                else
                    print_info "已安装: $dep ✓"
                fi
            done
            ;;
        arch|manjaro)
            DEPS="curl wget tar jq"
            for dep in $DEPS; do
                if ! command -v $dep >/dev/null 2>&1; then
                    print_info "正在安装: $dep"
                    pacman -Sy --noconfirm $dep 2>/dev/null || true
                else
                    print_info "已安装: $dep ✓"
                fi
            done
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

    # 加载 common.sh 模块
    if [[ -f "${SCRIPT_DIR}/modules/common.sh" ]]; then
        source "${SCRIPT_DIR}/modules/common.sh"
    else
        print_error "找不到 common.sh 模块"
        exit 1
    fi

    # 加载 core.sh 模块
    if [[ -f "${SCRIPT_DIR}/modules/core.sh" ]]; then
        source "${SCRIPT_DIR}/modules/core.sh"
    else
        print_error "找不到 core.sh 模块"
        exit 1
    fi

    # 调用安装函数
    if install_singbox; then
        print_success "sing-box 内核安装完成"
    else
        print_error "sing-box 内核安装失败"
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
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}         安装完成！${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo -e "${CYAN}安装信息：${NC}"
    echo -e "  安装目录: ${YELLOW}${SCRIPT_DIR}${NC}"
    echo -e "  全局命令: ${YELLOW}singbox-manager${NC}"
    echo ""
    echo -e "${CYAN}快速开始：${NC}"
    echo ""
    echo -e "  1. 启动管理脚本："
    echo -e "     ${YELLOW}singbox-manager${NC}  ${GREEN}(推荐)${NC}"
    echo -e "     或"
    echo -e "     ${YELLOW}${SCRIPT_DIR}/singbox-manager.sh${NC}"
    echo ""
    echo -e "  2. 首次使用建议："
    echo -e "     - 添加节点"
    echo -e "     - 添加用户"
    echo -e "     - 绑定用户到节点"
    echo -e "     - 生成配置"
    echo -e "     - 启动服务"
    echo ""
    echo -e "${CYAN}卸载方式：${NC}"
    echo -e "  ${YELLOW}bash ${SCRIPT_DIR}/uninstall.sh${NC}"
    echo ""
    echo -e "${CYAN}文档：${NC}"
    echo -e "  查看完整文档: ${YELLOW}${SCRIPT_DIR}/README.md${NC}"
    echo ""
    echo -e "${CYAN}感谢使用 sing-box 管理脚本！${NC}"
    echo ""
}

# 检查并下载项目文件（在线安装支持）
check_project_files() {
    # 检测是否为在线安装（通过 curl | bash 方式）
    if [[ ! -f "${SCRIPT_DIR}/singbox-manager.sh" ]] || [[ ! -d "${SCRIPT_DIR}/modules" ]]; then
        print_info "检测到在线安装，正在下载完整项目..."

        # 设置安装目录
        INSTALL_DIR="/opt/s-singbox"

        # 如果目录已存在，更新而不是删除
        if [[ -d "$INSTALL_DIR" ]]; then
            print_info "检测到已安装，将更新到最新版本..."

            # 备份用户数据（如果存在）
            if [[ -d "$INSTALL_DIR/data" ]]; then
                print_info "备份用户数据..."
                BACKUP_DIR="/tmp/s-singbox-backup-$(date +%Y%m%d%H%M%S)"
                mkdir -p "$BACKUP_DIR"
                cp -r "$INSTALL_DIR/data" "$BACKUP_DIR/" 2>/dev/null || true
                print_success "用户数据已备份到: $BACKUP_DIR"
            fi

            # 删除旧的脚本文件，但保留数据目录
            print_info "清理旧版本文件..."
            rm -rf "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/modules 2>/dev/null || true
        fi

        # 创建临时目录
        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR"

        # 下载项目文件
        print_info "下载项目文件..."
        DOWNLOAD_SUCCESS=false

        if command -v git >/dev/null 2>&1; then
            # 优先使用 git clone
            git clone --depth=1 https://github.com/sindricn/s-singbox.git s-singbox >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                # 创建或更新安装目录
                mkdir -p "$INSTALL_DIR"
                # 复制文件到安装目录（保留数据目录）
                cp -r s-singbox/* "$INSTALL_DIR/" 2>/dev/null || true
                DOWNLOAD_SUCCESS=true
            fi
        fi

        if [[ "$DOWNLOAD_SUCCESS" == "false" ]]; then
            # 使用 wget 或 curl 下载 zip
            if command -v wget >/dev/null 2>&1; then
                wget -q https://github.com/sindricn/s-singbox/archive/refs/heads/main.zip -O s-singbox.zip
            elif command -v curl >/dev/null 2>&1; then
                curl -sL https://github.com/sindricn/s-singbox/archive/refs/heads/main.zip -o s-singbox.zip
            else
                print_error "未找到 wget 或 curl 命令"
                rm -rf "$TEMP_DIR"
                exit 1
            fi

            # 解压文件
            if unzip -q s-singbox.zip 2>/dev/null; then
                # 创建或更新安装目录
                mkdir -p "$INSTALL_DIR"
                # 复制文件到安装目录（保留数据目录）
                cp -r s-singbox-main/* "$INSTALL_DIR/" 2>/dev/null || true
                DOWNLOAD_SUCCESS=true
            fi
        fi

        # 检查下载是否成功
        if [[ "$DOWNLOAD_SUCCESS" == "false" ]]; then
            print_error "项目文件下载失败"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # 恢复用户数据（如果有备份）
        if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/data" ]]; then
            print_info "恢复用户数据..."
            cp -r "$BACKUP_DIR/data" "$INSTALL_DIR/" 2>/dev/null || true
            print_success "用户数据已恢复"
        fi

        # 清理临时文件
        rm -rf "$TEMP_DIR"

        # 更新 SCRIPT_DIR
        SCRIPT_DIR="$INSTALL_DIR"
        cd "$SCRIPT_DIR"

        print_success "项目文件下载完成"
    fi

    # 验证文件
    if [[ ! -f "${SCRIPT_DIR}/singbox-manager.sh" ]]; then
        print_error "未找到主脚本文件: ${SCRIPT_DIR}/singbox-manager.sh"
        exit 1
    fi

    if [[ ! -d "${SCRIPT_DIR}/modules" ]]; then
        print_error "未找到模块目录: ${SCRIPT_DIR}/modules"
        exit 1
    fi

    # 设置权限
    print_info "设置执行权限..."
    chmod +x "${SCRIPT_DIR}/singbox-manager.sh"
    chmod +x "${SCRIPT_DIR}/modules/"*.sh 2>/dev/null || true
    chmod +x "${SCRIPT_DIR}/install.sh" 2>/dev/null || true
    chmod +x "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true

    print_success "脚本文件检查完成"
}

# 主函数
main() {
    print_header "s-singbox 安装向导"

    # 检查权限
    check_root

    # 检测系统
    detect_os

    # 检查并下载项目文件（在线安装支持）
    check_project_files

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
