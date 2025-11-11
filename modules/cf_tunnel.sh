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

        # 询问是否绑定到节点
        local nodes_file="${DATA_DIR}/nodes.json"
        if [[ -f "$nodes_file" ]]; then
            # 检查该端口是否对应一个节点
            local node_exists=$(jq -r ".nodes[] | select(.port == \"$local_port\") | .port" "$nodes_file" 2>/dev/null)

            if [[ -n "$node_exists" ]]; then
                echo ""
                read -p "检测到端口 $local_port 对应一个节点，是否关联此隧道到该节点？[y/N]: " bind_choice

                if [[ "$bind_choice" == "y" || "$bind_choice" == "Y" ]]; then
                    # 在节点中添加tunnel_domain字段
                    jq --arg port "$local_port" \
                       --arg domain "$tunnel_url" \
                       --arg pid "$pid" \
                       '(.nodes[] | select(.port == $port)) |= (
                           . + {
                               tunnel_domain: $domain,
                               tunnel_name: "temp-tunnel-" + $pid,
                               tunnel_type: "argo_temp"
                           }
                       )' \
                       "$nodes_file" > "${nodes_file}.tmp" && mv "${nodes_file}.tmp" "$nodes_file"

                    print_success "✅ 临时隧道已关联到节点"
                    echo ""
                    echo -e "${YELLOW}访问流程：${NC}"
                    echo -e "  用户 → ${GREEN}$tunnel_url${NC} (临时Argo隧道) → 本地节点(端口:$local_port)"
                    echo ""
                    echo -e "${YELLOW}注意：${NC}"
                    echo -e "  • 临时隧道重启后域名会变化，需重新绑定"
                    echo -e "  • 建议使用专用隧道以获得固定域名"
                fi
            fi
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
            # 列出可用隧道
            echo ""
            echo -e "${YELLOW}可用隧道：${NC}"
            "$CLOUDFLARED_BIN" tunnel list 2>/dev/null
            echo ""

            read -p "请输入隧道名称: " tunnel_name
            if [[ -z "$tunnel_name" ]]; then
                print_error "隧道名称不能为空"
                return 1
            fi

            # 获取隧道域名配置
            local config_file="${CLOUDFLARED_CONFIG_DIR}/config.yml"
            if [[ -f "$config_file" ]]; then
                local tunnel_domain=$(grep "hostname:" "$config_file" | head -1 | awk '{print $2}')
                local tunnel_port=$(grep "service: http://localhost:" "$config_file" | head -1 | grep -oP '\d+$')

                if [[ -n "$tunnel_domain" && -n "$tunnel_port" ]]; then
                    bind_tunnel_to_node "$tunnel_name" "$tunnel_domain" "$tunnel_port"
                else
                    print_error "无法从配置文件获取隧道信息"
                fi
            else
                print_error "隧道配置文件不存在"
            fi
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

# 安装 wgcf
install_wgcf() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         安装 wgcf (WARP)             ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查是否已安装
    if [[ -f "$WGCF_BIN" ]]; then
        print_warning "wgcf 已安装"
        local version=$("$WGCF_BIN" version 2>/dev/null || echo "unknown")
        print_info "当前版本: $version"
        return 0
    fi

    print_info "正在安装 wgcf..."

    # 检测系统架构
    local arch=$(uname -m)
    local download_url="https://github.com/ViRb3/wgcf/releases/latest/download/"

    case $arch in
        x86_64)
            download_url="${download_url}wgcf_2.2.22_linux_amd64"
            ;;
        aarch64|arm64)
            download_url="${download_url}wgcf_2.2.22_linux_arm64"
            ;;
        armv7l)
            download_url="${download_url}wgcf_2.2.22_linux_armv7"
            ;;
        *)
            print_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac

    # 下载 wgcf
    if ! curl -L -o "$WGCF_BIN" "$download_url"; then
        print_error "下载 wgcf 失败"
        return 1
    fi

    chmod +x "$WGCF_BIN"

    # 安装 WireGuard 工具
    print_info "正在安装 WireGuard 工具..."
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y wireguard-tools
    elif command -v yum &>/dev/null; then
        yum install -y wireguard-tools
    else
        print_warning "请手动安装 wireguard-tools"
    fi

    # 创建配置目录
    mkdir -p "$WGCF_CONFIG_DIR"

    # 验证安装（检查文件是否存在且可执行）
    if [[ -f "$WGCF_BIN" ]] && [[ -x "$WGCF_BIN" ]]; then
        print_success "wgcf 安装成功"
        # 尝试获取版本号，如果失败则显示"已安装"
        local version=$("$WGCF_BIN" version 2>/dev/null || echo "已安装")
        print_info "版本: $version"
        return 0
    else
        print_error "wgcf 安装失败：文件不存在或不可执行"
        return 1
    fi
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

    if [[ ! -f "$WGCF_PROFILE" ]]; then
        print_error "WARP 配置不存在，请先生成配置"
        return 1
    fi

    # 检查 wg-quick 是否安装
    if ! command -v wg-quick &>/dev/null; then
        print_error "wg-quick 未安装，请先安装 wireguard-tools"
        return 1
    fi

    print_info "正在启动 WARP 连接..."

    # 复制配置到标准位置
    cp "$WGCF_PROFILE" "${WGCF_CONFIG_DIR}/wgcf.conf"

    # 启动 WireGuard
    if wg-quick up wgcf; then
        print_success "✅ WARP 连接已启动"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "${YELLOW}连接信息：${NC}"
        wg show wgcf 2>/dev/null || echo "  无法获取连接信息"
        echo ""
    else
        print_error "WARP 启动失败"
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
    echo -e "${YELLOW}提示：${NC}"
    echo -e "  • 节点的出站流量将通过WARP代理"
    echo -e "  • 需要重新生成sing-box配置才能生效"
    echo -e "  • 确保WARP连接已启动"
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
        echo -e "   版本: $("$WGCF_BIN" version 2>/dev/null || echo 'unknown')"
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
        echo ""
        echo -e "${YELLOW}━━━━━━━ 节点关联 ━━━━━━━${NC}"
        echo -e "${GREEN}7.${NC}  关联WARP到节点（作为出站）"
        echo -e "${GREEN}8.${NC}  解除WARP节点关联"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 系统管理 ━━━━━━━${NC}"
        echo -e "${GREEN}9.${NC}  卸载 wgcf"
        echo ""
        echo -e "${GREEN}0.${NC}  返回上级菜单"
        echo ""
        read -p "请选择 [0-9]: " choice

        case $choice in
            1) install_wgcf; read -p "按 Enter 继续..." ;;
            2) register_warp; read -p "按 Enter 继续..." ;;
            3) generate_warp_config; read -p "按 Enter 继续..." ;;
            4) start_warp; read -p "按 Enter 继续..." ;;
            5) stop_warp; read -p "按 Enter 继续..." ;;
            6) warp_status; read -p "按 Enter 继续..." ;;
            7) bind_warp_to_node; read -p "按 Enter 继续..." ;;
            8) unbind_warp_from_node; read -p "按 Enter 继续..." ;;
            9) uninstall_wgcf; read -p "按 Enter 继续..." ;;
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
