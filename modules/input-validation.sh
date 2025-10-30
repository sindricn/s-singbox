#!/bin/bash

# =============================================================================
# input-validation.sh - 输入验证模块
# 提供各种输入验证功能
# =============================================================================

# 依赖检查
if [[ -z "${SCRIPT_DIR}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if ! declare -f print_error &>/dev/null; then
    source "${SCRIPT_DIR}/modules/common.sh"
fi

# =============================================================================
# 端口验证
# =============================================================================

validate_port() {
    local port=$1

    # 检查是否为数字
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # 检查范围
    if [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        return 1
    fi

    return 0
}

validate_port_with_message() {
    local port=$1

    if ! validate_port "$port"; then
        print_error "无效的端口号: $port (范围: 1-65535)"
        return 1
    fi

    return 0
}

# =============================================================================
# IP 地址验证
# =============================================================================

validate_ipv4() {
    local ip=$1

    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)

        for octet in "${octets[@]}"; do
            if [[ $octet -gt 255 ]]; then
                return 1
            fi
        done

        return 0
    fi

    return 1
}

validate_ipv6() {
    local ip=$1

    # 简化的 IPv6 验证
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    fi

    return 1
}

validate_ip() {
    local ip=$1

    if validate_ipv4 "$ip" || validate_ipv6 "$ip"; then
        return 0
    fi

    return 1
}

validate_ip_with_message() {
    local ip=$1

    if ! validate_ip "$ip"; then
        print_error "无效的 IP 地址: $ip"
        return 1
    fi

    return 0
}

# =============================================================================
# CIDR 验证
# =============================================================================

validate_cidr() {
    local cidr=$1

    if [[ $cidr =~ ^(.+)/([0-9]+)$ ]]; then
        local ip="${BASH_REMATCH[1]}"
        local prefix="${BASH_REMATCH[2]}"

        # 验证 IP
        if ! validate_ip "$ip"; then
            return 1
        fi

        # 验证前缀长度
        if validate_ipv4 "$ip"; then
            # IPv4: 0-32
            if [[ $prefix -lt 0 ]] || [[ $prefix -gt 32 ]]; then
                return 1
            fi
        else
            # IPv6: 0-128
            if [[ $prefix -lt 0 ]] || [[ $prefix -gt 128 ]]; then
                return 1
            fi
        fi

        return 0
    fi

    return 1
}

# =============================================================================
# 域名验证
# =============================================================================

validate_domain() {
    local domain=$1

    # 域名正则表达式
    if [[ $domain =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi

    return 1
}

validate_domain_with_message() {
    local domain=$1

    if ! validate_domain "$domain"; then
        print_error "无效的域名: $domain"
        return 1
    fi

    return 0
}

# =============================================================================
# UUID 验证
# =============================================================================

validate_uuid() {
    local uuid=$1

    if [[ $uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        return 0
    fi

    return 1
}

validate_uuid_with_message() {
    local uuid=$1

    if ! validate_uuid "$uuid"; then
        print_error "无效的 UUID: $uuid"
        return 1
    fi

    return 0
}

# =============================================================================
# 邮箱验证
# =============================================================================

validate_email() {
    local email=$1

    if [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi

    return 1
}

validate_email_with_message() {
    local email=$1

    if ! validate_email "$email"; then
        print_error "无效的邮箱地址: $email"
        return 1
    fi

    return 0
}

# =============================================================================
# 密码强度验证
# =============================================================================

validate_password_strength() {
    local password=$1
    local min_length=${2:-8}

    # 检查长度
    if [[ ${#password} -lt $min_length ]]; then
        return 1
    fi

    # 检查是否包含数字和字母
    if ! [[ $password =~ [0-9] ]] || ! [[ $password =~ [a-zA-Z] ]]; then
        return 1
    fi

    return 0
}

validate_password_with_message() {
    local password=$1
    local min_length=${2:-8}

    if [[ ${#password} -lt $min_length ]]; then
        print_error "密码长度不足 $min_length 位"
        return 1
    fi

    if ! [[ $password =~ [0-9] ]]; then
        print_error "密码必须包含数字"
        return 1
    fi

    if ! [[ $password =~ [a-zA-Z] ]]; then
        print_error "密码必须包含字母"
        return 1
    fi

    return 0
}

# =============================================================================
# 用户名验证
# =============================================================================

validate_username() {
    local username=$1

    # 只允许字母、数字、下划线、连字符
    if [[ $username =~ ^[a-zA-Z0-9_-]+$ ]]; then
        # 检查长度
        if [[ ${#username} -ge 3 ]] && [[ ${#username} -le 32 ]]; then
            return 0
        fi
    fi

    return 1
}

validate_username_with_message() {
    local username=$1

    if ! [[ $username =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_error "用户名只能包含字母、数字、下划线、连字符"
        return 1
    fi

    if [[ ${#username} -lt 3 ]]; then
        print_error "用户名长度不能少于 3 位"
        return 1
    fi

    if [[ ${#username} -gt 32 ]]; then
        print_error "用户名长度不能超过 32 位"
        return 1
    fi

    return 0
}

# =============================================================================
# 路径验证
# =============================================================================

validate_path() {
    local path=$1

    # 检查路径是否为绝对路径
    if [[ "$path" == /* ]]; then
        return 0
    fi

    return 1
}

validate_file_exists() {
    local file=$1

    if [[ -f "$file" ]]; then
        return 0
    fi

    return 1
}

validate_directory_exists() {
    local dir=$1

    if [[ -d "$dir" ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# 数字范围验证
# =============================================================================

validate_number_range() {
    local number=$1
    local min=$2
    local max=$3

    if ! [[ "$number" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ $number -lt $min ]] || [[ $number -gt $max ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# 协议类型验证
# =============================================================================

validate_protocol() {
    local protocol=$1

    local valid_protocols=(
        "shadowsocks"
        "trojan"
        "hysteria2"
        "tuic"
        "naive"
        "vmess"
        "vless"
        "shadowtls"
    )

    for valid in "${valid_protocols[@]}"; do
        if [[ "$protocol" == "$valid" ]]; then
            return 0
        fi
    done

    return 1
}

validate_protocol_with_message() {
    local protocol=$1

    if ! validate_protocol "$protocol"; then
        print_error "不支持的协议: $protocol"
        print_info "支持的协议: shadowsocks, trojan, hysteria2, tuic, naive, vmess, vless, shadowtls"
        return 1
    fi

    return 0
}

# =============================================================================
# 传输类型验证
# =============================================================================

validate_transport() {
    local transport=$1

    local valid_transports=(
        "tcp"
        "udp"
        "ws"
        "grpc"
        "http"
    )

    for valid in "${valid_transports[@]}"; do
        if [[ "$transport" == "$valid" ]]; then
            return 0
        fi
    done

    return 1
}

# =============================================================================
# 加密方式验证
# =============================================================================

validate_shadowsocks_method() {
    local method=$1

    local valid_methods=(
        "aes-128-gcm"
        "aes-256-gcm"
        "chacha20-ietf-poly1305"
        "2022-blake3-aes-128-gcm"
        "2022-blake3-aes-256-gcm"
        "2022-blake3-chacha20-poly1305"
    )

    for valid in "${valid_methods[@]}"; do
        if [[ "$method" == "$valid" ]]; then
            return 0
        fi
    done

    return 1
}

# =============================================================================
# URL 验证
# =============================================================================

validate_url() {
    local url=$1

    if [[ $url =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# 交互式验证输入
# =============================================================================

read_and_validate_port() {
    local prompt=$1
    local default=$2

    while true; do
        local port=$(read_input "$prompt" "$default")

        if validate_port_with_message "$port"; then
            echo "$port"
            return 0
        fi
    done
}

read_and_validate_domain() {
    local prompt=$1

    while true; do
        local domain=$(read_input "$prompt")

        if validate_domain_with_message "$domain"; then
            echo "$domain"
            return 0
        fi
    done
}

read_and_validate_email() {
    local prompt=$1

    while true; do
        local email=$(read_input "$prompt")

        if validate_email_with_message "$email"; then
            echo "$email"
            return 0
        fi
    done
}

# =============================================================================
# 模块初始化
# =============================================================================

log_debug "input-validation.sh 模块已加载"
