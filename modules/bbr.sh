#!/bin/bash

#================================================================
# BBR 加速管理模块
# 功能：BBR、BBRv3、BBR Plus、锐速等加速算法管理
#================================================================

# ============================================================================
# 系统检测
# ============================================================================

# 检测系统类型
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        print_error "无法检测系统类型"
        return 1
    fi
}

# 检测内核版本
check_kernel_version() {
    local kernel_version=$(uname -r | cut -d'.' -f1,2)
    echo "$kernel_version"
}

# 检查 BBR 是否可用
check_bbr_available() {
    local kernel_version=$(check_kernel_version)
    local major=$(echo "$kernel_version" | cut -d'.' -f1)
    local minor=$(echo "$kernel_version" | cut -d'.' -f2)

    # BBR 需要内核 4.9+
    if [[ "$major" -gt 4 ]] || [[ "$major" -eq 4 && "$minor" -ge 9 ]]; then
        return 0
    else
        return 1
    fi
}

# 检查 BBRv3 是否可用
check_bbrv3_available() {
    local kernel_version=$(check_kernel_version)
    local major=$(echo "$kernel_version" | cut -d'.' -f1)

    # BBRv3 需要内核 5.18+
    if [[ "$major" -ge 6 ]] || [[ "$major" -eq 5 && "$(uname -r | cut -d'.' -f2)" -ge 18 ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# BBR 管理
# ============================================================================

# 启用原版 BBR
enable_bbr() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         启用 BBR 加速                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查内核版本
    if ! check_bbr_available; then
        print_error "当前内核版本过低，BBR 需要 4.9 或更高版本"
        print_info "当前版本: $(uname -r)"
        print_info "建议升级内核后再启用 BBR"
        return 1
    fi

    # 检查是否已启用
    local current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$current_algo" == "bbr" ]]; then
        print_warning "BBR 已经启用"
        return 0
    fi

    # 加载 BBR 模块
    print_info "正在加载 BBR 模块..."
    modprobe tcp_bbr

    # 配置 sysctl
    print_info "正在配置系统参数..."

    # 备份原配置
    if [[ ! -f /etc/sysctl.conf.bak ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak
    fi

    # 写入 BBR 配置
    cat >> /etc/sysctl.conf <<EOF

# BBR 加速配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    # 应用配置
    sysctl -p

    # 验证
    local new_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$new_algo" == "bbr" ]]; then
        print_success "✅ BBR 已成功启用！"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "${YELLOW}BBR 状态信息：${NC}"
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "  拥塞控制算法: ${GREEN}$new_algo${NC}"
        echo -e "  队列算法: ${GREEN}$(sysctl net.core.default_qdisc | awk '{print $3}')${NC}"
        echo -e "  内核版本: ${GREEN}$(uname -r)${NC}"
        echo ""

        # 检查模块是否加载
        if lsmod | grep -q tcp_bbr; then
            echo -e "${GREEN}✅ BBR 模块已加载${NC}"
        fi
    else
        print_error "BBR 启用失败"
        return 1
    fi
}

# 启用 BBRv3
enable_bbrv3() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        启用 BBRv3 加速               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 检查内核版本
    if ! check_bbrv3_available; then
        print_error "BBRv3 需要内核 5.18 或更高版本"
        print_info "当前版本: $(uname -r)"
        print_info "建议升级内核后再启用 BBRv3"
        return 1
    fi

    # 检查是否已启用
    local current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$current_algo" == "bbr" ]]; then
        # 检查是否是 BBRv3
        if sysctl net.ipv4.tcp_ecn | grep -q "1"; then
            print_warning "BBRv3 可能已经启用"
        fi
    fi

    # 配置 BBRv3
    print_info "正在配置 BBRv3..."

    # 备份配置
    if [[ ! -f /etc/sysctl.conf.bak ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak
    fi

    # 写入 BBRv3 配置
    cat >> /etc/sysctl.conf <<EOF

# BBRv3 加速配置
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
EOF

    # 应用配置
    sysctl -p

    print_success "✅ BBRv3 配置已应用！"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}BBRv3 状态信息：${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "  拥塞控制算法: ${GREEN}$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')${NC}"
    echo -e "  队列算法: ${GREEN}$(sysctl net.core.default_qdisc | awk '{print $3}')${NC}"
    echo -e "  ECN 支持: ${GREEN}$(sysctl net.ipv4.tcp_ecn | awk '{print $3}')${NC}"
    echo -e "  内核版本: ${GREEN}$(uname -r)${NC}"
    echo ""
}

# 启用 BBR Plus（需要安装特定内核）
enable_bbr_plus() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      启用 BBR Plus 加速              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    print_warning "BBR Plus 需要安装特定的内核"
    print_info "这将下载并安装第三方内核，可能存在风险"
    echo ""
    read -p "是否继续？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消"
        return 0
    fi

    print_info "正在下载 BBR Plus 安装脚本..."

    # 下载安装脚本
    local install_script="/tmp/bbr-plus-install.sh"
    if ! curl -fsSL -o "$install_script" "https://github.com/chiakge/Linux-NetSpeed/raw/master/tcp.sh"; then
        print_error "下载安装脚本失败"
        return 1
    fi

    chmod +x "$install_script"

    print_info "运行安装脚本..."
    bash "$install_script"
}

# 启用锐速（Lotserver）
enable_lotserver() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        启用锐速加速                  ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    print_warning "锐速（Lotserver）是第三方闭源加速软件"
    print_info "仅支持特定内核版本"
    echo ""
    read -p "是否继续？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消"
        return 0
    fi

    print_info "正在下载锐速安装脚本..."

    # 下载安装脚本
    local install_script="/tmp/lotserver-install.sh"
    if ! curl -fsSL -o "$install_script" "https://raw.githubusercontent.com/0oVicero0/serverSpeeder_Install/master/appex.sh"; then
        print_error "下载安装脚本失败"
        return 1
    fi

    chmod +x "$install_script"

    print_info "运行安装脚本..."
    bash "$install_script" install
}

# ============================================================================
# 加速状态管理
# ============================================================================

# 查看当前加速状态
show_bbr_status() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       TCP 加速状态                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 系统信息
    echo -e "${YELLOW}系统信息：${NC}"
    echo -e "  操作系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo -e "  内核版本: $(uname -r)"
    echo ""

    # 当前拥塞控制算法
    echo -e "${YELLOW}拥塞控制算法：${NC}"
    local current_algo=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ -n "$current_algo" ]]; then
        if [[ "$current_algo" == "bbr" ]]; then
            echo -e "  当前算法: ${GREEN}$current_algo${NC}"
        else
            echo -e "  当前算法: ${YELLOW}$current_algo${NC}"
        fi
    else
        echo -e "  当前算法: ${RED}未知${NC}"
    fi
    echo ""

    # 队列算法
    echo -e "${YELLOW}队列算法：${NC}"
    local qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    if [[ -n "$qdisc" ]]; then
        echo -e "  队列算法: ${GREEN}$qdisc${NC}"
    else
        echo -e "  队列算法: ${RED}未知${NC}"
    fi
    echo ""

    # BBR 支持检查
    echo -e "${YELLOW}BBR 支持：${NC}"
    if check_bbr_available; then
        echo -e "  BBR:  ${GREEN}✓ 支持${NC} (需要内核 4.9+)"
    else
        echo -e "  BBR:  ${RED}✗ 不支持${NC} (当前内核版本过低)"
    fi

    if check_bbrv3_available; then
        echo -e "  BBRv3: ${GREEN}✓ 支持${NC} (需要内核 5.18+)"
    else
        echo -e "  BBRv3: ${YELLOW}✗ 不支持${NC} (当前内核版本过低)"
    fi
    echo ""

    # 可用的拥塞控制算法
    echo -e "${YELLOW}可用的拥塞控制算法：${NC}"
    local available_algos=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | cut -d'=' -f2)
    if [[ -n "$available_algos" ]]; then
        echo -e "  $available_algos"
    else
        echo -e "  ${RED}无法获取${NC}"
    fi
    echo ""

    # BBR 模块状态
    if lsmod | grep -q tcp_bbr; then
        echo -e "${GREEN}✅ BBR 模块已加载${NC}"
    else
        echo -e "${YELLOW}⚠ BBR 模块未加载${NC}"
    fi
    echo ""

    # ECN 状态（BBRv3）
    local ecn_status=$(sysctl net.ipv4.tcp_ecn 2>/dev/null | awk '{print $3}')
    if [[ "$ecn_status" == "1" ]]; then
        echo -e "${GREEN}✅ ECN 已启用（可能使用 BBRv3）${NC}"
    fi
}

# 禁用 BBR
disable_bbr() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         禁用 BBR 加速                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    print_warning "确认要禁用 BBR 吗？"
    read -p "输入 yes 确认: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消"
        return 0
    fi

    print_info "正在禁用 BBR..."

    # 恢复默认配置
    sysctl -w net.ipv4.tcp_congestion_control=cubic
    sysctl -w net.core.default_qdisc=pfifo_fast

    # 从配置文件中删除 BBR 配置
    if [[ -f /etc/sysctl.conf ]]; then
        sed -i '/# BBR/d' /etc/sysctl.conf
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_ecn/d' /etc/sysctl.conf
    fi

    # 应用配置
    sysctl -p

    print_success "BBR 已禁用"
    print_info "当前拥塞控制算法: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
}

# 测试加速效果
test_bbr_performance() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       测试 BBR 加速效果              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    print_info "将进行网络性能测试..."
    echo ""

    # 检查 iperf3 是否安装
    if ! command -v iperf3 &>/dev/null; then
        print_warning "iperf3 未安装"
        read -p "是否安装 iperf3？[y/N]: " install_choice
        if [[ "$install_choice" == "y" || "$install_choice" == "Y" ]]; then
            if command -v apt-get &>/dev/null; then
                apt-get update && apt-get install -y iperf3
            elif command -v yum &>/dev/null; then
                yum install -y iperf3
            else
                print_error "无法安装 iperf3"
                return 1
            fi
        else
            return 1
        fi
    fi

    # 简单的网络测试
    print_info "测试方法：使用 speedtest-cli 进行速度测试"

    # 安装 speedtest-cli
    if ! command -v speedtest &>/dev/null; then
        print_info "正在安装 speedtest-cli..."
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y speedtest-cli
        elif command -v yum &>/dev/null; then
            yum install -y speedtest-cli
        else
            # 使用 curl 安装
            curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
            apt-get install -y speedtest
        fi
    fi

    # 运行速度测试
    if command -v speedtest &>/dev/null; then
        print_info "正在测试网络速度..."
        speedtest
    else
        print_warning "speedtest 安装失败，跳过性能测试"
    fi
}

# ============================================================================
# BBR 主菜单
# ============================================================================

menu_bbr() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║       BBR 加速管理                   ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""

        # 显示当前状态
        local current_algo=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
        if [[ "$current_algo" == "bbr" ]]; then
            echo -e "${GREEN}当前状态: BBR 已启用${NC}"
        else
            echo -e "${YELLOW}当前状态: BBR 未启用 (当前: $current_algo)${NC}"
        fi
        echo ""

        echo -e "${YELLOW}━━━━━━━ BBR 管理 ━━━━━━━${NC}"
        echo -e "${GREEN}1.${NC}  启用 BBR（原版）"
        echo -e "${GREEN}2.${NC}  启用 BBRv3（高级版）"
        echo -e "${GREEN}3.${NC}  启用 BBR Plus（需安装内核）"
        echo -e "${GREEN}4.${NC}  启用锐速（Lotserver）"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 状态管理 ━━━━━━━${NC}"
        echo -e "${GREEN}5.${NC}  查看 BBR 状态"
        echo -e "${GREEN}6.${NC}  禁用 BBR"
        echo -e "${GREEN}7.${NC}  测试加速效果"
        echo ""
        echo -e "${GREEN}0.${NC}  返回主菜单"
        echo ""
        read -p "请选择 [0-7]: " choice

        case $choice in
            1) enable_bbr; read -p "按 Enter 继续..." ;;
            2) enable_bbrv3; read -p "按 Enter 继续..." ;;
            3) enable_bbr_plus; read -p "按 Enter 继续..." ;;
            4) enable_lotserver; read -p "按 Enter 继续..." ;;
            5) show_bbr_status; read -p "按 Enter 继续..." ;;
            6) disable_bbr; read -p "按 Enter 继续..." ;;
            7) test_bbr_performance; read -p "按 Enter 继续..." ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}
