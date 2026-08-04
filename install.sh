#!/bin/bash

#================================================================
# sing-box 一键安装脚本
# 快速安装入口
#================================================================

set -e
umask 077

# 当前安装入口所属分支。dev/install.sh 必须默认安装 dev，避免在线执行时
# 因无法从进程替换文件描述符反推出 curl URL 而错误回退到 main。
DEFAULT_BRANCH="dev"
PROJECT_KERNEL_REVISION="1"

# 在后续给 BRANCH 赋值前保留调用方显式传入的环境变量。
# 推荐使用 S_SINGBOX_BRANCH；同时兼容已有的 BRANCH 用法。
INSTALL_BRANCH_OVERRIDE="${S_SINGBOX_BRANCH:-${BRANCH:-}}"

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
    x86_64|amd64)
        print_success "支持的架构"
        ;;
    aarch64|arm64|armv7l|armv6l)
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
        DEPS="curl:curl wget:wget unzip:unzip jq:jq git:git openssl:openssl update-ca-certificates:ca-certificates tar:tar gzip:gzip sha256sum:coreutils flock:util-linux python3:python3 iptables:iptables"
        missing_deps=()

        for entry in $DEPS; do
            cmd=${entry%%:*}
            dep=${entry#*:}
            if command -v "$cmd" >/dev/null 2>&1; then
                print_info "✓ $cmd"
            else
                print_warning "未检测到: $cmd（软件包 $dep）"
                missing_deps+=("$dep")
            fi
        done

        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            print_info "更新软件包列表..."
            if ! apt-get update; then
                print_error "软件包列表更新失败"
                exit 1
            fi

            for dep in "${missing_deps[@]}"; do
                print_info "安装: $dep"
                if ! apt-get install -y "$dep"; then
                    print_error "依赖安装失败: $dep"
                    exit 1
                fi
            done
            print_success "依赖安装完成"
        else
            print_success "所有依赖已安装"
        fi
        ;;
    centos|rhel|fedora)
        DEPS="curl:curl wget:wget unzip:unzip jq:jq git:git openssl:openssl update-ca-trust:ca-certificates tar:tar gzip:gzip sha256sum:coreutils flock:util-linux python3:python3 iptables:iptables-services"
        missing_deps=()

        for entry in $DEPS; do
            cmd=${entry%%:*}
            dep=${entry#*:}
            if command -v "$cmd" >/dev/null 2>&1; then
                print_info "✓ $cmd"
            else
                print_warning "未检测到: $cmd（软件包 $dep）"
                missing_deps+=("$dep")
            fi
        done

        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            for dep in "${missing_deps[@]}"; do
                print_info "安装: $dep"
                if ! yum install -y "$dep"; then
                    print_error "依赖安装失败: $dep"
                    exit 1
                fi
            done
            print_success "依赖安装完成"
        else
            print_success "所有依赖已安装"
        fi
        ;;
    arch|manjaro)
        DEPS="curl:curl wget:wget unzip:unzip jq:jq git:git openssl:openssl update-ca-trust:ca-certificates tar:tar gzip:gzip sha256sum:coreutils flock:util-linux python3:python iptables:iptables"
        missing_deps=()
        for entry in $DEPS; do
            cmd=${entry%%:*}
            dep=${entry#*:}
            if command -v "$cmd" >/dev/null 2>&1; then
                print_info "✓ $cmd"
            else
                print_warning "未检测到: $cmd（软件包 $dep）"
                missing_deps+=("$dep")
            fi
        done
        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            if ! pacman -Sy --needed --noconfirm "${missing_deps[@]}"; then
                print_error "依赖安装失败"
                exit 1
            fi
            print_success "依赖安装完成"
        else
            print_success "所有依赖已安装"
        fi
        ;;
    *)
        print_warning "未识别的系统，请手动安装: curl wget unzip jq git openssl ca-certificates tar gzip coreutils util-linux"
        ;;
esac

# 在线安装支持
if [[ ! -f "${SCRIPT_DIR}/singbox-manager.sh" || ! -d "${SCRIPT_DIR}/modules" ]]; then
    print_info "检测到在线安装，正在下载项目文件..."

    INSTALL_DIR="/opt/s-singbox"
    TEMP_DIR=$(mktemp -d /tmp/s-singbox-install-XXXXXX) || exit 1
    BACKUP_DIR=""

    # 分支选择优先级：
    # 1. 命令行参数 $1
    # 2. 环境变量 S_SINGBOX_BRANCH（兼容 BRANCH）
    # 3. 本地git仓库的当前分支（如果存在）
    # 4. 脚本内定义的 DEFAULT_BRANCH
    BRANCH=""

    # 优先使用命令行参数
    if [[ -n "$1" ]]; then
        BRANCH="$1"
        print_info "使用命令行参数指定的分支: $BRANCH"
    # 使用调用方显式指定的环境变量
    elif [[ -n "$INSTALL_BRANCH_OVERRIDE" ]]; then
        BRANCH="$INSTALL_BRANCH_OVERRIDE"
        print_info "使用环境变量指定的分支: $BRANCH"
    # 检测本地git仓库
    elif [[ -d "${SCRIPT_DIR}/.git" ]]; then
        BRANCH=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ -n "$BRANCH" ]]; then
            print_info "检测到git仓库，使用当前分支: $BRANCH"
        fi
    fi

    # 如果都未检测到，使用当前安装入口的默认分支
    if [[ -z "$BRANCH" ]]; then
        BRANCH="$DEFAULT_BRANCH"
        print_info "使用默认分支: $BRANCH"
    fi

    if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
        print_error "无效的安装分支名称: $BRANCH"
        exit 1
    fi

    # 备份现有数据
    if [[ -d "/var/lib/sing-box" ]]; then
        print_info "检测到现有数据，正在备份..."
        BACKUP_DIR=$(mktemp -d /tmp/s-singbox-backup-XXXXXX) || exit 1
        cp -a "/var/lib/sing-box" "$BACKUP_DIR/data" 2>/dev/null || true
        print_success "数据已备份到: $BACKUP_DIR"
    fi

    # 下载项目文件
    print_info "下载最新代码 (分支: $BRANCH)..."
    if git clone --depth=1 --branch "$BRANCH" https://github.com/sindricn/s-singbox.git "$TEMP_DIR"; then
        CLONED_BRANCH=$(git -C "$TEMP_DIR" branch --show-current 2>/dev/null || echo "")
        CLONED_COMMIT=$(git -C "$TEMP_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        if [[ "$CLONED_BRANCH" != "$BRANCH" ]]; then
            print_error "下载分支校验失败: 期望 $BRANCH，实际 ${CLONED_BRANCH:-unknown}"
            exit 1
        fi
        print_success "代码下载完成 (分支: $CLONED_BRANCH, 提交: $CLONED_COMMIT)"
    else
        print_error "下载失败，请检查网络连接或分支名称是否正确"
        print_info "提示: 可用分支通常为 main 或 dev"
        exit 1
    fi

    # 安装到目标目录
    print_info "安装到: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    if [[ "$INSTALL_DIR" != "/opt/s-singbox" ]]; then
        print_error "拒绝清理非预期安装目录: $INSTALL_DIR"
        exit 1
    fi
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    cp -a "$TEMP_DIR/." "$INSTALL_DIR/"
    # 保留隐藏文件（包括 .git），支持后续在线更新
    print_success ".git 目录已保留，支持后续在线更新"

    # 恢复用户数据
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/data" ]]; then
        print_info "恢复用户数据..."
        mkdir -p /var/lib/sing-box
        cp -a "$BACKUP_DIR/data/." /var/lib/sing-box/ 2>/dev/null || true
        print_success "用户数据已恢复"
    fi

    # 清理临时文件
    [[ "$TEMP_DIR" == /tmp/s-singbox-install-* ]] && rm -rf -- "$TEMP_DIR"

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
DATA_DIR="/var/lib/sing-box"
mkdir -p "${DATA_DIR}/subscriptions"

# 初始化数据文件（如果不存在）
if [[ ! -f "${DATA_DIR}/users.json" ]]; then
    echo '{"users":[]}' > "${DATA_DIR}/users.json"
fi

if [[ ! -f "${DATA_DIR}/nodes.json" ]]; then
    echo '{"nodes":[]}' > "${DATA_DIR}/nodes.json"
fi

if [[ ! -f "${DATA_DIR}/node_users.json" ]]; then
    echo '{"bindings":[]}' > "${DATA_DIR}/node_users.json"
fi

if [[ ! -f "${DATA_DIR}/subscriptions.json" ]]; then
    echo '{"subscriptions":[]}' > "${DATA_DIR}/subscriptions.json"
fi

chmod 700 "$DATA_DIR" "$DATA_DIR/subscriptions"
chmod 600 "$DATA_DIR"/*.json

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
if [[ -d "${SCRIPT_DIR}/.git" ]]; then
    INSTALLED_BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "unknown")
    INSTALLED_COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo -e "  代码版本: ${YELLOW}${INSTALLED_BRANCH}@${INSTALLED_COMMIT}${NC}"
fi
echo -e "  全局命令: ${YELLOW}s-singbox${NC} / ${YELLOW}singbox-manager${NC}"
if command -v sing-box >/dev/null 2>&1; then
    KERNEL_INFO=$(sing-box version 2>/dev/null || true)
    KERNEL_BIN=$(command -v sing-box)
    KERNEL_METADATA="/var/lib/sing-box/project_kernel.json"
    KERNEL_SHA=$(sha256sum "$KERNEL_BIN" 2>/dev/null | awk '{print $1}')
    RECORDED_SHA=$(jq -r '.binary_sha256 // empty' "$KERNEL_METADATA" 2>/dev/null || true)
    RECORDED_REVISION=$(jq -r '.kernel_revision // empty' "$KERNEL_METADATA" 2>/dev/null || true)
    if ! grep -q 'with_v2ray_api' <<< "$KERNEL_INFO" \
        || ! grep -q 'with_clash_api' <<< "$KERNEL_INFO" \
        || [[ "$RECORDED_REVISION" != "$PROJECT_KERNEL_REVISION" || "$RECORDED_SHA" != "$KERNEL_SHA" ]]; then
        echo -e "  内核状态: ${YELLOW}当前内核不符合项目默认构建，可在管理菜单中更新/修复${NC}"
    fi
else
    echo -e "  内核状态: ${YELLOW}尚未安装，请在管理菜单中安装 sing-box 内核${NC}"
fi
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
echo -e "     - 安装项目默认的 sing-box 内核"
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
