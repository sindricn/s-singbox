#!/bin/bash

# =============================================================================
# sing-box 配置生成核心模块
# 功能：根据 users.json, nodes.json, node_users.json 动态生成 sing-box 配置
# =============================================================================

# 配置文件路径
SINGBOX_CONFIG_DIR="/usr/local/singbox"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config.json"
SINGBOX_CONFIG_BACKUP="${SINGBOX_CONFIG_FILE}.bak"

DATA_DIR="./data"
USERS_FILE="${DATA_DIR}/users.json"
NODES_FILE="${DATA_DIR}/nodes.json"
BINDINGS_FILE="${DATA_DIR}/node_users.json"

TEMPLATES_DIR="./templates"
BASE_TEMPLATE="${TEMPLATES_DIR}/base_config.json"
PROTOCOLS_DIR="${TEMPLATES_DIR}/protocols"

# =============================================================================
# 辅助函数
# =============================================================================

# 加载数据文件
load_data_files() {
    if [[ ! -f "$USERS_FILE" ]]; then
        print_error "用户数据文件不存在: $USERS_FILE"
        return 1
    fi

    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "节点数据文件不存在: $NODES_FILE"
        return 1
    fi

    if [[ ! -f "$BINDINGS_FILE" ]]; then
        print_error "绑定关系文件不存在: $BINDINGS_FILE"
        return 1
    fi

    # 读取数据到变量
    USERS_DATA=$(cat "$USERS_FILE")
    NODES_DATA=$(cat "$NODES_FILE")
    BINDINGS_DATA=$(cat "$BINDINGS_FILE")

    return 0
}

# 获取绑定到指定节点的用户列表
get_bound_users() {
    local port=$1
    local protocol=$2

    # 从 bindings 中查找匹配的用户ID列表
    local user_ids=$(echo "$BINDINGS_DATA" | jq -r \
        --arg port "$port" \
        --arg protocol "$protocol" \
        '.bindings[] | select(.port == $port and .protocol == $protocol) | .users[]' 2>/dev/null)

    if [[ -z "$user_ids" ]]; then
        echo "[]"
        return
    fi

    # 根据用户ID获取完整用户信息
    local users_array="[]"
    while IFS= read -r user_id; do
        local user_info=$(echo "$USERS_DATA" | jq -r \
            --arg uid "$user_id" \
            '.users[] | select(.id == $uid and .enabled == true)')

        if [[ -n "$user_info" ]]; then
            users_array=$(echo "$users_array" | jq --argjson user "$user_info" '. += [$user]')
        fi
    done <<< "$user_ids"

    echo "$users_array"
}

# =============================================================================
# 协议 Inbound 生成函数
# =============================================================================

# 生成 Shadowsocks Inbound
generate_shadowsocks_inbound() {
    local node=$1

    local port=$(echo "$node" | jq -r '.port')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local tag=$(echo "$node" | jq -r '.tag')
    local method=$(echo "$node" | jq -r '.extra.method // "aes-128-gcm"')

    # 获取绑定的用户
    local bound_users=$(get_bound_users "$port" "$protocol")

    # 构建用户列表 (sing-box shadowsocks 格式)
    local users_array="[]"
    local user_count=$(echo "$bound_users" | jq 'length')

    for ((i=0; i<user_count; i++)); do
        local user=$(echo "$bound_users" | jq -r ".[$i]")
        local email=$(echo "$user" | jq -r '.email')
        local password=$(echo "$user" | jq -r '.password')

        local user_obj=$(jq -n \
            --arg name "$email" \
            --arg password "$password" \
            '{name: $name, password: $password}')

        users_array=$(echo "$users_array" | jq --argjson user "$user_obj" '. += [$user]')
    done

    # 读取模板并替换变量
    local template=$(cat "${PROTOCOLS_DIR}/shadowsocks.json")

    local inbound=$(echo "$template" | jq \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg method "$method" \
        --argjson users "$users_array" \
        '.tag = $tag |
         .listen_port = $port |
         .method = $method |
         .users = $users')

    echo "$inbound"
}

# 生成 Trojan Inbound
generate_trojan_inbound() {
    local node=$1

    local port=$(echo "$node" | jq -r '.port')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local tag=$(echo "$node" | jq -r '.tag')
    local transport=$(echo "$node" | jq -r '.transport // "tcp"')

    # TLS 配置
    local tls_enabled=$(echo "$node" | jq -r '.extra.tls.enabled // true')
    local server_name=$(echo "$node" | jq -r '.extra.tls.server_name // ""')
    local cert_path=$(echo "$node" | jq -r '.extra.tls.certificate_path // ""')
    local key_path=$(echo "$node" | jq -r '.extra.tls.key_path // ""')

    # 获取绑定的用户
    local bound_users=$(get_bound_users "$port" "$protocol")

    # 构建用户列表 (sing-box trojan 格式)
    local users_array="[]"
    local user_count=$(echo "$bound_users" | jq 'length')

    for ((i=0; i<user_count; i++)); do
        local user=$(echo "$bound_users" | jq -r ".[$i]")
        local email=$(echo "$user" | jq -r '.email')
        local password=$(echo "$user" | jq -r '.password')

        local user_obj=$(jq -n \
            --arg name "$email" \
            --arg password "$password" \
            '{name: $name, password: $password}')

        users_array=$(echo "$users_array" | jq --argjson user "$user_obj" '. += [$user]')
    done

    # 读取模板
    local template=$(cat "${PROTOCOLS_DIR}/trojan.json")

    # 构建 TLS 配置
    local tls_config=$(jq -n \
        --argjson enabled "$tls_enabled" \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{enabled: $enabled, server_name: $server_name, certificate_path: $cert, key_path: $key}')

    # 替换变量
    local inbound=$(echo "$template" | jq \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson users "$users_array" \
        --argjson tls "$tls_config" \
        '.tag = $tag |
         .listen_port = $port |
         .users = $users |
         .tls = $tls')

    echo "$inbound"
}

# 生成 Hysteria2 Inbound
generate_hysteria2_inbound() {
    local node=$1

    local port=$(echo "$node" | jq -r '.port')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local tag=$(echo "$node" | jq -r '.tag')

    # TLS 配置
    local server_name=$(echo "$node" | jq -r '.extra.tls.server_name // ""')
    local cert_path=$(echo "$node" | jq -r '.extra.tls.certificate_path // ""')
    local key_path=$(echo "$node" | jq -r '.extra.tls.key_path // ""')

    # Obfs 配置
    local obfs_password=$(echo "$node" | jq -r '.extra.obfs.password // ""')

    # 获取绑定的用户
    local bound_users=$(get_bound_users "$port" "$protocol")

    # 构建用户列表
    local users_array="[]"
    local user_count=$(echo "$bound_users" | jq 'length')

    for ((i=0; i<user_count; i++)); do
        local user=$(echo "$bound_users" | jq -r ".[$i]")
        local email=$(echo "$user" | jq -r '.email')
        local password=$(echo "$user" | jq -r '.password')

        local user_obj=$(jq -n \
            --arg name "$email" \
            --arg password "$password" \
            '{name: $name, password: $password}')

        users_array=$(echo "$users_array" | jq --argjson user "$user_obj" '. += [$user]')
    done

    # 读取模板
    local template=$(cat "${PROTOCOLS_DIR}/hysteria2.json")

    # 构建配置
    local tls_config=$(jq -n \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{enabled: true, server_name: $server_name, certificate_path: $cert, key_path: $key}')

    local obfs_config=$(jq -n \
        --arg password "$obfs_password" \
        '{type: "salamander", password: $password}')

    # 替换变量
    local inbound=$(echo "$template" | jq \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson users "$users_array" \
        --argjson tls "$tls_config" \
        --argjson obfs "$obfs_config" \
        '.tag = $tag |
         .listen_port = $port |
         .users = $users |
         .tls = $tls |
         .obfs = $obfs')

    echo "$inbound"
}

# 生成 TUIC Inbound
generate_tuic_inbound() {
    local node=$1

    local port=$(echo "$node" | jq -r '.port')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local tag=$(echo "$node" | jq -r '.tag')

    # TLS 配置
    local server_name=$(echo "$node" | jq -r '.extra.tls.server_name // ""')
    local cert_path=$(echo "$node" | jq -r '.extra.tls.certificate_path // ""')
    local key_path=$(echo "$node" | jq -r '.extra.tls.key_path // ""')

    # 拥塞控制算法
    local congestion=$(echo "$node" | jq -r '.extra.congestion_control // "bbr"')

    # 获取绑定的用户
    local bound_users=$(get_bound_users "$port" "$protocol")

    # 构建用户列表 (TUIC 使用 uuid 和 password)
    local users_array="[]"
    local user_count=$(echo "$bound_users" | jq 'length')

    for ((i=0; i<user_count; i++)); do
        local user=$(echo "$bound_users" | jq -r ".[$i]")
        local uuid=$(echo "$user" | jq -r '.id')
        local password=$(echo "$user" | jq -r '.password')

        local user_obj=$(jq -n \
            --arg uuid "$uuid" \
            --arg password "$password" \
            '{uuid: $uuid, password: $password}')

        users_array=$(echo "$users_array" | jq --argjson user "$user_obj" '. += [$user]')
    done

    # 读取模板
    local template=$(cat "${PROTOCOLS_DIR}/tuic.json")

    # 构建 TLS 配置
    local tls_config=$(jq -n \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{enabled: true, server_name: $server_name, certificate_path: $cert, key_path: $key}')

    # 替换变量
    local inbound=$(echo "$template" | jq \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson users "$users_array" \
        --arg congestion "$congestion" \
        --argjson tls "$tls_config" \
        '.tag = $tag |
         .listen_port = $port |
         .users = $users |
         .congestion_control = $congestion |
         .tls = $tls')

    echo "$inbound"
}

# 生成 Naive Inbound
generate_naive_inbound() {
    local node=$1

    local port=$(echo "$node" | jq -r '.port')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local tag=$(echo "$node" | jq -r '.tag')

    # TLS 配置（Naive 必须）
    local server_name=$(echo "$node" | jq -r '.extra.tls.server_name // ""')
    local cert_path=$(echo "$node" | jq -r '.extra.tls.certificate_path // ""')
    local key_path=$(echo "$node" | jq -r '.extra.tls.key_path // ""')

    # 获取绑定的用户
    local bound_users=$(get_bound_users "$port" "$protocol")

    # 构建用户列表 (Naive 使用 username 和 password)
    local users_array="[]"
    local user_count=$(echo "$bound_users" | jq 'length')

    for ((i=0; i<user_count; i++)); do
        local user=$(echo "$bound_users" | jq -r ".[$i]")
        local username=$(echo "$user" | jq -r '.username')
        local password=$(echo "$user" | jq -r '.password')

        local user_obj=$(jq -n \
            --arg username "$username" \
            --arg password "$password" \
            '{username: $username, password: $password}')

        users_array=$(echo "$users_array" | jq --argjson user "$user_obj" '. += [$user]')
    done

    # 读取模板
    local template=$(cat "${PROTOCOLS_DIR}/naive.json")

    # 构建 TLS 配置
    local tls_config=$(jq -n \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{enabled: true, server_name: $server_name, certificate_path: $cert, key_path: $key}')

    # 替换变量
    local inbound=$(echo "$template" | jq \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson users "$users_array" \
        --argjson tls "$tls_config" \
        '.tag = $tag |
         .listen_port = $port |
         .users = $users |
         .tls = $tls')

    echo "$inbound"
}

# 生成 VMess Inbound
generate_vmess_inbound() {
    local node=$1

    local port=$(echo "$node" | jq -r '.port')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local tag=$(echo "$node" | jq -r '.tag')

    # TLS 配置（可选）
    local tls_enabled=$(echo "$node" | jq -r '.extra.tls.enabled // false')
    local server_name=$(echo "$node" | jq -r '.extra.tls.server_name // ""')
    local cert_path=$(echo "$node" | jq -r '.extra.tls.certificate_path // ""')
    local key_path=$(echo "$node" | jq -r '.extra.tls.key_path // ""')

    # 传输方式（可选）
    local transport_type=$(echo "$node" | jq -r '.extra.transport.type // ""')

    # 获取绑定的用户
    local bound_users=$(get_bound_users "$port" "$protocol")

    # 构建用户列表 (VMess 使用 name, uuid, alterId)
    local users_array="[]"
    local user_count=$(echo "$bound_users" | jq 'length')

    for ((i=0; i<user_count; i++)); do
        local user=$(echo "$bound_users" | jq -r ".[$i]")
        local username=$(echo "$user" | jq -r '.username')
        local uuid=$(echo "$user" | jq -r '.id')

        local user_obj=$(jq -n \
            --arg name "$username" \
            --arg uuid "$uuid" \
            '{name: $name, uuid: $uuid, alterId: 0}')

        users_array=$(echo "$users_array" | jq --argjson user "$user_obj" '. += [$user]')
    done

    # 读取模板
    local template=$(cat "${PROTOCOLS_DIR}/vmess.json")

    # 构建 TLS 配置
    local tls_config="null"
    if [[ "$tls_enabled" == "true" ]]; then
        tls_config=$(jq -n \
            --arg server_name "$server_name" \
            --arg cert "$cert_path" \
            --arg key "$key_path" \
            '{enabled: true, server_name: $server_name, certificate_path: $cert, key_path: $key}')
    fi

    # 构建传输配置
    local transport_config="null"
    if [[ -n "$transport_type" && "$transport_type" != "null" ]]; then
        transport_config=$(echo "$node" | jq -r '.extra.transport')
    fi

    # 替换变量
    local inbound=$(echo "$template" | jq \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson users "$users_array" \
        --argjson tls "$tls_config" \
        --argjson transport "$transport_config" \
        '.tag = $tag |
         .listen_port = $port |
         .users = $users |
         .tls = $tls |
         .transport = $transport')

    echo "$inbound"
}

# 生成 VLESS Inbound
generate_vless_inbound() {
    local node=$1

    local port=$(echo "$node" | jq -r '.port')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local tag=$(echo "$node" | jq -r '.tag')

    # TLS 配置（VLESS 通常需要 TLS）
    local server_name=$(echo "$node" | jq -r '.extra.tls.server_name // ""')
    local cert_path=$(echo "$node" | jq -r '.extra.tls.certificate_path // ""')
    local key_path=$(echo "$node" | jq -r '.extra.tls.key_path // ""')

    # Flow 配置（可选：xtls-rprx-vision）
    local flow=$(echo "$node" | jq -r '.extra.flow // ""')

    # 传输方式（可选）
    local transport_type=$(echo "$node" | jq -r '.extra.transport.type // ""')

    # 获取绑定的用户
    local bound_users=$(get_bound_users "$port" "$protocol")

    # 构建用户列表 (VLESS 使用 name, uuid, flow)
    local users_array="[]"
    local user_count=$(echo "$bound_users" | jq 'length')

    for ((i=0; i<user_count; i++)); do
        local user=$(echo "$bound_users" | jq -r ".[$i]")
        local username=$(echo "$user" | jq -r '.username')
        local uuid=$(echo "$user" | jq -r '.id')

        local user_obj=$(jq -n \
            --arg name "$username" \
            --arg uuid "$uuid" \
            --arg flow "$flow" \
            '{name: $name, uuid: $uuid, flow: $flow}')

        users_array=$(echo "$users_array" | jq --argjson user "$user_obj" '. += [$user]')
    done

    # 读取模板
    local template=$(cat "${PROTOCOLS_DIR}/vless.json")

    # 构建 TLS 配置
    local tls_config=$(jq -n \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{enabled: true, server_name: $server_name, certificate_path: $cert, key_path: $key}')

    # 构建传输配置
    local transport_config="null"
    if [[ -n "$transport_type" && "$transport_type" != "null" ]]; then
        transport_config=$(echo "$node" | jq -r '.extra.transport')
    fi

    # 替换变量
    local inbound=$(echo "$template" | jq \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson users "$users_array" \
        --argjson tls "$tls_config" \
        --argjson transport "$transport_config" \
        '.tag = $tag |
         .listen_port = $port |
         .users = $users |
         .tls = $tls |
         .transport = $transport')

    echo "$inbound"
}

# 生成 ShadowTLS Inbound
generate_shadowtls_inbound() {
    local node=$1

    local port=$(echo "$node" | jq -r '.port')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local tag=$(echo "$node" | jq -r '.tag')

    # ShadowTLS 版本
    local version=$(echo "$node" | jq -r '.extra.version // 3')

    # 握手服务器配置
    local handshake_server=$(echo "$node" | jq -r '.extra.handshake.server // "cloudflare.com"')
    local handshake_port=$(echo "$node" | jq -r '.extra.handshake.port // 443')

    # Strict mode（仅 v3）
    local strict_mode=$(echo "$node" | jq -r '.extra.strict_mode // false')

    # 获取绑定的用户
    local bound_users=$(get_bound_users "$port" "$protocol")

    # 构建用户列表 (ShadowTLS v3 使用 name, password)
    local users_array="[]"
    local user_count=$(echo "$bound_users" | jq 'length')

    for ((i=0; i<user_count; i++)); do
        local user=$(echo "$bound_users" | jq -r ".[$i]")
        local username=$(echo "$user" | jq -r '.username')
        local password=$(echo "$user" | jq -r '.password')

        local user_obj=$(jq -n \
            --arg name "$username" \
            --arg password "$password" \
            '{name: $name, password: $password}')

        users_array=$(echo "$users_array" | jq --argjson user "$user_obj" '. += [$user]')
    done

    # 读取模板
    local template=$(cat "${PROTOCOLS_DIR}/shadowtls.json")

    # 构建握手配置
    local handshake_config=$(jq -n \
        --arg server "$handshake_server" \
        --argjson port "$handshake_port" \
        '{server: $server, server_port: $port}')

    # 替换变量
    local inbound=$(echo "$template" | jq \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson version "$version" \
        --argjson users "$users_array" \
        --argjson handshake "$handshake_config" \
        --argjson strict_mode "$strict_mode" \
        '.tag = $tag |
         .listen_port = $port |
         .version = $version |
         .users = $users |
         .handshake = $handshake |
         .strict_mode = $strict_mode')

    echo "$inbound"
}

# =============================================================================
# 主配置生成函数
# =============================================================================

# 生成所有 inbounds
generate_inbounds() {
    local inbounds_array="[]"

    # 获取所有节点
    local nodes=$(echo "$NODES_DATA" | jq -r '.nodes[]')
    local node_count=$(echo "$NODES_DATA" | jq '.nodes | length')

    for ((i=0; i<node_count; i++)); do
        local node=$(echo "$NODES_DATA" | jq -r ".nodes[$i]")
        local protocol=$(echo "$node" | jq -r '.protocol')

        local inbound=""
        case "$protocol" in
            shadowsocks)
                inbound=$(generate_shadowsocks_inbound "$node")
                ;;
            trojan)
                inbound=$(generate_trojan_inbound "$node")
                ;;
            hysteria2)
                inbound=$(generate_hysteria2_inbound "$node")
                ;;
            tuic)
                inbound=$(generate_tuic_inbound "$node")
                ;;
            naive)
                inbound=$(generate_naive_inbound "$node")
                ;;
            vmess)
                inbound=$(generate_vmess_inbound "$node")
                ;;
            vless)
                inbound=$(generate_vless_inbound "$node")
                ;;
            shadowtls)
                inbound=$(generate_shadowtls_inbound "$node")
                ;;
            *)
                print_warn "未知协议: $protocol, 跳过"
                continue
                ;;
        esac

        if [[ -n "$inbound" ]]; then
            inbounds_array=$(echo "$inbounds_array" | jq --argjson inbound "$inbound" '. += [$inbound]')
        fi
    done

    echo "$inbounds_array"
}

# 生成完整配置
generate_singbox_config() {
    print_info "开始生成 sing-box 配置..."

    # 1. 加载数据文件
    if ! load_data_files; then
        return 1
    fi

    # 2. 读取基础配置模板
    if [[ ! -f "$BASE_TEMPLATE" ]]; then
        print_error "基础配置模板不存在: $BASE_TEMPLATE"
        return 1
    fi

    local base_config=$(cat "$BASE_TEMPLATE")

    # 3. 生成 inbounds
    print_info "生成 inbound 配置..."
    local inbounds=$(generate_inbounds)

    # 4. 合并配置
    local final_config=$(echo "$base_config" | jq --argjson inbounds "$inbounds" '.inbounds = $inbounds')

    # 5. 创建临时文件
    local temp_config="${SINGBOX_CONFIG_FILE}.tmp"
    echo "$final_config" | jq '.' > "$temp_config"

    # 6. 校验配置
    print_info "校验配置文件..."
    if command -v sing-box &>/dev/null; then
        if ! sing-box check -c "$temp_config" 2>&1; then
            print_error "配置校验失败"
            rm -f "$temp_config"
            return 1
        fi
    else
        print_warn "sing-box 未安装，跳过配置校验"
    fi

    # 7. 备份旧配置
    if [[ -f "$SINGBOX_CONFIG_FILE" ]]; then
        print_info "备份旧配置..."
        cp "$SINGBOX_CONFIG_FILE" "$SINGBOX_CONFIG_BACKUP"
    fi

    # 8. 应用新配置
    mkdir -p "$SINGBOX_CONFIG_DIR"
    mv "$temp_config" "$SINGBOX_CONFIG_FILE"

    print_success "配置生成成功: $SINGBOX_CONFIG_FILE"
    return 0
}

# 恢复备份配置
restore_config_backup() {
    if [[ -f "$SINGBOX_CONFIG_BACKUP" ]]; then
        print_info "恢复备份配置..."
        cp "$SINGBOX_CONFIG_BACKUP" "$SINGBOX_CONFIG_FILE"
        print_success "配置已恢复"
        return 0
    else
        print_error "备份配置不存在"
        return 1
    fi
}

# 查看当前配置
show_current_config() {
    if [[ -f "$SINGBOX_CONFIG_FILE" ]]; then
        cat "$SINGBOX_CONFIG_FILE" | jq '.'
    else
        print_error "配置文件不存在: $SINGBOX_CONFIG_FILE"
        return 1
    fi
}

# 通用打印函数（依赖 common.sh）
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
