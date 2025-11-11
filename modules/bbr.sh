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

    # 验证配置是否生效
    sleep 1
    local new_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    local new_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}')

    if [[ "$new_algo" == "bbr" ]]; then
        print_success "✅ BBR V1 已成功启用！"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "${YELLOW}BBR 状态信息：${NC}"
        echo -e "${CYAN}═══════════════════════════════════════${NC}"
        echo -e "  拥塞控制算法: ${GREEN}$new_algo${NC}"
        echo -e "  队列算法: ${GREEN}$new_qdisc${NC}"
        echo -e "  内核版本: ${GREEN}$(uname -r)${NC}"
        echo ""

        # 检查模块是否正确加载
        if lsmod | grep -q "^tcp_bbr"; then
            echo -e "${GREEN}✅ BBR 模块已正确加载${NC}"
        else
            echo -e "${YELLOW}⚠️ BBR 模块未在 lsmod 中显示（某些内核版本内置模块不显示）${NC}"
            # 进一步验证BBR是否真正工作
            if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control; then
                echo -e "${GREEN}✅ BBR 在可用算法列表中，功能正常${NC}"
            fi
        fi
    else
        print_error "BBR 启用失败，当前算法: $new_algo"
        print_info "请检查内核版本是否支持 BBR (需要 4.9+)"
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

    # BBR 模块状态检测（改进版）
    echo -e "${YELLOW}BBR 模块状态：${NC}"
    if lsmod | grep -q "^tcp_bbr"; then
        echo -e "  ${GREEN}✅ BBR 模块已加载（lsmod 可见）${NC}"
    else
        # 某些内核版本将BBR编译为内置模块，不会在lsmod中显示
        if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            echo -e "  ${GREEN}✅ BBR 功能可用（内核内置）${NC}"
        else
            echo -e "  ${RED}✗ BBR 模块未加载且不可用${NC}"
        fi
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

# 定义测试服务器（多地区）- 优化后的可靠服务器
declare -A TEST_SERVERS=(
    ["中国大陆"]="www.baidu.com"
    ["日本"]="www.yahoo.co.jp"
    ["美国"]="www.google.com"
    ["俄罗斯"]="www.yandex.ru"
    ["中国台湾"]="www.pchome.com.tw"
)

# 定义测试文件下载地址（用于吞吐量测试）
declare -A THROUGHPUT_URLS=(
    ["中国大陆"]="http://cachefly.cachefly.net/10mb.test"
    ["日本"]="http://speedtest.tokyo.linode.com/100MB-tokyo.bin"
    ["美国"]="http://speedtest.newark.linode.com/100MB-newark.bin"
    ["俄罗斯"]="http://cachefly.cachefly.net/10mb.test"
    ["中国台湾"]="http://cachefly.cachefly.net/10mb.test"
)

# 执行单次对比测试（Cubic vs BBR）
run_comparison_test() {
    local region=$1
    local test_server=$2
    local throughput_url=$3

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}测试地区: $region${NC}"
    echo -e "${YELLOW}测试服务器: $test_server${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    # 保存原始算法
    local original_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    local original_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "pfifo_fast")

    # 检查网络连通性
    print_info "检查网络连通性..."
    if ! ping -c 2 -W 3 "$test_server" &>/dev/null; then
        print_error "无法连接到测试服务器 $test_server"
        return 1
    fi
    print_success "连接正常"
    echo ""

    # ========== 第一阶段：Cubic 测试 ==========
    echo -e "${CYAN}━━━━━━━ [1/2] Cubic（默认算法）测试 ━━━━━━━${NC}"
    echo ""

    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
    sysctl -w net.core.default_qdisc=pfifo_fast > /dev/null 2>&1
    sleep 1

    # Cubic - 延迟测试
    print_info "测试延迟..."
    local cubic_latency=$(ping -c 10 -W 2 "$test_server" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    if [[ -z "$cubic_latency" ]]; then cubic_latency="N/A"; fi
    echo -e "  ${GREEN}Cubic 延迟: ${cubic_latency} ms${NC}"

    # Cubic - 丢包率测试
    print_info "测试丢包率..."
    local cubic_loss=$(ping -c 20 -W 2 "$test_server" 2>/dev/null | grep 'packet loss' | awk '{print $6}')
    if [[ -z "$cubic_loss" ]]; then cubic_loss="N/A"; fi
    echo -e "  ${GREEN}Cubic 丢包率: ${cubic_loss}${NC}"

    # Cubic - 吞吐量测试
    local cubic_throughput="N/A"
    if [[ -n "$throughput_url" ]]; then
        print_info "测试吞吐量..."
        local cubic_speed=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 15 "$throughput_url" 2>/dev/null)
        if [[ -n "$cubic_speed" && "$cubic_speed" != "0" ]]; then
            cubic_throughput=$(awk "BEGIN {printf \"%.2f\", $cubic_speed * 8 / 1000000}")
        fi
        echo -e "  ${GREEN}Cubic 吞吐量: ${cubic_throughput} Mbps${NC}"
    fi

    echo ""
    sleep 1

    # ========== 第二阶段：BBR 测试 ==========
    echo -e "${CYAN}━━━━━━━ [2/2] BBR（加速算法）测试 ━━━━━━━${NC}"
    echo ""

    modprobe tcp_bbr 2>/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
    sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
    sleep 1

    local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current" != "bbr" ]]; then
        print_warning "BBR切换失败，内核可能不支持（需要4.9+）"
        sysctl -w net.ipv4.tcp_congestion_control="$original_algo" > /dev/null 2>&1
        sysctl -w net.core.default_qdisc="$original_qdisc" > /dev/null 2>&1
        return 1
    fi

    # BBR - 延迟测试
    print_info "测试延迟..."
    local bbr_latency=$(ping -c 10 -W 2 "$test_server" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    if [[ -z "$bbr_latency" ]]; then bbr_latency="N/A"; fi
    echo -e "  ${GREEN}BBR 延迟: ${bbr_latency} ms${NC}"

    # BBR - 丢包率测试
    print_info "测试丢包率..."
    local bbr_loss=$(ping -c 20 -W 2 "$test_server" 2>/dev/null | grep 'packet loss' | awk '{print $6}')
    if [[ -z "$bbr_loss" ]]; then bbr_loss="N/A"; fi
    echo -e "  ${GREEN}BBR 丢包率: ${bbr_loss}${NC}"

    # BBR - 吞吐量测试
    local bbr_throughput="N/A"
    if [[ -n "$throughput_url" ]]; then
        print_info "测试吞吐量..."
        local bbr_speed=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 15 "$throughput_url" 2>/dev/null)
        if [[ -n "$bbr_speed" && "$bbr_speed" != "0" ]]; then
            bbr_throughput=$(awk "BEGIN {printf \"%.2f\", $bbr_speed * 8 / 1000000}")
        fi
        echo -e "  ${GREEN}BBR 吞吐量: ${bbr_throughput} Mbps${NC}"
    fi

    echo ""

    # ========== 对比分析 ==========
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}📊 性能对比结果（$region）${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 延迟对比
    if [[ "$cubic_latency" != "N/A" && "$bbr_latency" != "N/A" ]]; then
        echo -e "${YELLOW}🔹 延迟对比：${NC}"
        echo -e "  Cubic: $cubic_latency ms"
        echo -e "  BBR:   $bbr_latency ms"

        local latency_diff=$(awk "BEGIN {printf \"%.2f\", $cubic_latency - $bbr_latency}")
        local is_improved=$(awk "BEGIN {if ($cubic_latency > $bbr_latency) print 1; else print 0}")

        if [[ "$is_improved" == "1" ]]; then
            echo -e "  ${GREEN}✓ BBR 延迟降低 ${latency_diff} ms${NC}"
        else
            local abs_diff=${latency_diff#-}
            echo -e "  ${YELLOW}✗ BBR 延迟增加 ${abs_diff} ms${NC}"
        fi
    else
        echo -e "${YELLOW}🔹 延迟对比：${NC} 数据不足"
    fi
    echo ""

    # 丢包率对比
    echo -e "${YELLOW}🔹 丢包率对比：${NC}"
    echo -e "  Cubic: $cubic_loss"
    echo -e "  BBR:   $bbr_loss"
    echo ""

    # 吞吐量对比
    if [[ "$cubic_throughput" != "N/A" && "$bbr_throughput" != "N/A" ]]; then
        echo -e "${YELLOW}🔹 吞吐量对比：${NC}"
        echo -e "  Cubic: $cubic_throughput Mbps"
        echo -e "  BBR:   $bbr_throughput Mbps"

        local throughput_diff=$(awk "BEGIN {printf \"%.2f\", $bbr_throughput - $cubic_throughput}")
        local throughput_percent=$(awk "BEGIN {if ($cubic_throughput > 0) printf \"%.2f\", ($bbr_throughput - $cubic_throughput) / $cubic_throughput * 100; else print 0}")
        local is_improved=$(awk "BEGIN {if ($bbr_throughput > $cubic_throughput) print 1; else print 0}")

        if [[ "$is_improved" == "1" ]]; then
            echo -e "  ${GREEN}✓ BBR 提升 ${throughput_diff} Mbps (+${throughput_percent}%)${NC}"
        else
            local abs_diff=${throughput_diff#-}
            local abs_percent=${throughput_percent#-}
            echo -e "  ${YELLOW}✗ BBR 降低 ${abs_diff} Mbps (-${abs_percent}%)${NC}"
        fi
    else
        echo -e "${YELLOW}🔹 吞吐量对比：${NC} 数据不足"
    fi
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 恢复原始设置
    sysctl -w net.ipv4.tcp_congestion_control="$original_algo" > /dev/null 2>&1
    sysctl -w net.core.default_qdisc="$original_qdisc" > /dev/null 2>&1

    return 0
}

# BBR 性能测试主函数
test_bbr_performance() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       BBR 加速效果测试              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 显示当前BBR状态
    local current_algo=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo -e "${YELLOW}当前拥塞控制算法: ${GREEN}$current_algo${NC}"
    echo ""

    # 选择测试类型
    echo -e "${YELLOW}请选择测试类型：${NC}"
    echo -e "${GREEN}1.${NC} 快速测试（中国大陆）"
    echo -e "${GREEN}2.${NC} 其他地区测试"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-2]: " test_choice

    case $test_choice in
        1)
            # 快速测试（中国大陆）- 对比 Cubic vs BBR
            echo ""
            echo -e "${CYAN}━━━━━━━ 快速测试（中国大陆）━━━━━━━${NC}"
            echo ""

            run_comparison_test "中国大陆" "${TEST_SERVERS[中国大陆]}" "${THROUGHPUT_URLS[中国大陆]}"
            ;;

        2)
            # 其他地区测试
            echo ""
            echo -e "${YELLOW}请选择测试地区：${NC}"
            echo -e "${GREEN}1.${NC} 日本"
            echo -e "${GREEN}2.${NC} 美国"
            echo -e "${GREEN}3.${NC} 俄罗斯"
            echo -e "${GREEN}4.${NC} 中国台湾"
            echo -e "${GREEN}0.${NC} 返回"
            echo ""
            read -p "请选择 [0-4]: " region_choice

            case $region_choice in
                1)
                    run_comparison_test "日本" "${TEST_SERVERS[日本]}" "${THROUGHPUT_URLS[日本]}"
                    ;;
                2)
                    run_comparison_test "美国" "${TEST_SERVERS[美国]}" "${THROUGHPUT_URLS[美国]}"
                    ;;
                3)
                    run_comparison_test "俄罗斯" "${TEST_SERVERS[俄罗斯]}" "${THROUGHPUT_URLS[俄罗斯]}"
                    ;;
                4)
                    run_comparison_test "中国台湾" "${TEST_SERVERS[中国台湾]}" "${THROUGHPUT_URLS[中国台湾]}"
                    ;;
                0)
                    return
                    ;;
                *)
                    print_error "无效选择"
                    ;;
            esac
            ;;

        0)
            return
            ;;

        *)
            print_error "无效选择"
            ;;
    esac

    echo ""
    echo -e "${CYAN}━━━━━━━ 测试完成 ━━━━━━━${NC}"
    echo ""
    print_info "提示：BBR 对高延迟、丢包场景效果更明显"
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
        echo -e "${GREEN}1.${NC}  启用 BBR V1（Google 原版）"
        echo -e "${GREEN}2.${NC}  启用 BBR V3（Google 高级版）"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 状态管理 ━━━━━━━${NC}"
        echo -e "${GREEN}3.${NC}  查看 BBR 状态"
        echo -e "${GREEN}4.${NC}  禁用 BBR"
        echo -e "${GREEN}5.${NC}  测试加速效果"
        echo ""
        echo -e "${GREEN}0.${NC}  返回主菜单"
        echo ""
        read -p "请选择 [0-5]: " choice

        case $choice in
            1) enable_bbr; read -p "按 Enter 继续..." ;;
            2) enable_bbrv3; read -p "按 Enter 继续..." ;;
            3) show_bbr_status; read -p "按 Enter 继续..." ;;
            4) disable_bbr; read -p "按 Enter 继续..." ;;
            5) test_bbr_performance; read -p "按 Enter 继续..." ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}
