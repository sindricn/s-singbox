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

# 获取网络接口列表
get_network_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -10
}

# 解析 iptables 规则行
parse_iptables_rule() {
    local line="$1"
    local ip_version="$2"

    # 跳过表头和空行
    if [[ "$line" =~ ^(num|Chain|target|$) ]]; then
        return 1
    fi

    # 只处理 REDIRECT 规则
    if [[ ! "$line" =~ REDIRECT ]]; then
        return 1
    fi

    # 提取规则信息
    local rule_num=$(echo "$line" | awk '{print $1}')
    local target=$(echo "$line" | awk '{print $2}')
    local protocol=$(echo "$line" | awk '{print $3}')
    local in_interface=$(echo "$line" | awk '{print $6}')

    # 提取端口范围和目标端口
    local port_range=""
    local target_port=""

    if [[ "$line" =~ dpts:([0-9]+):([0-9]+) ]]; then
        port_range="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    elif [[ "$line" =~ dpt:([0-9]+) ]]; then
        port_range="${BASH_REMATCH[1]}"
    fi

    if [[ "$line" =~ redir\ ports\ ([0-9]+) ]]; then
        target_port="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ to:([0-9]+) ]]; then
        target_port="${BASH_REMATCH[1]}"
    fi

    echo "$rule_num|$ip_version|$protocol|$in_interface|$port_range|$target_port"
}

# 检测 iptables 中的端口跳跃规则
detect_port_hopping_rules() {
    local rules=()

    # 检测 IPv4 规则
    if command -v iptables &>/dev/null; then
        while IFS= read -r line; do
            local parsed=$(parse_iptables_rule "$line" "ipv4")
            if [[ -n "$parsed" ]]; then
                rules+=("$parsed")
            fi
        done < <(iptables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null)
    fi

    # 检测 IPv6 规则
    if command -v ip6tables &>/dev/null; then
        while IFS= read -r line; do
            local parsed=$(parse_iptables_rule "$line" "ipv6")
            if [[ -n "$parsed" ]]; then
                rules+=("$parsed")
            fi
        done < <(ip6tables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null)
    fi

    printf '%s\n' "${rules[@]}"
}

# 查看跳跃端口配置
list_port_hopping() {
    clear
    print_header "跳跃端口配置列表"
    echo ""

    init_port_hopping_file

    # 显示配置文件中的规则
    local count=$(jq '.configs | length' "$PORT_HOPPING_FILE" 2>/dev/null || echo "0")

    echo -e "${CYAN}═══ 配置文件中的规则 ═══${NC}"
    echo ""

    if [[ "$count" -eq 0 ]]; then
        print_warning "配置文件中暂无跳跃端口配置"
    else
        printf "${CYAN}%-4s %-15s %-12s %-15s %-12s %-10s %-10s${NC}\n" "序号" "名称" "网络接口" "源端口范围" "目标端口" "协议" "IP版本"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        local index=1
        while read -r config; do
            local name=$(echo "$config" | jq -r '.name')
            local interface=$(echo "$config" | jq -r '.interface')
            local port_range=$(echo "$config" | jq -r '.port_range')
            local target_port=$(echo "$config" | jq -r '.target_port')
            local protocol=$(echo "$config" | jq -r '.protocol')
            local ip_version=$(echo "$config" | jq -r '.ip_version')

            printf "%-4s %-15s %-12s %-15s %-12s %-10s %-10s\n" "$index" "$name" "$interface" "$port_range" "$target_port" "$protocol" "$ip_version"
            ((index++))
        done < <(jq -c '.configs[]' "$PORT_HOPPING_FILE" 2>/dev/null)
    fi

    echo ""
    echo -e "${CYAN}═══ 实际 iptables 规则 ═══${NC}"
    echo ""

    # 获取并解析实际规则
    local rules=($(detect_port_hopping_rules))

    if [[ ${#rules[@]} -eq 0 ]]; then
        print_warning "系统中暂无端口跳跃规则"
    else
        printf "${CYAN}%-4s %-8s %-10s %-12s %-15s %-12s${NC}\n" "行号" "IP版本" "协议" "接口" "源端口范围" "目标端口"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        for rule in "${rules[@]}"; do
            IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

            # 处理可能的空值
            [[ -z "$interface" || "$interface" == "*" ]] && interface="all"
            [[ -z "$port_range" ]] && port_range="N/A"
            [[ -z "$target_port" ]] && target_port="N/A"

            printf "%-4s %-8s %-10s %-12s %-15s %-12s\n" "$rule_num" "$ip_version" "$protocol" "$interface" "$port_range" "$target_port"
        done
    fi

    echo ""
    echo -e "${YELLOW}提示: 使用以下命令查看完整规则详情${NC}"
    echo -e "  IPv4: ${CYAN}iptables -t nat -L PREROUTING -n -v${NC}"
    echo -e "  IPv6: ${CYAN}ip6tables -t nat -L PREROUTING -n -v${NC}"
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

    # 选择网络接口
    echo ""
    echo -e "${CYAN}可用网络接口:${NC}"
    local interfaces=($(get_network_interfaces))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        print_error "未找到可用的网络接口"
        return 1
    fi

    local idx=1
    for iface in "${interfaces[@]}"; do
        echo -e "${GREEN}[$idx]${NC} $iface"
        ((idx++))
    done

    echo ""
    read -p "请选择网络接口序号 [默认: 1]: " iface_idx
    iface_idx=${iface_idx:-1}

    if [[ ! "$iface_idx" =~ ^[0-9]+$ ]] || [[ "$iface_idx" -lt 1 ]] || [[ "$iface_idx" -gt ${#interfaces[@]} ]]; then
        print_error "无效的序号"
        return 1
    fi

    local interface="${interfaces[$((iface_idx-1))]}"

    # 输入源端口范围
    echo ""
    echo -e "${YELLOW}提示: 请输入源端口范围,格式如: 20000:50000${NC}"
    read -p "源端口范围: " port_range

    if [[ -z "$port_range" ]]; then
        print_error "源端口范围不能为空"
        return 1
    fi

    # 验证端口范围格式
    if [[ ! "$port_range" =~ ^[0-9]+:[0-9]+$ ]]; then
        print_error "无效的端口范围格式,正确格式如: 20000:50000"
        return 1
    fi

    local start_port=$(echo "$port_range" | cut -d':' -f1)
    local end_port=$(echo "$port_range" | cut -d':' -f2)

    if [[ "$start_port" -ge "$end_port" ]]; then
        print_error "起始端口必须小于结束端口"
        return 1
    fi

    # 输入目标端口
    echo ""
    read -p "请输入目标端口(流量将重定向到此端口): " target_port

    if [[ -z "$target_port" ]] || ! [[ "$target_port" =~ ^[0-9]+$ ]] || [[ "$target_port" -lt 1 ]] || [[ "$target_port" -gt 65535 ]]; then
        print_error "无效的目标端口"
        return 1
    fi

    # 选择协议
    echo ""
    echo -e "${CYAN}选择协议:${NC}"
    echo -e "${GREEN}[1]${NC} UDP (推荐用于 QUIC/Hysteria2)"
    echo -e "${GREEN}[2]${NC} TCP"
    echo -e "${GREEN}[3]${NC} BOTH (TCP + UDP)"
    echo ""
    read -p "请选择协议 [默认: 1-UDP]: " proto_choice
    proto_choice=${proto_choice:-1}

    local protocol
    case $proto_choice in
        1) protocol="udp" ;;
        2) protocol="tcp" ;;
        3) protocol="both" ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac

    # 选择 IP 版本
    echo ""
    echo -e "${CYAN}选择 IP 版本:${NC}"
    echo -e "${GREEN}[1]${NC} IPv4"
    echo -e "${GREEN}[2]${NC} IPv6"
    echo -e "${GREEN}[3]${NC} BOTH (IPv4 + IPv6)"
    echo ""
    read -p "请选择 IP 版本 [默认: 1-IPv4]: " ip_choice
    ip_choice=${ip_choice:-1}

    local ip_version
    case $ip_choice in
        1) ip_version="ipv4" ;;
        2) ip_version="ipv6" ;;
        3) ip_version="both" ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac

    # 显示配置摘要
    echo ""
    echo -e "${CYAN}配置摘要:${NC}"
    echo -e "  名称: $name"
    echo -e "  网络接口: $interface"
    echo -e "  源端口范围: $port_range"
    echo -e "  目标端口: $target_port"
    echo -e "  协议: $protocol"
    echo -e "  IP版本: $ip_version"
    echo ""

    read -p "确认添加此配置? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消添加"
        return 0
    fi

    # 添加 iptables 规则
    print_info "正在添加 iptables 规则..."

    local success=true

    # IPv4 规则
    if [[ "$ip_version" == "ipv4" ]] || [[ "$ip_version" == "both" ]]; then
        if [[ "$protocol" == "udp" ]] || [[ "$protocol" == "both" ]]; then
            if ! iptables -t nat -A PREROUTING -i "$interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port" 2>/dev/null; then
                print_error "添加 IPv4 UDP 规则失败"
                success=false
            fi
        fi
        if [[ "$protocol" == "tcp" ]] || [[ "$protocol" == "both" ]]; then
            if ! iptables -t nat -A PREROUTING -i "$interface" -p tcp --dport "$port_range" -j REDIRECT --to-ports "$target_port" 2>/dev/null; then
                print_error "添加 IPv4 TCP 规则失败"
                success=false
            fi
        fi
    fi

    # IPv6 规则
    if [[ "$ip_version" == "ipv6" ]] || [[ "$ip_version" == "both" ]]; then
        if [[ "$protocol" == "udp" ]] || [[ "$protocol" == "both" ]]; then
            if ! ip6tables -t nat -A PREROUTING -i "$interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port" 2>/dev/null; then
                print_warning "添加 IPv6 UDP 规则失败(可能系统不支持IPv6)"
            fi
        fi
        if [[ "$protocol" == "tcp" ]] || [[ "$protocol" == "both" ]]; then
            if ! ip6tables -t nat -A PREROUTING -i "$interface" -p tcp --dport "$port_range" -j REDIRECT --to-ports "$target_port" 2>/dev/null; then
                print_warning "添加 IPv6 TCP 规则失败(可能系统不支持IPv6)"
            fi
        fi
    fi

    if [[ "$success" == false ]]; then
        print_error "添加规则失败"
        return 1
    fi

    # 保存 iptables 规则
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v service &>/dev/null; then
        service iptables save 2>/dev/null
        service ip6tables save 2>/dev/null
    fi

    # 生成唯一ID
    local id="hop_$(date +%s)"

    # 构建配置并保存到JSON
    local config=$(jq -n \
        --arg id "$id" \
        --arg name "$name" \
        --arg interface "$interface" \
        --arg port_range "$port_range" \
        --argjson target_port "$target_port" \
        --arg protocol "$protocol" \
        --arg ip_version "$ip_version" \
        '{
            id: $id,
            name: $name,
            interface: $interface,
            port_range: $port_range,
            target_port: $target_port,
            protocol: $protocol,
            ip_version: $ip_version,
            created_at: (now | tostring)
        }')

    # 添加到配置文件
    jq --argjson config "$config" '.configs += [$config]' "$PORT_HOPPING_FILE" > "${PORT_HOPPING_FILE}.tmp"
    mv "${PORT_HOPPING_FILE}.tmp" "$PORT_HOPPING_FILE"

    print_success "跳跃端口配置已添加"
    echo ""
    echo -e "${CYAN}已添加 iptables 规则:${NC}"
    echo -e "  接口: $interface"
    echo -e "  源端口: $port_range → 目标端口: $target_port"
    echo -e "  协议: $protocol | IP版本: $ip_version"
    echo ""
    echo -e "${YELLOW}提示: 客户端可以使用 $start_port-$end_port 范围内的任意端口连接${NC}"
}

# 删除指定的 iptables 规则（按行号）
delete_iptables_rule_by_number() {
    local ip_version="$1"
    local rule_num="$2"

    local cmd=""
    [[ "$ip_version" == "ipv4" ]] && cmd="iptables"
    [[ "$ip_version" == "ipv6" ]] && cmd="ip6tables"

    if [[ -z "$cmd" ]]; then
        return 1
    fi

    if $cmd -t nat -D PREROUTING "$rule_num" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 解析序号范围输入（支持 1,3,5 或 1-5 或混合）
parse_number_range() {
    local input="$1"
    local max="$2"
    local numbers=()

    # 分割逗号
    IFS=',' read -ra parts <<< "$input"

    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)  # 去除空格

        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # 范围格式 1-5
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"

            if [[ "$start" -gt "$end" ]]; then
                local temp=$start
                start=$end
                end=$temp
            fi

            for ((i=start; i<=end; i++)); do
                if [[ "$i" -ge 1 ]] && [[ "$i" -le "$max" ]]; then
                    numbers+=("$i")
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            # 单个数字
            if [[ "$part" -ge 1 ]] && [[ "$part" -le "$max" ]]; then
                numbers+=("$part")
            fi
        fi
    done

    # 去重并排序
    printf '%s\n' "${numbers[@]}" | sort -nu | tr '\n' ' '
}

# 删除跳跃端口配置
delete_port_hopping() {
    while true; do
        clear
        print_header "删除跳跃端口规则"
        echo ""

        # 获取所有规则
        local all_rules=($(detect_port_hopping_rules))

        if [[ ${#all_rules[@]} -eq 0 ]]; then
            print_warning "系统中暂无端口跳跃规则"
            echo ""
            read -p "按回车键返回..."
            return 0
        fi

        # 显示规则列表
        echo -e "${CYAN}当前端口跳跃规则:${NC}"
        echo ""
        printf "${CYAN}%-4s %-8s %-10s %-12s %-15s %-12s${NC}\n" "序号" "IP版本" "协议" "接口" "源端口范围" "目标端口"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        local index=1
        local -A rule_map
        for rule in "${all_rules[@]}"; do
            IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

            [[ -z "$interface" || "$interface" == "*" ]] && interface="all"
            [[ -z "$port_range" ]] && port_range="N/A"
            [[ -z "$target_port" ]] && target_port="N/A"

            printf "%-4s %-8s %-10s %-12s %-15s %-12s\n" "$index" "$ip_version" "$protocol" "$interface" "$port_range" "$target_port"

            # 保存规则映射
            rule_map[$index]="$rule"
            ((index++))
        done

        echo ""
        echo -e "${CYAN}删除选项:${NC}"
        echo -e "${GREEN}1.${NC} 按序号删除（单个或多个，如: 1 或 1,3,5 或 1-5）"
        echo -e "${GREEN}2.${NC} 按端口范围删除"
        echo -e "${GREEN}3.${NC} 按目标端口删除"
        echo -e "${GREEN}4.${NC} 删除所有规则"
        echo ""

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择操作")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return 0  # 返回上级
        [[ $ret -eq 98 ]] && return 0  # 返回主菜单

        case $choice in
            1)
                # 按序号删除
                echo ""
                read -p "请输入要删除的序号（支持: 1 或 1,3,5 或 1-5 或混合）: " input

                local numbers=($(parse_number_range "$input" "${#all_rules[@]}"))

                if [[ ${#numbers[@]} -eq 0 ]]; then
                    print_error "无效的序号输入"
                    sleep 2
                    continue
                fi

                echo ""
                echo -e "${YELLOW}将删除以下规则:${NC}"
                for num in "${numbers[@]}"; do
                    local rule="${rule_map[$num]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"
                    echo "  [$num] $ip_version | $protocol | $interface | $port_range → $target_port"
                done

                echo ""
                read -p "确认删除这 ${#numbers[@]} 条规则? [y/N]: " confirm
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    print_info "已取消删除"
                    sleep 1
                    continue
                fi

                print_info "正在删除规则..."

                local success=0
                local failed=0

                # 从大到小删除，避免序号变化
                for num in $(printf '%s\n' "${numbers[@]}" | sort -rn); do
                    local rule="${rule_map[$num]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

                    if delete_iptables_rule_by_number "$ip_version" "$rule_num"; then
                        ((success++))
                    else
                        ((failed++))
                    fi
                done

                # 保存规则
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service &>/dev/null; then
                    service iptables save 2>/dev/null
                    service ip6tables save 2>/dev/null
                fi

                print_success "成功删除 $success 条规则, 失败 $failed 条"
                sleep 2
                ;;

            2)
                # 按端口范围删除
                echo ""
                read -p "请输入要删除的源端口范围（如: 20000:50000）: " search_range

                if [[ -z "$search_range" ]]; then
                    print_error "端口范围不能为空"
                    sleep 2
                    continue
                fi

                # 筛选匹配的规则
                local matched_rules=()
                for idx in "${!rule_map[@]}"; do
                    local rule="${rule_map[$idx]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

                    if [[ "$port_range" == "$search_range" ]]; then
                        matched_rules+=("$idx")
                    fi
                done

                if [[ ${#matched_rules[@]} -eq 0 ]]; then
                    print_warning "未找到匹配的规则"
                    sleep 2
                    continue
                fi

                echo ""
                echo -e "${YELLOW}找到 ${#matched_rules[@]} 条匹配规则:${NC}"
                for idx in "${matched_rules[@]}"; do
                    local rule="${rule_map[$idx]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"
                    echo "  [$idx] $ip_version | $protocol | $interface | $port_range → $target_port"
                done

                echo ""
                read -p "确认删除这 ${#matched_rules[@]} 条规则? [y/N]: " confirm
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    print_info "已取消删除"
                    sleep 1
                    continue
                fi

                print_info "正在删除规则..."

                local success=0
                local failed=0

                for idx in $(printf '%s\n' "${matched_rules[@]}" | sort -rn); do
                    local rule="${rule_map[$idx]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

                    if delete_iptables_rule_by_number "$ip_version" "$rule_num"; then
                        ((success++))
                    else
                        ((failed++))
                    fi
                done

                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service &>/dev/null; then
                    service iptables save 2>/dev/null
                    service ip6tables save 2>/dev/null
                fi

                print_success "成功删除 $success 条规则, 失败 $failed 条"
                sleep 2
                ;;

            3)
                # 按目标端口删除
                echo ""
                read -p "请输入要删除的目标端口（如: 443）: " search_port

                if [[ -z "$search_port" ]] || ! [[ "$search_port" =~ ^[0-9]+$ ]]; then
                    print_error "无效的端口号"
                    sleep 2
                    continue
                fi

                # 筛选匹配的规则
                local matched_rules=()
                for idx in "${!rule_map[@]}"; do
                    local rule="${rule_map[$idx]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

                    if [[ "$target_port" == "$search_port" ]]; then
                        matched_rules+=("$idx")
                    fi
                done

                if [[ ${#matched_rules[@]} -eq 0 ]]; then
                    print_warning "未找到匹配的规则"
                    sleep 2
                    continue
                fi

                echo ""
                echo -e "${YELLOW}找到 ${#matched_rules[@]} 条匹配规则:${NC}"
                for idx in "${matched_rules[@]}"; do
                    local rule="${rule_map[$idx]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"
                    echo "  [$idx] $ip_version | $protocol | $interface | $port_range → $target_port"
                done

                echo ""
                read -p "确认删除这 ${#matched_rules[@]} 条规则? [y/N]: " confirm
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    print_info "已取消删除"
                    sleep 1
                    continue
                fi

                print_info "正在删除规则..."

                local success=0
                local failed=0

                for idx in $(printf '%s\n' "${matched_rules[@]}" | sort -rn); do
                    local rule="${rule_map[$idx]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

                    if delete_iptables_rule_by_number "$ip_version" "$rule_num"; then
                        ((success++))
                    else
                        ((failed++))
                    fi
                done

                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service &>/dev/null; then
                    service iptables save 2>/dev/null
                    service ip6tables save 2>/dev/null
                fi

                print_success "成功删除 $success 条规则, 失败 $failed 条"
                sleep 2
                ;;

            4)
                # 删除所有规则
                echo ""
                echo -e "${RED}警告: 即将删除所有端口跳跃规则（共 ${#all_rules[@]} 条）${NC}"
                echo ""
                read -p "确认删除所有规则? [y/N]: " confirm
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    print_info "已取消删除"
                    sleep 1
                    continue
                fi

                echo ""
                read -p "再次确认删除? 输入 YES 继续: " confirm2
                if [[ "$confirm2" != "YES" ]]; then
                    print_info "已取消删除"
                    sleep 1
                    continue
                fi

                print_info "正在删除所有规则..."

                local success=0
                local failed=0

                # 从大到小删除
                for idx in $(seq ${#all_rules[@]} -1 1); do
                    local rule="${rule_map[$idx]}"
                    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

                    if delete_iptables_rule_by_number "$ip_version" "$rule_num"; then
                        ((success++))
                    else
                        ((failed++))
                    fi
                done

                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service &>/dev/null; then
                    service iptables save 2>/dev/null
                    service ip6tables save 2>/dev/null
                fi

                # 清空配置文件
                echo '{"configs":[]}' > "$PORT_HOPPING_FILE"

                print_success "成功删除 $success 条规则, 失败 $failed 条"
                sleep 2
                ;;

            0)
                return 0
                ;;

            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 修改跳跃端口配置
modify_port_hopping() {
    clear
    print_header "修改跳跃端口规则"
    echo ""

    # 获取所有规则
    local all_rules=($(detect_port_hopping_rules))

    if [[ ${#all_rules[@]} -eq 0 ]]; then
        print_warning "系统中暂无端口跳跃规则"
        echo ""
        read -p "按回车键返回..."
        return 0
    fi

    # 显示规则列表
    echo -e "${CYAN}当前端口跳跃规则:${NC}"
    echo ""
    printf "${CYAN}%-4s %-8s %-10s %-12s %-15s %-12s${NC}\n" "序号" "IP版本" "协议" "接口" "源端口范围" "目标端口"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    local -A rule_map
    for rule in "${all_rules[@]}"; do
        IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$rule"

        [[ -z "$interface" || "$interface" == "*" ]] && interface="all"
        [[ -z "$port_range" ]] && port_range="N/A"
        [[ -z "$target_port" ]] && target_port="N/A"

        printf "%-4s %-8s %-10s %-12s %-15s %-12s\n" "$index" "$ip_version" "$protocol" "$interface" "$port_range" "$target_port"

        rule_map[$index]="$rule"
        ((index++))
    done

    echo ""
    read -p "请输入要修改的规则序号 [0=返回]: " select_idx

    if [[ "$select_idx" == "0" ]]; then
        return 0
    fi

    if [[ ! "$select_idx" =~ ^[0-9]+$ ]] || [[ "$select_idx" -lt 1 ]] || [[ "$select_idx" -gt ${#all_rules[@]} ]]; then
        print_error "无效的序号"
        sleep 2
        return 1
    fi

    # 获取选中的规则
    local selected_rule="${rule_map[$select_idx]}"
    IFS='|' read -r rule_num ip_version protocol interface port_range target_port <<< "$selected_rule"

    clear
    print_header "修改规则 #$select_idx"
    echo ""

    echo -e "${CYAN}当前规则信息:${NC}"
    echo -e "  IP版本: $ip_version"
    echo -e "  协议: $protocol"
    echo -e "  网络接口: $interface"
    echo -e "  源端口范围: $port_range"
    echo -e "  目标端口: $target_port"
    echo ""

    echo -e "${CYAN}修改选项:${NC}"
    echo -e "${GREEN}1.${NC} 修改源端口范围"
    echo -e "${GREEN}2.${NC} 修改目标端口"
    echo ""

    print_nav_options "true" "true"
    local modify_choice=$(read_menu_choice "请选择操作")
    local ret=$?

    # 处理导航
    [[ $ret -eq 99 ]] && return 0  # 返回上级
    [[ $ret -eq 98 ]] && return 0  # 返回主菜单

    case $modify_choice in
        1)
            # 修改源端口范围
            echo ""
            echo -e "${YELLOW}提示: 修改端口范围将删除旧规则并创建新规则${NC}"
            read -p "请输入新的源端口范围（如: 30000:60000）: " new_port_range

            if [[ -z "$new_port_range" ]] || [[ ! "$new_port_range" =~ ^[0-9]+:[0-9]+$ ]]; then
                print_error "无效的端口范围格式"
                sleep 2
                return 1
            fi

            read -p "确认将 $port_range 修改为 $new_port_range ? [y/N]: " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                print_info "已取消修改"
                sleep 1
                return 0
            fi

            print_info "正在修改规则..."

            # 删除旧规则
            local cmd=""
            [[ "$ip_version" == "ipv4" ]] && cmd="iptables"
            [[ "$ip_version" == "ipv6" ]] && cmd="ip6tables"

            if ! $cmd -t nat -D PREROUTING "$rule_num" 2>/dev/null; then
                print_error "删除旧规则失败"
                sleep 2
                return 1
            fi

            # 添加新规则
            if $cmd -t nat -A PREROUTING -i "$interface" -p "$protocol" --dport "$new_port_range" -j REDIRECT --to-ports "$target_port" 2>/dev/null; then
                # 保存规则
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service &>/dev/null; then
                    service iptables save 2>/dev/null
                    service ip6tables save 2>/dev/null
                fi

                print_success "源端口范围已修改: $port_range → $new_port_range"
            else
                print_error "添加新规则失败，正在回滚..."
                # 尝试恢复旧规则
                $cmd -t nat -A PREROUTING -i "$interface" -p "$protocol" --dport "$port_range" -j REDIRECT --to-ports "$target_port" 2>/dev/null
            fi

            sleep 2
            ;;

        2)
            # 修改目标端口
            echo ""
            echo -e "${YELLOW}提示: 修改目标端口将删除旧规则并创建新规则${NC}"
            read -p "请输入新的目标端口（如: 8443）: " new_target_port

            if [[ -z "$new_target_port" ]] || ! [[ "$new_target_port" =~ ^[0-9]+$ ]] || [[ "$new_target_port" -lt 1 ]] || [[ "$new_target_port" -gt 65535 ]]; then
                print_error "无效的端口号"
                sleep 2
                return 1
            fi

            read -p "确认将目标端口 $target_port 修改为 $new_target_port ? [y/N]: " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                print_info "已取消修改"
                sleep 1
                return 0
            fi

            print_info "正在修改规则..."

            # 删除旧规则
            local cmd=""
            [[ "$ip_version" == "ipv4" ]] && cmd="iptables"
            [[ "$ip_version" == "ipv6" ]] && cmd="ip6tables"

            if ! $cmd -t nat -D PREROUTING "$rule_num" 2>/dev/null; then
                print_error "删除旧规则失败"
                sleep 2
                return 1
            fi

            # 添加新规则
            if $cmd -t nat -A PREROUTING -i "$interface" -p "$protocol" --dport "$port_range" -j REDIRECT --to-ports "$new_target_port" 2>/dev/null; then
                # 保存规则
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service &>/dev/null; then
                    service iptables save 2>/dev/null
                    service ip6tables save 2>/dev/null
                fi

                print_success "目标端口已修改: $target_port → $new_target_port"
            else
                print_error "添加新规则失败，正在回滚..."
                # 尝试恢复旧规则
                $cmd -t nat -A PREROUTING -i "$interface" -p "$protocol" --dport "$port_range" -j REDIRECT --to-ports "$target_port" 2>/dev/null
            fi

            sleep 2
            ;;

        0)
            return 0
            ;;

        *)
            print_error "无效选择"
            sleep 1
            ;;
    esac
}

# 跳跃端口管理子菜单
port_hopping_menu() {
    while true; do
        clear
        print_header "跳跃端口管理"
        echo ""

        init_port_hopping_file

        echo -e "${YELLOW}说明: 端口跳跃通过 iptables NAT 规则实现,将端口范围的流量重定向到目标端口${NC}"
        echo ""

        print_section_start
        print_menu_item "1" "查看跳跃配置"
        print_menu_item "2" "添加跳跃配置"
        print_menu_item "3" "修改跳跃配置"
        print_menu_item "4" "删除跳跃配置"
        print_menu_item "0" "返回上级菜单"
        print_section_end

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择操作 [0-4]")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return 0  # 返回上级
        [[ $ret -eq 98 ]] && return 98  # 返回主菜单

        case $choice in
            1) list_port_hopping; wait_for_input ;;
            2) add_port_hopping; wait_for_input ;;
            3) modify_port_hopping; wait_for_input ;;
            4) delete_port_hopping; wait_for_input ;;
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
            4)
                port_hopping_menu
                [[ $? -eq 98 ]] && return  # 传播返回主菜单
                ;;
            5) show_firewall_rules; wait_for_input ;;
            6) enable_firewall; wait_for_input ;;
            7) disable_firewall; wait_for_input ;;
            8) reset_firewall; wait_for_input ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 初始化端口跳跃数据文件
init_port_hopping_file
