#!/bin/bash

# =============================================================================
# sing-box 节点管理模块
# 功能：添加、删除、列表、修改节点
# =============================================================================

DATA_DIR="./data"
NODES_FILE="${DATA_DIR}/nodes.json"
BINDINGS_FILE="${DATA_DIR}/node_users.json"

# =============================================================================
# 节点操作函数
# =============================================================================

# 检查端口是否被占用
check_port_conflict() {
    local port=$1

    # 检查 nodes.json 中是否已存在
    local existing=$(jq -r --arg port "$port" '.nodes[] | select(.port == $port) | .port' "$NODES_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        print_error "端口 $port 已被使用"
        return 1
    fi

    # 检查系统端口占用
    if command -v netstat &>/dev/null; then
        if netstat -tuln | grep -q ":${port} "; then
            print_warn "端口 $port 系统中已被占用"
            return 1
        fi
    fi

    return 0
}

# 生成节点标签
generate_node_tag() {
    local protocol=$1
    local port=$2

    echo "${protocol}-${port}"
}

# 生成随机密码
generate_random_password() {
    local length=${1:-16}
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "$length"
}

# =============================================================================
# 添加节点
# =============================================================================

# 添加 Shadowsocks 节点
add_shadowsocks_node() {
    print_info "添加 Shadowsocks 节点"

    # 输入端口
    read -p "请输入监听端口 [443]: " port
    port=${port:-443}

    # 检查端口冲突
    if ! check_port_conflict "$port"; then
        return 1
    fi

    # 选择加密方法
    echo "请选择加密方法:"
    echo "1) aes-128-gcm (推荐)"
    echo "2) aes-256-gcm"
    echo "3) chacha20-ietf-poly1305"
    read -p "请选择 [1]: " method_choice
    method_choice=${method_choice:-1}

    case "$method_choice" in
        1) method="aes-128-gcm" ;;
        2) method="aes-256-gcm" ;;
        3) method="chacha20-ietf-poly1305" ;;
        *) method="aes-128-gcm" ;;
    esac

    # 生成节点配置
    local tag=$(generate_node_tag "shadowsocks" "$port")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "shadowsocks" \
        --arg transport "tcp" \
        --arg security "none" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --arg method "$method" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: {
                method: $method
            }
        }')

    # 添加到 nodes.json
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    print_success "Shadowsocks 节点添加成功"
    print_info "端口: $port"
    print_info "标签: $tag"
    print_info "加密: $method"

    # 询问是否绑定 admin 用户
    read -p "是否绑定 admin 用户? [Y/n]: " bind_admin
    bind_admin=${bind_admin:-Y}

    if [[ "$bind_admin" =~ ^[Yy]$ ]]; then
        bind_admin_to_node "$port" "shadowsocks"
    fi

    return 0
}

# 添加 Trojan 节点
add_trojan_node() {
    print_info "添加 Trojan 节点"

    # 输入端口
    read -p "请输入监听端口 [443]: " port
    port=${port:-443}

    # 检查端口冲突
    if ! check_port_conflict "$port"; then
        return 1
    fi

    # 选择传输层
    echo "请选择传输层:"
    echo "1) TCP (推荐)"
    echo "2) WebSocket"
    echo "3) gRPC"
    read -p "请选择 [1]: " transport_choice
    transport_choice=${transport_choice:-1}

    case "$transport_choice" in
        1) transport="tcp" ;;
        2) transport="ws" ;;
        3) transport="grpc" ;;
        *) transport="tcp" ;;
    esac

    # TLS 配置
    read -p "是否启用 TLS? [Y/n]: " enable_tls
    enable_tls=${enable_tls:-Y}

    local tls_config="{}"
    if [[ "$enable_tls" =~ ^[Yy]$ ]]; then
        read -p "请输入 Server Name (域名): " server_name
        read -p "请输入证书路径: " cert_path
        read -p "请输入私钥路径: " key_path

        tls_config=$(jq -n \
            --argjson enabled true \
            --arg server_name "$server_name" \
            --arg cert "$cert_path" \
            --arg key "$key_path" \
            '{
                enabled: $enabled,
                server_name: $server_name,
                certificate_path: $cert,
                key_path: $key
            }')
    fi

    # 生成节点配置
    local tag=$(generate_node_tag "trojan" "$port")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "trojan" \
        --arg transport "$transport" \
        --arg security "tls" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --argjson tls "$tls_config" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: {
                tls: $tls
            }
        }')

    # 添加到 nodes.json
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    print_success "Trojan 节点添加成功"
    print_info "端口: $port"
    print_info "标签: $tag"
    print_info "传输: $transport"

    # 询问是否绑定 admin 用户
    read -p "是否绑定 admin 用户? [Y/n]: " bind_admin
    bind_admin=${bind_admin:-Y}

    if [[ "$bind_admin" =~ ^[Yy]$ ]]; then
        bind_admin_to_node "$port" "trojan"
    fi

    return 0
}

# 添加 Hysteria2 节点
add_hysteria2_node() {
    print_info "添加 Hysteria2 节点"

    # 输入端口
    read -p "请输入监听端口 [8443]: " port
    port=${port:-8443}

    # 检查端口冲突
    if ! check_port_conflict "$port"; then
        return 1
    fi

    # TLS 配置（Hysteria2 必须）
    read -p "请输入 Server Name (域名): " server_name
    read -p "请输入证书路径: " cert_path
    read -p "请输入私钥路径: " key_path

    tls_config=$(jq -n \
        --argjson enabled true \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{
            enabled: $enabled,
            server_name: $server_name,
            certificate_path: $cert,
            key_path: $key
        }')

    # Obfs 配置
    read -p "是否启用混淆? [y/N]: " enable_obfs
    enable_obfs=${enable_obfs:-N}

    local obfs_config="{}"
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        local obfs_password=$(generate_random_password 16)
        print_info "混淆密码（自动生成）: $obfs_password"

        obfs_config=$(jq -n \
            --arg password "$obfs_password" \
            '{
                type: "salamander",
                password: $password
            }')
    fi

    # 生成节点配置
    local tag=$(generate_node_tag "hysteria2" "$port")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "hysteria2" \
        --arg transport "udp" \
        --arg security "tls" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --argjson tls "$tls_config" \
        --argjson obfs "$obfs_config" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: {
                tls: $tls,
                obfs: $obfs
            }
        }')

    # 添加到 nodes.json
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    print_success "Hysteria2 节点添加成功"
    print_info "端口: $port"
    print_info "标签: $tag"

    # 询问是否绑定 admin 用户
    read -p "是否绑定 admin 用户? [Y/n]: " bind_admin
    bind_admin=${bind_admin:-Y}

    if [[ "$bind_admin" =~ ^[Yy]$ ]]; then
        bind_admin_to_node "$port" "hysteria2"
    fi

    return 0
}

# 添加 TUIC 节点
add_tuic_node() {
    print_info "添加 TUIC 节点"

    # 输入端口
    read -p "请输入监听端口 [8443]: " port
    port=${port:-8443}

    # 检查端口冲突
    if ! check_port_conflict "$port"; then
        return 1
    fi

    # TLS 配置（TUIC 必须）
    read -p "请输入 Server Name (域名): " server_name
    read -p "请输入证书路径: " cert_path
    read -p "请输入私钥路径: " key_path

    tls_config=$(jq -n \
        --argjson enabled true \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{
            enabled: $enabled,
            server_name: $server_name,
            certificate_path: $cert,
            key_path: $key
        }')

    # 拥塞控制算法
    echo "请选择拥塞控制算法:"
    echo "1) bbr (推荐)"
    echo "2) cubic"
    echo "3) new_reno"
    read -p "请选择 [1]: " congestion_choice
    congestion_choice=${congestion_choice:-1}

    case "$congestion_choice" in
        1) congestion="bbr" ;;
        2) congestion="cubic" ;;
        3) congestion="new_reno" ;;
        *) congestion="bbr" ;;
    esac

    # 生成节点配置
    local tag=$(generate_node_tag "tuic" "$port")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "tuic" \
        --arg transport "udp" \
        --arg security "tls" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --arg congestion "$congestion" \
        --argjson tls "$tls_config" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: {
                tls: $tls,
                congestion_control: $congestion
            }
        }')

    # 添加到 nodes.json
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    print_success "TUIC 节点添加成功"
    print_info "端口: $port"
    print_info "标签: $tag"
    print_info "拥塞控制: $congestion"

    # 询问是否绑定 admin 用户
    read -p "是否绑定 admin 用户? [Y/n]: " bind_admin
    bind_admin=${bind_admin:-Y}

    if [[ "$bind_admin" =~ ^[Yy]$ ]]; then
        bind_admin_to_node "$port" "tuic"
    fi

    return 0
}

# 添加 Naive 节点
add_naive_node() {
    print_info "添加 Naive 节点"

    # 输入端口
    read -p "请输入监听端口 [443]: " port
    port=${port:-443}

    # 检查端口冲突
    if ! check_port_conflict "$port"; then
        return 1
    fi

    # TLS 配置（Naive 必须）
    read -p "请输入 Server Name (域名): " server_name
    read -p "请输入证书路径: " cert_path
    read -p "请输入私钥路径: " key_path

    tls_config=$(jq -n \
        --argjson enabled true \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{
            enabled: $enabled,
            server_name: $server_name,
            certificate_path: $cert,
            key_path: $key
        }')

    # 生成节点配置
    local tag=$(generate_node_tag "naive" "$port")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "naive" \
        --arg transport "tcp" \
        --arg security "tls" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --argjson tls "$tls_config" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: {
                tls: $tls
            }
        }')

    # 添加到 nodes.json
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    print_success "Naive 节点添加成功"
    print_info "端口: $port"
    print_info "标签: $tag"

    # 询问是否绑定 admin 用户
    read -p "是否绑定 admin 用户? [Y/n]: " bind_admin
    bind_admin=${bind_admin:-Y}

    if [[ "$bind_admin" =~ ^[Yy]$ ]]; then
        bind_admin_to_node "$port" "naive"
    fi

    return 0
}

# 添加 VMess 节点
add_vmess_node() {
    print_info "添加 VMess 节点"

    # 输入端口
    read -p "请输入监听端口 [10086]: " port
    port=${port:-10086}

    # 检查端口冲突
    if ! check_port_conflict "$port"; then
        return 1
    fi

    # TLS 配置（可选）
    read -p "是否启用 TLS? [y/N]: " enable_tls
    enable_tls=${enable_tls:-N}

    local tls_config="null"
    local security="none"
    if [[ "$enable_tls" =~ ^[Yy]$ ]]; then
        read -p "请输入 Server Name (域名): " server_name
        read -p "请输入证书路径: " cert_path
        read -p "请输入私钥路径: " key_path

        tls_config=$(jq -n \
            --argjson enabled true \
            --arg server_name "$server_name" \
            --arg cert "$cert_path" \
            --arg key "$key_path" \
            '{
                enabled: $enabled,
                server_name: $server_name,
                certificate_path: $cert,
                key_path: $key
            }')
        security="tls"
    fi

    # 传输方式（可选）
    echo "请选择传输方式:"
    echo "1) TCP (默认)"
    echo "2) WebSocket"
    echo "3) gRPC"
    read -p "请选择 [1]: " transport_choice
    transport_choice=${transport_choice:-1}

    local transport="tcp"
    local transport_config="null"
    case "$transport_choice" in
        1) transport="tcp" ;;
        2)
            transport="ws"
            read -p "请输入 WebSocket 路径 [/]: " ws_path
            ws_path=${ws_path:-/}
            transport_config=$(jq -n --arg path "$ws_path" '{type: "ws", path: $path}')
            ;;
        3)
            transport="grpc"
            read -p "请输入 gRPC Service Name [/]: " grpc_service
            grpc_service=${grpc_service:-/}
            transport_config=$(jq -n --arg service "$grpc_service" '{type: "grpc", service_name: $service}')
            ;;
        *) transport="tcp" ;;
    esac

    # 生成节点配置
    local tag=$(generate_node_tag "vmess" "$port")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local extra=$(jq -n \
        --argjson tls "$tls_config" \
        --argjson transport "$transport_config" \
        '{tls: $tls, transport: $transport}')

    if [[ "$tls_config" == "null" ]]; then
        extra=$(echo "$extra" | jq 'del(.tls)')
    fi
    if [[ "$transport_config" == "null" ]]; then
        extra=$(echo "$extra" | jq 'del(.transport)')
    fi

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "vmess" \
        --arg transport "$transport" \
        --arg security "$security" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --argjson extra "$extra" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: $extra
        }')

    # 添加到 nodes.json
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    print_success "VMess 节点添加成功"
    print_info "端口: $port"
    print_info "标签: $tag"
    print_info "传输: $transport"
    print_info "TLS: $security"

    # 询问是否绑定 admin 用户
    read -p "是否绑定 admin 用户? [Y/n]: " bind_admin
    bind_admin=${bind_admin:-Y}

    if [[ "$bind_admin" =~ ^[Yy]$ ]]; then
        bind_admin_to_node "$port" "vmess"
    fi

    return 0
}

# 添加 VLESS 节点
add_vless_node() {
    print_info "添加 VLESS 节点"

    # 输入端口
    read -p "请输入监听端口 [443]: " port
    port=${port:-443}

    # 检查端口冲突
    if ! check_port_conflict "$port"; then
        return 1
    fi

    # TLS 配置（VLESS 通常需要）
    read -p "请输入 Server Name (域名): " server_name
    read -p "请输入证书路径: " cert_path
    read -p "请输入私钥路径: " key_path

    tls_config=$(jq -n \
        --argjson enabled true \
        --arg server_name "$server_name" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        '{
            enabled: $enabled,
            server_name: $server_name,
            certificate_path: $cert,
            key_path: $key
        }')

    # Flow 配置（可选）
    echo "请选择 Flow 配置:"
    echo "1) 无 (默认)"
    echo "2) xtls-rprx-vision"
    read -p "请选择 [1]: " flow_choice
    flow_choice=${flow_choice:-1}

    local flow=""
    case "$flow_choice" in
        1) flow="" ;;
        2) flow="xtls-rprx-vision" ;;
        *) flow="" ;;
    esac

    # 传输方式（可选）
    echo "请选择传输方式:"
    echo "1) TCP (默认)"
    echo "2) WebSocket"
    echo "3) gRPC"
    read -p "请选择 [1]: " transport_choice
    transport_choice=${transport_choice:-1}

    local transport="tcp"
    local transport_config="null"
    case "$transport_choice" in
        1) transport="tcp" ;;
        2)
            transport="ws"
            read -p "请输入 WebSocket 路径 [/]: " ws_path
            ws_path=${ws_path:-/}
            transport_config=$(jq -n --arg path "$ws_path" '{type: "ws", path: $path}')
            ;;
        3)
            transport="grpc"
            read -p "请输入 gRPC Service Name [/]: " grpc_service
            grpc_service=${grpc_service:-/}
            transport_config=$(jq -n --arg service "$grpc_service" '{type: "grpc", service_name: $service}')
            ;;
        *) transport="tcp" ;;
    esac

    # 生成节点配置
    local tag=$(generate_node_tag "vless" "$port")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local extra=$(jq -n \
        --argjson tls "$tls_config" \
        --argjson transport "$transport_config" \
        --arg flow "$flow" \
        '{tls: $tls, transport: $transport, flow: $flow}')

    if [[ "$transport_config" == "null" ]]; then
        extra=$(echo "$extra" | jq 'del(.transport)')
    fi
    if [[ -z "$flow" ]]; then
        extra=$(echo "$extra" | jq 'del(.flow)')
    fi

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "vless" \
        --arg transport "$transport" \
        --arg security "tls" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --argjson extra "$extra" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: $extra
        }')

    # 添加到 nodes.json
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    print_success "VLESS 节点添加成功"
    print_info "端口: $port"
    print_info "标签: $tag"
    print_info "传输: $transport"
    print_info "Flow: ${flow:-无}"

    # 询问是否绑定 admin 用户
    read -p "是否绑定 admin 用户? [Y/n]: " bind_admin
    bind_admin=${bind_admin:-Y}

    if [[ "$bind_admin" =~ ^[Yy]$ ]]; then
        bind_admin_to_node "$port" "vless"
    fi

    return 0
}

# 添加 ShadowTLS 节点
add_shadowtls_node() {
    print_info "添加 ShadowTLS 节点"

    # 输入端口
    read -p "请输入监听端口 [443]: " port
    port=${port:-443}

    # 检查端口冲突
    if ! check_port_conflict "$port"; then
        return 1
    fi

    # 选择版本
    echo "请选择 ShadowTLS 版本:"
    echo "1) v1"
    echo "2) v2"
    echo "3) v3 (推荐)"
    read -p "请选择 [3]: " version_choice
    version_choice=${version_choice:-3}

    local version=3
    case "$version_choice" in
        1) version=1 ;;
        2) version=2 ;;
        3) version=3 ;;
        *) version=3 ;;
    esac

    # 握手服务器配置
    read -p "请输入握手服务器地址 [cloudflare.com]: " handshake_server
    handshake_server=${handshake_server:-cloudflare.com}

    read -p "请输入握手服务器端口 [443]: " handshake_port
    handshake_port=${handshake_port:-443}

    handshake_config=$(jq -n \
        --arg server "$handshake_server" \
        --argjson port "$handshake_port" \
        '{server: $server, port: $port}')

    # Strict mode（仅 v3）
    local strict_mode=false
    if [[ $version -eq 3 ]]; then
        read -p "是否启用严格模式? [y/N]: " enable_strict
        enable_strict=${enable_strict:-N}

        if [[ "$enable_strict" =~ ^[Yy]$ ]]; then
            strict_mode=true
        fi
    fi

    # 生成节点配置
    local tag=$(generate_node_tag "shadowtls" "$port")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local extra=$(jq -n \
        --argjson version "$version" \
        --argjson handshake "$handshake_config" \
        --argjson strict_mode "$strict_mode" \
        '{version: $version, handshake: $handshake, strict_mode: $strict_mode}')

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "shadowtls" \
        --arg transport "tcp" \
        --arg security "shadowtls" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --argjson extra "$extra" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: $extra
        }')

    # 添加到 nodes.json
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    print_success "ShadowTLS 节点添加成功"
    print_info "端口: $port"
    print_info "标签: $tag"
    print_info "版本: v$version"
    print_info "握手服务器: $handshake_server:$handshake_port"

    # 询问是否绑定 admin 用户
    read -p "是否绑定 admin 用户? [Y/n]: " bind_admin
    bind_admin=${bind_admin:-Y}

    if [[ "$bind_admin" =~ ^[Yy]$ ]]; then
        bind_admin_to_node "$port" "shadowtls"
    fi

    return 0
}

# 主添加节点函数
add_node() {
    echo "请选择协议类型:"
    echo "1) Shadowsocks"
    echo "2) Trojan"
    echo "3) Hysteria2"
    echo "4) TUIC"
    echo "5) Naive"
    echo "6) VMess"
    echo "7) VLESS"
    echo "8) ShadowTLS"
    echo "0) 返回"

    read -p "请选择 [1]: " protocol_choice
    protocol_choice=${protocol_choice:-1}

    case "$protocol_choice" in
        1)
            add_shadowsocks_node
            ;;
        2)
            add_trojan_node
            ;;
        3)
            add_hysteria2_node
            ;;
        4)
            add_tuic_node
            ;;
        5)
            add_naive_node
            ;;
        6)
            add_vmess_node
            ;;
        7)
            add_vless_node
            ;;
        8)
            add_shadowtls_node
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac

    # 添加成功后重新生成配置
    if [[ $? -eq 0 ]]; then
        print_info "重新生成 sing-box 配置..."
        source modules/config_generator.sh
        generate_singbox_config

        # 询问是否重载服务
        read -p "是否重载 sing-box 服务? [Y/n]: " reload_service
        reload_service=${reload_service:-Y}

        if [[ "$reload_service" =~ ^[Yy]$ ]]; then
            systemctl reload sing-box 2>/dev/null || print_warn "服务重载失败或服务未运行"
        fi
    fi
}

# =============================================================================
# 删除节点
# =============================================================================

delete_node() {
    # 列出所有节点
    list_nodes

    # 选择节点
    read -p "请输入要删除的节点端口: " port

    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 获取节点协议
    local protocol=$(jq -r --arg port "$port" '.nodes[] | select(.port == $port) | .protocol' "$NODES_FILE" 2>/dev/null)

    if [[ -z "$protocol" ]]; then
        print_error "节点不存在: 端口 $port"
        return 1
    fi

    # 确认删除
    read -p "确认删除节点 $protocol:$port? [y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return 0
    fi

    # 从 nodes.json 删除
    local nodes_data=$(cat "$NODES_FILE")
    nodes_data=$(echo "$nodes_data" | jq --arg port "$port" '.nodes = [.nodes[] | select(.port != $port)]')
    echo "$nodes_data" | jq '.' > "$NODES_FILE"

    # 从 bindings 删除
    local bindings_data=$(cat "$BINDINGS_FILE")
    bindings_data=$(echo "$bindings_data" | jq --arg port "$port" --arg protocol "$protocol" \
        '.bindings = [.bindings[] | select(.port != $port or .protocol != $protocol)]')
    echo "$bindings_data" | jq '.' > "$BINDINGS_FILE"

    print_success "节点已删除: $protocol:$port"

    # 重新生成配置
    print_info "重新生成 sing-box 配置..."
    source modules/config_generator.sh
    generate_singbox_config

    # 重载服务
    read -p "是否重载 sing-box 服务? [Y/n]: " reload_service
    reload_service=${reload_service:-Y}

    if [[ "$reload_service" =~ ^[Yy]$ ]]; then
        systemctl reload sing-box 2>/dev/null || print_warn "服务重载失败或服务未运行"
    fi
}

# =============================================================================
# 列出节点
# =============================================================================

list_nodes() {
    print_info "当前节点列表:"

    # 格式化输出
    local nodes=$(jq -r '.nodes[]' "$NODES_FILE" 2>/dev/null)

    if [[ -z "$nodes" ]]; then
        print_warn "暂无节点"
        return 0
    fi

    # 表头
    printf "%-8s %-12s %-10s %-10s %-8s\n" "端口" "协议" "传输" "安全" "标签"
    printf "%-8s %-12s %-10s %-10s %-8s\n" "----" "--------" "------" "------" "----"

    # 遍历节点
    local node_count=$(jq '.nodes | length' "$NODES_FILE")

    for ((i=0; i<node_count; i++)); do
        local node=$(jq -r ".nodes[$i]" "$NODES_FILE")
        local port=$(echo "$node" | jq -r '.port')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local transport=$(echo "$node" | jq -r '.transport')
        local security=$(echo "$node" | jq -r '.security')
        local tag=$(echo "$node" | jq -r '.tag')

        printf "%-8s %-12s %-10s %-10s %-8s\n" "$port" "$protocol" "$transport" "$security" "$tag"
    done

    echo ""
}

# =============================================================================
# 辅助函数
# =============================================================================

# 绑定 admin 用户到节点
bind_admin_to_node() {
    local port=$1
    local protocol=$2

    # 获取 admin 用户 UUID
    local admin_uuid=$(jq -r '.users[] | select(.username == "admin") | .id' "${DATA_DIR}/users.json" 2>/dev/null)

    if [[ -z "$admin_uuid" ]]; then
        print_warn "admin 用户不存在"
        return 1
    fi

    # 检查绑定是否已存在
    local existing=$(jq -r --arg port "$port" --arg protocol "$protocol" \
        '.bindings[] | select(.port == $port and .protocol == $protocol)' "$BINDINGS_FILE" 2>/dev/null)

    local bindings_data=$(cat "$BINDINGS_FILE")

    if [[ -n "$existing" ]]; then
        # 更新现有绑定
        bindings_data=$(echo "$bindings_data" | jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$admin_uuid" \
            '(.bindings[] | select(.port == $port and .protocol == $protocol) | .users) += [$uuid] | .bindings[].users |= unique')
    else
        # 创建新绑定
        local new_binding=$(jq -n \
            --arg port "$port" \
            --arg protocol "$protocol" \
            --arg uuid "$admin_uuid" \
            '{port: $port, protocol: $protocol, users: [$uuid]}')

        bindings_data=$(echo "$bindings_data" | jq --argjson binding "$new_binding" '.bindings += [$binding]')
    fi

    echo "$bindings_data" | jq '.' > "$BINDINGS_FILE"

    print_success "已绑定 admin 用户到节点 $protocol:$port"
}

# 通用打印函数
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
