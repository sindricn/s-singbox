#!/bin/bash

#================================================================
# Cloudflare 隧道管理模块
# 功能：Argo 隧道管理（临时和专用）、WARP 隧道管理
#================================================================

# Cloudflared 安装路径
readonly CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
readonly CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"
readonly WARP_DIR="/opt/warp-plus"
readonly WARP_BIN="${WARP_DIR}/warp-plus"

# ============================================================================
# Cloudflared 安装管理
# ============================================================================

# 安装 cloudflared
install_cloudflared() {
    if [[ -f "$CLOUDFLARED_BIN" ]]; then
        print_warning "cloudflared 已安装"
        local version=$("$CLOUDFLARED_BIN" version 2>/dev/null || echo "unknown")
        print_info "当前版本: $version"
        return 0
    fi

    print_info "正在安装 cloudflared..."

    # 检测系统架构
    local arch=$(uname -m)
    local download_url

    case $arch in
        x86_64)
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64|arm64)
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        armv7l)
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
            ;;
        *)
            print_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac

    # 下载并安装
    if ! curl -L -o "$CLOUDFLARED_BIN" "$download_url"; then
        print_error "下载 cloudflared 失败"
        return 1
    fi

    chmod +x "$CLOUDFLARED_BIN"

    # 验证安装
    if [[ -f "$CLOUDFLARED_BIN" ]] && "$CLOUDFLARED_BIN" version &>/dev/null; then
        print_success "cloudflared 安装成功"
        local version=$("$CLOUDFLARED_BIN" version)
        print_info "版本: $version"
        return 0
    else
        print_error "cloudflared 安装失败"
        return 1
    fi
}

# 卸载 cloudflared
uninstall_cloudflared() {
    print_warning "确认要卸载 cloudflared 吗？"
    read -p "输入 yes 确认: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消"
        return 0
    fi

    # 停止所有隧道
    pkill -f cloudflared

    # 删除文件
    rm -f "$CLOUDFLARED_BIN"
    rm -rf "$CLOUDFLARED_CONFIG_DIR"

    print_success "cloudflared 已卸载"
}

# ============================================================================
# Argo 临时隧道管理
# ============================================================================

# 启动临时 Argo 隧道
start_temp_argo_tunnel() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       启动临时 Argo 隧道            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查 cloudflared 是否安装
    if [[ ! -f "$CLOUDFLARED_BIN" ]]; then
        print_warning "cloudflared 未安装"
        read -p "是否现在安装？[y/N]: " install_choice
        if [[ "$install_choice" == "y" || "$install_choice" == "Y" ]]; then
            install_cloudflared || return 1
        else
            return 1
        fi
    fi

    # 输入本地服务端口
    read -p "请输入本地服务端口 [例如: 8080]: " local_port
    if [[ -z "$local_port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 验证端口
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [[ "$local_port" -lt 1 ]] || [[ "$local_port" -gt 65535 ]]; then
        print_error "无效的端口号"
        return 1
    fi

    # 启动临时隧道
    print_info "正在启动临时 Argo 隧道..."
    print_info "映射到本地端口: $local_port"
    echo ""

    # 使用 nohup 在后台运行，并捕获输出
    local log_file="/tmp/argo-tunnel-${local_port}.log"
    nohup "$CLOUDFLARED_BIN" tunnel --url "http://localhost:${local_port}" > "$log_file" 2>&1 &
    local pid=$!

    # 等待隧道启动
    sleep 3

    # 检查进程是否还在运行
    if ! kill -0 $pid 2>/dev/null; then
        print_error "隧道启动失败"
        cat "$log_file"
        return 1
    fi

    # 从日志中提取隧道 URL
    sleep 2
    local tunnel_url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" | head -1)

    if [[ -n "$tunnel_url" ]]; then
        print_success "✅ 临时 Argo 隧道启动成功！"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "${YELLOW}隧道信息：${NC}"
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "  本地端口: ${GREEN}$local_port${NC}"
        echo -e "  公网地址: ${GREEN}$tunnel_url${NC}"
        echo -e "  进程 PID: ${GREEN}$pid${NC}"
        echo -e "  日志文件: ${GREEN}$log_file${NC}"
        echo ""
        echo -e "${YELLOW}提示：${NC}"
        echo -e "  • 这是临时隧道，重启后失效"
        echo -e "  • 使用 kill $pid 可停止隧道"
        echo -e "  • 查看日志: tail -f $log_file"
        echo ""
    else
        print_warning "隧道可能已启动，但无法获取 URL"
        print_info "请查看日志: tail -f $log_file"
    fi
}

# 查看临时隧道状态
list_temp_argo_tunnels() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       临时 Argo 隧道列表            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    local pids=$(pgrep -f "cloudflared tunnel --url")
    if [[ -z "$pids" ]]; then
        print_info "没有运行中的临时隧道"
        return 0
    fi

    echo -e "${YELLOW}运行中的临时隧道：${NC}"
    echo ""

    local count=0
    for pid in $pids; do
        ((count++))
        local cmdline=$(ps -p $pid -o args= 2>/dev/null)
        local port=$(echo "$cmdline" | grep -oP 'localhost:\K[0-9]+')
        local log_file="/tmp/argo-tunnel-${port}.log"

        echo -e "${GREEN}[$count]${NC} PID: ${CYAN}$pid${NC}"
        echo -e "    端口: ${YELLOW}$port${NC}"

        if [[ -f "$log_file" ]]; then
            local tunnel_url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" | head -1)
            if [[ -n "$tunnel_url" ]]; then
                echo -e "    URL:  ${GREEN}$tunnel_url${NC}"
            fi
        fi
        echo ""
    done

    echo -e "${YELLOW}管理操作：${NC}"
    echo -e "  停止隧道: kill <PID>"
    echo -e "  停止所有: pkill -f 'cloudflared tunnel'"
    echo ""
}

# 停止临时隧道
stop_temp_argo_tunnel() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       停止临时 Argo 隧道            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    local pids=$(pgrep -f "cloudflared tunnel --url")
    if [[ -z "$pids" ]]; then
        print_info "没有运行中的临时隧道"
        return 0
    fi

    echo -e "${YELLOW}运行中的临时隧道：${NC}"
    echo ""
    echo -e "${GREEN}0.${NC} 停止所有隧道"

    local count=0
    local pid_array=()
    for pid in $pids; do
        ((count++))
        pid_array+=("$pid")
        local cmdline=$(ps -p $pid -o args= 2>/dev/null)
        local port=$(echo "$cmdline" | grep -oP 'localhost:\K[0-9]+')
        echo -e "${GREEN}$count.${NC} PID: $pid (端口: $port)"
    done

    echo ""
    read -p "请选择要停止的隧道 [0-$count]: " choice

    if [[ "$choice" == "0" ]]; then
        pkill -f "cloudflared tunnel --url"
        print_success "所有临时隧道已停止"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
        local target_pid="${pid_array[$((choice-1))]}"
        kill "$target_pid"
        print_success "隧道 (PID: $target_pid) 已停止"
    else
        print_error "无效选择"
    fi
}

# ============================================================================
# Argo 专用隧道管理（需要 CF 账号）
# ============================================================================

# 创建专用 Argo 隧道
create_dedicated_argo_tunnel() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     创建专用 Argo 隧道（需CF账号）  ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查 cloudflared
    if [[ ! -f "$CLOUDFLARED_BIN" ]]; then
        print_warning "cloudflared 未安装"
        install_cloudflared || return 1
    fi

    # 创建配置目录
    mkdir -p "$CLOUDFLARED_CONFIG_DIR"

    # 第一步：登录 Cloudflare
    print_info "第一步：登录 Cloudflare 账号"
    echo ""
    print_warning "将打开浏览器进行授权，请完成登录"
    read -p "按 Enter 继续..."

    if ! "$CLOUDFLARED_BIN" tunnel login; then
        print_error "Cloudflare 登录失败"
        return 1
    fi

    print_success "✅ Cloudflare 登录成功"
    echo ""

    # 第二步：创建隧道
    read -p "请输入隧道名称 [例如: my-tunnel]: " tunnel_name
    if [[ -z "$tunnel_name" ]]; then
        print_error "隧道名称不能为空"
        return 1
    fi

    print_info "正在创建隧道: $tunnel_name"
    if ! "$CLOUDFLARED_BIN" tunnel create "$tunnel_name"; then
        print_error "隧道创建失败"
        return 1
    fi

    print_success "✅ 隧道创建成功"
    echo ""

    # 获取隧道 ID
    local tunnel_id=$("$CLOUDFLARED_BIN" tunnel list | grep "$tunnel_name" | awk '{print $1}')
    if [[ -z "$tunnel_id" ]]; then
        print_error "无法获取隧道 ID"
        return 1
    fi

    print_info "隧道 ID: $tunnel_id"
    echo ""

    # 第三步：配置域名
    read -p "请输入要绑定的域名 [例如: tunnel.example.com]: " tunnel_domain
    if [[ -z "$tunnel_domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 第四步：配置本地服务
    read -p "请输入本地服务端口 [例如: 8080]: " local_port
    if [[ -z "$local_port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 创建配置文件
    local config_file="${CLOUDFLARED_CONFIG_DIR}/config.yml"
    cat > "$config_file" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${CLOUDFLARED_CONFIG_DIR}/${tunnel_id}.json

ingress:
  - hostname: ${tunnel_domain}
    service: http://localhost:${local_port}
  - service: http_status:404
EOF

    print_success "✅ 配置文件已创建: $config_file"
    echo ""

    # 第五步：配置 DNS
    print_info "正在配置 DNS 记录..."
    if "$CLOUDFLARED_BIN" tunnel route dns "$tunnel_id" "$tunnel_domain"; then
        print_success "✅ DNS 记录配置成功"
    else
        print_warning "DNS 配置失败，请手动添加 DNS 记录"
        echo "  类型: CNAME"
        echo "  名称: $tunnel_domain"
        echo "  内容: ${tunnel_id}.cfargotunnel.com"
    fi

    echo ""

    # 第六步：创建 systemd 服务
    print_info "正在创建 systemd 服务..."
    local service_file="/etc/systemd/system/cloudflared-${tunnel_name}.service"
    cat > "$service_file" <<EOF
[Unit]
Description=Cloudflare Tunnel - ${tunnel_name}
After=network.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${config_file} run ${tunnel_id}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "cloudflared-${tunnel_name}.service"
    systemctl start "cloudflared-${tunnel_name}.service"

    print_success "✅ 专用 Argo 隧道创建完成！"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}隧道信息：${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "  隧道名称: ${GREEN}$tunnel_name${NC}"
    echo -e "  隧道 ID:  ${GREEN}$tunnel_id${NC}"
    echo -e "  绑定域名: ${GREEN}$tunnel_domain${NC}"
    echo -e "  本地端口: ${GREEN}$local_port${NC}"
    echo -e "  服务状态: ${GREEN}$(systemctl is-active cloudflared-${tunnel_name})${NC}"
    echo ""
    echo -e "${YELLOW}管理命令：${NC}"
    echo -e "  查看状态: systemctl status cloudflared-${tunnel_name}"
    echo -e "  查看日志: journalctl -u cloudflared-${tunnel_name} -f"
    echo -e "  重启服务: systemctl restart cloudflared-${tunnel_name}"
    echo ""
}

# 列出专用隧道
list_dedicated_argo_tunnels() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       专用 Argo 隧道列表            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -f "$CLOUDFLARED_BIN" ]]; then
        print_error "cloudflared 未安装"
        return 1
    fi

    "$CLOUDFLARED_BIN" tunnel list
}

# 删除专用隧道
delete_dedicated_argo_tunnel() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       删除专用 Argo 隧道            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -f "$CLOUDFLARED_BIN" ]]; then
        print_error "cloudflared 未安装"
        return 1
    fi

    # 列出隧道
    "$CLOUDFLARED_BIN" tunnel list
    echo ""

    read -p "请输入要删除的隧道名称: " tunnel_name
    if [[ -z "$tunnel_name" ]]; then
        print_error "隧道名称不能为空"
        return 1
    fi

    # 停止并禁用服务
    local service_name="cloudflared-${tunnel_name}.service"
    if systemctl is-active --quiet "$service_name"; then
        systemctl stop "$service_name"
        systemctl disable "$service_name"
        rm -f "/etc/systemd/system/$service_name"
        systemctl daemon-reload
    fi

    # 删除隧道
    if "$CLOUDFLARED_BIN" tunnel delete "$tunnel_name"; then
        print_success "隧道已删除: $tunnel_name"
    else
        print_error "删除失败"
    fi
}

# ============================================================================
# WARP 隧道管理
# ============================================================================

# 安装 WARP
install_warp() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         安装 WARP                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ -f "$WARP_BIN" ]]; then
        print_warning "WARP 已安装"
        return 0
    fi

    print_info "正在安装 WARP..."

    # 创建目录
    mkdir -p "$WARP_DIR"

    # 下载安装脚本
    local install_script="${WARP_DIR}/install.sh"
    if ! curl -fsSL -o "$install_script" "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"; then
        print_error "下载安装脚本失败"
        return 1
    fi

    chmod +x "$install_script"

    # 运行安装
    bash "$install_script"
}

# 卸载 WARP
uninstall_warp() {
    print_warning "确认要卸载 WARP 吗？"
    read -p "输入 yes 确认: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消"
        return 0
    fi

    # 停止 WARP
    systemctl stop warp-svc 2>/dev/null

    # 删除文件
    rm -rf "$WARP_DIR"
    rm -f /usr/local/bin/warp-cli

    print_success "WARP 已卸载"
}

# WARP 状态
warp_status() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         WARP 状态                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if ! command -v warp-cli &>/dev/null; then
        print_error "WARP 未安装"
        return 1
    fi

    warp-cli status
}

# 连接 WARP
connect_warp() {
    if ! command -v warp-cli &>/dev/null; then
        print_error "WARP 未安装"
        return 1
    fi

    print_info "正在连接 WARP..."
    warp-cli connect

    if [[ $? -eq 0 ]]; then
        print_success "WARP 已连接"
    else
        print_error "连接失败"
    fi
}

# 断开 WARP
disconnect_warp() {
    if ! command -v warp-cli &>/dev/null; then
        print_error "WARP 未安装"
        return 1
    fi

    print_info "正在断开 WARP..."
    warp-cli disconnect

    if [[ $? -eq 0 ]]; then
        print_success "WARP 已断开"
    else
        print_error "断开失败"
    fi
}

# ============================================================================
# CF 隧道主菜单
# ============================================================================

# Argo 隧道菜单
menu_argo_tunnel() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║       Argo 隧道管理                  ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 临时隧道（无需CF账号） ━━━━━━━${NC}"
        echo -e "${GREEN}1.${NC}  启动临时隧道"
        echo -e "${GREEN}2.${NC}  查看临时隧道"
        echo -e "${GREEN}3.${NC}  停止临时隧道"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 专用隧道（需要CF账号） ━━━━━━━${NC}"
        echo -e "${GREEN}4.${NC}  创建专用隧道"
        echo -e "${GREEN}5.${NC}  查看专用隧道"
        echo -e "${GREEN}6.${NC}  删除专用隧道"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 系统管理 ━━━━━━━${NC}"
        echo -e "${GREEN}7.${NC}  安装 cloudflared"
        echo -e "${GREEN}8.${NC}  卸载 cloudflared"
        echo ""
        echo -e "${GREEN}0.${NC}  返回上级菜单"
        echo ""
        read -p "请选择 [0-8]: " choice

        case $choice in
            1) start_temp_argo_tunnel; read -p "按 Enter 继续..." ;;
            2) list_temp_argo_tunnels; read -p "按 Enter 继续..." ;;
            3) stop_temp_argo_tunnel; read -p "按 Enter 继续..." ;;
            4) create_dedicated_argo_tunnel; read -p "按 Enter 继续..." ;;
            5) list_dedicated_argo_tunnels; read -p "按 Enter 继续..." ;;
            6) delete_dedicated_argo_tunnel; read -p "按 Enter 继续..." ;;
            7) install_cloudflared; read -p "按 Enter 继续..." ;;
            8) uninstall_cloudflared; read -p "按 Enter 继续..." ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# WARP 隧道菜单
menu_warp_tunnel() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║       WARP 隧道管理                  ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}1.${NC}  安装 WARP"
        echo -e "${GREEN}2.${NC}  卸载 WARP"
        echo -e "${GREEN}3.${NC}  查看状态"
        echo -e "${GREEN}4.${NC}  连接 WARP"
        echo -e "${GREEN}5.${NC}  断开 WARP"
        echo ""
        echo -e "${GREEN}0.${NC}  返回上级菜单"
        echo ""
        read -p "请选择 [0-5]: " choice

        case $choice in
            1) install_warp; read -p "按 Enter 继续..." ;;
            2) uninstall_warp; read -p "按 Enter 继续..." ;;
            3) warp_status; read -p "按 Enter 继续..." ;;
            4) connect_warp; read -p "按 Enter 继续..." ;;
            5) disconnect_warp; read -p "按 Enter 继续..." ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# CF 隧道主菜单
menu_cf_tunnel() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║     Cloudflare 隧道管理              ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}1.${NC}  Argo 隧道管理"
        echo -e "${GREEN}2.${NC}  WARP 隧道管理"
        echo ""
        echo -e "${GREEN}0.${NC}  返回主菜单"
        echo ""
        read -p "请选择 [0-2]: " choice

        case $choice in
            1) menu_argo_tunnel ;;
            2) menu_warp_tunnel ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}
