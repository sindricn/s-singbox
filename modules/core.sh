#!/bin/bash

#================================================================
# 内核管理模块
# 功能：安装、卸载、更新、启动、停止 sing-box
#================================================================

# 安装 sing-box
install_sing-box() {
    print_info "开始安装 sing-box..."

    # 检测系统架构
    local arch=$(uname -m)
    case $arch in
        x86_64)
            arch="amd64"
            ;;
        aarch64)
            arch="arm64"
            ;;
        armv7l)
            arch="armv7"
            ;;
        *)
            print_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac

    # 检查是否已安装
    if [[ -f "$SINGBOX_BIN" ]]; then
        print_warning "sing-box 已安装，请先卸载"
        return 1
    fi

    # 安装依赖
    print_info "安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y curl wget tar gzip jq
    elif command -v yum &>/dev/null; then
        yum install -y curl wget tar gzip jq
    else
        print_error "不支持的包管理器"
        return 1
    fi

    # 获取最新版本
    print_info "获取最新版本信息..."
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$latest_version" ]]; then
        print_error "获取版本信息失败"
        return 1
    fi
    print_info "最新版本: v${latest_version}"

    # 下载 sing-box
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${arch}.tar.gz"
    print_info "下载 sing-box: $download_url"

    local temp_dir=$(mktemp -d)
    if ! wget -q --show-progress -O "${temp_dir}/sing-box.tar.gz" "$download_url"; then
        print_error "下载失败"
        rm -rf "$temp_dir"
        return 1
    fi

    # 解压安装
    print_info "解压安装..."
    mkdir -p "$SINGBOX_DIR"
    tar -xzf "${temp_dir}/sing-box.tar.gz" -C "${temp_dir}"
    mv "${temp_dir}/sing-box-${latest_version}-linux-${arch}/sing-box" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf "$temp_dir"

    # 创建配置文件
    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        create_default_config
    fi

    # 创建 systemd 服务
    create_systemd_service

    # 启动服务
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box

    print_success "sing-box 安装完成！版本: v${latest_version}"
    print_info "运行状态: $(systemctl is-active sing-box)"
}

# 卸载 sing-box
uninstall_sing-box() {
    print_warning "开始卸载 sing-box..."

    read -p "确认卸载 sing-box？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        return 0
    fi

    # 停止服务
    if systemctl is-active --quiet sing-box; then
        systemctl stop sing-box
    fi
    systemctl disable sing-box 2>/dev/null

    # 删除文件
    rm -f "$SINGBOX_SERVICE"
    rm -rf "$SINGBOX_DIR"

    systemctl daemon-reload
    print_success "sing-box 卸载完成"
}

# 更新 sing-box
update_sing-box() {
    print_info "检查更新..."

    if [[ ! -f "$SINGBOX_BIN" ]]; then
        print_error "sing-box 未安装"
        return 1
    fi

    # 获取当前版本
    local current_version=$("$SINGBOX_BIN" version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' || echo "unknown")
    print_info "当前版本: ${current_version}"

    # 获取最新版本
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
    print_info "最新版本: v${latest_version}"

    if [[ "$current_version" == "$latest_version" ]]; then
        print_success "已是最新版本"
        return 0
    fi

    print_info "发现新版本，开始更新..."

    # 备份配置
    if declare -f backup_config &>/dev/null; then
        backup_config
    fi

    # 停止服务
    systemctl stop sing-box

    # 下载新版本
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
    esac

    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${arch}.tar.gz"
    local temp_dir=$(mktemp -d)

    if ! wget -q --show-progress -O "${temp_dir}/sing-box.tar.gz" "$download_url"; then
        print_error "下载失败"
        systemctl start sing-box
        rm -rf "$temp_dir"
        return 1
    fi

    # 解压更新
    tar -xzf "${temp_dir}/sing-box.tar.gz" -C "${temp_dir}"
    mv "${temp_dir}/sing-box-${latest_version}-linux-${arch}/sing-box" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf "$temp_dir"

    # 启动服务
    systemctl start sing-box

    print_success "更新完成！当前版本: v${latest_version}"
}

# 启动 sing-box
start_sing-box() {
    if systemctl is-active --quiet sing-box; then
        print_warning "sing-box 已在运行"
        return 0
    fi

    print_info "启动 sing-box..."
    systemctl start sing-box

    sleep 2
    if systemctl is-active --quiet sing-box; then
        print_success "sing-box 启动成功"
    else
        print_error "sing-box 启动失败"
        systemctl status sing-box
        return 1
    fi
}

# 停止 sing-box
stop_sing-box() {
    if ! systemctl is-active --quiet sing-box; then
        print_warning "sing-box 未运行"
        return 0
    fi

    print_info "停止 sing-box..."
    systemctl stop sing-box

    sleep 1
    if ! systemctl is-active --quiet sing-box; then
        print_success "sing-box 停止成功"
    else
        print_error "sing-box 停止失败"
        return 1
    fi
}

# 重启 sing-box
restart_sing-box() {
    print_info "重启 sing-box..."
    systemctl restart sing-box

    sleep 2
    if systemctl is-active --quiet sing-box; then
        print_success "sing-box 重启成功"
    else
        print_error "sing-box 重启失败"
        systemctl status sing-box
        return 1
    fi
}

# 查看版本
show_version() {
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        print_error "sing-box 未安装"
        return 1
    fi

    echo -e "${CYAN}sing-box 版本信息：${NC}"
    "$SINGBOX_BIN" version
}

# 创建默认配置
create_default_config() {
    cat > "$SINGBOX_CONFIG" <<'EOF'
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/usr/local/sing-box/cache.db"
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "",
      "secret": "",
      "default_mode": "rule"
    }
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF
}

# 创建 systemd 服务
create_systemd_service() {
    cat > "$SINGBOX_SERVICE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}
