#!/bin/bash

#================================================================
# 状态监控模块
# 功能：查看运行状态、流量统计、连接信息、日志、实时监控
#================================================================

# 查看运行状态
show_status() {
    clear
    echo -e "${CYAN}====== sing-box 运行状态 ======${NC}\n"

    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box 未安装"
        return 1
    fi

    # 服务状态
    echo -e "${CYAN}服务状态：${NC}"
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}● 运行中${NC}"
    else
        echo -e "${RED}● 已停止${NC}"
        return 0
    fi

    # 版本信息
    echo -e "\n${CYAN}版本信息：${NC}"
    sing-box version | head -n1

    # 运行时长
    echo -e "\n${CYAN}运行时长：${NC}"
    systemctl show sing-box --property=ActiveEnterTimestamp --no-pager | cut -d'=' -f2

    # 内存使用
    echo -e "\n${CYAN}资源使用：${NC}"
    local pid=$(pgrep -f "sing-box")
    if [[ -n "$pid" ]]; then
        ps aux | grep "$pid" | grep -v grep | awk '{printf "CPU: %s%%  内存: %s%%\n", $3, $4}'
    fi

    # 端口监听
    echo -e "\n${CYAN}端口监听：${NC}"
    ss -tlnp | grep sing-box | awk '{print $4}' | cut -d':' -f2 | sort -n | uniq | paste -sd ' '

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

    if declare -f singbox_has_stats_capability >/dev/null 2>&1 \
        && ! singbox_has_stats_capability; then
        print_warning "当前内核未启用 with_v2ray_api，流量统计不可用"
        print_info "节点创建与代理功能不受影响；可在 sing-box 管理中更新/修复内核"
        return 0
    fi

    if ! systemctl is-active --quiet sing-box; then
        print_error "sing-box 未运行"
        return 1
    fi

    local bin stats api_addr="${SINGBOX_API_ADDR:-127.0.0.1:10085}"
    if declare -f get_singbox_bin >/dev/null 2>&1; then
        bin=$(get_singbox_bin)
    else
        bin=$(command -v sing-box)
    fi
    [[ -x "$bin" ]] || { print_error "sing-box 命令不可用"; return 1; }
    if ! stats=$("$bin" api statsquery --server="$api_addr" -pattern "traffic" 2>/dev/null); then
        print_error "无法连接 V2Ray Stats API: $api_addr"
        print_info "请重新生成配置并确认 experimental.v2ray_api 已启用"
        return 1
    fi
    echo "$stats" | jq -e '.stat | type == "array"' >/dev/null 2>&1 || {
        print_error "Stats API 返回了无效数据"
        return 1
    }

    echo -e "${CYAN}总流量统计：${NC}"
    echo "----------------------------------------"

    echo "$stats" | jq -r '
        [.stat[]? | select(.name | startswith("inbound>>>"))
         | (.name | split(">>>")) as $parts
         | {name:$parts[1], direction:$parts[3], value:(.value // 0)}]
        | group_by(.name)[]
        | .[0].name as $name
        | ([.[] | select(.direction=="uplink") | .value] | add // 0) as $up
        | ([.[] | select(.direction=="downlink") | .value] | add // 0) as $down
        | "\($name): 上行 \(($up/1048576*100|round)/100) MB  下行 \(($down/1048576*100|round)/100) MB"' 2>/dev/null

    echo ""
    echo -e "${CYAN}用户流量统计：${NC}"
    echo "----------------------------------------"

    echo "$stats" | jq -r '
        [.stat[]? | select(.name | startswith("user>>>"))
         | (.name | split(">>>")) as $parts
         | {name:$parts[1], direction:$parts[3], value:(.value // 0)}]
        | group_by(.name)[]
        | .[0].name as $name
        | ([.[] | select(.direction=="uplink") | .value] | add // 0) as $up
        | ([.[] | select(.direction=="downlink") | .value] | add // 0) as $down
        | "\($name): 上行 \(($up/1048576*100|round)/100) MB  下行 \(($down/1048576*100|round)/100) MB"' 2>/dev/null
}

# 查看连接信息
show_connections() {
    clear
    echo -e "${CYAN}====== 当前连接 ======${NC}\n"

    if ! systemctl is-active --quiet sing-box; then
        print_error "sing-box 未运行"
        return 1
    fi

    if ! declare -f refresh_connection_snapshot >/dev/null 2>&1 || ! refresh_connection_snapshot; then
        print_error "无法读取 sing-box 实时连接数据"
        print_info "请确认 sing-box 正常运行，并重新生成一次配置"
        return 1
    fi

    local total_connections online_users
    total_connections=$(get_realtime_connection_count 2>/dev/null || echo "N/A")
    online_users=$(get_realtime_online_users_count 2>/dev/null || echo "N/A")
    [[ "$online_users" != "UNAVAILABLE" ]] || online_users="数据不可用"

    echo -e "${CYAN}实时概览：${NC}"
    echo "----------------------------------------"
    echo "在线用户: $online_users"
    echo "活动连接: $total_connections"
    echo ""
    render_realtime_node_connection_table

    echo ""
    echo -e "${CYAN}连接详情（前10条）：${NC}"
    printf "%-7s %-22s %-16s %-22s %-28s\n" "网络" "节点" "用户" "来源" "目标"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    while IFS=$'\t' read -r network inbound user source target; do
        printf "%-7s %-22s %-16s %-22s %-28s\n" "$network" "$inbound" "$user" "$source" "$target"
    done < <(jq -r '
        .connections[:10][]?
        | [(.metadata.network // "-"),
           (.metadata.type // "-"),
           (.metadata.inboundUser // "-"),
           ((.metadata.sourceIP // "-") + ":" + ((.metadata.sourcePort // "-") | tostring)),
           ((if (.metadata.host // "") != "" then .metadata.host else (.metadata.destinationIP // "-") end)
             + ":" + ((.metadata.destinationPort // "-") | tostring))]
        | @tsv' <<< "$CONNECTION_SNAPSHOT_JSON" 2>/dev/null)
}

# 查看日志
show_logs() {
    clear
    echo -e "${CYAN}====== sing-box 日志 ======${NC}\n"

    echo "1. 查看实时日志"
    echo "2. 查看访问日志"
    echo "3. 查看错误日志"
    echo "4. 查看 systemd 日志"
    echo ""
    print_nav_options "true" "true"

    choice=$(read_menu_choice "请选择")
    local ret=$?

    # 处理导航
    [[ $ret -eq 98 ]] && return 0  # 返回主菜单

    case $choice in
        1)
            print_info "按 Ctrl+C 退出日志查看"
            sleep 2
            journalctl -u sing-box -f
            ;;
        2)
            if [[ -f "${SINGBOX_DIR}/access.log" ]]; then
                less +G "${SINGBOX_DIR}/access.log"
            else
                print_warning "访问日志文件不存在"
            fi
            ;;
        3)
            if [[ -f "${SINGBOX_DIR}/error.log" ]]; then
                less +G "${SINGBOX_DIR}/error.log"
            else
                print_warning "错误日志文件不存在"
            fi
            ;;
        4)
            journalctl -u sing-box --no-pager -n 100
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
    print_info "每 2 秒刷新，按 q 返回"
    echo ""

    while true; do
        clear
        echo -e "${CYAN}====== sing-box 实时监控 ======${NC}"
        echo -e "${CYAN}更新时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}\n"

        # 服务状态
        if systemctl is-active --quiet sing-box; then
            echo -e "${GREEN}● 服务运行中${NC}"
        else
            echo -e "${RED}● 服务已停止${NC}"
            local stopped_key=""
            read -rsn1 -t 2 stopped_key || true
            [[ "$stopped_key" =~ ^[Qq]$ ]] && break
            continue
        fi

        # CPU和内存
        local pid=$(pgrep -f "sing-box")
        if [[ -n "$pid" ]]; then
            echo ""
            echo -e "${CYAN}资源使用：${NC}"
            ps aux | grep "$pid" | grep -v grep | awk '{printf "CPU: %5s%%  内存: %5s%%  进程: %s\n", $3, $4, $2}'
        fi

        # 实时在线用户与节点连接
        echo ""
        echo -e "${CYAN}实时连接：${NC}"
        if refresh_connection_snapshot; then
            local total_conn online_users
            total_conn=$(get_realtime_connection_count 2>/dev/null || echo "N/A")
            online_users=$(get_realtime_online_users_count 2>/dev/null || echo "N/A")
            [[ "$online_users" != "UNAVAILABLE" ]] || online_users="数据不可用"
            echo "在线用户: $online_users  |  活动连接: $total_conn"
            echo ""
            render_realtime_node_connection_table
        else
            print_warning "实时连接数据暂不可用"
        fi

        # 最新日志
        echo ""
        echo -e "${CYAN}最新日志（最近5条）：${NC}"
        journalctl -u sing-box --no-pager -n 5 --output=short-precise | tail -5

        local key=""
        read -rsn1 -t 2 key || true
        [[ "$key" =~ ^[Qq]$ ]] && break
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

    begin_data_transaction || return 1
    if ! update_json_file '(.users[]?.traffic_used_gb) = "0"' "$USERS_FILE" \
        || ! atomic_write_json "${TRAFFIC_COUNTERS_FILE:-${DATA_DIR}/traffic_counters.json}" '{"users":{}}'; then
        rollback_data_transaction
        print_error "流量账本重置失败，操作已回滚"
        return 1
    fi
    if ! restart_sing-box; then
        print_error "服务重启失败，流量账本已回滚"
        return 1
    fi

    print_success "运行时统计和持久化流量账本已重置"
}

# 导出统计数据
export_stats() {
    clear
    echo -e "${CYAN}====== 导出统计数据 ======${NC}"

    if declare -f singbox_has_stats_capability >/dev/null 2>&1 \
        && ! singbox_has_stats_capability; then
        print_warning "当前内核未启用 with_v2ray_api，没有可导出的运行时流量统计"
        print_info "节点创建与代理功能不受影响"
        return 0
    fi

    local export_file="${DATA_DIR}/stats_export_$(date +%Y%m%d_%H%M%S).json"

    local bin stats api_addr="${SINGBOX_API_ADDR:-127.0.0.1:10085}" temp_file
    if declare -f get_singbox_bin >/dev/null 2>&1; then
        bin=$(get_singbox_bin)
    else
        bin=$(command -v sing-box)
    fi
    if [[ ! -x "$bin" ]] || ! stats=$("$bin" api statsquery --server="$api_addr" -pattern "traffic" 2>/dev/null) \
        || ! echo "$stats" | jq -e '.stat | type == "array"' >/dev/null 2>&1; then
        print_error "无法获取统计数据"
        return 1
    fi

    temp_file=$(mktemp "${DATA_DIR}/stats_export_XXXXXX.json") || return 1
    if ! jq -n --arg exported_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson runtime "$stats" \
        --slurpfile users "$USERS_FILE" --slurpfile ledger "${TRAFFIC_COUNTERS_FILE:-${DATA_DIR}/traffic_counters.json}" \
        '{exported_at:$exported_at,runtime:$runtime,users:($users[0] // {users:[]}),traffic_ledger:($ledger[0] // {users:{}})}' \
        > "$temp_file" || ! mv "$temp_file" "$export_file"; then
        rm -f "$temp_file"
        print_error "统计数据导出失败"
        return 1
    fi
    chmod 600 "$export_file"
    print_success "统计数据已导出到: $export_file"
}
