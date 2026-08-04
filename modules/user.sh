#!/bin/bash

#================================================================
# 用户管理模块
# 功能：添加、删除、查看、修改用户，UUID生成
#================================================================

# 检查用户邮箱是否已存在
check_email_exists() {
    local email=$1
    local port=$2  # 可选参数，指定节点端口

    if [[ -z "$email" ]]; then
        return 1
    fi

    if [[ ! -f "$USERS_FILE" ]]; then
        return 1  # 用户文件不存在，邮箱可用
    fi

    # 如果指定了端口，检查该节点下是否存在该邮箱
    if [[ -n "$port" ]]; then
        local existing=$(jq -r ".users[] | select(.port == \"$port\" and .email == \"$email\") | .email" "$USERS_FILE" 2>/dev/null)
    else
        # 全局检查（任意节点）
        local existing=$(jq -r ".users[] | select(.email == \"$email\") | .email" "$USERS_FILE" 2>/dev/null)
    fi

    if [[ -n "$existing" ]]; then
        return 0  # 邮箱已存在
    fi

    return 1  # 邮箱可用
}

# 生成 UUID
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# 初始化默认admin用户
init_admin_user() {
    # 确保用户文件存在
    if [[ ! -f "$USERS_FILE" ]]; then
        echo '{"users":[]}' > "$USERS_FILE"
    fi

    # 检查是否已存在admin用户
    local admin_exists=$(jq -r '.users[] | select(.username == "admin") | .username' "$USERS_FILE" 2>/dev/null)

    if [[ -n "$admin_exists" ]]; then
        # admin用户已存在，不需要初始化
        return 0
    fi

    # 创建admin用户
    local admin_uuid=$(generate_uuid)
    local admin_password=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)
    local admin_email="admin@system"  # 保持邮箱格式

    local admin_data=$(jq -n \
        --arg id "$admin_uuid" \
        --arg username "admin" \
        --arg password "$admin_password" \
        --arg email "$admin_email" \
        '{id: $id, username: $username, password: $password, email: $email, level: 0, traffic_limit_gb: "unlimited", traffic_used_gb: "0", expire_date: "unlimited", created: (now|todate), enabled: true}')

    jq --argjson admin_data "$admin_data" '.users += [$admin_data]' "$USERS_FILE" > "${USERS_FILE}.tmp"
    mv "${USERS_FILE}.tmp" "$USERS_FILE"

    print_success "默认admin用户初始化成功"
    echo -e "${CYAN}Admin用户信息：${NC}"
    echo -e "  用户名: ${YELLOW}admin${NC}"
    echo -e "  密码: ${YELLOW}$admin_password${NC}"
    echo -e "  UUID: ${YELLOW}$admin_uuid${NC}"
    echo -e "  邮箱: ${YELLOW}$admin_email${NC}"
    echo -e "${YELLOW}请妥善保存admin密码！${NC}"
    echo ""
}

# 显示全局用户列表（新架构）
list_global_users() {
    if [[ ! -f "$USERS_FILE" ]]; then
        print_warning "用户文件不存在"
        return 1
    fi

    local user_count=$(jq '.users | length' "$USERS_FILE" 2>/dev/null)
    if [[ $user_count -eq 0 ]]; then
        print_warning "没有用户"
        return 0
    fi

    if declare -f refresh_connection_snapshot >/dev/null 2>&1; then
        refresh_connection_snapshot || CONNECTION_SNAPSHOT_JSON=""
    fi

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    # 表头：镂空设计，移除右边框
    echo -e "${CYAN}║${NC} 用户名      密码              邮箱                  UUID                                  状态    在线状态"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"

    while IFS= read -r user; do
        local username=$(echo "$user" | jq -r '.username // "未设置"')
        local password=$(echo "$user" | jq -r '.password // "无"')
        local email=$(echo "$user" | jq -r 'if .email == "" or .email == null then "未设置" else .email end')
        local uuid=$(echo "$user" | jq -r '.id')
        local enabled=$(echo "$user" | jq -r 'if .enabled == true then "true" else "false" end')

        # 截断处理
        local display_username="$username"
        if [[ ${#username} -gt 10 ]]; then
            display_username="${username:0:8}.."
        fi

        local display_password="$password"
        if [[ ${#password} -gt 16 ]]; then
            display_password="${password:0:14}.."
        fi

        local display_email="$email"
        if [[ ${#email} -gt 20 ]]; then
            display_email="${email:0:18}.."
        fi

        local display_uuid="$uuid"

        # 状态（纯文本，用于对齐计算）
        local status_text=""
        local status_display=""
        if [[ "$enabled" == "true" ]]; then
            status_text="启用"
            status_display="${GREEN}启用${NC}"
        else
            status_text="禁用"
            status_display="${RED}禁用${NC}"
        fi

        # 获取在线状态
        local online_text=""
        local online_display=""
        if [[ "$enabled" == "true" ]]; then
            local port=$(get_user_first_port "$uuid")
            if [[ -n "$port" ]]; then
                local user_status=$(get_user_online_status "$uuid")
                case $user_status in
                    online)
                        online_text="在线"
                        online_display="${GREEN}在线${NC}"
                        ;;
                    offline)
                        online_text="离线"
                        online_display="${YELLOW}离线${NC}"
                        ;;
                    unavailable)
                        online_text="不可用"
                        online_display="${GRAY}不可用${NC}"
                        ;;
                    *)
                        online_text="未知"
                        online_display="${GRAY}未知${NC}"
                        ;;
                esac
            else
                online_text="未绑定"
                online_display="${GRAY}未绑定${NC}"
            fi
        else
            online_text="已禁用"
            online_display="${GRAY}已禁用${NC}"
        fi

        # 计算显示宽度（中文字符每个占2宽度）
        # 使用bash内置的字符串长度计算
        local status_char_count=${#status_text}
        # 对于纯中文，显示宽度 = 字符数 × 2
        local status_display_width=$((status_char_count * 2))
        local status_spaces=$((6 - status_display_width))
        # 防止负数
        [[ $status_spaces -lt 0 ]] && status_spaces=0

        local online_char_count=${#online_text}
        local online_display_width=$((online_char_count * 2))
        local online_spaces=$((8 - online_display_width))
        # 防止负数
        [[ $online_spaces -lt 0 ]] && online_spaces=0

        # 生成填充空格字符串
        local status_padding=$(printf '%*s' "$status_spaces" "")
        local online_padding=$(printf '%*s' "$online_spaces" "")

        # 手动构建对齐的输出（移除右边框，保持镂空）
        printf "${CYAN}║${NC} %-10s  %-16s  %-20s  %-36s  %b%s  %b%s\n" \
            "$display_username" "$display_password" "$display_email" "$display_uuid" \
            "$status_display" "$status_padding" "$online_display" "$online_padding"
    done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}总计: ${user_count} 个用户${NC}"
}

# 添加全局用户（新架构）
add_global_user() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      添加全局用户"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 输入用户名
    read -p "请输入用户名: " username
    while [[ -z "$username" ]]; do
        print_error "用户名不能为空"
        read -p "请输入用户名: " username
    done
    if [[ ! "$username" =~ ^[A-Za-z0-9._@-]+$ ]]; then
        print_error "用户名只能包含字母、数字、点、下划线、@ 和连字符"
        return 1
    fi

    # 检查用户名是否已存在
    if [[ -f "$USERS_FILE" ]]; then
        local existing_username=$(jq -r --arg username "$username" '.users[] | select(.username == $username) | .username' "$USERS_FILE" 2>/dev/null)
        if [[ -n "$existing_username" ]]; then
            print_error "用户名 '$username' 已存在"
            return 1
        fi
    fi

    # 输入密码
    read -p "请输入密码 [留空自动生成]: " password
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)
        print_info "自动生成密码: $password"
    fi
    if [[ "$password" == *$'\n'* || "$password" == *$'\r'* ]]; then
        print_error "密码不能包含换行符"
        return 1
    fi

    # 生成UUID（自动，不再询问用户）
    uuid=$(generate_uuid)

    # 输入邮箱（可选）
    read -p "请输入用户邮箱/备注 [可选]: " email
    if [[ -z "$email" ]]; then
        email="${username}@local"  # 默认使用username@local
    fi

    # 设置用户等级
    read -p "请输入用户等级 [默认: 0]: " level
    level=${level:-0}
    [[ "$level" =~ ^[0-9]+$ ]] || { print_error "用户等级必须是非负整数"; return 1; }

    # 设置流量限制
    read -p "请输入流量限制(GB) [留空表示无限制]: " traffic_limit_gb
    traffic_limit_gb=${traffic_limit_gb:-unlimited}
    [[ "$traffic_limit_gb" == unlimited || "$traffic_limit_gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || { print_error "流量限制必须是数字或 unlimited"; return 1; }

    # 设置有效期
    read -p "请输入有效期(天数) [留空表示无限制]: " expire_days
    if [[ -n "$expire_days" && "$expire_days" != "unlimited" ]]; then
        [[ "$expire_days" =~ ^[1-9][0-9]*$ ]] || { print_error "有效期必须是正整数天数"; return 1; }
        expire_date=$(date -d "+${expire_days} days" '+%Y-%m-%d' 2>/dev/null || date -v+${expire_days}d '+%Y-%m-%d')
    else
        expire_date="unlimited"
    fi

    # 保存到全局用户文件
    if [[ ! -f "$USERS_FILE" ]]; then
        echo '{"users":[]}' > "$USERS_FILE"
    fi

    # 使用 --arg 代替 --argjson，在 jq 表达式中转换类型
    local user_data=$(jq -n \
        --arg id "$uuid" \
        --arg username "$username" \
        --arg password "$password" \
        --arg email "$email" \
        --arg level "$level" \
        --arg traffic_limit "$traffic_limit_gb" \
        --arg traffic_used "0" \
        --arg expire "$expire_date" \
        '{id: $id, username: $username, password: $password, email: $email, level: ($level|tonumber), traffic_limit_gb: $traffic_limit, traffic_used_gb: $traffic_used, expire_date: $expire, created: (now|todate), enabled: true}')

    local users_data
    users_data=$(jq --argjson user_data "$user_data" '.users += [$user_data]' "$USERS_FILE") || return 1
    atomic_write_json "$USERS_FILE" "$users_data" || return 1
    if ! commit_data_transaction; then
        rollback_data_transaction
        print_error "用户已写入但运行时快照提交失败，新增操作已回滚"
        return 1
    fi

    print_success "全局用户添加成功！"
    echo ""
    echo -e "${CYAN}用户信息：${NC}"
    echo -e "  用户名: ${YELLOW}$username${NC}"
    echo -e "  密码: ${YELLOW}$password${NC}"
    echo -e "  UUID: ${YELLOW}$uuid${NC}"
    echo -e "  邮箱: ${YELLOW}$email${NC}"
    echo -e "  等级: ${YELLOW}$level${NC}"
    echo -e "  流量限制: ${YELLOW}$traffic_limit_gb GB${NC}"
    echo -e "  有效期: ${YELLOW}$expire_date${NC}"
    echo ""

    # 询问是否绑定到节点
    read -p "是否立即绑定到节点? [y/N]: " bind_now
    if [[ "$bind_now" == "y" || "$bind_now" == "Y" ]]; then
        bind_user_to_node "$username"
    fi
}

# 显示用户详情（包含绑定节点）
show_user_detail() {
    local username=$1

    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      用户详情"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 获取用户信息
    local user=$(jq -r ".users[] | select(.username == \"$username\")" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$user" || "$user" == "null" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    local uuid=$(echo "$user" | jq -r '.id')
    local password=$(echo "$user" | jq -r '.password // "无"')
    local email=$(echo "$user" | jq -r 'if .email == "" or .email == null then "未设置" else .email end')
    local level=$(echo "$user" | jq -r '.level // 0')
    local enabled=$(echo "$user" | jq -r 'if .enabled == true then "true" else "false" end')
    local created=$(echo "$user" | jq -r '.created // "未知"')
    local traffic_limit=$(echo "$user" | jq -r '.traffic_limit_gb // "unlimited"')
    local expire_date=$(echo "$user" | jq -r '.expire_date // "unlimited"')

    # 实时更新流量使用情况；缺少 Stats API 时明确显示不可用。
    local traffic_used
    if declare -f singbox_has_stats_capability >/dev/null 2>&1 \
        && ! singbox_has_stats_capability; then
        traffic_used="数据不可用"
    else
        echo -e "${GRAY}正在获取实时流量统计...${NC}"
        local updated_gb
        updated_gb=$(update_user_traffic_usage "$uuid" 2>/dev/null)
        if [[ $? -eq 0 && -n "$updated_gb" ]]; then
            traffic_used="${updated_gb} GB"
            commit_data_transaction || print_warning "流量账本已更新，但最后可用快照同步失败"
        else
            # Stats API 临时不可达时显示旧账本值，并明确标记不是实时数据。
            traffic_used="$(echo "$user" | jq -r '.traffic_used_gb // "0"') GB（缓存）"
        fi
    fi

    local status_text=""
    if [[ "$enabled" == "true" ]]; then
        status_text="${GREEN}启用${NC}"
    else
        status_text="${RED}禁用${NC}"
    fi

    echo -e "${GREEN}基本信息：${NC}"
    echo -e "  用户名: ${YELLOW}$username${NC}"
    echo -e "  密码: ${YELLOW}$password${NC}"
    echo -e "  邮箱: ${YELLOW}$email${NC}"
    echo -e "  UUID: ${YELLOW}$uuid${NC}"
    echo -e "  等级: ${YELLOW}$level${NC}"
    echo -e "  状态: $status_text"
    echo -e "  创建时间: ${YELLOW}${created:0:19}${NC}"
    echo ""
    echo -e "${GREEN}流量与有效期：${NC}"
    echo -e "  流量限制: ${YELLOW}$traffic_limit GB${NC}"
    echo -e "  已用流量: ${YELLOW}$traffic_used${NC}"
    echo -e "  有效期至: ${YELLOW}$expire_date${NC}"
    echo ""

    # 显示绑定的节点
    echo -e "${GREEN}绑定节点：${NC}"
    local node_found=false

    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo -e "  ${YELLOW}未绑定任何节点${NC}"
    else
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
                local transport=$(echo "$node" | jq -r '.transport // "未知"')
                local security=$(echo "$node" | jq -r '.security // "未知"')
                local outbound_tag=$(echo "$node" | jq -r '.outbound_tag // empty')

                echo -e "  ${CYAN}•${NC} $name"
                echo -e "    端口: ${YELLOW}$port${NC} | 协议: ${YELLOW}$protocol${NC}"
                echo -e "    传输: ${YELLOW}$transport${NC} | 安全: ${YELLOW}$security${NC}"
                if [[ -n "$outbound_tag" ]]; then
                    echo -e "    出站: ${GREEN}$outbound_tag${NC}"
                fi
            fi
        done < <(jq -c '.bindings[]' "$NODE_USERS_FILE" 2>/dev/null)

        if [[ "$node_found" == "false" ]]; then
            echo -e "  ${YELLOW}未绑定任何节点${NC}"
        fi
    fi
    echo ""
}

# 删除单个用户（新增函数）
delete_single_user() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      删除用户"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    list_global_users

    echo ""
    read -p "请输入要删除的用户名: " username
    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 检查用户是否存在
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    # 警告
    echo ""
    print_warning "删除用户将同时清理所有节点绑定关系和订阅链接"
    read -p "确认删除用户 $username? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消删除"
        return 0
    fi

    begin_data_transaction || return 1
    remove_user_subscriptions_by_id "$uuid" || { rollback_data_transaction; print_error "清理订阅失败"; return 1; }

    # 2. 从所有节点解绑
    if [[ -f "$NODE_USERS_FILE" ]]; then
        local tmp_file="${NODE_USERS_FILE}.tmp"
        if ! jq --arg uuid "$uuid" '(.bindings[].users) |= map(select(. != $uuid))' "$NODE_USERS_FILE" > "$tmp_file" || ! mv "$tmp_file" "$NODE_USERS_FILE"; then
            print_error "清理节点绑定关系失败"
            rm -f "$tmp_file"
            rollback_data_transaction
            return 1
        fi
        print_info "已清理节点绑定关系"
    fi

    # 3. 从全局用户列表删除
    local tmp_file="${USERS_FILE}.tmp"
    if ! jq --arg uuid "$uuid" '.users = [.users[] | select(.id != $uuid)]' "$USERS_FILE" > "$tmp_file" || ! mv "$tmp_file" "$USERS_FILE"; then
        print_error "删除用户失败"
        rm -f "$tmp_file"
        rollback_data_transaction
        return 1
    fi

    print_success "用户删除成功"

    if ! generate_singbox_config || ! restart_sing-box; then
        print_error "删除用户后的配置应用失败，数据和订阅已回滚"
        return 1
    fi

    print_success "配置已更新并重启服务"
}

# 删除全局用户（新架构）
delete_global_user() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      删除全局用户"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    list_global_users

    echo ""
    read -p "请输入要删除的用户名: " username
    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 检查用户是否存在
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        print_error "用户不存在: $username"
        return 1
    fi

    # 警告
    echo ""
    print_warning "删除用户将同时清理所有节点绑定关系和订阅链接"
    read -p "确认删除用户 $username? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消删除"
        return 0
    fi

    begin_data_transaction || return 1
    remove_user_subscriptions_by_id "$uuid" || { rollback_data_transaction; print_error "清理订阅失败"; return 1; }

    # 2. 从所有节点解绑
    if [[ -f "$NODE_USERS_FILE" ]]; then
        local tmp_file="${NODE_USERS_FILE}.tmp"
        if ! jq --arg uuid "$uuid" '(.bindings[].users) |= map(select(. != $uuid))' "$NODE_USERS_FILE" > "$tmp_file" || ! mv "$tmp_file" "$NODE_USERS_FILE"; then
            print_error "清理节点绑定关系失败"
            rm -f "$tmp_file"
            rollback_data_transaction
            return 1
        fi
        print_info "已清理节点绑定关系"
    fi

    # 3. 从全局用户列表删除
    local tmp_file="${USERS_FILE}.tmp"
    if ! jq --arg uuid "$uuid" '.users = [.users[] | select(.id != $uuid)]' "$USERS_FILE" > "$tmp_file" || ! mv "$tmp_file" "$USERS_FILE"; then
        print_error "删除用户失败"
        rm -f "$tmp_file"
        rollback_data_transaction
        return 1
    fi

    print_success "用户删除成功"

    if ! generate_singbox_config || ! restart_sing-box; then
        print_error "删除用户后的配置应用失败，数据和订阅已回滚"
        return 1
    fi

    print_success "配置已更新并重启服务"
}

# 添加用户
add_user() {
    clear
    echo -e "${CYAN}====== 添加用户 ======${NC}"

    # 显示可用节点
    print_info "当前可用节点："
    list_nodes true

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

    # 获取节点协议
    local node_protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE" 2>/dev/null)

    read -p "请输入用户邮箱/备注: " email
    while [[ -z "$email" ]]; do
        print_error "邮箱不能为空"
        read -p "请输入用户邮箱/备注: " email
    done

    # 检查邮箱是否已存在（仅检查当前节点）
    if check_email_exists "$email" "$port"; then
        print_error "用户邮箱 '$email' 在端口 $port 上已存在"
        return 1
    fi

    # 根据协议生成用户配置
    case $node_protocol in
        vless|vmess)
            read -p "请输入UUID [留空自动生成]: " uuid
            if [[ -z "$uuid" ]]; then
                uuid=$(generate_uuid)
                print_info "自动生成 UUID: $uuid"
            fi

            read -p "请输入用户等级 [默认: 0]: " level
            level=${level:-0}

            add_user_to_node "$port" "$node_protocol" "$uuid" "$email" "$level"
            ;;

        trojan|shadowsocks)
            read -p "请输入密码: " password
            while [[ -z "$password" ]]; do
                print_error "密码不能为空"
                read -p "请输入密码: " password
            done

            add_user_to_node "$port" "$node_protocol" "$password" "$email" "0"
            ;;

        *)
            print_error "不支持的协议"
            return 1
            ;;
    esac

    # 保存用户信息
    save_user_info "$port" "$node_protocol" "${uuid:-$password}" "$email"

    restart_sing-box
    print_success "用户添加成功！"
}


# 添加用户到节点配置
add_user_to_node() {
    local port=$1
    local protocol=$2
    local id=$3
    local email=$4
    local level=$5

    # sing-box 用户由 users.json + node_users.json 单一数据源生成，禁止直接修改 config.json。
    generate_singbox_config
}


# 保存用户信息到数据库
save_user_info() {
    local port=$1
    local protocol=$2
    local id=$3
    local email=$4

    local user_data=$(jq -n \
        --arg port "$port" \
        --arg protocol "$protocol" \
        --arg id "$id" \
        --arg email "$email" \
        '{port: $port, protocol: $protocol, id: $id, email: $email, created: now|todate}')

    jq --argjson user_data "$user_data" '.users += [$user_data]' "$USERS_FILE" > "${USERS_FILE}.tmp"
    mv "${USERS_FILE}.tmp" "$USERS_FILE"
}


# 更新用户邮箱
update_user_email() {
    local port=$1
    local old_email=$2
    local new_email=$3

    # 更新数据库
    if ! jq "(.users[] | select(.port == \"$port\" and .email == \"$old_email\") | .email) = \"$new_email\"" "$USERS_FILE" > "${USERS_FILE}.tmp"; then
        print_error "更新数据库邮箱失败"
        rm -f "${USERS_FILE}.tmp"
        return 1
    fi
    mv "${USERS_FILE}.tmp" "$USERS_FILE"
    generate_singbox_config
}

# 更新用户ID
update_user_id() {
    local port=$1
    local email=$2
    local new_id=$3

    # 更新数据库
    if ! jq "(.users[] | select(.port == \"$port\" and .email == \"$email\") | .id) = \"$new_id\"" "$USERS_FILE" > "${USERS_FILE}.tmp"; then
        print_error "更新数据库ID失败"
        rm -f "${USERS_FILE}.tmp"
        return 1
    fi
    mv "${USERS_FILE}.tmp" "$USERS_FILE"
    generate_singbox_config
}

# 更新用户等级
update_user_level() {
    local port=$1
    local email=$2
    local new_level=$3

    local data
    data=$(jq --arg email "$email" --argjson level "$new_level" '(.users[] | select((.email // .username)==$email) | .level)=$level' "$USERS_FILE") || return 1
    atomic_write_json "$USERS_FILE" "$data" && generate_singbox_config
}

#================================================================
# 用户在线状态检测
#================================================================

# 获取用户绑定的第一个节点端口
get_user_first_port() {
    local uuid=$1

    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo ""
        return
    fi

    # 查找包含该用户的第一个节点
    local port=$(jq -r ".bindings[] | select(.users[] == \"$uuid\") | .port" "$NODE_USERS_FILE" 2>/dev/null | head -n 1)
    echo "$port"
}

# 获取用户绑定的所有节点端口
get_user_all_ports() {
    local uuid=$1

    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo ""
        return
    fi

    # 查找包含该用户的所有节点端口
    local ports=$(jq -r ".bindings[] | select(.users[] == \"$uuid\") | .port" "$NODE_USERS_FILE" 2>/dev/null)
    echo "$ports"
}

# 更新所有用户的流量使用情况
update_all_users_traffic() {
    if [[ ! -f "$USERS_FILE" ]]; then
        return
    fi

    if declare -f singbox_has_stats_capability >/dev/null 2>&1 \
        && ! singbox_has_stats_capability; then
        print_warning "当前内核未启用 with_v2ray_api，无法更新用户流量统计"
        print_info "节点创建与代理功能不受影响；可在 sing-box 管理中更新/修复内核"
        return 0
    fi

    echo -e "${CYAN}正在更新所有用户流量统计...${NC}"

    local updated_count=0
    local total_count=$(jq '.users | length' "$USERS_FILE" 2>/dev/null)

    while IFS= read -r user; do
        local uuid=$(echo "$user" | jq -r '.id')
        local username=$(echo "$user" | jq -r '.username // "未知"')

        # 更新该用户的流量
        local used_gb update_status
        used_gb=$(update_user_traffic_usage "$uuid")
        update_status=$?

        if [[ $update_status -eq 0 && -n "$used_gb" ]]; then
            echo -e "  ${GREEN}✓${NC} $username: ${used_gb} GB"
            ((updated_count++))
        else
            echo -e "  ${GRAY}○${NC} $username: 无法获取"
        fi
    done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

    echo ""
    echo -e "${GREEN}已更新 $updated_count/$total_count 个用户的流量统计${NC}"
}

# 检查用户有效期（如果过期则禁用）
check_user_expiration() {
    if [[ ! -f "$USERS_FILE" ]]; then
        return
    fi

    echo -e "${CYAN}检查用户有效期...${NC}"

    local disabled_count=0
    local today=$(date '+%Y-%m-%d')

    while IFS= read -r user; do
        local uuid=$(echo "$user" | jq -r '.id')
        local username=$(echo "$user" | jq -r '.username // "未知"')
        local enabled=$(echo "$user" | jq -r '.enabled // true')
        local expire_date=$(echo "$user" | jq -r '.expire_date // "unlimited"')

        # 跳过无限期或已禁用的用户
        if [[ "$expire_date" == "unlimited" || "$enabled" != "true" ]]; then
            continue
        fi

        # 比较日期（使用日期戳）
        local expire_ts=$(date -d "$expire_date" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$expire_date" '+%s' 2>/dev/null)
        local today_ts=$(date -d "$today" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$today" '+%s' 2>/dev/null)

        if [[ -z "$expire_ts" || -z "$today_ts" ]]; then
            echo -e "  ${YELLOW}⚠${NC} $username: 无法解析日期 $expire_date"
            continue
        fi

        # 检查是否过期
        if [[ $today_ts -ge $expire_ts ]]; then
            echo -e "  ${RED}✗${NC} $username: 已过期 (有效期至 $expire_date) ${RED}(已禁用)${NC}"

            # 禁用用户（文件+API动态）
            local users_json=$(cat "$USERS_FILE")
            users_json=$(echo "$users_json" | jq --arg uuid "$uuid" \
                '(.users[] | select(.id == $uuid) | .enabled) = false')
            atomic_write_json "$USERS_FILE" "$users_json" || return 1

            USER_LIMITS_CHANGED=true
            ((disabled_count++))
        else
            # 计算剩余天数
            local days_left=$(( (expire_ts - today_ts) / 86400 ))

            if [[ $days_left -le 7 ]]; then
                echo -e "  ${YELLOW}⚠${NC} $username: 还有 ${days_left} 天过期 (有效期至 $expire_date)"
            else
                echo -e "  ${GREEN}✓${NC} $username: 有效期至 $expire_date (还有 ${days_left} 天)"
            fi
        fi
    done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

    echo ""
    if [[ $disabled_count -gt 0 ]]; then
        echo -e "${RED}共禁用 $disabled_count 个过期用户${NC}"
        echo -e "${YELLOW}将在本轮检查结束后统一应用配置${NC}"
    else
        echo -e "${GREEN}所有用户有效期正常${NC}"
    fi
}

# 检查用户流量限制（如果超过限制则禁用）
check_traffic_limits() {
    if [[ ! -f "$USERS_FILE" ]]; then
        return 0
    fi

    if declare -f singbox_has_stats_capability >/dev/null 2>&1 \
        && ! singbox_has_stats_capability; then
        echo -e "${YELLOW}跳过用户流量限制：当前内核不支持流量统计${NC}"
        echo -e "${GRAY}用户有效期限制仍会正常执行，节点代理功能不受影响${NC}"
        return 0
    fi

    echo -e "${CYAN}检查用户流量限制...${NC}"

    local disabled_count=0

    while IFS= read -r user; do
        local uuid=$(echo "$user" | jq -r '.id')
        local username=$(echo "$user" | jq -r '.username // "未知"')
        local enabled=$(echo "$user" | jq -r '.enabled // true')
        local traffic_limit=$(echo "$user" | jq -r '.traffic_limit_gb // "unlimited"')

        # 已禁用用户不再采集；所有启用用户（包括无限流量）都必须刷新账本。
        if [[ "$enabled" != "true" ]]; then
            continue
        fi

        # 更新流量统计
        local used_gb update_status
        used_gb=$(update_user_traffic_usage "$uuid")
        update_status=$?
        if [[ $update_status -ne 0 || -z "$used_gb" ]]; then
            continue
        fi

        # 无限流量用户只更新统计，不执行超限判断。
        if [[ "$traffic_limit" == "unlimited" ]]; then
            continue
        fi

        # 比较流量（使用 awk 进行浮点数比较）
        local over_limit=$(awk -v used="$used_gb" -v limit="$traffic_limit" 'BEGIN {print (used >= limit) ? "yes" : "no"}')

        if [[ "$over_limit" == "yes" ]]; then
            echo -e "  ${RED}✗${NC} $username: 已用 ${used_gb} GB / 限制 ${traffic_limit} GB ${RED}(超限,已禁用)${NC}"

            # 禁用用户（文件+API动态）
            local users_json=$(cat "$USERS_FILE")
            users_json=$(echo "$users_json" | jq --arg uuid "$uuid" \
                '(.users[] | select(.id == $uuid) | .enabled) = false')
            atomic_write_json "$USERS_FILE" "$users_json" || return 1

            USER_LIMITS_CHANGED=true
            ((disabled_count++))
        else
            local percent=$(awk -v used="$used_gb" -v limit="$traffic_limit" 'BEGIN {printf "%.1f", (used/limit)*100}')

            if (( $(awk -v p="$percent" 'BEGIN {print (p >= 80) ? 1 : 0}') )); then
                echo -e "  ${YELLOW}⚠${NC} $username: 已用 ${used_gb} GB / 限制 ${traffic_limit} GB ${YELLOW}(${percent}%)${NC}"
            else
                echo -e "  ${GREEN}✓${NC} $username: 已用 ${used_gb} GB / 限制 ${traffic_limit} GB (${percent}%)"
            fi
        fi
    done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

    echo ""
    if [[ $disabled_count -gt 0 ]]; then
        echo -e "${RED}共禁用 $disabled_count 个超限用户${NC}"
        echo -e "${YELLOW}将在本轮检查结束后统一应用配置${NC}"
    else
        echo -e "${GREEN}所有用户流量正常${NC}"
    fi
}

# 综合检查用户限制（流量 + 有效期）
check_all_user_limits() {
    [[ -t 1 ]] && clear
    USER_LIMITS_CHANGED=false
    begin_data_transaction || return 1
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      用户限制综合检查"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 先检查有效期
    if ! check_user_expiration; then
        rollback_data_transaction
        print_error "用户有效期检查失败，已回滚本轮变更"
        return 1
    fi
    echo ""

    # 再检查流量限制
    if ! check_traffic_limits; then
        rollback_data_transaction
        print_error "用户流量检查失败，已回滚本轮变更"
        return 1
    fi
    echo ""

    if [[ "$USER_LIMITS_CHANGED" == true ]]; then
        if ! generate_singbox_config || ! restart_sing-box; then
            print_error "应用用户限制失败，数据与配置已回滚"
            return 1
        fi
    else
        commit_data_transaction || {
            rollback_data_transaction
            print_error "用户限制检查结果无法提交"
            return 1
        }
    fi

    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}提示: 用户状态已写入数据文件，并通过配置重载或服务重启生效${NC}"
}

# ============================================================================
# 新的用户管理功能
# ============================================================================

# 查看用户菜单（列表+详情）
view_users_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}      查看用户"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""

        # 显示用户列表
        list_global_users

        echo ""
        echo -e "${GREEN}1.${NC} 查看单个用户详情"
        echo ""

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return 0  # 返回上级
        [[ $ret -eq 98 ]] && return 98  # 返回主菜单

        case "$choice" in
            1)
                echo ""
                read -p "请输入要查看的用户名 (按回车返回): " username

                # 支持返回
                if [[ -z "$username" ]]; then
                    continue
                fi

                show_user_detail "$username"
                echo ""
                read -p "按回车键继续..."
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 修改用户菜单
modify_user_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}      修改用户"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""

        # 显示用户列表
        list_global_users

        echo ""
        echo -e "${GREEN}1.${NC} 修改用户基础信息"
        echo -e "${GREEN}2.${NC} 修改用户绑定节点"
        echo ""

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return 0  # 返回上级
        [[ $ret -eq 98 ]] && return 98  # 返回主菜单

        case "$choice" in
            1)
                modify_user_basic_info
                [[ $? -eq 98 ]] && return 98
                read -p "按回车键继续..."
                ;;
            2)
                modify_user_bindings
                [[ $? -eq 98 ]] && return 98
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 修改用户基础信息
modify_user_basic_info() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      修改用户基础信息"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    list_global_users

    echo ""
    read -p "请输入要修改的用户名 (0 返回): " username

    # 支持返回上一级
    if [[ "$username" == "0" ]]; then
        return 0
    fi

    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        sleep 1
        return 1
    fi

    # 检查用户是否存在
    local user=$(jq -r ".users[] | select(.username == \"$username\")" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$user" || "$user" == "null" ]]; then
        print_error "用户不存在: $username"
        sleep 1
        return 1
    fi

    local uuid=$(echo "$user" | jq -r '.id')

    # 进入修改菜单
    while true; do
        # 重新获取最新的用户信息
        user=$(jq -c ".users[] | select(.id == \"$uuid\")" "$USERS_FILE" 2>/dev/null)
        local current_password=$(echo "$user" | jq -r '.password // ""')
        local current_email=$(echo "$user" | jq -r 'if .email == "" or .email == null then "" else .email end')
        local current_enabled=$(echo "$user" | jq -r 'if .enabled == true then "true" else "false" end')

        local status_display=""
        if [[ "$current_enabled" == "true" ]]; then
            status_display="${GREEN}启用${NC}"
        else
            status_display="${RED}禁用${NC}"
        fi

        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║      修改用户: $username                ${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}当前信息：${NC}"
        echo -e "  用户名: ${YELLOW}$username${NC}"
        echo -e "  密码: ${YELLOW}$current_password${NC}"
        echo -e "  邮箱: ${YELLOW}$current_email${NC}"
        echo -e "  状态: $status_display"
        echo ""
        echo -e "${GREEN}1.${NC} 修改密码"
        echo -e "${GREEN}2.${NC} 修改邮箱"
        echo -e "${GREEN}3.${NC} 修改状态"
        echo ""

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择要修改的项目")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return 0  # 返回上级
        [[ $ret -eq 98 ]] && return 98  # 返回主菜单

        case "$choice" in
            1)
                # 修改密码
                echo ""
                read -p "请输入新密码 (0 取消): " new_password
                if [[ "$new_password" == "0" ]]; then
                    continue
                fi
                if [[ -z "$new_password" ]]; then
                    print_error "密码不能为空"
                    sleep 1
                    continue
                fi

                # 更新密码
                local tmp_file="${USERS_FILE}.tmp"
                if ! jq --arg uuid "$uuid" --arg password "$new_password" \
                    '(.users[] | select(.id == $uuid)) |= (.password = $password)' \
                    "$USERS_FILE" > "$tmp_file"; then
                    print_error "修改密码失败"
                    rm -f "$tmp_file"
                    sleep 1
                    continue
                fi
                mv "$tmp_file" "$USERS_FILE"
                print_success "密码修改成功"

                # 重新生成配置并重启
                generate_singbox_config && restart_sing-box
                sleep 1
                ;;
            2)
                # 修改邮箱
                echo ""
                read -p "请输入新邮箱 (0 取消): " new_email
                if [[ "$new_email" == "0" ]]; then
                    continue
                fi
                if [[ -z "$new_email" ]]; then
                    print_error "邮箱不能为空"
                    sleep 1
                    continue
                fi

                # 更新邮箱
                local tmp_file="${USERS_FILE}.tmp"
                if ! jq --arg uuid "$uuid" --arg email "$new_email" \
                    '(.users[] | select(.id == $uuid)) |= (.email = $email)' \
                    "$USERS_FILE" > "$tmp_file"; then
                    print_error "修改邮箱失败"
                    rm -f "$tmp_file"
                    sleep 1
                    continue
                fi
                mv "$tmp_file" "$USERS_FILE"
                print_success "邮箱修改成功"

                # 重新生成配置并重启
                generate_singbox_config && restart_sing-box
                sleep 1
                ;;
            3)
                # 修改状态
                echo ""
                echo -e "${CYAN}当前状态: $status_display${NC}"
                echo ""
                echo -e "${GREEN}1.${NC} 启用"
                echo -e "${GREEN}2.${NC} 禁用"
                echo -e "${GREEN}0.${NC} 取消"
                echo ""
                read -p "请选择: " status_choice

                local new_enabled=""
                case "$status_choice" in
                    1)
                        new_enabled="true"
                        ;;
                    2)
                        new_enabled="false"
                        ;;
                    0)
                        continue
                        ;;
                    *)
                        print_error "无效选择"
                        sleep 1
                        continue
                        ;;
                esac

                # 更新状态
                local tmp_file="${USERS_FILE}.tmp"
                if ! jq --arg uuid "$uuid" --argjson enabled "$new_enabled" \
                    '(.users[] | select(.id == $uuid)) |= (.enabled = $enabled)' \
                    "$USERS_FILE" > "$tmp_file"; then
                    print_error "修改状态失败"
                    rm -f "$tmp_file"
                    sleep 1
                    continue
                fi
                mv "$tmp_file" "$USERS_FILE"

                if [[ "$new_enabled" == "true" ]]; then
                    print_success "用户已启用"
                else
                    print_success "用户已禁用"
                fi

                # 重新生成配置并重启
                generate_singbox_config && restart_sing-box
                sleep 1
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 修改用户绑定节点
modify_user_bindings() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}      修改用户绑定节点"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""

        list_global_users

        echo ""
        read -p "请输入要修改的用户名 (0 返回): " username

        # 支持返回上一级
        if [[ "$username" == "0" ]]; then
            return 0
        fi

        if [[ -z "$username" ]]; then
            print_error "用户名不能为空"
            sleep 1
            continue
        fi

        # 检查用户是否存在
        local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
        if [[ -z "$uuid" || "$uuid" == "null" ]]; then
            print_error "用户不存在: $username"
            sleep 1
            continue
        fi

        # 显示当前绑定的节点
        echo ""
        echo -e "${CYAN}当前绑定的节点：${NC}"
        local bound_ports=$(jq -r ".bindings[] | select(.users[] == \"$uuid\") | .port" "$NODE_USERS_FILE" 2>/dev/null)
        if [[ -z "$bound_ports" ]]; then
            echo -e "  ${YELLOW}未绑定任何节点${NC}"
        else
            while IFS= read -r port; do
                local node=$(jq -r ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                local name=$(echo "$node" | jq -r '.name // "未命名"')
                local protocol=$(echo "$node" | jq -r '.protocol')
                echo -e "  ${CYAN}•${NC} $name (端口: $port, 协议: $protocol)"
            done <<< "$bound_ports"
        fi

        echo ""
        echo -e "${GREEN}1.${NC} 添加绑定节点"
        echo -e "${GREEN}2.${NC} 移除绑定节点"
        echo ""

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return 0  # 返回上级
        [[ $ret -eq 98 ]] && return 98  # 返回主菜单

        case "$choice" in
            1)
                add_user_node_bindings "$uuid" "$username"
                read -p "按回车键继续..."
                ;;
            2)
                remove_user_node_bindings "$uuid" "$username"
                read -p "按回车键继续..."
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 添加用户绑定节点（支持多个）
add_user_node_bindings() {
    local uuid=$1
    local username=$2

    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      添加绑定节点"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}用户：${YELLOW}$username${NC}"
    echo ""

    # 显示所有可用节点
    echo -e "${CYAN}可用节点：${NC}"
    local node_count=0
    while IFS= read -r node; do
        local port=$(echo "$node" | jq -r '.port')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local name=$(echo "$node" | jq -r '.name // "未命名"')

        # 检查是否已绑定
        local is_bound=$(jq -r ".bindings[] | select(.port == \"$port\" and (.users[] == \"$uuid\")) | .port" "$NODE_USERS_FILE" 2>/dev/null)

        if [[ -z "$is_bound" ]]; then
            echo -e "  ${GREEN}$port${NC} - $name ($protocol)"
            ((node_count++))
        fi
    done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)

    if [[ $node_count -eq 0 ]]; then
        print_warning "没有可用的节点"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}提示：可以输入多个端口，用空格分隔 (0 取消)${NC}"
    read -p "请输入要绑定的节点端口: " ports

    # 支持返回
    if [[ "$ports" == "0" ]]; then
        return 0
    fi

    if [[ -z "$ports" ]]; then
        print_info "取消操作"
        return 0
    fi

    local success_count=0
    local fail_count=0
    begin_data_transaction || return 1

    for port in $ports; do
        # 检查节点是否存在
        local node_exists=$(jq -r ".nodes[] | select(.port == \"$port\") | .port" "$NODES_FILE" 2>/dev/null)
        if [[ -z "$node_exists" ]]; then
            print_warning "节点不存在: $port"
            ((fail_count++))
            continue
        fi

        # 检查绑定是否已存在
        local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

        local tmp_file="${NODE_USERS_FILE}.tmp"
        if [[ -z "$binding_exists" ]]; then
            # 创建新绑定
            local protocol=$(jq -r --arg port "$port" '.nodes[] | select((.port|tostring)==$port) | .protocol' "$NODES_FILE")
            if ! jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" \
                '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' \
                "$NODE_USERS_FILE" > "$tmp_file"; then
                print_error "添加绑定失败: $port"
                rm -f "$tmp_file"
                ((fail_count++))
                continue
            fi
        else
            # 添加到现有绑定
            if ! jq --arg port "$port" --arg uuid "$uuid" \
                '(.bindings[] | select(.port == $port) | .users) |= (. + [$uuid] | unique)' \
                "$NODE_USERS_FILE" > "$tmp_file"; then
                print_error "添加绑定失败: $port"
                rm -f "$tmp_file"
                ((fail_count++))
                continue
            fi
        fi

        mv "$tmp_file" "$NODE_USERS_FILE"
        print_success "已绑定节点: $port"
        ((success_count++))
    done

    echo ""
    echo -e "${CYAN}操作结果：${NC}"
    echo -e "  成功: ${GREEN}$success_count${NC}"
    echo -e "  失败: ${RED}$fail_count${NC}"

    if [[ $success_count -gt 0 ]]; then
        if ! generate_singbox_config || ! restart_sing-box; then
            print_error "批量绑定应用失败，数据和配置已回滚"
            return 1
        fi
        print_success "配置已更新并重启服务"
    else
        rollback_data_transaction
    fi
}

remove_user_subscriptions_by_id() {
    local user_id="$1" meta_file="${DATA_DIR}/subscription_metadata.json" sub_db="${DATA_DIR}/subscriptions.json"
    [[ -f "$meta_file" ]] || return 0
    local names
    names=$(jq -c --arg id "$user_id" '[.subscriptions[] | select(.user_id==$id) | .name]' "$meta_file") || return 1
    if [[ -f "$sub_db" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] || safe_remove_subscription_file "$file" || true
        done < <(jq -r --argjson names "$names" '.subscriptions[] | select(.name as $n | $names | index($n)) | .file // empty' "$sub_db")
        jq --argjson names "$names" '.subscriptions |= map(select(.name as $n | ($names | index($n) | not)))' "$sub_db" > "${sub_db}.tmp" \
            && mv "${sub_db}.tmp" "$sub_db" || { rm -f "${sub_db}.tmp"; return 1; }
    fi
    jq --arg id "$user_id" '.subscriptions |= map(select(.user_id != $id))' "$meta_file" > "${meta_file}.tmp" \
        && mv "${meta_file}.tmp" "$meta_file" || { rm -f "${meta_file}.tmp"; return 1; }
}

# 移除用户绑定节点（支持多个）
remove_user_node_bindings() {
    local uuid=$1
    local username=$2

    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      移除绑定节点"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}用户：${YELLOW}$username${NC}"
    echo ""

    # 显示已绑定的节点
    echo -e "${CYAN}已绑定的节点：${NC}"
    local bound_ports=$(jq -r ".bindings[] | select(.users[] == \"$uuid\") | .port" "$NODE_USERS_FILE" 2>/dev/null)
    if [[ -z "$bound_ports" ]]; then
        print_warning "未绑定任何节点"
        return 0
    fi

    while IFS= read -r port; do
        local node=$(jq -r ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
        local name=$(echo "$node" | jq -r '.name // "未命名"')
        local protocol=$(echo "$node" | jq -r '.protocol')
        echo -e "  ${GREEN}$port${NC} - $name ($protocol)"
    done <<< "$bound_ports"

    echo ""
    echo -e "${YELLOW}提示：可以输入多个端口，用空格分隔 (0 取消)${NC}"
    read -p "请输入要移除的节点端口: " ports

    # 支持返回
    if [[ "$ports" == "0" ]]; then
        return 0
    fi

    if [[ -z "$ports" ]]; then
        print_info "取消操作"
        return 0
    fi

    local success_count=0
    local fail_count=0
    begin_data_transaction || return 1

    for port in $ports; do
        local tmp_file="${NODE_USERS_FILE}.tmp"
        if ! jq --arg port "$port" --arg uuid "$uuid" \
            '(.bindings[] | select(.port == $port) | .users) |= map(select(. != $uuid))' \
            "$NODE_USERS_FILE" > "$tmp_file"; then
            print_error "移除绑定失败: $port"
            rm -f "$tmp_file"
            ((fail_count++))
            continue
        fi

        mv "$tmp_file" "$NODE_USERS_FILE"
        print_success "已移除节点绑定: $port"
        ((success_count++))
    done

    echo ""
    echo -e "${CYAN}操作结果：${NC}"
    echo -e "  成功: ${GREEN}$success_count${NC}"
    echo -e "  失败: ${RED}$fail_count${NC}"

    if [[ $success_count -gt 0 ]]; then
        if ! generate_singbox_config || ! restart_sing-box; then
            print_error "批量解绑应用失败，数据和配置已回滚"
            return 1
        fi
        print_success "配置已更新并重启服务"
    else
        rollback_data_transaction
    fi
}

# 批量删除用户
delete_users_batch() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      批量删除用户"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    list_global_users

    echo ""
    echo -e "${YELLOW}提示：可以输入多个用户名，用空格分隔 (0 返回)${NC}"
    read -p "请输入要删除的用户名: " usernames

    # 支持返回
    if [[ "$usernames" == "0" ]]; then
        return 0
    fi

    if [[ -z "$usernames" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 确认删除
    echo ""
    print_warning "删除用户将同时清理所有节点绑定关系和订阅链接"
    echo -e "${RED}准备删除的用户：${NC}"
    for username in $usernames; do
        echo -e "  ${YELLOW}• $username${NC}"
    done
    echo ""
    read -p "确认删除这些用户? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消删除"
        return 0
    fi

    local success_count=0
    local fail_count=0
    begin_data_transaction || return 1

    for username in $usernames; do
        # 检查用户是否存在
        local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
        if [[ -z "$uuid" || "$uuid" == "null" ]]; then
            print_warning "用户不存在，跳过: $username"
            ((fail_count++))
            continue
        fi

        # 1. 删除订阅
        if [[ -f "$SUBSCRIPTION_META_FILE" ]]; then
            local sub_names_json
            sub_names_json=$(jq -c --arg uuid "$uuid" '[.subscriptions[] | select(.user_id == $uuid) | .name]' "$SUBSCRIPTION_META_FILE") || {
                print_error "读取用户订阅元数据失败: $username"
                rollback_data_transaction
                return 1
            }
            if [[ "$(jq 'length' <<< "$sub_names_json")" -gt 0 ]]; then
                local sub_db="${DATA_DIR}/subscriptions.json"
                if [[ -f "$sub_db" ]]; then
                    while IFS= read -r sub_file; do
                        [[ -n "$sub_file" ]] || continue
                        if declare -f safe_remove_subscription_file >/dev/null 2>&1; then
                            safe_remove_subscription_file "$sub_file" || true
                        fi
                    done < <(jq -r --argjson names "$sub_names_json" '.subscriptions[] | select(.name as $n | $names | index($n)) | .file // empty' "$sub_db")

                    if ! jq --argjson names "$sub_names_json" '.subscriptions |= map(select(.name as $n | ($names | index($n) | not)))' \
                        "$sub_db" > "${sub_db}.tmp" || ! mv "${sub_db}.tmp" "$sub_db"; then
                        rm -f "${sub_db}.tmp"
                        print_error "删除用户订阅记录失败: $username"
                        rollback_data_transaction
                        return 1
                    fi
                fi

                local tmp_file="${SUBSCRIPTION_META_FILE}.tmp"
                if ! jq --arg uuid "$uuid" '.subscriptions |= map(select(.user_id != $uuid))' "$SUBSCRIPTION_META_FILE" > "$tmp_file" \
                    || ! mv "$tmp_file" "$SUBSCRIPTION_META_FILE"; then
                    rm -f "$tmp_file"
                    print_error "删除用户订阅元数据失败: $username"
                    rollback_data_transaction
                    return 1
                fi
            fi
        fi

        # 2. 解绑节点
        if [[ -f "$NODE_USERS_FILE" ]]; then
            local tmp_file="${NODE_USERS_FILE}.tmp"
            jq --arg uuid "$uuid" '(.bindings[].users) |= map(select(. != $uuid))' "$NODE_USERS_FILE" > "$tmp_file"
            mv "$tmp_file" "$NODE_USERS_FILE"
        fi

        # 3. 删除用户
        local tmp_file="${USERS_FILE}.tmp"
        if ! jq --arg uuid "$uuid" '.users = [.users[] | select(.id != $uuid)]' "$USERS_FILE" > "$tmp_file"; then
            print_error "删除用户失败: $username"
            rm -f "$tmp_file"
            ((fail_count++))
            continue
        fi
        mv "$tmp_file" "$USERS_FILE"

        print_success "用户删除成功: $username"
        ((success_count++))
    done

    echo ""
    echo -e "${CYAN}操作结果：${NC}"
    echo -e "  成功: ${GREEN}$success_count${NC}"
    echo -e "  失败: ${RED}$fail_count${NC}"

    if [[ $success_count -gt 0 ]]; then
        if ! generate_singbox_config || ! restart_sing-box; then
            print_error "批量删除应用失败，用户、订阅、数据和配置已回滚"
            return 1
        fi
        print_success "配置已更新并重启服务"
    else
        rollback_data_transaction
    fi
}
