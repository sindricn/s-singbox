#!/bin/bash

# =============================================================================
# sing-box 防火墙管理模块
# 功能：端口开放、规则管理、安全配置
# =============================================================================

# =============================================================================
# 防火墙检测
# =============================================================================

# 检测使用的防火墙
detect_firewall() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo "firewalld"
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        echo "ufw"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

# =============================================================================
# Firewalld 管理
# =============================================================================

# Firewalld: 开放端口
firewalld_open_port() {
    local port=$1
    local protocol=${2:-tcp}

    print_info "使用 firewalld 开放端口 $port/$protocol"

    firewall-cmd --permanent --add-port="${port}/${protocol}"
    firewall-cmd --reload

    if [[ $? -eq 0 ]]; then
        print_success "端口已开放: $port/$protocol"
        return 0
    else
        print_error "端口开放失败"
        return 1
    fi
}

# Firewalld: 关闭端口
firewalld_close_port() {
    local port=$1
    local protocol=${2:-tcp}

    print_info "使用 firewalld 关闭端口 $port/$protocol"

    firewall-cmd --permanent --remove-port="${port}/${protocol}"
    firewall-cmd --reload

    if [[ $? -eq 0 ]]; then
        print_success "端口已关闭: $port/$protocol"
        return 0
    else
        print_error "端口关闭失败"
        return 1
    fi
}

# Firewalld: 列出开放端口
firewalld_list_ports() {
    print_info "firewalld 开放的端口:"
    firewall-cmd --list-ports
}

# =============================================================================
# UFW 管理
# =============================================================================

# UFW: 开放端口
ufw_open_port() {
    local port=$1
    local protocol=${2:-tcp}

    print_info "使用 ufw 开放端口 $port/$protocol"

    ufw allow "${port}/${protocol}"

    if [[ $? -eq 0 ]]; then
        print_success "端口已开放: $port/$protocol"
        return 0
    else
        print_error "端口开放失败"
        return 1
    fi
}

# UFW: 关闭端口
ufw_close_port() {
    local port=$1
    local protocol=${2:-tcp}

    print_info "使用 ufw 关闭端口 $port/$protocol"

    ufw delete allow "${port}/${protocol}"

    if [[ $? -eq 0 ]]; then
        print_success "端口已关闭: $port/$protocol"
        return 0
    else
        print_error "端口关闭失败"
        return 1
    fi
}

# UFW: 列出规则
ufw_list_rules() {
    print_info "ufw 防火墙规则:"
    ufw status numbered
}

# =============================================================================
# iptables 管理
# =============================================================================

# iptables: 开放端口
iptables_open_port() {
    local port=$1
    local protocol=${2:-tcp}

    print_info "使用 iptables 开放端口 $port/$protocol"

    # 检查规则是否已存在
    if iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null; then
        print_warn "规则已存在"
        return 0
    fi

    # 添加规则
    iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT

    if [[ $? -eq 0 ]]; then
        # 保存规则
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi

        print_success "端口已开放: $port/$protocol"
        return 0
    else
        print_error "端口开放失败"
        return 1
    fi
}

# iptables: 关闭端口
iptables_close_port() {
    local port=$1
    local protocol=${2:-tcp}

    print_info "使用 iptables 关闭端口 $port/$protocol"

    # 删除规则
    iptables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null

    if [[ $? -eq 0 ]]; then
        # 保存规则
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi

        print_success "端口已关闭: $port/$protocol"
        return 0
    else
        print_error "端口关闭失败"
        return 1
    fi
}

# iptables: 列出规则
iptables_list_rules() {
    print_info "iptables 防火墙规则:"
    iptables -L INPUT -n --line-numbers | grep -E "ACCEPT.*dpt:"
}

# =============================================================================
# 通用端口管理
# =============================================================================

# 开放端口（自动检测防火墙）
open_port() {
    local port=$1
    local protocol=${2:-tcp}

    local fw=$(detect_firewall)

    case "$fw" in
        firewalld)
            firewalld_open_port "$port" "$protocol"
            ;;
        ufw)
            ufw_open_port "$port" "$protocol"
            ;;
        iptables)
            iptables_open_port "$port" "$protocol"
            ;;
        none)
            print_warn "未检测到防火墙，跳过端口开放"
            return 0
            ;;
    esac
}

# 关闭端口（自动检测防火墙）
close_port() {
    local port=$1
    local protocol=${2:-tcp}

    local fw=$(detect_firewall)

    case "$fw" in
        firewalld)
            firewalld_close_port "$port" "$protocol"
            ;;
        ufw)
            ufw_close_port "$port" "$protocol"
            ;;
        iptables)
            iptables_close_port "$port" "$protocol"
            ;;
        none)
            print_warn "未检测到防火墙"
            return 0
            ;;
    esac
}

# 列出防火墙规则
list_firewall_rules() {
    local fw=$(detect_firewall)

    print_info "当前使用的防火墙: $fw"
    echo ""

    case "$fw" in
        firewalld)
            firewalld_list_ports
            ;;
        ufw)
            ufw_list_rules
            ;;
        iptables)
            iptables_list_rules
            ;;
        none)
            print_warn "未检测到防火墙"
            ;;
    esac
}

# =============================================================================
# 节点端口批量管理
# =============================================================================

# 开放所有节点端口
open_all_node_ports() {
    print_info "开放所有节点端口..."

    local DATA_DIR="./data"
    local NODES_FILE="${DATA_DIR}/nodes.json"

    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "节点配置文件不存在"
        return 1
    fi

    local node_count=$(jq '.nodes | length' "$NODES_FILE")

    if [[ $node_count -eq 0 ]]; then
        print_warn "暂无节点"
        return 0
    fi

    local success_count=0

    for ((i=0; i<node_count; i++)); do
        local node=$(jq -r ".nodes[$i]" "$NODES_FILE")
        local port=$(echo "$node" | jq -r '.port')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local transport=$(echo "$node" | jq -r '.transport')

        # 确定协议类型（TCP/UDP）
        local proto="tcp"
        if [[ "$protocol" == "hysteria2" || "$protocol" == "tuic" ]]; then
            proto="udp"
        fi

        echo ""
        print_info "开放节点端口: $protocol:$port ($proto)"

        if open_port "$port" "$proto"; then
            ((success_count++))
        fi
    done

    echo ""
    print_success "成功开放 $success_count / $node_count 个端口"
}

# 关闭所有节点端口
close_all_node_ports() {
    print_warn "此操作将关闭所有节点端口，可能导致服务不可用"

    read -p "确认关闭所有节点端口? [y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return 0
    fi

    print_info "关闭所有节点端口..."

    local DATA_DIR="./data"
    local NODES_FILE="${DATA_DIR}/nodes.json"

    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "节点配置文件不存在"
        return 1
    fi

    local node_count=$(jq '.nodes | length' "$NODES_FILE")

    if [[ $node_count -eq 0 ]]; then
        print_warn "暂无节点"
        return 0
    fi

    local success_count=0

    for ((i=0; i<node_count; i++)); do
        local node=$(jq -r ".nodes[$i]" "$NODES_FILE")
        local port=$(echo "$node" | jq -r '.port')
        local protocol=$(echo "$node" | jq -r '.protocol')

        # 确定协议类型（TCP/UDP）
        local proto="tcp"
        if [[ "$protocol" == "hysteria2" || "$protocol" == "tuic" ]]; then
            proto="udp"
        fi

        echo ""
        print_info "关闭节点端口: $protocol:$port ($proto)"

        if close_port "$port" "$proto"; then
            ((success_count++))
        fi
    done

    echo ""
    print_success "成功关闭 $success_count / $node_count 个端口"
}

# =============================================================================
# 安全配置
# =============================================================================

# 开启 BBR 拥塞控制
enable_bbr() {
    print_info "启用 BBR 拥塞控制算法..."

    # 检查内核版本
    local kernel_version=$(uname -r | cut -d. -f1)

    if [[ $kernel_version -lt 4 ]]; then
        print_error "内核版本过低，需要 4.9 以上才能使用 BBR"
        return 1
    fi

    # 检查是否已启用
    local current_cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

    if [[ "$current_cc" == "bbr" ]]; then
        print_success "BBR 已启用"
        return 0
    fi

    # 启用 BBR
    cat >> /etc/sysctl.conf <<EOF

# BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # 应用配置
    sysctl -p

    # 验证
    current_cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

    if [[ "$current_cc" == "bbr" ]]; then
        print_success "BBR 已成功启用"
    else
        print_error "BBR 启用失败"
        return 1
    fi
}

# 优化网络参数
optimize_network() {
    print_info "优化网络参数..."

    # 备份原配置
    cp /etc/sysctl.conf /etc/sysctl.conf.bak

    # 添加优化参数
    cat >> /etc/sysctl.conf <<EOF

# sing-box 网络优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF

    # 应用配置
    sysctl -p

    print_success "网络参数已优化"
}

# =============================================================================
# 防火墙菜单
# =============================================================================

firewall_menu() {
    while true; do
        clear
        print_header "防火墙管理"

        local fw=$(detect_firewall)
        print_info "当前防火墙: $fw"
        echo ""

        echo "1)  开放端口"
        echo "2)  关闭端口"
        echo "3)  列出规则"
        echo "4)  开放所有节点端口"
        echo "5)  关闭所有节点端口"
        echo "6)  启用 BBR"
        echo "7)  优化网络参数"
        echo ""
        echo "0)  返回主菜单"
        echo ""

        read -p "请选择: " choice

        case "$choice" in
            1)
                read -p "请输入端口号: " port
                echo "请选择协议:"
                echo "1) TCP"
                echo "2) UDP"
                read -p "请选择 [1]: " proto_choice
                proto_choice=${proto_choice:-1}

                local protocol="tcp"
                [[ "$proto_choice" == "2" ]] && protocol="udp"

                open_port "$port" "$protocol"
                read -p "按回车键继续..."
                ;;
            2)
                read -p "请输入端口号: " port
                echo "请选择协议:"
                echo "1) TCP"
                echo "2) UDP"
                read -p "请选择 [1]: " proto_choice
                proto_choice=${proto_choice:-1}

                local protocol="tcp"
                [[ "$proto_choice" == "2" ]] && protocol="udp"

                close_port "$port" "$protocol"
                read -p "按回车键继续..."
                ;;
            3)
                list_firewall_rules
                read -p "按回车键继续..."
                ;;
            4)
                open_all_node_ports
                read -p "按回车键继续..."
                ;;
            5)
                close_all_node_ports
                read -p "按回车键继续..."
                ;;
            6)
                enable_bbr
                read -p "按回车键继续..."
                ;;
            7)
                optimize_network
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# 通用打印函数
# =============================================================================

print_header() {
    echo ""
    echo -e "\033[32m======================================\033[0m"
    echo -e "\033[32m  $1\033[0m"
    echo -e "\033[32m======================================\033[0m"
    echo ""
}

print_info() {
    echo -e "\033[34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[32m[SUCCESS]\033[0m $1"
}

print_error() {
    echo -e "\033[31m[ERROR]\033[0m $1"
}

print_warn() {
    echo -e "\033[33m[WARN]\033[0m $1"
}
