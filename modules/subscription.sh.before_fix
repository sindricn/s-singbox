#!/bin/bash

# =============================================================================
# sing-box 订阅管理模块
# 功能：订阅源管理、节点导入、自动更新
# =============================================================================

DATA_DIR="./data"
SUBSCRIPTIONS_FILE="${DATA_DIR}/subscriptions.json"
NODES_FILE="${DATA_DIR}/nodes.json"

# =============================================================================
# 订阅数据初始化
# =============================================================================

init_subscriptions_file() {
    if [[ ! -f "$SUBSCRIPTIONS_FILE" ]]; then
        cat > "$SUBSCRIPTIONS_FILE" <<EOF
{
  "subscriptions": []
}
EOF
        print_success "subscriptions.json 初始化完成"
    fi
}

# =============================================================================
# 订阅链接解析器
# =============================================================================

# Base64 解码
base64_decode() {
    local encoded=$1

    # 尝试多种 base64 解码方式
    if command -v base64 &>/dev/null; then
        echo "$encoded" | base64 -d 2>/dev/null || \
        echo "$encoded" | base64 --decode 2>/dev/null
    else
        python3 -c "import base64, sys; print(base64.b64decode(sys.argv[1]).decode())" "$encoded" 2>/dev/null
    fi
}

# 解析 Shadowsocks 链接 (ss://)
parse_ss_link() {
    local link=$1

    # 移除前缀
    link=${link#ss://}

    # Base64 解码
    local decoded=$(base64_decode "$link")

    if [[ -z "$decoded" ]]; then
        print_warn "SS 链接解析失败: 无法解码"
        return 1
    fi

    # 格式: method:password@host:port
    local method=$(echo "$decoded" | cut -d: -f1)
    local rest=$(echo "$decoded" | cut -d: -f2-)
    local password=$(echo "$rest" | cut -d@ -f1)
    local server=$(echo "$rest" | cut -d@ -f2 | cut -d: -f1)
    local port=$(echo "$rest" | cut -d@ -f2 | cut -d: -f2)

    # 生成节点配置
    local tag="ss-sub-${port}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "shadowsocks" \
        --arg transport "tcp" \
        --arg security "none" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --arg method "$method" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: {
                method: $method
            }
        }')

    echo "$node"
}

# 解析 Trojan 链接 (trojan://)
parse_trojan_link() {
    local link=$1

    # 移除前缀
    link=${link#trojan://}

    # 格式: password@host:port
    local password=$(echo "$link" | cut -d@ -f1)
    local server=$(echo "$link" | cut -d@ -f2 | cut -d: -f1)
    local port=$(echo "$link" | cut -d@ -f2 | cut -d: -f2 | cut -d? -f1)

    # 提取查询参数
    local query=$(echo "$link" | grep -oP '\?.*' | sed 's/^?//')

    local sni=""
    if [[ -n "$query" ]]; then
        sni=$(echo "$query" | grep -oP 'sni=\K[^&]+' || echo "")
    fi

    # 生成节点配置
    local tag="trojan-sub-${port}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local tls_config=$(jq -n \
        --argjson enabled true \
        --arg server_name "$sni" \
        '{
            enabled: $enabled,
            server_name: $server_name
        }')

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "trojan" \
        --arg transport "tcp" \
        --arg security "tls" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --argjson tls "$tls_config" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: {
                tls: $tls
            }
        }')

    echo "$node"
}

# 解析 Hysteria2 链接 (hysteria2:// 或 hy2://)
parse_hysteria2_link() {
    local link=$1

    # 移除前缀
    link=${link#hysteria2://}
    link=${link#hy2://}

    # 格式: password@host:port
    local password=$(echo "$link" | cut -d@ -f1)
    local server=$(echo "$link" | cut -d@ -f2 | cut -d: -f1)
    local port=$(echo "$link" | cut -d@ -f2 | cut -d: -f2 | cut -d? -f1)

    # 提取查询参数
    local query=$(echo "$link" | grep -oP '\?.*' | sed 's/^?//')

    local sni=""
    local obfs=""
    if [[ -n "$query" ]]; then
        sni=$(echo "$query" | grep -oP 'sni=\K[^&]+' || echo "")
        obfs=$(echo "$query" | grep -oP 'obfs=\K[^&]+' || echo "")
    fi

    # 生成节点配置
    local tag="hy2-sub-${port}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local tls_config=$(jq -n \
        --argjson enabled true \
        --arg server_name "$sni" \
        '{
            enabled: $enabled,
            server_name: $server_name
        }')

    local obfs_config="{}"
    if [[ -n "$obfs" ]]; then
        obfs_config=$(jq -n \
            --arg password "$obfs" \
            '{
                type: "salamander",
                password: $password
            }')
    fi

    local node=$(jq -n \
        --arg port "$port" \
        --arg protocol "hysteria2" \
        --arg transport "udp" \
        --arg security "tls" \
        --arg listen "0.0.0.0" \
        --arg tag "$tag" \
        --arg timestamp "$timestamp" \
        --argjson tls "$tls_config" \
        --argjson obfs "$obfs_config" \
        '{
            port: $port,
            protocol: $protocol,
            transport: $transport,
            security: $security,
            listen: $listen,
            tag: $tag,
            created_at: $timestamp,
            extra: {
                tls: $tls,
                obfs: $obfs
            }
        }')

    echo "$node"
}

# =============================================================================
# 订阅操作函数
# =============================================================================

# 添加订阅源
add_subscription() {
    print_info "添加订阅源"

    # 输入订阅信息
    read -p "请输入订阅名称: " name

    if [[ -z "$name" ]]; then
        print_error "订阅名称不能为空"
        return 1
    fi

    read -p "请输入订阅 URL: " url

    if [[ -z "$url" ]]; then
        print_error "订阅 URL 不能为空"
        return 1
    fi

    # 检查订阅是否已存在
    local existing=$(jq -r --arg name "$name" '.subscriptions[] | select(.name == $name)' "$SUBSCRIPTIONS_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        print_error "订阅名称已存在: $name"
        return 1
    fi

    # 生成订阅配置
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local subscription=$(jq -n \
        --arg name "$name" \
        --arg url "$url" \
        --arg timestamp "$timestamp" \
        '{
            name: $name,
            url: $url,
            created_at: $timestamp,
            last_update: "",
            node_count: 0
        }')

    # 添加到 subscriptions.json
    local subs_data=$(cat "$SUBSCRIPTIONS_FILE")
    subs_data=$(echo "$subs_data" | jq --argjson sub "$subscription" '.subscriptions += [$sub]')
    echo "$subs_data" | jq '.' > "$SUBSCRIPTIONS_FILE"

    print_success "订阅源添加成功: $name"

    # 询问是否立即更新
    read -p "是否立即拉取订阅? [Y/n]: " fetch_now
    fetch_now=${fetch_now:-Y}

    if [[ "$fetch_now" =~ ^[Yy]$ ]]; then
        update_subscription "$name"
    fi

    return 0
}

# 更新订阅
update_subscription() {
    local name=$1

    if [[ -z "$name" ]]; then
        read -p "请输入订阅名称: " name
    fi

    # 获取订阅 URL
    local url=$(jq -r --arg name "$name" '.subscriptions[] | select(.name == $name) | .url' "$SUBSCRIPTIONS_FILE" 2>/dev/null)

    if [[ -z "$url" ]]; then
        print_error "订阅不存在: $name"
        return 1
    fi

    print_info "拉取订阅: $name"
    print_info "URL: $url"

    # 下载订阅内容
    local content=$(curl -sL "$url" --max-time 30)

    if [[ -z "$content" ]]; then
        print_error "订阅拉取失败: 无法获取内容"
        return 1
    fi

    # 尝试 Base64 解码
    local decoded=$(base64_decode "$content")

    if [[ -n "$decoded" ]]; then
        content="$decoded"
    fi

    # 解析订阅链接
    local node_count=0

    # 按行分割
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local node=""

        case "$line" in
            ss://*)
                node=$(parse_ss_link "$line")
                ;;
            trojan://*)
                node=$(parse_trojan_link "$line")
                ;;
            hysteria2://*|hy2://*)
                node=$(parse_hysteria2_link "$line")
                ;;
            *)
                # 跳过未知协议
                continue
                ;;
        esac

        # 添加节点到 nodes.json
        if [[ -n "$node" ]]; then
            local nodes_data=$(cat "$NODES_FILE")

            # 检查节点是否已存在 (根据端口和协议)
            local port=$(echo "$node" | jq -r '.port')
            local protocol=$(echo "$node" | jq -r '.protocol')
            local existing=$(jq -r --arg port "$port" --arg protocol "$protocol" \
                '.nodes[] | select(.port == $port and .protocol == $protocol)' "$NODES_FILE" 2>/dev/null)

            if [[ -z "$existing" ]]; then
                nodes_data=$(echo "$nodes_data" | jq --argjson node "$node" '.nodes += [$node]')
                echo "$nodes_data" | jq '.' > "$NODES_FILE"
                ((node_count++))
                print_success "导入节点: $(echo "$node" | jq -r '.tag')"
            else
                print_warn "节点已存在，跳过: $protocol:$port"
            fi
        fi
    done <<< "$content"

    # 更新订阅信息
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local subs_data=$(cat "$SUBSCRIPTIONS_FILE")
    subs_data=$(echo "$subs_data" | jq --arg name "$name" --arg timestamp "$timestamp" --argjson count "$node_count" \
        '(.subscriptions[] | select(.name == $name) | .last_update) = $timestamp |
         (.subscriptions[] | select(.name == $name) | .node_count) = $count')
    echo "$subs_data" | jq '.' > "$SUBSCRIPTIONS_FILE"

    print_success "订阅更新完成: 导入 $node_count 个新节点"

    # 重新生成配置
    if [[ $node_count -gt 0 ]]; then
        print_info "重新生成 sing-box 配置..."
        source modules/config_generator.sh
        generate_singbox_config

        read -p "是否重载 sing-box 服务? [Y/n]: " reload_service
        reload_service=${reload_service:-Y}

        if [[ "$reload_service" =~ ^[Yy]$ ]]; then
            systemctl reload sing-box 2>/dev/null || print_warn "服务重载失败或服务未运行"
        fi
    fi

    return 0
}

# 删除订阅
delete_subscription() {
    # 列出所有订阅
    list_subscriptions

    read -p "请输入要删除的订阅名称: " name

    if [[ -z "$name" ]]; then
        print_error "订阅名称不能为空"
        return 1
    fi

    # 检查订阅是否存在
    local existing=$(jq -r --arg name "$name" '.subscriptions[] | select(.name == $name)' "$SUBSCRIPTIONS_FILE" 2>/dev/null)

    if [[ -z "$existing" ]]; then
        print_error "订阅不存在: $name"
        return 1
    fi

    # 确认删除
    read -p "确认删除订阅 $name? [y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return 0
    fi

    # 从 subscriptions.json 删除
    local subs_data=$(cat "$SUBSCRIPTIONS_FILE")
    subs_data=$(echo "$subs_data" | jq --arg name "$name" '.subscriptions = [.subscriptions[] | select(.name != $name)]')
    echo "$subs_data" | jq '.' > "$SUBSCRIPTIONS_FILE"

    print_success "订阅已删除: $name"

    # 询问是否删除相关节点
    read -p "是否删除订阅导入的节点? [y/N]: " delete_nodes
    delete_nodes=${delete_nodes:-N}

    if [[ "$delete_nodes" =~ ^[Yy]$ ]]; then
        # 删除标签包含 "sub" 的节点
        local nodes_data=$(cat "$NODES_FILE")
        nodes_data=$(echo "$nodes_data" | jq '.nodes = [.nodes[] | select(.tag | contains("sub") | not)]')
        echo "$nodes_data" | jq '.' > "$NODES_FILE"

        print_success "订阅节点已删除"
    fi

    return 0
}

# 列出所有订阅
list_subscriptions() {
    print_info "订阅列表:"

    local subs=$(jq -r '.subscriptions[]' "$SUBSCRIPTIONS_FILE" 2>/dev/null)

    if [[ -z "$subs" ]]; then
        print_warn "暂无订阅"
        return 0
    fi

    # 表头
    printf "%-20s %-10s %-20s\n" "名称" "节点数" "最后更新"
    printf "%-20s %-10s %-20s\n" "----" "------" "--------"

    # 遍历订阅
    local sub_count=$(jq '.subscriptions | length' "$SUBSCRIPTIONS_FILE")

    for ((i=0; i<sub_count; i++)); do
        local sub=$(jq -r ".subscriptions[$i]" "$SUBSCRIPTIONS_FILE")
        local name=$(echo "$sub" | jq -r '.name')
        local node_count=$(echo "$sub" | jq -r '.node_count')
        local last_update=$(echo "$sub" | jq -r '.last_update')

        [[ "$last_update" == "" ]] && last_update="从未更新"

        printf "%-20s %-10s %-20s\n" "$name" "$node_count" "$last_update"
    done

    echo ""
}

# 更新所有订阅
update_all_subscriptions() {
    print_info "更新所有订阅..."

    local sub_count=$(jq '.subscriptions | length' "$SUBSCRIPTIONS_FILE")

    if [[ $sub_count -eq 0 ]]; then
        print_warn "暂无订阅"
        return 0
    fi

    for ((i=0; i<sub_count; i++)); do
        local name=$(jq -r ".subscriptions[$i].name" "$SUBSCRIPTIONS_FILE")
        echo ""
        update_subscription "$name"
    done

    print_success "所有订阅更新完成"
}

# =============================================================================
# 通用打印函数
# =============================================================================

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

# 初始化
init_subscriptions_file
