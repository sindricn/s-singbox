#!/bin/bash

#================================================================
# 内核管理模块
# 功能：安装、卸载、更新、启动、停止 Xray
#================================================================

# 安装 Xray
install_sing-box() {
    print_info "开始安装 Xray..."

    # 检测系统架构
    local arch=$(uname -m)
    case $arch in
        x86_64)
            arch="64"
            ;;
        aarch64)
            arch="arm64-v8a"
            ;;
        armv7l)
            arch="arm32-v7a"
            ;;
        *)
            print_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac

    # 检查是否已安装
    if [[ -f "$SINGBOX_BIN" ]]; then
        print_warning "Xray 已安装，请先卸载"
        return 1
    fi

    # 安装依赖
    print_info "安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update
        apt-get install -y curl wget unzip jq
    elif command -v yum &>/dev/null; then
        yum install -y curl wget unzip jq
    else
        print_error "不支持的包管理器"
        return 1
    fi

    # 获取最新版本
    print_info "获取最新版本信息..."
    local latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    if [[ -z "$latest_version" ]]; then
        print_error "获取版本信息失败"
        return 1
    fi
    print_info "最新版本: v${latest_version}"

    # 下载 Xray
    local download_url="https://github.com/XTLS/Xray-core/releases/download/v${latest_version}/Xray-linux-${arch}.zip"
    print_info "下载 Xray: $download_url"

    local temp_dir=$(mktemp -d)
    if ! wget -q --show-progress -O "${temp_dir}/sing-box.zip" "$download_url"; then
        print_error "下载失败"
        rm -rf "$temp_dir"
        return 1
    fi

    # 解压安装
    print_info "解压安装..."
    mkdir -p "$SINGBOX_DIR"
    unzip -q "${temp_dir}/sing-box.zip" -d "$SINGBOX_DIR"
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

    print_success "Xray 安装完成！版本: v${latest_version}"
    print_info "运行状态: $(systemctl is-active sing-box)"
}

# 卸载 Xray
uninstall_sing-box() {
    print_warning "开始卸载 Xray..."

    read -p "确认卸载 Xray？[y/N]: " confirm
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
    print_success "Xray 卸载完成"
}

# 更新 Xray
update_sing-box() {
    print_info "检查更新..."

    if [[ ! -f "$SINGBOX_BIN" ]]; then
        print_error "Xray 未安装"
        return 1
    fi

    # 获取当前版本
    local current_version=$("$SINGBOX_BIN" version | head -n1 | awk '{print $2}' | sed 's/^v//')
    print_info "当前版本: v${current_version}"

    # 获取最新版本
    local latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    print_info "最新版本: v${latest_version}"

    if [[ "$current_version" == "$latest_version" ]]; then
        print_success "已是最新版本"
        return 0
    fi

    print_info "发现新版本，开始更新..."

    # 备份配置
    backup_config

    # 停止服务
    systemctl stop sing-box

    # 下载新版本
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l) arch="arm32-v7a" ;;
    esac

    local download_url="https://github.com/XTLS/Xray-core/releases/download/v${latest_version}/Xray-linux-${arch}.zip"
    local temp_dir=$(mktemp -d)

    if ! wget -q --show-progress -O "${temp_dir}/sing-box.zip" "$download_url"; then
        print_error "下载失败"
        systemctl start sing-box
        rm -rf "$temp_dir"
        return 1
    fi

    # 解压更新
    unzip -qo "${temp_dir}/sing-box.zip" -d "$SINGBOX_DIR"
    chmod +x "$SINGBOX_BIN"
    rm -rf "$temp_dir"

    # 启动服务
    systemctl start sing-box

    print_success "更新完成！当前版本: v${latest_version}"
}

# 启动 Xray
start_sing-box() {
    if systemctl is-active --quiet sing-box; then
        print_warning "Xray 已在运行"
        return 0
    fi

    print_info "启动 Xray..."
    systemctl start sing-box

    sleep 2
    if systemctl is-active --quiet sing-box; then
        print_success "Xray 启动成功"
    else
        print_error "Xray 启动失败"
        systemctl status sing-box
        return 1
    fi
}

# 停止 Xray
stop_sing-box() {
    if ! systemctl is-active --quiet sing-box; then
        print_warning "Xray 未运行"
        return 0
    fi

    print_info "停止 Xray..."
    systemctl stop sing-box

    sleep 1
    if ! systemctl is-active --quiet sing-box; then
        print_success "Xray 停止成功"
    else
        print_error "Xray 停止失败"
        return 1
    fi
}

# 重启 Xray
restart_sing-box() {
    print_info "重启 Xray..."
    systemctl restart sing-box

    sleep 2
    if systemctl is-active --quiet sing-box; then
        print_success "Xray 重启成功"
    else
        print_error "Xray 重启失败"
        systemctl status sing-box
        return 1
    fi
}

# 查看版本
show_version() {
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        print_error "Xray 未安装"
        return 1
    fi

    echo -e "${CYAN}Xray 版本信息：${NC}"
    "$SINGBOX_BIN" version
}

# 创建默认配置
create_default_config() {
    cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${SINGBOX_DIR}/access.log",
    "error": "${SINGBOX_DIR}/error.log"
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "StatsService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      }
    ]
  }
}
EOF
}

# 创建 systemd 服务
create_systemd_service() {
    cat > "$SINGBOX_SERVICE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SINGBOX_BIN} run -config ${SINGBOX_CONFIG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}
