#!/bin/bash

#================================================================
# 配置生成模块（新架构）
# 功能：根据nodes.json、users.json、node_users.json生成config.json
# 架构：节点用户分离架构
#================================================================

# 生成sing-box完整配置文件
generate_singbox_config() {
    print_info "开始生成sing-box配置..."

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
            local transport=$(echo "$node" | jq -r '.transport')
            local security=$(echo "$node" | jq -r '.security')
            local extra=$(echo "$node" | jq -r '.extra')

            print_info "  处理节点: $protocol/$port (security: $security)"

            # 获取该节点的用户列表
            local user_uuids=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[]" "$node_users_file" 2>/dev/null)

            # 生成clients列表
            local clients="[]"
            if [[ -n "$user_uuids" ]]; then
                local user_count=0
                while IFS= read -r uuid; do
                    [[ -z "$uuid" ]] && continue

                    # 从users.json获取用户信息
                    local user=$(jq -r ".users[] | select(.id == \"$uuid\" and .enabled == true)" "$users_file" 2>/dev/null)

                    if [[ -n "$user" && "$user" != "null" ]]; then
                        local email=$(echo "$user" | jq -r '.email // ""')
                        local level=$(echo "$user" | jq -r '.level // 0')
                        local password=$(echo "$user" | jq -r '.password // ""')

                        # 如果email为空或null,使用UUID作为email(确保Stats API能工作)
                        if [[ -z "$email" || "$email" == "null" ]]; then
                            email="${uuid}@local"
                            print_warning "    用户 $uuid 缺少email字段,使用默认: $email"
                        fi

                        # 根据协议生成client配置
                        local client=""
                        case $protocol in
                            vless|vmess)
                                local flow=""
                                if [[ "$security" == "reality" ]]; then
                                    flow=$(echo "$extra" | jq -r '.flow // "xtls-rprx-vision"')
                                fi

                                if [[ -n "$flow" ]]; then
                                    client=$(jq -n \
                                        --arg id "$uuid" \
                                        --arg email "$email" \
                                        --argjson level "$level" \
                                        --arg flow "$flow" \
                                        '{id: $id, email: $email, level: $level, flow: $flow}')
                                else
                                    client=$(jq -n \
                                        --arg id "$uuid" \
                                        --arg email "$email" \
                                        --argjson level "$level" \
                                        '{id: $id, email: $email, level: $level}')
                                fi
                                ;;
                            trojan)
                                # Trojan使用password（从用户表读取）
                                client=$(jq -n \
                                    --arg password "$password" \
                                    --arg email "$email" \
                                    --argjson level "$level" \
                                    '{password: $password, email: $email, level: $level}')
                                ;;
                            shadowsocks)
                                # Shadowsocks也使用password
                                client=$(jq -n \
                                    --arg password "$password" \
                                    --arg email "$email" \
                                    --argjson level "$level" \
                                    '{password: $password, email: $email, level: $level}')
                                ;;
                            http|socks)
                                # HTTP/SOCKS使用username和password
                                local username=$(echo "$user" | jq -r '.username')
                                client=$(jq -n \
                                    --arg user "$username" \
                                    --arg pass "$password" \
                                    --arg email "$email" \
                                    --argjson level "$level" \
                                    '{user: $user, pass: $pass, email: $email, level: $level}')
                                ;;
                        esac

                        clients=$(echo "$clients" | jq ". += [$client]")
                        ((user_count++))
                    fi
                done <<< "$user_uuids"

                print_info "    绑定用户: $user_count 个"
            else
                print_warning "    没有绑定用户，节点将无法使用"
            fi

            # 生成inbound配置
            local inbound=$(generate_inbound_config "$port" "$protocol" "$transport" "$security" "$extra" "$clients")

            # 添加到inbounds列表
            inbounds=$(echo "$inbounds" | jq ". += [$inbound]")

        done < <(jq -c '.nodes[]' "$nodes_file" 2>/dev/null)
    fi

    # 读取用户配置的出站规则
    local outbounds="[]"
    local outbounds_file="$DATA_DIR/outbounds.json"
    if [[ -f "$outbounds_file" ]]; then
        local user_outbounds=$(jq '.outbounds // []' "$outbounds_file" 2>/dev/null)
        if [[ -n "$user_outbounds" && "$user_outbounds" != "null" ]]; then
            outbounds="$user_outbounds"
        fi
    fi

    # 添加默认出站
    outbounds=$(echo "$outbounds" | jq '. += [
        {
            protocol: "freedom",
            tag: "direct"
        },
        {
            protocol: "blackhole",
            tag: "block"
        }
    ]')

    # 注意: API outbound 由 sing-box 自动创建，不需要手动添加
    # 参考文档: "当 api 配置开启时，sing-box 会自建一个和 tag 同名的出站代理"

    # 生成路由规则
    local routing_rules="[]"

    # 为每个节点生成路由规则
    while IFS= read -r node; do
        local port=$(echo "$node" | jq -r '.port')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local outbound_tag=$(echo "$node" | jq -r '.outbound_tag // empty')
        local inbound_tag="${protocol}-${port}"

        # 如果节点配置了出站规则,使用指定的出站;否则使用直连
        if [[ -n "$outbound_tag" && "$outbound_tag" != "null" ]]; then
            # 有出站规则的节点使用指定的代理
            local rule=$(jq -n \
                --arg inbound_tag "$inbound_tag" \
                --arg outbound_tag "$outbound_tag" \
                '{
                    type: "field",
                    inboundTag: [$inbound_tag],
                    outboundTag: $outbound_tag
                }')
        else
            # 没有出站规则的节点使用直连
            local rule=$(jq -n \
                --arg inbound_tag "$inbound_tag" \
                '{
                    type: "field",
                    inboundTag: [$inbound_tag],
                    outboundTag: "direct"
                }')
        fi
        routing_rules=$(echo "$routing_rules" | jq ". += [$rule]")
    done < <(jq -c '.nodes[]' "$nodes_file" 2>/dev/null)

    # 添加默认路由规则（阻止私有IP,必须放在最后）
    routing_rules=$(echo "$routing_rules" | jq '. += [{
        type: "field",
        ip: ["geoip:private"],
        outboundTag: "block"
    }]')

    # 添加 API inbound
    local api_inbound=$(jq -n '{
        tag: "api",
        listen: "127.0.0.1",
        port: 10085,
        protocol: "dokodemo-door",
        settings: {
            address: "127.0.0.1"
        }
    }')
    inbounds=$(echo "$inbounds" | jq ". += [$api_inbound]")

    # 添加 API 路由规则 (将 API inbound 连接到 API outbound)
    local api_routing_rule=$(jq -n '{
        type: "field",
        inboundTag: ["api"],
        outboundTag: "api"
    }')
    routing_rules=$(echo "$routing_rules" | jq ". = [$api_routing_rule] + .")

    # 生成完整配置
    local full_config=$(jq -n \
        --argjson inbounds "$inbounds" \
        --argjson outbounds "$outbounds" \
        --argjson routing_rules "$routing_rules" \
        '{
            log: {
                loglevel: "warning"
            },
            inbounds: $inbounds,
            outbounds: $outbounds,
            routing: {
                rules: $routing_rules
            },
            stats: {},
            policy: {
                levels: {
                    "0": {
                        statsUserUplink: true,
                        statsUserDownlink: true
                    }
                },
                system: {
                    statsInboundUplink: true,
                    statsInboundDownlink: true,
                    statsOutboundUplink: true,
                    statsOutboundDownlink: true
                }
            },
            api: {
                tag: "api",
                services: ["StatsService", "HandlerService"]
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

# 生成单个inbound配置
generate_inbound_config() {
    local port=$1
    local protocol=$2
    local transport=$3
    local security=$4
    local extra=$5
    local clients=$6

    local stream_settings=$(generate_stream_settings "$transport" "$security" "$extra")

    case $protocol in
        vless)
            local inbound=$(jq -n \
                --argjson port "$port" \
                --arg tag "vless-$port" \
                --argjson clients "$clients" \
                --argjson stream_settings "$stream_settings" \
                '{
                    port: $port,
                    protocol: "vless",
                    tag: $tag,
                    settings: {
                        clients: $clients,
                        decryption: "none"
                    },
                    streamSettings: $stream_settings,
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls", "quic"]
                    }
                }')
            ;;

        vmess)
            # VMess配置: alterId已废弃,不再添加
            local inbound=$(jq -n \
                --argjson port "$port" \
                --arg tag "vmess-$port" \
                --argjson clients "$clients" \
                --argjson stream_settings "$stream_settings" \
                '{
                    port: $port,
                    protocol: "vmess",
                    tag: $tag,
                    settings: {
                        clients: $clients
                    },
                    streamSettings: $stream_settings,
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls", "quic"]
                    }
                }')
            ;;

        trojan)
            local inbound=$(jq -n \
                --argjson port "$port" \
                --arg tag "trojan-$port" \
                --argjson clients "$clients" \
                --argjson stream_settings "$stream_settings" \
                '{
                    port: $port,
                    protocol: "trojan",
                    tag: $tag,
                    settings: {
                        clients: $clients
                    },
                    streamSettings: $stream_settings,
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls", "quic"]
                    }
                }')
            ;;

        shadowsocks)
            # Shadowsocks配置: 需要method和password作为默认值
            local method=$(echo "$extra" | jq -r '.method // "aes-256-gcm"')

            # 如果有clients,使用多用户模式;否则使用单用户模式
            local has_clients=$(echo "$clients" | jq 'length > 0')

            if [[ "$has_clients" == "true" ]]; then
                # 多用户模式: 使用clients数组
                local inbound=$(jq -n \
                    --argjson port "$port" \
                    --arg tag "shadowsocks-$port" \
                    --arg method "$method" \
                    --argjson clients "$clients" \
                    --argjson stream_settings "$stream_settings" \
                    '{
                        port: $port,
                        protocol: "shadowsocks",
                        tag: $tag,
                        settings: {
                            network: "tcp,udp",
                            method: $method,
                            clients: $clients
                        },
                        streamSettings: $stream_settings
                    }')
            else
                # 单用户模式: 需要password字段(从第一个client提取)
                local password=$(echo "$clients" | jq -r '.[0].password // "default-password"')
                local inbound=$(jq -n \
                    --argjson port "$port" \
                    --arg tag "shadowsocks-$port" \
                    --arg method "$method" \
                    --arg password "$password" \
                    --argjson stream_settings "$stream_settings" \
                    '{
                        port: $port,
                        protocol: "shadowsocks",
                        tag: $tag,
                        settings: {
                            network: "tcp,udp",
                            method: $method,
                            password: $password
                        },
                        streamSettings: $stream_settings
                    }')
            fi
            ;;

        http)
            local inbound=$(jq -n \
                --argjson port "$port" \
                --arg tag "http-$port" \
                --argjson clients "$clients" \
                '{
                    port: $port,
                    protocol: "http",
                    tag: $tag,
                    settings: {
                        accounts: $clients,
                        allowTransparent: false
                    }
                }')
            ;;

        socks)
            local inbound=$(jq -n \
                --argjson port "$port" \
                --arg tag "socks-$port" \
                --argjson clients "$clients" \
                '{
                    port: $port,
                    protocol: "socks",
                    tag: $tag,
                    settings: {
                        auth: "password",
                        accounts: $clients,
                        udp: true
                    }
                }')
            ;;
    esac

    echo "$inbound"
}

# 生成streamSettings配置
generate_stream_settings() {
    local transport=$1
    local security=$2
    local extra=$3

    local stream_settings="{}"

    # 设置network
    stream_settings=$(echo "$stream_settings" | jq --arg network "$transport" '. + {network: $network}')

    # 设置security
    case $security in
        reality)
            local dest=$(echo "$extra" | jq -r '.dest')
            local server_names=$(echo "$extra" | jq -r '.server_names')
            local private_key=$(echo "$extra" | jq -r '.private_key')
            local short_ids=$(echo "$extra" | jq -r '.short_ids')

            stream_settings=$(echo "$stream_settings" | jq \
                --arg security "reality" \
                --arg dest "$dest" \
                --argjson server_names "$server_names" \
                --arg private_key "$private_key" \
                --argjson short_ids "$short_ids" \
                '. + {
                    security: $security,
                    realitySettings: {
                        show: false,
                        dest: $dest,
                        xver: 0,
                        serverNames: $server_names,
                        privateKey: $private_key,
                        shortIds: $short_ids
                    }
                }')
            ;;

        tls)
            local cert_file=$(echo "$extra" | jq -r '.cert_file // "/usr/local/sing-box/certs/cert.pem"')
            local key_file=$(echo "$extra" | jq -r '.key_file // "/usr/local/sing-box/certs/key.pem"')

            stream_settings=$(echo "$stream_settings" | jq \
                --arg security "tls" \
                --arg cert "$cert_file" \
                --arg key "$key_file" \
                '. + {
                    security: $security,
                    tlsSettings: {
                        certificates: [{
                            certificateFile: $cert,
                            keyFile: $key
                        }]
                    }
                }')
            ;;

        none|*)
            stream_settings=$(echo "$stream_settings" | jq '. + {security: "none"}')
            ;;
    esac

    # 设置传输层配置
    case $transport in
        ws)
            local path=$(echo "$extra" | jq -r '.path // "/"')
            stream_settings=$(echo "$stream_settings" | jq \
                --arg path "$path" \
                '. + {
                    wsSettings: {
                        path: $path
                    }
                }')
            ;;

        grpc)
            local service_name=$(echo "$extra" | jq -r '.service_name // "grpc"')
            stream_settings=$(echo "$stream_settings" | jq \
                --arg service_name "$service_name" \
                '. + {
                    grpcSettings: {
                        serviceName: $service_name
                    }
                }')
            ;;
    esac

    echo "$stream_settings"
}

# 验证配置文件
validate_singbox_config() {
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        print_error "sing-box未安装"
        return 1
    fi

    print_info "验证配置文件..."
    if "$SINGBOX_BIN" run -test -config "$SINGBOX_CONFIG" &>/dev/null; then
        print_success "配置文件验证通过"
        return 0
    else
        print_error "配置文件验证失败"
        "$SINGBOX_BIN" run -test -config "$SINGBOX_CONFIG"
        return 1
    fi
}
