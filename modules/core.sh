#!/bin/bash

#================================================================
# 内核管理模块
# 功能：安装、卸载、更新、启动、停止 sing-box
#================================================================

# 安装 sing-box（使用官方安装脚本）
install_sing-box() {
    print_info "开始安装 sing-box..."
    echo ""

    # 检查是否已安装
    if command -v sing-box &>/dev/null; then
        local installed_version=$(sing-box version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' || echo "unknown")
        print_warning "sing-box 已安装，版本: ${installed_version}"
        print_info "如需重新安装，请先卸载"
        return 1
    fi

    # 检查网络连接
    print_info "检查网络连接..."
    if ! curl -fsSL --connect-timeout 10 https://sing-box.app >/dev/null 2>&1; then
        print_error "无法连接到 sing-box.app，请检查网络"
        return 1
    fi

    # 选择版本
    echo -e "${CYAN}选择安装版本：${NC}"
    echo -e "  ${GREEN}1.${NC} 最新稳定版（推荐）"
    echo -e "  ${GREEN}2.${NC} 最新测试版"
    echo -e "  ${GREEN}3.${NC} 指定版本"
    echo ""
    read -p "请选择 [1-3，默认1]: " version_choice
    version_choice=${version_choice:-1}

    local install_cmd="curl -fsSL https://sing-box.app/install.sh | bash"

    case $version_choice in
        1)
            print_info "安装最新稳定版..."
            ;;
        2)
            print_info "安装最新测试版..."
            install_cmd="curl -fsSL https://sing-box.app/install.sh | bash -s -- --beta"
            ;;
        3)
            read -p "请输入版本号（如 1.9.0）: " custom_version
            if [[ -z "$custom_version" ]]; then
                print_error "版本号不能为空"
                return 1
            fi
            print_info "安装版本 ${custom_version}..."
            install_cmd="curl -fsSL https://sing-box.app/install.sh | bash -s -- --version ${custom_version}"
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac

    echo ""
    print_info "正在下载并安装 sing-box..."
    echo -e "${YELLOW}使用官方安装脚本: https://sing-box.app/install.sh${NC}"
    echo ""

    # 执行官方安装脚本
    if eval "$install_cmd"; then
        print_success "sing-box 安装完成"
    else
        print_error "sing-box 安装失败"
        return 1
    fi

    # 等待安装完成
    sleep 2

    # 获取安装的版本
    if command -v sing-box &>/dev/null; then
        local installed_version=$(sing-box version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' || echo "unknown")
        print_success "已安装版本: ${installed_version}"
    fi

    # 创建数据目录
    print_info "初始化数据目录..."
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

    # 创建配置目录（如果不存在）
    mkdir -p "$(dirname "$SINGBOX_CONFIG")"

    # 创建配置文件（简单默认配置，无节点）
    print_info "创建默认配置..."
    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        create_default_config
    fi

    # 重新加载 systemd
    print_info "重新加载 systemd..."
    systemctl daemon-reload

    # 检查 systemd 服务（多种可能的位置）
    local service_found=false
    local service_path=""

    if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
        service_found=true
        service_path="/etc/systemd/system/sing-box.service"
    elif [[ -f "/lib/systemd/system/sing-box.service" ]]; then
        service_found=true
        service_path="/lib/systemd/system/sing-box.service"
    elif [[ -f "/usr/lib/systemd/system/sing-box.service" ]]; then
        service_found=true
        service_path="/usr/lib/systemd/system/sing-box.service"
    fi

    if [[ "$service_found" == "true" ]]; then
        print_success "systemd 服务已配置: $service_path"
    else
        print_warning "官方脚本未创建 systemd 服务，正在手动创建..."
        create_systemd_service
        systemctl daemon-reload
        if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
            print_success "systemd 服务创建成功"
            service_found=true
        else
            print_error "systemd 服务创建失败"
        fi
    fi

    if [[ "$service_found" == "true" ]]; then
        # 启用并启动服务
        print_info "启用并启动服务..."
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box

        sleep 2

        # 检查服务状态
        if systemctl is-active --quiet sing-box; then
            print_success "sing-box 服务运行正常"
        else
            print_warning "服务启动失败，请检查配置"
            print_info "查看日志: journalctl -u sing-box -n 50"
            print_info "验证配置: sing-box check -c $SINGBOX_CONFIG"
            echo ""
            print_info "显示服务状态："
            systemctl status sing-box --no-pager -l | head -20
        fi
    fi

    echo ""
    print_success "安装完成！"
    echo ""
    print_info "配置文件: $SINGBOX_CONFIG"
    print_info "数据目录: $DATA_DIR"
    if [[ "$service_found" == "true" ]]; then
        print_info "服务管理: systemctl {start|stop|restart|status} sing-box"
    else
        print_warning "systemd 服务未配置，需要手动启动"
        print_info "手动启动: sing-box run -c $SINGBOX_CONFIG"
    fi
}

# 卸载 sing-box（使用包管理器）
uninstall_sing-box() {
    print_warning "开始卸载 sing-box..."
    echo ""

    # 检查是否已安装
    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box 未安装"
        return 1
    fi

    # 显示当前版本
    local installed_version=$(sing-box version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' || echo "unknown")
    print_info "当前安装版本: ${installed_version}"

    # 显示将要删除的内容
    echo ""
    echo -e "${YELLOW}将执行以下操作：${NC}"
    echo "  1. 使用包管理器卸载 sing-box"
    echo "  2. 清理配置和数据目录（可选）"
    echo ""

    read -p "确认卸载 sing-box？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        return 0
    fi

    echo ""

    # 1. 停止服务
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        print_info "停止 sing-box 服务..."
        systemctl stop sing-box
        print_success "服务已停止"
    fi

    # 2. 禁用服务
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        print_info "禁用 sing-box 服务..."
        systemctl disable sing-box 2>/dev/null
        print_success "服务已禁用"
    fi

    # 3. 使用包管理器卸载
    print_info "使用包管理器卸载 sing-box..."
    local uninstall_success=false

    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu
        print_info "检测到 APT 包管理器"
        if dpkg -l | grep -q sing-box; then
            apt-get remove -y sing-box
            apt-get purge -y sing-box  # 完全删除包括配置文件
            apt-get autoremove -y
            uninstall_success=true
        else
            print_warning "未找到 sing-box 软件包"
        fi
    elif command -v dnf &>/dev/null; then
        # RedHat/CentOS (DNF)
        print_info "检测到 DNF 包管理器"
        if dnf list installed | grep -q sing-box; then
            dnf remove -y sing-box
            uninstall_success=true
        else
            print_warning "未找到 sing-box 软件包"
        fi
    elif command -v yum &>/dev/null; then
        # RedHat/CentOS (YUM)
        print_info "检测到 YUM 包管理器"
        if yum list installed | grep -q sing-box; then
            yum remove -y sing-box
            uninstall_success=true
        else
            print_warning "未找到 sing-box 软件包"
        fi
    elif command -v pacman &>/dev/null; then
        # Arch Linux
        print_info "检测到 Pacman 包管理器"
        if pacman -Q sing-box &>/dev/null; then
            pacman -R --noconfirm sing-box
            uninstall_success=true
        else
            print_warning "未找到 sing-box 软件包"
        fi
    elif command -v opkg &>/dev/null; then
        # OpenWrt
        print_info "检测到 Opkg 包管理器"
        if opkg list-installed | grep -q sing-box; then
            opkg remove sing-box
            uninstall_success=true
        else
            print_warning "未找到 sing-box 软件包"
        fi
    fi

    # 如果包管理器卸载失败，尝试手动删除
    if [[ "$uninstall_success" == "false" ]] && command -v sing-box &>/dev/null; then
        print_warning "包管理器未找到 sing-box，尝试手动删除..."

        # 查找 sing-box 二进制位置
        local singbox_path=$(which sing-box)
        if [[ -n "$singbox_path" ]]; then
            rm -f "$singbox_path"
            print_success "已删除: $singbox_path"
        fi

        # 删除 systemd 服务
        if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
            rm -f /etc/systemd/system/sing-box.service
            print_success "已删除服务文件"
        fi
        if [[ -f "/lib/systemd/system/sing-box.service" ]]; then
            rm -f /lib/systemd/system/sing-box.service
            print_success "已删除服务文件"
        fi

        systemctl daemon-reload
    fi

    # 4. 询问是否删除配置和数据
    echo ""
    read -p "是否删除配置和数据目录？[y/N]: " delete_data
    if [[ "$delete_data" == "y" || "$delete_data" == "Y" ]]; then
        print_info "删除配置和数据目录..."

        # 删除配置目录
        if [[ -d "$SINGBOX_DIR" ]]; then
            rm -rf "$SINGBOX_DIR"
            print_success "已删除: $SINGBOX_DIR"
        fi

        # 删除系统配置（如果存在）
        if [[ -d "/etc/sing-box" ]]; then
            rm -rf /etc/sing-box
            print_success "已删除: /etc/sing-box"
        fi

        # 删除备份文件
        rm -f "${SINGBOX_DIR}.backup"* 2>/dev/null || true
        rm -f /tmp/singbox_* 2>/dev/null || true
    else
        print_info "保留配置和数据目录"
        print_info "配置目录: $SINGBOX_DIR"
    fi

    # 5. 清理 systemd
    print_info "清理 systemd..."
    systemctl daemon-reload
    systemctl reset-failed sing-box 2>/dev/null || true

    echo ""
    # 验证卸载结果
    if command -v sing-box &>/dev/null; then
        print_error "❌ 卸载未完全成功，sing-box 命令仍然存在"
        print_info "可能需要手动删除: $(which sing-box)"
        return 1
    else
        print_success "✅ sing-box 卸载完成"
        return 0
    fi
}

# 更新 sing-box（使用包管理器或官方脚本）
update_sing-box() {
    print_info "检查更新..."
    echo ""

    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box 未安装"
        return 1
    fi

    # 获取当前版本
    local current_version=$(sing-box version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' || echo "unknown")
    print_info "当前版本: ${current_version}"

    # 选择更新方式
    echo ""
    echo -e "${CYAN}选择更新方式：${NC}"
    echo -e "  ${GREEN}1.${NC} 使用包管理器更新（推荐）"
    echo -e "  ${GREEN}2.${NC} 使用官方脚本更新"
    echo -e "  ${GREEN}3.${NC} 更新到指定版本"
    echo ""
    read -p "请选择 [1-3，默认1]: " update_choice
    update_choice=${update_choice:-1}

    # 备份配置
    print_info "备份配置文件..."
    if [[ -f "$SINGBOX_CONFIG" ]]; then
        cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
        print_success "配置已备份"
    fi

    # 停止服务
    if systemctl is-active --quiet sing-box; then
        print_info "停止 sing-box 服务..."
        systemctl stop sing-box
    fi

    local update_success=false

    case $update_choice in
        1)
            print_info "使用包管理器更新..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq
                apt-get install --only-upgrade -y sing-box
                update_success=true
            elif command -v dnf &>/dev/null; then
                dnf upgrade -y sing-box
                update_success=true
            elif command -v yum &>/dev/null; then
                yum update -y sing-box
                update_success=true
            elif command -v pacman &>/dev/null; then
                pacman -Syu --noconfirm sing-box
                update_success=true
            elif command -v opkg &>/dev/null; then
                opkg update
                opkg upgrade sing-box
                update_success=true
            else
                print_warning "未检测到支持的包管理器"
                print_info "将使用官方脚本更新"
                curl -fsSL https://sing-box.app/install.sh | bash
                update_success=true
            fi
            ;;
        2)
            print_info "使用官方脚本更新..."
            curl -fsSL https://sing-box.app/install.sh | bash
            update_success=true
            ;;
        3)
            read -p "请输入目标版本号（如 1.9.0）: " target_version
            if [[ -z "$target_version" ]]; then
                print_error "版本号不能为空"
                systemctl start sing-box
                return 1
            fi
            print_info "更新到版本 ${target_version}..."
            curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$target_version"
            update_success=true
            ;;
        *)
            print_error "无效选择"
            systemctl start sing-box
            return 1
            ;;
    esac

    # 启动服务
    print_info "启动 sing-box 服务..."
    systemctl start sing-box
    sleep 2

    # 验证更新
    if command -v sing-box &>/dev/null; then
        local new_version=$(sing-box version 2>/dev/null | grep -oP 'sing-box version \K[0-9.]+' || echo "unknown")
        echo ""
        print_success "更新完成！"
        print_info "之前版本: ${current_version}"
        print_info "当前版本: ${new_version}"

        # 检查服务状态
        if systemctl is-active --quiet sing-box; then
            print_success "服务运行正常"
        else
            print_warning "服务启动失败"
            print_info "查看日志: journalctl -u sing-box -n 50"
        fi
    else
        print_error "更新失败，sing-box 命令不可用"
        return 1
    fi
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
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "direct-out"
      },
      {
        "tag": "dns-local",
        "address": "local",
        "detour": "direct-out"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns-local"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "action": "route",
        "outbound": "direct-out"
      }
    ],
    "final": "direct-out",
    "auto_detect_interface": true
  }
}
EOF
}

# 创建 systemd 服务
# 注意：官方安装脚本会自动创建服务，此函数仅用于特殊情况
create_systemd_service() {
    # 确定 sing-box 二进制路径
    local singbox_bin_path=$(which sing-box 2>/dev/null || echo "/usr/local/bin/sing-box")

    # 确定配置文件路径（优先使用官方路径）
    local config_path="$SINGBOX_CONFIG"
    if [[ -f "/etc/sing-box/config.json" ]]; then
        config_path="/etc/sing-box/config.json"
    fi

    print_info "创建 systemd 服务..."
    print_info "二进制路径: $singbox_bin_path"
    print_info "配置路径: $config_path"

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
ExecStart=${singbox_bin_path} run -c ${config_path}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}
