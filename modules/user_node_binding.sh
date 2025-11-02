#!/bin/bash

#================================================================
# 用户-节点绑定管理模块（新架构）
# 功能：绑定用户到节点、解绑、查看绑定关系
#================================================================

# 绑定用户到节点
bind_user_to_node() {
    local username="$1"  # 可选参数：如果提供则直接使用，否则交互选择

    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      绑定用户到节点                  ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 如果没有提供用户名，显示用户列表并选择
    if [[ -z "$username" ]]; then
        echo -e "${YELLOW}可用用户列表：${NC}"
        list_global_users

        echo ""
        read -p "请输入用户名: " username
        if [[ -z "$username" ]]; then
            print_error "用户名不能为空"
            return 1
        fi
    else
        echo -e "${GREEN}用户：${NC}${YELLOW}$username${NC}"
        echo ""
    fi

    # 获取用户UUID和邮箱
    local user_info=$(jq -r ".users[] | select(.username == \"$username\")" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$user_info" || "$user_info" == "null" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    local uuid=$(echo "$user_info" | jq -r '.id')
    local email=$(echo "$user_info" | jq -r '.email // .username')

    # 显示所有节点
    echo -e "${YELLOW}可用节点列表：${NC}"
    list_nodes true

    echo ""
    read -p "请输入节点序号: " node_index
    if [[ -z "$node_index" ]]; then
        print_error "节点序号不能为空"
        return 1
    fi

    # 根据序号获取端口
    local port=$(get_node_port_by_index "$node_index")
    if [[ -z "$port" || "$port" == "null" ]]; then
        print_error "无效的节点序号: $node_index"
        return 1
    fi

    # 检查节点是否存在
    local node_exists=$(jq -r ".nodes[] | select(.port == \"$port\") | .port" "$NODES_FILE" 2>/dev/null)
    if [[ -z "$node_exists" ]]; then
        print_error "节点不存在: $port"
        return 1
    fi

    # 检查是否已绑定
    local already_bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
    if [[ -n "$already_bound" ]]; then
        print_warning "用户 $email 已绑定到端口 $port"
        return 0
    fi

    # 添加绑定
    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo '{"bindings":[]}' > "$NODE_USERS_FILE"
    fi

    # 检查该端口的绑定是否存在
    local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$binding_exists" ]]; then
        # 创建新绑定
        local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
        if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "创建绑定失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            return 1
        fi
    else
        # 添加用户到现有绑定
        if ! jq --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "添加用户到绑定失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            return 1
        fi
    fi

    mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"

    print_success "用户 $email 已绑定到端口 $port"

    # 重新生成配置
    generate_xray_config

    # 重启服务
    restart_xray

    print_success "配置已更新并重启服务"
}

# 解绑用户
unbind_user_from_node() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      解绑用户                        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 显示当前绑定关系
    show_user_node_bindings

    echo ""
    read -p "请输入用户名: " username
    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$uuid" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    echo ""
    read -p "请输入节点端口: " port
    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 检查绑定是否存在
    local bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
    if [[ -z "$bound" ]]; then
        print_error "用户 $email 未绑定到端口 $port"
        return 1
    fi

    # 解绑用户
    if ! jq '.bindings |= map(if .port == $port then .users |= map(select(. != $uuid)) else . end)' --arg port "$port" --arg uuid "$uuid" "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
        print_error "解绑用户失败"
        rm -f "${NODE_USERS_FILE}.tmp"
        return 1
    fi
    mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"

    print_success "用户 $email 已从端口 $port 解绑"

    # 重新生成配置
    generate_xray_config

    # 重启服务
    restart_xray

    print_success "配置已更新并重启服务"
}

# 显示用户-节点绑定关系
show_user_node_bindings() {
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      用户-节点绑定关系              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        print_warning "绑定关系文件不存在"
        return 1
    fi

    local binding_count=$(jq '.bindings | length' "$NODE_USERS_FILE")
    if [[ $binding_count -eq 0 ]]; then
        print_warning "没有绑定关系"
        return 0
    fi

    # 遍历所有绑定
    while IFS= read -r binding; do
        local port=$(echo "$binding" | jq -r '.port')
        local protocol=$(echo "$binding" | jq -r '.protocol')
        local users=$(echo "$binding" | jq -r '.users[]')

        # 获取节点名称
        local node_name=$(jq -r ".nodes[] | select(.port == \"$port\") | .name // \"未命名\"" "$NODES_FILE" 2>/dev/null)
        echo -e "${GREEN}端口 $port ($protocol) - $node_name:${NC}"

        if [[ -z "$users" ]]; then
            echo -e "  ${YELLOW}无绑定用户${NC}"
        else
            while IFS= read -r uuid; do
                local user=$(jq -r ".users[] | select(.id == \"$uuid\")" "$USERS_FILE" 2>/dev/null)
                if [[ -n "$user" && "$user" != "null" ]]; then
                    local username=$(echo "$user" | jq -r '.username // "未设置"')
                    local email=$(echo "$user" | jq -r '.email // "未设置"')
                    local enabled=$(echo "$user" | jq -r '.enabled // true')
                    local expire_date=$(echo "$user" | jq -r '.expire_date // "unlimited"')

                    local status_text=""
                    if [[ "$enabled" == "true" ]]; then
                        status_text="${GREEN}启用${NC}"
                    else
                        status_text="${RED}禁用${NC}"
                    fi

                    echo -e "  ${CYAN}•${NC} $username ($email) - 状态: $status_text, 有效期: ${YELLOW}$expire_date${NC}"
                fi
            done <<< "$users"
        fi
        echo ""
    done < <(jq -c '.bindings[]' "$NODE_USERS_FILE" 2>/dev/null)
}

# 查看用户可访问的节点
show_user_nodes() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      用户可访问节点                  ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 显示所有用户
    list_global_users

    echo ""
    read -p "请输入用户名: " username
    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 获取用户信息
    local user=$(jq -r ".users[] | select(.username == \"$username\")" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$user" || "$user" == "null" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    local uuid=$(echo "$user" | jq -r '.id')
    local email=$(echo "$user" | jq -r '.email // .username')
    local traffic_limit=$(echo "$user" | jq -r '.traffic_limit_gb // "unlimited"')
    local traffic_used=$(echo "$user" | jq -r '.traffic_used_gb // "0"')
    local expire_date=$(echo "$user" | jq -r '.expire_date // "unlimited"')

    echo ""
    echo -e "${GREEN}用户信息：${NC}"
    echo -e "  用户名: ${YELLOW}$username${NC}"
    echo -e "  邮箱: ${YELLOW}$email${NC}"
    echo -e "  流量: ${YELLOW}${traffic_used}/${traffic_limit} GB${NC}"
    echo -e "  有效期: ${YELLOW}$expire_date${NC}"
    echo ""
    echo -e "${GREEN}可访问节点：${NC}"

    # 查找该用户绑定的所有节点
    local node_found=false
    while IFS= read -r binding; do
        local port=$(echo "$binding" | jq -r '.port')
        local protocol=$(echo "$binding" | jq -r '.protocol')
        local users=$(echo "$binding" | jq -r '.users[]')

        # 检查用户是否在这个节点的用户列表中
        if echo "$users" | grep -q "$uuid"; then
            node_found=true
            # 获取节点详细信息
            local node=$(jq -r ".nodes[] | select(.port == \"$port\")" "$NODES_FILE")
            local name=$(echo "$node" | jq -r '.name // "未命名"')
            local transport=$(echo "$node" | jq -r '.transport')
            local security=$(echo "$node" | jq -r '.security')
            local outbound_tag=$(echo "$node" | jq -r '.outbound_tag // empty')

            echo -e "  ${CYAN}•${NC} $name"
            echo -e "    端口: ${YELLOW}$port${NC} | 协议: ${YELLOW}$protocol${NC}"
            echo -e "    传输: ${YELLOW}$transport${NC} | 安全: ${YELLOW}$security${NC}"
            if [[ -n "$outbound_tag" ]]; then
                echo -e "    出站: ${GREEN}$outbound_tag${NC}"
            fi
            echo ""
        fi
    done < <(jq -c '.bindings[]' "$NODE_USERS_FILE" 2>/dev/null)

    if [[ "$node_found" == "false" ]]; then
        print_warning "用户 $email 未绑定到任何节点"
    fi
}

# 查看节点的用户列表
show_node_users() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      节点用户列表                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 显示所有节点
    list_nodes

    echo ""
    read -p "请输入节点端口: " port
    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 检查节点是否存在
    local node_exists=$(jq -r ".nodes[] | select(.port == \"$port\") | .port" "$NODES_FILE" 2>/dev/null)
    if [[ -z "$node_exists" ]]; then
        print_error "节点不存在: $port"
        return 1
    fi

    echo ""
    echo -e "${GREEN}端口 $port 的用户列表：${NC}"
    echo ""

    # 获取该节点的用户列表
    local users=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[]" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$users" ]]; then
        print_warning "该节点没有绑定用户"
        return 0
    fi

    # 显示用户信息
    while IFS= read -r uuid; do
        local user=$(jq -r ".users[] | select(.id == \"$uuid\")" "$USERS_FILE" 2>/dev/null)
        if [[ -n "$user" && "$user" != "null" ]]; then
            local username=$(echo "$user" | jq -r '.username // "未设置"')
            local password=$(echo "$user" | jq -r '.password // "无"')
            local level=$(echo "$user" | jq -r '.level // 0')
            local enabled=$(echo "$user" | jq -r '.enabled // true')

            local status_text=""
            if [[ "$enabled" == "true" ]]; then
                status_text="${GREEN}启用${NC}"
            else
                status_text="${RED}禁用${NC}"
            fi

            echo -e "${CYAN}•${NC} 用户名: $username"
            echo -e "  密码: $password"
            echo -e "  UUID: ${uuid:0:8}...${uuid: -8}"
            echo -e "  等级: $level"
            echo -e "  状态: $status_text"
            echo ""
        fi
    done <<< "$users"
}

# 为用户添加单个节点绑定
bind_single_node_to_user() {
    local username=$1

    echo ""
    echo -e "${YELLOW}可用节点列表：${NC}"
    list_nodes

    echo ""
    read -p "请输入要绑定的节点端口: " port
    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 检查节点是否存在
    local node_exists=$(jq -r ".nodes[] | select(.port == \"$port\") | .port" "$NODES_FILE" 2>/dev/null)
    if [[ -z "$node_exists" ]]; then
        print_error "节点不存在: $port"
        return 1
    fi

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)

    # 检查是否已绑定
    local already_bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
    if [[ -n "$already_bound" ]]; then
        print_warning "用户 $username 已绑定到端口 $port"
        return 0
    fi

    # 添加绑定
    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo '{"bindings":[]}' > "$NODE_USERS_FILE"
    fi

    local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$binding_exists" ]]; then
        local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
        if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "创建绑定失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            return 1
        fi
    else
        if ! jq --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "添加用户到绑定失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            return 1
        fi
    fi

    mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"

    generate_xray_config
    restart_xray

    print_success "用户 $username 已绑定到端口 $port"
}

# 为用户批量添加节点绑定
batch_bind_nodes_to_user() {
    local username=$1

    echo ""
    echo -e "${YELLOW}可用节点列表：${NC}"
    list_nodes

    echo ""
    echo -e "${YELLOW}输入节点端口（多个端口用空格分隔）${NC}"
    read -p "端口列表: " ports

    if [[ -z "$ports" ]]; then
        print_error "端口列表不能为空"
        return 1
    fi

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)

    local success_count=0
    local fail_count=0

    for port in $ports; do
        # 检查节点是否存在
        local node_exists=$(jq -r ".nodes[] | select(.port == \"$port\") | .port" "$NODES_FILE" 2>/dev/null)
        if [[ -z "$node_exists" ]]; then
            print_error "节点不存在: $port"
            ((fail_count++))
            continue
        fi

        # 检查是否已绑定
        local already_bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
        if [[ -n "$already_bound" ]]; then
            print_info "端口 $port 已绑定，跳过"
            continue
        fi

        # 添加绑定
        local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

        if [[ -z "$binding_exists" ]]; then
            local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
            if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "创建绑定失败"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        else
            if ! jq --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "添加用户到绑定失败"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        fi

        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已绑定到端口 $port"
        ((success_count++))
    done

    echo ""
    print_info "批量绑定完成：成功 $success_count 个，失败 $fail_count 个"

    if [[ $success_count -gt 0 ]]; then
        generate_xray_config
        restart_xray
        print_success "配置已更新并重启服务"
    fi
}

# 为用户移除单个节点绑定
unbind_single_node_from_user() {
    local username=$1

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)

    echo ""
    echo -e "${YELLOW}用户 $username 已绑定的节点：${NC}"

    local has_bindings=false
    while IFS= read -r binding; do
        local port=$(echo "$binding" | jq -r '.port')
        local users=$(echo "$binding" | jq -r '.users[]')

        if echo "$users" | grep -q "$uuid"; then
            echo "  - 端口 $port"
            has_bindings=true
        fi
    done < <(jq -c '.bindings[]' "$NODE_USERS_FILE" 2>/dev/null)

    if [[ "$has_bindings" == "false" ]]; then
        print_warning "用户未绑定任何节点"
        return 0
    fi

    echo ""
    read -p "请输入要移除的节点端口: " port
    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 移除绑定
    if ! jq '.bindings |= map(if .port == $port then .users |= map(select(. != $uuid)) else . end)' --arg port "$port" --arg uuid "$uuid" "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
        print_error "移除绑定失败"
        rm -f "${NODE_USERS_FILE}.tmp"
        return 1
    fi
    mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"

    generate_xray_config
    restart_xray

    print_success "用户 $username 已从端口 $port 解绑"
}

# 为用户批量移除节点绑定
batch_unbind_nodes_from_user() {
    local username=$1

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)

    echo ""
    echo -e "${YELLOW}用户 $username 已绑定的节点：${NC}"

    local bound_ports=()
    while IFS= read -r binding; do
        local port=$(echo "$binding" | jq -r '.port')
        local users=$(echo "$binding" | jq -r '.users[]')

        if echo "$users" | grep -q "$uuid"; then
            echo "  - 端口 $port"
            bound_ports+=("$port")
        fi
    done < <(jq -c '.bindings[]' "$NODE_USERS_FILE" 2>/dev/null)

    if [[ ${#bound_ports[@]} -eq 0 ]]; then
        print_warning "用户未绑定任何节点"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}输入要移除的端口（多个端口用空格分隔）${NC}"
    read -p "端口列表: " ports

    if [[ -z "$ports" ]]; then
        print_error "端口列表不能为空"
        return 1
    fi

    local success_count=0
    for port in $ports; do
        if ! jq '.bindings |= map(if .port == $port then .users |= map(select(. != $uuid)) else . end)' --arg port "$port" --arg uuid "$uuid" "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "从端口 $port 解绑失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            continue
        fi
        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已从端口 $port 解绑"
        ((success_count++))
    done

    echo ""
    print_info "批量解绑完成：成功 $success_count 个"

    if [[ $success_count -gt 0 ]]; then
        generate_xray_config
        restart_xray
        print_success "配置已更新并重启服务"
    fi
}

# 批量绑定用户到多个节点
batch_bind_user_to_nodes() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      批量绑定用户到节点              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 显示所有用户
    echo -e "${YELLOW}可用用户列表：${NC}"
    list_global_users

    echo ""
    read -p "请输入用户名: " username
    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$uuid" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    # 显示所有节点
    echo ""
    echo -e "${YELLOW}可用节点列表：${NC}"
    list_nodes

    echo ""
    echo -e "${YELLOW}输入节点端口（多个端口用空格分隔，如: 443 8443 10086）${NC}"
    read -p "端口列表: " ports

    if [[ -z "$ports" ]]; then
        print_error "端口列表不能为空"
        return 1
    fi

    # 绑定到每个节点
    local success_count=0
    local fail_count=0

    for port in $ports; do
        # 检查节点是否存在
        local node_exists=$(jq -r ".nodes[] | select(.port == \"$port\") | .port" "$NODES_FILE" 2>/dev/null)
        if [[ -z "$node_exists" ]]; then
            print_error "节点不存在: $port"
            ((fail_count++))
            continue
        fi

        # 检查是否已绑定
        local already_bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
        if [[ -n "$already_bound" ]]; then
            print_info "端口 $port 已绑定，跳过"
            continue
        fi

        # 添加绑定
        local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

        if [[ -z "$binding_exists" ]]; then
            # 创建新绑定
            local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
            if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "创建绑定失败"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        else
            # 添加用户到现有绑定
            if ! jq --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "添加用户到绑定失败"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        fi

        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已绑定到端口 $port"
        ((success_count++))
    done

    echo ""
    print_info "批量绑定完成：成功 $success_count 个，失败 $fail_count 个"

    if [[ $success_count -gt 0 ]]; then
        # 重新生成配置
        generate_xray_config

        # 重启服务
        restart_xray

        print_success "配置已更新并重启服务"
    fi
}

# 为节点添加单个用户绑定
bind_single_user_to_node() {
    local port=$1

    echo ""
    echo -e "${YELLOW}可用用户列表：${NC}"
    list_global_users

    echo ""
    read -p "请输入要绑定的用户名: " username
    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$uuid" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    # 检查是否已绑定
    local already_bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
    if [[ -n "$already_bound" ]]; then
        print_warning "用户 $username 已绑定到端口 $port"
        return 0
    fi

    # 添加绑定
    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo '{"bindings":[]}' > "$NODE_USERS_FILE"
    fi

    local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$binding_exists" ]]; then
        local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
        if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "创建绑定失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            return 1
        fi
    else
        if ! jq --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "添加用户到绑定失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            return 1
        fi
    fi

    mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"

    generate_xray_config
    restart_xray

    print_success "用户 $username 已绑定到端口 $port"
}

# 为节点批量添加用户绑定
batch_bind_users_to_node() {
    local port=$1

    echo ""
    echo -e "${YELLOW}可用用户列表：${NC}"
    list_global_users

    echo ""
    echo -e "${YELLOW}输入用户名（多个用户名用空格分隔）${NC}"
    read -p "用户名列表: " usernames

    if [[ -z "$usernames" ]]; then
        print_error "用户名列表不能为空"
        return 1
    fi

    local success_count=0
    local fail_count=0

    for username in $usernames; do
        # 获取用户UUID
        local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
        if [[ -z "$uuid" ]]; then
            print_error "用户不存在: $username"
            ((fail_count++))
            continue
        fi

        # 检查是否已绑定
        local already_bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
        if [[ -n "$already_bound" ]]; then
            print_info "用户 $username 已绑定，跳过"
            continue
        fi

        # 添加绑定
        local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

        if [[ -z "$binding_exists" ]]; then
            local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
            if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "创建绑定失败"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        else
            if ! jq --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "添加用户到绑定失败"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        fi

        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已绑定用户 $username"
        ((success_count++))
    done

    echo ""
    print_info "批量绑定完成：成功 $success_count 个，失败 $fail_count 个"

    if [[ $success_count -gt 0 ]]; then
        generate_xray_config
        restart_xray
        print_success "配置已更新并重启服务"
    fi
}

# 为节点移除单个用户绑定
unbind_single_user_from_node() {
    local port=$1

    echo ""
    echo -e "${YELLOW}节点端口 $port 已绑定的用户：${NC}"

    # 获取该节点的用户列表
    local users=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[]" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$users" ]]; then
        print_warning "该节点没有绑定用户"
        return 0
    fi

    # 显示用户列表
    while IFS= read -r uuid; do
        local username=$(jq -r ".users[] | select(.id == \"$uuid\") | .username" "$USERS_FILE" 2>/dev/null)
        if [[ -n "$username" ]]; then
            echo "  - $username"
        fi
    done <<< "$users"

    echo ""
    read -p "请输入要移除的用户名: " username
    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$uuid" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    # 移除绑定
    if ! jq '.bindings |= map(if .port == $port then .users |= map(select(. != $uuid)) else . end)' --arg port "$port" --arg uuid "$uuid" "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
        print_error "移除绑定失败"
        rm -f "${NODE_USERS_FILE}.tmp"
        return 1
    fi
    mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"

    generate_xray_config
    restart_xray

    print_success "用户 $username 已从端口 $port 解绑"
}

# 为节点批量移除用户绑定
batch_unbind_users_from_node() {
    local port=$1

    echo ""
    echo -e "${YELLOW}节点端口 $port 已绑定的用户：${NC}"

    # 获取该节点的用户列表
    local users=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[]" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$users" ]]; then
        print_warning "该节点没有绑定用户"
        return 0
    fi

    # 显示用户列表
    local bound_users=()
    while IFS= read -r uuid; do
        local username=$(jq -r ".users[] | select(.id == \"$uuid\") | .username" "$USERS_FILE" 2>/dev/null)
        if [[ -n "$username" ]]; then
            echo "  - $username"
            bound_users+=("$username")
        fi
    done <<< "$users"

    if [[ ${#bound_users[@]} -eq 0 ]]; then
        print_warning "该节点没有绑定用户"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}输入要移除的用户名（多个用户名用空格分隔）${NC}"
    read -p "用户名列表: " usernames

    if [[ -z "$usernames" ]]; then
        print_error "用户名列表不能为空"
        return 1
    fi

    local success_count=0
    for username in $usernames; do
        # 获取用户UUID
        local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
        if [[ -z "$uuid" ]]; then
            print_error "用户不存在: $username"
            continue
        fi

        if ! jq '.bindings |= map(if .port == $port then .users |= map(select(. != $uuid)) else . end)' --arg port "$port" --arg uuid "$uuid" "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "移除用户 $username 失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            continue
        fi
        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已移除用户 $username"
        ((success_count++))
    done

    echo ""
    print_info "批量解绑完成：成功 $success_count 个"

    if [[ $success_count -gt 0 ]]; then
        generate_xray_config
        restart_xray
        print_success "配置已更新并重启服务"
    fi
}

#================================================================
# 智能绑定/解绑函数（自动识别单个/批量）
#================================================================

# 智能为用户绑定节点（自动识别单个/批量）
bind_nodes_to_user_smart() {
    local username=$1

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)

    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo '{"bindings":[]}' > "$NODE_USERS_FILE"
    fi

    # 获取所有节点和绑定状态
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}已绑定节点：${NC}"
    echo ""
    local has_bound=false
    local bound_ports=()

    while IFS= read -r binding; do
        local port=$(echo "$binding" | jq -r '.port')
        local users=$(echo "$binding" | jq -r '.users[]')

        if echo "$users" | grep -q "$uuid"; then
            local node=$(jq -r ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
            if [[ -n "$node" && "$node" != "null" ]]; then
                local name=$(echo "$node" | jq -r '.name // "未命名"')
                local protocol=$(echo "$node" | jq -r '.protocol')
                local transport=$(echo "$node" | jq -r '.transport // "N/A"')
                local security=$(echo "$node" | jq -r '.security // "N/A"')
                local outbound_tag=$(echo "$node" | jq -r '.outbound_tag // empty')

                echo -e "  ${YELLOW}✓${NC} ${GREEN}$name${NC}"
                echo -e "    端口: ${YELLOW}$port${NC} | 协议: ${YELLOW}$protocol${NC} | 传输: ${YELLOW}$transport${NC} | 安全: ${YELLOW}$security${NC}"
                if [[ -n "$outbound_tag" ]]; then
                    echo -e "    出站: ${GREEN}$outbound_tag${NC}"
                fi
                has_bound=true
                bound_ports+=("$port")
            fi
        fi
    done < <(jq -c '.bindings[]' "$NODE_USERS_FILE" 2>/dev/null)

    if [[ "$has_bound" == "false" ]]; then
        echo -e "  ${YELLOW}无${NC}"
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}未绑定节点：${NC}"
    echo ""
    local has_unbound=false
    local node_count=0

    while IFS= read -r node; do
        ((node_count++))
        local port=$(echo "$node" | jq -r '.port')
        local name=$(echo "$node" | jq -r '.name // "未命名"')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local transport=$(echo "$node" | jq -r '.transport // "N/A"')
        local security=$(echo "$node" | jq -r '.security // "N/A"')
        local outbound_tag=$(echo "$node" | jq -r '.outbound_tag // empty')

        # 检查是否已绑定
        local is_bound=false
        for bound_port in "${bound_ports[@]}"; do
            if [[ "$bound_port" == "$port" ]]; then
                is_bound=true
                break
            fi
        done

        if [[ "$is_bound" == "false" ]]; then
            echo -e "  ${CYAN}[$node_count]${NC} ${YELLOW}$name${NC}"
            echo -e "      端口: ${YELLOW}$port${NC} | 协议: ${YELLOW}$protocol${NC} | 传输: ${YELLOW}$transport${NC} | 安全: ${YELLOW}$security${NC}"
            if [[ -n "$outbound_tag" ]]; then
                echo -e "      出站: ${GREEN}$outbound_tag${NC}"
            fi
            has_unbound=true
        fi
    done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)

    if [[ "$has_unbound" == "false" ]]; then
        echo -e "  ${YELLOW}无${NC}"
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        print_info "所有节点都已绑定"
        return 0
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}请输入节点序号或端口（单个或多个用空格分隔）${NC}"
    read -p "输入: " inputs

    if [[ -z "$inputs" ]]; then
        print_error "输入不能为空"
        return 1
    fi

    local success_count=0
    local fail_count=0
    local skip_count=0

    for input in $inputs; do
        local port=""

        # 判断是序号还是端口
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            # 是数字，判断是序号还是端口
            # 检查是否为有效序号（必须>=1且在节点总数范围内）
            local total_nodes=$(jq '.nodes | length' "$NODES_FILE" 2>/dev/null)

            if [[ "$input" -ge 1 && "$input" -le "$total_nodes" ]]; then
                # 可能是序号，尝试获取端口
                local temp_port=$(jq -r ".nodes[$((input-1))].port" "$NODES_FILE" 2>/dev/null)

                if [[ -n "$temp_port" && "$temp_port" != "null" ]]; then
                    # 检查这个节点是否在未绑定列表中
                    local is_unbound=false
                    for bound_port in "${bound_ports[@]}"; do
                        if [[ "$bound_port" == "$temp_port" ]]; then
                            is_unbound=false
                            break
                        fi
                        is_unbound=true
                    done

                    # 如果bound_ports为空，说明没有已绑定节点，所有都是未绑定
                    if [[ ${#bound_ports[@]} -eq 0 ]]; then
                        is_unbound=true
                    else
                        # 需要重新检查
                        is_unbound=true
                        for bound_port in "${bound_ports[@]}"; do
                            if [[ "$bound_port" == "$temp_port" ]]; then
                                is_unbound=false
                                break
                            fi
                        done
                    fi

                    if [[ "$is_unbound" == "true" ]]; then
                        port="$temp_port"
                    else
                        # 已绑定的节点，不应该用序号访问，当作端口处理
                        port="$input"
                    fi
                else
                    # 不是有效序号，当作端口处理
                    port="$input"
                fi
            else
                # 超出序号范围或为0，当作端口处理
                port="$input"
            fi
        else
            port="$input"
        fi

        # 检查节点是否存在
        local node_exists=$(jq -r ".nodes[] | select(.port == \"$port\") | .port" "$NODES_FILE" 2>/dev/null)
        if [[ -z "$node_exists" || "$node_exists" == "null" ]]; then
            print_error "节点不存在: $input (解析为端口: $port)"
            ((fail_count++))
            continue
        fi

        # 检查是否已绑定
        local already_bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
        if [[ -n "$already_bound" ]]; then
            print_info "端口 $port 已绑定，跳过"
            ((skip_count++))
            continue
        fi

        # 添加绑定
        local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

        if [[ -z "$binding_exists" ]]; then
            local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
            if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "创建绑定失败"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        else
            if ! jq --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "添加用户到绑定失败"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        fi

        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已绑定到端口 $port"
        ((success_count++))
    done

    echo ""
    if [[ $success_count -gt 0 || $skip_count -gt 0 || $fail_count -gt 0 ]]; then
        print_info "操作完成：成功 $success_count 个，跳过 $skip_count 个，失败 $fail_count 个"
    fi

    if [[ $success_count -gt 0 ]]; then
        generate_xray_config
        restart_xray
        print_success "配置已更新并重启服务"
    fi
}

# 智能为用户解绑节点（自动识别单个/批量）
unbind_nodes_from_user_smart() {
    local username=$1

    # 获取用户UUID
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)

    # Display bound nodes section with details
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}用户 ${YELLOW}$username${CYAN} 已绑定的节点：${NC}"
    echo ""

    local bound_nodes=()
    local node_index=0

    while IFS= read -r binding; do
        local port=$(echo "$binding" | jq -r '.port')
        local users=$(echo "$binding" | jq -r '.users[]')

        if echo "$users" | grep -q "$uuid"; then
            # 获取节点详细信息
            local node=$(jq -r ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
            if [[ -n "$node" && "$node" != "null" ]]; then
                ((node_index++))
                local name=$(echo "$node" | jq -r '.name // "未命名"')
                local protocol=$(echo "$node" | jq -r '.protocol // "unknown"')
                local transport=$(echo "$node" | jq -r '.transport // "N/A"')
                local security=$(echo "$node" | jq -r '.security // "N/A"')
                local outbound_tag=$(echo "$node" | jq -r '.outbound_tag // empty')

                echo -e "  ${CYAN}[$node_index]${NC} ${YELLOW}$name${NC}"
                echo -e "      端口: ${YELLOW}$port${NC} | 协议: ${YELLOW}$protocol${NC} | 传输: ${YELLOW}$transport${NC} | 安全: ${YELLOW}$security${NC}"
                if [[ -n "$outbound_tag" ]]; then
                    echo -e "      出站: ${GREEN}$outbound_tag${NC}"
                fi
                bound_nodes+=("$port")
            fi
        fi
    done < <(jq -c '.bindings[]' "$NODE_USERS_FILE" 2>/dev/null)

    if [[ ${#bound_nodes[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}暂无${NC}"
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        print_info "用户未绑定任何节点"
        return 0
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}请输入要移除的节点序号或端口（单个或多个用空格分隔）${NC}"
    read -p "输入: " inputs

    if [[ -z "$inputs" ]]; then
        print_error "输入不能为空"
        return 1
    fi

    local success_count=0
    local fail_count=0

    for input in $inputs; do
        local port=""

        # 判断是序号还是端口
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            # 是数字，判断是序号还是端口
            if [[ "$input" -ge 1 && "$input" -le "${#bound_nodes[@]}" ]]; then
                # 是有效序号
                port="${bound_nodes[$((input-1))]}"
            else
                # 不是有效序号，当作端口处理
                port="$input"
            fi
        else
            port="$input"
        fi

        # 检查该端口是否在已绑定列表中
        local is_bound=false
        for bound_port in "${bound_nodes[@]}"; do
            if [[ "$bound_port" == "$port" ]]; then
                is_bound=true
                break
            fi
        done

        if [[ "$is_bound" == "false" ]]; then
            print_error "节点未绑定或不存在: $input (解析为端口: $port)"
            ((fail_count++))
            continue
        fi

        # 解绑操作
        if ! jq '.bindings |= map(if .port == $port then .users |= map(select(. != $uuid)) else . end)' --arg port "$port" --arg uuid "$uuid" "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "从节点 (端口 $port) 解绑失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            continue
        fi
        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已从节点 (端口 $port) 解绑"
        ((success_count++))
    done

    echo ""
    if [[ $success_count -gt 0 || $fail_count -gt 0 ]]; then
        print_info "操作完成：成功 $success_count 个，失败 $fail_count 个"
    fi

    if [[ $success_count -gt 0 ]]; then
        generate_xray_config
        restart_xray
        print_success "配置已更新并重启服务"
    fi
}

# 智能为节点绑定用户（自动识别单个/批量）
bind_users_to_node_smart() {
    local port=$1

    # 获取已绑定到此节点的用户UUID列表
    local bound_uuids=()
    while IFS= read -r uuid; do
        [[ -n "$uuid" && "$uuid" != "null" ]] && bound_uuids+=("$uuid")
    done < <(jq -r ".bindings[] | select(.port == \"$port\") | .users[]?" "$NODE_USERS_FILE" 2>/dev/null)

    # Display bound users section
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}已绑定用户：${NC}"
    local has_bound=false

    if [[ ${#bound_uuids[@]} -gt 0 ]]; then
        for uuid in "${bound_uuids[@]}"; do
            local user=$(jq -r ".users[] | select(.id == \"$uuid\")" "$USERS_FILE" 2>/dev/null)
            if [[ -n "$user" && "$user" != "null" ]]; then
                local username=$(echo "$user" | jq -r '.username')
                local email=$(echo "$user" | jq -r '.email // "无邮箱"')
                echo -e "  ${YELLOW}✓${NC} ${GREEN}$username${NC} ($email)"
                has_bound=true
            fi
        done
    fi

    [[ "$has_bound" == "false" ]] && echo -e "  ${YELLOW}暂无${NC}"

    # Display unbound users section
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}未绑定用户：${NC}"
    local unbound_user_index=0
    local has_unbound=false

    # Store unbound users with their usernames for index lookup
    declare -a unbound_usernames=()

    while IFS= read -r user; do
        local username=$(echo "$user" | jq -r '.username')
        local uuid=$(echo "$user" | jq -r '.id')
        local email=$(echo "$user" | jq -r '.email // "无邮箱"')

        # Check if already bound
        local is_bound=false
        for bound_uuid in "${bound_uuids[@]}"; do
            if [[ "$bound_uuid" == "$uuid" ]]; then
                is_bound=true
                break
            fi
        done

        if [[ "$is_bound" == "false" ]]; then
            ((unbound_user_index++))
            echo -e "  ${CYAN}[$unbound_user_index]${NC} ${YELLOW}$username${NC} ($email)"
            unbound_usernames+=("$username")
            has_unbound=true
        fi
    done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

    [[ "$has_unbound" == "false" ]] && echo -e "  ${YELLOW}暂无${NC}"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Smart input handling - accept both index and username
    echo ""
    echo -e "${YELLOW}请输入用户序号或用户名（单个或多个用空格分隔）${NC}"
    read -p "输入: " inputs

    if [[ -z "$inputs" ]]; then
        print_error "输入不能为空"
        return 1
    fi

    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo '{"bindings":[]}' > "$NODE_USERS_FILE"
    fi

    local success_count=0
    local fail_count=0
    local skip_count=0

    for input in $inputs; do
        local username=""
        local uuid=""

        # Detect if input is index or username
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            # Input is a number - check if it's a valid unbound user index
            if [[ "$input" -ge 1 && "$input" -le "${#unbound_usernames[@]}" ]]; then
                # Valid index in unbound users list
                username="${unbound_usernames[$((input-1))]}"
            else
                # Not a valid index, treat as username
                username="$input"
            fi
        else
            # Input is username
            username="$input"
        fi

        # Get UUID from username
        uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)

        if [[ -z "$uuid" || "$uuid" == "null" ]]; then
            print_error "用户不存在: $username"
            ((fail_count++))
            continue
        fi

        # Check if already bound
        local already_bound=false
        for bound_uuid in "${bound_uuids[@]}"; do
            if [[ "$bound_uuid" == "$uuid" ]]; then
                already_bound=true
                break
            fi
        done

        if [[ "$already_bound" == "true" ]]; then
            print_info "用户 $username 已绑定，跳过"
            ((skip_count++))
            continue
        fi

        # Add binding
        local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

        if [[ -z "$binding_exists" || "$binding_exists" == "null" ]]; then
            # Create new binding entry
            local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
            if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "Failed to create binding"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        else
            # Append to existing binding
            if ! jq --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
                print_error "Failed to add user to binding"
                rm -f "${NODE_USERS_FILE}.tmp"
                continue
            fi
        fi

        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已绑定用户 $username"
        ((success_count++))

        # Add to bound list for next iteration
        bound_uuids+=("$uuid")
    done

    echo ""
    if [[ $success_count -gt 0 || $skip_count -gt 0 || $fail_count -gt 0 ]]; then
        print_info "操作完成：成功 $success_count 个，跳过 $skip_count 个，失败 $fail_count 个"
    fi

    if [[ $success_count -gt 0 ]]; then
        generate_xray_config
        restart_xray
        print_success "配置已更新并重启服务"
    fi
}

# 智能为节点解绑用户（自动识别单个/批量）
unbind_users_from_node_smart() {
    local port=$1

    echo ""
    echo -e "${YELLOW}节点端口 $port 已绑定的用户：${NC}"

    # 获取该节点的用户列表
    local users=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[]" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$users" ]]; then
        print_warning "该节点没有绑定用户"
        return 0
    fi

    # 显示用户列表
    local bound_users=()
    while IFS= read -r uuid; do
        local username=$(jq -r ".users[] | select(.id == \"$uuid\") | .username" "$USERS_FILE" 2>/dev/null)
        if [[ -n "$username" ]]; then
            echo "  - $username"
            bound_users+=("$username")
        fi
    done <<< "$users"

    if [[ ${#bound_users[@]} -eq 0 ]]; then
        print_warning "该节点没有绑定用户"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}请输入要移除的用户名（单个或多个用空格分隔）${NC}"
    read -p "用户名: " usernames

    if [[ -z "$usernames" ]]; then
        print_error "用户名列表不能为空"
        return 1
    fi

    local success_count=0
    local fail_count=0

    for username in $usernames; do
        # 获取用户UUID
        local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
        if [[ -z "$uuid" ]]; then
            print_error "用户不存在: $username"
            ((fail_count++))
            continue
        fi

        if ! jq '.bindings |= map(if .port == $port then .users |= map(select(. != $uuid)) else . end)' --arg port "$port" --arg uuid "$uuid" "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp"; then
            print_error "移除用户 $username 失败"
            rm -f "${NODE_USERS_FILE}.tmp"
            continue
        fi
        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
        print_success "已移除用户 $username"
        ((success_count++))
    done

    echo ""
    if [[ $success_count -gt 0 || $fail_count -gt 0 ]]; then
        print_info "操作完成：成功 $success_count 个，失败 $fail_count 个"
    fi

    if [[ $success_count -gt 0 ]]; then
        generate_xray_config
        restart_xray
        print_success "配置已更新并重启服务"
    fi
}
