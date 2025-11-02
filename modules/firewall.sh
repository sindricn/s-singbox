#!/bin/bash

#================================================================
# 防火墙管理模块
# 功能：开放端口、关闭端口、查看规则、重置防火墙
#================================================================

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
    echo -e "${CYAN}====== 开放端口 ======${NC}"

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
    echo -e "${CYAN}====== 关闭端口 ======${NC}"

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
    echo -e "${CYAN}====== 防火墙规则 ======${NC}\n"

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
    echo -e "${CYAN}====== 重置防火墙 ======${NC}"

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
    echo -e "${CYAN}====== 禁用防火墙 ======${NC}"

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
    echo -e "${CYAN}====== 启用防火墙 ======${NC}"

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
    echo -e "${CYAN}====== 批量开放端口 ======${NC}"

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

    echo -e "${CYAN}将开放以下端口：${NC}"
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

    print_success "成功开放 $success 个端口，失败 $failed 个"
}
