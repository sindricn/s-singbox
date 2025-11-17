#!/bin/bash

#================================================================
# 防火墙管理模块
# 功能：开放端口、关闭端口、查看规则、重置防火墙、跳跃端口管理
#================================================================

# 跳跃端口配置文件
PORT_HOPPING_FILE="${DATA_DIR}/port_hopping.json"

# 初始化跳跃端口配置文件
init_port_hopping_file() {
    if [[ ! -f "$PORT_HOPPING_FILE" ]]; then
        echo '{"configs":[]}' > "$PORT_HOPPING_FILE"
    fi
}

# 检测防火墙类型
detect_firewall() {
    if command -v ufw &>/dev/null && ufw status &>/dev/null 2>&1; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

# 开放端口
open_port() {
    clear
    print_header "开放端口"
    echo ""

    read -p "请输入要开放的端口: " port
    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 验证端口号
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        print_error "无效的端口号"
        return 1
    fi

    read -p "协议类型 [tcp/udp/both, 默认: tcp]: " protocol
    protocol=${protocol:-tcp}

    local fw_type=$(detect_firewall)

    case $fw_type in
        ufw)
            if [[ "$protocol" == "both" ]]; then
                ufw allow "$port" >/dev/null 2>&1
            else
                ufw allow "$port/$protocol" >/dev/null 2>&1
            fi
            print_success "端口 $port 已开放 ($protocol)"
            ;;

        firewalld)
            if [[ "$protocol" == "both" ]]; then
                firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
                firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1
            else
                firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null 2>&1
            fi
            firewall-cmd --reload >/dev/null 2>&1
            print_success "端口 $port 已开放 ($protocol)"
            ;;

        iptables)
            if [[ "$protocol" == "both" || "$protocol" == "tcp" ]]; then
                iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            fi
            if [[ "$protocol" == "both" || "$protocol" == "udp" ]]; then
                iptables -I INPUT -p udp --dport "$port" -j ACCEPT
            fi
            # 保存规则
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save
            elif command -v service &>/dev/null; then
                service iptables save 2>/dev/null
            fi
            print_success "端口 $port 已开放 ($protocol)"
            ;;

        none)
            print_warning "未检测到防火墙，端口可能已开放"
            ;;
    esac
}

# 关闭端口
close_port() {
    clear
    print_header "关闭端口"
    echo ""

    read -p "请输入要关闭的端口: " port
    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    read -p "协议类型 [tcp/udp/both, 默认: tcp]: " protocol
    protocol=${protocol:-tcp}

    local fw_type=$(detect_firewall)

    case $fw_type in
        ufw)
            if [[ "$protocol" == "both" ]]; then
                ufw delete allow "$port" >/dev/null 2>&1
            else
                ufw delete allow "$port/$protocol" >/dev/null 2>&1
            fi
            print_success "端口 $port 已关闭 ($protocol)"
            ;;

        firewalld)
            if [[ "$protocol" == "both" ]]; then
                firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1
                firewall-cmd --permanent --remove-port="${port}/udp" >/dev/null 2>&1
            else
                firewall-cmd --permanent --remove-port="${port}/${protocol}" >/dev/null 2>&1
            fi
            firewall-cmd --reload >/dev/null 2>&1
            print_success "端口 $port 已关闭 ($protocol)"
            ;;

        iptables)
            if [[ "$protocol" == "both" || "$protocol" == "tcp" ]]; then
                iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            fi
            if [[ "$protocol" == "both" || "$protocol" == "udp" ]]; then
                iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
            fi
            # 保存规则
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save
            elif command -v service &>/dev/null; then
                service iptables save 2>/dev/null
            fi
            print_success "端口 $port 已关闭 ($protocol)"
            ;;

        none)
            print_warning "未检测到防火墙"
            ;;
    esac
}

# 查看防火墙规则
show_firewall_rules() {
    clear
    print_header "防火墙规则"
    echo ""

    local fw_type=$(detect_firewall)

    case $fw_type in
        ufw)
            echo -e "${CYAN}防火墙类型: UFW${NC}"
            echo ""
            ufw status numbered
            ;;

        firewalld)
            echo -e "${CYAN}防火墙类型: Firewalld${NC}"
            echo ""
            echo -e "${CYAN}开放的端口：${NC}"
            firewall-cmd --list-ports
            echo ""
            echo -e "${CYAN}开放的服务：${NC}"
            firewall-cmd --list-services
            ;;

        iptables)
            echo -e "${CYAN}防火墙类型: iptables${NC}"
            echo ""
            echo -e "${CYAN}INPUT 链规则：${NC}"
            iptables -L INPUT -n --line-numbers
            ;;

        none)
            print_warning "未检测到防火墙"
            ;;
    esac
}

# 重置防火墙
reset_firewall() {
    clear
    print_header "重置防火墙"
    echo ""

    print_warning "此操作将清除所有防火墙规则！"
    read -p "确认重置防火墙? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消重置"
        return 0
    fi

    local fw_type=$(detect_firewall)

    case $fw_type in
        ufw)
            ufw --force reset
            print_success "UFW 防火墙已重置"
            ;;

        firewalld)
            firewall-cmd --complete-reload
            print_success "Firewalld 防火墙已重置"
            ;;

        iptables)
            iptables -F
            iptables -X
            iptables -t nat -F
            iptables -t nat -X
            iptables -t mangle -F
            iptables -t mangle -X
            iptables -P INPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -P OUTPUT ACCEPT

            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save
            fi
            print_success "iptables 防火墙已重置"
            ;;

        none)
            print_warning "未检测到防火墙"
            ;;
    esac
}

# 禁用防火墙
disable_firewall() {
    clear
    print_header "禁用防火墙"
    echo ""

    print_warning "禁用防火墙可能导致安全风险！"
    read -p "确认禁用防火墙? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消操作"
        return 0
    fi

    local fw_type=$(detect_firewall)

    case $fw_type in
        ufw)
            ufw disable
            print_success "UFW 防火墙已禁用"
            ;;

        firewalld)
            systemctl stop firewalld
            systemctl disable firewalld
            print_success "Firewalld 防火墙已禁用"
            ;;

        iptables)
            systemctl stop iptables 2>/dev/null
            systemctl disable iptables 2>/dev/null
            print_success "iptables 防火墙已禁用"
            ;;

        none)
            print_warning "未检测到防火墙"
            ;;
    esac
}

# 启用防火墙
enable_firewall() {
    clear
    print_header "启用防火墙"
    echo ""

    local fw_type=$(detect_firewall)

    case $fw_type in
        ufw)
            ufw --force enable
            print_success "UFW 防火墙已启用"
            ;;

        firewalld)
            systemctl start firewalld
            systemctl enable firewalld
            print_success "Firewalld 防火墙已启用"
            ;;

        iptables)
            systemctl start iptables 2>/dev/null
            systemctl enable iptables 2>/dev/null
            print_success "iptables 防火墙已启用"
            ;;

        none)
            print_error "未检测到防火墙，无法启用"
            ;;
    esac
}

# 批量开放端口
batch_open_ports() {
    clear
    print_header "批量开放端口"
    echo ""

    # 获取所有节点端口
    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "暂无节点"
        return 1
    fi

    local ports=$(jq -r '.nodes[].port' "$NODES_FILE" 2>/dev/null | sort -n | uniq)

    if [[ -z "$ports" ]]; then
        print_error "暂无端口需要开放"
        return 1
    fi

    echo -e "${CYAN}将开放以下端口:${NC}"
    echo "$ports" | tr '\n' ' '
    echo ""

    read -p "确认开放这些端口? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消操作"
        return 0
    fi

    local fw_type=$(detect_firewall)
    local success=0
    local failed=0

    for port in $ports; do
        case $fw_type in
            ufw)
                if ufw allow "$port/tcp" >/dev/null 2>&1; then
                    ((success++))
                else
                    ((failed++))
                fi
                ;;

            firewalld)
                if firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1; then
                    ((success++))
                else
                    ((failed++))
                fi
                ;;

            iptables)
                if iptables -I INPUT -p tcp --dport "$port" -j ACCEPT; then
                    ((success++))
                else
                    ((failed++))
                fi
                ;;
        esac
    done

    # 重载防火墙
    case $fw_type in
        firewalld)
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        iptables)
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save
            fi
            ;;
    esac

    print_success "成功开放 $success 个端口,失败 $failed 个"
}

#================================================================
# 跳跃端口管理功能
#================================================================

# 查看跳跃端口配置
list_port_hopping() {
    clear
    print_header "跳跃端口配置列表"
    echo ""

    init_port_hopping_file

    local count=$(jq '.configs | length' "$PORT_HOPPING_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -eq 0 ]]; then
        print_warning "暂无跳跃端口配置"
        return 0
    fi

    echo -e "${YELLOW}跳跃配置总数:${NC} $count"
    echo ""

    printf "${CYAN}%-4s %-20s %-10s %-30s %-10s %-10s${NC}\n" "序号" "配置名称" "原端口" "跳跃端口列表" "间隔(秒)" "状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    while read -r config; do
        local name=$(echo "$config" | jq -r '.name')
        local node_port=$(echo "$config" | jq -r '.node_port')
        local hop_ports=$(echo "$config" | jq -r '.hop_ports | join(",")')
        local interval=$(echo "$config" | jq -r '.interval')
        local enabled=$(echo "$config" | jq -r '.enabled')
        local current_hop=$(echo "$config" | jq -r '.current_hop_port // "N/A"')

        # 截断过长的端口列表
        if [[ ${#hop_ports} -gt 28 ]]; then
            hop_ports="${hop_ports:0:25}..."
        fi

        local status="${RED}禁用${NC}"
        [[ "$enabled" == "true" ]] && status="${GREEN}启用${NC}"

        printf "%-4s %-20s %-10s %-30s %-10s %-10b\n" "$index" "$name" "$node_port" "$hop_ports" "$interval" "$status"
        echo -e "  ${GRAY}当前跳跃端口: $current_hop${NC}"
        ((index++))
    done < <(jq -c '.configs[]' "$PORT_HOPPING_FILE" 2>/dev/null)

    echo ""
}

# 添加跳跃端口配置
add_port_hopping() {
    clear
    print_header "添加跳跃端口配置"
    echo ""

    init_port_hopping_file

    # 输入配置名称
    read -p "请输入配置名称: " name
    if [[ -z "$name" ]]; then
        print_error "配置名称不能为空"
        return 1
    fi

    # 选择节点
    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "暂无节点"
        return 1
    fi

    local node_count=$(jq '.nodes | length' "$NODES_FILE" 2>/dev/null || echo "0")
    if [[ "$node_count" -eq 0 ]]; then
        print_error "暂无节点"
        return 1
    fi

    echo -e "${CYAN}现有节点列表:${NC}"
    echo ""
    local index=1
    while read -r node; do
        local node_name=$(echo "$node" | jq -r '.name')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local port=$(echo "$node" | jq -r '.port')
        echo -e "${GREEN}[$index]${NC} $node_name ($protocol) - 端口: $port"
        ((index++))
    done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)

    echo ""
    read -p "请选择节点序号: " node_idx
    if [[ ! "$node_idx" =~ ^[0-9]+$ ]] || [[ "$node_idx" -lt 1 ]] || [[ "$node_idx" -gt "$node_count" ]]; then
        print_error "无效的序号"
        return 1
    fi

    local node_port=$(jq -r ".nodes[$((node_idx-1))].port" "$NODES_FILE" 2>/dev/null)

    # 输入跳跃端口列表
    echo ""
    echo -e "${YELLOW}提示: 请输入跳跃端口列表,用逗号分隔,例如: 8443,8444,8445,8446${NC}"
    read -p "跳跃端口列表: " hop_ports_input

    if [[ -z "$hop_ports_input" ]]; then
        print_error "跳跃端口列表不能为空"
        return 1
    fi

    # 验证端口格式并转换为数组
    IFS=',' read -ra hop_ports_array <<< "$hop_ports_input"
    local valid_ports=()
    for port in "${hop_ports_array[@]}"; do
        port=$(echo "$port" | xargs)  # 去除空格
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
            valid_ports+=("$port")
        else
            print_warning "跳过无效端口: $port"
        fi
    done

    if [[ ${#valid_ports[@]} -eq 0 ]]; then
        print_error "没有有效的跳跃端口"
        return 1
    fi

    # 输入切换间隔
    echo ""
    read -p "端口切换间隔(秒, 默认3600): " interval
    interval=${interval:-3600}

    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 60 ]]; then
        print_error "间隔必须至少60秒"
        return 1
    fi

    # 生成唯一ID
    local id="hop_$(date +%s)"
    local current_time=$(date +%s)

    # 构建配置
    local hop_ports_json=$(printf '%s\n' "${valid_ports[@]}" | jq -R . | jq -s .)
    local config=$(jq -n \
        --arg id "$id" \
        --arg name "$name" \
        --argjson node_port "$node_port" \
        --argjson hop_ports "$hop_ports_json" \
        --argjson interval "$interval" \
        --argjson last_switch "$current_time" \
        --argjson current_hop "${valid_ports[0]}" \
        '{
            id: $id,
            name: $name,
            node_port: $node_port,
            hop_ports: $hop_ports,
            interval: $interval,
            enabled: false,
            last_switch: $last_switch,
            current_hop_port: $current_hop
        }')

    # 添加到配置文件
    jq --argjson config "$config" '.configs += [$config]' "$PORT_HOPPING_FILE" > "${PORT_HOPPING_FILE}.tmp"
    mv "${PORT_HOPPING_FILE}.tmp" "$PORT_HOPPING_FILE"

    print_success "跳跃端口配置已添加"
    echo ""
    echo -e "${CYAN}配置信息:${NC}"
    echo -e "  配置名称: $name"
    echo -e "  原节点端口: $node_port"
    echo -e "  跳跃端口: ${valid_ports[*]}"
    echo -e "  切换间隔: ${interval}秒"
    echo -e "  ${YELLOW}提示: 请在菜单中启用此配置${NC}"
}

# 删除跳跃端口配置
delete_port_hopping() {
    list_port_hopping

    local count=$(jq '.configs | length' "$PORT_HOPPING_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    echo ""
    read -p "请输入要删除的配置序号: " index
    if [[ ! "$index" =~ ^[0-9]+$ ]] || [[ "$index" -lt 1 ]] || [[ "$index" -gt "$count" ]]; then
        print_error "无效的序号"
        return 1
    fi

    local config_name=$(jq -r ".configs[$((index-1))].name" "$PORT_HOPPING_FILE" 2>/dev/null)

    read -p "确认删除配置 '$config_name'? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消删除"
        return 0
    fi

    jq "del(.configs[$((index-1))])" "$PORT_HOPPING_FILE" > "${PORT_HOPPING_FILE}.tmp"
    mv "${PORT_HOPPING_FILE}.tmp" "$PORT_HOPPING_FILE"

    print_success "跳跃端口配置已删除: $config_name"
}

# 修改跳跃端口配置
modify_port_hopping() {
    list_port_hopping

    local count=$(jq '.configs | length' "$PORT_HOPPING_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    echo ""
    read -p "请输入要修改的配置序号: " index
    if [[ ! "$index" =~ ^[0-9]+$ ]] || [[ "$index" -lt 1 ]] || [[ "$index" -gt "$count" ]]; then
        print_error "无效的序号"
        return 1
    fi

    local config=$(jq ".configs[$((index-1))]" "$PORT_HOPPING_FILE" 2>/dev/null)
    local current_name=$(echo "$config" | jq -r '.name')
    local current_interval=$(echo "$config" | jq -r '.interval')
    local current_hop_ports=$(echo "$config" | jq -r '.hop_ports | join(",")')

    clear
    print_header "修改跳跃端口配置: $current_name"
    echo ""

    echo -e "${CYAN}当前配置:${NC}"
    echo -e "  配置名称: $current_name"
    echo -e "  跳跃端口: $current_hop_ports"
    echo -e "  切换间隔: ${current_interval}秒"
    echo ""

    echo -e "${GREEN}1.${NC} 修改配置名称"
    echo -e "${GREEN}2.${NC} 修改跳跃端口列表"
    echo -e "${GREEN}3.${NC} 修改切换间隔"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""

    read -p "请选择操作 [0-3]: " choice

    case $choice in
        1)
            read -p "请输入新的配置名称: " new_name
            if [[ -n "$new_name" ]]; then
                jq "(.configs[$((index-1))].name) = \"$new_name\"" "$PORT_HOPPING_FILE" > "${PORT_HOPPING_FILE}.tmp"
                mv "${PORT_HOPPING_FILE}.tmp" "$PORT_HOPPING_FILE"
                print_success "配置名称已更新"
            fi
            ;;
        2)
            read -p "请输入新的跳跃端口列表(逗号分隔): " new_ports
            if [[ -n "$new_ports" ]]; then
                IFS=',' read -ra ports_array <<< "$new_ports"
                local valid_ports=()
                for port in "${ports_array[@]}"; do
                    port=$(echo "$port" | xargs)
                    if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
                        valid_ports+=("$port")
                    fi
                done

                if [[ ${#valid_ports[@]} -gt 0 ]]; then
                    local ports_json=$(printf '%s\n' "${valid_ports[@]}" | jq -R . | jq -s .)
                    jq --argjson ports "$ports_json" "(.configs[$((index-1))].hop_ports) = \$ports" "$PORT_HOPPING_FILE" > "${PORT_HOPPING_FILE}.tmp"
                    mv "${PORT_HOPPING_FILE}.tmp" "$PORT_HOPPING_FILE"
                    print_success "跳跃端口列表已更新"
                else
                    print_error "没有有效的端口"
                fi
            fi
            ;;
        3)
            read -p "请输入新的切换间隔(秒): " new_interval
            if [[ "$new_interval" =~ ^[0-9]+$ ]] && [[ "$new_interval" -ge 60 ]]; then
                jq "(.configs[$((index-1))].interval) = $new_interval" "$PORT_HOPPING_FILE" > "${PORT_HOPPING_FILE}.tmp"
                mv "${PORT_HOPPING_FILE}.tmp" "$PORT_HOPPING_FILE"
                print_success "切换间隔已更新"
            else
                print_error "间隔必须至少60秒"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            ;;
    esac
}

# 启用/禁用跳跃端口配置
toggle_port_hopping() {
    list_port_hopping

    local count=$(jq '.configs | length' "$PORT_HOPPING_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    echo ""
    read -p "请输入配置序号: " index
    if [[ ! "$index" =~ ^[0-9]+$ ]] || [[ "$index" -lt 1 ]] || [[ "$index" -gt "$count" ]]; then
        print_error "无效的序号"
        return 1
    fi

    local current_status=$(jq -r ".configs[$((index-1))].enabled" "$PORT_HOPPING_FILE" 2>/dev/null)
    local new_status="false"
    [[ "$current_status" == "false" ]] && new_status="true"

    jq "(.configs[$((index-1))].enabled) = $new_status" "$PORT_HOPPING_FILE" > "${PORT_HOPPING_FILE}.tmp"
    mv "${PORT_HOPPING_FILE}.tmp" "$PORT_HOPPING_FILE"

    if [[ "$new_status" == "true" ]]; then
        print_success "跳跃端口配置已启用"
        echo -e "${YELLOW}提示: 请使用'手动切换端口'功能激活跳跃${NC}"
    else
        print_success "跳跃端口配置已禁用"
    fi
}

# 手动切换端口
manual_switch_port() {
    list_port_hopping

    local count=$(jq '.configs | length' "$PORT_HOPPING_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    echo ""
    read -p "请输入配置序号: " index
    if [[ ! "$index" =~ ^[0-9]+$ ]] || [[ "$index" -lt 1 ]] || [[ "$index" -gt "$count" ]]; then
        print_error "无效的序号"
        return 1
    fi

    local config=$(jq ".configs[$((index-1))]" "$PORT_HOPPING_FILE" 2>/dev/null)
    local enabled=$(echo "$config" | jq -r '.enabled')

    if [[ "$enabled" != "true" ]]; then
        print_error "此配置未启用,请先启用"
        return 1
    fi

    local node_port=$(echo "$config" | jq -r '.node_port')
    local current_hop=$(echo "$config" | jq -r '.current_hop_port')
    local hop_ports=($(echo "$config" | jq -r '.hop_ports[]'))

    # 找到当前端口的索引
    local current_index=0
    for i in "${!hop_ports[@]}"; do
        if [[ "${hop_ports[$i]}" == "$current_hop" ]]; then
            current_index=$i
            break
        fi
    done

    # 切换到下一个端口
    local next_index=$(( (current_index + 1) % ${#hop_ports[@]} ))
    local next_port="${hop_ports[$next_index]}"

    echo ""
    echo -e "${CYAN}准备切换端口:${NC}"
    echo -e "  原节点端口: $node_port"
    echo -e "  当前跳跃端口: $current_hop"
    echo -e "  新跳跃端口: $next_port"
    echo ""

    read -p "确认切换? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消切换"
        return 0
    fi

    # 执行切换
    print_info "正在切换端口..."

    # 1. 更新节点配置中的端口
    jq --argjson old_port "$node_port" --argjson new_port "$next_port" '
        (.nodes[] | select(.port == $old_port) | .port) = $new_port
    ' "$NODES_FILE" > "${NODES_FILE}.tmp"
    mv "${NODES_FILE}.tmp" "$NODES_FILE"

    # 2. 更新防火墙规则
    local fw_type=$(detect_firewall)
    case $fw_type in
        ufw)
            ufw allow "$next_port/tcp" >/dev/null 2>&1
            ufw delete allow "$current_hop/tcp" >/dev/null 2>&1
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${next_port}/tcp" >/dev/null 2>&1
            firewall-cmd --permanent --remove-port="${current_hop}/tcp" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        iptables)
            iptables -I INPUT -p tcp --dport "$next_port" -j ACCEPT
            iptables -D INPUT -p tcp --dport "$current_hop" -j ACCEPT 2>/dev/null
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save
            fi
            ;;
    esac

    # 3. 更新跳跃配置
    local current_time=$(date +%s)
    jq --argjson idx "$((index-1))" --argjson new_port "$next_port" --argjson time "$current_time" '
        (.configs[$idx].current_hop_port) = $new_port |
        (.configs[$idx].last_switch) = $time |
        (.configs[$idx].node_port) = $new_port
    ' "$PORT_HOPPING_FILE" > "${PORT_HOPPING_FILE}.tmp"
    mv "${PORT_HOPPING_FILE}.tmp" "$PORT_HOPPING_FILE"

    # 4. 重新生成配置并重启
    if declare -f generate_singbox_config &>/dev/null; then
        generate_singbox_config
    fi

    if declare -f restart_singbox &>/dev/null; then
        restart_singbox
    fi

    print_success "端口切换完成"
    echo -e "  旧端口: $current_hop → 新端口: $next_port"
}

# 跳跃端口管理子菜单
port_hopping_menu() {
    while true; do
        clear
        print_header "跳跃端口管理"
        echo ""

        init_port_hopping_file

        print_section_start
        print_menu_item "1" "查看跳跃配置"
        print_menu_item "2" "添加跳跃配置"
        print_menu_item "3" "修改跳跃配置"
        print_menu_item "4" "删除跳跃配置"
        print_divider
        print_menu_item "5" "启用/禁用配置"
        print_menu_item "6" "手动切换端口"
        print_menu_item "0" "返回上级菜单"
        print_section_end

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择操作 [0-6]")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return  # 返回上级
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case $choice in
            1) list_port_hopping; wait_for_input ;;
            2) add_port_hopping; wait_for_input ;;
            3) modify_port_hopping; wait_for_input ;;
            4) delete_port_hopping; wait_for_input ;;
            5) toggle_port_hopping; wait_for_input ;;
            6) manual_switch_port; wait_for_input ;;
            0) return ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

#================================================================
# 防火墙管理菜单
#================================================================
firewall_management_menu() {
    while true; do
        clear
        local fw_type=$(detect_firewall)
        local fw_name="未检测到"

        case $fw_type in
            ufw) fw_name="UFW" ;;
            firewalld) fw_name="Firewalld" ;;
            iptables) fw_name="iptables" ;;
            none) fw_name="未检测到" ;;
        esac

        print_header "防火墙管理"
        echo ""

        print_section_start
        print_menu_info "  ${YELLOW}防火墙类型${NC}" "${CYAN}${fw_name}${NC}"
        print_divider
        print_menu_item "1" "开放端口"
        print_menu_item "2" "关闭端口"
        print_menu_item "3" "批量开放节点端口"
        print_menu_item "4" "端口跳跃管理" " ${YELLOW}[安全增强]${NC}"
        print_menu_item "5" "查看防火墙规则"
        print_divider
        print_menu_item "6" "启用防火墙"
        print_menu_item "7" "禁用防火墙"
        print_menu_item "8" "重置防火墙" " ${RED}[危险]${NC}"
        print_menu_item "0" "返回主菜单"
        print_section_end

        print_nav_options "false" "true"
        choice=$(read_menu_choice "请选择操作 [0-8]")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case $choice in
            1) open_port; wait_for_input ;;
            2) close_port; wait_for_input ;;
            3) batch_open_ports; wait_for_input ;;
            4) port_hopping_menu ;;
            5) show_firewall_rules; wait_for_input ;;
            6) enable_firewall; wait_for_input ;;
            7) disable_firewall; wait_for_input ;;
            8) reset_firewall; wait_for_input ;;
            0) return ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 初始化端口跳跃数据文件
init_port_hopping_file
