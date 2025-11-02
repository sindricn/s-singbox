#!/bin/bash

#================================================================
# 输入验证模块 - Input Validation
# 功能：增强的输入验证、安全检查、用户输入处理
# 参考：s-hy2 最佳实践
#================================================================

#================================================================
# 基础验证函数（增强版）
#================================================================

# 端口验证（增强）
validate_port_enhanced() {
    local port=$1
    local check_in_use=${2:-false}

    # 基础格式验证
    if ! validate_port "$port"; then
        log_error "端口格式不正确: $port (必须是 1-65535 之间的数字)"
        return 1
    fi

    # 检查是否为特权端口
    if [[ $port -lt 1024 ]]; then
        log_warn "端口 $port 是特权端口，需要 root 权限"
    fi

    # 检查是否被占用
    if [[ "$check_in_use" == "true" ]]; then
        if check_port_in_use "$port"; then
            log_error "端口 $port 已被占用"
            return 1
        fi
    fi

    return 0
}

# 域名验证（增强）
validate_domain_enhanced() {
    local domain=$1
    local check_dns=${2:-false}

    # 基础格式验证
    if ! validate_domain "$domain"; then
        log_error "域名格式不正确: $domain"
        return 1
    fi

    # DNS 解析验证
    if [[ "$check_dns" == "true" ]]; then
        if ! host "$domain" &>/dev/null; then
            log_error "域名 DNS 解析失败: $domain"
            return 1
        fi
    fi

    return 0
}

# UUID 验证（增强）
validate_uuid_enhanced() {
    local uuid=$1

    # 基础格式验证
    if ! validate_uuid "$uuid"; then
        log_error "UUID 格式不正确: $uuid"
        log_info "正确格式示例: 12345678-1234-1234-1234-123456789abc"
        return 1
    fi

    return 0
}

#================================================================
# 协议相关验证
#================================================================

# VLESS 配置验证
validate_vless_config() {
    local uuid=$1
    local port=$2

    validate_uuid_enhanced "$uuid" || return 1
    validate_port_enhanced "$port" true || return 1

    return 0
}

# VMess 配置验证
validate_vmess_config() {
    local uuid=$1
    local port=$2
    local alter_id=${3:-0}

    validate_uuid_enhanced "$uuid" || return 1
    validate_port_enhanced "$port" true || return 1

    # alterID 验证
    if [[ ! $alter_id =~ ^[0-9]+$ ]] || [[ $alter_id -lt 0 ]] || [[ $alter_id -gt 65535 ]]; then
        log_error "alterID 必须是 0-65535 之间的数字"
        return 1
    fi

    return 0
}

# Trojan 配置验证
validate_trojan_config() {
    local password=$1
    local port=$2

    # 密码强度检查
    if [[ ${#password} -lt 8 ]]; then
        log_error "Trojan 密码长度至少 8 位"
        return 1
    fi

    validate_port_enhanced "$port" true || return 1

    return 0
}

# Shadowsocks 配置验证
validate_shadowsocks_config() {
    local password=$1
    local port=$2
    local method=$3

    # 密码强度检查
    if [[ ${#password} -lt 8 ]]; then
        log_error "Shadowsocks 密码长度至少 8 位"
        return 1
    fi

    validate_port_enhanced "$port" true || return 1

    # 加密方法验证
    local valid_methods=(
        "aes-128-gcm"
        "aes-256-gcm"
        "chacha20-poly1305"
        "chacha20-ietf-poly1305"
        "2022-blake3-aes-128-gcm"
        "2022-blake3-aes-256-gcm"
        "2022-blake3-chacha20-poly1305"
    )

    local method_valid=false
    for valid_method in "${valid_methods[@]}"; do
        if [[ "$method" == "$valid_method" ]]; then
            method_valid=true
            break
        fi
    done

    if [[ "$method_valid" == "false" ]]; then
        log_error "不支持的加密方法: $method"
        log_info "支持的方法: ${valid_methods[*]}"
        return 1
    fi

    return 0
}

#================================================================
# Reality 相关验证
#================================================================

# Reality 密钥验证
validate_reality_key() {
    local key=$1

    # Reality 密钥应该是 base64 编码的 x25519 密钥
    if [[ ! $key =~ ^[A-Za-z0-9+/=_-]{43,44}$ ]]; then
        log_error "Reality 密钥格式不正确"
        return 1
    fi

    return 0
}

# Reality ShortId 验证
validate_reality_shortid() {
    local short_id=$1

    # ShortId 应该是 16 个十六进制字符
    if [[ ! $short_id =~ ^[0-9a-f]{16}$ ]]; then
        log_error "Reality ShortId 格式不正确（应为 16 个十六进制字符）"
        return 1
    fi

    return 0
}

# Reality 配置完整性验证
validate_reality_config() {
    local public_key=$1
    local private_key=$2
    local short_id=$3
    local dest_server=$4

    validate_reality_key "$public_key" || return 1
    validate_reality_key "$private_key" || return 1
    validate_reality_shortid "$short_id" || return 1
    validate_domain_enhanced "$dest_server" false || return 1

    return 0
}

#================================================================
# 传输协议验证
#================================================================

# 传输协议验证
validate_transport() {
    local transport=$1

    local valid_transports=("tcp" "ws" "grpc" "http" "quic")

    for valid_transport in "${valid_transports[@]}"; do
        if [[ "$transport" == "$valid_transport" ]]; then
            return 0
        fi
    done

    log_error "不支持的传输协议: $transport"
    log_info "支持的协议: ${valid_transports[*]}"
    return 1
}

# WebSocket 路径验证
validate_ws_path() {
    local path=$1

    # 必须以 / 开头
    if [[ ! $path =~ ^/ ]]; then
        log_error "WebSocket 路径必须以 / 开头"
        return 1
    fi

    # 路径安全检查
    if [[ $path =~ \.\. ]]; then
        log_error "WebSocket 路径不能包含 .."
        return 1
    fi

    return 0
}

# gRPC ServiceName 验证
validate_grpc_servicename() {
    local service_name=$1

    # ServiceName 应该是合法的标识符
    if [[ ! $service_name =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
        log_error "gRPC ServiceName 格式不正确"
        return 1
    fi

    return 0
}

#================================================================
# TLS 相关验证
#================================================================

# 证书文件验证
validate_cert_file() {
    local cert_file=$1

    if [[ ! -f "$cert_file" ]]; then
        log_error "证书文件不存在: $cert_file"
        return 1
    fi

    # 检查证书格式
    if ! openssl x509 -in "$cert_file" -noout 2>/dev/null; then
        log_error "证书文件格式不正确: $cert_file"
        return 1
    fi

    # 检查证书有效期
    local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
    local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
    local current_epoch=$(date +%s)

    if [[ $expiry_epoch -gt 0 ]] && [[ $expiry_epoch -lt $current_epoch ]]; then
        log_error "证书已过期: $cert_file"
        return 1
    fi

    return 0
}

# 密钥文件验证
validate_key_file() {
    local key_file=$1

    if [[ ! -f "$key_file" ]]; then
        log_error "密钥文件不存在: $key_file"
        return 1
    fi

    # 检查密钥格式
    if ! openssl rsa -in "$key_file" -check -noout 2>/dev/null && \
       ! openssl ec -in "$key_file" -check -noout 2>/dev/null; then
        log_error "密钥文件格式不正确: $key_file"
        return 1
    fi

    # 检查文件权限（应该是 600）
    local perm=$(stat -c %a "$key_file" 2>/dev/null || stat -f %A "$key_file" 2>/dev/null)
    if [[ "$perm" != "600" ]]; then
        log_warn "密钥文件权限不安全: $key_file (当前: $perm, 推荐: 600)"
    fi

    return 0
}

# TLS 配置验证
validate_tls_config() {
    local cert_file=$1
    local key_file=$2

    validate_cert_file "$cert_file" || return 1
    validate_key_file "$key_file" || return 1

    return 0
}

#================================================================
# 用户输入处理
#================================================================

# 读取并验证端口输入
read_port() {
    local prompt="${1:-请输入端口}"
    local default="${2:-}"
    local check_in_use="${3:-true}"

    while true; do
        local input_prompt="$prompt"
        [[ -n "$default" ]] && input_prompt="$input_prompt [默认: $default]"
        input_prompt="$input_prompt: "

        read -p "$input_prompt" port
        port=${port:-$default}

        if [[ -z "$port" ]]; then
            log_error "端口不能为空"
            continue
        fi

        if validate_port_enhanced "$port" "$check_in_use"; then
            echo "$port"
            return 0
        fi

        log_warn "请重新输入"
    done
}

# 读取并验证 UUID 输入
read_uuid() {
    local prompt="${1:-请输入 UUID}"
    local allow_generate="${2:-true}"

    while true; do
        local input_prompt="$prompt"
        if [[ "$allow_generate" == "true" ]]; then
            input_prompt="$input_prompt [留空自动生成]"
        fi
        input_prompt="$input_prompt: "

        read -p "$input_prompt" uuid

        if [[ -z "$uuid" ]] && [[ "$allow_generate" == "true" ]]; then
            uuid=$(generate_uuid)
            log_info "已生成 UUID: $uuid"
            echo "$uuid"
            return 0
        fi

        if [[ -z "$uuid" ]]; then
            log_error "UUID 不能为空"
            continue
        fi

        if validate_uuid_enhanced "$uuid"; then
            echo "$uuid"
            return 0
        fi

        log_warn "请重新输入"
    done
}

# 读取并验证域名输入
read_domain() {
    local prompt="${1:-请输入域名}"
    local default="${2:-}"
    local check_dns="${3:-false}"

    while true; do
        local input_prompt="$prompt"
        [[ -n "$default" ]] && input_prompt="$input_prompt [默认: $default]"
        input_prompt="$input_prompt: "

        read -p "$input_prompt" domain
        domain=${domain:-$default}

        if [[ -z "$domain" ]]; then
            log_error "域名不能为空"
            continue
        fi

        if validate_domain_enhanced "$domain" "$check_dns"; then
            echo "$domain"
            return 0
        fi

        log_warn "请重新输入"
    done
}

# 读取并验证密码输入
read_password() {
    local prompt="${1:-请输入密码}"
    local min_length="${2:-8}"
    local allow_generate="${3:-true}"

    while true; do
        local input_prompt="$prompt (最少 $min_length 位)"
        if [[ "$allow_generate" == "true" ]]; then
            input_prompt="$input_prompt [留空自动生成]"
        fi
        input_prompt="$input_prompt: "

        read -s -p "$input_prompt" password
        echo ""

        if [[ -z "$password" ]] && [[ "$allow_generate" == "true" ]]; then
            password=$(generate_secure_password "$min_length")
            log_info "已生成密码: $password"
            echo "$password"
            return 0
        fi

        if [[ ${#password} -lt $min_length ]]; then
            log_error "密码长度不足 $min_length 位"
            continue
        fi

        echo "$password"
        return 0
    done
}

# 读取选择（单选）
read_choice() {
    local prompt="$1"
    shift
    local options=("$@")

    while true; do
        echo "$prompt"
        for i in "${!options[@]}"; do
            echo "$((i+1)). ${options[$i]}"
        done

        read -p "请选择 [1-${#options[@]}]: " choice

        if [[ ! $choice =~ ^[0-9]+$ ]]; then
            log_error "请输入数字"
            continue
        fi

        if [[ $choice -lt 1 || $choice -gt ${#options[@]} ]]; then
            log_error "选择超出范围"
            continue
        fi

        echo "$((choice-1))"
        return 0
    done
}

# 读取是否确认（带默认值）
read_confirm() {
    local prompt="${1:-确认操作}"
    local default="${2:-n}"

    confirm "$prompt" "$default"
}

#================================================================
# 配置文件验证
#================================================================

# JSON 格式验证
validate_json_file() {
    local json_file=$1

    if [[ ! -f "$json_file" ]]; then
        log_error "文件不存在: $json_file"
        return 1
    fi

    if ! jq empty "$json_file" 2>/dev/null; then
        log_error "JSON 格式不正确: $json_file"
        return 1
    fi

    return 0
}

# Xray 配置文件验证
validate_xray_config() {
    local config_file=$1

    # JSON 格式验证
    validate_json_file "$config_file" || return 1

    # 使用 Xray 内置验证
    if [[ -f "$XRAY_BIN" ]]; then
        if ! "$XRAY_BIN" test -c "$config_file" &>/dev/null; then
            log_error "Xray 配置文件验证失败: $config_file"
            "$XRAY_BIN" test -c "$config_file"
            return 1
        fi
    else
        log_warn "Xray 未安装，跳过配置验证"
    fi

    return 0
}

#================================================================
# 安全检查
#================================================================

# 检查危险操作
check_dangerous_operation() {
    local operation=$1

    log_warn "警告：即将执行危险操作: $operation"

    if ! confirm "确认继续" "n"; then
        log_info "操作已取消"
        return 1
    fi

    return 0
}

# 检查生产环境
is_production_env() {
    # 检查是否存在生产环境标记
    if [[ -f "/etc/xray/production" ]] || [[ "$ENVIRONMENT" == "production" ]]; then
        return 0
    fi

    return 1
}

# 生产环境保护
protect_production() {
    local operation=$1

    if is_production_env; then
        log_error "生产环境禁止操作: $operation"
        log_error "如需执行，请先切换到非生产环境"
        return 1
    fi

    return 0
}

log_debug "输入验证模块加载完成"
