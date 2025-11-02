#!/bin/bash

#================================================================
# 状态监控模块
# 功能：查看运行状态、流量统计、连接信息、日志、实时监控
#================================================================

# 查看运行状态
show_status() {
    clear
    echo -e "${CYAN}====== Xray 运行状态 ======${NC}\n"

    if [[ ! -f "$XRAY_BIN" ]]; then
        print_error "Xray 未安装"
        return 1
    fi

    # 服务状态
    echo -e "${CYAN}服务状态：${NC}"
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}● 运行中${NC}"
    else
        echo -e "${RED}● 已停止${NC}"
        return 0
    fi

    # 版本信息
    echo -e "\n${CYAN}版本信息：${NC}"
    "$XRAY_BIN" version | head -n1

    # 运行时长
    echo -e "\n${CYAN}运行时长：${NC}"
    systemctl show xray --property=ActiveEnterTimestamp --no-pager | cut -d'=' -f2

    # 内存使用
    echo -e "\n${CYAN}资源使用：${NC}"
    local pid=$(pgrep -f "$XRAY_BIN")
    if [[ -n "$pid" ]]; then
        ps aux | grep "$pid" | grep -v grep | awk '{printf "CPU: %s%%  内存: %s%%\n", $3, $4}'
    fi

    # 端口监听
    echo -e "\n${CYAN}端口监听：${NC}"
    ss -tlnp | grep xray | awk '{print $4}' | cut -d':' -f2 | sort -n | uniq | paste -sd ' '

    # 节点数量
    echo -e "\n${CYAN}节点统计：${NC}"
    local node_count=$(jq -r '.nodes | length' "$NODES_FILE" 2>/dev/null || echo "0")
    local user_count=$(jq -r '.users | length' "$USERS_FILE" 2>/dev/null || echo "0")
    echo "节点数: $node_count  |  用户数: $user_count"
}

# 查看流量统计
show_traffic() {
    clear
    echo -e "${CYAN}====== 流量统计 ======${NC}\n"

    if ! systemctl is-active --quiet xray; then
        print_error "Xray 未运行"
        return 1
    fi

    # 使用 xray API 获取统计信息
    local api_port=10085
    local api_addr="127.0.0.1:${api_port}"

    # 检查API是否可用
    if ! nc -z 127.0.0.1 "$api_port" 2>/dev/null; then
        print_warning "API 服务未配置或未启动"
        echo ""
        echo "请确保配置文件中包含以下内容："
        echo '  "api": {'
        echo '    "tag": "api",'
        echo '    "services": ["HandlerService", "StatsService"]'
        echo '  }'
        return 1
    fi

    echo -e "${CYAN}总流量统计：${NC}"
    echo "----------------------------------------"

    # 获取入站流量统计
    local inbound_stats=$(curl -s "http://${api_addr}/stats" 2>/dev/null)

    if [[ -n "$inbound_stats" ]]; then
        echo "$inbound_stats" | jq -r '.stat[]? | select(.name | contains("inbound")) | "\(.name): 上行 \(.value.uplink|tonumber/1024/1024|floor)MB 下行 \(.value.downlink|tonumber/1024/1024|floor)MB"' 2>/dev/null
    else
        print_warning "无法获取流量统计"
    fi

    echo ""
    echo -e "${CYAN}用户流量统计：${NC}"
    echo "----------------------------------------"

    # 获取用户流量统计
    if [[ -n "$inbound_stats" ]]; then
        echo "$inbound_stats" | jq -r '.stat[]? | select(.name | contains("user")) | "\(.name): 上行 \(.value.uplink|tonumber/1024/1024|floor)MB 下行 \(.value.downlink|tonumber/1024/1024|floor)MB"' 2>/dev/null
    fi
}

# 查看连接信息
show_connections() {
    clear
    echo -e "${CYAN}====== 当前连接 ======${NC}\n"

    if ! systemctl is-active --quiet xray; then
        print_error "Xray 未运行"
        return 1
    fi

    # 获取监听端口
    local ports=$(ss -tlnp | grep xray | awk '{print $4}' | cut -d':' -f2 | sort -n | uniq)

    echo -e "${CYAN}活动连接数：${NC}"
    echo "----------------------------------------"

    local total_connections=0

    for port in $ports; do
        local conn_count=$(ss -tn | grep ":${port}" | wc -l)
        echo "端口 ${port}: ${conn_count} 个连接"
        total_connections=$((total_connections + conn_count))
    done

    echo "----------------------------------------"
    echo "总连接数: $total_connections"

    echo ""
    echo -e "${CYAN}连接详情（前10条）：${NC}"
    echo "----------------------------------------"
    printf "%-20s %-10s %-25s %-25s\n" "协议" "状态" "本地地址" "远程地址"
    echo "----------------------------------------"

    for port in $ports; do
        ss -tn | grep ":${port}" | head -10 | awk '{printf "%-20s %-10s %-25s %-25s\n", "TCP", $1, $3, $4}'
    done
}

# 查看日志
show_logs() {
    clear
    echo -e "${CYAN}====== Xray 日志 ======${NC}\n"

    echo "1. 查看实时日志"
    echo "2. 查看访问日志"
    echo "3. 查看错误日志"
    echo "4. 查看 systemd 日志"
    echo "0. 返回"
    echo ""
    read -p "请选择 [0-4]: " choice

    case $choice in
        1)
            print_info "按 Ctrl+C 退出日志查看"
            sleep 2
            journalctl -u xray -f
            ;;
        2)
            if [[ -f "${XRAY_DIR}/access.log" ]]; then
                less +G "${XRAY_DIR}/access.log"
            else
                print_warning "访问日志文件不存在"
            fi
            ;;
        3)
            if [[ -f "${XRAY_DIR}/error.log" ]]; then
                less +G "${XRAY_DIR}/error.log"
            else
                print_warning "错误日志文件不存在"
            fi
            ;;
        4)
            journalctl -u xray --no-pager -n 100
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            ;;
    esac
}

# 实时监控
monitor_realtime() {
    clear
    echo -e "${CYAN}====== 实时监控 ======${NC}"
    print_info "按 Ctrl+C 退出监控"
    echo ""

    while true; do
        clear
        echo -e "${CYAN}====== Xray 实时监控 ======${NC}"
        echo -e "${CYAN}更新时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}\n"

        # 服务状态
        if systemctl is-active --quiet xray; then
            echo -e "${GREEN}● 服务运行中${NC}"
        else
            echo -e "${RED}● 服务已停止${NC}"
            sleep 5
            continue
        fi

        # CPU和内存
        local pid=$(pgrep -f "$XRAY_BIN")
        if [[ -n "$pid" ]]; then
            echo ""
            echo -e "${CYAN}资源使用：${NC}"
            ps aux | grep "$pid" | grep -v grep | awk '{printf "CPU: %5s%%  内存: %5s%%  进程: %s\n", $3, $4, $2}'
        fi

        # 连接数统计
        echo ""
        echo -e "${CYAN}连接统计：${NC}"
        local ports=$(ss -tlnp | grep xray | awk '{print $4}' | cut -d':' -f2 | sort -n | uniq)
        local total_conn=0

        for port in $ports; do
            local conn=$(ss -tn | grep ":${port}" | wc -l)
            printf "端口 %-6s: %3s 连接\n" "$port" "$conn"
            total_conn=$((total_conn + conn))
        done
        echo "总连接数: $total_conn"

        # 流量速率（简化版）
        echo ""
        echo -e "${CYAN}网络流量：${NC}"
        local rx1=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0)
        local tx1=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || echo 0)
        sleep 1
        local rx2=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0)
        local tx2=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || echo 0)

        local rx_rate=$(((rx2 - rx1) / 1024))
        local tx_rate=$(((tx2 - tx1) / 1024))

        printf "下载: %6s KB/s  上传: %6s KB/s\n" "$rx_rate" "$tx_rate"

        # 最新日志
        echo ""
        echo -e "${CYAN}最新日志（最近5条）：${NC}"
        journalctl -u xray --no-pager -n 5 --output=short-precise | tail -5

        sleep 3
    done
}

# 流量重置
reset_traffic() {
    clear
    echo -e "${CYAN}====== 重置流量统计 ======${NC}"

    read -p "确认重置所有流量统计? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消重置"
        return 0
    fi

    # 重启服务以重置统计
    systemctl restart xray

    print_success "流量统计已重置"
}

# 导出统计数据
export_stats() {
    clear
    echo -e "${CYAN}====== 导出统计数据 ======${NC}"

    local export_file="${DATA_DIR}/stats_export_$(date +%Y%m%d_%H%M%S).json"

    # 获取统计数据
    local api_port=10085
    local stats=$(curl -s "http://127.0.0.1:${api_port}/stats" 2>/dev/null)

    if [[ -n "$stats" ]]; then
        echo "$stats" | jq . > "$export_file"
        print_success "统计数据已导出到: $export_file"
    else
        print_error "无法获取统计数据"
        return 1
    fi
}
