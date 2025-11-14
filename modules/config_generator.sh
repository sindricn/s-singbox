#!/bin/bash

#================================================================
# sing-box 配置生成模块（修复版）
# 功能：根据nodes.json、users.json、node_users.json生成正确的sing-box config.json
# 重要：使用sing-box原生格式，不是Xray格式
#================================================================

# 从WARP配置文件读取密钥信息
get_warp_config() {
    local wgcf_profile="/etc/wireguard/wgcf-profile.conf"

    if [[ ! -f "$wgcf_profile" ]]; then
        print_warning "WARP配置文件不存在: $wgcf_profile" >&2
        echo "{}"
        return 1
    fi

    # 读取Interface段的配置
    local private_key=$(grep "^PrivateKey" "$wgcf_profile" | cut -d= -f2 | tr -d ' \t\r\n')
    local address=$(grep "^Address" "$wgcf_profile" | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -1)

    # 读取Peer段的配置
    local public_key=$(grep "^PublicKey" "$wgcf_profile" | cut -d= -f2 | tr -d ' \t\r\n')
    local endpoint=$(grep "^Endpoint" "$wgcf_profile" | cut -d= -f2 | tr -d ' \t\r\n')

    # WARP配置读取（静默）

    # 验证必需字段
    if [[ -z "$private_key" || -z "$public_key" || -z "$endpoint" ]]; then
        print_error "WARP配置缺少必需字段" >&2
        echo "{}"
        return 1
    fi

    # 验证base64格式（WireGuard密钥应该是44字符的base64）
    if [[ ${#private_key} -ne 44 ]] || [[ ! "$private_key" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        print_error "WARP私钥格式无效 (长度: ${#private_key}, 应为44)" >&2
        echo "{}"
        return 1
    fi

    if [[ ${#public_key} -ne 44 ]] || [[ ! "$public_key" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        print_error "WARP公钥格式无效 (长度: ${#public_key}, 应为44)" >&2
        echo "{}"
        return 1
    fi

    # 分离服务器地址和端口
    local server=$(echo "$endpoint" | cut -d: -f1)
    local server_port=$(echo "$endpoint" | cut -d: -f2)
    server_port=${server_port:-2408}

    # 输出JSON格式
    jq -n \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg server "$server" \
        --argjson server_port "$server_port" \
        --arg address "$address" \
        '{
            private_key: $private_key,
            peer_public_key: $public_key,
            server: $server,
            server_port: $server_port,
            local_address: [$address]
        }'
}

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

    # 提前检查WARP节点（避免悖论：只有配置成功才能看到WARP信息）
    local warp_check_count=$(jq -r '[.nodes[] | select(.warp_outbound == true)] | length' "$nodes_file" 2>/dev/null)
    if [[ "$warp_check_count" -gt 0 ]]; then
        print_success "→ 检测到 $warp_check_count 个节点已启用WARP出站"
    fi

    # 生成inbounds配置
    local inbounds="[]"
    local node_count=$(jq '.nodes | length' "$nodes_file")

    if [[ $node_count -eq 0 ]]; then
        print_warning "没有配置节点"
    else
        # 遍历所有节点
        while IFS= read -r node; do
            local port=$(echo "$node" | jq -r '.port')
            local protocol=$(echo "$node" | jq -r '.protocol')
            local transport=$(echo "$node" | jq -r '.transport // "tcp"')
            local security=$(echo "$node" | jq -r '.security // "none"')
            local extra=$(echo "$node" | jq -r '.extra // "{}"')
            local warp_outbound=$(echo "$node" | jq -r '.warp_outbound // false')

            # 跳过端口为空的节点
            if [[ -z "$port" || "$port" == "null" ]]; then
                print_warning "  跳过端口为空的节点: $protocol (请删除此节点)"
                continue
            fi

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
            else
                print_warning "  端口 $port 没有绑定用户，节点将无法使用"
            fi

            # 生成inbound配置（sing-box格式）
            local inbound=$(generate_singbox_inbound "$port" "$protocol" "$transport" "$security" "$extra" "$users")

            # 如果节点启用了WARP出站，添加endpoint标签（新格式）
            if [[ "$warp_outbound" == "true" ]]; then
                inbound=$(echo "$inbound" | jq '. + {detour: "warp-ep"}')
            fi

            # 添加到inbounds列表
            inbounds=$(echo "$inbounds" | jq ". += [$inbound]")

        done < <(jq -c '.nodes[]' "$nodes_file" 2>/dev/null)
    fi

    # 检查是否有节点启用WARP（用于配置生成）
    local warp_enabled_count=$(jq -r '[.nodes[] | select(.warp_outbound == true)] | length' "$nodes_file" 2>/dev/null)

    local has_warp="false"
    if [[ "$warp_enabled_count" -gt 0 ]]; then
        has_warp="true"
    fi

    # 获取WARP配置
    local warp_config="{}"
    if [[ "$has_warp" == "true" ]]; then
        warp_config=$(get_warp_config)
        if [[ "$warp_config" == "{}" ]]; then
            print_warning "WARP配置不存在或无效，将使用默认配置"
        fi
    fi

    # 生成完整配置（sing-box 1.11.0+ 兼容格式，使用新的endpoint格式）
    local full_config=$(jq -n \
        --argjson inbounds "$inbounds" \
        --argjson warp_cfg "$warp_config" \
        --argjson has_warp "$has_warp" \
        '{
            log: {
                disabled: false,
                level: "info",
                timestamp: true
            },
            dns: {
                servers: [
                    {
                        type: "https",
                        tag: "dns-remote",
                        server: "1.1.1.1",
                        server_port: 443,
                        path: "/dns-query"
                    },
                    {
                        type: "local",
                        tag: "dns-local"
                    }
                ],
                rules: [],
                final: "dns-remote"
            },
            inbounds: $inbounds,
            endpoints: (
                if $has_warp then
                    [{
                        type: "wireguard",
                        tag: "warp-ep",
                        name: "wgcf",
                        mtu: 1280,
                        address: ($warp_cfg.local_address // ["172.16.0.2/32"]),
                        private_key: ($warp_cfg.private_key // ""),
                        peers: [
                            {
                                address: ($warp_cfg.server // "engage.cloudflareclient.com"),
                                port: ($warp_cfg.server_port // 2408),
                                public_key: ($warp_cfg.peer_public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="),
                                allowed_ips: ["0.0.0.0/0", "::/0"],
                                reserved: [0, 0, 0]
                            }
                        ]
                    }]
                else
                    []
                end
            ),
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

        # 验证配置
        local inbound_count=$(jq '.inbounds | length' "$config_file")
        local outbound_count=$(jq '.outbounds | length' "$config_file")

        # 验证WARP配置（新格式：检查endpoints）
        if [[ "$warp_check_count" -gt 0 ]]; then
            local warp_ep_exists=$(jq -r '.endpoints[]? | select(.tag == "warp-ep") | .tag' "$config_file" 2>/dev/null)
            if [[ -n "$warp_ep_exists" ]]; then
                local warp_detour_count=$(jq -r '[.inbounds[] | select(.detour == "warp-ep")] | length' "$config_file")
                print_success "→ WARP endpoint配置成功 (配置了 $warp_detour_count 个节点)"
            else
                print_error "→ WARP endpoint配置失败！已启用WARP的节点未添加到配置文件"
                print_warning "   请检查WARP配置文件: /etc/wireguard/wgcf-profile.conf"
            fi
        fi

        print_info "配置统计: 入站=$inbound_count, 出站=$outbound_count"

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
            # 兼容两种格式：新格式 (dest_server/dest_port) 和旧格式 (dest)
            local server=$(echo "$extra" | jq -r '.dest_server // empty')
            local server_port=$(echo "$extra" | jq -r '.dest_port // empty')

            # 如果新格式不存在，从旧格式 dest 中解析
            if [[ -z "$server" || "$server" == "null" ]]; then
                local dest=$(echo "$extra" | jq -r '.dest // "www.apple.com:443"')
                server=$(echo "$dest" | cut -d':' -f1)
                server_port=$(echo "$dest" | cut -d':' -f2)
            fi

            # 设置默认值
            server=${server:-"www.apple.com"}
            server_port=${server_port:-443}

            local private_key=$(echo "$extra" | jq -r '.private_key // empty')
            # short_id 必须是数组格式，不能用 -r
            local short_ids=$(echo "$extra" | jq '.short_ids // ["","0123456789abcdef"]')

            # 验证私钥
            if [[ -z "$private_key" || "$private_key" == "null" ]]; then
                print_error "Reality 节点私钥缺失 (端口: $port)"
                print_error "节点数据: $(echo "$extra" | jq -c '.')"
                print_error "请删除此节点并重新创建"
                return 1
            fi

            local tls_config=$(jq -n \
                --argjson enabled "true" \
                --arg server "$server" \
                --argjson server_port "$server_port" \
                --arg private_key "$private_key" \
                --argjson short_id "$short_ids" \
                '{
                    enabled: $enabled,
                    reality: {
                        enabled: true,
                        handshake: {
                            server: $server,
                            server_port: $server_port
                        },
                        private_key: $private_key,
                        short_id: $short_id
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
