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

    # 创建数据目录
    mkdir -p "$DATA_DIR"
    mkdir -p "$SUBSCRIPTION_DIR"

    # 初始化数据文件
    if [[ ! -f "$USERS_FILE" ]]; then
        echo '{"users":[]}' > "$USERS_FILE"
    fi
    if [[ ! -f "$NODES_FILE" ]]; then
        echo '{"nodes":[]}' > "$NODES_FILE"
    fi
    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo '{"bindings":[]}' > "$NODE_USERS_FILE"
    fi

    # 创建配置文件（简单默认配置，无节点）
    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        create_default_config
    fi

    # 创建 systemd 服务
    create_systemd_service

    # 重新加载 systemd
    systemctl daemon-reload
    systemctl enable sing-box

    # 启动服务
    print_info "启动 sing-box 服务..."
    systemctl start sing-box
    sleep 2

    # 检查启动状态
    if systemctl is-active --quiet sing-box; then
        print_success "sing-box 安装完成！版本: v${latest_version}"
        print_success "服务运行状态: $(systemctl is-active sing-box)"
    else
        print_success "sing-box 安装完成！版本: v${latest_version}"
        print_warning "服务启动失败，请检查配置"
        print_info "查看日志: journalctl -u sing-box -n 50"
        print_info "验证配置: $SINGBOX_BIN check -c $SINGBOX_CONFIG"
        systemctl status sing-box --no-pager -l
    fi
}

# 卸载 sing-box
uninstall_sing-box() {
    print_warning "开始卸载 sing-box..."
    echo ""

    # 检查是否已安装
    if [[ ! -f "$SINGBOX_BIN" && ! -f "$SINGBOX_SERVICE" ]]; then
        print_error "sing-box 未安装"
        return 1
    fi

    # 显示将要删除的内容
    echo -e "${YELLOW}将删除以下内容：${NC}"
    [[ -f "$SINGBOX_BIN" ]] && echo "  - 二进制文件: $SINGBOX_BIN"
    [[ -f "$SINGBOX_SERVICE" ]] && echo "  - 服务文件: $SINGBOX_SERVICE"
    [[ -d "$SINGBOX_DIR" ]] && echo "  - 配置目录: $SINGBOX_DIR"
    [[ -d "$DATA_DIR" ]] && echo "  - 数据目录: $DATA_DIR"
    echo ""

    read -p "确认卸载 sing-box？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        return 0
    fi

    echo ""
    print_info "正在卸载..."

    # 1. 停止服务
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        print_info "停止 sing-box 服务..."
        systemctl stop sing-box
        if [[ $? -eq 0 ]]; then
            print_success "服务已停止"
        else
            print_warning "停止服务失败"
        fi
    fi

    # 2. 禁用服务
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        print_info "禁用 sing-box 服务..."
        systemctl disable sing-box 2>/dev/null
        if [[ $? -eq 0 ]]; then
            print_success "服务已禁用"
        else
            print_warning "禁用服务失败"
        fi
    fi

    # 3. 删除服务文件
    if [[ -f "$SINGBOX_SERVICE" ]]; then
        print_info "删除服务文件..."
        rm -f "$SINGBOX_SERVICE"
        if [[ ! -f "$SINGBOX_SERVICE" ]]; then
            print_success "服务文件已删除"
        else
            print_error "删除服务文件失败"
        fi
    fi

    # 4. 删除二进制文件
    if [[ -f "$SINGBOX_BIN" ]]; then
        print_info "删除二进制文件..."
        rm -f "$SINGBOX_BIN"
        if [[ ! -f "$SINGBOX_BIN" ]]; then
            print_success "二进制文件已删除"
        else
            print_error "删除二进制文件失败"
        fi
    fi

    # 5. 删除配置和数据目录（包括所有子目录）
    if [[ -d "$SINGBOX_DIR" ]]; then
        print_info "删除配置和数据目录..."
        rm -rf "$SINGBOX_DIR"
        if [[ ! -d "$SINGBOX_DIR" ]]; then
            print_success "目录已删除"
        else
            print_error "删除目录失败"
        fi
    fi

    # 6. 清理可能的备份文件
    print_info "清理备份文件..."
    rm -f "${SINGBOX_DIR}.backup"* 2>/dev/null || true
    rm -f /tmp/singbox_* 2>/dev/null || true

    # 7. 重新加载 systemd
    print_info "重新加载 systemd..."
    systemctl daemon-reload

    # 8. 清理systemd缓存
    systemctl reset-failed sing-box 2>/dev/null || true

    echo ""
    # 验证卸载结果
    local failed=0
    if [[ -f "$SINGBOX_BIN" ]]; then
        echo "  ${RED}✗${NC} 二进制文件仍存在: $SINGBOX_BIN"
        failed=1
    fi
    if [[ -f "$SINGBOX_SERVICE" ]]; then
        echo "  ${RED}✗${NC} 服务文件仍存在: $SINGBOX_SERVICE"
        failed=1
    fi
    if [[ -d "$SINGBOX_DIR" ]]; then
        echo "  ${RED}✗${NC} 目录仍存在: $SINGBOX_DIR"
        failed=1
    fi

    if [[ $failed -eq 0 ]]; then
        print_success "✅ sing-box 卸载完成"
        return 0
    else
        print_error "❌ 卸载未完全成功，请手动检查上述文件"
        return 1
    fi
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
