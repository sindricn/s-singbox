#!/bin/bash

#================================================================
# sing-box 配置生成模块（修复版）
# 功能：根据nodes.json、users.json、node_users.json生成正确的sing-box config.json
# 重要：使用sing-box原生格式，不是Xray格式
#================================================================

# 生成sing-box完整配置文件
generate_singbox_config() {
    print_info "开始生成 sing-box 配置..."

    local nodes_file="$DATA_DIR/nodes.json"
    local users_file="$DATA_DIR/users.json"
    local node_users_file="$DATA_DIR/node_users.json"
    local config_file="$SINGBOX_CONFIG"

    # 检查必需文件
    if [[ ! -f "$nodes_file" ]]; then
        print_error "节点文件不存在: $nodes_file"
        return 1
    fi

    if [[ ! -f "$users_file" ]]; then
        print_warning "用户文件不存在，创建空文件"
        echo '{"users":[]}' > "$users_file"
    fi

    if [[ ! -f "$node_users_file" ]]; then
        print_warning "绑定关系文件不存在，创建空文件"
        echo '{"bindings":[]}' > "$node_users_file"
    fi

    # 生成inbounds配置
    local inbounds="[]"
    local node_count=$(jq '.nodes | length' "$nodes_file")

    if [[ $node_count -eq 0 ]]; then
        print_warning "没有配置节点"
    else
        print_info "处理 $node_count 个节点..."

        # 遍历所有节点
        while IFS= read -r node; do
            local port=$(echo "$node" | jq -r '.port')
            local protocol=$(echo "$node" | jq -r '.protocol')
            local transport=$(echo "$node" | jq -r '.transport // "tcp"')
            local security=$(echo "$node" | jq -r '.security // "none"')
            local extra=$(echo "$node" | jq -r '.extra // "{}"')

            print_info "  处理节点: $protocol/$port (security: $security)"

            # 获取该节点的用户列表
            local user_uuids=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[]" "$node_users_file" 2>/dev/null)

            # 生成users列表（sing-box格式）
            local users="[]"
            if [[ -n "$user_uuids" ]]; then
                local user_count=0
                while IFS= read -r uuid; do
                    [[ -z "$uuid" ]] && continue

                    # 从users.json获取用户信息
                    local user=$(jq -r ".users[] | select(.id == \"$uuid\" and .enabled == true)" "$users_file" 2>/dev/null)

                    if [[ -n "$user" && "$user" != "null" ]]; then
                        local username=$(echo "$user" | jq -r '.username // ""')
                        local password=$(echo "$user" | jq -r '.password // ""')

                        # 根据协议生成user配置（sing-box格式）
                        local user_item=""
                        case $protocol in
                            vless)
                                # VLESS使用uuid，可能需要flow
                                local flow=""
                                if [[ "$security" == "reality" ]]; then
                                    flow="xtls-rprx-vision"
                                fi

                                if [[ -n "$flow" ]]; then
                                    user_item=$(jq -n \
                                        --arg name "$username" \
                                        --arg uuid "$uuid" \
                                        --arg flow "$flow" \
                                        '{name: $name, uuid: $uuid, flow: $flow}')
                                else
                                    user_item=$(jq -n \
                                        --arg name "$username" \
                                        --arg uuid "$uuid" \
                                        '{name: $name, uuid: $uuid}')
                                fi
                                ;;
                            vmess)
                                user_item=$(jq -n \
                                    --arg name "$username" \
                                    --arg uuid "$uuid" \
                                    '{name: $name, uuid: $uuid}')
                                ;;
                            trojan)
                                user_item=$(jq -n \
                                    --arg name "$username" \
                                    --arg password "$password" \
                                    '{name: $name, password: $password}')
                                ;;
                            shadowsocks)
                                user_item=$(jq -n \
                                    --arg name "$username" \
                                    --arg password "$password" \
                                    '{name: $name, password: $password}')
                                ;;
                            hysteria2)
                                user_item=$(jq -n \
                                    --arg name "$username" \
                                    --arg password "$password" \
                                    '{name: $name, password: $password}')
                                ;;
                        esac

                        if [[ -n "$user_item" ]]; then
                            users=$(echo "$users" | jq ". += [$user_item]")
                            ((user_count++))
                        fi
                    fi
                done <<< "$user_uuids"

                print_info "    绑定用户: $user_count 个"
            else
                print_warning "    没有绑定用户，节点将无法使用"
            fi

            # 生成inbound配置（sing-box格式）
            local inbound=$(generate_singbox_inbound "$port" "$protocol" "$transport" "$security" "$extra" "$users")

            # 添加到inbounds列表
            inbounds=$(echo "$inbounds" | jq ". += [$inbound]")

        done < <(jq -c '.nodes[]' "$nodes_file" 2>/dev/null)
    fi

    # 生成完整配置（sing-box 1.11.0+ 兼容格式）
    local full_config=$(jq -n \
        --argjson inbounds "$inbounds" \
        '{
            log: {
                disabled: false,
                level: "info",
                timestamp: true
            },
            dns: {
                servers: [
                    {
                        tag: "dns-remote",
                        address: "https://1.1.1.1/dns-query",
                        detour: "direct-out"
                    },
                    {
                        tag: "dns-local",
                        address: "local",
                        detour: "direct-out"
                    }
                ],
                rules: [
                    {
                        outbound: "any",
                        server: "dns-local"
                    }
                ],
                final: "dns-remote"
            },
            inbounds: $inbounds,
            outbounds: [
                {
                    type: "direct",
                    tag: "direct-out"
                }
            ],
            route: {
                rules: [
                    {
                        protocol: "dns",
                        action: "route",
                        outbound: "direct-out"
                    }
                ],
                final: "direct-out",
                auto_detect_interface: true
            }
        }')

    # 写入配置文件
    echo "$full_config" | jq '.' > "$config_file"

    if [[ $? -eq 0 ]]; then
        print_success "配置文件生成成功: $config_file"
        return 0
    else
        print_error "配置文件生成失败"
        return 1
    fi
}

# 生成单个inbound配置（sing-box格式）
generate_singbox_inbound() {
    local port=$1
    local protocol=$2
    local transport=$3
    local security=$4
    local extra=$5
    local users=$6

    local inbound="{}"

    case $protocol in
        vless)
            # VLESS inbound（sing-box格式）
            inbound=$(jq -n \
                --arg type "vless" \
                --arg tag "vless-$port" \
                --arg listen "::" \
                --argjson listen_port "$port" \
                --argjson users "$users" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $listen_port,
                    users: $users
                }')

            # 添加TLS配置
            if [[ "$security" == "tls" || "$security" == "reality" ]]; then
                local tls_config=$(generate_singbox_tls_config "$security" "$extra")
                inbound=$(echo "$inbound" | jq --argjson tls "$tls_config" '. + {tls: $tls}')
            fi

            # 添加传输层配置
            if [[ "$transport" != "tcp" && "$transport" != "" ]]; then
                local transport_config=$(generate_singbox_transport_config "$transport" "$extra")
                inbound=$(echo "$inbound" | jq --argjson trans "$transport_config" '. + {transport: $trans}')
            fi
            ;;

        vmess)
            # VMess inbound
            inbound=$(jq -n \
                --arg type "vmess" \
                --arg tag "vmess-$port" \
                --arg listen "::" \
                --argjson listen_port "$port" \
                --argjson users "$users" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $listen_port,
                    users: $users
                }')

            # 添加TLS配置
            if [[ "$security" == "tls" ]]; then
                local tls_config=$(generate_singbox_tls_config "$security" "$extra")
                inbound=$(echo "$inbound" | jq --argjson tls "$tls_config" '. + {tls: $tls}')
            fi

            # 添加传输层配置
            if [[ "$transport" != "tcp" && "$transport" != "" ]]; then
                local transport_config=$(generate_singbox_transport_config "$transport" "$extra")
                inbound=$(echo "$inbound" | jq --argjson trans "$transport_config" '. + {transport: $trans}')
            fi
            ;;

        trojan)
            # Trojan inbound
            inbound=$(jq -n \
                --arg type "trojan" \
                --arg tag "trojan-$port" \
                --arg listen "::" \
                --argjson listen_port "$port" \
                --argjson users "$users" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $listen_port,
                    users: $users
                }')

            # Trojan 必须启用TLS
            local tls_config=$(generate_singbox_tls_config "tls" "$extra")
            inbound=$(echo "$inbound" | jq --argjson tls "$tls_config" '. + {tls: $tls}')

            # 添加传输层配置
            if [[ "$transport" != "tcp" && "$transport" != "" ]]; then
                local transport_config=$(generate_singbox_transport_config "$transport" "$extra")
                inbound=$(echo "$inbound" | jq --argjson trans "$transport_config" '. + {transport: $trans}')
            fi
            ;;

        shadowsocks)
            # Shadowsocks inbound
            local method=$(echo "$extra" | jq -r '.method // "aes-256-gcm"')

            inbound=$(jq -n \
                --arg type "shadowsocks" \
                --arg tag "shadowsocks-$port" \
                --arg listen "::" \
                --argjson listen_port "$port" \
                --arg method "$method" \
                --argjson users "$users" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $listen_port,
                    method: $method,
                    users: $users
                }')
            ;;

        hysteria2)
            # Hysteria2 inbound
            local up_mbps=$(echo "$extra" | jq -r '.up_mbps // 100')
            local down_mbps=$(echo "$extra" | jq -r '.down_mbps // 100')
            local obfs_password=$(echo "$extra" | jq -r '.obfs_password // ""')

            inbound=$(jq -n \
                --arg type "hysteria2" \
                --arg tag "hysteria2-$port" \
                --arg listen "::" \
                --argjson listen_port "$port" \
                --argjson up_mbps "$up_mbps" \
                --argjson down_mbps "$down_mbps" \
                --argjson users "$users" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $listen_port,
                    up_mbps: $up_mbps,
                    down_mbps: $down_mbps,
                    users: $users
                }')

            # 添加混淆配置
            if [[ -n "$obfs_password" && "$obfs_password" != "null" ]]; then
                local obfs_config=$(jq -n \
                    --arg password "$obfs_password" \
                    '{
                        type: "salamander",
                        salamander: {
                            password: $password
                        }
                    }')
                inbound=$(echo "$inbound" | jq --argjson obfs "$obfs_config" '. + {obfs: $obfs}')
            fi

            # Hysteria2 必须启用TLS
            local tls_config=$(generate_singbox_tls_config "tls" "$extra")
            inbound=$(echo "$inbound" | jq --argjson tls "$tls_config" '. + {tls: $tls}')

            # 添加伪装配置
            local masquerade=$(echo "$extra" | jq -r '.masquerade // "https://bing.com"')
            if [[ -n "$masquerade" && "$masquerade" != "null" ]]; then
                inbound=$(echo "$inbound" | jq --arg masq "$masquerade" '. + {masquerade: $masq}')
            fi
            ;;

        http)
            # HTTP inbound
            inbound=$(jq -n \
                --arg type "http" \
                --arg tag "http-$port" \
                --arg listen "::" \
                --argjson listen_port "$port" \
                --argjson users "$users" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $listen_port,
                    users: $users
                }')
            ;;

        socks)
            # SOCKS inbound
            inbound=$(jq -n \
                --arg type "socks" \
                --arg tag "socks-$port" \
                --arg listen "::" \
                --argjson listen_port "$port" \
                --argjson users "$users" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $listen_port,
                    users: $users
                }')
            ;;

        mixed)
            # Mixed (HTTP+SOCKS) inbound
            inbound=$(jq -n \
                --arg type "mixed" \
                --arg tag "mixed-$port" \
                --arg listen "::" \
                --argjson listen_port "$port" \
                --argjson users "$users" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $listen_port,
                    users: $users
                }')
            ;;

        *)
            print_error "不支持的协议: $protocol"
            inbound="{}"
            ;;
    esac

    echo "$inbound"
}

# 生成TLS配置（sing-box格式）
generate_singbox_tls_config() {
    local security=$1
    local extra=$2

    case $security in
        reality)
            # Reality配置
            local server=$(echo "$extra" | jq -r '.dest_server // "www.apple.com"')
            local server_port=$(echo "$extra" | jq -r '.dest_port // 443')
            local private_key=$(echo "$extra" | jq -r '.private_key')
            local short_ids=$(echo "$extra" | jq -r '.short_ids // ["","0123456789abcdef"]')

            local tls_config=$(jq -n \
                --argjson enabled "true" \
                --arg server "$server" \
                --argjson server_port "$server_port" \
                --arg private_key "$private_key" \
                --argjson short_ids "$short_ids" \
                '{
                    enabled: $enabled,
                    reality: {
                        enabled: true,
                        handshake: {
                            server: $server,
                            server_port: $server_port
                        },
                        private_key: $private_key,
                        short_id: $short_ids
                    }
                }')
            ;;

        tls)
            # 普通TLS配置
            local cert_path=$(echo "$extra" | jq -r '.tls_cert // ""')
            local key_path=$(echo "$extra" | jq -r '.tls_key // ""')

            if [[ -n "$cert_path" && -n "$key_path" ]]; then
                local tls_config=$(jq -n \
                    --argjson enabled "true" \
                    --arg cert "$cert_path" \
                    --arg key "$key_path" \
                    '{
                        enabled: $enabled,
                        certificate_path: $cert,
                        key_path: $key
                    }')
            else
                # 没有证书路径，返回基本TLS配置
                local tls_config='{"enabled": true}'
            fi
            ;;

        *)
            local tls_config='{"enabled": false}'
            ;;
    esac

    echo "$tls_config"
}

# 生成传输层配置（sing-box格式）
generate_singbox_transport_config() {
    local transport=$1
    local extra=$2

    local transport_config="{}"

    case $transport in
        ws)
            local path=$(echo "$extra" | jq -r '.ws_path // "/"')
            transport_config=$(jq -n \
                --arg type "ws" \
                --arg path "$path" \
                '{
                    type: $type,
                    path: $path
                }')
            ;;

        grpc)
            local service_name=$(echo "$extra" | jq -r '.grpc_service // "grpc"')
            transport_config=$(jq -n \
                --arg type "grpc" \
                --arg service_name "$service_name" \
                '{
                    type: $type,
                    service_name: $service_name
                }')
            ;;

        h2|http)
            transport_config='{"type": "http"}'
            ;;

        *)
            transport_config="{}"
            ;;
    esac

    echo "$transport_config"
}

# 验证配置文件
validate_singbox_config() {
    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box未安装"
        return 1
    fi

    print_info "验证配置文件..."
    if sing-box check -c "$SINGBOX_CONFIG" &>/dev/null; then
        print_success "配置文件验证通过"
        return 0
    else
        print_error "配置文件验证失败"
        sing-box check -c "$SINGBOX_CONFIG"
        return 1
    fi
}
