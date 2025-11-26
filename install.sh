#!/bin/bash

#================================================================
# sing-box 一键安装脚本
# 快速安装入口
#================================================================

set -e

# 默认分支配置
DEFAULT_BRANCH="main"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 打印函数
print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    print_error "此脚本必须以 root 权限运行"
    exit 1
fi

clear
echo -e "${CYAN}"
cat << "EOF"
     _                 _
 ___(_)_ __   __ _    | |__   _____  __
/ __| | '_ \ / _` |___| '_ \ / _ \ \/ /
\__ \ | | | | (_| |___| |_) | (_) >  <
|___/_|_| |_|\__, |   |_.__/ \___/_/\_\
             |___/
    __  __
   |  \/  | __ _ _ __   __ _  __ _  ___ _ __
   | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
   | |  | | (_| | | | | (_| | (_| |  __/ |
   |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|
                             |___/
EOF
echo -e "${NC}"
echo -e "${CYAN}=====================================${NC}"
echo -e "${CYAN}   sing-box 一键管理脚本安装程序${NC}"
echo -e "${CYAN}=====================================${NC}"
echo ""

# 检测脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 检查系统
print_info "检测系统信息..."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    print_success "系统: $PRETTY_NAME"
else
    print_error "无法检测系统类型"
    exit 1
fi

# 检查架构
ARCH=$(uname -m)
print_info "系统架构: $ARCH"

case $ARCH in
    x86_64)
        print_success "支持的架构"
        ;;
    aarch64|armv7l)
        print_success "支持的架构"
        ;;
    *)
        print_error "不支持的架构: $ARCH"
        exit 1
        ;;
esac

# 安装依赖
print_info "检查并安装必要依赖..."

case $OS in
    ubuntu|debian)
        DEPS="curl wget unzip jq git"
        missing_deps=()

        for dep in $DEPS; do
            if command -v "$dep" >/dev/null 2>&1; then
                print_info "✓ $dep"
            else
                print_warning "未检测到: $dep"
                missing_deps+=("$dep")
            fi
        done

        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            print_info "更新软件包列表..."
            apt-get update -qq 2>&1 | grep -E "^(Get:|Fetched|Reading)" || true

            for dep in "${missing_deps[@]}"; do
                print_info "安装: $dep"
                apt-get install -y "$dep" 2>&1 | grep -E "^(Setting up|Unpacking)" || true
            done
            print_success "依赖安装完成"
        else
            print_success "所有依赖已安装"
        fi
        ;;
    centos|rhel|fedora)
        DEPS="curl wget unzip jq git"
        missing_deps=()

        for dep in $DEPS; do
            if command -v "$dep" >/dev/null 2>&1; then
                print_info "✓ $dep"
            else
                print_warning "未检测到: $dep"
                missing_deps+=("$dep")
            fi
        done

        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            for dep in "${missing_deps[@]}"; do
                print_info "安装: $dep"
                yum install -y "$dep" 2>&1 | grep -E "^(Installing|Complete)" || true
            done
            print_success "依赖安装完成"
        else
            print_success "所有依赖已安装"
        fi
        ;;
    *)
        print_warning "未识别的系统，请手动安装: curl wget unzip jq git"
        ;;
esac

# 在线安装支持
if [[ ! -f "${SCRIPT_DIR}/singbox-manager.sh" || ! -d "${SCRIPT_DIR}/modules" ]]; then
    print_info "检测到在线安装，正在下载项目文件..."

    INSTALL_DIR="/opt/s-singbox"
    TEMP_DIR="/tmp/s-singbox-$$"
    BACKUP_DIR=""

    # 分支选择优先级：
    # 1. 命令行参数 $1
    # 2. 本地git仓库的当前分支（如果存在）
    # 3. 环境变量 BRANCH
    # 4. 脚本内定义的 DEFAULT_BRANCH
    BRANCH=""

    # 优先使用命令行参数
    if [[ -n "$1" ]]; then
        BRANCH="$1"
        print_info "使用命令行参数指定的分支: $BRANCH"
    # 检测本地git仓库
    elif [[ -d "${SCRIPT_DIR}/.git" ]]; then
        BRANCH=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ -n "$BRANCH" ]]; then
            print_info "检测到git仓库，使用当前分支: $BRANCH"
        fi
    fi

    # 如果都未检测到，使用环境变量或脚本默认分支
    if [[ -z "$BRANCH" ]]; then
        BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
        print_info "使用默认分支: $BRANCH"
    fi

    # 备份现有数据
    if [[ -d "$INSTALL_DIR/data" ]]; then
        print_info "检测到现有数据，正在备份..."
        BACKUP_DIR="/tmp/s-singbox-backup-$$"
        mkdir -p "$BACKUP_DIR"
        cp -r "$INSTALL_DIR/data" "$BACKUP_DIR/" 2>/dev/null || true
        print_success "数据已备份到: $BACKUP_DIR"
    fi

    # 下载项目文件
    print_info "下载最新代码 (分支: $BRANCH)..."
    mkdir -p "$TEMP_DIR"

    if git clone --depth=1 --branch "$BRANCH" https://github.com/sindricn/s-singbox.git "$TEMP_DIR" 2>&1 | grep -E "^(Cloning|Receiving)" || true; then
        print_success "代码下载完成 (分支: $BRANCH)"
    else
        print_error "下载失败，请检查网络连接或分支名称是否正确"
        print_info "提示: 可用分支通常为 main 或 dev"
        exit 1
    fi

    # 安装到目标目录
    print_info "安装到: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/"* 2>/dev/null || true
    cp -r "$TEMP_DIR/"* "$INSTALL_DIR/"
    # 复制隐藏文件（包括 .git）
    cp -r "$TEMP_DIR/".git "$INSTALL_DIR/" 2>/dev/null || true
    cp -r "$TEMP_DIR/".gitignore "$INSTALL_DIR/" 2>/dev/null || true
    print_success ".git 目录已保留，支持后续在线更新"

    # 恢复用户数据
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

print_success "脚本文件检查完成"

# 初始化数据目录
print_info "初始化数据目录..."
mkdir -p "${SCRIPT_DIR}/data"
mkdir -p "${SCRIPT_DIR}/data/subscriptions"

# 初始化数据文件（如果不存在）
if [[ ! -f "${SCRIPT_DIR}/data/users.json" ]]; then
    echo '{"users":[]}' > "${SCRIPT_DIR}/data/users.json"
fi

if [[ ! -f "${SCRIPT_DIR}/data/nodes.json" ]]; then
    echo '{"nodes":[]}' > "${SCRIPT_DIR}/data/nodes.json"
fi

if [[ ! -f "${SCRIPT_DIR}/data/node_users.json" ]]; then
    echo '{"bindings":[]}' > "${SCRIPT_DIR}/data/node_users.json"
fi

if [[ ! -f "${SCRIPT_DIR}/data/subscriptions.json" ]]; then
    echo '{"subscriptions":[]}' > "${SCRIPT_DIR}/data/subscriptions.json"
fi

print_success "数据目录初始化完成"

# 设置权限
print_info "设置执行权限..."
chmod +x "${SCRIPT_DIR}/singbox-manager.sh"
chmod +x "${SCRIPT_DIR}/modules/"*.sh 2>/dev/null || true
chmod +x "${SCRIPT_DIR}/install.sh" 2>/dev/null || true
chmod +x "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true

print_success "权限设置完成"

# 创建软链接
print_info "创建命令软链接..."
ln -sf "${SCRIPT_DIR}/singbox-manager.sh" /usr/local/bin/singbox-manager 2>/dev/null || true
ln -sf "${SCRIPT_DIR}/singbox-manager.sh" /usr/local/bin/s-singbox 2>/dev/null || true

if [[ -f /usr/local/bin/s-singbox ]]; then
    print_success "可以使用 's-singbox' 或 'singbox-manager' 命令启动脚本"
fi

echo ""
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}         安装完成！${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo -e "${CYAN}安装信息：${NC}"
echo -e "  安装目录: ${YELLOW}${SCRIPT_DIR}${NC}"
echo -e "  全局命令: ${YELLOW}s-singbox${NC} / ${YELLOW}singbox-manager${NC}"
echo ""
echo -e "${CYAN}快速开始：${NC}"
echo ""
echo -e "  1. 启动管理脚本："
echo -e "     ${YELLOW}s-singbox${NC}  ${GREEN}(推荐)${NC}"
echo -e "     或"
echo -e "     ${YELLOW}singbox-manager${NC}"
echo -e "     或"
echo -e "     ${YELLOW}${SCRIPT_DIR}/singbox-manager.sh${NC}"
echo ""
echo -e "  2. 首次使用建议："
echo -e "     - 安装 sing-box 内核"
echo -e "     - 添加节点"
echo -e "     - 添加用户"
echo -e "     - 生成订阅"
echo -e "     - 开放防火墙端口"
echo ""
echo -e "${CYAN}卸载方式：${NC}"
echo -e "  ${YELLOW}bash ${SCRIPT_DIR}/uninstall.sh${NC}"
echo ""
echo -e "${CYAN}文档：${NC}"
echo -e "  查看完整文档: ${YELLOW}${SCRIPT_DIR}/README.md${NC}"
echo -e "  项目地址: ${BLUE}https://github.com/sindricn/s-singbox${NC}"
echo ""
echo -e "${GREEN}感谢使用 sing-box 管理脚本！${NC}"
echo ""
