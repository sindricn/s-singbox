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

# Argo隧道保活脚本路径
readonly ARGO_KEEPALIVE_SCRIPT="/usr/local/bin/argo-keepalive.sh"

# 创建Argo隧道保活脚本
create_argo_keepalive_script() {
    cat > "$ARGO_KEEPALIVE_SCRIPT" << 'EOF'
#!/bin/bash
# Argo临时隧道保活脚本
# 每5分钟检查一次隧道状态，如果隧道进程消失则自动重启

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
DATA_DIR="/var/lib/sing-box/data"
TUNNELS_FILE="${DATA_DIR}/argo_temp_tunnels.json"

# 检查并重启隧道
check_and_restart_tunnels() {
    [[ ! -f "$TUNNELS_FILE" ]] && return

    while IFS= read -r tunnel; do
        local pid=$(echo "$tunnel" | jq -r '.pid')
        local port=$(echo "$tunnel" | jq -r '.port')
        local log_file="/tmp/argo-tunnel-${port}.log"

        # 检查进程是否存在
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "[$(date)] 隧道PID $pid (端口$port) 已停止，正在重启..."

            # 重启隧道
            nohup "$CLOUDFLARED_BIN" tunnel --url "http://localhost:${port}" > "$log_file" 2>&1 &
            local new_pid=$!

            # 等待启动
            sleep 3

            if kill -0 "$new_pid" 2>/dev/null; then
                # 更新PID
                local tmp_file=$(mktemp)
                jq --arg old_pid "$pid" --arg new_pid "$new_pid" \
                   '(.tunnels[] | select(.pid == $old_pid)) |= (.pid = $new_pid)' \
                   "$TUNNELS_FILE" > "$tmp_file" && mv "$tmp_file" "$TUNNELS_FILE"

                echo "[$(date)] 隧道已重启，新PID: $new_pid"
            else
                echo "[$(date)] 隧道重启失败"
            fi
        fi
    done < <(jq -c '.tunnels[]' "$TUNNELS_FILE" 2>/dev/null)
}

# 主循环
while true; do
    check_and_restart_tunnels
    sleep 300  # 5分钟
done
EOF

    chmod +x "$ARGO_KEEPALIVE_SCRIPT"
}

# 启动保活服务
start_argo_keepalive_service() {
    # 检查保活脚本是否存在
    if [[ ! -f "$ARGO_KEEPALIVE_SCRIPT" ]]; then
        create_argo_keepalive_script
    fi

    # 检查服务是否已运行
    if pgrep -f "argo-keepalive.sh" > /dev/null; then
        return 0
    fi

    # 启动保活服务
    nohup "$ARGO_KEEPALIVE_SCRIPT" > /dev/null 2>&1 &
    print_info "Argo隧道保活服务已启动"
}

# 停止保活服务
stop_argo_keepalive_service() {
    pkill -f "argo-keepalive.sh"
    print_info "Argo隧道保活服务已停止"
}

# 记录临时隧道信息
# 参数: $1=pid, $2=port
save_temp_tunnel_info() {
    local pid=$1
    local port=$2
    local tunnels_file="${DATA_DIR}/argo_temp_tunnels.json"

    # 初始化文件
    if [[ ! -f "$tunnels_file" ]]; then
        echo '{"tunnels":[]}' > "$tunnels_file"
    fi

    # 添加隧道信息
    local tmp_file=$(mktemp)
    jq --arg pid "$pid" --arg port "$port" \
       '.tunnels += [{pid: $pid, port: $port, created: now}]' \
       "$tunnels_file" > "$tmp_file" && mv "$tmp_file" "$tunnels_file"
}

# 移除临时隧道信息
remove_temp_tunnel_info() {
    local pid=$1
    local tunnels_file="${DATA_DIR}/argo_temp_tunnels.json"

    if [[ -f "$tunnels_file" ]]; then
        local tmp_file=$(mktemp)
        jq --arg pid "$pid" 'del(.tunnels[] | select(.pid == $pid))' \
           "$tunnels_file" > "$tmp_file" && mv "$tmp_file" "$tunnels_file"
    fi
}

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

    # 询问是直接指定端口还是选择节点
    echo ""
    echo -e "${YELLOW}隧道配置方式：${NC}"
    echo -e "${GREEN}1.${NC} 选择已有节点（推荐）"
    echo -e "${GREEN}2.${NC} 手动指定端口"
    echo ""
    read -p "请选择 [1-2]: " config_choice

    local local_port=""
    local selected_node_port=""
    local bind_to_node=false

    if [[ "$config_choice" == "1" ]]; then
        # 选择节点模式
        local nodes_file="${DATA_DIR}/nodes.json"
        if [[ ! -f "$nodes_file" ]]; then
            print_error "节点文件不存在，请先创建节点"
            return 1
        fi

        local nodes=$(jq -r '.nodes[] | "\(.port)|\(.protocol)|\(.tag // "N/A")"' "$nodes_file" 2>/dev/null)
        if [[ -z "$nodes" ]]; then
            print_error "没有可用节点，请先创建节点"
            return 1
        fi

        echo ""
        echo -e "${YELLOW}可用节点：${NC}"
        local index=1
        echo "$nodes" | while IFS='|' read -r port protocol tag; do
            echo -e "${GREEN}$index.${NC} 端口: $port | 协议: $protocol | 标签: $tag"
            ((index++))
        done
        echo ""
        read -p "请选择节点 [1-$(echo "$nodes" | wc -l)]: " node_choice

        if [[ "$node_choice" =~ ^[0-9]+$ ]]; then
            selected_node_port=$(echo "$nodes" | sed -n "${node_choice}p" | cut -d'|' -f1)
            if [[ -n "$selected_node_port" ]]; then
                local_port=$selected_node_port
                bind_to_node=true
                print_info "已选择节点端口: $local_port"
            else
                print_error "无效的节点选择"
                return 1
            fi
        else
            print_error "无效的选择"
            return 1
        fi
    else
        # 手动指定端口模式
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
    fi

    # 启动临时隧道
    print_info "正在启动临时 Argo 隧道..."
    print_info "映射到本地端口: $local_port"
    echo ""

    # 使用 nohup 在后台运行，并捕获输出
    local log_file="/tmp/argo-tunnel-${local_port}.log"
    nohup "$CLOUDFLARED_BIN" tunnel --url "http://localhost:${local_port}" > "$log_file" 2>&1 &
    local pid=$!

    # 记录隧道信息用于保活
    save_temp_tunnel_info "$pid" "$local_port"

    # 启动保活服务（如果未启动）
    start_argo_keepalive_service

    # 等待隧道启动
    sleep 3

    # 检查进程是否还在运行
    if ! kill -0 $pid 2>/dev/null; then
        print_error "隧道启动失败"
        cat "$log_file"
        remove_temp_tunnel_info "$pid"
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
        echo -e "${YELLOW}访问流程：${NC}"
        echo -e "  用户 → ${GREEN}$tunnel_url${NC} (Argo隧道) → localhost:$local_port (节点监听)"
        echo ""
        echo -e "${YELLOW}提示：${NC}"
        echo -e "  • 这是临时隧道，重启后域名会变化"
        echo -e "  • 使用 kill $pid 可停止隧道"
        echo -e "  • 查看日志: tail -f $log_file"
        echo -e "  • 建议使用专用隧道以获得固定域名"
        echo ""

        # 如果是绑定到节点模式，更新节点配置
        if [[ "$bind_to_node" == true ]]; then
            local nodes_file="${DATA_DIR}/nodes.json"
            jq --arg port "$selected_node_port" \
               --arg domain "$tunnel_url" \
               --arg pid "$pid" \
               '(.nodes[] | select(.port == $port)) |= (
                   . + {
                       tunnel_domain: $domain,
                       tunnel_name: ("temp-tunnel-" + $pid),
                       tunnel_type: "argo_temp"
                   }
               )' \
               "$nodes_file" > "${nodes_file}.tmp" && mv "${nodes_file}.tmp" "$nodes_file"

            print_success "✅ 临时隧道已绑定到节点(端口:$selected_node_port)"
            echo ""
            echo -e "${YELLOW}说明：${NC}"
            echo -e "  • 节点监听在 localhost:$selected_node_port"
            echo -e "  • Argo隧道转发 $tunnel_url → localhost:$selected_node_port"
            echo -e "  • 外部用户通过 $tunnel_url 访问此节点"
        fi
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
        # 停止所有隧道并清理保活记录
        for pid in $pids; do
            remove_temp_tunnel_info "$pid"
        done
        pkill -f "cloudflared tunnel --url"
        print_success "所有临时隧道已停止"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
        local target_pid="${pid_array[$((choice-1))]}"
        # 移除保活记录
        remove_temp_tunnel_info "$target_pid"
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

    # 第四步：选择要关联的节点端口
    echo ""
    echo -e "${YELLOW}请选择隧道要转发到的节点：${NC}"
    echo ""

    # 检查节点文件
    local nodes_file="${DATA_DIR}/nodes.json"
    local local_port=""

    if [[ -f "$nodes_file" ]]; then
        # 列出现有节点
        local nodes=$(jq -r '.nodes[] | "\(.port)|\(.protocol)|\(.tag // "N/A")"' "$nodes_file" 2>/dev/null)

        if [[ -n "$nodes" ]]; then
            local index=1
            echo "$nodes" | while IFS='|' read -r port protocol tag; do
                echo -e "${GREEN}$index.${NC} 端口: $port | 协议: $protocol | 标签: $tag"
                ((index++))
            done

            echo -e "${GREEN}0.${NC} 手动输入端口"
            echo ""
            read -p "请选择 [0-$(echo "$nodes" | wc -l)]: " node_choice

            if [[ "$node_choice" == "0" ]]; then
                read -p "请输入本地服务端口 [例如: 8080]: " local_port
            else
                local_port=$(echo "$nodes" | sed -n "${node_choice}p" | cut -d'|' -f1)
            fi
        else
            read -p "没有现有节点，请输入本地服务端口 [例如: 8080]: " local_port
        fi
    else
        read -p "请输入本地服务端口 [例如: 8080]: " local_port
    fi

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

    # 自动将隧道域名记录到节点配置中
    echo ""
    if [[ -f "$nodes_file" ]]; then
        # 检查该端口是否对应一个节点
        local node_exists=$(jq -r ".nodes[] | select(.port == \"$local_port\") | .port" "$nodes_file" 2>/dev/null)

        if [[ -n "$node_exists" ]]; then
            print_info "检测到节点端口 $local_port，将隧道域名关联到该节点..."

            # 在节点中添加tunnel_domain字段
            jq --arg port "$local_port" \
               --arg domain "$tunnel_domain" \
               --arg tunnel_name "$tunnel_name" \
               '(.nodes[] | select(.port == $port)) |= (
                   . + {
                       tunnel_domain: $domain,
                       tunnel_name: $tunnel_name,
                       tunnel_type: "argo_dedicated"
                   }
               )' \
               "$nodes_file" > "${nodes_file}.tmp" && mv "${nodes_file}.tmp" "$nodes_file"

            print_success "✅ 隧道域名已关联到节点"
            echo ""
            echo -e "${YELLOW}访问流程：${NC}"
            echo -e "  用户 → ${GREEN}$tunnel_domain${NC} (Argo隧道) → 本地节点(端口:$local_port)"
            echo ""
            echo -e "${YELLOW}提示：${NC}"
            echo -e "  • 用户通过 ${GREEN}$tunnel_domain${NC} 访问此节点"
            echo -e "  • 生成节点分享链接时，将使用隧道域名"
            echo -e "  • 需要重新生成配置和分享链接"
        else
            print_info "端口 $local_port 未匹配到现有节点"
            echo -e "${YELLOW}访问流程：${NC}"
            echo -e "  用户 → ${GREEN}$tunnel_domain${NC} (Argo隧道) → 本地服务(端口:$local_port)"
        fi
    fi
}

# 将隧道域名关联到现有节点
bind_tunnel_to_node() {
    local tunnel_name=$1
    local tunnel_domain=$2

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       关联隧道到节点                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查 nodes.json 是否存在
    local nodes_file="${DATA_DIR}/nodes.json"
    if [[ ! -f "$nodes_file" ]]; then
        print_error "节点文件不存在，请先创建节点"
        return 1
    fi

    # 列出现有节点
    echo -e "${YELLOW}现有节点：${NC}"
    local nodes=$(jq -r '.nodes[] | "\(.port)|\(.protocol)|\(.tag // "N/A")"' "$nodes_file" 2>/dev/null)

    if [[ -z "$nodes" ]]; then
        print_error "没有可用节点"
        return 1
    fi

    local index=1
    echo "$nodes" | while IFS='|' read -r port protocol tag; do
        echo -e "${GREEN}$index.${NC} 端口: $port | 协议: $protocol | 标签: $tag"
        ((index++))
    done

    echo ""
    read -p "请选择要关联的节点编号: " node_choice

    # 获取选中节点的端口
    local selected_port=$(echo "$nodes" | sed -n "${node_choice}p" | cut -d'|' -f1)

    if [[ -z "$selected_port" ]]; then
        print_error "无效选择"
        return 1
    fi

    # 更新节点配置，添加隧道域名
    jq --arg port "$selected_port" \
       --arg domain "$tunnel_domain" \
       --arg tunnel_name "$tunnel_name" \
       '(.nodes[] | select(.port == $port)) |= (
           . + {
               tunnel_domain: $domain,
               tunnel_name: $tunnel_name,
               tunnel_type: "argo_dedicated"
           }
       )' \
       "$nodes_file" > "${nodes_file}.tmp" && mv "${nodes_file}.tmp" "$nodes_file"

    print_success "✅ 隧道域名已关联到节点 (端口: $selected_port)"
    echo ""
    echo -e "${YELLOW}访问流程：${NC}"
    echo -e "  用户 → ${GREEN}$tunnel_domain${NC} (Argo隧道) → 节点(端口:$selected_port)"
    echo ""
    echo -e "${YELLOW}提示：${NC}"
    echo -e "  • 用户将通过隧道域名访问此节点"
    echo -e "  • 需要重新生成节点配置和分享链接"
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

# 管理隧道节点绑定
manage_tunnel_node_binding() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    管理隧道-节点绑定关系            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查节点文件
    local nodes_file="${DATA_DIR}/nodes.json"
    if [[ ! -f "$nodes_file" ]]; then
        print_error "节点文件不存在"
        return 1
    fi

    echo -e "${YELLOW}请选择操作：${NC}"
    echo -e "${GREEN}1.${NC} 绑定隧道到节点"
    echo -e "${GREEN}2.${NC} 查看节点绑定状态"
    echo -e "${GREEN}3.${NC} 解除节点绑定"
    echo ""
    read -p "请选择 [1-3]: " action

    case $action in
        1)
            # 列出所有可用隧道（临时+专用）
            echo ""
            echo -e "${YELLOW}━━━━━━━ 可用隧道列表 ━━━━━━━${NC}"
            echo ""

            # 收集所有隧道
            declare -a tunnel_list
            declare -a tunnel_types
            declare -a tunnel_urls
            local index=1

            # 1. 临时隧道（从进程获取）
            local temp_pids=$(pgrep -f "cloudflared tunnel --url" 2>/dev/null)
            if [[ -n "$temp_pids" ]]; then
                echo -e "${CYAN}临时隧道：${NC}"
                for pid in $temp_pids; do
                    local cmdline=$(ps -p $pid -o args= 2>/dev/null)
                    local port=$(echo "$cmdline" | grep -oP 'localhost:\K\d+')
                    local log_file="/tmp/argo-tunnel-${port}.log"

                    if [[ -f "$log_file" ]]; then
                        local url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" | head -1)
                        if [[ -n "$url" ]]; then
                            echo -e "${GREEN}$index.${NC} [临时] 端口:$port → $url (PID:$pid)"
                            tunnel_list[$index]="temp-$pid"
                            tunnel_types[$index]="temp"
                            tunnel_urls[$index]="$url"
                            ((index++))
                        fi
                    fi
                done
                echo ""
            fi

            # 2. 专用隧道（从cloudflared获取）
            if [[ -f "$CLOUDFLARED_BIN" ]]; then
                local dedicated_tunnels=$("$CLOUDFLARED_BIN" tunnel list 2>/dev/null | tail -n +2 | awk '{print $2}')
                if [[ -n "$dedicated_tunnels" ]]; then
                    echo -e "${CYAN}专用隧道：${NC}"
                    for tname in $dedicated_tunnels; do
                        # 从配置文件获取域名
                        local config_file="${CLOUDFLARED_CONFIG_DIR}/config.yml"
                        if [[ -f "$config_file" ]]; then
                            local domain=$(grep "hostname:" "$config_file" | head -1 | awk '{print $2}')
                            echo -e "${GREEN}$index.${NC} [专用] $tname → ${domain:-未配置域名}"
                            tunnel_list[$index]="$tname"
                            tunnel_types[$index]="dedicated"
                            tunnel_urls[$index]="${domain:-}"
                            ((index++))
                        fi
                    done
                    echo ""
                fi
            fi

            if [[ ${#tunnel_list[@]} -eq 0 ]]; then
                print_info "没有可用的隧道"
                return 0
            fi

            echo ""
            read -p "请选择隧道 [1-$((index-1))]: " tunnel_choice

            if [[ ! "$tunnel_choice" =~ ^[0-9]+$ ]] || [[ "$tunnel_choice" -lt 1 ]] || [[ "$tunnel_choice" -ge $index ]]; then
                print_error "无效选择"
                return 1
            fi

            local selected_tunnel="${tunnel_list[$tunnel_choice]}"
            local selected_type="${tunnel_types[$tunnel_choice]}"
            local selected_url="${tunnel_urls[$tunnel_choice]}"

            # 列出节点供选择
            echo ""
            echo -e "${YELLOW}可用节点：${NC}"
            local nodes=$(jq -r '.nodes[] | "\(.port)|\(.protocol)|\(.tag // "N/A")"' "$nodes_file" 2>/dev/null)

            if [[ -z "$nodes" ]]; then
                print_error "没有可用节点"
                return 1
            fi

            index=1
            echo "$nodes" | while IFS='|' read -r port protocol tag; do
                echo -e "${GREEN}$index.${NC} 端口: $port | 协议: $protocol | 标签: $tag"
                ((index++))
            done

            echo ""
            read -p "请选择节点 [1-$(echo "$nodes" | wc -l)]: " node_choice

            if [[ ! "$node_choice" =~ ^[0-9]+$ ]]; then
                print_error "无效选择"
                return 1
            fi

            local selected_port=$(echo "$nodes" | sed -n "${node_choice}p" | cut -d'|' -f1)

            if [[ -z "$selected_port" ]]; then
                print_error "无效选择"
                return 1
            fi

            # 绑定隧道到节点
            jq --arg port "$selected_port" \
               --arg domain "$selected_url" \
               --arg tunnel_name "$selected_tunnel" \
               --arg tunnel_type "argo_$selected_type" \
               '(.nodes[] | select(.port == $port)) |= (
                   . + {
                       tunnel_domain: $domain,
                       tunnel_name: $tunnel_name,
                       tunnel_type: $tunnel_type
                   }
               )' \
               "$nodes_file" > "${nodes_file}.tmp" && mv "${nodes_file}.tmp" "$nodes_file"

            print_success "✅ 隧道已绑定到节点(端口:$selected_port)"
            echo ""
            echo -e "${YELLOW}访问流程：${NC}"
            echo -e "  用户 → ${GREEN}$selected_url${NC} ($selected_type隧道) → 节点端口($selected_port)"
            ;;

        2)
            # 查看绑定状态
            echo ""
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo -e "${YELLOW}节点绑定状态：${NC}"
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo ""

            local has_binding=false
            jq -r '.nodes[] | select(.tunnel_domain != null) | "\(.port)|\(.protocol)|\(.tunnel_type // "N/A")|\(.tunnel_name // "N/A")|\(.tunnel_domain)"' "$nodes_file" 2>/dev/null | while IFS='|' read -r port protocol tunnel_type tunnel_name tunnel_domain; do
                has_binding=true
                echo -e "${GREEN}端口:${NC} $port"
                echo -e "${GREEN}协议:${NC} $protocol"
                echo -e "${GREEN}隧道类型:${NC} $tunnel_type"
                echo -e "${GREEN}隧道名称:${NC} $tunnel_name"
                echo -e "${GREEN}隧道域名:${NC} $tunnel_domain"
                echo -e "${YELLOW}访问流程:${NC} 用户 → $tunnel_domain → 节点($port)"
                echo ""
            done

            if [[ "$has_binding" == "false" ]]; then
                print_info "没有节点绑定隧道"
            fi
            ;;

        3)
            # 解除绑定
            echo ""
            echo -e "${YELLOW}已绑定隧道的节点：${NC}"

            local bound_nodes=$(jq -r '.nodes[] | select(.tunnel_domain != null) | "\(.port)|\(.protocol)|\(.tunnel_name // "N/A")"' "$nodes_file" 2>/dev/null)

            if [[ -z "$bound_nodes" ]]; then
                print_info "没有节点绑定隧道"
                return 0
            fi

            local index=1
            echo "$bound_nodes" | while IFS='|' read -r port protocol tunnel_name; do
                echo -e "${GREEN}$index.${NC} 端口: $port | 协议: $protocol | 隧道: $tunnel_name"
                ((index++))
            done

            echo ""
            read -p "请选择要解除绑定的节点编号: " unbind_choice

            local selected_port=$(echo "$bound_nodes" | sed -n "${unbind_choice}p" | cut -d'|' -f1)

            if [[ -z "$selected_port" ]]; then
                print_error "无效选择"
                return 1
            fi

            # 移除隧道配置字段
            jq --arg port "$selected_port" \
               '(.nodes[] | select(.port == $port)) |= del(.tunnel_domain, .tunnel_name, .tunnel_type)' \
               "$nodes_file" > "${nodes_file}.tmp" && mv "${nodes_file}.tmp" "$nodes_file"

            print_success "已解除节点 $selected_port 的隧道绑定"
            ;;

        *)
            print_error "无效选择"
            ;;
    esac
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
# WARP 隧道管理（使用 wgcf）
# ============================================================================

readonly WGCF_BIN="/usr/local/bin/wgcf"
readonly WGCF_CONFIG_DIR="/etc/wireguard"
readonly WGCF_PROFILE="${WGCF_CONFIG_DIR}/wgcf-profile.conf"
readonly WGCF_ACCOUNT="${WGCF_CONFIG_DIR}/wgcf-account.toml"
readonly WGCF_VERSION_FILE="${WGCF_CONFIG_DIR}/wgcf-version.txt"

# 获取 wgcf 版本号
get_wgcf_version() {
    # 优先从版本文件读取
    if [[ -f "$WGCF_VERSION_FILE" ]]; then
        cat "$WGCF_VERSION_FILE" 2>/dev/null
        return 0
    fi

    # 如果版本文件不存在，尝试从帮助输出提取（兼容旧版本）
    if [[ -f "$WGCF_BIN" ]]; then
        local help_output=$("$WGCF_BIN" 2>&1)
        local version=$(echo "$help_output" | grep -oE '([0-9]+\.[0-9]+\.[0-9]+)' | head -1)

        if [[ -z "$version" ]]; then
            version=$(echo "$help_output" | head -1 | grep -oE '([0-9]+\.[0-9]+\.[0-9]+)')
        fi

        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi

    echo "unknown"
    return 1
}

# 保存 wgcf 版本号
save_wgcf_version() {
    local version=$1
    if [[ -n "$version" ]]; then
        mkdir -p "$WGCF_CONFIG_DIR"
        echo "$version" > "$WGCF_VERSION_FILE"
    fi
}

# 安装 wgcf
install_wgcf() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         安装 wgcf (WARP)             ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # ========================================
    # 步骤 1: 检查是否已安装
    # ========================================
    if [[ -f "$WGCF_BIN" ]]; then
        print_warning "wgcf 已安装"

        # 使用统一的版本获取函数
        local current_version=$(get_wgcf_version)

        if [[ "$current_version" != "unknown" ]]; then
            print_info "当前版本: v$current_version"
        else
            print_info "无法获取版本信息"
        fi

        return 0
    fi

    # ========================================
    # 步骤 2: 安装 wgcf 二进制文件
    # ========================================
    print_info "正在获取 wgcf 最新版本..."

    # 从GitHub API获取最新版本
    local latest_release=$(curl -sSL "https://api.github.com/repos/ViRb3/wgcf/releases/latest" 2>/dev/null)
    local wgcf_version=$(echo "$latest_release" | grep -oP '"tag_name":\s*"v\K[^"]+' 2>/dev/null)

    # 如果获取失败，使用默认版本
    if [[ -z "$wgcf_version" ]]; then
        wgcf_version="2.2.29"
        print_warning "无法获取最新版本，使用默认版本: $wgcf_version"
    else
        print_info "最新版本: v$wgcf_version"
    fi

    # 检测系统架构
    local arch=$(uname -m)
    local binary_name=""

    case $arch in
        x86_64)       binary_name="wgcf_${wgcf_version}_linux_amd64" ;;
        aarch64|arm64) binary_name="wgcf_${wgcf_version}_linux_arm64" ;;
        armv7l|armv7)  binary_name="wgcf_${wgcf_version}_linux_armv7" ;;
        armv6l)       binary_name="wgcf_${wgcf_version}_linux_armv6" ;;
        i386|i686)    binary_name="wgcf_${wgcf_version}_linux_386" ;;
        *)
            print_error "不支持的系统架构: $arch"
            print_info "支持的架构: x86_64, aarch64, arm64, armv7l, armv6l, i386, i686"
            return 1
            ;;
    esac

    local download_url="https://github.com/ViRb3/wgcf/releases/download/v${wgcf_version}/${binary_name}"
    print_info "下载链接: $download_url"

    # 下载wgcf
    if ! curl -sSL -o "$WGCF_BIN" "$download_url"; then
        print_error "下载失败"
        print_info "请检查网络连接或手动下载: $download_url"
        [[ -f "$WGCF_BIN" ]] && rm -f "$WGCF_BIN"
        return 1
    fi

    # 设置执行权限
    chmod +x "$WGCF_BIN"

    # 验证文件完整性
    local file_size=$(stat -c%s "$WGCF_BIN" 2>/dev/null || stat -f%z "$WGCF_BIN" 2>/dev/null)
    if [[ -z "$file_size" ]] || [[ "$file_size" -lt 1000000 ]]; then
        print_error "下载的文件大小异常: ${file_size:-0} bytes（预期 >1MB）"
        print_info "可能原因：网络中断、GitHub访问受限"
        rm -f "$WGCF_BIN"
        return 1
    fi

    print_success "✅ wgcf 二进制文件下载完成"

    # ========================================
    # 步骤 3: 安装 WireGuard 工具（必需）
    # ========================================
    print_info "正在检查 WireGuard 工具..."

    if ! command -v wg-quick &>/dev/null; then
        print_info "wg-quick 未安装，正在安装 wireguard-tools..."

        if command -v apt-get &>/dev/null; then
            if apt-get update >/dev/null 2>&1 && apt-get install -y wireguard-tools openresolv >/dev/null 2>&1; then
                print_success "✅ wireguard-tools 和 openresolv 安装成功 (apt)"
            else
                print_error "wireguard-tools 安装失败"
                print_info "请手动执行: apt-get install wireguard-tools"
                return 1
            fi
        elif command -v yum &>/dev/null; then
            if yum install -y wireguard-tools openresolv >/dev/null 2>&1; then
                print_success "✅ wireguard-tools 和 openresolv 安装成功 (yum)"
            else
                print_error "wireguard-tools 安装失败"
                print_info "请手动执行: yum install wireguard-tools"
                return 1
            fi
        else
            print_error "无法自动安装 wireguard-tools"
            print_info "请根据您的系统手动安装 wireguard-tools 包"
            return 1
        fi

        # 再次验证wg-quick是否可用
        if ! command -v wg-quick &>/dev/null; then
            print_error "wireguard-tools 安装后 wg-quick 仍不可用"
            return 1
        fi
    else
        print_success "✅ WireGuard 工具已安装"
    fi

    # 检查并安装 openresolv（如果缺失）
    if ! command -v resolvconf &>/dev/null; then
        print_info "正在安装 openresolv..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y openresolv >/dev/null 2>&1 && print_success "✅ openresolv 安装成功"
        elif command -v yum &>/dev/null; then
            yum install -y openresolv >/dev/null 2>&1 && print_success "✅ openresolv 安装成功"
        fi
    fi

    # ========================================
    # 步骤 4: 创建配置目录
    # ========================================
    mkdir -p "$WGCF_CONFIG_DIR"

    # ========================================
    # 步骤 5: 验证 wgcf 可执行性
    # ========================================
    print_info "正在验证 wgcf..."

    # 测试执行 - wgcf不带参数显示帮助
    local test_output=$("$WGCF_BIN" 2>&1)
    local exit_code=$?

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}wgcf 实际输出（前10行）：${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "$test_output" | head -10
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 检查执行是否成功（帮助信息通常返回0或1，都算正常）
    if [[ $exit_code -gt 1 ]]; then
        print_error "wgcf 执行异常 (退出码: $exit_code)"
        print_info "架构: $(uname -m)"
        print_info "文件类型: $(file "$WGCF_BIN" 2>/dev/null || echo 'unknown')"
        return 1
    fi

    # 从帮助输出中提取实际版本号
    # 尝试多种模式匹配版本号
    local installed_version=$(echo "$test_output" | grep -oE '([0-9]+\.[0-9]+\.[0-9]+)' | head -1)

    if [[ -z "$installed_version" ]]; then
        # 如果第一种方法失败，尝试从第一行提取
        installed_version=$(echo "$test_output" | head -1 | grep -oE '([0-9]+\.[0-9]+\.[0-9]+)')
    fi

    if [[ -z "$installed_version" ]]; then
        # 如果还是无法提取，使用下载的版本号
        installed_version="$wgcf_version"
    fi

    # 保存版本号到文件，供后续使用
    save_wgcf_version "$installed_version"

    # ========================================
    # 步骤 6: 安装完成
    # ========================================
    print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "✅ wgcf 安装完成"
    print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${YELLOW}安装信息：${NC}"
    echo -e "  wgcf 位置: ${GREEN}$WGCF_BIN${NC}"
    echo -e "  安装版本: ${GREEN}v$installed_version${NC}"
    echo -e "  配置目录: ${GREEN}$WGCF_CONFIG_DIR${NC}"
    echo ""
    echo -e "${YELLOW}下一步操作：${NC}"
    echo -e "  1. 注册 WARP 账号: 选择菜单中的 '注册 WARP 账号'"
    echo -e "  2. 生成配置文件: 选择 '生成 WireGuard 配置'"
    echo -e "  3. 启动 WARP 连接: 选择 '启动 WARP 连接'"
    echo ""

    return 0
}

# 注册 WARP 账号
register_warp() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       注册 WARP 账号                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -f "$WGCF_BIN" ]]; then
        print_error "wgcf 未安装"
        return 1
    fi

    # 检查是否已注册
    if [[ -f "$WGCF_ACCOUNT" ]]; then
        print_warning "WARP 账号已存在"
        read -p "是否重新注册？[y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            return 0
        fi
        rm -f "$WGCF_ACCOUNT"
    fi

    print_info "正在注册 WARP 账号..."
    cd "$WGCF_CONFIG_DIR" || return 1

    if "$WGCF_BIN" register --accept-tos; then
        print_success "✅ WARP 账号注册成功"

        # 显示账号信息
        if [[ -f "$WGCF_ACCOUNT" ]]; then
            echo ""
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo -e "${YELLOW}账号信息：${NC}"
            local device_id=$(grep "device_id" "$WGCF_ACCOUNT" | cut -d'"' -f2)
            local access_token=$(grep "access_token" "$WGCF_ACCOUNT" | cut -d'"' -f2)
            echo -e "  设备 ID: ${GREEN}$device_id${NC}"
            echo -e "  访问令牌: ${GREEN}${access_token:0:20}...${NC}"
            echo ""
        fi
    else
        print_error "WARP 账号注册失败"
        return 1
    fi
}

# 生成 WireGuard 配置
generate_warp_config() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    生成 WARP WireGuard 配置          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -f "$WGCF_BIN" ]]; then
        print_error "wgcf 未安装"
        return 1
    fi

    if [[ ! -f "$WGCF_ACCOUNT" ]]; then
        print_error "WARP 账号不存在，请先注册"
        return 1
    fi

    print_info "正在生成 WireGuard 配置..."
    cd "$WGCF_CONFIG_DIR" || return 1

    if "$WGCF_BIN" generate; then
        # 移动配置文件
        if [[ -f "wgcf-profile.conf" ]]; then
            mv wgcf-profile.conf "$WGCF_PROFILE"
            print_success "✅ WireGuard 配置生成成功"
            echo ""
            echo -e "${YELLOW}配置文件位置: ${GREEN}$WGCF_PROFILE${NC}"
        fi
    else
        print_error "配置生成失败"
        return 1
    fi
}

# 启动 WARP 连接
start_warp() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         启动 WARP 连接               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限才能启动 WARP 连接"
        print_info "请使用 sudo 运行此脚本"
        return 1
    fi

    if [[ ! -f "$WGCF_PROFILE" ]]; then
        print_error "WARP 配置不存在，请先生成配置"
        return 1
    fi

    # 检查 wg-quick 是否安装
    if ! command -v wg-quick &>/dev/null; then
        print_error "wg-quick 未安装，请先安装 wireguard-tools"
        return 1
    fi

    # ========================================
    # 环境检查
    # ========================================
    print_info "正在检查系统环境..."

    # 1. 检查 WireGuard 内核模块
    if ! lsmod | grep -q wireguard; then
        print_warning "WireGuard 内核模块未加载，尝试加载..."
        if ! modprobe wireguard 2>/dev/null; then
            print_error "无法加载 WireGuard 内核模块"
            print_info "请确保内核支持 WireGuard 或安装 wireguard-dkms"
            print_info "  Ubuntu/Debian: apt install wireguard-dkms"
            print_info "  CentOS/RHEL: yum install wireguard-dkms"
            return 1
        fi
        print_success "✅ WireGuard 内核模块已加载"
    fi

    # 2. 检查并启用 IPv6
    local ipv6_available=false
    if [[ -d /proc/sys/net/ipv6 ]]; then
        # 尝试启用 IPv6
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null

        # 验证 IPv6 是否真的可用
        sleep 1
        if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == "0" ]]; then
            ipv6_available=true
            print_success "✅ IPv6 已启用"
        else
            print_warning "⚠️  IPv6 启用失败，将使用纯 IPv4 模式"
        fi
    else
        print_warning "⚠️  系统不支持 IPv6，将使用纯 IPv4 模式"
    fi

    # 3. 检查是否已有同名接口
    if ip link show wgcf &>/dev/null; then
        print_warning "接口 wgcf 已存在，尝试先删除..."
        ip link delete wgcf 2>/dev/null
    fi

    # ========================================
    # 准备配置文件
    # ========================================
    print_info "正在准备配置文件..."

    # 复制配置到标准位置
    cp "$WGCF_PROFILE" "${WGCF_CONFIG_DIR}/wgcf.conf"

    # 如果 IPv6 不可用，从配置中移除 IPv6 地址
    if [[ "$ipv6_available" == "false" ]]; then
        print_info "移除配置中的 IPv6 地址..."
        # 移除 IPv6 地址行（格式: Address = xxxx:xxxx::/128）
        sed -i '/Address.*:.*:.*\/128/d' "${WGCF_CONFIG_DIR}/wgcf.conf"
        # 移除 AllowedIPs 中的 IPv6 部分
        sed -i 's/,:://' "${WGCF_CONFIG_DIR}/wgcf.conf"
        sed -i 's/, :://' "${WGCF_CONFIG_DIR}/wgcf.conf"
        print_success "✅ 已切换到纯 IPv4 模式"
    fi

    # 4. 检查 resolvconf 依赖
    if ! command -v resolvconf &>/dev/null; then
        print_warning "⚠️  系统未安装 resolvconf，将移除配置中的 DNS 设置"
        # 从配置文件中删除 DNS 行，避免 wg-quick 调用 resolvconf
        sed -i '/^DNS[[:space:]]*=/d' "${WGCF_CONFIG_DIR}/wgcf.conf"
        print_info "提示：可安装 openresolv 以支持 DNS 配置"
        print_info "  Ubuntu/Debian: apt install openresolv"
        print_info "  CentOS/RHEL: yum install openresolv"
    fi

    # 5. 修改路由配置，防止接管系统默认路由
    print_info "正在配置路由策略（仅隧道模式，不影响系统路由）..."

    # 检查是否有 [Interface] 段
    if grep -q "^\[Interface\]" "${WGCF_CONFIG_DIR}/wgcf.conf" 2>/dev/null; then
        print_warning "⚠️  配置为隧道专用模式，不会修改系统路由表"

        # 方案：在 [Interface] 段添加 Table = off
        # 这样 wg-quick 创建接口但不会添加任何路由规则
        # WARP 接口可用，但不会劫持 SSH 等系统流量
        # sing-box 可以通过 bind_interface 绑定使用

        # 在 [Interface] 段后添加 Table = off（如果不存在）
        if ! grep -q "^Table[[:space:]]*=" "${WGCF_CONFIG_DIR}/wgcf.conf"; then
            sed -i '/^\[Interface\]/a Table = off' "${WGCF_CONFIG_DIR}/wgcf.conf"
        fi

        print_success "✅ 已配置为隧道专用模式（不影响 SSH 等系统流量）"
        print_info "说明：WARP 接口已创建但不修改路由表，可供 sing-box 使用"
    fi

    # ========================================
    # 启动 WARP
    # ========================================
    print_info "正在启动 WARP 连接..."

    # 启动 WireGuard，并捕获详细错误
    local error_log=$(mktemp)
    if wg-quick up wgcf 2>"$error_log"; then
        print_success "✅ WARP 连接已启动"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "${YELLOW}连接信息：${NC}"
        wg show wgcf 2>/dev/null || echo "  无法获取连接信息"
        echo ""
        rm -f "$error_log"
    else
        print_error "WARP 启动失败"
        echo ""
        echo -e "${YELLOW}错误详情：${NC}"
        cat "$error_log"
        echo ""

        # 提供可能的解决方案
        echo -e "${YELLOW}可能的原因和解决方案：${NC}"

        if grep -q "Permission denied" "$error_log"; then
            echo -e "  1. ${RED}权限问题${NC}"
            echo -e "     • 确认以 root 用户运行"
            echo -e "     • 检查 SELinux 状态: getenforce"
            echo -e "     • 临时关闭 SELinux: setenforce 0"
        fi

        if grep -q "Cannot find device" "$error_log" || grep -q "No such device" "$error_log"; then
            echo -e "  2. ${RED}WireGuard 模块问题${NC}"
            echo -e "     • 安装内核模块: apt install wireguard-dkms (Debian/Ubuntu)"
            echo -e "     • 或: yum install wireguard-dkms (CentOS/RHEL)"
        fi

        if grep -q "ipv6" "$error_log"; then
            echo -e "  3. ${RED}IPv6 未启用${NC}"
            echo -e "     • 启用 IPv6: sysctl -w net.ipv6.conf.all.disable_ipv6=0"
            echo -e "     • 检查 IPv6 状态: cat /proc/sys/net/ipv6/conf/all/disable_ipv6"
        fi

        echo -e "  4. ${YELLOW}查看完整日志${NC}"
        echo -e "     • 运行诊断: wg-quick up wgcf"
        echo -e "     • 查看系统日志: journalctl -xe"

        rm -f "$error_log"
        return 1
    fi
}

# 停止 WARP 连接
stop_warp() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         停止 WARP 连接               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限才能停止 WARP 连接"
        print_info "请使用 sudo 运行此脚本"
        return 1
    fi

    if ! wg show wgcf &>/dev/null; then
        print_warning "WARP 未运行"
        return 0
    fi

    print_info "正在停止 WARP 连接..."

    if wg-quick down wgcf; then
        print_success "WARP 连接已停止"
    else
        print_error "停止失败"
        return 1
    fi
}

# 将WARP关联到节点（作为出站）
bind_warp_to_node() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    将WARP关联到节点（出站）         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查WARP是否配置
    if [[ ! -f "$WGCF_PROFILE" ]]; then
        print_error "WARP配置不存在，请先生成WireGuard配置"
        return 1
    fi

    # 检查节点文件
    local nodes_file="${DATA_DIR}/nodes.json"
    if [[ ! -f "$nodes_file" ]]; then
        print_error "节点文件不存在"
        return 1
    fi

    # 列出节点
    echo -e "${YELLOW}现有节点：${NC}"
    local nodes=$(jq -r '.nodes[] | "\(.port)|\(.protocol)|\(.tag // "N/A")|\(.warp_outbound // "未使用")"' "$nodes_file" 2>/dev/null)

    if [[ -z "$nodes" ]]; then
        print_error "没有可用节点"
        return 1
    fi

    local index=1
    echo "$nodes" | while IFS='|' read -r port protocol tag warp_status; do
        if [[ "$warp_status" == "true" ]]; then
            echo -e "${GREEN}$index.${NC} 端口: $port | 协议: $protocol | 标签: $tag ${YELLOW}[已启用WARP]${NC}"
        else
            echo -e "${GREEN}$index.${NC} 端口: $port | 协议: $protocol | 标签: $tag"
        fi
        ((index++))
    done

    echo ""
    read -p "请选择要关联WARP的节点编号: " node_choice

    local selected_port=$(echo "$nodes" | sed -n "${node_choice}p" | cut -d'|' -f1)

    if [[ -z "$selected_port" ]]; then
        print_error "无效选择"
        return 1
    fi

    # 更新节点配置，启用WARP出站
    jq --arg port "$selected_port" \
       '(.nodes[] | select(.port == $port)) |= (. + {warp_outbound: true})' \
       "$nodes_file" > "${nodes_file}.tmp" && mv "${nodes_file}.tmp" "$nodes_file"

    print_success "✅ WARP已关联到节点 (端口: $selected_port)"
    echo ""
    echo -e "${YELLOW}访问流程：${NC}"
    echo -e "  用户 → 节点($selected_port) → ${GREEN}WARP${NC} → 目标服务器"
    echo ""

    # 询问是否立即重新生成配置
    read -p "是否立即重新生成sing-box配置以应用更改？[Y/n]: " regen_choice
    if [[ "$regen_choice" != "n" && "$regen_choice" != "N" ]]; then
        echo ""
        echo -e "${CYAN}════════════════════════════════════════${NC}"
        echo -e "${CYAN}开始重新生成sing-box配置${NC}"
        echo -e "${CYAN}════════════════════════════════════════${NC}"

        # 检查配置生成函数是否可用
        if declare -f generate_singbox_config >/dev/null 2>&1; then
            generate_singbox_config

            echo -e "${CYAN}════════════════════════════════════════${NC}"
            echo -e "${CYAN}配置生成完成${NC}"
            echo -e "${CYAN}════════════════════════════════════════${NC}"

            # 询问是否重启服务
            read -p "配置已更新，是否重启sing-box服务？[Y/n]: " restart_choice
            if [[ "$restart_choice" != "n" && "$restart_choice" != "N" ]]; then
                systemctl restart sing-box
                print_success "sing-box服务已重启"
            fi
        else
            print_warning "配置生成函数不可用，请手动重新生成配置"
            print_info "提示：运行主菜单中的'重新生成配置'选项"
        fi
    else
        echo -e "${YELLOW}提示：${NC}"
        echo -e "  • 节点的出站流量将通过WARP代理"
        echo -e "  • 需要重新生成sing-box配置才能生效"
        echo -e "  • 确保WARP连接已启动"
    fi
}

# 解除WARP与节点的关联
unbind_warp_from_node() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       解除WARP节点关联              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    local nodes_file="${DATA_DIR}/nodes.json"
    if [[ ! -f "$nodes_file" ]]; then
        print_error "节点文件不存在"
        return 1
    fi

    # 列出已启用WARP的节点
    echo -e "${YELLOW}已启用WARP的节点：${NC}"
    local warp_nodes=$(jq -r '.nodes[] | select(.warp_outbound == true) | "\(.port)|\(.protocol)|\(.tag // "N/A")"' "$nodes_file" 2>/dev/null)

    if [[ -z "$warp_nodes" ]]; then
        print_info "没有节点启用WARP"
        return 0
    fi

    local index=1
    echo "$warp_nodes" | while IFS='|' read -r port protocol tag; do
        echo -e "${GREEN}$index.${NC} 端口: $port | 协议: $protocol | 标签: $tag"
        ((index++))
    done

    echo ""
    read -p "请选择要解除WARP的节点编号: " node_choice

    local selected_port=$(echo "$warp_nodes" | sed -n "${node_choice}p" | cut -d'|' -f1)

    if [[ -z "$selected_port" ]]; then
        print_error "无效选择"
        return 1
    fi

    # 移除WARP配置
    jq --arg port "$selected_port" \
       '(.nodes[] | select(.port == $port)) |= del(.warp_outbound)' \
       "$nodes_file" > "${nodes_file}.tmp" && mv "${nodes_file}.tmp" "$nodes_file"

    print_success "已解除节点 $selected_port 的WARP关联"
    echo ""

    # 询问是否立即重新生成配置
    read -p "是否立即重新生成sing-box配置以应用更改？[Y/n]: " regen_choice
    if [[ "$regen_choice" != "n" && "$regen_choice" != "N" ]]; then
        print_info "正在重新生成配置..."

        if declare -f generate_singbox_config >/dev/null 2>&1; then
            generate_singbox_config

            read -p "配置已更新，是否重启sing-box服务？[Y/n]: " restart_choice
            if [[ "$restart_choice" != "n" && "$restart_choice" != "N" ]]; then
                systemctl restart sing-box
                print_success "sing-box服务已重启"
            fi
        else
            print_warning "配置生成函数不可用，请手动重新生成配置"
        fi
    fi
}

# WARP 系统诊断
warp_diagnose() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      WARP 系统诊断                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 1. 检查 root 权限
    echo -e "${YELLOW}1. 权限检查${NC}"
    if [[ $EUID -eq 0 ]]; then
        echo -e "   ✅ 当前用户: root"
    else
        echo -e "   ❌ 当前用户: $(whoami) (非 root)"
        echo -e "   ${RED}提示: 需要 root 权限运行${NC}"
    fi
    echo ""

    # 2. 检查 WireGuard 工具
    echo -e "${YELLOW}2. WireGuard 工具${NC}"
    if command -v wg &>/dev/null; then
        echo -e "   ✅ wg: $(wg --version 2>&1 | head -1)"
    else
        echo -e "   ❌ wg 未安装"
    fi

    if command -v wg-quick &>/dev/null; then
        echo -e "   ✅ wg-quick: 已安装"
    else
        echo -e "   ❌ wg-quick 未安装"
    fi
    echo ""

    # 3. 检查内核模块
    echo -e "${YELLOW}3. 内核模块${NC}"
    if lsmod | grep -q wireguard; then
        echo -e "   ✅ WireGuard 内核模块已加载"
        lsmod | grep wireguard | while read line; do
            echo -e "      $line"
        done
    else
        echo -e "   ❌ WireGuard 内核模块未加载"
        echo -e "   ${YELLOW}尝试加载: modprobe wireguard${NC}"
    fi
    echo ""

    # 4. 检查 IPv6 支持
    echo -e "${YELLOW}4. IPv6 支持${NC}"
    if [[ -d /proc/sys/net/ipv6 ]]; then
        local ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        if [[ "$ipv6_disabled" == "0" ]]; then
            echo -e "   ✅ IPv6 已启用（推荐）"
        else
            echo -e "   ⚠️  IPv6 已禁用"
            echo -e "   ${YELLOW}启用命令: sysctl -w net.ipv6.conf.all.disable_ipv6=0${NC}"
            echo -e "   ${CYAN}提示: 如无法启用，系统会自动使用纯 IPv4 模式${NC}"
        fi
    else
        echo -e "   ❌ 系统不支持 IPv6"
        echo -e "   ${CYAN}提示: 系统会自动使用纯 IPv4 模式${NC}"
    fi
    echo ""

    # 5. 检查 SELinux
    echo -e "${YELLOW}5. SELinux 状态${NC}"
    if command -v getenforce &>/dev/null; then
        local selinux_status=$(getenforce 2>/dev/null)
        echo -e "   状态: $selinux_status"
        if [[ "$selinux_status" == "Enforcing" ]]; then
            echo -e "   ⚠️  SELinux 可能阻止 WireGuard"
            echo -e "   ${YELLOW}临时关闭: setenforce 0${NC}"
        fi
    else
        echo -e "   SELinux 未安装"
    fi
    echo ""

    # 6. 检查配置文件
    echo -e "${YELLOW}6. WARP 配置文件${NC}"
    if [[ -f "$WGCF_PROFILE" ]]; then
        echo -e "   ✅ 配置文件存在: $WGCF_PROFILE"
        local file_size=$(stat -c%s "$WGCF_PROFILE" 2>/dev/null || stat -f%z "$WGCF_PROFILE" 2>/dev/null)
        echo -e "   文件大小: ${file_size} bytes"
    else
        echo -e "   ❌ 配置文件不存在"
    fi
    echo ""

    # 7. 检查网络接口
    echo -e "${YELLOW}7. WireGuard 接口${NC}"
    if ip link show wgcf &>/dev/null; then
        echo -e "   ✅ wgcf 接口已存在"
        ip link show wgcf | head -2
    else
        echo -e "   wgcf 接口不存在"
    fi
    echo ""

    # 8. 检查连接状态
    echo -e "${YELLOW}8. WARP 连接状态${NC}"
    if wg show wgcf &>/dev/null; then
        echo -e "   ✅ WARP 运行中"
        wg show wgcf | head -5
    else
        echo -e "   WARP 未运行"
    fi
    echo ""

    # 总结建议
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}诊断建议：${NC}"

    local has_issue=false

    if [[ $EUID -ne 0 ]]; then
        echo -e "  • ${RED}请使用 root 权限运行脚本${NC}"
        has_issue=true
    fi

    if ! lsmod | grep -q wireguard; then
        echo -e "  • ${RED}加载 WireGuard 内核模块: modprobe wireguard${NC}"
        has_issue=true
    fi

    if [[ ! -d /proc/sys/net/ipv6 ]] || [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) != "0" ]]; then
        echo -e "  • ${CYAN}建议启用 IPv6（可选，系统会自动降级到 IPv4）${NC}"
    fi

    if ! command -v wg-quick &>/dev/null; then
        echo -e "  • ${RED}安装 wireguard-tools: apt install wireguard-tools${NC}"
        has_issue=true
    fi

    if [[ ! -f "$WGCF_PROFILE" ]]; then
        echo -e "  • ${YELLOW}需要先生成 WARP 配置文件${NC}"
        has_issue=true
    fi

    if ! $has_issue; then
        echo -e "  ✅ ${GREEN}系统环境正常，可以尝试启动 WARP${NC}"
    fi
    echo ""
}

# 查看 WARP 状态
warp_status() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         WARP 状态                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查 wgcf 安装状态
    if [[ -f "$WGCF_BIN" ]]; then
        echo -e "${GREEN}✅ wgcf 已安装${NC}"

        # 使用统一的版本获取函数
        local wgcf_ver=$(get_wgcf_version)

        if [[ "$wgcf_ver" != "unknown" ]]; then
            echo -e "   版本: ${GREEN}v$wgcf_ver${NC}"
        else
            echo -e "   版本: ${YELLOW}无法获取${NC}"
        fi
    else
        echo -e "${RED}✗ wgcf 未安装${NC}"
    fi
    echo ""

    # 检查账号状态
    if [[ -f "$WGCF_ACCOUNT" ]]; then
        echo -e "${GREEN}✅ WARP 账号已注册${NC}"
        local device_id=$(grep "device_id" "$WGCF_ACCOUNT" | cut -d'"' -f2)
        echo -e "   设备 ID: $device_id"
    else
        echo -e "${YELLOW}⚠ WARP 账号未注册${NC}"
    fi
    echo ""

    # 检查配置文件
    if [[ -f "$WGCF_PROFILE" ]]; then
        echo -e "${GREEN}✅ WireGuard 配置已生成${NC}"
    else
        echo -e "${YELLOW}⚠ WireGuard 配置未生成${NC}"
    fi
    echo ""

    # 检查连接状态
    if wg show wgcf &>/dev/null; then
        echo -e "${GREEN}✅ WARP 连接运行中${NC}"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "${YELLOW}连接详情：${NC}"
        wg show wgcf
    else
        echo -e "${YELLOW}⚠ WARP 连接未运行${NC}"
    fi
}

# 卸载 wgcf
uninstall_wgcf() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         卸载 wgcf                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    print_warning "确认要卸载 wgcf 吗？"
    read -p "输入 yes 确认: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消"
        return 0
    fi

    # 停止 WARP 连接
    if wg show wgcf &>/dev/null; then
        wg-quick down wgcf 2>/dev/null
    fi

    # 删除文件
    rm -f "$WGCF_BIN"
    rm -f "$WGCF_ACCOUNT"
    rm -f "$WGCF_PROFILE"
    rm -f "$WGCF_VERSION_FILE"
    rm -f "${WGCF_CONFIG_DIR}/wgcf.conf"

    print_success "wgcf 已卸载"
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
        echo -e "${GREEN}7.${NC}  管理隧道-节点绑定"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 系统管理 ━━━━━━━${NC}"
        echo -e "${GREEN}8.${NC}  安装 cloudflared"
        echo -e "${GREEN}9.${NC}  卸载 cloudflared"
        echo ""
        echo -e "${GREEN}0.${NC}  返回上级菜单"
        echo ""
        read -p "请选择 [0-9]: " choice

        case $choice in
            1) start_temp_argo_tunnel; read -p "按 Enter 继续..." ;;
            2) list_temp_argo_tunnels; read -p "按 Enter 继续..." ;;
            3) stop_temp_argo_tunnel; read -p "按 Enter 继续..." ;;
            4) create_dedicated_argo_tunnel; read -p "按 Enter 继续..." ;;
            5) list_dedicated_argo_tunnels; read -p "按 Enter 继续..." ;;
            6) delete_dedicated_argo_tunnel; read -p "按 Enter 继续..." ;;
            7) manage_tunnel_node_binding; read -p "按 Enter 继续..." ;;
            8) install_cloudflared; read -p "按 Enter 继续..." ;;
            9) uninstall_cloudflared; read -p "按 Enter 继续..." ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# WARP 隧道菜单
menu_warp_tunnel() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║    WARP 隧道管理 (wgcf)             ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 安装配置 ━━━━━━━${NC}"
        echo -e "${GREEN}1.${NC}  安装 wgcf"
        echo -e "${GREEN}2.${NC}  注册 WARP 账号"
        echo -e "${GREEN}3.${NC}  生成 WireGuard 配置"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 连接管理 ━━━━━━━${NC}"
        echo -e "${GREEN}4.${NC}  启动 WARP 连接"
        echo -e "${GREEN}5.${NC}  停止 WARP 连接"
        echo -e "${GREEN}6.${NC}  查看 WARP 状态"
        echo -e "${GREEN}7.${NC}  系统诊断（排查问题）"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 节点关联 ━━━━━━━${NC}"
        echo -e "${GREEN}8.${NC}  关联WARP到节点（作为出站）"
        echo -e "${GREEN}9.${NC}  解除WARP节点关联"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 系统管理 ━━━━━━━${NC}"
        echo -e "${GREEN}10.${NC} 卸载 wgcf"
        echo ""
        echo -e "${GREEN}0.${NC}  返回上级菜单"
        echo ""
        read -p "请选择 [0-10]: " choice

        case $choice in
            1) install_wgcf; read -p "按 Enter 继续..." ;;
            2) register_warp; read -p "按 Enter 继续..." ;;
            3) generate_warp_config; read -p "按 Enter 继续..." ;;
            4) start_warp; read -p "按 Enter 继续..." ;;
            5) stop_warp; read -p "按 Enter 继续..." ;;
            6) warp_status; read -p "按 Enter 继续..." ;;
            7) warp_diagnose; read -p "按 Enter 继续..." ;;
            8) bind_warp_to_node; read -p "按 Enter 继续..." ;;
            9) unbind_warp_from_node; read -p "按 Enter 继续..." ;;
            10) uninstall_wgcf; read -p "按 Enter 继续..." ;;
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
        print_nav_options "true" "true"

        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case $choice in
            1) menu_argo_tunnel ;;
            2) menu_warp_tunnel ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}
