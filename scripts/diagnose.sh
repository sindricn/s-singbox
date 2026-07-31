#!/bin/bash

# =============================================================================
# diagnose.sh - 系统诊断脚本
# 检查系统环境、依赖、配置完整性、服务状态
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载模块
source "${SCRIPT_DIR}/modules/common.sh"

# 使用官方标准路径
readonly SINGBOX_CONFIG_DIR="/etc/sing-box"
readonly SINGBOX_CONFIG_FILE="/etc/sing-box/config.json"
readonly SINGBOX_DATA_DIR="/var/lib/sing-box"

# =============================================================================
# 诊断报告
# =============================================================================

print_section() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN} $1${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
}

check_item() {
    local item=$1
    local result=$2

    if [[ "$result" == "ok" ]]; then
        echo -e "  ${GREEN}✓${NC} $item"
    elif [[ "$result" == "warn" ]]; then
        echo -e "  ${YELLOW}!${NC} $item"
    else
        echo -e "  ${RED}✗${NC} $item"
    fi
}

# =============================================================================
# 系统环境检查
# =============================================================================

check_system_environment() {
    print_section "系统环境"

    # 操作系统
    local os_info=$(uname -a)
    echo -e "${CYAN}操作系统:${NC} $os_info"

    # 发行版
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo -e "${CYAN}发行版:${NC} $PRETTY_NAME"
    fi

    # 架构
    local arch=$(uname -m)
    echo -e "${CYAN}架构:${NC} $arch"

    # 内核版本
    local kernel=$(uname -r)
    echo -e "${CYAN}内核:${NC} $kernel"

    # 内存
    if command -v free &>/dev/null; then
        local mem_total=$(free -h | awk '/^Mem:/ {print $2}')
        local mem_used=$(free -h | awk '/^Mem:/ {print $3}')
        echo -e "${CYAN}内存:${NC} 使用 $mem_used / 总共 $mem_total"
    fi

    # 磁盘空间
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}')
    echo -e "${CYAN}磁盘使用:${NC} $disk_usage"

    echo ""
    check_item "系统环境" "ok"
}

# =============================================================================
# 依赖检查
# =============================================================================

check_dependencies() {
    print_section "依赖检查"

    local required_commands=(
        "curl:curl"
        "wget:wget"
        "tar:tar"
        "jq:jq"
        "systemctl:systemd"
    )

    local optional_commands=(
        "ufw:ufw"
        "firewall-cmd:firewalld"
        "openssl:openssl"
    )

    echo "必需命令:"
    for item in "${required_commands[@]}"; do
        IFS=: read -r cmd pkg <<< "$item"

        if command -v "$cmd" &>/dev/null; then
            check_item "$cmd" "ok"
        else
            check_item "$cmd (缺失 - 需要安装 $pkg)" "fail"
        fi
    done

    echo ""
    echo "可选命令:"
    for item in "${optional_commands[@]}"; do
        IFS=: read -r cmd pkg <<< "$item"

        if command -v "$cmd" &>/dev/null; then
            check_item "$cmd" "ok"
        else
            check_item "$cmd (可选)" "warn"
        fi
    done
}

# =============================================================================
# sing-box 检查
# =============================================================================

check_singbox() {
    print_section "sing-box 检查"

    # 二进制文件
    if [[ -f /usr/local/bin/sing-box ]]; then
        check_item "二进制文件存在" "ok"

        local version=$(/usr/local/bin/sing-box version 2>/dev/null | grep -oP 'version \K[0-9.]+' | head -1)
        echo -e "  ${CYAN}版本:${NC} $version"
        if /usr/local/bin/sing-box version 2>/dev/null | grep -q 'with_v2ray_api'; then
            check_item "with_v2ray_api 流量统计能力" "ok"
        else
            check_item "普通内核：节点功能正常，用户流量统计不可用" "warn"
        fi
    else
        check_item "二进制文件不存在" "fail"
    fi

    # 配置目录
    if [[ -d ${SINGBOX_CONFIG_DIR} ]]; then
        check_item "配置目录存在" "ok"
    else
        check_item "配置目录不存在" "warn"
    fi

    # 配置文件
    if [[ -f ${SINGBOX_CONFIG_FILE} ]]; then
        check_item "配置文件存在" "ok"

        # 验证配置
        if /usr/local/bin/sing-box check -c ${SINGBOX_CONFIG_FILE} &>/dev/null; then
            check_item "配置文件有效" "ok"
        else
            check_item "配置文件无效" "fail"
        fi
    else
        check_item "配置文件不存在" "warn"
    fi

    # systemd 服务
    if [[ -f /etc/systemd/system/sing-box.service ]]; then
        check_item "systemd 服务已安装" "ok"

        if systemctl is-enabled sing-box &>/dev/null; then
            check_item "开机自启已启用" "ok"
        else
            check_item "开机自启未启用" "warn"
        fi

        if systemctl is-active sing-box &>/dev/null; then
            check_item "服务正在运行" "ok"
            if stats_json=$(/usr/local/bin/sing-box api statsquery --server=127.0.0.1:10085 -pattern 'user>>>' 2>/dev/null) \
                && echo "$stats_json" | jq -e '.stat | type == "array"' >/dev/null 2>&1; then
                check_item "Stats API 可查询" "ok"
            elif /usr/local/bin/sing-box version 2>/dev/null | grep -q 'with_v2ray_api'; then
                check_item "Stats API 无法查询" "fail"
            else
                check_item "普通内核未启用 Stats API（节点功能不受影响）" "warn"
            fi
        else
            check_item "服务未运行" "warn"
        fi
    else
        check_item "systemd 服务未安装" "fail"
    fi
}

check_subscription_service() {
    print_section "订阅服务"
    local port_file="${SINGBOX_DATA_DIR}/subscription_port.txt"
    if [[ ! -f "$port_file" ]]; then
        check_item "未配置订阅服务" "warn"
        return
    fi

    local port
    port=$(cat "$port_file" 2>/dev/null)
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
        check_item "订阅端口记录无效" "fail"
        return
    fi

    if systemctl is-active --quiet sing-box-subscription.service 2>/dev/null; then
        check_item "订阅服务进程运行中" "ok"
    else
        check_item "订阅服务进程未运行" "fail"
    fi

    if curl -fsS --max-time 3 "http://127.0.0.1:${port}/healthz" 2>/dev/null | grep -q '"status":"ok"'; then
        check_item "订阅 HTTP 健康检查" "ok"
    else
        check_item "订阅进程可能假活，HTTP 健康检查失败" "fail"
    fi

    if systemctl is-enabled --quiet sing-box-subscription-health.timer 2>/dev/null; then
        check_item "订阅健康巡检定时器" "ok"
    else
        check_item "订阅健康巡检定时器未启用" "warn"
    fi
}

# =============================================================================
# 项目文件检查
# =============================================================================

check_project_files() {
    print_section "项目文件"

    local required_files=(
        "singbox-manager.sh"
        "modules/common.sh"
        "modules/safe_json.sh"
        "modules/core.sh"
        "modules/node.sh"
        "modules/user.sh"
        "modules/config_generator.sh"
    )

    for file in "${required_files[@]}"; do
        if [[ -f "${SCRIPT_DIR}/${file}" ]]; then
            check_item "$file" "ok"
        else
            check_item "$file (缺失)" "fail"
        fi
    done
}

# =============================================================================
# 数据文件检查
# =============================================================================

check_data_files() {
    print_section "数据文件"

    local data_dir="$SINGBOX_DATA_DIR"

    if [[ ! -d "$data_dir" ]]; then
        check_item "data 目录不存在" "warn"
        return
    fi

    local data_files=(
        "users.json"
        "nodes.json"
        "node_users.json"
    )

    for file in "${data_files[@]}"; do
        local filepath="${data_dir}/${file}"

        if [[ -f "$filepath" ]]; then
            if jq empty "$filepath" 2>/dev/null; then
                check_item "$file (有效)" "ok"
            else
                check_item "$file (JSON 无效)" "fail"
            fi
        else
            check_item "$file (不存在)" "warn"
        fi
    done
}

# =============================================================================
# 网络检查
# =============================================================================

check_network() {
    print_section "网络检查"

    # 公网 IP
    local public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)

    if [[ -n "$public_ip" ]]; then
        echo -e "  ${CYAN}公网 IP:${NC} $public_ip"
        check_item "网络连接正常" "ok"
    else
        check_item "无法获取公网 IP" "warn"
    fi

    # DNS 解析
    if ping -c 1 github.com &>/dev/null; then
        check_item "DNS 解析正常" "ok"
    else
        check_item "DNS 解析失败" "warn"
    fi
}

# =============================================================================
# 防火墙检查
# =============================================================================

check_firewall() {
    print_section "防火墙检查"

    if command -v ufw &>/dev/null; then
        local status=$(ufw status | head -1)
        echo -e "  ${CYAN}UFW:${NC} $status"

        if [[ "$status" == *"inactive"* ]]; then
            check_item "UFW 未启用" "warn"
        else
            check_item "UFW 已启用" "ok"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        if systemctl is-active firewalld &>/dev/null; then
            check_item "firewalld 已启用" "ok"
        else
            check_item "firewalld 未启用" "warn"
        fi
    else
        check_item "未检测到防火墙" "warn"
    fi
}

# =============================================================================
# 端口检查
# =============================================================================

check_ports() {
    print_section "端口检查"

    # 从 nodes.json 读取端口
    local nodes_file="${SINGBOX_DATA_DIR}/nodes.json"

    if [[ ! -f "$nodes_file" ]]; then
        echo "  nodes.json 不存在，跳过端口检查"
        return
    fi

    local ports=$(jq -r '.nodes[].port' "$nodes_file" 2>/dev/null)

    if [[ -z "$ports" ]]; then
        echo "  没有配置的节点"
        return
    fi

    echo "  已配置的端口:"
    for port in $ports; do
        if ss -tuln 2>/dev/null | grep -q ":${port} "; then
            check_item "端口 $port 正在监听" "ok"
        else
            check_item "端口 $port 未监听" "warn"
        fi
    done
}

# =============================================================================
# 日志检查
# =============================================================================

check_logs() {
    print_section "日志检查"

    # sing-box 日志
    if systemctl is-active sing-box &>/dev/null; then
        local log_lines=$(journalctl -u sing-box -n 10 --no-pager 2>/dev/null | wc -l)

        if [[ $log_lines -gt 0 ]]; then
            check_item "服务日志可访问" "ok"
            echo ""
            echo -e "${CYAN}最近的日志:${NC}"
            journalctl -u sing-box -n 5 --no-pager 2>/dev/null | sed 's/^/  /'
        else
            check_item "无法获取服务日志" "warn"
        fi
    else
        check_item "服务未运行，无日志" "warn"
    fi
}

# =============================================================================
# 生成诊断报告
# =============================================================================

generate_report() {
    print_header "s-singbox 系统诊断报告"
    echo -e "${CYAN}生成时间:${NC} $(date)"
    echo -e "${CYAN}脚本目录:${NC} $SCRIPT_DIR"

    check_system_environment
    check_dependencies
    check_singbox
    check_subscription_service
    check_project_files
    check_data_files
    check_network
    check_firewall
    check_ports
    check_logs

    print_section "诊断完成"
    echo "如有问题，请查看上述检查结果"
    echo ""
}

# 主函数
generate_report
