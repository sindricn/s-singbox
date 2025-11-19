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

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    # 表头：镂空设计，移除右边框
    echo -e "${CYAN}║${NC} 用户名      密码              邮箱                  UUID                                  状态    在线"
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
                # 从配置文件中获取实际使用的email(可能与用户文件中的不同)
                local config_email=$(get_user_email_from_config "$uuid")
                if [[ -n "$config_email" && "$config_email" != "null" ]]; then
                    local user_status=$(get_user_online_status "$config_email" "$port")
                    case $user_status in
                        online)
                            online_text="在线"
                            online_display="${GREEN}在线${NC}"
                            ;;
                        offline)
                            online_text="离线"
                            online_display="${YELLOW}离线${NC}"
                            ;;
                        never)
                            online_text="未连接"
                            online_display="${GRAY}未连接${NC}"
                            ;;
                        *)
                            online_text="未知"
                            online_display="${GRAY}未知${NC}"
                            ;;
                    esac
                else
                    online_text="离线"
                    online_display="${GRAY}离线${NC}"
                fi
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

    # 检查用户名是否已存在
    if [[ -f "$USERS_FILE" ]]; then
        local existing_username=$(jq -r ".users[] | select(.username == \"$username\") | .username" "$USERS_FILE" 2>/dev/null)
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

    # 设置流量限制
    read -p "请输入流量限制(GB) [留空表示无限制]: " traffic_limit_gb
    traffic_limit_gb=${traffic_limit_gb:-unlimited}

    # 设置有效期
    read -p "请输入有效期(天数) [留空表示无限制]: " expire_days
    if [[ -n "$expire_days" && "$expire_days" != "unlimited" ]]; then
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

    jq --argjson user_data "$user_data" '.users += [$user_data]' "$USERS_FILE" > "${USERS_FILE}.tmp"
    mv "${USERS_FILE}.tmp" "$USERS_FILE"

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

    # 实时更新流量使用情况
    echo -e "${GRAY}正在获取实时流量统计...${NC}"
    local traffic_used="0"
    local updated_gb=$(update_user_traffic_usage "$uuid" 2>/dev/null)
    if [[ $? -eq 0 && -n "$updated_gb" ]]; then
        traffic_used="$updated_gb"
    else
        # 如果无法更新，使用文件中的旧值
        traffic_used=$(echo "$user" | jq -r '.traffic_used_gb // "0"')
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
    echo -e "  已用流量: ${YELLOW}$traffic_used GB${NC}"
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

    # 1. 删除该用户的所有订阅
    if [[ -f "$SUBSCRIPTION_META_FILE" ]]; then
        # 获取该用户的所有订阅名称
        local sub_names=$(jq -r ".subscriptions[] | select(.user_id == \"$uuid\") | .name" "$SUBSCRIPTION_META_FILE" 2>/dev/null)
        if [[ -n "$sub_names" ]]; then
            while IFS= read -r sub_name; do
                # 删除订阅文件
                find "$SUBSCRIPTION_DIR" -name "${sub_name}.*" -type f -delete 2>/dev/null
                print_info "已删除订阅: $sub_name"
            done <<< "$sub_names"

            # 从元数据中删除
            local tmp_file="${SUBSCRIPTION_META_FILE}.tmp"
            if ! jq --arg uuid "$uuid" '.subscriptions = [.subscriptions[] | select(.user_id != $uuid)]' "$SUBSCRIPTION_META_FILE" > "$tmp_file"; then
                print_error "清理订阅元数据失败"
                rm -f "$tmp_file"
                return 1
            fi
            mv "$tmp_file" "$SUBSCRIPTION_META_FILE"
            print_info "已清理订阅元数据"
        fi
    fi

    # 2. 从所有节点解绑
    if [[ -f "$NODE_USERS_FILE" ]]; then
        local tmp_file="${NODE_USERS_FILE}.tmp"
        if ! jq --arg uuid "$uuid" '(.bindings[].users) |= map(select(. != $uuid))' "$NODE_USERS_FILE" > "$tmp_file"; then
            print_error "清理节点绑定关系失败"
            rm -f "$tmp_file"
            return 1
        fi
        mv "$tmp_file" "$NODE_USERS_FILE"
        print_info "已清理节点绑定关系"
    fi

    # 3. 从全局用户列表删除
    local tmp_file="${USERS_FILE}.tmp"
    if ! jq --arg uuid "$uuid" '.users = [.users[] | select(.id != $uuid)]' "$USERS_FILE" > "$tmp_file"; then
        print_error "删除用户失败"
        rm -f "$tmp_file"
        return 1
    fi
    mv "$tmp_file" "$USERS_FILE"

    print_success "用户删除成功"

    # 重新生成配置
    generate_sing-box_config

    # 重启服务
    restart_sing-box

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

    # 1. 删除该用户的所有订阅
    if [[ -f "$SUBSCRIPTION_META_FILE" ]]; then
        local sub_names=$(jq -r ".subscriptions[] | select(.user_id == \"$uuid\") | .name" "$SUBSCRIPTION_META_FILE" 2>/dev/null)
        if [[ -n "$sub_names" ]]; then
            while IFS= read -r sub_name; do
                find "$SUBSCRIPTION_DIR" -name "${sub_name}.*" -type f -delete 2>/dev/null
                print_info "已删除订阅文件: $sub_name"
            done <<< "$sub_names"

            local tmp_file="${SUBSCRIPTION_META_FILE}.tmp"
            if ! jq --arg uuid "$uuid" '.subscriptions = [.subscriptions[] | select(.user_id != $uuid)]' "$SUBSCRIPTION_META_FILE" > "$tmp_file"; then
                print_error "清理订阅元数据失败"
                rm -f "$tmp_file"
                return 1
            fi
            mv "$tmp_file" "$SUBSCRIPTION_META_FILE"
            print_info "已清理订阅元数据"
        fi
    fi

    # 2. 从所有节点解绑
    if [[ -f "$NODE_USERS_FILE" ]]; then
        local tmp_file="${NODE_USERS_FILE}.tmp"
        if ! jq --arg uuid "$uuid" '(.bindings[].users) |= map(select(. != $uuid))' "$NODE_USERS_FILE" > "$tmp_file"; then
            print_error "清理节点绑定关系失败"
            rm -f "$tmp_file"
            return 1
        fi
        mv "$tmp_file" "$NODE_USERS_FILE"
        print_info "已清理节点绑定关系"
    fi

    # 3. 从全局用户列表删除
    local tmp_file="${USERS_FILE}.tmp"
    if ! jq --arg uuid "$uuid" '.users = [.users[] | select(.id != $uuid)]' "$USERS_FILE" > "$tmp_file"; then
        print_error "删除用户失败"
        rm -f "$tmp_file"
        return 1
    fi
    mv "$tmp_file" "$USERS_FILE"

    print_success "用户删除成功"

    # 重新生成配置
    generate_sing-box_config

    # 重启服务
    restart_sing-box

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

    # 构建用户配置
    local user_config=""

    case $protocol in
        vless)
            user_config=$(jq -n \
                --arg id "$id" \
                --arg email "$email" \
                --argjson level "$level" \
                '{id: $id, email: $email, level: $level, flow: "xtls-rprx-vision"}')
            ;;

        vmess)
            user_config=$(jq -n \
                --arg id "$id" \
                --arg email "$email" \
                --argjson level "$level" \
                '{id: $id, email: $email, level: $level, alterId: 0}')
            ;;

        trojan)
            user_config=$(jq -n \
                --arg password "$id" \
                --arg email "$email" \
                --argjson level "$level" \
                '{password: $password, email: $email, level: $level}')
            ;;

        shadowsocks)
            # Shadowsocks 不支持多用户，需要重新配置密码
            print_warning "Shadowsocks 节点需要更新密码配置"
            if ! jq "(.inbounds[] | select(.port == $port) | .settings.password) = \"$id\"" "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp"; then
                print_error "更新Shadowsocks密码失败"
                rm -f "${SINGBOX_CONFIG}.tmp"
                return 1
            fi
            mv "${SINGBOX_CONFIG}.tmp" "$SINGBOX_CONFIG"
            return 0
            ;;
    esac

    # 添加到配置文件
    if [[ -n "$user_config" ]]; then
        if ! jq "(.inbounds[] | select(.port == $port) | .settings.clients) += [$user_config]" "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp"; then
            print_error "添加用户配置失败"
            rm -f "${SINGBOX_CONFIG}.tmp"
            return 1
        fi
        mv "${SINGBOX_CONFIG}.tmp" "$SINGBOX_CONFIG"
    fi
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

    # 更新配置文件
    if ! jq "(.inbounds[] | select(.port == $port) | .settings.clients[] | select(.email == \"$old_email\") | .email) = \"$new_email\"" "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp"; then
        print_error "更新配置文件邮箱失败"
        rm -f "${SINGBOX_CONFIG}.tmp"
        return 1
    fi
    mv "${SINGBOX_CONFIG}.tmp" "$SINGBOX_CONFIG"

    # 更新数据库
    if ! jq "(.users[] | select(.port == \"$port\" and .email == \"$old_email\") | .email) = \"$new_email\"" "$USERS_FILE" > "${USERS_FILE}.tmp"; then
        print_error "更新数据库邮箱失败"
        rm -f "${USERS_FILE}.tmp"
        return 1
    fi
    mv "${USERS_FILE}.tmp" "$USERS_FILE"
}

# 更新用户ID
update_user_id() {
    local port=$1
    local email=$2
    local new_id=$3

    # 获取协议
    local protocol=$(jq -r ".users[] | select(.port == \"$port\" and .email == \"$email\") | .protocol" "$USERS_FILE")

    # 更新配置文件
    case $protocol in
        vless|vmess)
            if ! jq "(.inbounds[] | select(.port == $port) | .settings.clients[] | select(.email == \"$email\") | .id) = \"$new_id\"" "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp"; then
                print_error "更新配置文件ID失败"
                rm -f "${SINGBOX_CONFIG}.tmp"
                return 1
            fi
            ;;
        trojan)
            if ! jq "(.inbounds[] | select(.port == $port) | .settings.clients[] | select(.email == \"$email\") | .password) = \"$new_id\"" "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp"; then
                print_error "更新配置文件密码失败"
                rm -f "${SINGBOX_CONFIG}.tmp"
                return 1
            fi
            ;;
        shadowsocks)
            if ! jq "(.inbounds[] | select(.port == $port) | .settings.password) = \"$new_id\"" "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp"; then
                print_error "更新配置文件密码失败"
                rm -f "${SINGBOX_CONFIG}.tmp"
                return 1
            fi
            ;;
    esac
    mv "${SINGBOX_CONFIG}.tmp" "$SINGBOX_CONFIG"

    # 更新数据库
    if ! jq "(.users[] | select(.port == \"$port\" and .email == \"$email\") | .id) = \"$new_id\"" "$USERS_FILE" > "${USERS_FILE}.tmp"; then
        print_error "更新数据库ID失败"
        rm -f "${USERS_FILE}.tmp"
        return 1
    fi
    mv "${USERS_FILE}.tmp" "$USERS_FILE"
}

# 更新用户等级
update_user_level() {
    local port=$1
    local email=$2
    local new_level=$3

    # 更新配置文件
    if ! jq "(.inbounds[] | select(.port == $port) | .settings.clients[] | select(.email == \"$email\") | .level) = $new_level" "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp"; then
        print_error "更新用户等级失败"
        rm -f "${SINGBOX_CONFIG}.tmp"
        return 1
    fi
    mv "${SINGBOX_CONFIG}.tmp" "$SINGBOX_CONFIG"
}

#================================================================
# 用户在线状态检测
#================================================================

# 检查用户是否有流量记录
check_user_has_traffic() {
    local email=$1
    local api_addr="127.0.0.1:10085"
    local singbox_bin="/usr/local/sing-box/sing-box"

    # 检查 API 端口是否在监听
    if ! ss -lnt 2>/dev/null | grep -q ":10085 " && ! netstat -lnt 2>/dev/null | grep -q ":10085 "; then
        echo "unknown"
        return
    fi

    # 检查 sing-box 命令是否可用
    if [[ ! -x "$singbox_bin" ]]; then
        echo "unknown"
        return
    fi

    # 查询流量（使用 -pattern 参数返回 JSON，然后用 jq 解析）
    local stats_json=$($singbox_bin api statsquery --server=$api_addr -pattern "user>>>${email}>>>traffic" 2>/dev/null)

    # 从 JSON 中提取上行流量
    local uplink=$(echo "$stats_json" | jq -r ".stat[]? | select(.name == \"user>>>${email}>>>traffic>>>uplink\") | .value // 0" 2>/dev/null)
    uplink=${uplink:-0}
    # 确保是数字
    [[ ! "$uplink" =~ ^[0-9]+$ ]] && uplink=0

    # 从 JSON 中提取下行流量
    local downlink=$(echo "$stats_json" | jq -r ".stat[]? | select(.name == \"user>>>${email}>>>traffic>>>downlink\") | .value // 0" 2>/dev/null)
    downlink=${downlink:-0}
    # 确保是数字
    [[ ! "$downlink" =~ ^[0-9]+$ ]] && downlink=0

    # 检查是否有流量数据
    if [[ "$uplink" -gt 0 ]] || [[ "$downlink" -gt 0 ]]; then
        echo "yes"
        return
    fi

    echo "no"
}

# 检查端口是否有活跃连接
check_port_has_connections() {
    local port=$1

    # 使用 ss 或 netstat 检查
    if command -v ss &>/dev/null; then
        # ss 显示 ESTAB 而不是 ESTABLISHED
        # 使用空格确保端口号完全匹配(避免443匹配到4430)
        if ss -tn 2>/dev/null | grep -q "ESTAB.*:${port} "; then
            echo "yes"
            return
        fi
    elif command -v netstat &>/dev/null; then
        # netstat 显示 ESTABLISHED
        if netstat -tn 2>/dev/null | grep -q ":${port}.*ESTABLISHED"; then
            echo "yes"
            return
        fi
    fi

    echo "no"
}

# 获取用户在线状态（混合方案）- 单端口检测
get_user_online_status() {
    local email=$1
    local port=$2

    # 检查流量记录
    local has_traffic=$(check_user_has_traffic "$email")

    if [[ "$has_traffic" == "unknown" ]]; then
        echo "unknown"  # API 不可用
        return
    elif [[ "$has_traffic" == "yes" ]]; then
        echo "online"  # 有流量即认为在线
        return
    fi

    # 没有流量记录时,检查端口是否有活跃连接
    local has_conn=$(check_port_has_connections "$port")

    if [[ "$has_conn" == "yes" ]]; then
        echo "online"  # 端口有连接,可能刚连接还没产生流量
    else
        echo "offline"  # 既无流量也无连接,确认离线
    fi
}

# 检测用户在所有绑定端口上的在线状态，返回"状态:端口"
get_user_online_status_with_port() {
    local email=$1
    local uuid=$2

    # 检查流量记录（Stats API返回的是累计流量，不会归零）
    local has_traffic=$(check_user_has_traffic "$email")

    if [[ "$has_traffic" == "unknown" ]]; then
        echo "unknown:"  # API 不可用
        return
    fi

    # 检查所有绑定端口的连接状态
    local all_ports=$(get_user_all_ports "$uuid")
    local active_port=""
    local has_connection=false

    if [[ -n "$all_ports" ]]; then
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            local has_conn=$(check_port_has_connections "$port")
            if [[ "$has_conn" == "yes" ]]; then
                active_port="$port"
                has_connection=true
                break
            fi
        done <<< "$all_ports"
    fi

    # 判断逻辑:
    # 1. 有流量 + 有连接 = 在线 (正在使用)
    # 2. 有流量 + 无连接 = 离线 (之前用过,现在断开了)
    # 3. 无流量 + 有连接 = 离线 (可能是其他服务的连接,不是sing-box用户连接)
    # 4. 无流量 + 无连接 = 离线

    if [[ "$has_traffic" == "yes" && "$has_connection" == true ]]; then
        echo "online:$active_port"
    else
        echo "offline:"
    fi
}

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

# 从配置文件中获取用户的实际email
get_user_email_from_config() {
    local uuid=$1

    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        echo ""
        return
    fi

    # 首先尝试用UUID查找(适用于vless/vmess)
    local email=$(jq -r ".inbounds[].settings.clients[]? | select(.id == \"$uuid\") | .email" "$SINGBOX_CONFIG" 2>/dev/null | head -n 1)

    # 如果没找到,可能是trojan/shadowsocks,需要用password查找
    if [[ -z "$email" || "$email" == "null" ]]; then
        # 从用户文件中获取该UUID对应的password
        if [[ -f "$USERS_FILE" ]]; then
            local password=$(jq -r ".users[] | select(.id == \"$uuid\") | .password" "$USERS_FILE" 2>/dev/null)

            if [[ -n "$password" && "$password" != "null" ]]; then
                # 用password查找email
                email=$(jq -r ".inbounds[].settings.clients[]? | select(.password == \"$password\") | .email" "$SINGBOX_CONFIG" 2>/dev/null | head -n 1)
            fi
        fi
    fi

    echo "$email"
}

# 获取用户流量摘要
get_user_traffic_summary() {
    local email=$1
    local api_addr="127.0.0.1:10085"
    local singbox_bin="/usr/local/sing-box/sing-box"

    # 检查 API 端口是否在监听
    if ! ss -lnt 2>/dev/null | grep -q ":10085 " && ! netstat -lnt 2>/dev/null | grep -q ":10085 "; then
        echo "N/A"
        return
    fi

    # 检查 sing-box 命令是否可用
    if [[ ! -x "$singbox_bin" ]]; then
        echo "N/A"
        return
    fi

    # 查询流量（使用 -pattern 参数返回 JSON，然后用 jq 解析）
    local stats_json=$($singbox_bin api statsquery --server=$api_addr -pattern "user>>>${email}>>>traffic" 2>/dev/null)

    # 从 JSON 中提取上行流量
    local uplink=$(echo "$stats_json" | jq -r ".stat[]? | select(.name == \"user>>>${email}>>>traffic>>>uplink\") | .value // 0" 2>/dev/null)
    uplink=${uplink:-0}
    # 确保是数字
    [[ ! "$uplink" =~ ^[0-9]+$ ]] && uplink=0

    # 从 JSON 中提取下行流量
    local downlink=$(echo "$stats_json" | jq -r ".stat[]? | select(.name == \"user>>>${email}>>>traffic>>>downlink\") | .value // 0" 2>/dev/null)
    downlink=${downlink:-0}
    # 确保是数字
    [[ ! "$downlink" =~ ^[0-9]+$ ]] && downlink=0

    # 转换为人类可读格式
    local uplink_mb=$((uplink / 1048576))
    local downlink_mb=$((downlink / 1048576))

    echo "↑${uplink_mb}MB ↓${downlink_mb}MB"
}

# 更新用户已使用流量（从 Stats API 读取并写入用户文件）
update_user_traffic_usage() {
    local uuid=$1

    # 从配置文件中获取用户的 email
    local config_email=$(get_user_email_from_config "$uuid")
    if [[ -z "$config_email" || "$config_email" == "null" ]]; then
        return 1
    fi

    # 从 Stats API 获取流量
    local api_addr="127.0.0.1:10085"
    local singbox_bin="/usr/local/sing-box/sing-box"

    # 检查 API 和 sing-box 可用性
    if ! ss -lnt 2>/dev/null | grep -q ":10085 " && ! netstat -lnt 2>/dev/null | grep -q ":10085 "; then
        return 1
    fi

    if [[ ! -x "$singbox_bin" ]]; then
        return 1
    fi

    # 查询流量
    local stats_json=$($singbox_bin api statsquery --server=$api_addr -pattern "user>>>${config_email}>>>traffic" 2>/dev/null)

    local uplink=$(echo "$stats_json" | jq -r ".stat[]? | select(.name == \"user>>>${config_email}>>>traffic>>>uplink\") | .value // 0" 2>/dev/null)
    uplink=${uplink:-0}
    [[ ! "$uplink" =~ ^[0-9]+$ ]] && uplink=0

    local downlink=$(echo "$stats_json" | jq -r ".stat[]? | select(.name == \"user>>>${config_email}>>>traffic>>>downlink\") | .value // 0" 2>/dev/null)
    downlink=${downlink:-0}
    [[ ! "$downlink" =~ ^[0-9]+$ ]] && downlink=0

    # 计算总流量（GB）
    local total_bytes=$((uplink + downlink))
    local total_gb=$(awk "BEGIN {printf \"%.3f\", $total_bytes/1073741824}")

    # 更新用户文件中的 traffic_used_gb
    local users_json=$(cat "$USERS_FILE")
    users_json=$(echo "$users_json" | jq --arg uuid "$uuid" --arg used "$total_gb" \
        '(.users[] | select(.id == $uuid) | .traffic_used_gb) = $used')

    echo "$users_json" | jq '.' > "$USERS_FILE"

    echo "$total_gb"
}

# 更新所有用户的流量使用情况
update_all_users_traffic() {
    if [[ ! -f "$USERS_FILE" ]]; then
        return
    fi

    echo -e "${CYAN}正在更新所有用户流量统计...${NC}"

    local updated_count=0
    local total_count=$(jq '.users | length' "$USERS_FILE" 2>/dev/null)

    while IFS= read -r user; do
        local uuid=$(echo "$user" | jq -r '.id')
        local username=$(echo "$user" | jq -r '.username // "未知"')

        # 更新该用户的流量
        local used_gb=$(update_user_traffic_usage "$uuid")

        if [[ $? -eq 0 && -n "$used_gb" ]]; then
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
            echo "$users_json" | jq '.' > "$USERS_FILE"

            # 通过 API 动态禁用用户（无需重启）
            if command -v api_disable_user &>/dev/null; then
                api_disable_user "$uuid" 2>&1 | sed 's/^/    /'
            fi

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
        echo -e "${YELLOW}提示: 需要重新生成配置并重启 sing-box 才能生效${NC}"
    else
        echo -e "${GREEN}所有用户有效期正常${NC}"
    fi
}

# 检查用户流量限制（如果超过限制则禁用）
check_traffic_limits() {
    if [[ ! -f "$USERS_FILE" ]]; then
        return
    fi

    echo -e "${CYAN}检查用户流量限制...${NC}"

    local disabled_count=0

    while IFS= read -r user; do
        local uuid=$(echo "$user" | jq -r '.id')
        local username=$(echo "$user" | jq -r '.username // "未知"')
        local enabled=$(echo "$user" | jq -r '.enabled // true')
        local traffic_limit=$(echo "$user" | jq -r '.traffic_limit_gb // "unlimited"')

        # 跳过无限流量或已禁用的用户
        if [[ "$traffic_limit" == "unlimited" || "$enabled" != "true" ]]; then
            continue
        fi

        # 更新流量统计
        local used_gb=$(update_user_traffic_usage "$uuid")
        if [[ $? -ne 0 || -z "$used_gb" ]]; then
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
            echo "$users_json" | jq '.' > "$USERS_FILE"

            # 通过 API 动态禁用用户（无需重启）
            if command -v api_disable_user &>/dev/null; then
                api_disable_user "$uuid" 2>&1 | sed 's/^/    /'
            fi

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
        echo -e "${YELLOW}提示: 需要重新生成配置并重启 sing-box 才能生效${NC}"
    else
        echo -e "${GREEN}所有用户流量正常${NC}"
    fi
}

# 综合检查用户限制（流量 + 有效期）
check_all_user_limits() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      用户限制综合检查"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 先检查有效期
    check_user_expiration
    echo ""

    # 再检查流量限制
    check_traffic_limits
    echo ""

    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}提示: 用户已通过 API 动态禁用，立即生效，无需重启 sing-box${NC}"
}

# 查看在线用户
show_online_users() {
    local debug_mode=${1:-false}  # 可选的调试模式参数

    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      在线用户列表"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 获取所有用户
    if [[ ! -f "$USERS_FILE" ]]; then
        print_warning "用户文件不存在"
        return 1
    fi

    local total_users=$(jq '.users | length' "$USERS_FILE" 2>/dev/null)
    if [[ "$total_users" -eq 0 ]]; then
        print_warning "没有用户"
        return 0
    fi

    local online_count=0
    local checked_count=0

    if [[ "$debug_mode" == "true" ]]; then
        echo -e "${YELLOW}=== 调试模式 ===${NC}"
        echo ""
    fi

    echo -e "${CYAN}╔═════════════════════════════════════════════════════════════════════════════╗${NC}"
    printf "${CYAN}║${NC} %-15s %-20s %-10s %-20s %-12s\n" "用户名" "邮箱" "节点端口" "流量统计" "连接状态"
    echo -e "${CYAN}╠═════════════════════════════════════════════════════════════════════════════╣${NC}"

    while IFS= read -r user; do
        local username=$(echo "$user" | jq -r '.username')
        local email=$(echo "$user" | jq -r '.email')
        local uuid=$(echo "$user" | jq -r '.id')
        local enabled=$(echo "$user" | jq -r '.enabled // true')

        ((checked_count++))

        if [[ "$debug_mode" == "true" ]]; then
            echo "  UUID: $uuid"
            echo "  Enabled: $enabled"
        fi

        # 只显示启用的用户
        if [[ "$enabled" != "true" ]]; then
            [[ "$debug_mode" == "true" ]] && echo "  ${GRAY}跳过: 用户未启用${NC}"
            continue
        fi

        # 检查用户是否有绑定的端口
        local all_ports=$(get_user_all_ports "$uuid")
        if [[ "$debug_mode" == "true" ]]; then
            echo "  绑定端口: ${all_ports:-未绑定}"
        fi

        if [[ -z "$all_ports" ]]; then
            [[ "$debug_mode" == "true" ]] && echo "  ${GRAY}跳过: 未绑定节点${NC}"
            continue
        fi

        # 从配置文件中获取实际使用的email
        local config_email=$(get_user_email_from_config "$uuid")
        if [[ "$debug_mode" == "true" ]]; then
            echo "  配置Email: ${config_email:-未找到}"
        fi

        if [[ -z "$config_email" || "$config_email" == "null" ]]; then
            [[ "$debug_mode" == "true" ]] && echo "  ${GRAY}跳过: 配置中无Email${NC}"
            continue
        fi

        # 检测在线状态和实际连接的端口
        local status_port=$(get_user_online_status_with_port "$config_email" "$uuid")
        local status=$(echo "$status_port" | cut -d: -f1)
        local active_port=$(echo "$status_port" | cut -d: -f2)

        if [[ "$debug_mode" == "true" ]]; then
            echo "  在线状态: $status"
            echo "  活跃端口: ${active_port:-无}"
        fi

        # 只显示在线或可能在线的用户
        if [[ "$status" == "online" ]]; then
            ((online_count++))

            # 获取流量统计
            local traffic=$(get_user_traffic_summary "$config_email")

            # 截断显示
            local short_username="${username:0:15}"
            local short_email="${email:0:20}"
            local short_traffic="${traffic:0:20}"

            printf "${CYAN}║${NC} %-15s %-20s %-10s %-20s ${GREEN}%-12s${NC}\n" \
                "$short_username" "$short_email" "$active_port" "$short_traffic" "在线"

            [[ "$debug_mode" == "true" ]] && echo "  ${GREEN}✅ 显示为在线 (端口: $active_port)${NC}"
        else
            [[ "$debug_mode" == "true" ]] && echo "  ${GRAY}未显示: status=$status${NC}"
        fi
    done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

    echo -e "${CYAN}╚═════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}在线用户总数: ${GREEN}${online_count}${NC}${GRAY} / 已检查: $checked_count${NC}"

    if [[ "$debug_mode" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}提示: 要使用调试模式,请运行: show_online_users true${NC}"
    fi
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
        [[ $ret -eq 99 ]] && return  # 返回上级
        [[ $ret -eq 98 ]] && return  # 返回主菜单

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
        [[ $ret -eq 99 ]] && return  # 返回上级
        [[ $ret -eq 98 ]] && return  # 返回主菜单

        case "$choice" in
            1)
                modify_user_basic_info
                read -p "按回车键继续..."
                ;;
            2)
                modify_user_bindings
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
        [[ $ret -eq 98 ]] && return 0  # 返回主菜单

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
        [[ $ret -eq 99 ]] && return  # 返回上级
        [[ $ret -eq 98 ]] && return  # 返回主菜单

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
            if ! jq --arg port "$port" --arg uuid "$uuid" \
                '.bindings += [{port: $port, users: [$uuid]}]' \
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
        # 重新生成配置
        generate_singbox_config
        if [[ $? -eq 0 ]]; then
            restart_sing-box
            print_success "配置已更新并重启服务"
        fi
    fi
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
        # 重新生成配置
        generate_singbox_config
        if [[ $? -eq 0 ]]; then
            restart_sing-box
            print_success "配置已更新并重启服务"
        fi
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
            local sub_names=$(jq -r ".subscriptions[] | select(.user_id == \"$uuid\") | .name" "$SUBSCRIPTION_META_FILE" 2>/dev/null)
            if [[ -n "$sub_names" ]]; then
                while IFS= read -r sub_name; do
                    find "$SUBSCRIPTION_DIR" -name "${sub_name}.*" -type f -delete 2>/dev/null
                done <<< "$sub_names"

                local tmp_file="${SUBSCRIPTION_META_FILE}.tmp"
                jq --arg uuid "$uuid" '.subscriptions = [.subscriptions[] | select(.user_id != $uuid)]' "$SUBSCRIPTION_META_FILE" > "$tmp_file"
                mv "$tmp_file" "$SUBSCRIPTION_META_FILE"
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
        # 重新生成配置
        generate_singbox_config
        restart_sing-box
        print_success "配置已更新并重启服务"
    fi
}


