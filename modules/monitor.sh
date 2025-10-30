#!/bin/bash

# =============================================================================
# sing-box 监控统计模块
# 功能：流量统计、在线用户、服务状态监控
# =============================================================================

DATA_DIR="./data"
STATS_DIR="${DATA_DIR}/stats"
LOG_FILE="/var/log/singbox/singbox.log"

# =============================================================================
# 初始化统计目录
# =============================================================================

init_stats_dir() {
    if [[ ! -d "$STATS_DIR" ]]; then
        mkdir -p "$STATS_DIR"
        print_success "统计目录已创建: $STATS_DIR"
    fi
}

# =============================================================================
# 服务状态监控
# =============================================================================

# 检查 sing-box 服务状态
check_service_status() {
    print_info "sing-box 服务状态:"

    if systemctl is-active --quiet sing-box; then
        print_success "服务状态: 运行中"

        # 运行时间
        local uptime=$(systemctl show sing-box --property=ActiveEnterTimestamp --value)
        print_info "启动时间: $uptime"

        # 内存使用
        local memory=$(systemctl show sing-box --property=MemoryCurrent --value)
        if [[ -n "$memory" && "$memory" != "0" ]]; then
            local memory_mb=$((memory / 1024 / 1024))
            print_info "内存使用: ${memory_mb} MB"
        fi

        # 进程ID
        local pid=$(systemctl show sing-box --property=MainPID --value)
        print_info "进程 PID: $pid"

        return 0
    else
        print_error "服务状态: 已停止"
        return 1
    fi
}

# 实时监控服务状态
watch_service_status() {
    print_info "实时监控 sing-box 服务 (Ctrl+C 退出)"
    echo ""

    while true; do
        clear
        check_service_status
        echo ""
        check_connections
        echo ""
        sleep 3
    done
}

# =============================================================================
# 连接统计
# =============================================================================

# 检查活动连接
check_connections() {
    print_info "活动连接统计:"

    # 获取所有节点端口
    local ports=$(jq -r '.nodes[].port' "${DATA_DIR}/nodes.json" 2>/dev/null)

    if [[ -z "$ports" ]]; then
        print_warn "暂无节点配置"
        return 0
    fi

    local total_connections=0

    # 统计每个端口的连接数
    while IFS= read -r port; do
        local connections=0

        if command -v ss &>/dev/null; then
            connections=$(ss -tn | grep ":${port}" | grep ESTAB | wc -l)
        elif command -v netstat &>/dev/null; then
            connections=$(netstat -tn | grep ":${port}" | grep ESTABLISHED | wc -l)
        fi

        if [[ $connections -gt 0 ]]; then
            local protocol=$(jq -r --arg port "$port" '.nodes[] | select(.port == $port) | .protocol' "${DATA_DIR}/nodes.json")
            print_info "  端口 $port ($protocol): $connections 个连接"
            total_connections=$((total_connections + connections))
        fi
    done <<< "$ports"

    print_success "总连接数: $total_connections"
}

# 查看端口连接详情
show_port_connections() {
    read -p "请输入端口号: " port

    if [[ -z "$port" ]]; then
        print_error "端口号不能为空"
        return 1
    fi

    print_info "端口 $port 的连接详情:"

    if command -v ss &>/dev/null; then
        ss -tnp | grep ":${port}"
    elif command -v netstat &>/dev/null; then
        netstat -tnp | grep ":${port}"
    else
        print_error "未找到 ss 或 netstat 命令"
        return 1
    fi
}

# =============================================================================
# 流量统计
# =============================================================================

# 获取网络接口流量
get_interface_traffic() {
    local interface=${1:-eth0}

    if [[ ! -f "/sys/class/net/${interface}/statistics/rx_bytes" ]]; then
        print_error "网络接口不存在: $interface"
        return 1
    fi

    local rx_bytes=$(cat "/sys/class/net/${interface}/statistics/rx_bytes")
    local tx_bytes=$(cat "/sys/class/net/${interface}/statistics/tx_bytes")

    # 转换为 MB
    local rx_mb=$((rx_bytes / 1024 / 1024))
    local tx_mb=$((tx_bytes / 1024 / 1024))

    # 转换为 GB
    local rx_gb=$((rx_bytes / 1024 / 1024 / 1024))
    local tx_gb=$((tx_bytes / 1024 / 1024 / 1024))

    print_info "网络接口: $interface"
    print_info "下行流量: ${rx_gb} GB (${rx_mb} MB)"
    print_info "上行流量: ${tx_gb} GB (${tx_mb} MB)"
    print_info "总流量: $((rx_gb + tx_gb)) GB"
}

# 实时流量监控
watch_traffic() {
    local interface=${1:-eth0}

    print_info "实时流量监控: $interface (Ctrl+C 退出)"
    echo ""

    # 获取初始流量
    local rx_bytes_start=$(cat "/sys/class/net/${interface}/statistics/rx_bytes")
    local tx_bytes_start=$(cat "/sys/class/net/${interface}/statistics/tx_bytes")

    while true; do
        sleep 1

        # 获取当前流量
        local rx_bytes=$(cat "/sys/class/net/${interface}/statistics/rx_bytes")
        local tx_bytes=$(cat "/sys/class/net/${interface}/statistics/tx_bytes")

        # 计算速率 (字节/秒)
        local rx_rate=$((rx_bytes - rx_bytes_start))
        local tx_rate=$((tx_bytes - tx_bytes_start))

        # 转换为 KB/s
        local rx_kbps=$((rx_rate / 1024))
        local tx_kbps=$((tx_rate / 1024))

        # 清屏并显示
        clear
        echo -e "\033[32m实时流量监控: $interface\033[0m"
        echo "================================"
        echo -e "下行速率: \033[34m${rx_kbps} KB/s\033[0m"
        echo -e "上行速率: \033[34m${tx_kbps} KB/s\033[0m"
        echo "================================"

        # 更新起始值
        rx_bytes_start=$rx_bytes
        tx_bytes_start=$tx_bytes
    done
}

# =============================================================================
# 日志分析
# =============================================================================

# 分析日志错误
analyze_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        print_error "日志文件不存在: $LOG_FILE"
        return 1
    fi

    print_info "分析 sing-box 日志..."

    # 错误统计
    local error_count=$(grep -i "error" "$LOG_FILE" | wc -l)
    local warn_count=$(grep -i "warn" "$LOG_FILE" | wc -l)

    print_info "错误数量: $error_count"
    print_info "警告数量: $warn_count"

    # 显示最近的错误
    if [[ $error_count -gt 0 ]]; then
        echo ""
        print_warn "最近 10 条错误:"
        grep -i "error" "$LOG_FILE" | tail -10
    fi

    # 显示最近的警告
    if [[ $warn_count -gt 0 ]]; then
        echo ""
        print_warn "最近 10 条警告:"
        grep -i "warn" "$LOG_FILE" | tail -10
    fi
}

# 查看实时日志
tail_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        print_error "日志文件不存在: $LOG_FILE"
        return 1
    fi

    print_info "实时日志 (Ctrl+C 退出):"
    echo ""

    tail -f "$LOG_FILE"
}

# 搜索日志
search_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        print_error "日志文件不存在: $LOG_FILE"
        return 1
    fi

    read -p "请输入搜索关键词: " keyword

    if [[ -z "$keyword" ]]; then
        print_error "关键词不能为空"
        return 1
    fi

    print_info "搜索日志: $keyword"
    echo ""

    grep -i "$keyword" "$LOG_FILE" | tail -50
}

# =============================================================================
# 性能监控
# =============================================================================

# 系统资源监控
check_system_resources() {
    print_info "系统资源使用情况:"

    # CPU 使用率
    if command -v top &>/dev/null; then
        local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
        print_info "CPU 使用率: ${cpu_usage}%"
    fi

    # 内存使用率
    if command -v free &>/dev/null; then
        local mem_total=$(free -m | awk 'NR==2 {print $2}')
        local mem_used=$(free -m | awk 'NR==2 {print $3}')
        local mem_percent=$((mem_used * 100 / mem_total))
        print_info "内存使用: ${mem_used}MB / ${mem_total}MB (${mem_percent}%)"
    fi

    # 磁盘使用率
    if command -v df &>/dev/null; then
        local disk_usage=$(df -h / | awk 'NR==2 {print $5}')
        print_info "磁盘使用: $disk_usage"
    fi

    # 系统负载
    if [[ -f /proc/loadavg ]]; then
        local load=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
        print_info "系统负载: $load"
    fi
}

# =============================================================================
# 用户统计
# =============================================================================

# 统计在线用户（通过连接数估算）
estimate_online_users() {
    print_info "估算在线用户数..."

    local total_connections=0

    # 获取所有节点端口
    local ports=$(jq -r '.nodes[].port' "${DATA_DIR}/nodes.json" 2>/dev/null)

    if [[ -z "$ports" ]]; then
        print_warn "暂无节点配置"
        return 0
    fi

    # 统计每个端口的连接数
    while IFS= read -r port; do
        local connections=0

        if command -v ss &>/dev/null; then
            connections=$(ss -tn | grep ":${port}" | grep ESTAB | wc -l)
        elif command -v netstat &>/dev/null; then
            connections=$(netstat -tn | grep ":${port}" | grep ESTABLISHED | wc -l)
        fi

        total_connections=$((total_connections + connections))
    done <<< "$ports"

    # 假设每个用户平均 2 个连接
    local estimated_users=$((total_connections / 2))

    print_success "估算在线用户: $estimated_users 人 (基于 $total_connections 个连接)"
}

# =============================================================================
# 统计报告
# =============================================================================

# 生成统计报告
generate_stats_report() {
    local report_file="${STATS_DIR}/report_$(date +%Y%m%d_%H%M%S).txt"

    print_info "生成统计报告: $report_file"

    {
        echo "================================"
        echo "sing-box 统计报告"
        echo "生成时间: $(date)"
        echo "================================"
        echo ""

        echo "# 服务状态"
        if systemctl is-active --quiet sing-box; then
            echo "状态: 运行中"
        else
            echo "状态: 已停止"
        fi
        echo ""

        echo "# 连接统计"
        check_connections 2>&1 | grep -v "INFO"
        echo ""

        echo "# 节点统计"
        jq -r '.nodes[] | "\(.protocol):\(.port)"' "${DATA_DIR}/nodes.json" 2>/dev/null
        echo ""

        echo "# 用户统计"
        jq -r '.users[] | "\(.username) - \(.email)"' "${DATA_DIR}/users.json" 2>/dev/null
        echo ""

        echo "# 系统资源"
        check_system_resources 2>&1 | grep -v "INFO"
        echo ""

    } > "$report_file"

    print_success "报告已生成: $report_file"

    # 询问是否查看
    read -p "是否查看报告? [Y/n]: " view
    view=${view:-Y}

    if [[ "$view" =~ ^[Yy]$ ]]; then
        cat "$report_file"
    fi
}

# =============================================================================
# 监控菜单
# =============================================================================

monitor_menu() {
    while true; do
        clear
        print_header "监控统计"

        echo "1)  服务状态"
        echo "2)  实时监控服务"
        echo "3)  连接统计"
        echo "4)  端口连接详情"
        echo "5)  网络流量统计"
        echo "6)  实时流量监控"
        echo "7)  日志分析"
        echo "8)  实时日志"
        echo "9)  搜索日志"
        echo "10) 系统资源"
        echo "11) 在线用户估算"
        echo "12) 生成统计报告"
        echo ""
        echo "0)  返回主菜单"
        echo ""

        read -p "请选择: " choice

        case "$choice" in
            1)
                check_service_status
                read -p "按回车键继续..."
                ;;
            2)
                watch_service_status
                ;;
            3)
                check_connections
                read -p "按回车键继续..."
                ;;
            4)
                show_port_connections
                read -p "按回车键继续..."
                ;;
            5)
                read -p "请输入网络接口 [eth0]: " interface
                interface=${interface:-eth0}
                get_interface_traffic "$interface"
                read -p "按回车键继续..."
                ;;
            6)
                read -p "请输入网络接口 [eth0]: " interface
                interface=${interface:-eth0}
                watch_traffic "$interface"
                ;;
            7)
                analyze_logs
                read -p "按回车键继续..."
                ;;
            8)
                tail_logs
                ;;
            9)
                search_logs
                read -p "按回车键继续..."
                ;;
            10)
                check_system_resources
                read -p "按回车键继续..."
                ;;
            11)
                estimate_online_users
                read -p "按回车键继续..."
                ;;
            12)
                generate_stats_report
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

# 初始化
init_stats_dir
