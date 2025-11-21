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

    # 读取Interface段的配置（兼容多种格式，保留密钥末尾的=填充）
    local private_key=$(grep -i "^[[:space:]]*PrivateKey" "$wgcf_profile" | cut -d= -f2- | tr -d ' \t\r\n')
    local address=$(grep -i "^[[:space:]]*Address" "$wgcf_profile" | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -1)

    # 读取Peer段的配置
    local public_key=$(grep -i "^[[:space:]]*PublicKey" "$wgcf_profile" | cut -d= -f2- | tr -d ' \t\r\n')
    local endpoint=$(grep -i "^[[:space:]]*Endpoint" "$wgcf_profile" | cut -d= -f2- | tr -d ' \t\r\n')

    # 验证必需字段
    if [[ -z "$private_key" || -z "$public_key" || -z "$endpoint" ]]; then
        print_error "WARP配置缺少必需字段" >&2
        echo "{}"
        return 1
    fi

    # 验证base64格式（WireGuard密钥应该是44字符）
    if [[ ${#private_key} -ne 44 ]] || [[ ! "$private_key" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        print_error "WARP私钥格式无效 (长度: ${#private_key}, 应为44字符)" >&2
        echo "{}"
        return 1
    fi

    if [[ ${#public_key} -ne 44 ]] || [[ ! "$public_key" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        print_error "WARP公钥格式无效 (长度: ${#public_key}, 应为44字符)" >&2
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
    local outbound_file="$DATA_DIR/outbounds.json"
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

    # 初始化出站规则文件
    if [[ ! -f "$outbound_file" ]]; then
        print_warning "出站规则文件不存在，创建空文件"
        echo '{"outbounds":[]}' > "$outbound_file"
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
            local warp_outbound=$(echo "$node" | jq -r '.warp_outbound // false')
            # 修复：不使用-r参数，保持extra为JSON格式
            local extra=$(echo "$node" | jq '.extra // {}')

            # 跳过端口为空的节点
            if [[ -z "$port" || "$port" == "null" ]]; then
                print_warning "  跳过端口为空的节点: $protocol (请删除此节点)"
                continue
            fi

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
            else
                print_warning "  端口 $port 没有绑定用户，节点将无法使用"
            fi

            # 生成inbound配置（sing-box格式）
            local inbound
            if ! inbound=$(generate_singbox_inbound "$port" "$protocol" "$transport" "$security" "$extra" "$users"); then
                print_error "生成入站配置失败: ${protocol}/${port}"
                return 1
            fi

            # 如果节点启用了WARP出站，添加标记字段（用于路由规则过滤）
            if [[ "$warp_outbound" == "true" ]]; then
                inbound=$(echo "$inbound" | jq '. + {warp_outbound: true}')
            fi

            # 添加到inbounds列表
            if ! inbounds=$(echo "$inbounds" | jq ". += [$inbound]"); then
                print_error "合并入站配置失败: ${protocol}/${port}"
                return 1
            fi

        done < <(jq -c '.nodes[]' "$nodes_file" 2>/dev/null)
    fi

    # ========== 处理出站规则 ==========
    print_info "处理出站规则..."

    # 提取所有节点使用的出站标签（去重）
    local used_outbound_tags=$(jq -r '[.nodes[] | select(.outbound_tag != null) | .outbound_tag] | unique | .[]' "$nodes_file" 2>/dev/null)

    # 根据使用的标签，从 outbounds.json 中提取对应的出站规则
    local custom_outbounds="[]"
    if [[ -n "$used_outbound_tags" ]]; then
        local tag_count=0
        while IFS= read -r tag; do
            [[ -z "$tag" ]] && continue

            # 从 outbounds.json 中查找该标签的配置
            local outbound_rule=$(jq --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" 2>/dev/null)

            if [[ -n "$outbound_rule" && "$outbound_rule" != "null" ]]; then
                # 添加到 custom_outbounds 数组
                custom_outbounds=$(echo "$custom_outbounds" | jq --argjson rule "$outbound_rule" '. += [$rule]')
                ((tag_count++))
                print_success "  → 加载出站规则: $tag"
            else
                print_warning "  ⚠ 节点引用的出站规则不存在: $tag"
            fi
        done <<< "$used_outbound_tags"

        if [[ $tag_count -gt 0 ]]; then
            print_success "成功加载 $tag_count 个自定义出站规则"
        fi
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
            print_error "WARP配置不存在或无效，无法生成WARP endpoint"
            print_warning "请先运行 WARP 绑定功能以生成配置文件"
            # 禁用 WARP，避免生成无效的 endpoint
            has_warp="false"
            warp_config="{}"
        fi
    fi

    # 生成完整配置（sing-box 1.11.0+ 兼容格式，使用新的endpoint格式）
    local full_config=$(jq -n \
        --argjson inbounds "$inbounds" \
        --argjson custom_outbounds "$custom_outbounds" \
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
                        path: "/dns-query",
                        domain_resolver: "dns-local"
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
            outbounds: (
                [
                    {
                        type: "direct",
                        tag: "direct-out"
                    },
                    {
                        type: "block",
                        tag: "block-out"
                    }
                ] + $custom_outbounds
            ),
            route: {
                default_domain_resolver: "dns-local",
                rules: (
                    [
                        {
                            protocol: "dns",
                            action: "route",
                            outbound: "direct-out"
                        }
                    ] + (
                        if $has_warp then
                            # 为启用 WARP 的 inbound 添加路由规则，直接路由到 endpoint
                            ($inbounds | map(select(.warp_outbound == true)) | map({
                                inbound: [.tag],
                                action: "route",
                                outbound: "warp-ep"
                            }))
                        else
                            []
                        end
                    )
                ),
                final: "direct-out",
                auto_detect_interface: true
            }
        }')

    # 写入配置文件（移除临时的 warp_outbound 标记字段）
    echo "$full_config" | jq 'del(.inbounds[].warp_outbound)' > "$config_file"

    if [[ $? -eq 0 ]]; then
        print_success "配置文件生成成功: $config_file"

        # 验证配置
        local inbound_count=$(jq '.inbounds | length' "$config_file" 2>/dev/null || echo "0")
        local outbound_count=$(jq '.outbounds | length' "$config_file" 2>/dev/null || echo "0")

        # 验证WARP配置（检查wireguard endpoint和路由规则）
        if [[ "$warp_check_count" -gt 0 ]]; then
            local warp_ep_exists=$(jq -r '.endpoints[]? | select(.tag == "warp-ep" and .type == "wireguard") | .tag' "$config_file" 2>/dev/null)
            if [[ -n "$warp_ep_exists" ]]; then
                local warp_route_count=$(jq -r '[.route.rules[] | select(.outbound == "warp-ep")] | length' "$config_file" 2>/dev/null)
                print_success "→ WARP配置成功 (wireguard endpoint + $warp_route_count 条路由规则)"
            else
                print_error "→ WARP配置失败！缺少 wireguard endpoint"
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
                }') || return 1

            # 添加TLS配置
            if [[ "$security" == "tls" || "$security" == "reality" ]]; then
                local tls_config
                tls_config=$(generate_singbox_tls_config "$security" "$extra")
                local tls_exit_code=$?

                if [[ $tls_exit_code -ne 0 ]]; then
                    echo "    [错误] TLS配置生成失败，退出码: $tls_exit_code" >&2
                    return 1
                fi


                local merged_inbound
                merged_inbound=$(echo "$inbound" | jq --argjson tls "$tls_config" '. + {tls: $tls}' 2>&1)
                local merge_exit_code=$?

                if [[ $merge_exit_code -ne 0 ]]; then
                    echo "    [错误] 合并TLS配置失败，退出码: $merge_exit_code" >&2
                    echo "    [错误] jq输出: $merged_inbound" >&2
                    return 1
                fi

                inbound="$merged_inbound"
            fi

            # 添加传输层配置
            if [[ "$transport" != "tcp" && "$transport" != "" ]]; then
                local transport_config
                if ! transport_config=$(generate_singbox_transport_config "$transport" "$extra"); then
                    return 1
                fi
                inbound=$(echo "$inbound" | jq --argjson trans "$transport_config" '. + {transport: $trans}') || return 1
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
                }') || return 1

            # 添加TLS配置
            if [[ "$security" == "tls" ]]; then
                local tls_config
                if ! tls_config=$(generate_singbox_tls_config "$security" "$extra"); then
                    return 1
                fi
                inbound=$(echo "$inbound" | jq --argjson tls "$tls_config" '. + {tls: $tls}') || return 1
            fi

            # 添加传输层配置
            if [[ "$transport" != "tcp" && "$transport" != "" ]]; then
                local transport_config
                if ! transport_config=$(generate_singbox_transport_config "$transport" "$extra"); then
                    return 1
                fi
                inbound=$(echo "$inbound" | jq --argjson trans "$transport_config" '. + {transport: $trans}') || return 1
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
                }') || return 1

            # Trojan 必须启用TLS
            local tls_config
            if ! tls_config=$(generate_singbox_tls_config "tls" "$extra"); then
                return 1
            fi
            inbound=$(echo "$inbound" | jq --argjson tls "$tls_config" '. + {tls: $tls}') || return 1

            # 添加传输层配置
            if [[ "$transport" != "tcp" && "$transport" != "" ]]; then
                local transport_config
                if ! transport_config=$(generate_singbox_transport_config "$transport" "$extra"); then
                    return 1
                fi
                inbound=$(echo "$inbound" | jq --argjson trans "$transport_config" '. + {transport: $trans}') || return 1
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
                }') || return 1
            ;;

        hysteria2)
            # Hysteria2 inbound
            local up_mbps=$(echo "$extra" | jq -r '.up_mbps // 0')
            local down_mbps=$(echo "$extra" | jq -r '.down_mbps // 0')
            local obfs_password=$(echo "$extra" | jq -r '.obfs_password // ""')
            local port_hopping=$(echo "$extra" | jq -r '.port_hopping // ""')


            # 构建基础配置
            # 端口跳跃通过iptables实现，配置中只使用单端口监听
            if [[ $up_mbps -eq 0 && $down_mbps -eq 0 ]]; then
                # 不限速配置（不包含up_mbps和down_mbps字段）
                inbound=$(jq -n \
                    --arg type "hysteria2" \
                    --arg tag "hysteria2-$port" \
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
            else
                # 有速率限制
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
            fi

            local jq_exit=$?
            if [[ $jq_exit -ne 0 ]]; then
                echo "    [错误] Hysteria2 inbound生成失败" >&2
                return 1
            fi

            # 添加混淆配置
            if [[ -n "$obfs_password" && "$obfs_password" != "null" ]]; then
                local obfs_config
                obfs_config=$(jq -n \
                    --arg password "$obfs_password" \
                    '{
                        type: "salamander",
                        password: $password
                    }')

                local obfs_exit=$?
                if [[ $obfs_exit -ne 0 ]]; then
                    echo "    [错误] Obfs配置生成失败" >&2
                    return 1
                fi


                local merged
                merged=$(echo "$inbound" | jq --argjson obfs "$obfs_config" '. + {obfs: $obfs}' 2>&1)
                local merge_exit=$?

                if [[ $merge_exit -ne 0 ]]; then
                    echo "    [错误] 合并Obfs配置失败: $merged" >&2
                    return 1
                fi

                inbound="$merged"
            fi

            # Hysteria2 必须启用TLS
            local tls_config
            tls_config=$(generate_singbox_tls_config "tls" "$extra")
            local tls_exit=$?

            if [[ $tls_exit -ne 0 ]]; then
                echo "    [错误] Hysteria2 TLS配置生成失败，退出码: $tls_exit" >&2
                return 1
            fi


            local merged
            merged=$(echo "$inbound" | jq --argjson tls "$tls_config" '. + {tls: $tls}' 2>&1)
            local merge_exit=$?

            if [[ $merge_exit -ne 0 ]]; then
                echo "    [错误] Hysteria2合并TLS配置失败，退出码: $merge_exit" >&2
                echo "    [错误] jq输出: $merged" >&2
                return 1
            fi

            inbound="$merged"

            # 添加伪装配置
            local masquerade=$(echo "$extra" | jq -r '.masquerade // "https://bing.com"')
            if [[ -n "$masquerade" && "$masquerade" != "null" ]]; then
                inbound=$(echo "$inbound" | jq --arg masq "$masquerade" '. + {masquerade: $masq}') || return 1
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
                }') || return 1
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
                }') || return 1
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
                }') || return 1
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
    local tls_config=""

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

            # 修复：使用正确的方式提取private_key
            local private_key=$(echo "$extra" | jq -r '.private_key // ""')

            # 调试输出（重定向到stderr避免污染返回值）

            local short_id_json
            # 修复：移除空字符串，避免sing-box启动失败
            if ! short_id_json=$(echo "$extra" | jq '.short_ids // ["0123456789abcdef"]'); then
                print_error "Reality 节点 short_id 解析失败"
                return 1
            fi

            # 验证私钥（必须存在且非空）
            if [[ -z "$private_key" || "$private_key" == "null" ]]; then
                print_error "Reality 节点私钥缺失或为空"
                print_error "端口: $port"
                print_error "节点数据: $(echo "$extra" | jq -c '.')"
                print_error "请删除此节点并重新创建"
                return 1
            fi

            # 验证私钥格式（base64或base64url格式）
            # base64url使用 - 和 _ 代替 + 和 /
            if ! echo "$private_key" | grep -qE '^[A-Za-z0-9+/_=-]{40,}$'; then
                print_error "Reality 节点私钥格式无效" >&2
                print_error "端口: $port" >&2
                print_error "私钥: $private_key" >&2
                print_error "请删除此节点并重新创建" >&2
                return 1
            fi

            # 提取server_names（用于SNI）
            local server_names_json=$(echo "$extra" | jq -r '.server_names // []')
            local server_name=""
            if [[ "$server_names_json" != "[]" && "$server_names_json" != "null" ]]; then
                server_name=$(echo "$server_names_json" | jq -r '.[0] // ""')
            fi
            # 如果没有server_names，使用handshake server作为SNI
            if [[ -z "$server_name" || "$server_name" == "null" ]]; then
                server_name="$server"
            fi


            tls_config=$(jq -n \
                --argjson enabled true \
                --arg server_name "$server_name" \
                --arg server "$server" \
                --argjson server_port "$server_port" \
                --arg private_key "$private_key" \
                --argjson short_id "$short_id_json" \
                '{
                    enabled: $enabled,
                    server_name: $server_name,
                    reality: {
                        enabled: true,
                        handshake: {
                            server: $server,
                            server_port: $server_port
                        },
                        private_key: $private_key,
                        short_id: $short_id
                    }
                }' 2>&1)

            local jq_exit_code=$?
            if [[ $jq_exit_code -ne 0 ]]; then
                echo "    [错误] jq命令失败，退出码: $jq_exit_code" >&2
                echo "    [错误] jq输出: $tls_config" >&2
                return 1
            fi

            ;;

        tls)
            # 普通TLS配置
            local cert_path=$(echo "$extra" | jq -r '.tls_cert // ""')
            local key_path=$(echo "$extra" | jq -r '.tls_key // ""')
            local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')


            if [[ -n "$cert_path" && -n "$key_path" ]]; then
                # 完整TLS配置（带证书）
                if [[ -n "$tls_domain" && "$tls_domain" != "null" ]]; then
                    tls_config=$(jq -n \
                        --argjson enabled true \
                        --arg server_name "$tls_domain" \
                        --arg cert "$cert_path" \
                        --arg key "$key_path" \
                        '{
                            enabled: $enabled,
                            server_name: $server_name,
                            certificate_path: $cert,
                            key_path: $key
                        }')
                else
                    tls_config=$(jq -n \
                        --argjson enabled true \
                        --arg cert "$cert_path" \
                        --arg key "$key_path" \
                        '{
                            enabled: $enabled,
                            certificate_path: $cert,
                            key_path: $key
                        }')
                fi

                local tls_exit=$?
                if [[ $tls_exit -ne 0 ]]; then
                    echo "    [错误] TLS配置生成失败" >&2
                    return 1
                fi
            else
                echo "    [警告] 缺少证书路径，使用基本TLS配置" >&2
                # 没有证书路径，返回基本TLS配置
                if [[ -n "$tls_domain" && "$tls_domain" != "null" ]]; then
                    tls_config=$(jq -n --arg server_name "$tls_domain" '{enabled: true, server_name: $server_name}')
                else
                    tls_config='{"enabled": true}'
                fi
            fi
            ;;

        *)
            tls_config='{"enabled": false}'
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
