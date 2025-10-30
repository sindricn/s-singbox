#!/bin/bash

# =============================================================================
# sing-box API 集成模块
# 功能：Clash API 管理、统计查询、连接管理
# =============================================================================

# API 配置
API_HOST="127.0.0.1"
API_PORT="9090"
API_SECRET=""

# =============================================================================
# API 配置管理
# =============================================================================

# 启用 Clash API
enable_clash_api() {
    print_info "启用 Clash API..."

    local SINGBOX_CONFIG_FILE="/usr/local/singbox/config.json"

    if [[ ! -f "$SINGBOX_CONFIG_FILE" ]]; then
        print_error "sing-box 配置文件不存在"
        return 1
    fi

    # 输入配置
    read -p "请输入 API 监听地址 [127.0.0.1]: " api_host
    api_host=${api_host:-127.0.0.1}

    read -p "请输入 API 监听端口 [9090]: " api_port
    api_port=${api_port:-9090}

    read -p "请输入 API Secret (留空则不设置): " api_secret

    # 生成 API 配置
    local api_config=$(jq -n \
        --arg controller "${api_host}:${api_port}" \
        --arg secret "$api_secret" \
        '{
            clash_api: {
                external_controller: $controller,
                secret: $secret
            }
        }')

    # 更新配置文件
    local config=$(cat "$SINGBOX_CONFIG_FILE")

    # 检查是否已有 experimental 配置
    if echo "$config" | jq -e '.experimental' >/dev/null 2>&1; then
        # 更新现有 experimental
        config=$(echo "$config" | jq --argjson api "$api_config" '.experimental.clash_api = $api.clash_api')
    else
        # 添加新的 experimental
        config=$(echo "$config" | jq --argjson api "$api_config" '.experimental = $api')
    fi

    # 写回配置
    echo "$config" | jq '.' > "$SINGBOX_CONFIG_FILE"

    print_success "Clash API 已启用"
    print_info "API 地址: http://${api_host}:${api_port}"

    if [[ -n "$api_secret" ]]; then
        print_info "API Secret: $api_secret"
    fi

    # 保存配置到环境变量
    API_HOST="$api_host"
    API_PORT="$api_port"
    API_SECRET="$api_secret"

    # 询问是否重启服务
    read -p "是否重启 sing-box 服务以应用配置? [Y/n]: " restart
    restart=${restart:-Y}

    if [[ "$restart" =~ ^[Yy]$ ]]; then
        systemctl restart sing-box
        print_success "服务已重启"
    fi

    return 0
}

# 禁用 Clash API
disable_clash_api() {
    print_info "禁用 Clash API..."

    local SINGBOX_CONFIG_FILE="/usr/local/singbox/config.json"

    if [[ ! -f "$SINGBOX_CONFIG_FILE" ]]; then
        print_error "sing-box 配置文件不存在"
        return 1
    fi

    # 删除 clash_api 配置
    local config=$(cat "$SINGBOX_CONFIG_FILE")
    config=$(echo "$config" | jq 'del(.experimental.clash_api)')

    # 写回配置
    echo "$config" | jq '.' > "$SINGBOX_CONFIG_FILE"

    print_success "Clash API 已禁用"

    # 询问是否重启服务
    read -p "是否重启 sing-box 服务以应用配置? [Y/n]: " restart
    restart=${restart:-Y}

    if [[ "$restart" =~ ^[Yy]$ ]]; then
        systemctl restart sing-box
        print_success "服务已重启"
    fi

    return 0
}

# =============================================================================
# API 查询函数
# =============================================================================

# 构建 API URL
build_api_url() {
    local endpoint=$1

    echo "http://${API_HOST}:${API_PORT}${endpoint}"
}

# 发送 API 请求
api_request() {
    local method=${1:-GET}
    local endpoint=$2
    local data=$3

    local url=$(build_api_url "$endpoint")

    local args=("-s" "-X" "$method")

    # 添加 Secret 头部
    if [[ -n "$API_SECRET" ]]; then
        args+=("-H" "Authorization: Bearer $API_SECRET")
    fi

    # 添加数据
    if [[ -n "$data" ]]; then
        args+=("-H" "Content-Type: application/json")
        args+=("-d" "$data")
    fi

    # 发送请求
    curl "${args[@]}" "$url" 2>/dev/null
}

# =============================================================================
# 流量统计查询
# =============================================================================

# 查询流量统计
get_traffic_stats() {
    print_info "查询流量统计..."

    local response=$(api_request GET "/traffic")

    if [[ -z "$response" ]]; then
        print_error "API 请求失败，请检查 Clash API 是否已启用"
        return 1
    fi

    # 解析响应
    local upload=$(echo "$response" | jq -r '.up // 0')
    local download=$(echo "$response" | jq -r '.down // 0')

    # 转换单位
    local upload_mb=$((upload / 1024 / 1024))
    local download_mb=$((download / 1024 / 1024))
    local upload_gb=$((upload / 1024 / 1024 / 1024))
    local download_gb=$((download / 1024 / 1024 / 1024))

    print_success "流量统计:"
    print_info "上传: ${upload_gb} GB (${upload_mb} MB)"
    print_info "下载: ${download_gb} GB (${download_mb} MB)"
    print_info "总计: $((upload_gb + download_gb)) GB"

    return 0
}

# 实时流量监控
watch_traffic_api() {
    print_info "实时流量监控 (Ctrl+C 退出)"
    echo ""

    # 获取初始流量
    local response=$(api_request GET "/traffic")
    local upload_start=$(echo "$response" | jq -r '.up // 0')
    local download_start=$(echo "$response" | jq -r '.down // 0')

    while true; do
        sleep 1

        # 获取当前流量
        local response=$(api_request GET "/traffic")

        if [[ -z "$response" ]]; then
            print_error "API 请求失败"
            break
        fi

        local upload=$(echo "$response" | jq -r '.up // 0')
        local download=$(echo "$response" | jq -r '.down // 0')

        # 计算速率（字节/秒）
        local upload_rate=$((upload - upload_start))
        local download_rate=$((download - download_start))

        # 转换为 KB/s
        local upload_kbps=$((upload_rate / 1024))
        local download_kbps=$((download_rate / 1024))

        # 清屏并显示
        clear
        echo -e "\033[32m实时流量监控 (API)\033[0m"
        echo "================================"
        echo -e "上传速率: \033[34m${upload_kbps} KB/s\033[0m"
        echo -e "下载速率: \033[34m${download_kbps} KB/s\033[0m"
        echo "================================"
        echo -e "总上传: $((upload / 1024 / 1024)) MB"
        echo -e "总下载: $((download / 1024 / 1024)) MB"

        # 更新起始值
        upload_start=$upload
        download_start=$download
    done
}

# =============================================================================
# 连接管理
# =============================================================================

# 查询所有连接
get_connections() {
    print_info "查询活动连接..."

    local response=$(api_request GET "/connections")

    if [[ -z "$response" ]]; then
        print_error "API 请求失败"
        return 1
    fi

    # 解析连接列表
    local connections=$(echo "$response" | jq -r '.connections[]')

    if [[ -z "$connections" ]]; then
        print_warn "暂无活动连接"
        return 0
    fi

    # 格式化输出
    echo "$response" | jq -r '.connections[] | "\(.id) - \(.metadata.network) - \(.metadata.sourceIP):\(.metadata.sourcePort) -> \(.metadata.destinationIP):\(.metadata.destinationPort)"'

    # 统计连接数
    local count=$(echo "$response" | jq '.connections | length')
    print_success "活动连接数: $count"

    return 0
}

# 关闭指定连接
close_connection() {
    read -p "请输入要关闭的连接 ID: " conn_id

    if [[ -z "$conn_id" ]]; then
        print_error "连接 ID 不能为空"
        return 1
    fi

    print_info "关闭连接: $conn_id"

    local response=$(api_request DELETE "/connections/$conn_id")

    if [[ $? -eq 0 ]]; then
        print_success "连接已关闭"
    else
        print_error "连接关闭失败"
        return 1
    fi
}

# 关闭所有连接
close_all_connections() {
    print_warn "此操作将关闭所有活动连接"

    read -p "确认关闭所有连接? [y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return 0
    fi

    print_info "关闭所有连接..."

    local response=$(api_request DELETE "/connections")

    if [[ $? -eq 0 ]]; then
        print_success "所有连接已关闭"
    else
        print_error "操作失败"
        return 1
    fi
}

# =============================================================================
# 规则和代理管理
# =============================================================================

# 查询规则
get_rules() {
    print_info "查询路由规则..."

    local response=$(api_request GET "/rules")

    if [[ -z "$response" ]]; then
        print_error "API 请求失败"
        return 1
    fi

    echo "$response" | jq '.'
}

# 查询代理
get_proxies() {
    print_info "查询代理节点..."

    local response=$(api_request GET "/proxies")

    if [[ -z "$response" ]]; then
        print_error "API 请求失败"
        return 1
    fi

    echo "$response" | jq '.'
}

# =============================================================================
# 配置重载
# =============================================================================

# 重载配置
reload_config_api() {
    print_info "通过 API 重载配置..."

    local response=$(api_request PUT "/configs" '{"path": "/usr/local/singbox/config.json"}')

    if [[ $? -eq 0 ]]; then
        print_success "配置已重载"
    else
        print_error "配置重载失败"
        return 1
    fi
}

# =============================================================================
# API 菜单
# =============================================================================

api_menu() {
    while true; do
        clear
        print_header "sing-box API 管理"

        echo "1)  启用 Clash API"
        echo "2)  禁用 Clash API"
        echo "3)  查询流量统计"
        echo "4)  实时流量监控"
        echo "5)  查询活动连接"
        echo "6)  关闭指定连接"
        echo "7)  关闭所有连接"
        echo "8)  查询路由规则"
        echo "9)  查询代理节点"
        echo "10) 重载配置"
        echo ""
        echo "0)  返回主菜单"
        echo ""

        read -p "请选择: " choice

        case "$choice" in
            1)
                enable_clash_api
                read -p "按回车键继续..."
                ;;
            2)
                disable_clash_api
                read -p "按回车键继续..."
                ;;
            3)
                get_traffic_stats
                read -p "按回车键继续..."
                ;;
            4)
                watch_traffic_api
                ;;
            5)
                get_connections
                read -p "按回车键继续..."
                ;;
            6)
                close_connection
                read -p "按回车键继续..."
                ;;
            7)
                close_all_connections
                read -p "按回车键继续..."
                ;;
            8)
                get_rules
                read -p "按回车键继续..."
                ;;
            9)
                get_proxies
                read -p "按回车键继续..."
                ;;
            10)
                reload_config_api
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# 通用打印函数
# =============================================================================

print_header() {
    echo ""
    echo -e "\033[32m======================================\033[0m"
    echo -e "\033[32m  $1\033[0m"
    echo -e "\033[32m======================================\033[0m"
    echo ""
}

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
