#!/bin/bash

# =============================================================================
# core.sh - sing-box 内核管理模块
# 提供安装、更新、卸载、服务管理等功能
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
# 配置
# =============================================================================

# sing-box 相关路径
SINGBOX_BINARY="/usr/local/bin/sing-box"
SINGBOX_CONFIG_DIR="/usr/local/singbox"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config.json"
SINGBOX_LOG_DIR="/var/log/singbox"
SINGBOX_CACHE_DIR="/var/lib/singbox"

# systemd 服务文件
SYSTEMD_SERVICE_FILE="/etc/systemd/system/sing-box.service"

# GitHub 仓库信息
GITHUB_REPO="SagerNet/sing-box"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
DOWNLOAD_BASE_URL="https://github.com/${GITHUB_REPO}/releases/download"

# =============================================================================
# 版本检查
# =============================================================================

# 获取已安装的版本
get_installed_version() {
    if [[ ! -f "$SINGBOX_BINARY" ]]; then
        echo "未安装"
        return 1
    fi

    local version=$("$SINGBOX_BINARY" version 2>/dev/null | grep -oP 'version \K[0-9.]+' | head -1)
    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    else
        echo "未知"
        return 1
    fi
}

# 获取最新版本号
get_latest_version() {
    local latest_version=$(curl -s "$GITHUB_API" | jq -r '.tag_name' | sed 's/^v//')

    if [[ -n "$latest_version" ]] && [[ "$latest_version" != "null" ]]; then
        echo "$latest_version"
        return 0
    else
        log_error "获取最新版本失败"
        return 1
    fi
}

# 检查是否有新版本
check_update_available() {
    local current_version=$(get_installed_version)
    local latest_version=$(get_latest_version)

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    if [[ "$current_version" == "未安装" ]]; then
        echo "未安装"
        return 0
    fi

    local comparison=$(version_compare "$current_version" "$latest_version")
    if [[ $comparison -lt 0 ]]; then
        echo "有新版本: $latest_version (当前: $current_version)"
        return 0
    else
        echo "已是最新版本: $current_version"
        return 1
    fi
}

# =============================================================================
# 下载和安装
# =============================================================================

# 检测系统架构
detect_architecture() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        *)
            log_error "不支持的架构: $arch"
            return 1
            ;;
    esac
}

# 检测操作系统
detect_os() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case $os in
        linux)
            echo "linux"
            ;;
        darwin)
            echo "darwin"
            ;;
        *)
            log_error "不支持的操作系统: $os"
            return 1
            ;;
    esac
}

# 构建下载 URL
build_download_url() {
    local version=$1
    local os=$(detect_os)
    local arch=$(detect_architecture)

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    local filename="sing-box-${version}-${os}-${arch}.tar.gz"
    local url="${DOWNLOAD_BASE_URL}/v${version}/${filename}"

    echo "$url"
}

# 下载 sing-box
download_singbox() {
    local version=$1
    local download_url=$2
    local download_dir="/tmp/singbox-install-$$"

    log_info "开始下载 sing-box v${version}"

    # 创建临时目录
    mkdir -p "$download_dir"

    # 下载文件
    local filename=$(basename "$download_url")
    local download_path="${download_dir}/${filename}"

    if curl -L -o "$download_path" "$download_url" --progress-bar; then
        log_success "下载完成"
        echo "$download_path"
        return 0
    else
        log_error "下载失败"
        rm -rf "$download_dir"
        return 1
    fi
}

# 解压和安装
install_binary() {
    local archive_path=$1
    local extract_dir=$(dirname "$archive_path")

    log_info "解压文件..."

    # 解压
    if ! tar -xzf "$archive_path" -C "$extract_dir"; then
        log_error "解压失败"
        return 1
    fi

    # 查找二进制文件
    local binary=$(find "$extract_dir" -name "sing-box" -type f | head -1)

    if [[ -z "$binary" ]]; then
        log_error "未找到 sing-box 二进制文件"
        return 1
    fi

    # 安装二进制文件
    log_info "安装二进制文件到 $SINGBOX_BINARY"

    if cp "$binary" "$SINGBOX_BINARY" && chmod +x "$SINGBOX_BINARY"; then
        log_success "安装成功"
        return 0
    else
        log_error "安装失败"
        return 1
    fi
}

# 创建必要的目录
create_directories() {
    log_info "创建必要的目录..."

    ensure_dir "$SINGBOX_CONFIG_DIR"
    ensure_dir "$SINGBOX_LOG_DIR"
    ensure_dir "$SINGBOX_CACHE_DIR"

    # 设置权限
    chmod 755 "$SINGBOX_CONFIG_DIR"
    chmod 755 "$SINGBOX_LOG_DIR"
    chmod 755 "$SINGBOX_CACHE_DIR"

    log_success "目录创建完成"
}

# 安装 sing-box
install_singbox() {
    local target_version=$1

    require_root

    # 检查依赖命令
    if ! check_commands curl tar jq; then
        log_error "请先安装必需的依赖: curl tar jq"
        return 1
    fi

    # 获取目标版本
    if [[ -z "$target_version" ]]; then
        log_info "获取最新版本..."
        target_version=$(get_latest_version)

        if [[ $? -ne 0 ]]; then
            return 1
        fi

        log_info "最新版本: $target_version"
    fi

    # 构建下载 URL
    local download_url=$(build_download_url "$target_version")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    log_info "下载地址: $download_url"

    # 下载
    local archive_path=$(download_singbox "$target_version" "$download_url")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # 安装
    if ! install_binary "$archive_path"; then
        rm -rf "$(dirname "$archive_path")"
        return 1
    fi

    # 清理临时文件
    rm -rf "$(dirname "$archive_path")"

    # 创建目录
    create_directories

    # 安装 systemd 服务
    install_systemd_service

    # 验证安装
    local installed_version=$(get_installed_version)
    log_success "sing-box 安装完成"
    log_info "版本: $installed_version"

    return 0
}

# =============================================================================
# 更新
# =============================================================================

# 更新 sing-box
update_singbox() {
    require_root

    # 检查是否已安装
    if [[ ! -f "$SINGBOX_BINARY" ]]; then
        log_error "sing-box 未安装"
        log_info "请先运行安装命令"
        return 1
    fi

    # 获取当前版本
    local current_version=$(get_installed_version)
    log_info "当前版本: $current_version"

    # 获取最新版本
    log_info "检查更新..."
    local latest_version=$(get_latest_version)

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    log_info "最新版本: $latest_version"

    # 比较版本
    local comparison=$(version_compare "$current_version" "$latest_version")

    if [[ $comparison -ge 0 ]]; then
        log_success "已是最新版本，无需更新"
        return 0
    fi

    log_info "发现新版本，开始更新..."

    # 停止服务
    if is_service_running; then
        log_info "停止服务..."
        stop_singbox_service
    fi

    # 备份当前二进制文件
    local backup_path="${SINGBOX_BINARY}.bak"
    if cp "$SINGBOX_BINARY" "$backup_path"; then
        log_info "已备份当前版本"
    fi

    # 执行安装（会覆盖现有文件）
    if install_singbox "$latest_version"; then
        log_success "更新成功"

        # 删除备份
        rm -f "$backup_path"

        # 重启服务
        if systemctl is-enabled sing-box &>/dev/null; then
            log_info "重启服务..."
            start_singbox_service
        fi

        return 0
    else
        log_error "更新失败，恢复原版本"

        # 恢复备份
        if [[ -f "$backup_path" ]]; then
            mv "$backup_path" "$SINGBOX_BINARY"
            log_info "已恢复原版本"
        fi

        return 1
    fi
}

# =============================================================================
# 卸载
# =============================================================================

# 卸载 sing-box
uninstall_singbox() {
    require_root

    log_warn "即将卸载 sing-box"

    if ! confirm "确认卸载"; then
        log_info "取消卸载"
        return 0
    fi

    # 停止并禁用服务
    if systemctl is-active sing-box &>/dev/null; then
        log_info "停止服务..."
        systemctl stop sing-box
    fi

    if systemctl is-enabled sing-box &>/dev/null; then
        log_info "禁用服务..."
        systemctl disable sing-box
    fi

    # 删除 systemd 服务文件
    if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
        rm -f "$SYSTEMD_SERVICE_FILE"
        systemctl daemon-reload
        log_info "删除 systemd 服务"
    fi

    # 删除二进制文件
    if [[ -f "$SINGBOX_BINARY" ]]; then
        rm -f "$SINGBOX_BINARY"
        log_info "删除二进制文件"
    fi

    # 询问是否删除配置和数据
    if confirm "是否删除配置和数据"; then
        rm -rf "$SINGBOX_CONFIG_DIR"
        rm -rf "$SINGBOX_LOG_DIR"
        rm -rf "$SINGBOX_CACHE_DIR"
        log_info "删除配置和数据目录"
    else
        log_info "保留配置和数据目录"
    fi

    log_success "卸载完成"
}

# =============================================================================
# systemd 服务管理
# =============================================================================

# 安装 systemd 服务
install_systemd_service() {
    log_info "安装 systemd 服务..."

    cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BINARY} run -c ${SINGBOX_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载 systemd
    systemctl daemon-reload

    # 启用服务
    systemctl enable sing-box

    log_success "systemd 服务安装完成"
}

# 检查服务是否运行
is_service_running() {
    systemctl is-active sing-box &>/dev/null
}

# 启动服务
start_singbox_service() {
    require_root

    if is_service_running; then
        log_warn "服务已在运行"
        return 0
    fi

    log_info "启动 sing-box 服务..."

    if systemctl start sing-box; then
        log_success "服务启动成功"
        return 0
    else
        log_error "服务启动失败"
        log_info "查看日志: journalctl -u sing-box -n 50"
        return 1
    fi
}

# 停止服务
stop_singbox_service() {
    require_root

    if ! is_service_running; then
        log_warn "服务未运行"
        return 0
    fi

    log_info "停止 sing-box 服务..."

    if systemctl stop sing-box; then
        log_success "服务停止成功"
        return 0
    else
        log_error "服务停止失败"
        return 1
    fi
}

# 重启服务
restart_singbox_service() {
    require_root

    log_info "重启 sing-box 服务..."

    if systemctl restart sing-box; then
        log_success "服务重启成功"
        return 0
    else
        log_error "服务重启失败"
        log_info "查看日志: journalctl -u sing-box -n 50"
        return 1
    fi
}

# 重载配置
reload_singbox_service() {
    require_root

    if ! is_service_running; then
        log_warn "服务未运行，启动服务..."
        start_singbox_service
        return $?
    fi

    log_info "重载 sing-box 配置..."

    if systemctl reload sing-box; then
        log_success "配置重载成功"
        return 0
    else
        log_warn "重载失败，尝试重启服务..."
        restart_singbox_service
        return $?
    fi
}

# 查看服务状态
status_singbox_service() {
    systemctl status sing-box
}

# 启用服务自启动
enable_singbox_service() {
    require_root

    if systemctl enable sing-box; then
        log_success "已启用开机自启动"
        return 0
    else
        log_error "启用自启动失败"
        return 1
    fi
}

# 禁用服务自启动
disable_singbox_service() {
    require_root

    if systemctl disable sing-box; then
        log_success "已禁用开机自启动"
        return 0
    else
        log_error "禁用自启动失败"
        return 1
    fi
}

# =============================================================================
# 配置验证
# =============================================================================

# 验证配置文件
check_config() {
    if [[ ! -f "$SINGBOX_CONFIG_FILE" ]]; then
        log_error "配置文件不存在: $SINGBOX_CONFIG_FILE"
        return 1
    fi

    log_info "验证配置文件..."

    if "$SINGBOX_BINARY" check -c "$SINGBOX_CONFIG_FILE"; then
        log_success "配置文件有效"
        return 0
    else
        log_error "配置文件无效"
        return 1
    fi
}

# =============================================================================
# 信息查询
# =============================================================================

# 显示 sing-box 信息
show_singbox_info() {
    print_header "sing-box 信息"

    # 版本信息
    local installed_version=$(get_installed_version)
    echo -e "${CYAN}安装版本:${NC} $installed_version"

    # 二进制文件路径
    if [[ -f "$SINGBOX_BINARY" ]]; then
        echo -e "${CYAN}二进制文件:${NC} $SINGBOX_BINARY"
        echo -e "${CYAN}文件大小:${NC} $(du -h "$SINGBOX_BINARY" | cut -f1)"
    fi

    # 配置目录
    echo -e "${CYAN}配置目录:${NC} $SINGBOX_CONFIG_DIR"

    # 配置文件
    if [[ -f "$SINGBOX_CONFIG_FILE" ]]; then
        echo -e "${CYAN}配置文件:${NC} $SINGBOX_CONFIG_FILE"
        echo -e "${CYAN}配置大小:${NC} $(du -h "$SINGBOX_CONFIG_FILE" | cut -f1)"
    else
        echo -e "${CYAN}配置文件:${NC} ${YELLOW}未创建${NC}"
    fi

    # 日志目录
    echo -e "${CYAN}日志目录:${NC} $SINGBOX_LOG_DIR"

    # 缓存目录
    echo -e "${CYAN}缓存目录:${NC} $SINGBOX_CACHE_DIR"

    # 服务状态
    echo ""
    echo -e "${CYAN}服务状态:${NC}"
    if is_service_running; then
        echo -e "  运行状态: ${GREEN}运行中${NC}"
    else
        echo -e "  运行状态: ${RED}已停止${NC}"
    fi

    if systemctl is-enabled sing-box &>/dev/null; then
        echo -e "  开机自启: ${GREEN}已启用${NC}"
    else
        echo -e "  开机自启: ${YELLOW}未启用${NC}"
    fi

    # 检查更新
    echo ""
    echo -e "${CYAN}更新检查:${NC}"
    local update_info=$(check_update_available 2>/dev/null)
    if [[ $? -eq 0 ]]; then
        echo -e "  $update_info"
    fi

    echo ""
}

# =============================================================================
# 模块初始化
# =============================================================================

log_debug "core.sh 模块已加载"
