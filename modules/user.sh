#!/bin/bash

# =============================================================================
# sing-box 用户管理模块
# 功能：添加、删除、列表、修改用户
# =============================================================================

DATA_DIR="./data"
USERS_FILE="${DATA_DIR}/users.json"
BINDINGS_FILE="${DATA_DIR}/node_users.json"

# =============================================================================
# UUID 生成函数
# =============================================================================

generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # Fallback: 使用 random 生成
        python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || \
        echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 8 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-4$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 3 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 4 | head -n 1)-$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 12 | head -n 1)"
    fi
}

# 生成随机密码
generate_random_password() {
    local length=${1:-16}
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "$length"
}

# =============================================================================
# 用户操作函数
# =============================================================================

# 检查用户名是否存在
check_username_exists() {
    local username=$1

    local existing=$(jq -r --arg username "$username" '.users[] | select(.username == $username) | .username' "$USERS_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        return 0  # 存在
    else
        return 1  # 不存在
    fi
}

# 检查邮箱是否存在
check_email_exists() {
    local email=$1

    local existing=$(jq -r --arg email "$email" '.users[] | select(.email == $email) | .email' "$USERS_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        return 0  # 存在
    else
        return 1  # 不存在
    fi
}

# =============================================================================
# 添加用户
# =============================================================================

add_user() {
    print_info "添加新用户"

    # 输入用户名
    while true; do
        read -p "请输入用户名: " username

        if [[ -z "$username" ]]; then
            print_error "用户名不能为空"
            continue
        fi

        if check_username_exists "$username"; then
            print_error "用户名已存在"
            continue
        fi

        break
    done

    # 输入邮箱
    while true; do
        read -p "请输入邮箱 (用于标识): " email

        if [[ -z "$email" ]]; then
            print_error "邮箱不能为空"
            continue
        fi

        # 简单邮箱格式验证
        if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            print_error "邮箱格式无效"
            continue
        fi

        if check_email_exists "$email"; then
            print_error "邮箱已存在"
            continue
        fi

        break
    done

    # 输入用户等级
    read -p "请输入用户等级 (0-9) [0]: " level
    level=${level:-0}

    # 验证等级
    if ! [[ "$level" =~ ^[0-9]$ ]]; then
        print_error "等级必须是 0-9 之间的数字"
        return 1
    fi

    # 生成密码
    local password=$(generate_random_password 16)
    print_info "自动生成密码: $password"

    # 生成 UUID
    local uuid=$(generate_uuid)

    # 流量限制
    read -p "是否设置流量限制? [y/N]: " set_limit
    set_limit=${set_limit:-N}

    local traffic_limit=0
    if [[ "$set_limit" =~ ^[Yy]$ ]]; then
        read -p "请输入流量限制 (GB): " limit_gb
        traffic_limit=$((limit_gb * 1024 * 1024 * 1024))  # 转换为字节
    fi

    # 过期时间
    read -p "是否设置过期时间? [y/N]: " set_expire
    set_expire=${set_expire:-N}

    local expire_time=""
    if [[ "$set_expire" =~ ^[Yy]$ ]]; then
        read -p "请输入有效天数: " days
        expire_time=$(date -u -d "+${days} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                      date -u -v+${days}d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    fi

    # 获取当前时间戳
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # 创建用户对象
    local user=$(jq -n \
        --arg id "$uuid" \
        --arg username "$username" \
        --arg email "$email" \
        --arg password "$password" \
        --argjson level "$level" \
        --argjson enabled true \
        --arg created_at "$timestamp" \
        --argjson traffic_limit "$traffic_limit" \
        --arg expire_time "$expire_time" \
        '{
            id: $id,
            username: $username,
            email: $email,
            password: $password,
            level: $level,
            enabled: $enabled,
            created_at: $created_at,
            traffic_limit: $traffic_limit,
            expire_time: $expire_time
        }')

    # 添加到 users.json
    local users_data=$(cat "$USERS_FILE")
    users_data=$(echo "$users_data" | jq --argjson user "$user" '.users += [$user]')
    echo "$users_data" | jq '.' > "$USERS_FILE"

    print_success "用户添加成功"
    echo ""
    print_info "用户信息:"
    print_info "  UUID: $uuid"
    print_info "  用户名: $username"
    print_info "  邮箱: $email"
    print_info "  密码: $password"
    print_info "  等级: $level"

    if [[ $traffic_limit -gt 0 ]]; then
        print_info "  流量限制: ${limit_gb} GB"
    fi

    if [[ -n "$expire_time" ]]; then
        print_info "  过期时间: $expire_time"
    fi

    echo ""

    # 询问是否绑定节点
    read -p "是否立即绑定节点? [Y/n]: " bind_now
    bind_now=${bind_now:-Y}

    if [[ "$bind_now" =~ ^[Yy]$ ]]; then
        bind_user_to_nodes "$uuid"
    fi

    return 0
}

# =============================================================================
# 删除用户
# =============================================================================

delete_user() {
    # 列出所有用户
    list_users

    # 选择用户
    read -p "请输入要删除的用户名: " username

    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 检查用户是否存在
    if ! check_username_exists "$username"; then
        print_error "用户不存在: $username"
        return 1
    fi

    # 禁止删除 admin 用户
    if [[ "$username" == "admin" ]]; then
        print_error "不能删除 admin 用户"
        return 1
    fi

    # 获取用户 UUID
    local uuid=$(jq -r --arg username "$username" '.users[] | select(.username == $username) | .id' "$USERS_FILE")

    # 确认删除
    read -p "确认删除用户 $username? [y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return 0
    fi

    # 从 users.json 删除
    local users_data=$(cat "$USERS_FILE")
    users_data=$(echo "$users_data" | jq --arg username "$username" '.users = [.users[] | select(.username != $username)]')
    echo "$users_data" | jq '.' > "$USERS_FILE"

    # 从所有绑定中删除该用户
    local bindings_data=$(cat "$BINDINGS_FILE")
    bindings_data=$(echo "$bindings_data" | jq --arg uuid "$uuid" \
        '.bindings[].users = [.bindings[].users[] | select(. != $uuid)]')
    echo "$bindings_data" | jq '.' > "$BINDINGS_FILE"

    print_success "用户已删除: $username"

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
# 列出用户
# =============================================================================

list_users() {
    print_info "当前用户列表:"

    local users=$(jq -r '.users[]' "$USERS_FILE" 2>/dev/null)

    if [[ -z "$users" ]]; then
        print_warn "暂无用户"
        return 0
    fi

    # 表头
    printf "%-20s %-25s %-8s %-10s %-20s\n" "用户名" "邮箱" "等级" "状态" "创建时间"
    printf "%-20s %-25s %-8s %-10s %-20s\n" "--------" "-----" "----" "----" "--------"

    # 遍历用户
    local user_count=$(jq '.users | length' "$USERS_FILE")

    for ((i=0; i<user_count; i++)); do
        local user=$(jq -r ".users[$i]" "$USERS_FILE")
        local username=$(echo "$user" | jq -r '.username')
        local email=$(echo "$user" | jq -r '.email')
        local level=$(echo "$user" | jq -r '.level')
        local enabled=$(echo "$user" | jq -r '.enabled')
        local created_at=$(echo "$user" | jq -r '.created_at')

        local status="启用"
        [[ "$enabled" == "false" ]] && status="禁用"

        printf "%-20s %-25s %-8s %-10s %-20s\n" "$username" "$email" "$level" "$status" "$created_at"
    done

    echo ""
}

# =============================================================================
# 修改用户
# =============================================================================

modify_user() {
    # 列出所有用户
    list_users

    # 选择用户
    read -p "请输入要修改的用户名: " username

    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    # 检查用户是否存在
    if ! check_username_exists "$username"; then
        print_error "用户不存在: $username"
        return 1
    fi

    # 获取当前用户信息
    local user=$(jq -r --arg username "$username" '.users[] | select(.username == $username)' "$USERS_FILE")

    print_info "当前用户信息:"
    echo "$user" | jq '.'

    echo ""
    echo "请选择要修改的项目:"
    echo "1) 密码"
    echo "2) 用户等级"
    echo "3) 启用/禁用"
    echo "4) 流量限制"
    echo "5) 过期时间"
    echo "0) 返回"

    read -p "请选择 [0]: " modify_choice
    modify_choice=${modify_choice:-0}

    local users_data=$(cat "$USERS_FILE")

    case "$modify_choice" in
        1)
            # 修改密码
            local new_password=$(generate_random_password 16)
            print_info "新密码: $new_password"

            users_data=$(echo "$users_data" | jq --arg username "$username" --arg password "$new_password" \
                '(.users[] | select(.username == $username) | .password) = $password')

            echo "$users_data" | jq '.' > "$USERS_FILE"
            print_success "密码已更新"
            ;;

        2)
            # 修改等级
            read -p "请输入新等级 (0-9): " new_level

            if ! [[ "$new_level" =~ ^[0-9]$ ]]; then
                print_error "等级必须是 0-9 之间的数字"
                return 1
            fi

            users_data=$(echo "$users_data" | jq --arg username "$username" --argjson level "$new_level" \
                '(.users[] | select(.username == $username) | .level) = $level')

            echo "$users_data" | jq '.' > "$USERS_FILE"
            print_success "等级已更新"
            ;;

        3)
            # 启用/禁用
            local current_status=$(echo "$user" | jq -r '.enabled')
            local new_status="true"
            [[ "$current_status" == "true" ]] && new_status="false"

            users_data=$(echo "$users_data" | jq --arg username "$username" --argjson enabled "$new_status" \
                '(.users[] | select(.username == $username) | .enabled) = $enabled')

            echo "$users_data" | jq '.' > "$USERS_FILE"

            if [[ "$new_status" == "true" ]]; then
                print_success "用户已启用"
            else
                print_success "用户已禁用"
            fi
            ;;

        4)
            # 修改流量限制
            read -p "请输入新的流量限制 (GB, 0=无限制): " limit_gb
            local new_limit=$((limit_gb * 1024 * 1024 * 1024))

            users_data=$(echo "$users_data" | jq --arg username "$username" --argjson limit "$new_limit" \
                '(.users[] | select(.username == $username) | .traffic_limit) = $limit')

            echo "$users_data" | jq '.' > "$USERS_FILE"
            print_success "流量限制已更新"
            ;;

        5)
            # 修改过期时间
            read -p "请输入有效天数 (0=永久): " days

            local new_expire=""
            if [[ $days -gt 0 ]]; then
                new_expire=$(date -u -d "+${days} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                             date -u -v+${days}d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
            fi

            users_data=$(echo "$users_data" | jq --arg username "$username" --arg expire "$new_expire" \
                '(.users[] | select(.username == $username) | .expire_time) = $expire')

            echo "$users_data" | jq '.' > "$USERS_FILE"
            print_success "过期时间已更新"
            ;;

        0)
            return 0
            ;;

        *)
            print_error "无效选择"
            return 1
            ;;
    esac

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
# 查看用户详情
# =============================================================================

show_user_info() {
    read -p "请输入用户名: " username

    if [[ -z "$username" ]]; then
        print_error "用户名不能为空"
        return 1
    fi

    if ! check_username_exists "$username"; then
        print_error "用户不存在: $username"
        return 1
    fi

    local user=$(jq -r --arg username "$username" '.users[] | select(.username == $username)' "$USERS_FILE")

    print_info "用户详细信息:"
    echo "$user" | jq '.'

    # 查找用户绑定的节点
    local uuid=$(echo "$user" | jq -r '.id')

    print_info "绑定的节点:"
    local bindings=$(jq -r --arg uuid "$uuid" '.bindings[] | select(.users[] == $uuid)' "$BINDINGS_FILE" 2>/dev/null)

    if [[ -z "$bindings" ]]; then
        print_warn "  无绑定节点"
    else
        echo "$bindings" | jq -r '"\(.protocol):\(.port)"'
    fi
}

# =============================================================================
# 辅助函数
# =============================================================================

# 绑定用户到节点
bind_user_to_nodes() {
    local uuid=$1

    # 列出所有可用节点
    source modules/node.sh
    list_nodes

    read -p "请输入要绑定的节点端口 (多个用空格分隔): " ports

    if [[ -z "$ports" ]]; then
        print_warn "未选择节点"
        return 0
    fi

    # 遍历端口
    for port in $ports; do
        # 获取节点协议
        local protocol=$(jq -r --arg port "$port" '.nodes[] | select(.port == $port) | .protocol' "${DATA_DIR}/nodes.json" 2>/dev/null)

        if [[ -z "$protocol" ]]; then
            print_warn "节点不存在: 端口 $port"
            continue
        fi

        # 检查绑定是否已存在
        local existing=$(jq -r --arg port "$port" --arg protocol "$protocol" \
            '.bindings[] | select(.port == $port and .protocol == $protocol)' "$BINDINGS_FILE" 2>/dev/null)

        local bindings_data=$(cat "$BINDINGS_FILE")

        if [[ -n "$existing" ]]; then
            # 更新现有绑定
            bindings_data=$(echo "$bindings_data" | jq --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" \
                '(.bindings[] | select(.port == $port and .protocol == $protocol) | .users) += [$uuid] | .bindings[].users |= unique')
        else
            # 创建新绑定
            local new_binding=$(jq -n \
                --arg port "$port" \
                --arg protocol "$protocol" \
                --arg uuid "$uuid" \
                '{port: $port, protocol: $protocol, users: [$uuid]}')

            bindings_data=$(echo "$bindings_data" | jq --argjson binding "$new_binding" '.bindings += [$binding]')
        fi

        echo "$bindings_data" | jq '.' > "$BINDINGS_FILE"
        print_success "已绑定到节点: $protocol:$port"
    done

    # 重新生成配置
    print_info "重新生成 sing-box 配置..."
    source modules/config_generator.sh
    generate_singbox_config
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
