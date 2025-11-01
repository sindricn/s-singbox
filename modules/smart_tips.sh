#!/bin/bash

# =============================================================================
# smart_tips.sh - 智能提示系统
# 提供系统健康检查、配置检测、证书监控、性能警告等智能提示
# =============================================================================

# 依赖检查
if [[ -z "${SCRIPT_DIR}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# NOTE: 依赖模块已在主文件中加载
# 依赖: common.sh (print_error, print_info, print_success 等函数)

# =============================================================================
# 提示级别定义
# =============================================================================

readonly TIP_LEVEL_INFO="INFO"
readonly TIP_LEVEL_WARNING="WARNING"
readonly TIP_LEVEL_ERROR="ERROR"
readonly TIP_LEVEL_CRITICAL="CRITICAL"

# 提示存储数组
declare -a SMART_TIPS_LIST=()

# =============================================================================
# 提示收集函数
# =============================================================================

# 添加提示
add_tip() {
    local level=$1
    local category=$2
    local message=$3
    local action=${4:-""}

    SMART_TIPS_LIST+=("$level|$category|$message|$action")
}

# 清空提示列表
clear_tips() {
    SMART_TIPS_LIST=()
}

# 获取提示数量
get_tips_count() {
    echo "${#SMART_TIPS_LIST[@]}"
}

# 获取指定级别的提示数量
get_tips_count_by_level() {
    local level=$1
    local count=0

    for tip in "${SMART_TIPS_LIST[@]}"; do
        local tip_level=$(echo "$tip" | cut -d'|' -f1)
        if [[ "$tip_level" == "$level" ]]; then
            ((count++))
        fi
    done

    echo "$count"
}

# =============================================================================
# 系统健康检查
# =============================================================================

# 检查sing-box服务状态
check_service_health() {
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        add_tip "$TIP_LEVEL_ERROR" "服务" "sing-box 服务未运行" "使用 '服务控制 > 启动服务' 启动服务"
        return 1
    fi

    # 检查服务是否失败
    if systemctl is-failed --quiet sing-box 2>/dev/null; then
        add_tip "$TIP_LEVEL_CRITICAL" "服务" "sing-box 服务处于失败状态" "使用 '查看日志' 检查错误信息"
        return 1
    fi

    return 0
}

# 检查sing-box二进制文件
check_binary() {
    if [[ ! -f "$SINGBOX_BINARY" ]]; then
        add_tip "$TIP_LEVEL_CRITICAL" "安装" "sing-box 程序未安装" "请先安装 sing-box"
        return 1
    fi

    if [[ ! -x "$SINGBOX_BINARY" ]]; then
        add_tip "$TIP_LEVEL_ERROR" "权限" "sing-box 程序无执行权限" "运行: chmod +x $SINGBOX_BINARY"
        return 1
    fi

    return 0
}

# 检查配置文件
check_config_file() {
    if [[ ! -f "$SINGBOX_CONFIG_FILE" ]]; then
        add_tip "$TIP_LEVEL_WARNING" "配置" "配置文件不存在" "使用 '配置管理 > 生成配置' 创建配置"
        return 1
    fi

    # 验证JSON格式
    if ! jq empty "$SINGBOX_CONFIG_FILE" 2>/dev/null; then
        add_tip "$TIP_LEVEL_ERROR" "配置" "配置文件JSON格式无效" "使用 '配置管理 > 验证配置' 检查错误"
        return 1
    fi

    # 检查配置文件是否为空
    local config_size=$(stat -c%s "$SINGBOX_CONFIG_FILE" 2>/dev/null || echo "0")
    if [[ $config_size -lt 100 ]]; then
        add_tip "$TIP_LEVEL_WARNING" "配置" "配置文件内容可能不完整" "重新生成配置文件"
        return 1
    fi

    return 0
}

# 检查数据完整性
check_data_integrity() {
    local has_issue=false

    # 检查节点数据
    local nodes_file="${DATA_DIR}/nodes.json"
    if [[ ! -f "$nodes_file" ]]; then
        add_tip "$TIP_LEVEL_WARNING" "数据" "节点数据文件不存在" "添加至少一个节点"
        has_issue=true
    else
        local nodes_count=$(jq '.nodes | length' "$nodes_file" 2>/dev/null || echo "0")
        if [[ $nodes_count -eq 0 ]]; then
            add_tip "$TIP_LEVEL_INFO" "数据" "尚未配置任何节点" "使用 '节点管理' 添加节点"
            has_issue=true
        fi
    fi

    # 检查用户数据
    local users_file="${DATA_DIR}/users.json"
    if [[ ! -f "$users_file" ]]; then
        add_tip "$TIP_LEVEL_WARNING" "数据" "用户数据文件不存在" "添加至少一个用户"
        has_issue=true
    else
        local users_count=$(jq '.users | length' "$users_file" 2>/dev/null || echo "0")
        if [[ $users_count -eq 0 ]]; then
            add_tip "$TIP_LEVEL_INFO" "数据" "尚未配置任何用户" "使用 '用户管理' 添加用户"
            has_issue=true
        fi

        # 检查是否有启用的用户
        local enabled_count=$(jq '[.users[] | select(.enabled == true)] | length' "$users_file" 2>/dev/null || echo "0")
        if [[ $enabled_count -eq 0 ]] && [[ $users_count -gt 0 ]]; then
            add_tip "$TIP_LEVEL_WARNING" "数据" "所有用户都已禁用" "启用至少一个用户"
            has_issue=true
        fi
    fi

    # 检查绑定关系
    local bindings_file="${DATA_DIR}/node_users.json"
    if [[ ! -f "$bindings_file" ]]; then
        add_tip "$TIP_LEVEL_WARNING" "数据" "绑定数据文件不存在" "绑定用户到节点"
        has_issue=true
    else
        local bindings_count=$(jq '.bindings | length' "$bindings_file" 2>/dev/null || echo "0")
        if [[ $bindings_count -eq 0 ]]; then
            add_tip "$TIP_LEVEL_INFO" "数据" "尚未配置任何绑定关系" "使用 '绑定管理' 绑定用户到节点"
            has_issue=true
        fi
    fi

    if [[ "$has_issue" == "true" ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# 证书检查
# =============================================================================

# 检查证书文件
check_certificates() {
    local cert_dir="${SINGBOX_CONFIG_DIR}/certs"

    if [[ ! -d "$cert_dir" ]]; then
        add_tip "$TIP_LEVEL_INFO" "证书" "证书目录不存在" "使用 '证书管理' 配置TLS证书（推荐）"
        return 0
    fi

    # 查找证书文件
    local cert_files=$(find "$cert_dir" -name "*.crt" -o -name "*.pem" 2>/dev/null)

    if [[ -z "$cert_files" ]]; then
        add_tip "$TIP_LEVEL_INFO" "证书" "未找到证书文件" "配置TLS证书提高安全性"
        return 0
    fi

    # 检查证书过期时间
    while IFS= read -r cert_file; do
        if command -v openssl &>/dev/null; then
            local expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)

            if [[ -n "$expiry_date" ]]; then
                local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
                local current_epoch=$(date +%s)
                local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

                if [[ $days_left -lt 0 ]]; then
                    add_tip "$TIP_LEVEL_CRITICAL" "证书" "证书 $(basename "$cert_file") 已过期" "立即更新证书"
                elif [[ $days_left -lt 7 ]]; then
                    add_tip "$TIP_LEVEL_ERROR" "证书" "证书 $(basename "$cert_file") 将在 $days_left 天后过期" "尽快更新证书"
                elif [[ $days_left -lt 30 ]]; then
                    add_tip "$TIP_LEVEL_WARNING" "证书" "证书 $(basename "$cert_file") 将在 $days_left 天后过期" "准备更新证书"
                fi
            fi
        fi
    done <<< "$cert_files"

    return 0
}

# =============================================================================
# 性能检查
# =============================================================================

# 检查系统资源
check_system_resources() {
    # 检查内存使用
    if command -v free &>/dev/null; then
        local mem_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')

        if [[ $mem_usage -gt 90 ]]; then
            add_tip "$TIP_LEVEL_CRITICAL" "性能" "内存使用率过高 (${mem_usage}%)" "检查是否有内存泄漏"
        elif [[ $mem_usage -gt 80 ]]; then
            add_tip "$TIP_LEVEL_WARNING" "性能" "内存使用率较高 (${mem_usage}%)" "关注内存使用情况"
        fi
    fi

    # 检查磁盘空间
    if command -v df &>/dev/null; then
        local disk_usage=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')

        if [[ $disk_usage -gt 90 ]]; then
            add_tip "$TIP_LEVEL_CRITICAL" "性能" "磁盘空间不足 (已用${disk_usage}%)" "清理磁盘空间"
        elif [[ $disk_usage -gt 80 ]]; then
            add_tip "$TIP_LEVEL_WARNING" "性能" "磁盘空间较少 (已用${disk_usage}%)" "注意磁盘空间"
        fi
    fi

    # 检查系统负载
    if [[ -f /proc/loadavg ]]; then
        local load=$(cut -d' ' -f1 /proc/loadavg)
        local cpu_count=$(nproc 2>/dev/null || echo "1")
        local load_percent=$(awk "BEGIN {printf \"%.0f\", $load / $cpu_count * 100}")

        if [[ $load_percent -gt 200 ]]; then
            add_tip "$TIP_LEVEL_WARNING" "性能" "系统负载过高 (${load})" "检查CPU密集型进程"
        fi
    fi

    return 0
}

# 检查日志大小
check_log_size() {
    local log_file="/var/log/singbox/manager.log"

    if [[ -f "$log_file" ]]; then
        local log_size=$(stat -c%s "$log_file" 2>/dev/null || echo "0")
        local log_size_mb=$((log_size / 1024 / 1024))

        if [[ $log_size_mb -gt 100 ]]; then
            add_tip "$TIP_LEVEL_WARNING" "日志" "日志文件过大 (${log_size_mb}MB)" "清理或归档旧日志"
        fi
    fi

    return 0
}

# =============================================================================
# 端口检查
# =============================================================================

# 检查端口占用
check_port_conflicts() {
    local nodes_file="${DATA_DIR}/nodes.json"

    if [[ ! -f "$nodes_file" ]]; then
        return 0
    fi

    # 获取所有配置的端口
    local ports=$(jq -r '.nodes[].port' "$nodes_file" 2>/dev/null)

    if command -v ss &>/dev/null || command -v netstat &>/dev/null; then
        while read -r port; do
            if [[ -z "$port" ]]; then
                continue
            fi

            # 检查端口是否被其他进程占用
            if command -v ss &>/dev/null; then
                local process=$(ss -tunlp | grep ":$port " | grep -v "sing-box")
            else
                local process=$(netstat -tunlp 2>/dev/null | grep ":$port " | grep -v "sing-box")
            fi

            if [[ -n "$process" ]]; then
                add_tip "$TIP_LEVEL_ERROR" "端口" "端口 $port 已被其他进程占用" "释放端口或更改节点配置"
            fi
        done <<< "$ports"
    fi

    return 0
}

# 检查防火墙规则
check_firewall() {
    # 检查firewalld
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        local nodes_file="${DATA_DIR}/nodes.json"

        if [[ -f "$nodes_file" ]]; then
            local ports=$(jq -r '.nodes[].port' "$nodes_file" 2>/dev/null)

            while read -r port; do
                if [[ -z "$port" ]]; then
                    continue
                fi

                if ! firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp"; then
                    add_tip "$TIP_LEVEL_WARNING" "防火墙" "端口 $port 未在防火墙中开放" "使用 '防火墙管理' 开放端口"
                fi
            done <<< "$ports"
        fi
    fi

    return 0
}

# =============================================================================
# 安全检查
# =============================================================================

# 检查默认密码
check_default_passwords() {
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 0
    fi

    # 检查是否有默认admin用户
    local admin_exists=$(jq -r '.users[] | select(.username == "admin") | .username' "$users_file" 2>/dev/null)

    if [[ -n "$admin_exists" ]]; then
        add_tip "$TIP_LEVEL_WARNING" "安全" "存在默认admin用户" "建议修改默认用户名和密码"
    fi

    return 0
}

# 检查TLS配置
check_tls_config() {
    if [[ ! -f "$SINGBOX_CONFIG_FILE" ]]; then
        return 0
    fi

    # 检查是否配置了TLS
    local has_tls=$(jq -r '.inbounds[]?.tls.enabled' "$SINGBOX_CONFIG_FILE" 2>/dev/null | grep -c "true")

    if [[ $has_tls -eq 0 ]]; then
        add_tip "$TIP_LEVEL_INFO" "安全" "未启用TLS加密" "配置TLS证书提高连接安全性"
    fi

    return 0
}

# =============================================================================
# 配置优化建议
# =============================================================================

# 检查配置优化机会
check_config_optimization() {
    local nodes_file="${DATA_DIR}/nodes.json"
    local users_file="${DATA_DIR}/users.json"

    # 检查节点数量
    if [[ -f "$nodes_file" ]]; then
        local nodes_count=$(jq '.nodes | length' "$nodes_file" 2>/dev/null || echo "0")

        if [[ $nodes_count -eq 1 ]]; then
            add_tip "$TIP_LEVEL_INFO" "优化" "仅配置了1个节点" "添加多个节点实现负载均衡"
        fi
    fi

    # 检查用户数量
    if [[ -f "$users_file" ]]; then
        local users_count=$(jq '.users | length' "$users_file" 2>/dev/null || echo "0")

        if [[ $users_count -gt 50 ]]; then
            add_tip "$TIP_LEVEL_INFO" "优化" "用户数量较多 ($users_count)" "考虑使用订阅功能管理用户"
        fi
    fi

    return 0
}

# =============================================================================
# 执行所有检查
# =============================================================================

# 运行全部检查
run_all_checks() {
    clear_tips

    log_debug "开始智能提示系统检查..."

    # 系统健康
    check_binary
    check_service_health
    check_config_file
    check_data_integrity

    # 证书
    check_certificates

    # 性能
    check_system_resources
    check_log_size

    # 网络
    check_port_conflicts
    check_firewall

    # 安全
    check_default_passwords
    check_tls_config

    # 优化
    check_config_optimization

    log_debug "智能提示系统检查完成"
}

# =============================================================================
# 提示显示
# =============================================================================

# 显示提示摘要
show_tips_summary() {
    local total=$(get_tips_count)

    if [[ $total -eq 0 ]]; then
        return 0
    fi

    local critical=$(get_tips_count_by_level "$TIP_LEVEL_CRITICAL")
    local error=$(get_tips_count_by_level "$TIP_LEVEL_ERROR")
    local warning=$(get_tips_count_by_level "$TIP_LEVEL_WARNING")
    local info=$(get_tips_count_by_level "$TIP_LEVEL_INFO")

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}智能提示 ($total 条)${NC}"

    if [[ $critical -gt 0 ]]; then
        echo -e "  ${RED}●${NC} 严重: $critical 条"
    fi
    if [[ $error -gt 0 ]]; then
        echo -e "  ${RED}●${NC} 错误: $error 条"
    fi
    if [[ $warning -gt 0 ]]; then
        echo -e "  ${YELLOW}●${NC} 警告: $warning 条"
    fi
    if [[ $info -gt 0 ]]; then
        echo -e "  ${BLUE}●${NC} 提示: $info 条"
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 显示详细提示
show_tips_detail() {
    if [[ ${#SMART_TIPS_LIST[@]} -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}✔ 系统运行正常，没有发现问题${NC}"
        echo ""
        return 0
    fi

    # 按级别分组显示
    show_tips_by_level "$TIP_LEVEL_CRITICAL" "严重问题" "$RED"
    show_tips_by_level "$TIP_LEVEL_ERROR" "错误" "$RED"
    show_tips_by_level "$TIP_LEVEL_WARNING" "警告" "$YELLOW"
    show_tips_by_level "$TIP_LEVEL_INFO" "提示" "$BLUE"
}

# 按级别显示提示
show_tips_by_level() {
    local level=$1
    local title=$2
    local color=$3

    local found=false

    for tip in "${SMART_TIPS_LIST[@]}"; do
        IFS='|' read -r tip_level category message action <<< "$tip"

        if [[ "$tip_level" == "$level" ]]; then
            if [[ "$found" == "false" ]]; then
                echo ""
                echo -e "${color}━━ $title ━━${NC}"
                echo ""
                found=true
            fi

            echo -e "  ${color}●${NC} ${BOLD}[$category]${NC} $message"
            if [[ -n "$action" ]]; then
                echo -e "    ${GRAY}→ $action${NC}"
            fi
            echo ""
        fi
    done
}

# 显示简化提示（用于主菜单）
show_quick_tips_panel() {
    run_all_checks

    local total=$(get_tips_count)

    if [[ $total -eq 0 ]]; then
        echo -e "${CYAN}┌─ 快捷提示 ─────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${NC} ${GREEN}✔${NC} 系统运行正常，没有发现问题                                ${CYAN}│${NC}"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
        return 0
    fi

    local critical=$(get_tips_count_by_level "$TIP_LEVEL_CRITICAL")
    local error=$(get_tips_count_by_level "$TIP_LEVEL_ERROR")
    local warning=$(get_tips_count_by_level "$TIP_LEVEL_WARNING")

    echo -e "${CYAN}┌─ 快捷提示 ─────────────────────────────────────────────────────┐${NC}"

    if [[ $critical -gt 0 ]]; then
        echo -e "${CYAN}│${NC} ${RED}●${NC} 发现 ${RED}$critical${NC} 个严重问题，请立即处理                        ${CYAN}│${NC}"
    elif [[ $error -gt 0 ]]; then
        echo -e "${CYAN}│${NC} ${RED}●${NC} 发现 ${RED}$error${NC} 个错误，建议尽快处理                            ${CYAN}│${NC}"
    elif [[ $warning -gt 0 ]]; then
        echo -e "${CYAN}│${NC} ${YELLOW}●${NC} 发现 ${YELLOW}$warning${NC} 个警告，建议关注                                ${CYAN}│${NC}"
    else
        # 只显示第一条INFO提示
        for tip in "${SMART_TIPS_LIST[@]}"; do
            IFS='|' read -r tip_level category message action <<< "$tip"
            if [[ "$tip_level" == "$TIP_LEVEL_INFO" ]]; then
                # 截断过长的消息
                if [[ ${#message} -gt 50 ]]; then
                    message="${message:0:47}..."
                fi
                printf "${CYAN}│${NC} ${BLUE}●${NC} %-58s ${CYAN}│${NC}\n" "$message"
                break
            fi
        done
    fi

    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
}

# =============================================================================
# 交互式提示查看
# =============================================================================

# 智能提示菜单
smart_tips_menu() {
    clear

    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "智能提示系统" 68
    else
        print_header "智能提示系统"
    fi

    echo ""
    echo -e "${CYAN}正在检查系统...${NC}"

    run_all_checks

    clear

    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "智能提示系统" 68
    else
        print_header "智能提示系统"
    fi

    show_tips_summary
    show_tips_detail

    if declare -f wait_for_key &>/dev/null; then
        wait_for_key "按回车键返回"
    else
        read -p "按回车键返回..."
    fi
}

# =============================================================================
# 模块初始化
# =============================================================================

log_debug "smart_tips.sh 模块已加载"
