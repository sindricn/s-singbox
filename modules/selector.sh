#!/bin/bash

# =============================================================================
# selector.sh - 选择器模块
# 提供统一的节点/用户选择接口，避免代码重复
# =============================================================================

# 依赖检查
if [[ -z "${SCRIPT_DIR}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# 加载依赖模块
if ! declare -f print_error &>/dev/null; then
    source "${SCRIPT_DIR}/modules/common.sh"
fi

# =============================================================================
# 节点选择器
# =============================================================================

# 选择节点（通过端口）
select_node() {
    local prompt="${1:-请选择节点}"
    local nodes_file="${DATA_DIR}/nodes.json"

    if [[ ! -f "$nodes_file" ]]; then
        log_error "节点数据文件不存在"
        return 1
    fi

    # 读取节点列表
    local nodes=$(jq -r '.nodes[] | "\(.port)|\(.protocol)|\(.transport)|\(.security)"' "$nodes_file" 2>/dev/null)

    if [[ -z "$nodes" ]]; then
        log_error "没有可用的节点"
        return 1
    fi

    # 显示节点列表
    echo ""
    print_header "节点列表"

    local index=1
    while IFS='|' read -r port protocol transport security; do
        echo -e "${CYAN}$index)${NC} 端口:${YELLOW}$port${NC} | 协议:${GREEN}$protocol${NC} | 传输:$transport | 安全:$security"
        ((index++))
    done <<< "$nodes"

    echo ""

    # 用户选择
    local choice
    read -p "$(echo -e ${CYAN}${prompt}${NC} [1-$((index-1))]: )" choice

    # 验证选择
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt $((index-1)) ]]; then
        log_error "无效的选择"
        return 1
    fi

    # 获取选中的端口
    local selected_port=$(echo "$nodes" | sed -n "${choice}p" | cut -d'|' -f1)

    if [[ -z "$selected_port" ]]; then
        log_error "获取端口失败"
        return 1
    fi

    # 返回端口
    echo "$selected_port"
    return 0
}

# 通过索引获取节点端口
get_node_port_by_index() {
    local index=$1
    local nodes_file="${DATA_DIR}/nodes.json"

    if [[ ! -f "$nodes_file" ]]; then
        return 1
    fi

    local port=$(jq -r ".nodes[$((index-1))].port" "$nodes_file" 2>/dev/null)

    if [[ "$port" == "null" || -z "$port" ]]; then
        return 1
    fi

    echo "$port"
    return 0
}

# 通过端口获取节点信息
get_node_by_port() {
    local port=$1
    local nodes_file="${DATA_DIR}/nodes.json"

    if [[ ! -f "$nodes_file" ]]; then
        return 1
    fi

    local node=$(jq -r ".nodes[] | select(.port == $port)" "$nodes_file" 2>/dev/null)

    if [[ -z "$node" || "$node" == "null" ]]; then
        return 1
    fi

    echo "$node"
    return 0
}

# 列出所有节点端口
list_node_ports() {
    local nodes_file="${DATA_DIR}/nodes.json"

    if [[ ! -f "$nodes_file" ]]; then
        return 1
    fi

    jq -r '.nodes[].port' "$nodes_file" 2>/dev/null
}

# =============================================================================
# 用户选择器
# =============================================================================

# 选择用户（返回 UUID）
select_user() {
    local prompt="${1:-请选择用户}"
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        log_error "用户数据文件不存在"
        return 1
    fi

    # 读取用户列表
    local users=$(jq -r '.users[] | "\(.id)|\(.username)|\(.email)|\(.enabled)"' "$users_file" 2>/dev/null)

    if [[ -z "$users" ]]; then
        log_error "没有可用的用户"
        return 1
    fi

    # 显示用户列表
    echo ""
    print_header "用户列表"

    local index=1
    while IFS='|' read -r id username email enabled; do
        local status_color="${GREEN}"
        local status_text="启用"
        if [[ "$enabled" == "false" ]]; then
            status_color="${RED}"
            status_text="禁用"
        fi

        echo -e "${CYAN}$index)${NC} 用户:${YELLOW}$username${NC} | 邮箱:$email | 状态:${status_color}$status_text${NC}"
        ((index++))
    done <<< "$users"

    echo ""

    # 用户选择
    local choice
    read -p "$(echo -e ${CYAN}${prompt}${NC} [1-$((index-1))]: )" choice

    # 验证选择
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt $((index-1)) ]]; then
        log_error "无效的选择"
        return 1
    fi

    # 获取选中的 UUID
    local selected_uuid=$(echo "$users" | sed -n "${choice}p" | cut -d'|' -f1)

    if [[ -z "$selected_uuid" ]]; then
        log_error "获取用户ID失败"
        return 1
    fi

    # 返回 UUID
    echo "$selected_uuid"
    return 0
}

# 通过用户名选择用户（返回 UUID）
select_user_by_username() {
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        log_error "用户数据文件不存在"
        return 1
    fi

    # 输入用户名
    local username
    read -p "$(echo -e ${CYAN}请输入用户名${NC}: )" username

    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        return 1
    fi

    # 查找用户
    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$users_file" 2>/dev/null)

    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        log_error "用户 '$username' 不存在"
        return 1
    fi

    echo "$uuid"
    return 0
}

# 通过索引获取用户 UUID
get_user_uuid_by_index() {
    local index=$1
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 1
    fi

    local uuid=$(jq -r ".users[$((index-1))].id" "$users_file" 2>/dev/null)

    if [[ "$uuid" == "null" || -z "$uuid" ]]; then
        return 1
    fi

    echo "$uuid"
    return 0
}

# 通过 UUID 获取用户信息
get_user_by_uuid() {
    local uuid=$1
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 1
    fi

    local user=$(jq -r ".users[] | select(.id == \"$uuid\")" "$users_file" 2>/dev/null)

    if [[ -z "$user" || "$user" == "null" ]]; then
        return 1
    fi

    echo "$user"
    return 0
}

# 通过用户名获取 UUID
get_uuid_by_username() {
    local username=$1
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 1
    fi

    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$users_file" 2>/dev/null)

    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        return 1
    fi

    echo "$uuid"
    return 0
}

# 通过 UUID 获取用户名
get_username_by_uuid() {
    local uuid=$1
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 1
    fi

    local username=$(jq -r ".users[] | select(.id == \"$uuid\") | .username" "$users_file" 2>/dev/null)

    if [[ -z "$username" || "$username" == "null" ]]; then
        return 1
    fi

    echo "$username"
    return 0
}

# 列出所有用户 UUID
list_user_uuids() {
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 1
    fi

    jq -r '.users[].id' "$users_file" 2>/dev/null
}

# 列出所有启用的用户 UUID
list_enabled_user_uuids() {
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 1
    fi

    jq -r '.users[] | select(.enabled == true) | .id' "$users_file" 2>/dev/null
}

# =============================================================================
# 多选选择器
# =============================================================================

# 多选用户（返回 UUID 数组）
select_multiple_users() {
    local prompt="${1:-请选择用户（逗号分隔多个选项）}"
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        log_error "用户数据文件不存在"
        return 1
    fi

    # 读取用户列表
    local users=$(jq -r '.users[] | "\(.id)|\(.username)|\(.email)|\(.enabled)"' "$users_file" 2>/dev/null)

    if [[ -z "$users" ]]; then
        log_error "没有可用的用户"
        return 1
    fi

    # 显示用户列表
    echo ""
    print_header "用户列表"

    local index=1
    declare -A index_to_uuid

    while IFS='|' read -r id username email enabled; do
        local status_color="${GREEN}"
        local status_text="启用"
        if [[ "$enabled" == "false" ]]; then
            status_color="${RED}"
            status_text="禁用"
        fi

        echo -e "${CYAN}$index)${NC} 用户:${YELLOW}$username${NC} | 邮箱:$email | 状态:${status_color}$status_text${NC}"
        index_to_uuid[$index]="$id"
        ((index++))
    done <<< "$users"

    echo ""
    echo -e "${YELLOW}提示：输入多个编号用逗号分隔，如: 1,3,5${NC}"

    # 用户选择
    local choices
    read -p "$(echo -e ${CYAN}${prompt}${NC}: )" choices

    if [[ -z "$choices" ]]; then
        log_error "请至少选择一个用户"
        return 1
    fi

    # 解析选择
    local selected_uuids=()
    IFS=',' read -ra choice_array <<< "$choices"

    for choice in "${choice_array[@]}"; do
        choice=$(echo "$choice" | xargs) # 去除空格

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt $((index-1)) ]]; then
            log_error "无效的选择: $choice"
            return 1
        fi

        local uuid="${index_to_uuid[$choice]}"
        if [[ -n "$uuid" ]]; then
            selected_uuids+=("$uuid")
        fi
    done

    if [[ ${#selected_uuids[@]} -eq 0 ]]; then
        log_error "没有选中任何用户"
        return 1
    fi

    # 返回 UUID 数组（每行一个）
    printf '%s\n' "${selected_uuids[@]}"
    return 0
}

# =============================================================================
# 验证函数
# =============================================================================

# 验证节点是否存在
node_exists() {
    local port=$1
    local nodes_file="${DATA_DIR}/nodes.json"

    if [[ ! -f "$nodes_file" ]]; then
        return 1
    fi

    local exists=$(jq -r ".nodes[] | select(.port == $port) | .port" "$nodes_file" 2>/dev/null)

    if [[ -n "$exists" && "$exists" != "null" ]]; then
        return 0
    else
        return 1
    fi
}

# 验证用户是否存在
user_exists() {
    local uuid=$1
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 1
    fi

    local exists=$(jq -r ".users[] | select(.id == \"$uuid\") | .id" "$users_file" 2>/dev/null)

    if [[ -n "$exists" && "$exists" != "null" ]]; then
        return 0
    else
        return 1
    fi
}

# 验证用户名是否存在
username_exists() {
    local username=$1
    local users_file="${DATA_DIR}/users.json"

    if [[ ! -f "$users_file" ]]; then
        return 1
    fi

    local exists=$(jq -r ".users[] | select(.username == \"$username\") | .username" "$users_file" 2>/dev/null)

    if [[ -n "$exists" && "$exists" != "null" ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# 模块初始化
# =============================================================================

log_debug "selector.sh 模块已加载"
