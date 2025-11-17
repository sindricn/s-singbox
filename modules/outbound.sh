#!/bin/bash

#================================================================
# 出站规则管理模块 - 重构版
# 功能：管理常用出站协议（HTTP、SOCKS）、代理链
# 移除：Freedom、Blackhole、默认出站等无用功能
# 优化：出站规则统一修改、绑定到节点的逻辑
#================================================================

# 避免重复加载导致只读变量冲突
if [[ -n "${OUTBOUND_MODULE_LOADED:-}" ]]; then
    return 0
fi
OUTBOUND_MODULE_LOADED=1

# 全局变量
OUTBOUND_FILE="${DATA_DIR}/outbounds.json"

# 颜色定义（继承主脚本）
readonly OUTBOUND_CYAN="${CYAN:-\033[0;36m}"
readonly OUTBOUND_GREEN="${GREEN:-\033[0;32m}"
readonly OUTBOUND_YELLOW="${YELLOW:-\033[1;33m}"
readonly OUTBOUND_RED="${RED:-\033[0;31m}"
readonly OUTBOUND_NC="${NC:-\033[0m}"

# 初始化出站规则文件
init_outbound_file() {
    if [[ ! -f "$OUTBOUND_FILE" ]]; then
        echo '{"outbounds":[]}' > "$OUTBOUND_FILE"
    fi
}

#================================================================
# 出站规则状态显示
#================================================================
show_outbound_status() {
    init_outbound_file

    # 1. 规则库中的出站规则数量
    local library_count=$(jq '.outbounds | length' "$OUTBOUND_FILE" 2>/dev/null || echo "0")

    # 2. 已应用规则数量（nodes.json中绑定了outbound_tag的节点）
    local applied_count=0
    if [[ -f "$NODES_FILE" ]]; then
        applied_count=$(jq '[.nodes[] | select(.outbound_tag != null)] | length' "$NODES_FILE" 2>/dev/null || echo "0")
    fi

    # 3. 配置文件中的实际出站数量
    local config_count=0
    if [[ -f "$SINGBOX_CONFIG" ]]; then
        config_count=$(jq '.outbounds | length' "$SINGBOX_CONFIG" 2>/dev/null || echo "0")
    fi

    echo -e "${OUTBOUND_CYAN}═══════════════════════════════════════${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}出站规则状态${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}═══════════════════════════════════════${OUTBOUND_NC}"
    echo -e "  ${OUTBOUND_YELLOW}规则库数量:${OUTBOUND_NC} $library_count"
    echo -e "  ${OUTBOUND_YELLOW}已应用节点:${OUTBOUND_NC} $applied_count"
    echo -e "  ${OUTBOUND_YELLOW}配置文件数量:${OUTBOUND_NC} $config_count"
    echo -e "${OUTBOUND_CYAN}═══════════════════════════════════════${OUTBOUND_NC}"
    echo ""
}

#================================================================
# 出站规则一致性检测
#================================================================
check_outbound_consistency() {
    init_outbound_file

    # 检查配置文件是否存在
    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        print_warning "配置文件不存在，跳过一致性检查"
        return 0
    fi

    echo -e "${OUTBOUND_CYAN}正在检测出站规则一致性...${OUTBOUND_NC}"
    echo ""

    # 获取规则库中的所有tag
    local library_tags=$(jq -r '.outbounds[].tag' "$OUTBOUND_FILE" 2>/dev/null | sort)
    local library_count=$(echo "$library_tags" | grep -v '^$' | wc -l)


    # 获取配置文件中的所有出站规则tag
    local config_tags=$(jq -r '[.outbounds[].tag] | .[]' "$SINGBOX_CONFIG" 2>/dev/null | sort)
    local config_count=$(echo "$config_tags" | grep -v '^$' | wc -l)

    # 显示检测信息
    echo -e "${OUTBOUND_YELLOW}检测信息：${OUTBOUND_NC}"
    echo -e "  规则库中的出站规则: $library_count 个"
    if [[ $library_count -gt 0 ]]; then
        echo "$library_tags" | while read -r tag; do
            [[ -n "$tag" ]] && echo -e "    - $tag"
        done
    fi
    echo ""
    echo -e "  配置文件中的出站规则: $config_count 个"
    if [[ $config_count -gt 0 ]]; then
        echo "$config_tags" | while read -r tag; do
            [[ -n "$tag" ]] && echo -e "    - $tag"
        done
    fi
    echo ""

    # 找出配置文件中有但规则库中没有的（异常规则）
    local orphan_tags=""
    while IFS= read -r tag; do
        if [[ -n "$tag" ]] && ! echo "$library_tags" | grep -q "^${tag}$"; then
            orphan_tags+="$tag"$'\n'
        fi
    done <<< "$config_tags"

    # 如果没有异常规则，检查通过
    if [[ -z "$orphan_tags" ]]; then
        print_success "出站规则一致性检查通过"
        return 0
    fi

    # 发现异常规则，需要处理
    print_warning "发现配置文件中存在规则库没有的出站规则："
    echo ""

    local index=1
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue

        # 获取该出站规则的详细信息
        local protocol=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | .protocol' "$SINGBOX_CONFIG" 2>/dev/null)
        local address=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | .settings.servers[0].address // .settings.vnext[0].address // "N/A"' "$SINGBOX_CONFIG" 2>/dev/null)

        echo -e "${OUTBOUND_YELLOW}[$index]${OUTBOUND_NC} 标签: $tag, 协议: $protocol, 地址: $address"
        ((index++))
    done <<< "$orphan_tags"

    echo ""
    echo -e "${OUTBOUND_CYAN}处理选项：${OUTBOUND_NC}"
    echo -e "  ${OUTBOUND_GREEN}1.${OUTBOUND_NC} 同步到规则库（推荐）"
    echo -e "  ${OUTBOUND_GREEN}2.${OUTBOUND_NC} 从配置文件删除"
    echo -e "  ${OUTBOUND_GREEN}3.${OUTBOUND_NC} 忽略（不推荐，可能导致配置不一致）"
    echo ""
    read -p "请选择处理方式 [1-3]: " choice

    case $choice in
        1)
            # 同步到规则库
            sync_orphan_outbounds_to_library "$orphan_tags"
            ;;
        2)
            # 从配置文件删除
            remove_orphan_outbounds_from_config "$orphan_tags"
            ;;
        3)
            print_warning "已忽略异常规则，建议尽快处理"
            return 0
            ;;
        *)
            print_error "无效选择，已取消操作"
            return 1
            ;;
    esac
}

#================================================================
# 同步孤立的出站规则到规则库
#================================================================
sync_orphan_outbounds_to_library() {
    local orphan_tags=$1
    local sync_count=0

    echo ""
    print_info "正在同步出站规则到规则库..."

    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue

        # 从配置文件中提取完整的出站规则
        local outbound=$(jq --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" 2>/dev/null)

        if [[ -n "$outbound" && "$outbound" != "null" ]]; then
            # 添加到规则库
            jq --argjson outbound "$outbound" '.outbounds += [$outbound]' "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
            mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"
            ((sync_count++))
            print_success "已同步: $tag"
        fi
    done <<< "$orphan_tags"

    echo ""
    print_success "成功同步 $sync_count 个出站规则到规则库"
    return 0
}

#================================================================
# 从配置文件删除孤立的出站规则
#================================================================
remove_orphan_outbounds_from_config() {
    local orphan_tags=$1

    echo ""
    read -p "确认从配置文件删除这些规则? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消删除"
        return 0
    fi

    print_info "正在从配置文件删除出站规则..."

    local remove_count=0
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue

        # 从配置文件删除
        jq --arg tag "$tag" '.outbounds = [.outbounds[] | select(.tag != $tag)]' "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp"
        mv "${SINGBOX_CONFIG}.tmp" "$SINGBOX_CONFIG"
        ((remove_count++))
        print_success "已删除: $tag"
    done <<< "$orphan_tags"

    echo ""
    print_success "成功删除 $remove_count 个出站规则"

    # 重启sing-box服务
    print_info "正在重启sing-box服务..."
    restart_sing-box

    return 0
}

#================================================================
# 出站协议类型枚举
#================================================================
get_outbound_type_name() {
    case $1 in
        vless) echo "VLESS 代理" ;;
        vmess) echo "VMess 代理" ;;
        trojan) echo "Trojan 代理" ;;
        shadowsocks) echo "Shadowsocks 代理" ;;
        socks) echo "Socks 代理" ;;
        http) echo "HTTP 代理" ;;
        wireguard) echo "WireGuard 代理" ;;
        *) echo "未知类型" ;;
    esac
}

#================================================================
# 添加 HTTP 出站
#================================================================
add_http_outbound() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      添加 HTTP 出站                  ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    echo -e "${OUTBOUND_YELLOW}HTTP 出站说明：${OUTBOUND_NC}"
    echo -e "  • 使用 HTTP/HTTPS 代理协议"
    echo -e "  • 适用于需要 HTTP 代理的场景"
    echo -e "  • 支持用户名密码认证"
    echo ""

    # 输入标签
    read -p "请输入出站标签 (例如: http-proxy): " tag
    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    if jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUND_FILE" >/dev/null 2>&1; then
        print_error "标签 '$tag' 已存在"
        return 1
    fi

    # 服务器地址和端口
    echo ""
    read -p "请输入服务器地址: " server
    if [[ -z "$server" ]]; then
        print_error "服务器地址不能为空"
        return 1
    fi

    read -p "请输入端口 (默认: 3128): " port
    port=${port:-3128}

    # 是否需要认证
    echo ""
    read -p "是否需要用户名密码认证? [y/N]: " need_auth
    local username=""
    local password=""
    if [[ "$need_auth" == "y" || "$need_auth" == "Y" ]]; then
        read -p "请输入用户名: " username
        read -p "请输入密码: " password
    fi

    # 构建出站配置 (使用jq确保JSON格式正确)
    local server_config=$(jq -n \
        --arg address "$server" \
        --argjson port "$port" \
        '{address: $address, port: $port}')

    # 如果需要认证,添加users数组
    if [[ -n "$username" && -n "$password" ]]; then
        local users_array=$(jq -n \
            --arg user "$username" \
            --arg pass "$password" \
            '[{user: $user, pass: $pass, level: 0}]')
        server_config=$(echo "$server_config" | jq \
            --argjson users "$users_array" \
            '. + {users: $users}')
    fi

    local outbound_config=$(jq -n \
        --arg tag "$tag" \
        --argjson server "$server_config" \
        '{
            protocol: "http",
            tag: $tag,
            settings: {
                servers: [$server],
                headers: {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
                }
            }
        }')

    # 添加到文件
    init_outbound_file
    jq --argjson outbound "$outbound_config" '.outbounds += [$outbound]' "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "HTTP 出站添加成功！"
    echo ""
    echo -e "${OUTBOUND_CYAN}出站信息：${OUTBOUND_NC}"
    echo -e "  标签: $tag"
    echo -e "  服务器: $server:$port"
    [[ -n "$username" ]] && echo -e "  认证: 已启用 (用户: $username)"

    # 提示是否绑定到节点
    prompt_bind_outbound_to_node "$tag"
}

#================================================================
# 添加 SOCKS 出站
#================================================================
add_socks_outbound() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      添加 SOCKS 出站                 ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    echo -e "${OUTBOUND_YELLOW}SOCKS 出站说明：${OUTBOUND_NC}"
    echo -e "  • 使用 SOCKS5/SOCKS4 代理协议"
    echo -e "  • 适用于需要 SOCKS 代理的场景"
    echo -e "  • 支持用户名密码认证"
    echo ""

    # 输入标签
    read -p "请输入出站标签 (例如: socks-proxy): " tag
    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    if jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUND_FILE" >/dev/null 2>&1; then
        print_error "标签 '$tag' 已存在"
        return 1
    fi

    # 服务器地址和端口
    echo ""
    read -p "请输入服务器地址: " server
    if [[ -z "$server" ]]; then
        print_error "服务器地址不能为空"
        return 1
    fi

    read -p "请输入端口 (默认: 1080): " port
    port=${port:-1080}

    # 是否需要认证
    echo ""
    read -p "是否需要用户名密码认证? [y/N]: " need_auth
    local username=""
    local password=""
    if [[ "$need_auth" == "y" || "$need_auth" == "Y" ]]; then
        read -p "请输入用户名: " username
        read -p "请输入密码: " password
    fi

    # 构建出站配置 (使用jq确保JSON格式正确)
    local server_config=$(jq -n \
        --arg address "$server" \
        --argjson port "$port" \
        '{address: $address, port: $port}')

    # 如果需要认证,添加users数组
    if [[ -n "$username" && -n "$password" ]]; then
        local users_array=$(jq -n \
            --arg user "$username" \
            --arg pass "$password" \
            '[{user: $user, pass: $pass, level: 0}]')
        server_config=$(echo "$server_config" | jq \
            --argjson users "$users_array" \
            '. + {users: $users}')
    fi

    local outbound_config=$(jq -n \
        --arg tag "$tag" \
        --argjson server "$server_config" \
        '{
            protocol: "socks",
            tag: $tag,
            settings: {
                servers: [$server]
            }
        }')

    # 添加到文件
    init_outbound_file
    jq --argjson outbound "$outbound_config" '.outbounds += [$outbound]' "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "SOCKS 出站添加成功！"
    echo ""
    echo -e "${OUTBOUND_CYAN}出站信息：${OUTBOUND_NC}"
    echo -e "  标签: $tag"
    echo -e "  服务器: $server:$port"
    [[ -n "$username" ]] && echo -e "  认证: 已启用 (用户: $username)"

    # 提示是否绑定到节点
    prompt_bind_outbound_to_node "$tag"
}

#================================================================
# 添加 VLESS 出站
#================================================================
add_vless_outbound() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      添加 VLESS 出站                 ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    echo -e "${OUTBOUND_YELLOW}VLESS 出站说明：${OUTBOUND_NC}"
    echo -e "  • 无状态轻量传输协议"
    echo -e "  • 支持 XTLS Vision 流控"
    echo -e "  • 需要配合 TLS/Reality 使用"
    echo ""

    # 输入标签
    read -p "请输入出站标签 (例如: vless-proxy): " tag
    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    if jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUND_FILE" >/dev/null 2>&1; then
        print_error "标签 '$tag' 已存在"
        return 1
    fi

    # 服务器地址和端口
    echo ""
    read -p "请输入服务器地址: " server
    if [[ -z "$server" ]]; then
        print_error "服务器地址不能为空"
        return 1
    fi

    read -p "请输入端口 (默认: 443): " port
    port=${port:-443}

    # UUID
    read -p "请输入用户UUID: " uuid
    if [[ -z "$uuid" ]]; then
        print_error "UUID不能为空"
        return 1
    fi

    # Flow (可选)
    echo ""
    echo -e "${OUTBOUND_YELLOW}流控模式 (可选):${OUTBOUND_NC}"
    echo -e "  1. 无流控 (适用于 ws/grpc 等传输)"
    echo -e "  2. xtls-rprx-vision (推荐，配合 Reality/TLS)"
    read -p "请选择 [1-2，默认1]: " flow_choice

    local flow=""
    case $flow_choice in
        2) flow="xtls-rprx-vision" ;;
        *) flow="" ;;
    esac

    # 构建 user 配置
    local user_config=$(jq -n \
        --arg id "$uuid" \
        --argjson level 0 \
        '{id: $id, encryption: "none", level: $level}')

    if [[ -n "$flow" ]]; then
        user_config=$(echo "$user_config" | jq --arg flow "$flow" '. + {flow: $flow}')
    fi

    # 构建完整出站配置
    local outbound_config=$(jq -n \
        --arg tag "$tag" \
        --arg address "$server" \
        --argjson port "$port" \
        --argjson user "$user_config" \
        '{
            protocol: "vless",
            tag: $tag,
            settings: {
                vnext: [{
                    address: $address,
                    port: $port,
                    users: [$user]
                }]
            }
        }')

    # 添加到文件
    init_outbound_file
    jq --argjson outbound "$outbound_config" '.outbounds += [$outbound]' "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "VLESS 出站添加成功！"
    echo ""
    echo -e "${OUTBOUND_CYAN}出站信息：${OUTBOUND_NC}"
    echo -e "  标签: $tag"
    echo -e "  服务器: $server:$port"
    echo -e "  UUID: ${uuid:0:8}...${uuid: -8}"
    [[ -n "$flow" ]] && echo -e "  流控: $flow"

    # 提示是否绑定到节点
    prompt_bind_outbound_to_node "$tag"
}

#================================================================
# 添加 VMess 出站
#================================================================
add_vmess_outbound() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      添加 VMess 出站                 ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    echo -e "${OUTBOUND_YELLOW}VMess 出站说明：${OUTBOUND_NC}"
    echo -e "  • 加密传输协议"
    echo -e "  • 依赖系统时间同步"
    echo -e "  • 支持多种加密方式"
    echo ""

    # 输入标签
    read -p "请输入出站标签 (例如: vmess-proxy): " tag
    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    if jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUND_FILE" >/dev/null 2>&1; then
        print_error "标签 '$tag' 已存在"
        return 1
    fi

    # 服务器地址和端口
    echo ""
    read -p "请输入服务器地址: " server
    if [[ -z "$server" ]]; then
        print_error "服务器地址不能为空"
        return 1
    fi

    read -p "请输入端口 (默认: 443): " port
    port=${port:-443}

    # UUID
    read -p "请输入用户UUID: " uuid
    if [[ -z "$uuid" ]]; then
        print_error "UUID不能为空"
        return 1
    fi

    # 加密方式
    echo ""
    echo -e "${OUTBOUND_YELLOW}加密方式:${OUTBOUND_NC}"
    echo -e "  1. auto (自动选择，推荐)"
    echo -e "  2. aes-128-gcm"
    echo -e "  3. chacha20-poly1305"
    echo -e "  4. none (不加密)"
    read -p "请选择 [1-4，默认1]: " security_choice

    local security="auto"
    case $security_choice in
        2) security="aes-128-gcm" ;;
        3) security="chacha20-poly1305" ;;
        4) security="none" ;;
        *) security="auto" ;;
    esac

    # 构建 user 配置
    local user_config=$(jq -n \
        --arg id "$uuid" \
        --arg security "$security" \
        --argjson level 0 \
        '{id: $id, security: $security, level: $level}')

    # 构建完整出站配置
    local outbound_config=$(jq -n \
        --arg tag "$tag" \
        --arg address "$server" \
        --argjson port "$port" \
        --argjson user "$user_config" \
        '{
            protocol: "vmess",
            tag: $tag,
            settings: {
                vnext: [{
                    address: $address,
                    port: $port,
                    users: [$user]
                }]
            }
        }')

    # 添加到文件
    init_outbound_file
    jq --argjson outbound "$outbound_config" '.outbounds += [$outbound]' "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "VMess 出站添加成功！"
    echo ""
    echo -e "${OUTBOUND_CYAN}出站信息：${OUTBOUND_NC}"
    echo -e "  标签: $tag"
    echo -e "  服务器: $server:$port"
    echo -e "  UUID: ${uuid:0:8}...${uuid: -8}"
    echo -e "  加密: $security"

    # 提示是否绑定到节点
    prompt_bind_outbound_to_node "$tag"
}

#================================================================
# 添加 Trojan 出站
#================================================================
add_trojan_outbound() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      添加 Trojan 出站                ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    echo -e "${OUTBOUND_YELLOW}Trojan 出站说明：${OUTBOUND_NC}"
    echo -e "  • 设计工作在 TLS 隧道中"
    echo -e "  • 使用密码认证"
    echo -e "  • 需要配合 TLS 使用"
    echo ""

    # 输入标签
    read -p "请输入出站标签 (例如: trojan-proxy): " tag
    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    if jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUND_FILE" >/dev/null 2>&1; then
        print_error "标签 '$tag' 已存在"
        return 1
    fi

    # 服务器地址和端口
    echo ""
    read -p "请输入服务器地址: " server
    if [[ -z "$server" ]]; then
        print_error "服务器地址不能为空"
        return 1
    fi

    read -p "请输入端口 (默认: 443): " port
    port=${port:-443}

    # 密码
    read -p "请输入密码: " password
    if [[ -z "$password" ]]; then
        print_error "密码不能为空"
        return 1
    fi

    # 构建 server 配置
    local server_config=$(jq -n \
        --arg address "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --argjson level 0 \
        '{address: $address, port: $port, password: $password, level: $level}')

    # 构建完整出站配置
    local outbound_config=$(jq -n \
        --arg tag "$tag" \
        --argjson server "$server_config" \
        '{
            protocol: "trojan",
            tag: $tag,
            settings: {
                servers: [$server]
            }
        }')

    # 添加到文件
    init_outbound_file
    jq --argjson outbound "$outbound_config" '.outbounds += [$outbound]' "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "Trojan 出站添加成功！"
    echo ""
    echo -e "${OUTBOUND_CYAN}出站信息：${OUTBOUND_NC}"
    echo -e "  标签: $tag"
    echo -e "  服务器: $server:$port"
    echo -e "  密码: ${password:0:4}***${password: -4}"

    # 提示是否绑定到节点
    prompt_bind_outbound_to_node "$tag"
}

#================================================================
# 添加 Shadowsocks 出站
#================================================================
add_shadowsocks_outbound() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      添加 Shadowsocks 出站           ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    echo -e "${OUTBOUND_YELLOW}Shadowsocks 出站说明：${OUTBOUND_NC}"
    echo -e "  • 支持 TCP 和 UDP"
    echo -e "  • 多种加密方式"
    echo -e "  • 推荐使用 2022 新协议"
    echo ""

    # 输入标签
    read -p "请输入出站标签 (例如: ss-proxy): " tag
    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    if jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUND_FILE" >/dev/null 2>&1; then
        print_error "标签 '$tag' 已存在"
        return 1
    fi

    # 服务器地址和端口
    echo ""
    read -p "请输入服务器地址: " server
    if [[ -z "$server" ]]; then
        print_error "服务器地址不能为空"
        return 1
    fi

    read -p "请输入端口 (默认: 8388): " port
    port=${port:-8388}

    # 加密方式
    echo ""
    echo -e "${OUTBOUND_YELLOW}加密方式:${OUTBOUND_NC}"
    echo -e "  1. 2022-blake3-aes-128-gcm (推荐)"
    echo -e "  2. 2022-blake3-aes-256-gcm"
    echo -e "  3. 2022-blake3-chacha20-poly1305"
    echo -e "  4. aes-256-gcm"
    echo -e "  5. aes-128-gcm"
    echo -e "  6. chacha20-ietf-poly1305"
    read -p "请选择 [1-6，默认1]: " method_choice

    local method="2022-blake3-aes-128-gcm"
    case $method_choice in
        2) method="2022-blake3-aes-256-gcm" ;;
        3) method="2022-blake3-chacha20-poly1305" ;;
        4) method="aes-256-gcm" ;;
        5) method="aes-128-gcm" ;;
        6) method="chacha20-ietf-poly1305" ;;
        *) method="2022-blake3-aes-128-gcm" ;;
    esac

    # 密码
    read -p "请输入密码: " password
    if [[ -z "$password" ]]; then
        print_error "密码不能为空"
        return 1
    fi

    # 构建 server 配置
    local server_config=$(jq -n \
        --arg address "$server" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        --argjson level 0 \
        '{address: $address, port: $port, method: $method, password: $password, level: $level}')

    # 构建完整出站配置
    local outbound_config=$(jq -n \
        --arg tag "$tag" \
        --argjson server "$server_config" \
        '{
            protocol: "shadowsocks",
            tag: $tag,
            settings: {
                servers: [$server]
            }
        }')

    # 添加到文件
    init_outbound_file
    jq --argjson outbound "$outbound_config" '.outbounds += [$outbound]' "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "Shadowsocks 出站添加成功！"
    echo ""
    echo -e "${OUTBOUND_CYAN}出站信息：${OUTBOUND_NC}"
    echo -e "  标签: $tag"
    echo -e "  服务器: $server:$port"
    echo -e "  加密: $method"
    echo -e "  密码: ${password:0:4}***${password: -4}"

    # 提示是否绑定到节点
    prompt_bind_outbound_to_node "$tag"
}

#================================================================
# 添加出站规则后的绑定提示
#================================================================
prompt_bind_outbound_to_node() {
    local outbound_tag=$1

    # 检查是否有节点
    if [[ ! -f "$NODES_FILE" ]]; then
        return 0
    fi

    local node_count=$(jq '.nodes | length' "$NODES_FILE" 2>/dev/null || echo "0")
    if [[ "$node_count" -eq 0 ]]; then
        return 0
    fi

    echo ""
    echo -e "${OUTBOUND_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${OUTBOUND_NC}"
    read -p "是否将此出站规则应用到现有节点? [y/N]: " apply_now
    if [[ "$apply_now" != "y" && "$apply_now" != "Y" ]]; then
        print_info "稍后可通过 '应用出站规则' 菜单进行绑定"
        return 0
    fi

    # 显示节点列表
    echo ""
    echo -e "${OUTBOUND_CYAN}现有节点列表：${OUTBOUND_NC}"
    echo ""
    printf "${OUTBOUND_CYAN}%-4s %-20s %-12s %-8s %-20s${OUTBOUND_NC}\n" "序号" "节点名称" "协议" "端口" "当前出站"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    while read -r node; do
        local name=$(echo "$node" | jq -r '.name // "未命名"')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local port=$(echo "$node" | jq -r '.port')
        local current_outbound=$(echo "$node" | jq -r '.outbound_tag // "未设置"')

        # 截断过长的名称
        if [[ ${#name} -gt 18 ]]; then
            name="${name:0:15}..."
        fi

        printf "%-4s %-20s %-12s %-8s %-20s\n" "$index" "$name" "$protocol" "$port" "$current_outbound"
        ((index++))
    done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)

    echo ""
    read -p "请输入节点序号（多个用空格分隔，0=全部）: " node_indices

    if [[ -z "$node_indices" ]]; then
        print_info "已取消绑定"
        return 0
    fi

    # 如果选择0，应用到所有节点
    if [[ "$node_indices" == "0" ]]; then
        jq --arg tag "$outbound_tag" '(.nodes[].outbound_tag) = $tag' "$NODES_FILE" > "${NODES_FILE}.tmp"
        mv "${NODES_FILE}.tmp" "$NODES_FILE"
        generate_sing-box_config
        restart_sing-box
        print_success "已将出站规则 '$outbound_tag' 应用到所有节点"
        return 0
    fi

    local success_count=0
    for node_idx in $node_indices; do
        if [[ ! "$node_idx" =~ ^[0-9]+$ ]]; then
            print_warning "跳过无效序号: $node_idx"
            continue
        fi

        # 更新节点的出站标签
        jq "(.nodes[$((node_idx-1))].outbound_tag) = \"$outbound_tag\"" "$NODES_FILE" > "${NODES_FILE}.tmp"
        if [[ $? -eq 0 ]]; then
            mv "${NODES_FILE}.tmp" "$NODES_FILE"
            ((success_count++))
        else
            rm -f "${NODES_FILE}.tmp"
        fi
    done

    if [[ $success_count -gt 0 ]]; then
        generate_sing-box_config
        restart_sing-box
        print_success "成功将出站规则 '$outbound_tag' 应用到 $success_count 个节点"
    else
        print_error "未能应用出站规则到任何节点"
    fi
}

#================================================================
# 应用出站规则到节点
#================================================================
apply_outbound_to_node() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      应用出站规则                    ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    # 检查是否有出站规则
    init_outbound_file
    local outbound_count=$(jq '.outbounds | length' "$OUTBOUND_FILE" 2>/dev/null || echo "0")
    if [[ "$outbound_count" -eq 0 ]]; then
        print_error "暂无出站规则，请先添加出站规则"
        return 1
    fi

    # 显示出站规则列表
    echo -e "${OUTBOUND_CYAN}现有出站规则：${OUTBOUND_NC}"
    echo ""
    local index=1
    while read -r outbound; do
        local tag=$(echo "$outbound" | jq -r '.tag')
        local protocol=$(echo "$outbound" | jq -r '.protocol')
        echo -e "${OUTBOUND_GREEN}[$index]${OUTBOUND_NC} 标签: $tag, 协议: $protocol"
        ((index++))
    done < <(jq -c '.outbounds[]' "$OUTBOUND_FILE" 2>/dev/null)

    echo ""
    read -p "请选择出站规则序号: " outbound_index
    if [[ ! "$outbound_index" =~ ^[0-9]+$ ]] || [[ "$outbound_index" -lt 1 ]] || [[ "$outbound_index" -gt "$outbound_count" ]]; then
        print_error "无效的序号"
        return 1
    fi

    local outbound=$(jq ".outbounds[$((outbound_index-1))]" "$OUTBOUND_FILE" 2>/dev/null)
    local outbound_tag=$(echo "$outbound" | jq -r '.tag')

    # 检查节点文件
    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "节点文件不存在"
        return 1
    fi

    # 显示节点列表
    echo ""
    echo -e "${OUTBOUND_CYAN}现有节点列表：${OUTBOUND_NC}"
    echo ""
    printf "${OUTBOUND_CYAN}%-4s %-20s %-12s %-8s %-20s${OUTBOUND_NC}\n" "序号" "节点名称" "协议" "端口" "当前出站"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    index=1
    while read -r node; do
        local name=$(echo "$node" | jq -r '.name // "未命名"')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local port=$(echo "$node" | jq -r '.port')
        local current_outbound=$(echo "$node" | jq -r '.outbound_tag // "未设置"')

        # 截断过长的名称
        if [[ ${#name} -gt 18 ]]; then
            name="${name:0:15}..."
        fi

        printf "%-4s %-20s %-12s %-8s %-20s\n" "$index" "$name" "$protocol" "$port" "$current_outbound"
        ((index++))
    done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)

    echo ""
    read -p "请输入节点序号（多个用空格分隔）: " node_indices

    if [[ -z "$node_indices" ]]; then
        print_error "请至少选择一个节点"
        return 1
    fi

    local success_count=0
    for node_idx in $node_indices; do
        if [[ ! "$node_idx" =~ ^[0-9]+$ ]]; then
            print_warning "跳过无效序号: $node_idx"
            continue
        fi

        # 更新节点的出站标签
        jq "(.nodes[$((node_idx-1))].outbound_tag) = \"$outbound_tag\"" "$NODES_FILE" > "${NODES_FILE}.tmp"
        if [[ $? -eq 0 ]]; then
            mv "${NODES_FILE}.tmp" "$NODES_FILE"
            ((success_count++))
        else
            rm -f "${NODES_FILE}.tmp"
        fi
    done

    if [[ $success_count -gt 0 ]]; then
        generate_sing-box_config
        restart_sing-box
        print_success "成功将出站规则 '$outbound_tag' 应用到 $success_count 个节点"
    else
        print_error "未能应用出站规则到任何节点"
    fi
}

#================================================================
# 禁用节点的出站规则
#================================================================
disable_outbound_from_node() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      禁用出站规则                    ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    # 检查节点文件
    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "节点文件不存在"
        return 1
    fi

    # 显示有出站规则的节点
    echo -e "${OUTBOUND_CYAN}已应用出站规则的节点：${OUTBOUND_NC}"
    echo ""
    printf "${OUTBOUND_CYAN}%-4s %-20s %-12s %-8s %-20s${OUTBOUND_NC}\n" "序号" "节点名称" "协议" "端口" "出站规则"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    local has_outbound=false
    while read -r node; do
        local outbound_tag=$(echo "$node" | jq -r '.outbound_tag // ""')
        if [[ -n "$outbound_tag" ]]; then
            local name=$(echo "$node" | jq -r '.name // "未命名"')
            local protocol=$(echo "$node" | jq -r '.protocol')
            local port=$(echo "$node" | jq -r '.port')

            # 截断过长的名称
            if [[ ${#name} -gt 18 ]]; then
                name="${name:0:15}..."
            fi

            printf "%-4s %-20s %-12s %-8s %-20s\n" "$index" "$name" "$protocol" "$port" "$outbound_tag"
            has_outbound=true
        fi
        ((index++))
    done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)

    if [[ "$has_outbound" == "false" ]]; then
        print_warning "暂无节点应用了出站规则"
        return 0
    fi

    echo ""
    read -p "请输入节点序号（多个用空格分隔，0=全部）: " node_indices

    if [[ -z "$node_indices" ]]; then
        print_error "请至少选择一个节点"
        return 1
    fi

    # 如果选择0，禁用所有节点的出站规则
    if [[ "$node_indices" == "0" ]]; then
        jq '(.nodes[].outbound_tag) = null' "$NODES_FILE" > "${NODES_FILE}.tmp"
        mv "${NODES_FILE}.tmp" "$NODES_FILE"
        generate_sing-box_config
        restart_sing-box
        print_success "已禁用所有节点的出站规则"
        return 0
    fi

    local success_count=0
    for node_idx in $node_indices; do
        if [[ ! "$node_idx" =~ ^[0-9]+$ ]]; then
            print_warning "跳过无效序号: $node_idx"
            continue
        fi

        # 移除节点的出站标签
        jq "(.nodes[$((node_idx-1))].outbound_tag) = null" "$NODES_FILE" > "${NODES_FILE}.tmp"
        if [[ $? -eq 0 ]]; then
            mv "${NODES_FILE}.tmp" "$NODES_FILE"
            ((success_count++))
        else
            rm -f "${NODES_FILE}.tmp"
        fi
    done

    if [[ $success_count -gt 0 ]]; then
        generate_sing-box_config
        restart_sing-box
        print_success "成功禁用 $success_count 个节点的出站规则"
    else
        print_error "未能禁用任何节点的出站规则"
    fi
}

#================================================================
# 查看出站规则列表
#================================================================
list_outbounds() {
    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║          出站规则列表                ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""

    init_outbound_file

    local count=$(jq '.outbounds | length' "$OUTBOUND_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -eq 0 ]]; then
        print_warning "暂无出站规则"
        return 0
    fi

    echo -e "${OUTBOUND_YELLOW}出站规则总数:${OUTBOUND_NC} $count"
    echo ""

    local index=1
    while read -r outbound; do
        local tag=$(echo "$outbound" | jq -r '.tag')
        local protocol=$(echo "$outbound" | jq -r '.protocol')

        # 显示出站规则摘要
        echo -e "${OUTBOUND_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${OUTBOUND_NC}"
        echo -e "${OUTBOUND_GREEN}[$index] $tag${OUTBOUND_NC} ($(get_outbound_type_name "$protocol"))"

        # 获取服务器信息
        local address=$(echo "$outbound" | jq -r '.settings.servers[0].address // .settings.vnext[0].address // "N/A"')
        local port=$(echo "$outbound" | jq -r '.settings.servers[0].port // .settings.vnext[0].port // "N/A"')
        echo -e "  ${OUTBOUND_YELLOW}服务器:${OUTBOUND_NC} $address:$port"

        # 根据协议显示特定信息
        case "$protocol" in
            http|socks)
                # 认证信息
                local has_auth=$(echo "$outbound" | jq -r '.settings.servers[0].users // empty | length > 0')
                if [[ "$has_auth" == "true" ]]; then
                    local username=$(echo "$outbound" | jq -r '.settings.servers[0].users[0].user')
                    echo -e "  ${OUTBOUND_YELLOW}认证:${OUTBOUND_NC} 已启用 (用户: $username)"
                else
                    echo -e "  ${OUTBOUND_YELLOW}认证:${OUTBOUND_NC} 未启用"
                fi

                # HTTP额外显示headers
                if [[ "$protocol" == "http" ]]; then
                    local user_agent=$(echo "$outbound" | jq -r '.settings.headers["User-Agent"] // "N/A"')
                    if [[ "$user_agent" != "N/A" ]]; then
                        echo -e "  ${OUTBOUND_YELLOW}User-Agent:${OUTBOUND_NC} ${user_agent:0:50}..."
                    fi
                fi
                ;;
            vless)
                local uuid=$(echo "$outbound" | jq -r '.settings.vnext[0].users[0].id // "N/A"')
                echo -e "  ${OUTBOUND_YELLOW}UUID:${OUTBOUND_NC} ${uuid:0:8}...${uuid: -8}"
                local flow=$(echo "$outbound" | jq -r '.settings.vnext[0].users[0].flow // "无"')
                echo -e "  ${OUTBOUND_YELLOW}流控:${OUTBOUND_NC} $flow"
                ;;
            vmess)
                local uuid=$(echo "$outbound" | jq -r '.settings.vnext[0].users[0].id // "N/A"')
                local security=$(echo "$outbound" | jq -r '.settings.vnext[0].users[0].security // "auto"')
                echo -e "  ${OUTBOUND_YELLOW}UUID:${OUTBOUND_NC} ${uuid:0:8}...${uuid: -8}"
                echo -e "  ${OUTBOUND_YELLOW}加密:${OUTBOUND_NC} $security"
                ;;
            trojan)
                local password=$(echo "$outbound" | jq -r '.settings.servers[0].password // "N/A"')
                echo -e "  ${OUTBOUND_YELLOW}密码:${OUTBOUND_NC} ${password:0:4}***${password: -4}"
                ;;
            shadowsocks)
                local method=$(echo "$outbound" | jq -r '.settings.servers[0].method // "N/A"')
                local password=$(echo "$outbound" | jq -r '.settings.servers[0].password // "N/A"')
                echo -e "  ${OUTBOUND_YELLOW}加密:${OUTBOUND_NC} $method"
                echo -e "  ${OUTBOUND_YELLOW}密码:${OUTBOUND_NC} ${password:0:4}***${password: -4}"
                ;;
        esac

        # Mux配置
        local mux_enabled=$(echo "$outbound" | jq -r '.mux.enabled // false')
        if [[ "$mux_enabled" == "true" ]]; then
            local mux_concurrency=$(echo "$outbound" | jq -r '.mux.concurrency // 8')
            echo -e "  ${OUTBOUND_YELLOW}Mux:${OUTBOUND_NC} 已启用 (并发: $mux_concurrency)"
        else
            echo -e "  ${OUTBOUND_YELLOW}Mux:${OUTBOUND_NC} 未启用"
        fi

        # TLS配置(如果有)
        local tls_enabled=$(echo "$outbound" | jq -r '.streamSettings.security // "none"')
        if [[ "$tls_enabled" != "none" ]]; then
            echo -e "  ${OUTBOUND_YELLOW}传输层安全:${OUTBOUND_NC} $tls_enabled"
            if [[ "$tls_enabled" == "tls" ]]; then
                local sni=$(echo "$outbound" | jq -r '.streamSettings.tlsSettings.serverName // "N/A"')
                [[ "$sni" != "N/A" ]] && echo -e "  ${OUTBOUND_YELLOW}SNI:${OUTBOUND_NC} $sni"
            elif [[ "$tls_enabled" == "reality" ]]; then
                local public_key=$(echo "$outbound" | jq -r '.streamSettings.realitySettings.publicKey // "N/A"')
                [[ "$public_key" != "N/A" ]] && echo -e "  ${OUTBOUND_YELLOW}PublicKey:${OUTBOUND_NC} ${public_key:0:16}..."
            fi
        fi

        # 传输协议(如果有)
        local network=$(echo "$outbound" | jq -r '.streamSettings.network // "tcp"')
        if [[ "$network" != "tcp" ]]; then
            echo -e "  ${OUTBOUND_YELLOW}传输协议:${OUTBOUND_NC} $network"
        fi

        echo ""
        ((index++))
    done < <(jq -c '.outbounds[]' "$OUTBOUND_FILE" 2>/dev/null)

    echo -e "${OUTBOUND_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${OUTBOUND_NC}"
    echo ""
}

#================================================================
# 删除出站规则
#================================================================
delete_outbound() {
    list_outbounds

    local count=$(jq '.outbounds | length' "$OUTBOUND_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    echo ""
    read -p "请输入要删除的出站规则序号: " index
    if [[ ! "$index" =~ ^[0-9]+$ ]] || [[ "$index" -lt 1 ]] || [[ "$index" -gt "$count" ]]; then
        print_error "无效的序号"
        return 1
    fi

    # 获取标签
    local tag=$(jq -r ".outbounds[$((index-1))].tag" "$OUTBOUND_FILE" 2>/dev/null)
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        print_error "出站规则不存在"
        return 1
    fi

    # 检查是否有节点使用该出站规则
    local affected_nodes=""
    if [[ -f "$NODES_FILE" ]]; then
        affected_nodes=$(jq -r ".nodes[] | select(.outbound_tag == \"$tag\") | .port" "$NODES_FILE" 2>/dev/null)
    fi

    echo ""
    if [[ -n "$affected_nodes" ]]; then
        print_warning "以下节点正在使用该出站规则："
        echo "$affected_nodes" | while read -r port; do
            local node_name=$(jq -r ".nodes[] | select(.port == \"$port\") | .name" "$NODES_FILE" 2>/dev/null)
            echo "  - 端口 $port ($node_name)"
        done
        print_warning "删除后这些节点的出站规则将被清空"
    fi

    read -p "确认删除出站规则 '$tag'? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消删除"
        return 0
    fi

    # 1. 从使用该出站的节点中移除 outbound_tag
    if [[ -n "$affected_nodes" ]] && [[ -f "$NODES_FILE" ]]; then
        jq --arg tag "$tag" '
            .nodes = [.nodes[] |
                if .outbound_tag == $tag then
                    del(.outbound_tag)
                else
                    .
                end
            ]
        ' "$NODES_FILE" > "${NODES_FILE}.tmp"
        mv "${NODES_FILE}.tmp" "$NODES_FILE"
        print_info "已更新节点配置"
    fi

    # 2. 删除出站规则
    jq --arg tag "$tag" '.outbounds = [.outbounds[] | select(.tag != $tag)]' "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "出站规则已删除: $tag"

    # 3. 重新生成 sing-box 配置（无论是否有受影响节点都需要重新生成）
    print_info "正在重新生成配置..."
    generate_sing-box_config
    restart_sing-box
    print_success "配置已更新并重启服务"
}

#================================================================
# 修改出站规则
#================================================================
modify_outbound() {
    list_outbounds

    local count=$(jq '.outbounds | length' "$OUTBOUND_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    echo ""
    read -p "请输入要修改的出站规则序号: " index
    if [[ ! "$index" =~ ^[0-9]+$ ]] || [[ "$index" -lt 1 ]] || [[ "$index" -gt "$count" ]]; then
        print_error "无效的序号"
        return 1
    fi

    local outbound=$(jq ".outbounds[$((index-1))]" "$OUTBOUND_FILE" 2>/dev/null)
    if [[ -z "$outbound" || "$outbound" == "null" ]]; then
        print_error "出站规则不存在"
        return 1
    fi

    local tag=$(echo "$outbound" | jq -r '.tag')
    local protocol=$(echo "$outbound" | jq -r '.protocol')

    clear
    echo -e "${OUTBOUND_CYAN}╔═══════════════════════════════════════╗${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}║      修改出站规则: ${OUTBOUND_YELLOW}$tag${OUTBOUND_CYAN}         ║${OUTBOUND_NC}"
    echo -e "${OUTBOUND_CYAN}╚═══════════════════════════════════════╝${OUTBOUND_NC}"
    echo ""
    echo -e "${OUTBOUND_GREEN}1.${OUTBOUND_NC} 修改标签"
    echo -e "${OUTBOUND_GREEN}2.${OUTBOUND_NC} 修改 Mux 配置"
    echo -e "${OUTBOUND_GREEN}3.${OUTBOUND_NC} 修改服务器地址/端口 (HTTP/SOCKS)"
    echo -e "${OUTBOUND_GREEN}4.${OUTBOUND_NC} 修改认证信息 (HTTP/SOCKS)"
    echo -e "${OUTBOUND_GREEN}0.${OUTBOUND_NC} 返回"
    echo ""
    read -p "请选择操作 [0-4]: " choice

    case $choice in
        1) modify_outbound_tag "$index" "$tag" ;;
        2) modify_outbound_mux_config "$index" "$tag" ;;
        3) modify_outbound_server "$index" "$tag" "$protocol" ;;
        4) modify_outbound_auth "$index" "$tag" "$protocol" ;;
        0) return 0 ;;
        *) print_error "无效选择" ;;
    esac
}

# 修改标签
modify_outbound_tag() {
    local index=$1
    local old_tag=$2

    echo ""
    read -p "请输入新标签: " new_tag
    if [[ -z "$new_tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查新标签是否已存在
    if jq -e --arg tag "$new_tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUND_FILE" >/dev/null 2>&1; then
        print_error "标签 '$new_tag' 已存在"
        return 1
    fi

    jq "(.outbounds[$((index-1))].tag) = \"$new_tag\"" "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "标签已更新: $old_tag -> $new_tag"
}

# 修改 Mux 配置
modify_outbound_mux_config() {
    local index=$1
    local tag=$2

    local current_enabled=$(jq -r ".outbounds[$((index-1))].mux.enabled // false" "$OUTBOUND_FILE")
    local current_concurrency=$(jq -r ".outbounds[$((index-1))].mux.concurrency // 8" "$OUTBOUND_FILE")

    echo ""
    echo -e "${OUTBOUND_YELLOW}当前 Mux 配置：${OUTBOUND_NC}"
    echo -e "  启用: $current_enabled"
    [[ "$current_enabled" == "true" ]] && echo -e "  并发数: $current_concurrency"
    echo ""

    read -p "是否启用 Mux? [y/N]: " enable_mux
    local mux_enabled="false"
    local mux_concurrency=8
    if [[ "$enable_mux" == "y" || "$enable_mux" == "Y" ]]; then
        mux_enabled="true"
        read -p "Mux 并发数 (1-128, 默认: 8): " input_concurrency
        mux_concurrency=${input_concurrency:-8}
    fi

    jq --argjson enabled "$mux_enabled" --argjson concurrency "$mux_concurrency" \
       "(.outbounds[$((index-1))].mux) = {enabled: \$enabled, concurrency: \$concurrency}" \
       "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "Mux 配置已更新"
}

# 修改服务器地址/端口
modify_outbound_server() {
    local index=$1
    local tag=$2
    local protocol=$3

    if [[ "$protocol" != "http" && "$protocol" != "socks" ]]; then
        print_error "只有 HTTP 和 SOCKS 协议支持此操作"
        return 1
    fi

    local current_address=$(jq -r ".outbounds[$((index-1))].settings.servers[0].address" "$OUTBOUND_FILE")
    local current_port=$(jq -r ".outbounds[$((index-1))].settings.servers[0].port" "$OUTBOUND_FILE")

    echo ""
    echo -e "${OUTBOUND_YELLOW}当前服务器：${OUTBOUND_NC}"
    echo -e "  地址: $current_address"
    echo -e "  端口: $current_port"
    echo ""

    read -p "请输入新的服务器地址 (回车保持不变): " new_address
    read -p "请输入新的端口 (回车保持不变): " new_port

    new_address=${new_address:-$current_address}
    new_port=${new_port:-$current_port}

    jq --arg address "$new_address" --argjson port "$new_port" \
       "(.outbounds[$((index-1))].settings.servers[0].address) = \$address |
        (.outbounds[$((index-1))].settings.servers[0].port) = \$port" \
       "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "服务器配置已更新"
}

# 修改认证信息
modify_outbound_auth() {
    local index=$1
    local tag=$2
    local protocol=$3

    if [[ "$protocol" != "http" && "$protocol" != "socks" ]]; then
        print_error "只有 HTTP 和 SOCKS 协议支持此操作"
        return 1
    fi

    # 正确获取当前认证信息(从users数组中)
    local current_user=$(jq -r ".outbounds[$((index-1))].settings.servers[0].users[0].user // \"\"" "$OUTBOUND_FILE")

    echo ""
    if [[ -n "$current_user" ]]; then
        echo -e "${OUTBOUND_YELLOW}当前认证用户: $current_user${OUTBOUND_NC}"
    else
        echo -e "${OUTBOUND_YELLOW}当前未启用认证${OUTBOUND_NC}"
    fi
    echo ""

    read -p "是否启用认证? [y/N]: " enable_auth
    if [[ "$enable_auth" != "y" && "$enable_auth" != "Y" ]]; then
        # 移除认证(删除users数组)
        jq "del(.outbounds[$((index-1))].settings.servers[0].users)" \
           "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
        mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"
        print_success "认证已禁用"
        return 0
    fi

    read -p "请输入用户名: " username
    read -p "请输入密码: " password

    if [[ -z "$username" || -z "$password" ]]; then
        print_error "用户名和密码不能为空"
        return 1
    fi

    # 正确更新认证信息(更新users数组)
    jq --arg user "$username" --arg pass "$password" \
       "(.outbounds[$((index-1))].settings.servers[0].users) = [{user: \$user, pass: \$pass, level: 0}]" \
       "$OUTBOUND_FILE" > "${OUTBOUND_FILE}.tmp"
    mv "${OUTBOUND_FILE}.tmp" "$OUTBOUND_FILE"

    print_success "认证信息已更新"
}

#================================================================
# 出站规则管理菜单
#================================================================
outbound_management_menu() {
    # 首次进入时运行一致性检测
    local first_run=true

    while true; do
        clear
        print_header "出站规则管理"
        echo ""

        # 首次进入时运行检测
        if [[ "$first_run" == "true" ]]; then
            first_run=false
            if ! check_outbound_consistency; then
                echo ""
                print_error "一致性检测未通过,请处理后再继续"
                wait_for_input
                return 1
            fi
            echo ""
        fi

        # 显示状态信息
        show_outbound_status

        print_section_start
        print_menu_item "1" "查看出站规则"
        print_menu_item "2" "添加出站规则"
        print_menu_item "3" "应用出站规则"
        print_menu_item "4" "禁用出站规则"
        print_menu_item "5" "修改出站规则"
        print_menu_item "6" "删除出站规则"
        print_menu_item "7" "重新检测一致性"
        print_menu_item "0" "返回主菜单"
        print_section_end

        print_nav_options "false" "true"
        choice=$(read_menu_choice "请选择操作 [0-7]")
        local ret=$?

        # 处理导航
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case $choice in
            1) list_outbounds; wait_for_input ;;
            2)
                # 添加出站规则子菜单
                clear
                print_header "添加出站规则"
                echo ""
                print_section_start
                print_menu_item "1" "HTTP 代理"
                print_menu_item "2" "SOCKS 代理"
                print_menu_item "3" "VLESS 协议"
                print_menu_item "4" "VMess 协议"
                print_menu_item "5" "Trojan 协议"
                print_menu_item "6" "Shadowsocks 协议"
                print_menu_item "0" "返回"
                print_section_end
                echo ""

                read -p "请选择协议 [0-6]: " protocol_choice
                case $protocol_choice in
                    1) add_http_outbound ;;
                    2) add_socks_outbound ;;
                    3) add_vless_outbound ;;
                    4) add_vmess_outbound ;;
                    5) add_trojan_outbound ;;
                    6) add_shadowsocks_outbound ;;
                    0) ;;
                    *) print_error "无效选择" ;;
                esac
                wait_for_input
                ;;
            3) apply_outbound_to_node; wait_for_input ;;
            4) disable_outbound_from_node; wait_for_input ;;
            5) modify_outbound; wait_for_input ;;
            6) delete_outbound; wait_for_input ;;
            7)
                clear
                check_outbound_consistency
                wait_for_input
                ;;
            0) break ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# 如果直接运行此脚本，显示菜单
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    outbound_management_menu
fi
