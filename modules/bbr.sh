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

# 定义测试服务器（多地区）
declare -A TEST_SERVERS=(
    ["中国大陆"]="speedtest.tele2.net"
    ["中国台湾"]="tpdb.speedtest.com.tw"
    ["中国香港"]="speedtest.hkbn.net"
    ["日本"]="speedtest.i-o.jp"
    ["俄罗斯"]="speedtest.dataline.net"
    ["美国"]="speedtest.verizon.net"
    ["新加坡"]="speedtest.singnet.com.sg"
)

# 测试延迟
test_latency() {
    local target=$1
    local name=$2

    echo -e "${YELLOW}测试 $name 延迟...${NC}"
    local ping_result=$(ping -c 10 -W 2 "$target" 2>/dev/null | tail -1)
    if [[ -n "$ping_result" ]]; then
        local avg_latency=$(echo "$ping_result" | awk -F'/' '{print $5}')
        local packet_loss=$(ping -c 10 -W 2 "$target" 2>/dev/null | grep 'packet loss' | awk '{print $6}')
        echo -e "  平均延迟: ${GREEN}${avg_latency} ms${NC}"
        echo -e "  丢包率: ${GREEN}${packet_loss}${NC}"
    else
        echo -e "  ${RED}测试失败${NC}"
    fi
    echo ""
}

# 测试丢包率（高级）
test_packet_loss() {
    local target=$1
    local name=$2

    echo -e "${YELLOW}测试 $name 丢包情况...${NC}"

    # 使用mtr进行更准确的丢包测试
    if command -v mtr &>/dev/null; then
        local mtr_result=$(mtr -c 50 -r -n "$target" 2>/dev/null | tail -1)
        if [[ -n "$mtr_result" ]]; then
            local loss=$(echo "$mtr_result" | awk '{print $3}')
            local avg=$(echo "$mtr_result" | awk '{print $6}')
            echo -e "  丢包率: ${GREEN}${loss}%${NC}"
            echo -e "  平均延迟: ${GREEN}${avg} ms${NC}"
        fi
    else
        # 使用ping作为备选
        local result=$(ping -c 50 -W 2 "$target" 2>/dev/null)
        if [[ -n "$result" ]]; then
            local loss=$(echo "$result" | grep 'packet loss' | awk '{print $6}')
            local avg=$(echo "$result" | tail -1 | awk -F'/' '{print $5}')
            echo -e "  丢包率: ${GREEN}${loss}${NC}"
            echo -e "  平均延迟: ${GREEN}${avg} ms${NC}"
        fi
    fi
    echo ""
}

# 测试吞吐量（使用curl下载测试文件）
test_throughput() {
    local url=$1
    local name=$2

    echo -e "${YELLOW}测试 $name 吞吐量...${NC}"

    # 使用curl下载测试（10MB文件）
    local speed=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 15 "$url" 2>/dev/null)
    if [[ -n "$speed" && "$speed" != "0" ]]; then
        # 转换为 Mbps
        local mbps=$(echo "scale=2; $speed * 8 / 1000000" | bc 2>/dev/null || echo "N/A")
        echo -e "  下载速度: ${GREEN}${mbps} Mbps${NC}"
    else
        echo -e "  ${RED}测试失败或超时${NC}"
    fi
    echo ""
}

# 综合性能测试
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
    echo -e "${GREEN}1.${NC} 快速测试（延迟 + 丢包）"
    echo -e "${GREEN}2.${NC} 完整测试（延迟 + 丢包 + 吞吐量）"
    echo -e "${GREEN}3.${NC} 自定义地区测试"
    echo -e "${GREEN}4.${NC} BBR加速效果对比测试（推荐）"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-4]: " test_choice

    case $test_choice in
        1)
            # 快速测试
            echo ""
            echo -e "${CYAN}━━━━━━━ 开始快速测试 ━━━━━━━${NC}"
            echo ""

            # 安装mtr（如果需要）
            if ! command -v mtr &>/dev/null; then
                print_info "正在安装 mtr 工具..."
                if command -v apt-get &>/dev/null; then
                    apt-get install -y mtr-tiny >/dev/null 2>&1
                elif command -v yum &>/dev/null; then
                    yum install -y mtr >/dev/null 2>&1
                fi
            fi

            # 测试主要地区
            for region in "中国台湾" "日本" "美国"; do
                local server="${TEST_SERVERS[$region]}"
                echo -e "${CYAN}━━━━━━━ $region ━━━━━━━${NC}"
                test_latency "$server" "$region"
            done
            ;;

        2)
            # 完整测试
            echo ""
            echo -e "${CYAN}━━━━━━━ 开始完整测试 ━━━━━━━${NC}"
            echo ""

            # 安装必要工具
            if ! command -v mtr &>/dev/null; then
                print_info "正在安装 mtr 工具..."
                if command -v apt-get &>/dev/null; then
                    apt-get install -y mtr-tiny >/dev/null 2>&1
                elif command -v yum &>/dev/null; then
                    yum install -y mtr >/dev/null 2>&1
                fi
            fi

            if ! command -v bc &>/dev/null; then
                if command -v apt-get &>/dev/null; then
                    apt-get install -y bc >/dev/null 2>&1
                elif command -v yum &>/dev/null; then
                    yum install -y bc >/dev/null 2>&1
                fi
            fi

            # 测试所有地区
            for region in "${!TEST_SERVERS[@]}"; do
                local server="${TEST_SERVERS[$region]}"
                echo -e "${CYAN}━━━━━━━ $region ━━━━━━━${NC}"
                test_latency "$server" "$region"
                test_packet_loss "$server" "$region"

                # 吞吐量测试（使用公开的测试文件）
                case $region in
                    "日本")
                        test_throughput "http://speedtest.tokyo.linode.com/100MB-tokyo.bin" "$region"
                        ;;
                    "美国")
                        test_throughput "http://speedtest.newark.linode.com/100MB-newark.bin" "$region"
                        ;;
                    "新加坡")
                        test_throughput "http://speedtest.singapore.linode.com/100MB-singapore.bin" "$region"
                        ;;
                esac

                echo ""
            done
            ;;

        3)
            # 自定义地区测试
            echo ""
            echo -e "${YELLOW}可用测试地区：${NC}"
            local index=1
            local regions=()
            for region in "${!TEST_SERVERS[@]}"; do
                echo -e "${GREEN}$index.${NC} $region"
                regions+=("$region")
                ((index++))
            done
            echo ""
            read -p "请选择地区 [1-${#regions[@]}]: " region_choice

            if [[ "$region_choice" =~ ^[0-9]+$ ]] && [[ "$region_choice" -ge 1 ]] && [[ "$region_choice" -le "${#regions[@]}" ]]; then
                local selected_region="${regions[$((region_choice-1))]}"
                local server="${TEST_SERVERS[$selected_region]}"

                echo ""
                echo -e "${CYAN}━━━━━━━ 测试 $selected_region ━━━━━━━${NC}"
                echo ""
                test_latency "$server" "$selected_region"
                test_packet_loss "$server" "$selected_region"
            else
                print_error "无效选择"
            fi
            ;;

        4)
            # BBR加速效果对比测试
            echo ""
            echo -e "${CYAN}━━━━━━━ BBR 加速效果对比测试 ━━━━━━━${NC}"
            echo ""

            # 保存当前算法
            local original_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
            local original_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "pfifo_fast")

            print_info "将分别测试 Cubic（默认）和 BBR 的性能"
            echo ""

            # 选择测试地区
            echo -e "${YELLOW}请选择测试地区：${NC}"
            echo -e "${GREEN}1.${NC} 中国大陆（默认）"
            echo -e "${GREEN}2.${NC} 日本（推荐）"
            echo -e "${GREEN}3.${NC} 美国"
            echo -e "${GREEN}4.${NC} 俄罗斯"
            echo -e "${GREEN}5.${NC} 中国台湾"
            echo ""
            read -p "请选择 [1-5]: " region_choice

            local test_region=""
            local test_server=""
            local throughput_url=""

            case $region_choice in
                1)
                    test_region="中国大陆"
                    test_server="speedtest.tele2.net"
                    throughput_url=""
                    ;;
                2)
                    test_region="日本"
                    test_server="speedtest.i-o.jp"
                    throughput_url="http://speedtest.tokyo.linode.com/100MB-tokyo.bin"
                    ;;
                3)
                    test_region="美国"
                    test_server="speedtest.verizon.net"
                    throughput_url="http://speedtest.newark.linode.com/100MB-newark.bin"
                    ;;
                4)
                    test_region="俄罗斯"
                    test_server="speedtest.dataline.net"
                    throughput_url=""
                    ;;
                5)
                    test_region="中国台湾"
                    test_server="tpdb.speedtest.com.tw"
                    throughput_url=""
                    ;;
                *)
                    print_error "无效选择"
                    return 0
                    ;;
            esac

            echo ""
            print_info "测试地区: $test_region"
            print_info "测试服务器: $test_server"
            print_warning "测试过程需要约2-3分钟，请耐心等待..."
            echo ""

            # 检查网络连通性
            if ! ping -c 1 -W 2 "$test_server" &>/dev/null; then
                print_error "无法连接到测试服务器 $test_server"
                print_info "请检查网络连接或选择其他地区"
                read -p "按 Enter 继续..."
                return 0
            fi

            # 第一阶段：Cubic测试
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo -e "${YELLOW}[1/2] 测试 Cubic（默认算法）${NC}"
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo ""

            # 切换到Cubic
            sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
            sysctl -w net.core.default_qdisc=pfifo_fast > /dev/null 2>&1
            sleep 2

            # 验证切换成功
            local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
            print_info "当前算法: $current"

            # Cubic测试 - 延迟
            echo -e "${YELLOW}测试延迟...${NC}"
            local cubic_latency=$(ping -c 10 -W 2 "$test_server" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
            if [[ -z "$cubic_latency" ]]; then
                cubic_latency="N/A"
            fi
            echo -e "${GREEN}Cubic 延迟:${NC} ${cubic_latency} ms"

            # Cubic测试 - 丢包
            echo -e "${YELLOW}测试丢包率...${NC}"
            local cubic_loss=$(ping -c 20 -W 2 "$test_server" 2>/dev/null | grep 'packet loss' | awk '{print $6}')
            if [[ -z "$cubic_loss" ]]; then
                cubic_loss="N/A"
            fi
            echo -e "${GREEN}Cubic 丢包率:${NC} ${cubic_loss}"

            # Cubic测试 - 吞吐量
            local cubic_throughput="N/A"
            if [[ -n "$throughput_url" ]]; then
                echo -e "${YELLOW}测试吞吐量...${NC}"
                local cubic_speed=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 15 "$throughput_url" 2>/dev/null)
                if [[ -n "$cubic_speed" && "$cubic_speed" != "0" ]]; then
                    cubic_throughput=$(awk "BEGIN {printf \"%.2f\", $cubic_speed * 8 / 1000000}")
                fi
                echo -e "${GREEN}Cubic 吞吐量:${NC} ${cubic_throughput} Mbps"
            fi

            echo ""
            sleep 2

            # 第二阶段：BBR测试
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo -e "${YELLOW}[2/2] 测试 BBR（加速算法）${NC}"
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo ""

            # 切换到BBR
            modprobe tcp_bbr 2>/dev/null
            sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
            sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
            sleep 2

            # 验证切换成功
            local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
            print_info "当前算法: $current"
            if [[ "$current" != "bbr" ]]; then
                print_warning "BBR切换失败，可能内核不支持"
            fi

            # BBR测试 - 延迟
            echo -e "${YELLOW}测试延迟...${NC}"
            local bbr_latency=$(ping -c 10 -W 2 "$test_server" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
            if [[ -z "$bbr_latency" ]]; then
                bbr_latency="N/A"
            fi
            echo -e "${GREEN}BBR 延迟:${NC} ${bbr_latency} ms"

            # BBR测试 - 丢包
            echo -e "${YELLOW}测试丢包率...${NC}"
            local bbr_loss=$(ping -c 20 -W 2 "$test_server" 2>/dev/null | grep 'packet loss' | awk '{print $6}')
            if [[ -z "$bbr_loss" ]]; then
                bbr_loss="N/A"
            fi
            echo -e "${GREEN}BBR 丢包率:${NC} ${bbr_loss}"

            # BBR测试 - 吞吐量
            local bbr_throughput="N/A"
            if [[ -n "$throughput_url" ]]; then
                echo -e "${YELLOW}测试吞吐量...${NC}"
                local bbr_speed=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 15 "$throughput_url" 2>/dev/null)
                if [[ -n "$bbr_speed" && "$bbr_speed" != "0" ]]; then
                    bbr_throughput=$(awk "BEGIN {printf \"%.2f\", $bbr_speed * 8 / 1000000}")
                fi
                echo -e "${GREEN}BBR 吞吐量:${NC} ${bbr_throughput} Mbps"
            fi

            echo ""
            sleep 1

            # 对比结果
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo -e "${YELLOW}📊 性能对比结果（$test_region）${NC}"
            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo ""

            # 延迟对比
            if [[ "$cubic_latency" != "N/A" && "$bbr_latency" != "N/A" ]]; then
                echo -e "${YELLOW}延迟对比：${NC}"
                echo -e "  Cubic: $cubic_latency ms"
                echo -e "  BBR:   $bbr_latency ms"

                local latency_diff=$(awk "BEGIN {printf \"%.2f\", $cubic_latency - $bbr_latency}")
                local is_improved=$(awk "BEGIN {if ($cubic_latency > $bbr_latency) print 1; else print 0}")

                if [[ "$is_improved" == "1" ]]; then
                    echo -e "  ${GREEN}✓ BBR 延迟降低 ${latency_diff} ms${NC}"
                else
                    local abs_diff=${latency_diff#-}
                    echo -e "  ${YELLOW}✗ BBR 延迟增加 ${abs_diff} ms（正常，BBR优先吞吐量）${NC}"
                fi
                echo ""
            fi

            # 丢包对比
            echo -e "${YELLOW}丢包率对比：${NC}"
            echo -e "  Cubic: $cubic_loss"
            echo -e "  BBR:   $bbr_loss"
            echo ""

            # 吞吐量对比
            if [[ "$cubic_throughput" != "N/A" && "$bbr_throughput" != "N/A" ]]; then
                echo -e "${YELLOW}吞吐量对比：${NC}"
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
                echo ""
            fi

            echo -e "${CYAN}═══════════════════════════════════════${NC}"
            echo ""

            # 恢复原始设置
            echo ""
            print_info "正在恢复原始设置..."
            if sysctl -w net.ipv4.tcp_congestion_control="$original_algo" > /dev/null 2>&1; then
                print_success "算法已恢复为: $original_algo"
            else
                print_warning "恢复算法失败"
            fi
            sysctl -w net.core.default_qdisc="$original_qdisc" > /dev/null 2>&1

            echo ""
            print_success "对比测试完成！"
            echo ""
            print_info "💡 说明："
            echo -e "  • BBR 优化高延迟、丢包场景的吞吐量"
            echo -e "  • 在良好网络环境下，提升可能不明显"
            echo -e "  • 建议在实际使用场景中测试效果"
            echo ""
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
