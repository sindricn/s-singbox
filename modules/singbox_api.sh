#!/bin/bash

#================================================================
# sing-box API 动态管理模块
# 功能：通过 HandlerService API 动态管理用户，无需重启 sing-box
# 版本：v1.0.0
#================================================================

# API 配置
if [[ -z "${SINGBOX_BIN:-}" ]]; then
    SINGBOX_BIN="/usr/local/sing-box/sing-box"
fi
readonly API_ADDR="127.0.0.1:10085"

#================================================================
# 动态添加用户到指定 inbound
# 参数：
#   $1: inbound_tag (例如 "vless-443")
#   $2: 用户配置 JSON (包含 email, id/password, level, flow 等)
#================================================================
api_add_user() {
    local inbound_tag=$1
    local user_json=$2

    if [[ -z "$inbound_tag" || -z "$user_json" ]]; then
        echo "错误: 缺少必要参数" >&2
        return 1
    fi

    # 提取协议类型从 tag (例如 "vless-443" -> "vless")
    local protocol=$(echo "$inbound_tag" | cut -d'-' -f1)

    # 构建 API 命令
    local result=$($SINGBOX_BIN api adi --server=$API_ADDR --tag="$inbound_tag" --json="$user_json" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "✓ 成功添加用户到 $inbound_tag"
        return 0
    else
        echo "✗ 添加用户失败: $result" >&2
        return 1
    fi
}

#================================================================
# 动态删除用户从指定 inbound
# 参数：
#   $1: inbound_tag (例如 "vless-443")
#   $2: user_email (用户的 email 标识)
#================================================================
api_remove_user() {
    local inbound_tag=$1
    local user_email=$2

    if [[ -z "$inbound_tag" || -z "$user_email" ]]; then
        echo "错误: 缺少必要参数" >&2
        return 1
    fi

    # 构建 API 命令
    local result=$($SINGBOX_BIN api rmi --server=$API_ADDR --tag="$inbound_tag" "$user_email" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "✓ 成功从 $inbound_tag 删除用户 $user_email"
        return 0
    else
        echo "✗ 删除用户失败: $result" >&2
        return 1
    fi
}

#================================================================
# 从 inbound 删除用户然后重新添加（实现禁用/启用效果）
# 参数：
#   $1: inbound_tag
#   $2: user_email
#   $3: user_json (用于重新添加)
#================================================================
api_reload_user() {
    local inbound_tag=$1
    local user_email=$2
    local user_json=$3

    # 先删除
    api_remove_user "$inbound_tag" "$user_email" || true

    # 再添加
    if [[ -n "$user_json" ]]; then
        api_add_user "$inbound_tag" "$user_json"
    fi
}

#================================================================
# 动态禁用用户（从所有绑定的 inbound 中删除）
# 参数：
#   $1: uuid (用户 UUID)
#================================================================
api_disable_user() {
    local uuid=$1

    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo "错误: 节点用户绑定文件不存在" >&2
        return 1
    fi

    if [[ ! -f "$NODES_FILE" ]]; then
        echo "错误: 节点配置文件不存在" >&2
        return 1
    fi

    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        echo "错误: sing-box 配置文件不存在" >&2
        return 1
    fi

    # 获取用户的 email
    local email=$(jq -r ".inbounds[].settings.clients[]? | select(.id == \"$uuid\" or .password) | .email" "$SINGBOX_CONFIG" | head -1)

    if [[ -z "$email" || "$email" == "null" ]]; then
        echo "错误: 无法找到用户的 email" >&2
        return 1
    fi

    echo "正在禁用用户 $email (UUID: $uuid)..."

    # 查找用户绑定的所有节点端口
    local ports=$(jq -r ".bindings[] | select(.users[] == \"$uuid\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$ports" ]]; then
        echo "用户未绑定任何节点"
        return 0
    fi

    local success_count=0
    local fail_count=0

    while IFS= read -r port; do
        [[ -z "$port" ]] && continue

        # 获取该端口对应的节点信息
        local node=$(jq -r ".nodes[] | select(.port == \"$port\")" "$NODES_FILE")
        if [[ -z "$node" || "$node" == "null" ]]; then
            echo "  警告: 端口 $port 的节点配置不存在"
            continue
        fi

        local protocol=$(echo "$node" | jq -r '.protocol')
        local inbound_tag="${protocol}-${port}"

        # 从该 inbound 删除用户
        if api_remove_user "$inbound_tag" "$email"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done <<< "$ports"

    echo "禁用完成: 成功 $success_count, 失败 $fail_count"

    if [[ $fail_count -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

#================================================================
# 动态启用用户（重新添加到所有绑定的 inbound）
# 参数：
#   $1: uuid (用户 UUID)
#================================================================
api_enable_user() {
    local uuid=$1

    if [[ ! -f "$USERS_FILE" ]]; then
        echo "错误: 用户文件不存在" >&2
        return 1
    fi

    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo "错误: 节点用户绑定文件不存在" >&2
        return 1
    fi

    if [[ ! -f "$NODES_FILE" ]]; then
        echo "错误: 节点配置文件不存在" >&2
        return 1
    fi

    # 获取用户信息
    local user=$(jq -r ".users[] | select(.id == \"$uuid\")" "$USERS_FILE")
    if [[ -z "$user" || "$user" == "null" ]]; then
        echo "错误: 用户不存在" >&2
        return 1
    fi

    local email=$(echo "$user" | jq -r '.email // ""')
    local level=$(echo "$user" | jq -r '.level // 0')
    local password=$(echo "$user" | jq -r '.password // ""')

    # 如果 email 为空，使用 UUID
    if [[ -z "$email" || "$email" == "null" ]]; then
        email="${uuid}@local"
    fi

    echo "正在启用用户 $email (UUID: $uuid)..."

    # 查找用户绑定的所有节点端口
    local ports=$(jq -r ".bindings[] | select(.users[] == \"$uuid\") | .port" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$ports" ]]; then
        echo "用户未绑定任何节点"
        return 0
    fi

    local success_count=0
    local fail_count=0

    while IFS= read -r port; do
        [[ -z "$port" ]] && continue

        # 获取该端口对应的节点信息
        local node=$(jq -r ".nodes[] | select(.port == \"$port\")" "$NODES_FILE")
        if [[ -z "$node" || "$node" == "null" ]]; then
            echo "  警告: 端口 $port 的节点配置不存在"
            continue
        fi

        local protocol=$(echo "$node" | jq -r '.protocol')
        local security=$(echo "$node" | jq -r '.security // "none"')
        local extra=$(echo "$node" | jq -r '.extra // "{}"')
        local inbound_tag="${protocol}-${port}"

        # 根据协议生成用户配置
        local user_json=""
        case $protocol in
            vless|vmess)
                local flow=""
                if [[ "$security" == "reality" ]]; then
                    flow=$(echo "$extra" | jq -r '.flow // "xtls-rprx-vision"')
                fi

                if [[ -n "$flow" && "$flow" != "null" ]]; then
                    user_json=$(jq -n \
                        --arg id "$uuid" \
                        --arg email "$email" \
                        --argjson level "$level" \
                        --arg flow "$flow" \
                        '{id: $id, email: $email, level: $level, flow: $flow}')
                else
                    user_json=$(jq -n \
                        --arg id "$uuid" \
                        --arg email "$email" \
                        --argjson level "$level" \
                        '{id: $id, email: $email, level: $level}')
                fi
                ;;
            trojan|shadowsocks)
                user_json=$(jq -n \
                    --arg password "$password" \
                    --arg email "$email" \
                    --argjson level "$level" \
                    '{password: $password, email: $email, level: $level}')
                ;;
            *)
                echo "  警告: 不支持的协议 $protocol"
                continue
                ;;
        esac

        # 添加用户到该 inbound
        if api_add_user "$inbound_tag" "$user_json"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done <<< "$ports"

    echo "启用完成: 成功 $success_count, 失败 $fail_count"

    if [[ $fail_count -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

#================================================================
# 列出所有 inbound
#================================================================
api_list_inbounds() {
    $SINGBOX_BIN api li --server=$API_ADDR 2>&1
}

#================================================================
# 测试 API 连接
#================================================================
api_test_connection() {
    if ! ss -lnt 2>/dev/null | grep -q ":10085 " && ! netstat -lnt 2>/dev/null | grep -q ":10085 "; then
        echo "✗ API 端口 10085 未监听" >&2
        return 1
    fi

    # 尝试列出 inbound
    local result=$(api_list_inbounds 2>&1)
    if [[ $? -eq 0 ]]; then
        echo "✓ API 连接正常"
        echo "当前 inbound 列表:"
        echo "$result"
        return 0
    else
        echo "✗ API 连接失败: $result" >&2
        return 1
    fi
}
