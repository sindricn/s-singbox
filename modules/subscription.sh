#!/bin/bash

#================================================================
# 订阅管理模块 - 修复版
# 功能：生成有效的订阅链接、支持用户绑定、查看单个节点链接
# 修复：订阅链接生成逻辑、用户绑定、admin默认用户
# 新增：订阅元数据管理（有效期、流量限制）
#================================================================

# 订阅元数据文件
SUBSCRIPTION_META_FILE="${DATA_DIR}/subscription_metadata.json"

# 获取用户绑定的节点端口列表
# 参数: $1=user_id
# 返回: 通过user_node_ports数组返回端口列表
get_user_bound_ports() {
    local user_id="$1"
    user_node_ports=()

    if [[ -z "$user_id" || ! -f "$NODE_USERS_FILE" ]]; then
        return 0
    fi

    while IFS= read -r binding; do
        local bport=$(echo "$binding" | jq -r '.port')
        local users=$(echo "$binding" | jq -r '.users[]')

        # 检查用户是否在该节点的用户列表中
        if echo "$users" | grep -q "$user_id"; then
            user_node_ports+=("$bport")
        fi
    done < <(jq -c '.bindings[]' "$NODE_USERS_FILE" 2>/dev/null)
}

# 查找订阅文件的实际路径
# 参数: 订阅基础名称 (不带后缀)
# 返回: 实际文件路径，如果不存在返回空
find_subscription_file() {
    local sub_name="$1"
    local user_id=""
    local sub_type=""

    if [[ -f "$SUBSCRIPTION_META_FILE" ]]; then
        local meta=$(jq -r ".subscriptions[] | select(.name == \"$sub_name\")" "$SUBSCRIPTION_META_FILE" 2>/dev/null)
        if [[ -n "$meta" && "$meta" != "null" ]]; then
            user_id=$(echo "$meta" | jq -r '.user_id // empty')
            sub_type=$(echo "$meta" | jq -r '.type // empty')
        fi
    fi

    # 尝试所有可能的后缀
    local possible_files=(
        "${SUBSCRIPTION_DIR}/${sub_name}.txt"
        "${SUBSCRIPTION_DIR}/${sub_name}_raw.txt"
        "${SUBSCRIPTION_DIR}/${sub_name}_clash.yaml"
        "${SUBSCRIPTION_DIR}/${sub_name}_singbox.json"
    )

    if [[ -n "$user_id" ]]; then
        case "$sub_type" in
            clash|3)
                possible_files+=("${SUBSCRIPTION_DIR}/${sub_name}_${user_id}_clash.yaml")
                ;;
            singbox|4)
                possible_files+=("${SUBSCRIPTION_DIR}/${sub_name}_${user_id}_singbox.json")
                ;;
            raw|2)
                possible_files+=("${SUBSCRIPTION_DIR}/${sub_name}_${user_id}_raw.txt")
                ;;
            *)
                possible_files+=("${SUBSCRIPTION_DIR}/${sub_name}_${user_id}_base64.txt")
                ;;
        esac
    fi

    while IFS= read -r candidate; do
        if [[ -n "$candidate" ]]; then
            possible_files+=("$candidate")
        fi
    done < <(find "$SUBSCRIPTION_DIR" -maxdepth 1 -type f -name "${sub_name}_*" 2>/dev/null)

    for file in "${possible_files[@]}"; do
        if [[ -f "$file" ]]; then
            echo "$file"
            return 0
        fi
    done

    # 如果都没找到，返回空
    return 1
}

# 初始化订阅元数据文件
init_subscription_metadata() {
    if [[ ! -f "$SUBSCRIPTION_META_FILE" ]]; then
        echo '{"subscriptions":[]}' > "$SUBSCRIPTION_META_FILE"
    fi
}

# 保存订阅元数据
# 参数: sub_name, expire_date, traffic_limit_gb, traffic_used_gb, user_id
save_subscription_metadata() {
    local sub_name="$1"
    local user_id="$2"        # 用户ID
    local sub_type="$3"       # 订阅类型

    init_subscription_metadata

    local metadata=$(jq -n \
        --arg name "$sub_name" \
        --arg user_id "$user_id" \
        --arg type "$sub_type" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        --arg updated "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{name: $name, user_id: $user_id, type: $type, created: $created, updated: $updated}')

    # 检查订阅是否已存在
    local existing=$(jq -r ".subscriptions[] | select(.name == \"$sub_name\") | .name" "$SUBSCRIPTION_META_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        # 更新现有元数据
        if ! jq ".subscriptions |= map(if .name == \"$sub_name\" then . + {type: \"$sub_type\", updated: \"$(date '+%Y-%m-%d %H:%M:%S')\"} else . end)" \
            "$SUBSCRIPTION_META_FILE" > "${SUBSCRIPTION_META_FILE}.tmp"; then
            print_error "更新订阅元数据失败"
            rm -f "${SUBSCRIPTION_META_FILE}.tmp"
            return 1
        fi
    else
        # 添加新元数据
        if ! jq ".subscriptions += [$metadata]" "$SUBSCRIPTION_META_FILE" > "${SUBSCRIPTION_META_FILE}.tmp"; then
            print_error "添加订阅元数据失败"
            rm -f "${SUBSCRIPTION_META_FILE}.tmp"
            return 1
        fi
    fi

    mv "${SUBSCRIPTION_META_FILE}.tmp" "$SUBSCRIPTION_META_FILE"
}

# 获取订阅元数据
get_subscription_metadata() {
    local sub_name="$1"

    if [[ ! -f "$SUBSCRIPTION_META_FILE" ]]; then
        echo "{}"
        return
    fi

    local metadata=$(jq -r ".subscriptions[] | select(.name == \"$sub_name\")" "$SUBSCRIPTION_META_FILE" 2>/dev/null)

    if [[ -z "$metadata" || "$metadata" == "null" ]]; then
        echo "{}"
    else
        echo "$metadata"
    fi
}

# 删除订阅元数据
delete_subscription_metadata() {
    local sub_name="$1"

    if [[ ! -f "$SUBSCRIPTION_META_FILE" ]]; then
        return 0
    fi

    # 使用--arg传递参数，避免特殊字符问题
    if ! jq --arg name "$sub_name" '.subscriptions |= map(select(.name != $name))' "$SUBSCRIPTION_META_FILE" > "${SUBSCRIPTION_META_FILE}.tmp"; then
        print_error "删除订阅元数据失败"
        rm -f "${SUBSCRIPTION_META_FILE}.tmp"
        return 1
    fi
    mv "${SUBSCRIPTION_META_FILE}.tmp" "$SUBSCRIPTION_META_FILE"
}

# 检查订阅是否过期
is_subscription_expired() {
    local sub_name="$1"
    local metadata=$(get_subscription_metadata "$sub_name")

    if [[ -z "$metadata" || "$metadata" == "{}" ]]; then
        return 1  # 没有元数据，默认不过期
    fi

    local expire_date=$(echo "$metadata" | jq -r '.expire_date // "unlimited"')

    if [[ "$expire_date" == "unlimited" ]]; then
        return 1  # 无限期
    fi

    local expire_timestamp=$(date -d "$expire_date" +%s 2>/dev/null)
    local current_timestamp=$(date +%s)

    if [[ $current_timestamp -gt $expire_timestamp ]]; then
        return 0  # 已过期
    else
        return 1  # 未过期
    fi
}

# 检查订阅流量是否超限
is_subscription_traffic_exceeded() {
    local sub_name="$1"
    local metadata=$(get_subscription_metadata "$sub_name")

    if [[ -z "$metadata" || "$metadata" == "{}" ]]; then
        return 1  # 没有元数据，默认不超限
    fi

    local traffic_limit=$(echo "$metadata" | jq -r '.traffic_limit_gb // "unlimited"')

    if [[ "$traffic_limit" == "unlimited" ]]; then
        return 1  # 无限流量
    fi

    local traffic_used=$(echo "$metadata" | jq -r '.traffic_used_gb // "0"')

    # 比较流量（使用bc进行浮点数比较）
    if command -v bc &> /dev/null; then
        local exceeded=$(echo "$traffic_used > $traffic_limit" | bc)
        if [[ "$exceeded" -eq 1 ]]; then
            return 0  # 已超限
        fi
    else
        # 如果没有bc，使用整数比较
        local used_int=${traffic_used%.*}
        local limit_int=${traffic_limit%.*}
        if [[ $used_int -gt $limit_int ]]; then
            return 0  # 已超限
        fi
    fi

    return 1  # 未超限
}

# 获取admin用户信息
# 返回格式: UUID|password|username
get_admin_user_info() {
    local admin_user=$(jq -r '.users[] | select(.username == "admin")' "$USERS_FILE" 2>/dev/null)

    if [[ -z "$admin_user" || "$admin_user" == "null" ]]; then
        print_error "admin用户不存在，请先初始化系统"
        return 1
    fi

    local admin_uuid=$(echo "$admin_user" | jq -r '.id')
    local admin_password=$(echo "$admin_user" | jq -r '.password // ""')
    local admin_username=$(echo "$admin_user" | jq -r '.username // "admin"')

    echo "$admin_uuid|$admin_password|$admin_username"
}

# 获取公网IP
get_public_ip() {
    local ip=""

    # 尝试多个IP获取服务
    ip=$(curl -s -4 --connect-timeout 3 https://api.ipify.org 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s -4 --connect-timeout 3 https://ifconfig.me 2>/dev/null)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -s -4 --connect-timeout 3 https://ip.sb 2>/dev/null)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    echo "$ip"
}

# 获取订阅服务配置中优先使用的域名
get_subscription_domain_hint() {
    for domain_file in "${DATA_DIR}/server_domain.txt" "${DATA_DIR}/host_domain.txt"; do
        if [[ -f "$domain_file" ]]; then
            local domain
            domain=$(tr -d ' \r\n' < "$domain_file")
            if [[ -n "$domain" && "$domain" != "未设置" ]]; then
                echo "$domain"
                return 0
            fi
        fi
    done
    echo ""
}

# 根据节点配置解析分享链接所需主机
resolve_subscription_host() {
    local node_json="$1"

    local protocol
    protocol=$(echo "$node_json" | jq -r '.protocol')
    local security
    security=$(echo "$node_json" | jq -r '.security // "none"')
    local extra
    extra=$(echo "$node_json" | jq -c '.extra // {}')

    local host=""

    # 优先1: 检查是否绑定了 Argo 隧道
    local tunnel_domain
    tunnel_domain=$(echo "$node_json" | jq -r '.tunnel_domain // ""')
    if [[ -n "$tunnel_domain" && "$tunnel_domain" != "null" ]]; then
        host="$tunnel_domain"
    fi

    # 优先2: 从 extra 中提取 tls_domain
    if [[ -z "$host" ]]; then
        case "$protocol" in
            vless|vmess|trojan)
                host=$(echo "$extra" | jq -r '.tls_domain // ""')
                [[ "$host" == "null" ]] && host=""
                ;;
        esac
    fi

    # 优先3: 使用配置的订阅域名
    if [[ -z "$host" ]]; then
        host=$(get_subscription_domain_hint)
    fi

    # 优先4: 使用公网 IP
    if [[ -z "$host" ]]; then
        host=$(get_public_ip)
    fi

    # 兜底: localhost
    if [[ -z "$host" ]]; then
        host="127.0.0.1"
    fi

    echo "$host"
}

# URL 编码
urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# YAML 字符串转义（处理反斜杠与双引号）
escape_yaml_string() {
    local input="$1"
    input="${input//\\/\\\\}"
    input="${input//\"/\\\"}"
    echo "$input"
}

# Base64 编码（无换行）
base64_encode() {
    # 支持从管道读取或从参数读取
    if [[ -p /dev/stdin ]]; then
        # 从管道读取
        base64 -w 0 2>/dev/null || base64 | tr -d '\n'
    else
        # 从参数读取
        local input="${1:-}"
        if [[ -z "$input" ]]; then
            return 1
        fi
        echo -n "$input" | base64 -w 0 2>/dev/null || echo -n "$input" | base64 | tr -d '\n'
    fi
}

#================================================================
# 分享链接生成函数（修复版）
#================================================================

# 从节点JSON生成VLESS Reality分享链接（新架构）
generate_vless_reality_link_from_config() {
    local uuid=$1
    local remark=$2
    local node_json=$3

    local port=$(echo "$node_json" | jq -r '.port')
    local extra=$(echo "$node_json" | jq -c '.extra // {}')

    # 从extra字段提取Reality参数
    local dest=$(echo "$extra" | jq -r '.dest // ""')
    local server_names=$(echo "$extra" | jq -r '.server_names[0] // ""')
    local public_key=$(echo "$extra" | jq -r '.public_key // ""')
    local short_id=$(echo "$extra" | jq -r '.short_ids[0] // ""')
    local flow=$(echo "$extra" | jq -r '.flow // "xtls-rprx-vision"')

    # 调试信息
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[调试 generate_vless_reality_link_from_config]" >&2
        echo "  uuid: $uuid" >&2
        echo "  remark: $remark" >&2
        echo "  port: $port" >&2
        echo "  dest: $dest" >&2
        echo "  server_names: $server_names" >&2
        echo "  public_key: ${public_key:0:20}..." >&2
        echo "  short_id: $short_id" >&2
        echo "  flow: $flow" >&2
    fi

    # 验证必需参数
    if [[ -z "$dest" || -z "$public_key" ]]; then
        if [[ "${DEBUG:-0}" == "1" ]]; then
            echo "  [错误] 缺少必需参数: dest=$dest, public_key=${public_key:0:10}" >&2
        fi
        echo ""
        return 1
    fi

    # SNI从server_names或dest提取
    local sni="$server_names"
    if [[ -z "$sni" && -n "$dest" ]]; then
        sni=$(echo "$dest" | cut -d':' -f1)
    fi

    local server_host
    server_host=$(resolve_subscription_host "$node_json")

    # 调试信息
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "  server_host: $server_host" >&2
        echo "  sni: $sni" >&2
    fi

    # 构建VLESS Reality链接
    local share_link="vless://${uuid}@${server_host}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#$(urlencode "$remark")"

    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "  生成的链接: $share_link" >&2
    fi

    echo "$share_link"
}

# 从节点JSON生成VLESS TLS分享链接（新架构）
generate_vless_tls_link_from_config() {
    local uuid=$1
    local remark=$2
    local node_json=$3

    local port=$(echo "$node_json" | jq -r '.port')
    local transport=$(echo "$node_json" | jq -r '.transport // "tcp"')
    local security=$(echo "$node_json" | jq -r '.security // "none"')
    local extra=$(echo "$node_json" | jq -c '.extra // {}')

    # 检查是否有TLS
    if [[ "$security" != "tls" ]]; then
        generate_vless_plain_link_from_config "$uuid" "$remark" "$node_json"
        return
    fi

    # 从extra提取参数
    local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')
    local ws_path=$(echo "$extra" | jq -r '.ws_path // ""')
    local grpc_service=$(echo "$extra" | jq -r '.grpc_service // ""')

    local server_host
    server_host=$(resolve_subscription_host "$node_json")

    # 构建链接
    local share_link="vless://${uuid}@${server_host}:${port}?encryption=none&security=tls&type=${transport}"

    if [[ -n "$tls_domain" ]]; then
        share_link+="&sni=${tls_domain}"
    fi

    if [[ "$transport" == "ws" && -n "$ws_path" ]]; then
        share_link+="&path=$(urlencode "$ws_path")"
    fi

    if [[ "$transport" == "grpc" && -n "$grpc_service" ]]; then
        share_link+="&serviceName=$(urlencode "$grpc_service")"
    fi

    share_link+="#$(urlencode "$remark")"

    echo "$share_link"
}

# 从节点JSON生成VLESS普通分享链接（新架构）
generate_vless_plain_link_from_config() {
    local uuid=$1
    local remark=$2
    local node_json=$3

    local port=$(echo "$node_json" | jq -r '.port')
    local transport=$(echo "$node_json" | jq -r '.transport // "tcp"')
    local extra=$(echo "$node_json" | jq -c '.extra // {}')

    # 从extra提取参数
    local ws_path=$(echo "$extra" | jq -r '.ws_path // ""')
    local grpc_service=$(echo "$extra" | jq -r '.grpc_service // ""')

    local server_host
    server_host=$(resolve_subscription_host "$node_json")

    local share_link="vless://${uuid}@${server_host}:${port}?encryption=none&type=${transport}"

    if [[ "$transport" == "ws" && -n "$ws_path" ]]; then
        share_link+="&path=$(urlencode "$ws_path")"
    fi

    if [[ "$transport" == "grpc" && -n "$grpc_service" ]]; then
        share_link+="&serviceName=$(urlencode "$grpc_service")"
    fi

    share_link+="#$(urlencode "$remark")"

    echo "$share_link"
}

# 从节点JSON生成VMess分享链接（新架构）
generate_vmess_link_from_config() {
    local uuid=$1
    local remark=$2
    local node_json=$3

    local port=$(echo "$node_json" | jq -r '.port')
    local transport=$(echo "$node_json" | jq -r '.transport // "tcp"')
    local extra=$(echo "$node_json" | jq -c '.extra // {}')

    # 从extra提取参数
    local alter_id=$(echo "$extra" | jq -r '.alter_id // 0')
    local cipher=$(echo "$extra" | jq -r '.cipher // "auto"')
    local ws_path=$(echo "$extra" | jq -r '.ws_path // ""')

    local server_host
    server_host=$(resolve_subscription_host "$node_json")

    # VMess JSON格式
    local vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "${remark}",
  "add": "${server_host}",
  "port": ${port},
  "id": "${uuid}",
  "aid": ${alter_id},
  "scy": "${cipher}",
  "net": "${transport}",
  "type": "none",
  "host": "",
  "path": "${ws_path}",
  "tls": "",
  "sni": "",
  "alpn": "",
  "fp": ""
}
EOF
)

    # Base64编码（去除换行）
    local vmess_link="vmess://$(echo -n "$vmess_json" | tr -d '\n' | base64_encode)"

    echo "$vmess_link"
}

# 从节点JSON生成Trojan分享链接（新架构）
generate_trojan_link_from_config() {
    local password=$1
    local remark=$2
    local node_json=$3

    local port=$(echo "$node_json" | jq -r '.port')
    local transport=$(echo "$node_json" | jq -r '.transport // "tcp"')
    local extra=$(echo "$node_json" | jq -c '.extra // {}')

    # 从extra提取参数
    local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')
    local server_host
    server_host=$(resolve_subscription_host "$node_json")

    local sni="${tls_domain}"
    if [[ -z "$sni" ]]; then
        sni=$server_host
    fi

    local share_link="trojan://${password}@${server_host}:${port}?security=tls&sni=${sni}&type=${transport}#$(urlencode "$remark")"

    echo "$share_link"
}

# 从节点JSON生成Shadowsocks分享链接（新架构）
generate_ss_link_from_config() {
    local password=$1
    local remark=$2
    local node_json=$3

    local port=$(echo "$node_json" | jq -r '.port')
    local extra=$(echo "$node_json" | jq -c '.extra // {}')

    # 从extra提取cipher
    local cipher=$(echo "$extra" | jq -r '.cipher // "aes-256-gcm"')
    local server_host
    server_host=$(resolve_subscription_host "$node_json")

    # SIP002格式
    local userinfo="${cipher}:${password}"
    local encoded=$(base64_encode "$userinfo")

    local share_link="ss://${encoded}@${server_host}:${port}#$(urlencode "$remark")"

    echo "$share_link"
}

# 从节点JSON生成Hysteria2分享链接（新架构）
generate_hysteria2_link_from_config() {
    local password=$1
    local remark=$2
    local node_json=$3

    local port=$(echo "$node_json" | jq -r '.port')
    local extra=$(echo "$node_json" | jq -c '.extra // {}')

    # 从extra提取参数
    local obfs_password=$(echo "$extra" | jq -r '.obfs_password // ""')
    local port_hopping=$(echo "$extra" | jq -r '.port_hopping // ""')
    local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')
    local tls_cert=$(echo "$extra" | jq -r '.tls_cert // ""')

    # 提取域名作为SNI（优先使用 tls_domain）
    local sni="$tls_domain"
    if [[ -z "$sni" && -n "$tls_cert" ]]; then
        # 从证书路径提取域名（支持多种格式）
        sni=$(basename "$(dirname "$tls_cert")")
        # 如果证书路径是旧格式 /path/domain.crt，则提取文件名
        if [[ "$sni" == "certs" || -z "$sni" ]]; then
            sni=$(basename "$tls_cert" | sed -e 's/.crt$//' -e 's/.cer$//' -e 's/fullchain.//')
        fi
    fi

    local server_host
    server_host=$(resolve_subscription_host "$node_json")

    # 构建Hysteria2链接
    # 格式: hysteria2://password@host:port?obfs=salamander&obfs-password=xxx&sni=xxx&mport=start-end#remark
    local share_link="hysteria2://${password}@${server_host}:${port}?"

    local params=""

    # 添加混淆参数
    if [[ -n "$obfs_password" ]]; then
        params+="obfs=salamander&obfs-password=${obfs_password}&"
    fi

    # 添加SNI
    if [[ -n "$sni" ]]; then
        params+="sni=${sni}&"
    fi

    # 添加端口跳跃
    if [[ -n "$port_hopping" ]]; then
        params+="mport=${port_hopping}&"
    fi

    # 添加insecure参数（自签名证书）
    params+="insecure=1"

    share_link+="${params}#$(urlencode "$remark")"

    echo "$share_link"
}

# 智能生成分享链接（根据节点类型）- 新架构
generate_share_link_smart() {
    local user_id=$1
    local user_email=$2
    local node_json=$3

    local protocol=$(echo "$node_json" | jq -r '.protocol')
    local security=$(echo "$node_json" | jq -r '.security // "none"')

    # 调试信息（可通过环境变量DEBUG=1启用）
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[调试 generate_share_link_smart]" >&2
        echo "  user_id: $user_id" >&2
        echo "  user_email: $user_email" >&2
        echo "  protocol: $protocol" >&2
        echo "  security: $security" >&2
        echo "  node_json: $(echo "$node_json" | jq -c '.')" >&2
    fi

    # 获取节点名称和用户信息
    local node_name=$(echo "$node_json" | jq -r '.name // "未命名"')
    local user=$(jq -r ".users[] | select(.id == \"$user_id\")" "$USERS_FILE" 2>/dev/null)
    local username=$(echo "$user" | jq -r '.username // ""')

    # 组合remark: 节点名-用户名（流量和期限信息将显示在订阅响应头中）
    local remark="${node_name}-${username}"

    # 获取用户密码（Trojan、SS和Hysteria2需要）
    local user_password=""
    if [[ "$protocol" == "trojan" || "$protocol" == "shadowsocks" || "$protocol" == "hysteria2" ]]; then
        user_password=$(jq -r ".users[] | select(.id == \"$user_id\") | .password // \"\"" "$USERS_FILE" 2>/dev/null)
    fi

    case $protocol in
        vless)
            # 根据security字段判断类型
            if [[ "$security" == "reality" ]]; then
                generate_vless_reality_link_from_config "$user_id" "$remark" "$node_json"
            elif [[ "$security" == "tls" ]]; then
                generate_vless_tls_link_from_config "$user_id" "$remark" "$node_json"
            else
                generate_vless_plain_link_from_config "$user_id" "$remark" "$node_json"
            fi
            ;;
        vmess)
            generate_vmess_link_from_config "$user_id" "$remark" "$node_json"
            ;;
        trojan)
            generate_trojan_link_from_config "$user_password" "$remark" "$node_json"
            ;;
        shadowsocks)
            generate_ss_link_from_config "$user_password" "$remark" "$node_json"
            ;;
        hysteria2)
            generate_hysteria2_link_from_config "$user_password" "$remark" "$node_json"
            ;;
        *)
            echo ""
            ;;
    esac
}

#================================================================
# Clash配置生成函数
#================================================================

# 生成Clash YAML完整配置
generate_clash_config() {
    local nodes_array="$1"  # JSON数组格式的节点列表
    local user_id="$2"
    local user_password="$3"

    # 验证必需参数
    if [[ -z "$user_id" ]]; then
        echo "# ERROR: user_id is required" >&2
        return 1
    fi

    # 对于需要password的协议，如果为空则尝试获取
    if [[ -z "$user_password" ]]; then
        user_password=$(jq -r ".users[] | select(.id == \"$user_id\") | .password // \"\"" "$USERS_FILE" 2>/dev/null)
    fi

    # Clash YAML头部
    cat <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: Rule
log-level: info
external-controller: 127.0.0.1:9090

proxies:
EOF

    # 获取用户信息用于节点名称（流量和期限信息将显示在订阅响应头中）
    local user=$(jq -r ".users[] | select(.id == \"$user_id\")" "$USERS_FILE" 2>/dev/null)
    local username=$(echo "$user" | jq -r '.username // ""')

    # 关键修复：使用数组收集节点配置，避免subshell问题
    local proxy_configs=()
    local proxy_list=()
    local skipped_count=0
    local processed_count=0

    while IFS= read -r node; do
        [[ -z "$node" || "$node" == "null" ]] && continue

        ((processed_count++))

        local protocol=$(echo "$node" | jq -r '.protocol')
        local port=$(echo "$node" | jq -r '.port')
        local security=$(echo "$node" | jq -r '.security // "none"')
        local transport=$(echo "$node" | jq -r '.transport // "tcp"')
        local extra=$(echo "$node" | jq -r '.extra')
        local node_name_raw=$(echo "$node" | jq -r '.name // "未命名"')
        local node_host=$(resolve_subscription_host "$node")
        local warp_outbound=$(echo "$node" | jq -r '.warp_outbound // false')
        local node_name="${node_name_raw}-${username}"
        local safe_node_name=$(escape_yaml_string "$node_name")

        # 调试信息 (只在需要时输出)
        [[ "${DEBUG_MODE:-0}" == "1" ]] && echo "# DEBUG: Processing node $processed_count: protocol=$protocol, port=$port, security=$security" >&2

        local node_config=""

        case $protocol in
            vless)
                # VLESS Reality 支持（Clash Meta）
                if [[ "$security" == "reality" ]]; then
                    local dest=$(echo "$extra" | jq -r '.dest // ""')
                    local server_names=$(echo "$extra" | jq -r '.server_names[0] // ""')
                    local public_key=$(echo "$extra" | jq -r '.public_key // ""')
                    local short_id=$(echo "$extra" | jq -r '.short_ids[0] // ""')
                    local flow=$(echo "$extra" | jq -r '.flow // "xtls-rprx-vision"')

                    # 验证必需参数
                    if [[ -z "$public_key" ]]; then
                        echo "# WARNING: Skipping Reality node on port $port - missing public_key" >&2
                        ((skipped_count++))
                        continue
                    fi

                    # SNI从server_names或dest提取
                    local sni="$server_names"
                    if [[ -z "$sni" && -n "$dest" ]]; then
                        sni=$(echo "$dest" | cut -d':' -f1)
                    fi

                    # 确保必需字段不为空
                    if [[ -z "$sni" ]]; then
                        echo "# WARNING: Skipping Reality node on port $port - missing SNI" >&2
                        ((skipped_count++))
                        continue
                    fi

                    node_config="  - name: \"${safe_node_name}\"
    type: vless
    server: ${node_host}
    port: ${port}
    uuid: ${user_id}
    network: tcp
    udp: true
    tls: true
    flow: ${flow}
    servername: ${sni}
    reality-opts:
      public-key: ${public_key}
      short-id: ${short_id}
    client-fingerprint: chrome"
                elif [[ "$security" == "tls" ]]; then
                    # VLESS TLS
                    local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')
                    local ws_path=$(echo "$extra" | jq -r '.ws_path // ""')

                    node_config="  - name: \"${safe_node_name}\"
    type: vless
    server: ${node_host}
    port: ${port}
    uuid: ${user_id}
    udp: true
    tls: true
    skip-cert-verify: true"
                    [[ -n "$tls_domain" ]] && node_config="${node_config}
    servername: ${tls_domain}"
                    if [[ "$transport" == "ws" && -n "$ws_path" ]]; then
                        node_config="${node_config}
    network: ws
    ws-opts:
      path: ${ws_path}"
                    fi
                else
                    # Plain VLESS (no TLS)
                    local ws_path=$(echo "$extra" | jq -r '.ws_path // ""')

                    node_config="  - name: \"${safe_node_name}\"
    type: vless
    server: ${node_host}
    port: ${port}
    uuid: ${user_id}
    udp: true"
                    if [[ "$transport" == "ws" && -n "$ws_path" ]]; then
                        node_config="${node_config}
    network: ws
    ws-opts:
      path: ${ws_path}"
                    fi
                fi
                ;;
            vmess)
                local alter_id=$(echo "$extra" | jq -r '.alter_id // 0')
                local cipher=$(echo "$extra" | jq -r '.cipher // "auto"')
                local ws_path=$(echo "$extra" | jq -r '.ws_path // ""')

                # 验证 VMess cipher 是否被 Clash 支持
                case "$cipher" in
                    auto|aes-128-gcm|chacha20-poly1305|none)
                        # 支持的加密方式
                        ;;
                    *)
                        # 不支持的加密方式，使用 auto
                        cipher="auto"
                        echo "# WARNING: VMess-${port} cipher not supported, using auto" >&2
                        ;;
                esac

                node_config="  - name: \"${safe_node_name}\"
    type: vmess
    server: ${node_host}
    port: ${port}
    uuid: ${user_id}
    alterId: ${alter_id}
    cipher: ${cipher}
    udp: true"
                if [[ "$transport" == "ws" && -n "$ws_path" ]]; then
                    node_config="${node_config}
    network: ws
    ws-opts:
      path: ${ws_path}"
                fi
                ;;
            trojan)
                # Trojan 必需 password，如果为空则跳过
                if [[ -z "$user_password" ]]; then
                    echo "# WARNING: Skipping Trojan-${port} - password required but not provided" >&2
                    ((skipped_count++))
                    continue
                fi

                local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')

                node_config="  - name: \"${safe_node_name}\"
    type: trojan
    server: ${node_host}
    port: ${port}
    password: ${user_password}
    udp: true
    skip-cert-verify: true"
                [[ -n "$tls_domain" ]] && node_config="${node_config}
    sni: ${tls_domain}"
                ;;
            shadowsocks)
                # Shadowsocks 必需 password，如果为空则跳过
                if [[ -z "$user_password" ]]; then
                    echo "# WARNING: Skipping SS-${port} - password required but not provided" >&2
                    ((skipped_count++))
                    continue
                fi

                local cipher=$(echo "$extra" | jq -r '.cipher // "aes-256-gcm"')
                # 验证 cipher 是否被 Clash 支持
                case "$cipher" in
                    aes-128-gcm|aes-192-gcm|aes-256-gcm|aes-128-cfb|aes-192-cfb|aes-256-cfb|aes-128-ctr|aes-192-ctr|aes-256-ctr|rc4-md5|chacha20-ietf|xchacha20|chacha20-ietf-poly1305|xchacha20-ietf-poly1305)
                        # 支持的加密方式
                        ;;
                    *)
                        # 不支持的加密方式，使用默认值
                        cipher="aes-256-gcm"
                        echo "# WARNING: SS-${port} cipher not supported, using aes-256-gcm" >&2
                        ;;
                esac

                node_config="  - name: \"${safe_node_name}\"
    type: ss
    server: ${node_host}
    port: ${port}
    cipher: ${cipher}
    password: ${user_password}
    udp: true"
                ;;
            hysteria2)
                # Hysteria2 必需 password，如果为空则跳过
                if [[ -z "$user_password" ]]; then
                    echo "# WARNING: Skipping Hysteria2-${port} - password required" >&2
                    ((skipped_count++))
                    continue
                fi

                local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')
                local obfs_password=$(echo "$extra" | jq -r '.obfs_password // ""')
                local port_hopping=$(echo "$extra" | jq -r '.port_hopping // ""')
                local up_mbps=$(echo "$extra" | jq -r '.up_mbps // 0')
                local down_mbps=$(echo "$extra" | jq -r '.down_mbps // 0')

                # 基本配置
                node_config="  - name: \"${safe_node_name}\"
    type: hysteria2
    server: ${node_host}
    port: ${port}
    password: ${user_password}
    skip-cert-verify: true
    udp: true"

                # 添加SNI
                [[ -n "$tls_domain" ]] && node_config="${node_config}
    sni: ${tls_domain}"

                # 添加混淆
                if [[ -n "$obfs_password" ]]; then
                    node_config="${node_config}
    obfs: salamander
    obfs-password: ${obfs_password}"
                fi

                # 添加端口跳跃
                if [[ -n "$port_hopping" ]]; then
                    node_config="${node_config}
    ports: ${port_hopping}"
                fi

                # 添加速率限制（如果配置了）
                if [[ "$up_mbps" -gt 0 ]] || [[ "$down_mbps" -gt 0 ]]; then
                    [[ "$up_mbps" -gt 0 ]] && node_config="${node_config}
    up: \"${up_mbps} Mbps\""
                    [[ "$down_mbps" -gt 0 ]] && node_config="${node_config}
    down: \"${down_mbps} Mbps\""
                fi
                ;;
        esac

        if [[ -n "$node_config" ]]; then
            proxy_configs+=("$node_config")
            proxy_list+=("$safe_node_name")
        fi
    done < <(echo "$nodes_array" | jq -c '.[]')

    # 调试统计信息 (只在需要时输出)
    [[ "${DEBUG_MODE:-0}" == "1" ]] && echo "# DEBUG: Total processed: $processed_count, Skipped: $skipped_count, Generated: ${#proxy_configs[@]}" >&2

    # 验证是否有有效节点
    if [[ ${#proxy_configs[@]} -eq 0 ]]; then
        echo "# ERROR: No valid nodes generated for Clash configuration" >&2
        echo "# Processed $processed_count nodes, skipped $skipped_count" >&2
        echo "# Possible reasons:" >&2
        echo "#   1. Reality nodes missing public_key field" >&2
        echo "#   2. Trojan/SS nodes missing password field" >&2
        echo "#   3. Node data structure mismatch" >&2
        echo "# Please check: /usr/local/sing-box/data/nodes.json" >&2
        return 1
    fi

    # 输出所有节点配置
    for config in "${proxy_configs[@]}"; do
        echo "$config"
        echo ""
    done

    # Clash代理组和规则（参考s-hy2项目格式）
    cat <<'EOF'
proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "🔄 自动选择"
EOF

    # 输出节点列表到选择组
    for proxy in "${proxy_list[@]}"; do
        echo "      - \"$proxy\""
    done

    cat <<'EOF'
      - "🎯 全球直连"

  - name: "🔄 自动选择"
    type: url-test
    proxies:
EOF

    # 再次输出节点列表到自动选择组
    for proxy in "${proxy_list[@]}"; do
        echo "      - \"$proxy\""
    done

    cat <<'EOF'
    url: 'http://www.gstatic.com/generate_204'
    interval: 300
    tolerance: 50

  - name: "🌍 国外媒体"
    type: select
    proxies:
      - "🚀 节点选择"
      - "🔄 自动选择"
      - "🎯 全球直连"

  - name: "🎯 全球直连"
    type: select
    proxies:
      - "DIRECT"

  - name: "🛑 全球拦截"
    type: select
    proxies:
      - "REJECT"
      - "🎯 全球直连"

rules:
  # 局域网直连
  - DOMAIN-SUFFIX,local,🎯 全球直连
  - IP-CIDR,192.168.0.0/16,🎯 全球直连,no-resolve
  - IP-CIDR,10.0.0.0/8,🎯 全球直连,no-resolve
  - IP-CIDR,172.16.0.0/12,🎯 全球直连,no-resolve
  - IP-CIDR,127.0.0.0/8,🎯 全球直连,no-resolve
  - IP-CIDR,100.64.0.0/10,🎯 全球直连,no-resolve
  - IP-CIDR6,::1/128,🎯 全球直连,no-resolve
  - IP-CIDR6,fc00::/7,🎯 全球直连,no-resolve
  - IP-CIDR6,fe80::/10,🎯 全球直连,no-resolve

  # 常用国外媒体服务
  - DOMAIN-KEYWORD,youtube,🌍 国外媒体
  - DOMAIN-KEYWORD,google,🌍 国外媒体
  - DOMAIN-KEYWORD,twitter,🌍 国外媒体
  - DOMAIN-KEYWORD,facebook,🌍 国外媒体
  - DOMAIN-KEYWORD,instagram,🌍 国外媒体
  - DOMAIN-KEYWORD,telegram,🌍 国外媒体
  - DOMAIN-KEYWORD,netflix,🌍 国外媒体
  - DOMAIN-KEYWORD,github,🌍 国外媒体
  - DOMAIN-SUFFIX,openai.com,🌍 国外媒体
  - DOMAIN-SUFFIX,chatgpt.com,🌍 国外媒体

  # 广告拦截
  - DOMAIN-KEYWORD,ad,🛑 全球拦截
  - DOMAIN-KEYWORD,ads,🛑 全球拦截
  - DOMAIN-KEYWORD,analytics,🛑 全球拦截
  - DOMAIN-KEYWORD,track,🛑 全球拦截

  # 国内域名和IP直连
  - GEOIP,CN,🎯 全球直连

  # 其他流量走代理
  - MATCH,🚀 节点选择
EOF
}

#================================================================
# 订阅管理功能
#================================================================

# 查看单个节点的分享链接
show_node_share_link() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      查看单个节点分享链接            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 显示节点列表
    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "暂无节点"
        return 1
    fi

    local node_count=$(jq -r '.nodes | length' "$NODES_FILE")
    if [[ "$node_count" -eq 0 ]]; then
        print_error "暂无节点"
        return 1
    fi

    echo -e "${YELLOW}节点列表：${NC}"
    echo ""

    local index=1
    while IFS= read -r node; do
        if [[ -z "$node" || "$node" == "null" ]]; then
            continue
        fi

        local name=$(echo "$node" | jq -r '.name // "未命名"')
        local protocol=$(echo "$node" | jq -r '.protocol')
        local port=$(echo "$node" | jq -r '.port')
        local transport=$(echo "$node" | jq -r '.transport // "N/A"')
        local security=$(echo "$node" | jq -r '.security // "N/A"')

        printf "${CYAN}[%d]${NC} ${YELLOW}%-20s${NC} (%s/%s/%s - 端口:%s)\n" "$index" "$name" "$protocol" "$transport" "$security" "$port"
        ((index++))
    done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)

    echo ""
    read -p "请输入节点序号: " node_index

    # 验证输入
    if [[ ! "$node_index" =~ ^[0-9]+$ ]] || [[ "$node_index" -lt 1 ]] || [[ "$node_index" -gt "$((index-1))" ]]; then
        print_error "无效的序号"
        return 1
    fi

    # 获取节点
    local node=$(jq -c ".nodes[$((node_index-1))]" "$NODES_FILE" 2>/dev/null)
    if [[ -z "$node" || "$node" == "null" ]]; then
        print_error "节点不存在"
        return 1
    fi

    local name=$(echo "$node" | jq -r '.name // "未命名"')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local port=$(echo "$node" | jq -r '.port')

    echo ""
    echo -e "${CYAN}节点信息：${NC}"
    echo -e "  节点名称: ${YELLOW}$name${NC}"
    echo -e "  协议: ${YELLOW}$protocol${NC}"
    echo -e "  端口: ${YELLOW}$port${NC}"
    echo ""

    # 查找该节点绑定的所有用户
    local binding=$(jq -c ".bindings[] | select(.port == \"$port\")" "$NODE_USERS_FILE" 2>/dev/null)
    if [[ -z "$binding" || "$binding" == "null" ]]; then
        print_warning "该节点未绑定任何用户"
        return 0
    fi

    local user_uuids=$(echo "$binding" | jq -r '.users[]')
    if [[ -z "$user_uuids" ]]; then
        print_warning "该节点未绑定任何用户"
        return 0
    fi

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}该节点的用户链接：${NC}"
    echo ""

    local link_count=0
    while IFS= read -r uuid; do
        if [[ -z "$uuid" ]]; then
            continue
        fi

        # 获取用户信息
        local user=$(jq -r ".users[] | select(.id == \"$uuid\")" "$USERS_FILE" 2>/dev/null)
        if [[ -z "$user" || "$user" == "null" ]]; then
            print_warning "用户UUID $uuid 不存在，跳过"
            continue
        fi

        local username=$(echo "$user" | jq -r '.username')
        local email=$(echo "$user" | jq -r '.email // .username')

        # 生成该用户的分享链接
        local share_link=$(generate_share_link_smart "$uuid" "$username" "$node")

        if [[ -n "$share_link" ]]; then
            ((link_count++))
            echo -e "${YELLOW}[$link_count] 用户:${NC} ${CYAN}$username${NC} (${email})"
            echo -e "    ${GREEN}$share_link${NC}"
            echo ""
        fi
    done <<< "$user_uuids"

    if [[ $link_count -eq 0 ]]; then
        print_warning "未能生成任何链接"
    else
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        print_success "共生成 $link_count 个用户链接"
    fi
}

# 生成 sing-box JSON 配置
generate_singbox_subscription_config() {
    local nodes_array="$1"  # JSON数组格式的节点列表
    local user_id="$2"
    local user_password="$3"

    # 验证必需参数
    if [[ -z "$user_id" ]]; then
        echo "# ERROR: user_id is required" >&2
        return 1
    fi

    # 对于需要password的协议，如果为空则尝试获取
    if [[ -z "$user_password" ]]; then
        user_password=$(jq -r ".users[] | select(.id == \"$user_id\") | .password // \"\"" "$USERS_FILE" 2>/dev/null)
    fi

    # sing-box JSON 配置框架
    local outbounds='[]'
    local proxy_tags='[]'
    local skipped_count=0
    local processed_count=0

    # 遍历节点生成 outbound 配置
    while IFS= read -r node; do
        [[ -z "$node" || "$node" == "null" ]] && continue

        ((processed_count++))

        local protocol=$(echo "$node" | jq -r '.protocol')
        local port=$(echo "$node" | jq -r '.port')
        local security=$(echo "$node" | jq -r '.security // "none"')
        local transport=$(echo "$node" | jq -r '.transport // "tcp"')
        local extra=$(echo "$node" | jq -r '.extra')
        local node_name_raw=$(echo "$node" | jq -r '.name // "未命名"')
        local node_host=$(resolve_subscription_host "$node")
        local warp_outbound=$(echo "$node" | jq -r '.warp_outbound // false')

        # 获取用户信息用于节点名称
        local user=$(jq -r ".users[] | select(.id == \"$user_id\")" "$USERS_FILE" 2>/dev/null)
        local username=$(echo "$user" | jq -r '.username // ""')
        local node_tag="${node_name_raw}-${username}-${port}"

        [[ "${DEBUG_MODE:-0}" == "1" ]] && echo "# DEBUG: Processing singbox node: protocol=$protocol, port=$port" >&2

        local outbound_config=""

        case $protocol in
            vless)
                if [[ "$security" == "reality" ]]; then
                    # VLESS Reality
                    local dest=$(echo "$extra" | jq -r '.dest // ""')
                    local server_names=$(echo "$extra" | jq -r '.server_names[0] // ""')
                    local public_key=$(echo "$extra" | jq -r '.public_key // ""')
                    local short_id=$(echo "$extra" | jq -r '.short_ids[0] // ""')
                    local flow=$(echo "$extra" | jq -r '.flow // "xtls-rprx-vision"')

                    if [[ -z "$public_key" ]]; then
                        echo "# WARNING: Skipping Reality node on port $port - missing public_key" >&2
                        ((skipped_count++))
                        continue
                    fi

                    local sni="$server_names"
                    if [[ -z "$sni" && -n "$dest" ]]; then
                        sni=$(echo "$dest" | cut -d':' -f1)
                    fi

                    if [[ -z "$sni" ]]; then
                        echo "# WARNING: Skipping Reality node on port $port - missing SNI" >&2
                        ((skipped_count++))
                        continue
                    fi

                    outbound_config=$(jq -n \
                        --arg tag "$node_tag" \
                        --arg server "$node_host" \
                        --argjson port "$port" \
                        --arg uuid "$user_id" \
                        --arg flow "$flow" \
                        --arg sni "$sni" \
                        --arg public_key "$public_key" \
                        --arg short_id "$short_id" \
                        '{
                            type: "vless",
                            tag: $tag,
                            server: $server,
                            server_port: $port,
                            uuid: $uuid,
                            flow: $flow,
                            tls: {
                                enabled: true,
                                server_name: $sni,
                                utls: {
                                    enabled: true,
                                    fingerprint: "chrome"
                                },
                                reality: {
                                    enabled: true,
                                    public_key: $public_key,
                                    short_id: $short_id
                                }
                            }
                        }')
                elif [[ "$security" == "tls" ]]; then
                    # VLESS TLS
                    local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')
                    local ws_path=$(echo "$extra" | jq -r '.ws_path // ""')

                    if [[ "$transport" == "ws" && -n "$ws_path" ]]; then
                        outbound_config=$(jq -n \
                            --arg tag "$node_tag" \
                            --arg server "$node_host" \
                            --argjson port "$port" \
                            --arg uuid "$user_id" \
                            --arg sni "$tls_domain" \
                            --arg path "$ws_path" \
                            '{
                                type: "vless",
                                tag: $tag,
                                server: $server,
                                server_port: $port,
                                uuid: $uuid,
                                tls: {
                                    enabled: true,
                                    server_name: $sni,
                                    insecure: true
                                },
                                transport: {
                                    type: "ws",
                                    path: $path
                                }
                            }')
                    else
                        outbound_config=$(jq -n \
                            --arg tag "$node_tag" \
                            --arg server "$node_host" \
                            --argjson port "$port" \
                            --arg uuid "$user_id" \
                            --arg sni "$tls_domain" \
                            '{
                                type: "vless",
                                tag: $tag,
                                server: $server,
                                server_port: $port,
                                uuid: $uuid,
                                tls: {
                                    enabled: true,
                                    server_name: $sni,
                                    insecure: true
                                }
                            }')
                    fi
                else
                    # Plain VLESS
                    outbound_config=$(jq -n \
                        --arg tag "$node_tag" \
                        --arg server "$node_host" \
                        --argjson port "$port" \
                        --arg uuid "$user_id" \
                        '{
                            type: "vless",
                            tag: $tag,
                            server: $server,
                            server_port: $port,
                            uuid: $uuid
                        }')
                fi
                ;;
            vmess)
                local alter_id=$(echo "$extra" | jq -r '.alter_id // 0')
                local cipher=$(echo "$extra" | jq -r '.cipher // "auto"')
                local ws_path=$(echo "$extra" | jq -r '.ws_path // ""')

                if [[ "$transport" == "ws" && -n "$ws_path" ]]; then
                    outbound_config=$(jq -n \
                        --arg tag "$node_tag" \
                        --arg server "$node_host" \
                        --argjson port "$port" \
                        --arg uuid "$user_id" \
                        --argjson alter_id "$alter_id" \
                        --arg cipher "$cipher" \
                        --arg path "$ws_path" \
                        '{
                            type: "vmess",
                            tag: $tag,
                            server: $server,
                            server_port: $port,
                            uuid: $uuid,
                            alter_id: $alter_id,
                            security: $cipher,
                            transport: {
                                type: "ws",
                                path: $path
                            }
                        }')
                else
                    outbound_config=$(jq -n \
                        --arg tag "$node_tag" \
                        --arg server "$node_host" \
                        --argjson port "$port" \
                        --arg uuid "$user_id" \
                        --argjson alter_id "$alter_id" \
                        --arg cipher "$cipher" \
                        '{
                            type: "vmess",
                            tag: $tag,
                            server: $server,
                            server_port: $port,
                            uuid: $uuid,
                            alter_id: $alter_id,
                            security: $cipher
                        }')
                fi
                ;;
            trojan)
                if [[ -z "$user_password" ]]; then
                    echo "# WARNING: Skipping Trojan-${port} - password required" >&2
                    ((skipped_count++))
                    continue
                fi

                local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')

                outbound_config=$(jq -n \
                    --arg tag "$node_tag" \
                    --arg server "$node_host" \
                    --argjson port "$port" \
                    --arg password "$user_password" \
                    --arg sni "$tls_domain" \
                    '{
                        type: "trojan",
                        tag: $tag,
                        server: $server,
                        server_port: $port,
                        password: $password,
                        tls: {
                            enabled: true,
                            server_name: $sni,
                            insecure: true,
                            utls: {
                                enabled: true,
                                fingerprint: "chrome"
                            }
                        },
                        multiplex: {
                            enabled: true,
                            protocol: "smux",
                            max_streams: 32
                        }
                    }')
                ;;
            shadowsocks)
                if [[ -z "$user_password" ]]; then
                    echo "# WARNING: Skipping SS-${port} - password required" >&2
                    ((skipped_count++))
                    continue
                fi

                local cipher=$(echo "$extra" | jq -r '.cipher // "aes-256-gcm"')

                outbound_config=$(jq -n \
                    --arg tag "$node_tag" \
                    --arg server "$node_host" \
                    --argjson port "$port" \
                    --arg method "$cipher" \
                    --arg password "$user_password" \
                    '{
                        type: "shadowsocks",
                        tag: $tag,
                        server: $server,
                        server_port: $port,
                        method: $method,
                        password: $password,
                        multiplex: {
                            enabled: true,
                            protocol: "smux",
                            max_streams: 32
                        }
                    }')
                ;;
            hysteria2)
                if [[ -z "$user_password" ]]; then
                    echo "# WARNING: Skipping Hysteria2-${port} - password required" >&2
                    ((skipped_count++))
                    continue
                fi

                local tls_domain=$(echo "$extra" | jq -r '.tls_domain // ""')
                local obfs_password=$(echo "$extra" | jq -r '.obfs_password // ""')
                local port_hopping=$(echo "$extra" | jq -r '.port_hopping // ""')
                local up_mbps=$(echo "$extra" | jq -r '.up_mbps // 0')
                local down_mbps=$(echo "$extra" | jq -r '.down_mbps // 0')

                # 构建基础配置
                outbound_config=$(jq -n \
                    --arg tag "$node_tag" \
                    --arg server "$node_host" \
                    --argjson port "$port" \
                    --arg password "$user_password" \
                    --arg sni "$tls_domain" \
                    --arg obfs_pwd "$obfs_password" \
                    --arg port_hop "$port_hopping" \
                    --argjson up "$up_mbps" \
                    --argjson down "$down_mbps" \
                    '{
                        type: "hysteria2",
                        tag: $tag,
                        server: $server,
                        server_port: $port,
                        password: $password,
                        tls: {
                            enabled: true,
                            server_name: $sni,
                            insecure: true
                        }
                    } + (if $obfs_pwd != "" then {
                        obfs: {
                            type: "salamander",
                            password: $obfs_pwd
                        }
                    } else {} end) + (if $port_hop != "" then {
                        server_ports: [$port_hop],
                        hop_interval: "30s"
                    } else {} end) + (if $up > 0 and $down > 0 then {
                        up_mbps: $up,
                        down_mbps: $down
                    } else {} end)')
                ;;
        esac

        # 如果节点绑定了 WARP，添加 bind_interface
        if [[ -n "$outbound_config" && "$warp_outbound" == "true" ]]; then
            outbound_config=$(echo "$outbound_config" | jq '. + {bind_interface: "wgcf"}')
        fi

        if [[ -n "$outbound_config" ]]; then
            outbounds=$(echo "$outbounds" | jq --argjson ob "$outbound_config" '. += [$ob]')
            proxy_tags=$(echo "$proxy_tags" | jq --arg tag "$node_tag" '. += [$tag]')
        fi
    done < <(echo "$nodes_array" | jq -c '.[]')

    [[ "${DEBUG_MODE:-0}" == "1" ]] && echo "# DEBUG: Total processed: $processed_count, Skipped: $skipped_count, Generated: $(echo "$outbounds" | jq 'length')" >&2

    # 验证是否有有效节点
    local outbound_count=$(echo "$outbounds" | jq 'length')
    if [[ "$outbound_count" -eq 0 ]]; then
        echo "# ERROR: No valid nodes generated for sing-box configuration" >&2
        echo "# Processed $processed_count nodes, skipped $skipped_count" >&2
        return 1
    fi

    # 创建 selector 代理组
    local selector_outbound=$(jq -n \
        --argjson proxy_tags "$proxy_tags" \
        '{
            type: "selector",
            tag: "🌏️主代理",
            outbounds: ($proxy_tags + ["Direct"]),
            default: $proxy_tags[0]
        }')

    # 创建 urltest 自动选择组
    local urltest_outbound=$(jq -n \
        --argjson proxy_tags "$proxy_tags" \
        '{
            type: "urltest",
            tag: "♾️自动选择",
            outbounds: $proxy_tags,
            url: "http://www.gstatic.com/generate_204",
            interval: "5m",
            tolerance: 50
        }')

    # 添加 Direct outbound
    local direct_outbound='{"type": "direct", "tag": "Direct"}'

    # 组装最终 outbounds: [selector, urltest, 节点列表, Direct]
    outbounds=$(echo "$outbounds" | jq --argjson selector "$selector_outbound" --argjson urltest "$urltest_outbound" --argjson direct "$direct_outbound" \
        '. = [$selector, $urltest] + . + [$direct]')

    # 生成完整的 sing-box 配置
    jq -n \
        --argjson outbounds "$outbounds" \
        '{
            log: {
                disabled: false,
                level: "error",
                timestamp: true
            },
            dns: {
                servers: [
                    {
                        tag: "dns-remote",
                        address: "https://223.5.5.5/dns-query",
                        strategy: "ipv4_only",
                        detour: "Direct"
                    },
                    {
                        tag: "dns-local",
                        address: "223.5.5.5",
                        strategy: "ipv4_only",
                        detour: "Direct"
                    }
                ],
                rules: [
                    {
                        outbound: ["🌏️主代理", "♾️自动选择", "Direct"],
                        action: "route",
                        server: "dns-local"
                    }
                ],
                final: "dns-remote",
                strategy: "ipv4_only"
            },
            inbounds: [
                {
                    type: "mixed",
                    tag: "mixed-in",
                    listen: "127.0.0.1",
                    listen_port: 2080,
                    sniff: true
                },
                {
                    type: "tun",
                    tag: "tun-in",
                    interface_name: "singtun0",
                    address: ["172.19.0.1/30"],
                    auto_route: true,
                    strict_route: true,
                    stack: "system",
                    mtu: 9000,
                    sniff: true
                }
            ],
            outbounds: $outbounds,
            route: {
                rules: [
                    {
                        ip_is_private: true,
                        action: "route",
                        outbound: "Direct"
                    },
                    {
                        domain_suffix: [".cn"],
                        action: "route",
                        outbound: "Direct"
                    }
                ],
                final: "🌏️主代理",
                auto_detect_interface: true
            }
        }'
}

# 生成订阅（绑定用户版）
generate_subscription_with_user() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          生成订阅链接                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -f "$NODES_FILE" ]]; then
        print_error "暂无节点，请先添加节点"
        return 1
    fi

    local node_count=$(jq -r '.nodes | length' "$NODES_FILE")
    if [[ "$node_count" -eq 0 ]]; then
        print_error "暂无节点，请先添加节点"
        return 1
    fi

    echo -e "${YELLOW}当前节点数量:${NC} $node_count"
    echo ""

    # 选择用户
    echo -e "${CYAN}选择订阅用户：${NC}"
    echo -e "  ${GREEN}1.${NC} admin（默认管理员）"
    echo -e "  ${GREEN}2.${NC} 选择其他用户"
    echo ""
    read -p "请选择 [1-2，默认: 1]: " user_choice

    # 验证输入：空值默认为1，但0或其他无效值应该报错
    if [[ -z "$user_choice" ]]; then
        user_choice=1
    elif [[ ! "$user_choice" =~ ^[12]$ ]]; then
        print_error "无效的选择，请输入1或2"
        return 1
    fi

    local sub_user_id=""
    local sub_user_email=""

    if [[ "$user_choice" == "1" ]]; then
        # 获取admin用户信息
        local admin_info=$(get_admin_user_info)
        if [[ $? -ne 0 ]]; then
            print_error "无法获取admin用户信息"
            return 1
        fi
        IFS='|' read -r sub_user_id sub_user_password sub_user_email <<< "$admin_info"
    else
        # 显示用户列表
        if [[ ! -f "$USERS_FILE" ]]; then
            print_warning "暂无用户，使用admin用户"
            local admin_info=$(get_admin_user_info)
            if [[ $? -ne 0 ]]; then
                print_error "无法获取admin用户信息"
                return 1
            fi
            IFS='|' read -r sub_user_id sub_user_password sub_user_email <<< "$admin_info"
        else
            local user_count=$(jq -r '.users | length' "$USERS_FILE")
            if [[ "$user_count" -eq 0 ]]; then
                print_warning "暂无用户，使用admin用户"
                local admin_info=$(get_admin_user_info)
                if [[ $? -ne 0 ]]; then
                    print_error "无法获取admin用户信息"
                    return 1
                fi
                IFS='|' read -r sub_user_id sub_user_password sub_user_email <<< "$admin_info"
            else
                echo ""
                echo -e "${YELLOW}用户列表：${NC}"
                local index=1
                while IFS= read -r user; do
                    if [[ -z "$user" || "$user" == "null" ]]; then
                        continue
                    fi

                    local uid=$(echo "$user" | jq -r '.id')
                    local uname=$(echo "$user" | jq -r '.username')
                    local uemail=$(echo "$user" | jq -r '.email // "无邮箱"')

                    printf "${CYAN}[%d]${NC} ${YELLOW}%s${NC} (%s) - UUID: %s\n" "$index" "$uname" "$uemail" "${uid:0:16}..."
                    ((index++))
                done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

                echo ""
                read -p "请输入用户序号: " user_index

                # 验证输入
                if [[ ! "$user_index" =~ ^[0-9]+$ ]] || [[ "$user_index" -lt 1 ]] || [[ "$user_index" -gt "$((index-1))" ]]; then
                    print_error "无效的序号"
                    return 1
                fi

                local user=$(jq -c ".users[$((user_index-1))]" "$USERS_FILE" 2>/dev/null)
                if [[ -z "$user" || "$user" == "null" ]]; then
                    print_error "用户不存在"
                    return 1
                fi

                sub_user_id=$(echo "$user" | jq -r '.id')
                sub_user_email=$(echo "$user" | jq -r '.username')  # 使用用户名而不是邮箱
            fi
        fi
    fi

    echo ""
    echo -e "${CYAN}订阅用户:${NC} ${YELLOW}$sub_user_email${NC}"
    echo ""

    # 选择订阅类型（必须先选择类型，才能检查是否已存在）
    echo -e "${CYAN}选择订阅类型：${NC}"
    echo -e "  ${GREEN}1.${NC} 通用订阅（Base64编码，支持V2Ray/Qv2ray等）"
    echo -e "  ${GREEN}2.${NC} 原始订阅（纯文本，支持所有客户端）"
    echo -e "  ${GREEN}3.${NC} Clash订阅（YAML格式，支持Clash系列）"
    echo -e "  ${GREEN}4.${NC} sing-box订阅（JSON格式，支持sing-box客户端）"
    echo ""
    read -p "请选择 [1-4，默认: 1]: " sub_type_choice
    sub_type_choice=${sub_type_choice:-1}

    # 转换订阅类型为字符串标识
    case $sub_type_choice in
        1) sub_type="general" ;;
        2) sub_type="raw" ;;
        3) sub_type="clash" ;;
        4) sub_type="singbox" ;;
        *) sub_type="general" ;;
    esac

    echo ""

    # 检查该用户是否已有同类型订阅
    local existing_sub=""
    if [[ -f "$SUBSCRIPTION_META_FILE" ]]; then
        existing_sub=$(jq -r ".subscriptions[] | select(.user_id == \"$sub_user_id\" and .type == \"$sub_type\") | .name" "$SUBSCRIPTION_META_FILE" 2>/dev/null | head -1)
    fi

    if [[ -n "$existing_sub" ]]; then
        echo -e "${YELLOW}注意：用户 $sub_user_email 已有 $sub_type 类型订阅：${existing_sub}${NC}"
        echo ""
        read -p "是否更新现有订阅？[Y/n]: " update_existing

        if [[ "$update_existing" == "n" || "$update_existing" == "N" ]]; then
            print_info "取消生成订阅"
            return 0
        fi

        # 使用现有订阅名称
        sub_name="$existing_sub"
        print_info "将更新现有订阅: $sub_name"
    else
        # 订阅名称
        read -p "请输入订阅名称 [默认: ${sub_user_email}-${sub_type}-sub]: " sub_name
        sub_name=${sub_name:-${sub_user_email}-${sub_type}-sub}
    fi

    # 清理订阅名称中的特殊字符和中文，避免乱码
    # 只保留字母、数字、连字符和下划线
    sub_name=$(echo "$sub_name" | tr -cd 'a-zA-Z0-9_-')

    # 如果清理后为空，使用时间戳
    if [[ -z "$sub_name" ]]; then
        sub_name="subscription-$(date +%s)"
    fi

    # 从用户信息读取有效期和流量限制
    echo ""
    print_info "从用户配置读取流量和有效期设置..."

    local user_info=$(jq -r ".users[] | select(.id == \"$sub_user_id\")" "$USERS_FILE" 2>/dev/null)

    if [[ -z "$user_info" || "$user_info" == "null" ]]; then
        print_error "无法找到用户信息"
        return 1
    fi

    local expire_date=$(echo "$user_info" | jq -r '.expire_date // "unlimited"')
    local traffic_limit=$(echo "$user_info" | jq -r '.traffic_limit_gb // "unlimited"')
    local traffic_used=$(echo "$user_info" | jq -r '.traffic_used_gb // "0"')
    local sub_user_password=$(echo "$user_info" | jq -r '.password // ""')

    echo -e "${CYAN}用户配置：${NC}"
    echo -e "  有效期: ${YELLOW}$expire_date${NC}"
    echo -e "  流量限制: ${YELLOW}$traffic_limit GB${NC}"
    echo -e "  已用流量: ${YELLOW}$traffic_used GB${NC}"
    echo ""

    # 收集所有分享链接（新架构：只生成用户绑定的节点）
    print_info "正在生成分享链接..."
    echo ""

    # 获取用户绑定的节点列表
    local user_node_ports=()
    get_user_bound_ports "$sub_user_id"

    if [[ ${#user_node_ports[@]} -eq 0 ]]; then
        print_warning "用户 $sub_user_email 未绑定任何节点"
        echo ""
        read -p "是否生成所有节点的订阅? [y/N]: " use_all_nodes
        if [[ "$use_all_nodes" != "y" && "$use_all_nodes" != "Y" ]]; then
            print_info "取消生成订阅"
            return 0
        fi
        # 如果选择使用所有节点，获取所有节点端口
        while IFS= read -r node; do
            user_node_ports+=($(echo "$node" | jq -r '.port'))
        done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)
    fi

    print_info "用户可访问节点数: ${#user_node_ports[@]}"
    echo ""

    local share_links=()
    local link_count=0

    # 遍历用户绑定的节点
    for port in "${user_node_ports[@]}"; do
        local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)

        if [[ -z "$node" || "$node" == "null" ]]; then
            continue
        fi

        local protocol=$(echo "$node" | jq -r '.protocol')

        # 使用选定的用户生成链接
        local link=$(generate_share_link_smart "$sub_user_id" "$sub_user_email" "$node")
        if [[ -n "$link" ]]; then
            share_links+=("$link")
            ((link_count++))
            echo -e "  ${GREEN}✔${NC} 节点 ${protocol}:${port}"
        else
            echo -e "  ${RED}✘${NC} 节点 ${protocol}:${port} - 生成失败"
        fi
    done

    if [[ $link_count -eq 0 ]]; then
        print_error "没有可用的节点配置"
        return 1
    fi

    echo ""
    print_success "成功生成 $link_count 个分享链接"
    echo ""

    # 生成订阅内容
    local sub_content=""
    local sub_file=""

    case $sub_type in
        general)
            # 通用订阅 - Base64编码（每行一个链接，然后整体编码，不包含最后的换行）
            if [[ ${#share_links[@]} -gt 0 ]]; then
                local raw_links=""
                for link in "${share_links[@]}"; do
                    if [[ -n "$raw_links" ]]; then
                        raw_links="${raw_links}\n${link}"
                    else
                        raw_links="$link"
                    fi
                done
                # 使用echo -e来处理\n,然后Base64编码,去除所有换行
                sub_content=$(echo -e "$raw_links" | base64 -w 0 2>/dev/null || echo -e "$raw_links" | base64 | tr -d '\n')
            else
                sub_content=""
            fi
            # 文件名格式: {name}_{user_id}_base64.txt (便于服务器提取用户信息)
            sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${sub_user_id}_base64.txt"
            ;;
        raw)
            # 原始订阅（纯文本，每行一个链接）
            sub_content=$(printf "%s\n" "${share_links[@]}")
            # 文件名格式: {name}_{user_id}_raw.txt
            sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${sub_user_id}_raw.txt"
            ;;
        clash)
            # Clash订阅 - YAML格式
            # 收集用户绑定的节点JSON数组
            local nodes_json_array="[]"
            for port in "${user_node_ports[@]}"; do
                local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                if [[ -n "$node" && "$node" != "null" ]]; then
                    nodes_json_array=$(echo "$nodes_json_array" | jq --argjson node "$node" '. += [$node]')
                fi
            done

            # 验证是否有节点数据
            local node_count=$(echo "$nodes_json_array" | jq 'length')
            if [[ "$node_count" -eq 0 ]]; then
                echo ""
                print_error "没有找到可用的节点"
                echo ""
                echo -e "${YELLOW}可能的原因：${NC}"
                echo "  1. 用户未绑定任何节点"
                echo "  2. 节点数据文件不存在或为空"
                echo "  3. 节点端口匹配失败"
                echo ""
                echo -e "${CYAN}建议操作：${NC}"
                echo "  1. 检查用户绑定的节点: ${NODES_FILE}"
                echo "  2. 确认节点端口是否正确"
                echo "  3. 先为用户绑定节点，再生成订阅"
                echo ""
                return 1
            fi

            # 生成Clash配置（分离stdout和stderr）
            # 创建临时文件存储stderr
            local clash_stderr_file=$(mktemp)
            local clash_output=$(generate_clash_config "$nodes_json_array" "$sub_user_id" "$sub_user_password" 2>"$clash_stderr_file")
            local clash_exit_code=$?

            if [[ $clash_exit_code -ne 0 ]]; then
                echo ""
                print_error "Clash配置生成失败"
                echo ""
                echo -e "${YELLOW}详细信息：${NC}"
                # 显示所有错误和警告信息
                cat "$clash_stderr_file" | grep -E "^# (ERROR|WARNING)" | sed 's/^# /  /'
                echo ""
                echo -e "${CYAN}提示：${NC}"
                echo "  1. Reality 节点需要 public_key 字段"
                echo "  2. Trojan/SS 节点需要 password 字段"
                echo "  3. 检查节点数据结构是否完整"
                echo "  4. 可以尝试使用【通用订阅】或【原始订阅】格式"
                echo ""

                # 清理临时文件
                rm -f "$clash_stderr_file"
                return 1
            fi

            # 验证生成的配置是否有效
            if [[ -z "$clash_output" ]]; then
                echo ""
                print_error "Clash配置生成为空"
                echo ""
                echo -e "${YELLOW}详细信息：${NC}"
                cat "$clash_stderr_file" | sed 's/^# /  /'
                echo ""
                rm -f "$clash_stderr_file"
                return 1
            fi

            # 配置有效，直接使用（DEBUG信息已通过条件判断被禁用）
            sub_content="$clash_output"

            # 清理临时文件
            rm -f "$clash_stderr_file"
            # 文件名格式: {name}_{user_id}_clash.yaml
            sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${sub_user_id}_clash.yaml"
            ;;
        singbox)
            # sing-box订阅 - JSON格式
            # 收集用户绑定的节点JSON数组
            local nodes_json_array="[]"
            for port in "${user_node_ports[@]}"; do
                local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                if [[ -n "$node" && "$node" != "null" ]]; then
                    nodes_json_array=$(echo "$nodes_json_array" | jq --argjson node "$node" '. += [$node]')
                fi
            done

            # 验证是否有节点数据
            local node_count=$(echo "$nodes_json_array" | jq 'length')
            if [[ "$node_count" -eq 0 ]]; then
                echo ""
                print_error "没有找到可用的节点"
                echo ""
                echo -e "${YELLOW}可能的原因：${NC}"
                echo "  1. 用户未绑定任何节点"
                echo "  2. 节点数据文件不存在或为空"
                echo "  3. 节点端口匹配失败"
                echo ""
                echo -e "${CYAN}建议操作：${NC}"
                echo "  1. 检查用户绑定的节点: ${NODES_FILE}"
                echo "  2. 确认节点端口是否正确"
                echo "  3. 先为用户绑定节点，再生成订阅"
                echo ""
                return 1
            fi

            # 生成 sing-box 配置（分离stdout和stderr）
            local singbox_stderr_file=$(mktemp)
            local singbox_output=$(generate_singbox_subscription_config "$nodes_json_array" "$sub_user_id" "$sub_user_password" 2>"$singbox_stderr_file")
            local singbox_exit_code=$?

            if [[ $singbox_exit_code -ne 0 ]]; then
                echo ""
                print_error "sing-box配置生成失败"
                echo ""
                echo -e "${YELLOW}详细信息：${NC}"
                cat "$singbox_stderr_file" | grep -E "^# (ERROR|WARNING)" | sed 's/^# /  /'
                echo ""
                echo -e "${CYAN}提示：${NC}"
                echo "  1. Reality 节点需要 public_key 字段"
                echo "  2. Trojan/SS 节点需要 password 字段"
                echo "  3. 检查节点数据结构是否完整"
                echo "  4. 可以尝试使用【通用订阅】或【原始订阅】格式"
                echo ""
                rm -f "$singbox_stderr_file"
                return 1
            fi

            # 验证生成的配置是否有效
            if [[ -z "$singbox_output" ]]; then
                echo ""
                print_error "sing-box配置生成为空"
                echo ""
                echo -e "${YELLOW}详细信息：${NC}"
                cat "$singbox_stderr_file" | sed 's/^# /  /'
                echo ""
                rm -f "$singbox_stderr_file"
                return 1
            fi

            # 配置有效，直接使用
            sub_content="$singbox_output"

            # 清理临时文件
            rm -f "$singbox_stderr_file"
            # 文件名格式: {name}_{user_id}_singbox.json
            sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${sub_user_id}_singbox.json"
            ;;
    esac

    # 保存订阅文件
    echo "$sub_content" > "$sub_file"

    # 生成订阅URL
    echo -e "${CYAN}订阅访问配置：${NC}"
    echo ""

    read -p "请输入订阅访问域名或IP [留空使用服务器IP]: " sub_domain
    if [[ -z "$sub_domain" ]]; then
        sub_domain=$(get_subscription_domain_hint)
    fi
    if [[ -z "$sub_domain" ]]; then
        sub_domain=$(get_public_ip)
    fi
    if [[ -z "$sub_domain" ]]; then
        sub_domain="127.0.0.1"
    fi

    read -p "请输入订阅端口 [默认: 8080]: " sub_port
    sub_port=${sub_port:-8080}

    # 订阅路径
    local sub_filename=$(basename "$sub_file")
    local sub_url="http://${sub_domain}:${sub_port}/sub/${sub_filename}"

    # 保存订阅信息到数据库
    save_subscription_info "$sub_name" "$sub_url" "$sub_file" "$sub_type" "$sub_user_email"

    # 保存订阅元数据（用户ID和订阅类型）
    save_subscription_metadata "$sub_name" "$sub_user_id" "$sub_type"

    # 启动订阅服务
    setup_subscription_server "$sub_port"

    # 显示结果
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        订阅生成成功！                ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}订阅信息：${NC}"
    echo -e "  订阅名称: ${YELLOW}$sub_name${NC}"
    echo -e "  绑定用户: ${YELLOW}$sub_user_email${NC}"
    echo -e "  节点数量: ${YELLOW}$link_count${NC}"
    echo -e "  订阅类型: ${YELLOW}$(get_sub_type_name $sub_type)${NC}"
    if [[ "$expire_date" != "unlimited" ]]; then
        echo -e "  有效期至: ${YELLOW}$expire_date${NC}"
    else
        echo -e "  有效期至: ${YELLOW}无限期${NC}"
    fi
    if [[ "$traffic_limit" != "unlimited" ]]; then
        echo -e "  流量限制: ${YELLOW}${traffic_limit}GB${NC}"
    else
        echo -e "  流量限制: ${YELLOW}无限${NC}"
    fi
    echo ""
    echo -e "${CYAN}订阅链接：${NC}"
    echo -e "${GREEN}${sub_url}${NC}"
    echo ""
    echo -e "${YELLOW}使用说明：${NC}"
    echo -e "  1. 复制上面的订阅链接"
    echo -e "  2. 在客户端中添加订阅"
    echo -e "  3. 更新订阅获取节点"
    echo ""

    # 显示支持的客户端
    case $sub_type in
        general)
            echo -e "${CYAN}支持的客户端：${NC}"
            echo -e "  • V2RayN/V2RayNG"
            echo -e "  • Shadowrocket"
            echo -e "  • Quantumult X"
            echo -e "  • SagerNet"
            ;;
        raw)
            echo -e "${CYAN}支持的客户端：${NC}"
            echo -e "  • 所有支持订阅的客户端"
            echo -e "  • 可手动复制链接导入"
            ;;
        clash)
            echo -e "${CYAN}支持的客户端（推荐）：${NC}"
            echo -e "  • Clash Verge (推荐) - 跨平台"
            echo -e "  • Clash Verge Rev - 社区维护版"
            echo -e "  • Clash Meta - 核心版本"
            echo -e "  • Clash Nyanpasu - 新一代客户端"
            echo -e "  • Clash for Android - 需 Meta 核心"
            echo ""
            echo -e "${YELLOW}注意：${NC}"
            echo -e "  • Reality 节点需要 Clash Meta 内核支持"
            echo -e "  • 不支持原版 Clash Premium"
            ;;
    esac
    echo ""
}

# 获取订阅类型名称
get_sub_type_name() {
    case $1 in
        1|general) echo "通用订阅 (Base64)" ;;
        2|raw) echo "原始订阅 (纯文本)" ;;
        3|clash) echo "Clash订阅 (YAML)" ;;
        4|singbox) echo "sing-box订阅 (JSON)" ;;
        *) echo "未知类型" ;;
    esac
}

# 同步订阅数据库（清理不存在的文件记录）
sync_subscription_database() {
    local sub_db="${DATA_DIR}/subscriptions.json"

    if [[ ! -f "$sub_db" ]]; then
        return 0
    fi

    # 获取所有数据库中的订阅
    local names_to_remove=()
    while IFS= read -r name; do
        if [[ -z "$name" ]]; then
            continue
        fi

        # 检查订阅文件是否存在
        local sub_file=$(find_subscription_file "$name" 2>/dev/null)
        if [[ -z "$sub_file" ]]; then
            names_to_remove+=("$name")
        fi
    done < <(jq -r '.subscriptions[].name' "$sub_db" 2>/dev/null)

    # 批量删除不存在的记录
    if [[ ${#names_to_remove[@]} -gt 0 ]]; then
        for name in "${names_to_remove[@]}"; do
            remove_subscription_info "$name" 2>/dev/null
            delete_subscription_metadata "$name" 2>/dev/null
        done
    fi
}

# 查看订阅列表
show_subscription() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          订阅列表                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -d "$SUBSCRIPTION_DIR" ]]; then
        print_warning "暂无订阅"
        return 0
    fi

    local sub_db="${DATA_DIR}/subscriptions.json"
    if [[ ! -f "$sub_db" ]]; then
        print_warning "暂无订阅"
        return 0
    fi

    # 同步数据库，清理不存在的文件记录
    sync_subscription_database

    local sub_count=$(jq -r '.subscriptions | length' "$sub_db" 2>/dev/null || echo "0")
    if [[ "$sub_count" -eq 0 ]]; then
        print_warning "暂无订阅"
        return 0
    fi

    echo -e "${YELLOW}订阅总数:${NC} $sub_count"
    echo ""
    printf "${CYAN}%-4s %-20s %-15s %-12s %-15s %-15s${NC}\n" "序号" "订阅名称" "绑定用户" "类型" "有效期" "流量限制"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    while read -r sub; do
        if [[ -z "$sub" || "$sub" == "null" ]]; then
            continue
        fi

        local name=$(echo "$sub" | jq -r '.name')
        local url=$(echo "$sub" | jq -r '.url')
        local user=$(echo "$sub" | jq -r '.user // "N/A"')

        # 从元数据获取user_id和type
        local metadata=$(get_subscription_metadata "$name")
        local user_id=$(echo "$metadata" | jq -r '.user_id // empty')
        local type=$(echo "$metadata" | jq -r '.type // "unknown"')
        local type_name=$(get_sub_type_name "$type")

        local expire_display="无限期"
        local traffic_display="无限"

        # 从用户信息读取流量和有效期
        if [[ -n "$user_id" ]]; then
            local user_info=$(jq -r ".users[] | select(.id == \"$user_id\")" "$USERS_FILE" 2>/dev/null)
            if [[ -n "$user_info" && "$user_info" != "null" ]]; then
                local expire_date=$(echo "$user_info" | jq -r '.expire_date // "unlimited"')
                local traffic_limit=$(echo "$user_info" | jq -r '.traffic_limit_gb // "unlimited"')
                local traffic_used=$(echo "$user_info" | jq -r '.traffic_used_gb // "0"')

                if [[ "$expire_date" != "unlimited" ]]; then
                    # 检查是否过期
                    local today=$(date +%Y-%m-%d)
                    if [[ "$expire_date" < "$today" ]]; then
                        expire_display="${expire_date}(已过期)"
                    else
                        expire_display="$expire_date"
                    fi
                fi

                if [[ "$traffic_limit" != "unlimited" ]]; then
                    traffic_display="${traffic_used}/${traffic_limit}GB"
                    # 检查是否超限
                    if (( $(echo "$traffic_used >= $traffic_limit" | bc -l 2>/dev/null || echo 0) )); then
                        traffic_display="${traffic_display}(超限)"
                    fi
                fi
            fi
        fi

        printf "%-4s %-20s %-15s %-12s %-15s %-15s\n" "$index" "$name" "$user" "$type_name" "$expire_display" "$traffic_display"
        ((index++))
    done < <(jq -c '.subscriptions[]' "$sub_db" 2>/dev/null)
}

# 查看订阅链接(显示实际访问URL)
show_subscription_links() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          订阅链接查看                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 先显示订阅列表
    show_subscription

    local sub_db="${DATA_DIR}/subscriptions.json"
    if [[ ! -f "$sub_db" ]]; then
        return 0
    fi

    local sub_count=$(jq -r '.subscriptions | length' "$sub_db" 2>/dev/null || echo "0")
    if [[ "$sub_count" -eq 0 ]]; then
        return 0
    fi

    # 获取服务器IP
    local server_host=$(get_subscription_domain_hint)
    if [[ -z "$server_host" ]]; then
        server_host=$(get_public_ip)
    fi
    if [[ -z "$server_host" ]]; then
        print_error "无法获取服务器IP"
        return 1
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}订阅访问链接：${NC}"
    echo ""

    local index=1
    while read -r sub; do
        if [[ -z "$sub" || "$sub" == "null" ]]; then
            continue
        fi

        local name=$(echo "$sub" | jq -r '.name')
        local url=$(echo "$sub" | jq -r '.url // empty')

        # 从元数据获取类型
        local metadata=$(get_subscription_metadata "$name")
        local type=$(echo "$metadata" | jq -r '.type // "general"')
        local user_id=$(echo "$metadata" | jq -r '.user_id // empty')

        # 获取用户名
        local username="N/A"
        if [[ -n "$user_id" ]]; then
            username=$(jq -r ".users[] | select(.id == \"$user_id\") | .username" "$USERS_FILE" 2>/dev/null)
        fi

        # 获取订阅端口
        local sub_port=$(cat "${DATA_DIR}/sub_port.txt" 2>/dev/null || echo "8080")

        # 使用实际文件构建访问URL
        local sub_file_path=$(echo "$sub" | jq -r '.file // empty')
        local resolved_file=""
        if [[ -n "$sub_file_path" && -f "$sub_file_path" ]]; then
            resolved_file="$sub_file_path"
        else
            resolved_file=$(find_subscription_file "$name" 2>/dev/null)
        fi

        local access_url=""
        if [[ -n "$resolved_file" && -f "$resolved_file" ]]; then
            local filename=$(basename "$resolved_file")
            access_url="http://${server_host}:${sub_port}/sub/${filename}"
        elif [[ -n "$url" ]]; then
            access_url="$url"
        fi

        echo -e "${YELLOW}[$index] $name${NC} (用户: ${CYAN}$username${NC})"
        if [[ -n "$access_url" ]]; then
            echo -e "    ${GREEN}$access_url${NC}"
        else
            echo -e "    ${RED}无法生成URL${NC}"
        fi
        echo ""
        ((index++))
    done < <(jq -c '.subscriptions[]' "$sub_db" 2>/dev/null)

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# 删除订阅
delete_subscription() {
    show_subscription

    echo ""
    read -p "请输入要删除的订阅名称: " sub_name
    if [[ -z "$sub_name" ]]; then
        print_error "订阅名称不能为空"
        return 1
    fi

    local sub_db="${DATA_DIR}/subscriptions.json"
    local sub_info=$(jq -r ".subscriptions[] | select(.name == \"$sub_name\")" "$sub_db" 2>/dev/null)

    if [[ -z "$sub_info" ]]; then
        print_error "订阅不存在"
        return 1
    fi

    read -p "确认删除订阅 ${sub_name}? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消删除"
        return 0
    fi

    # 获取订阅文件路径
    local sub_file=$(echo "$sub_info" | jq -r '.file')

    # 删除订阅文件
    if [[ -f "$sub_file" ]]; then
        rm -f "$sub_file"
    fi

    # 从数据库删除
    remove_subscription_info "$sub_name"

    # 删除订阅元数据
    delete_subscription_metadata "$sub_name"

    print_success "订阅删除成功"
}

# 重新生成订阅（更新现有订阅）
regenerate_subscription() {
    local sub_name="$1"

    if [[ -z "$sub_name" ]]; then
        print_error "订阅名称不能为空"
        return 1
    fi

    local sub_db="${DATA_DIR}/subscriptions.json"
    if [[ ! -f "$sub_db" ]]; then
        print_error "订阅数据库不存在"
        return 1
    fi

    # 获取订阅信息
    local sub_info=$(jq -r ".subscriptions[] | select(.name == \"$sub_name\")" "$sub_db" 2>/dev/null)
    if [[ -z "$sub_info" ]]; then
        print_error "订阅 '${sub_name}' 不存在"
        return 1
    fi

    # 获取订阅配置
    local user_id=$(echo "$sub_info" | jq -r '.user_id // empty')
    local sub_type=$(echo "$sub_info" | jq -r '.type // "base64"')

    # 根据新的文件命名规则生成文件路径
    local sub_file=""
    if [[ -n "$user_id" ]]; then
        case "$sub_type" in
            "base64")
                sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${user_id}_base64.txt"
                ;;
            "clash")
                sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${user_id}_clash.yaml"
                ;;
            "raw")
                sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${user_id}_raw.txt"
                ;;
            *)
                # 兼容旧格式
                sub_file=$(echo "$sub_info" | jq -r '.file')
                ;;
        esac
    else
        # 无用户绑定，使用旧格式
        sub_file=$(echo "$sub_info" | jq -r '.file')
    fi

    echo ""
    print_info "正在重新生成订阅: ${sub_name}"
    print_info "订阅类型: ${sub_type}"
    if [[ -n "$user_id" ]]; then
        local user_email=$(jq -r ".users[] | select(.id == \"$user_id\") | .email" "$USERS_FILE" 2>/dev/null)
        print_info "绑定用户: ${user_email} (${user_id})"
    fi

    # 根据订阅类型重新生成内容
    case "$sub_type" in
        "base64")
            # Base64编码订阅
            local links=""
            if [[ -n "$user_id" ]]; then
                # 用户绑定订阅：只包含该用户的节点
                links=$(generate_user_share_links "$user_id")
            else
                # 通用订阅：包含所有节点+所有用户
                links=$(generate_all_share_links)
            fi

            if [[ -z "$links" ]]; then
                print_error "没有可用的节点"
                return 1
            fi

            # Base64编码
            local encoded=$(echo -n "$links" | base64 -w 0 2>/dev/null || echo -n "$links" | base64)
            echo "$encoded" > "$sub_file"
            ;;

        "clash")
            # Clash YAML格式
            # 获取用户绑定的节点（使用统一函数）
            local user_node_ports=()
            if [[ -n "$user_id" ]]; then
                get_user_bound_ports "$user_id"
            else
                # 没有绑定用户，使用所有节点
                while IFS= read -r node; do
                    user_node_ports+=($(echo "$node" | jq -r '.port'))
                done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)
            fi

            # 收集节点JSON数组
            local nodes_json_array="[]"
            for port in "${user_node_ports[@]}"; do
                local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                if [[ -n "$node" && "$node" != "null" ]]; then
                    nodes_json_array=$(echo "$nodes_json_array" | jq --argjson node "$node" '. += [$node]')
                fi
            done

            # 验证是否有节点数据
            local node_count=$(echo "$nodes_json_array" | jq 'length')
            if [[ "$node_count" -eq 0 ]]; then
                print_error "没有找到可用的节点"
                echo ""
                echo -e "${YELLOW}可能的原因：${NC}"
                echo "  1. 用户未绑定任何节点"
                echo "  2. 节点数据文件不存在或为空"
                echo "  3. 节点端口匹配失败"
                echo ""
                return 1
            fi

            # 获取用户密码（用于 Trojan/SS）
            local user_password=""
            if [[ -n "$user_id" ]]; then
                user_password=$(jq -r ".users[] | select(.id == \"$user_id\") | .password // \"\"" "$USERS_FILE" 2>/dev/null)
            fi

            # 生成 Clash 配置（使用与新生成订阅相同的错误处理逻辑）
            local clash_stderr_file=$(mktemp)
            local clash_output=$(generate_clash_config "$nodes_json_array" "$user_id" "$user_password" 2>"$clash_stderr_file")
            local clash_exit_code=$?

            if [[ $clash_exit_code -ne 0 ]]; then
                print_error "Clash配置生成失败"
                echo ""
                echo -e "${YELLOW}详细信息：${NC}"
                cat "$clash_stderr_file" | grep -E "^# (ERROR|WARNING)" | sed 's/^# /  /'
                echo ""
                rm -f "$clash_stderr_file"
                return 1
            fi

            # 验证生成的配置是否有效
            if [[ -z "$clash_output" ]]; then
                print_error "Clash配置生成为空"
                echo ""
                echo -e "${YELLOW}详细信息：${NC}"
                cat "$clash_stderr_file" | sed 's/^# /  /'
                echo ""
                rm -f "$clash_stderr_file"
                return 1
            fi

            # 保存配置到文件
            echo "$clash_output" > "$sub_file"

            # 清理临时文件
            rm -f "$clash_stderr_file"
            ;;

        "singbox")
            # sing-box JSON 格式
            local nodes_json_array="[]"
            if [[ -n "$user_id" ]]; then
                # 获取用户绑定的节点
                local user_node_ports=()
                get_user_bound_ports "$user_id"

                for port in "${user_node_ports[@]}"; do
                    local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                    if [[ -n "$node" && "$node" != "null" ]]; then
                        nodes_json_array=$(echo "$nodes_json_array" | jq --argjson node "$node" '. += [$node]')
                    fi
                done
            else
                # 没有绑定用户，使用所有节点
                while IFS= read -r node; do
                    nodes_json_array=$(echo "$nodes_json_array" | jq --argjson node "$node" '. += [$node]')
                done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)
            fi

            # 验证节点数据
            local node_count=$(echo "$nodes_json_array" | jq 'length')
            if [[ "$node_count" -eq 0 ]]; then
                print_error "没有可用的节点"
                return 1
            fi

            # 获取用户密码（用于 Trojan/SS）
            local user_password=""
            if [[ -n "$user_id" ]]; then
                user_password=$(jq -r ".users[] | select(.id == \"$user_id\") | .password // \"\"" "$USERS_FILE" 2>/dev/null)
            fi

            # 生成 sing-box 配置
            local singbox_stderr_file=$(mktemp)
            local singbox_output=$(generate_singbox_subscription_config "$nodes_json_array" "$user_id" "$user_password" 2>"$singbox_stderr_file")
            local singbox_exit_code=$?

            if [[ $singbox_exit_code -ne 0 ]] || [[ -z "$singbox_output" ]]; then
                print_error "sing-box配置生成失败"
                cat "$singbox_stderr_file" | grep -E "^# (ERROR|WARNING)" | sed 's/^# /  /'
                rm -f "$singbox_stderr_file"
                return 1
            fi

            # 保存配置到文件
            echo "$singbox_output" > "$sub_file"

            # 清理临时文件
            rm -f "$singbox_stderr_file"
            ;;

        "raw")
            # 原始文本格式
            if [[ -n "$user_id" ]]; then
                generate_user_share_links "$user_id" > "$sub_file"
            else
                generate_all_share_links > "$sub_file"
            fi
            ;;

        *)
            print_error "未知的订阅类型: ${sub_type}"
            return 1
            ;;
    esac

    # 更新订阅信息（更新时间、文件路径和URL）
    local port=$(cat "${DATA_DIR}/subscription_port.txt" 2>/dev/null || echo "8080")
    local server_ip=$(get_subscription_domain_hint)
    if [[ -z "$server_ip" ]]; then
        server_ip=$(get_public_ip)
    fi
    if [[ -z "$server_ip" ]]; then
        server_ip="127.0.0.1"
    fi
    local sub_filename=$(basename "$sub_file")
    local sub_url="http://${server_ip}:${port}/sub/${sub_filename}"

    jq --arg name "$sub_name" --arg url "$sub_url" --arg file "$sub_file" \
       '(.subscriptions[] | select(.name == $name)) |= (. + {url: $url, file: $file, updated: (now|todate)})' \
       "$sub_db" > "${sub_db}.tmp"
    mv "${sub_db}.tmp" "$sub_db"

    print_success "订阅重新生成成功！"

    # 显示订阅信息

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          订阅链接                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}订阅名称:${NC} ${sub_name}"
    echo -e "${GREEN}订阅类型:${NC} ${sub_type}"
    echo -e "${GREEN}订阅链接:${NC}"
    echo ""
    echo -e "${YELLOW}${sub_url}${NC}"
    echo ""
}

# 订阅配置
config_subscription() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          订阅配置                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${GREEN}1.${NC} 设置订阅端口"
    echo -e "${GREEN}2.${NC} 重启订阅服务"
    echo -e "${GREEN}3.${NC} 查看订阅服务状态"
    echo -e "${GREEN}4.${NC} 查看单个节点分享链接"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-4]: " choice

    case $choice in
        1)
            read -p "请输入订阅端口 [1-65535]: " sub_port
            if [[ -n "$sub_port" && "$sub_port" =~ ^[0-9]+$ ]]; then
                if [[ $sub_port -ge 1 && $sub_port -le 65535 ]]; then
                    echo "$sub_port" > "${DATA_DIR}/sub_port.txt"
                    setup_subscription_server "$sub_port"
                    print_success "订阅端口设置成功"
                else
                    print_error "端口范围必须在 1-65535 之间"
                fi
            fi
            ;;
        2)
            local sub_port=$(cat "${DATA_DIR}/sub_port.txt" 2>/dev/null || echo "8080")
            setup_subscription_server "$sub_port"
            print_success "订阅服务重启成功"
            ;;
        3)
            if pgrep -f "python.*subscription_server" > /dev/null 2>&1; then
                local sub_port=$(cat "${DATA_DIR}/sub_port.txt" 2>/dev/null || echo "8080")
                print_success "订阅服务运行中"
                print_info "监听端口: $sub_port"
            else
                print_warning "订阅服务未运行"
            fi
            ;;
        4)
            show_node_share_link
            ;;
    esac
}

# 设置订阅服务器
setup_subscription_server() {
    local port=$1

    # 停止已有服务
    pkill -f "python.*subscription_server" 2>/dev/null

    # 创建简单的 HTTP 服务器脚本
    cat > "${DATA_DIR}/subscription_server.py" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import http.server
import socketserver
import os
import sys
import json
from urllib.parse import unquote
from datetime import datetime

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
DATA_DIR = sys.argv[3] if len(sys.argv) > 3 else os.path.dirname(DIRECTORY)

class SubscriptionHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def get_user_info_from_filename(self, filename):
        """从订阅文件名中提取用户信息"""
        try:
            # 订阅文件名格式: {name}_{user_id}_{type}.txt
            # 例如: mysubscription_abc123_base64.txt
            parts = filename.rsplit('_', 2)
            if len(parts) >= 3:
                user_id = parts[1]
                return user_id
        except:
            pass
        return None

    def get_subscription_userinfo(self, user_id):
        """读取用户流量和期限信息"""
        try:
            users_file = os.path.join(DATA_DIR, 'users.json')
            if not os.path.exists(users_file):
                return None

            with open(users_file, 'r', encoding='utf-8') as f:
                users_data = json.load(f)

            # 查找用户
            user = None
            for u in users_data.get('users', []):
                if u.get('id') == user_id:
                    user = u
                    break

            if not user:
                return None

            # 提取流量信息
            traffic_limit = user.get('traffic_limit_gb', 'unlimited')
            traffic_used = float(user.get('traffic_used_gb', 0))

            # 计算上传和下载（这里简化为各占一半）
            upload_bytes = int(traffic_used * 1073741824 / 2)
            download_bytes = int(traffic_used * 1073741824 / 2)

            # 计算总流量限制
            if traffic_limit == 'unlimited':
                total_bytes = 0  # 0 表示无限制
            else:
                total_bytes = int(float(traffic_limit) * 1073741824)

            # 提取过期时间
            expire_date = user.get('expire_date', 'unlimited')
            if expire_date == 'unlimited':
                expire_timestamp = 0  # 0 表示永不过期
            else:
                try:
                    dt = datetime.strptime(expire_date, '%Y-%m-%d')
                    expire_timestamp = int(dt.timestamp())
                except:
                    expire_timestamp = 0

            # 返回格式: upload=xxx; download=xxx; total=xxx; expire=xxx
            return f'upload={upload_bytes}; download={download_bytes}; total={total_bytes}; expire={expire_timestamp}'

        except Exception as e:
            print(f'[订阅服务] 读取用户信息失败: {e}', file=sys.stderr)
            return None

    def do_GET(self):
        if self.path.startswith('/sub/'):
            filename = unquote(self.path[5:])
            filepath = os.path.join(DIRECTORY, filename)

            if os.path.exists(filepath):
                self.send_response(200)

                # 根据文件扩展名设置正确的Content-Type
                if filename.endswith('.yaml') or filename.endswith('.yml'):
                    content_type = 'text/yaml; charset=utf-8'
                elif filename.endswith('.json'):
                    content_type = 'application/json; charset=utf-8'
                else:
                    content_type = 'text/plain; charset=utf-8'

                self.send_header('Content-Type', content_type)
                self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')

                # 获取文件大小并发送Content-Length
                file_size = os.path.getsize(filepath)
                self.send_header('Content-Length', str(file_size))

                # 添加订阅用户信息头
                user_id = self.get_user_info_from_filename(filename)
                if user_id:
                    userinfo = self.get_subscription_userinfo(user_id)
                    if userinfo:
                        self.send_header('subscription-userinfo', userinfo)
                        self.send_header('profile-update-interval', '24')  # 建议客户端每24小时更新一次

                self.end_headers()

                # 分块读取文件，避免大文件内存问题和超时
                with open(filepath, 'rb') as f:
                    chunk_size = 8192
                    while True:
                        chunk = f.read(chunk_size)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
            else:
                self.send_error(404, 'Subscription not found')
        else:
            self.send_error(403, 'Access denied')

    def log_message(self, format, *args):
        pass

if __name__ == '__main__':
    try:
        socketserver.TCPServer.allow_reuse_address = True
        with socketserver.TCPServer(("", PORT), SubscriptionHandler) as httpd:
            print(f"[订阅服务] 运行在端口 {PORT}")
            print(f"[订阅服务] 文件目录: {DIRECTORY}")
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[订阅服务] 停止")
    except Exception as e:
        print(f"[订阅服务] 错误: {e}")
PYEOF

    chmod +x "${DATA_DIR}/subscription_server.py"

    # 后台启动服务（传递 DATA_DIR 作为第三个参数）
    nohup python3 "${DATA_DIR}/subscription_server.py" "$port" "$SUBSCRIPTION_DIR" "$DATA_DIR" > /dev/null 2>&1 &

    sleep 1

    if pgrep -f "python.*subscription_server" > /dev/null 2>&1; then
        print_success "订阅服务已启动"
        print_info "监听端口: $port"
    else
        print_error "订阅服务启动失败"
    fi
}

# 保存订阅信息
save_subscription_info() {
    local name=$1
    local url=$2
    local file=$3
    local type=$4
    local user=$5

    local sub_db="${DATA_DIR}/subscriptions.json"
    if [[ ! -f "$sub_db" ]]; then
        echo '{"subscriptions":[]}' > "$sub_db"
    fi

    # 检查是否已存在
    local exists=$(jq -r --arg name "$name" '.subscriptions[] | select(.name == $name) | .name' "$sub_db" 2>/dev/null)

    if [[ -n "$exists" ]]; then
        # 更新现有订阅
        if ! jq --arg name "$name" --arg url "$url" --arg file "$file" --arg type "$type" --arg user "$user" \
           '.subscriptions = [.subscriptions[] | if .name == $name then {name: $name, url: $url, file: $file, type: $type, user: $user, updated: now|todate} else . end]' \
           "$sub_db" > "${sub_db}.tmp"; then
            print_error "更新订阅信息失败"
            rm -f "${sub_db}.tmp"
            return 1
        fi
    else
        # 添加新订阅
        local sub_data=$(jq -n \
            --arg name "$name" \
            --arg url "$url" \
            --arg file "$file" \
            --arg type "$type" \
            --arg user "$user" \
            '{name: $name, url: $url, file: $file, type: $type, user: $user, created: now|todate}')

        if ! jq ".subscriptions += [$sub_data]" "$sub_db" > "${sub_db}.tmp"; then
            print_error "添加订阅信息失败"
            rm -f "${sub_db}.tmp"
            return 1
        fi
    fi

    mv "${sub_db}.tmp" "$sub_db"
}

# 删除订阅信息
remove_subscription_info() {
    local name=$1
    local sub_db="${DATA_DIR}/subscriptions.json"

    if [[ ! -f "$sub_db" ]]; then
        return 0
    fi

    # 使用--arg传递参数，避免特殊字符问题
    if ! jq --arg name "$name" '.subscriptions = [.subscriptions[] | select(.name != $name)]' "$sub_db" > "${sub_db}.tmp"; then
        print_error "删除订阅信息失败"
        rm -f "${sub_db}.tmp"
        return 1
    fi
    mv "${sub_db}.tmp" "$sub_db"
}

# 更新订阅名称
update_subscription_name() {
    local old_name=$1
    local new_name=$2
    local sub_db="${DATA_DIR}/subscriptions.json"

    if [[ ! -f "$sub_db" ]]; then
        return 1
    fi

    # 更新订阅名称,保留其他信息
    if ! jq ".subscriptions = [.subscriptions[] | if .name == \"$old_name\" then .name = \"$new_name\" | .updated = (now|todate) else . end]" "$sub_db" > "${sub_db}.tmp"; then
        print_error "更新订阅名称失败"
        rm -f "${sub_db}.tmp"
        return 1
    fi
    mv "${sub_db}.tmp" "$sub_db"
}

# 更新订阅文件路径
update_subscription_file() {
    local name=$1
    local new_file=$2
    local sub_db="${DATA_DIR}/subscriptions.json"

    if [[ ! -f "$sub_db" ]]; then
        return 1
    fi

    # 更新文件路径
    if ! jq ".subscriptions = [.subscriptions[] | if .name == \"$name\" then .file = \"$new_file\" | .updated = (now|todate) else . end]" "$sub_db" > "${sub_db}.tmp"; then
        print_error "更新订阅文件路径失败"
        rm -f "${sub_db}.tmp"
        return 1
    fi
    mv "${sub_db}.tmp" "$sub_db"
}

# 更新别名（兼容旧函数名）
generate_subscription() {
    generate_subscription_with_user
}

# 更新指定用户的所有订阅内容
# 参数: $1=用户ID
update_user_subscriptions() {
    local target_user_id="$1"

    if [[ -z "$target_user_id" ]]; then
        print_error "用户ID不能为空"
        return 1
    fi

    # 获取用户信息
    local user_info=$(jq -r ".users[] | select(.id == \"$target_user_id\")" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$user_info" || "$user_info" == "null" ]]; then
        print_error "用户不存在 (ID: $target_user_id)"
        return 1
    fi

    local username=$(echo "$user_info" | jq -r '.username // .email // "unknown"')
    local user_password=$(echo "$user_info" | jq -r '.password // ""')

    # 从元数据中查找该用户的所有订阅
    if [[ ! -f "$SUBSCRIPTION_META_FILE" ]]; then
        print_warning "用户 $username 没有订阅"
        return 0
    fi

    local user_subscriptions=$(jq -c ".subscriptions[] | select(.user_id == \"$target_user_id\")" "$SUBSCRIPTION_META_FILE" 2>/dev/null)

    if [[ -z "$user_subscriptions" ]]; then
        print_warning "用户 $username 没有订阅"
        return 0
    fi

    local updated_count=0
    local failed_count=0

    # 遍历用户的所有订阅
    while IFS= read -r sub_meta; do
        local sub_name=$(echo "$sub_meta" | jq -r '.name')
        local sub_type=$(echo "$sub_meta" | jq -r '.type')

        print_info "更新订阅: $sub_name (类型: $sub_type)"

        # 调用核心更新逻辑
        if regenerate_subscription_content "$sub_name" "$target_user_id" "$username" "$user_password" "$sub_type"; then
            ((updated_count++))
            print_success "✓ $sub_name"
        else
            ((failed_count++))
            print_error "✗ $sub_name"
        fi
        echo ""
    done <<< "$user_subscriptions"

    echo -e "${CYAN}用户 $username 订阅更新完成${NC}"
    echo -e "  成功: ${GREEN}$updated_count${NC}"
    if [[ $failed_count -gt 0 ]]; then
        echo -e "  失败: ${RED}$failed_count${NC}"
    fi

    return 0
}

# 重新生成订阅内容的核心逻辑（参考 generate_subscription_with_user）
# 参数: $1=订阅名称, $2=用户ID, $3=用户名, $4=用户密码, $5=订阅类型
regenerate_subscription_content() {
    local sub_name="$1"
    local sub_user_id="$2"
    local sub_user_email="$3"
    local sub_user_password="$4"
    local sub_type="$5"

    # 1. 获取用户绑定的节点列表
    local user_node_ports=()
    get_user_bound_ports "$sub_user_id"

    if [[ ${#user_node_ports[@]} -eq 0 ]]; then
        print_warning "用户未绑定节点，使用所有节点"
        while IFS= read -r node; do
            user_node_ports+=($(echo "$node" | jq -r '.port'))
        done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)
    fi

    if [[ ${#user_node_ports[@]} -eq 0 ]]; then
        print_error "没有可用的节点"
        return 1
    fi

    # 2. 根据订阅类型生成内容
    local sub_content=""
    local sub_file=""

    case $sub_type in
        general)
            # 通用订阅 - Base64编码
            local share_links=()
            for port in "${user_node_ports[@]}"; do
                local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                if [[ -n "$node" && "$node" != "null" ]]; then
                    local link=$(generate_share_link_smart "$sub_user_id" "$sub_user_email" "$node")
                    [[ -n "$link" ]] && share_links+=("$link")
                fi
            done

            [[ ${#share_links[@]} -eq 0 ]] && { print_error "没有可用节点"; return 1; }

            local raw_links=""
            for link in "${share_links[@]}"; do
                [[ -n "$raw_links" ]] && raw_links="${raw_links}\n${link}" || raw_links="$link"
            done
            sub_content=$(echo -e "$raw_links" | base64 -w 0 2>/dev/null || echo -e "$raw_links" | base64 | tr -d '\n')
            sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${sub_user_id}_base64.txt"
            ;;

        raw)
            # 原始订阅
            local share_links=()
            for port in "${user_node_ports[@]}"; do
                local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                if [[ -n "$node" && "$node" != "null" ]]; then
                    local link=$(generate_share_link_smart "$sub_user_id" "$sub_user_email" "$node")
                    [[ -n "$link" ]] && share_links+=("$link")
                fi
            done

            [[ ${#share_links[@]} -eq 0 ]] && { print_error "没有可用节点"; return 1; }

            sub_content=$(printf "%s\n" "${share_links[@]}")
            sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${sub_user_id}_raw.txt"
            ;;

        clash)
            # Clash订阅
            local nodes_json_array="[]"
            for port in "${user_node_ports[@]}"; do
                local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                [[ -n "$node" && "$node" != "null" ]] && \
                    nodes_json_array=$(echo "$nodes_json_array" | jq --argjson node "$node" '. += [$node]')
            done

            local node_count=$(echo "$nodes_json_array" | jq 'length')
            [[ "$node_count" -eq 0 ]] && { print_error "没有可用节点"; return 1; }

            local clash_stderr=$(mktemp)
            sub_content=$(generate_clash_config "$nodes_json_array" "$sub_user_id" "$sub_user_password" 2>"$clash_stderr")

            if [[ $? -ne 0 ]] || [[ -z "$sub_content" ]]; then
                print_error "Clash配置生成失败"
                cat "$clash_stderr" | grep -E "^# (ERROR|WARNING)" | sed 's/^# /  /' >&2
                rm -f "$clash_stderr"
                return 1
            fi
            rm -f "$clash_stderr"
            sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${sub_user_id}_clash.yaml"
            ;;

        singbox)
            # sing-box订阅
            local nodes_json_array="[]"
            for port in "${user_node_ports[@]}"; do
                local node=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
                [[ -n "$node" && "$node" != "null" ]] && \
                    nodes_json_array=$(echo "$nodes_json_array" | jq --argjson node "$node" '. += [$node]')
            done

            local node_count=$(echo "$nodes_json_array" | jq 'length')
            [[ "$node_count" -eq 0 ]] && { print_error "没有可用节点"; return 1; }

            local singbox_stderr=$(mktemp)
            sub_content=$(generate_singbox_subscription_config "$nodes_json_array" "$sub_user_id" "$sub_user_password" 2>"$singbox_stderr")

            if [[ $? -ne 0 ]] || [[ -z "$sub_content" ]]; then
                print_error "sing-box配置生成失败"
                cat "$singbox_stderr" | grep -E "^# (ERROR|WARNING)" | sed 's/^# /  /' >&2
                rm -f "$singbox_stderr"
                return 1
            fi
            rm -f "$singbox_stderr"
            sub_file="${SUBSCRIPTION_DIR}/${sub_name}_${sub_user_id}_singbox.json"
            ;;

        *)
            print_error "未知订阅类型: $sub_type"
            return 1
            ;;
    esac

    # 3. 保存订阅文件
    echo "$sub_content" > "$sub_file"

    # 4. 更新数据库中的URL和时间戳
    local port=$(cat "${DATA_DIR}/subscription_port.txt" 2>/dev/null || echo "8080")
    local server_ip=$(get_subscription_domain_hint)
    [[ -z "$server_ip" ]] && server_ip=$(get_public_ip)
    [[ -z "$server_ip" ]] && server_ip="127.0.0.1"

    local sub_filename=$(basename "$sub_file")
    local sub_url="http://${server_ip}:${port}/sub/${sub_filename}"

    local sub_db="${DATA_DIR}/subscriptions.json"
    jq --arg name "$sub_name" --arg url "$sub_url" --arg file "$sub_file" \
       '(.subscriptions[] | select(.name == $name)) |= (. + {url: $url, file: $file, updated: (now|todate)})' \
       "$sub_db" > "${sub_db}.tmp" && mv "${sub_db}.tmp" "$sub_db"

    return 0
}

#================================================================
# 订阅管理菜单
#================================================================

# 订阅管理主菜单
menu_subscription() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║           订阅管理                   ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}1.${NC}  生成订阅链接"
        echo -e "${GREEN}2.${NC}  查看单个节点链接"
        echo -e "${GREEN}3.${NC}  查看所有订阅"
        echo -e "${GREEN}4.${NC}  查看用户订阅"
        echo -e "${GREEN}5.${NC}  更新订阅"
        echo -e "${GREEN}6.${NC}  删除订阅"
        echo ""
        echo -e "${GREEN}0.${NC}  返回主菜单"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        read -p "请选择 [0-6]: " choice

        case $choice in
            1)
                generate_subscription_with_user
                read -p "按 Enter 键继续..."
                ;;
            2)
                show_node_share_link
                read -p "按 Enter 键继续..."
                ;;
            3)
                list_subscriptions
                read -p "按 Enter 键继续..."
                ;;
            4)
                show_user_subscriptions
                read -p "按 Enter 键继续..."
                ;;
            5)
                update_subscription_menu
                read -p "按 Enter 键继续..."
                ;;
            6)
                delete_subscription_menu
                read -p "按 Enter 键继续..."
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

# 查看所有订阅
list_subscriptions() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           订阅列表                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    local sub_db="${DATA_DIR}/subscriptions.json"
    if [[ ! -f "$sub_db" ]]; then
        print_warning "暂无订阅"
        return 0
    fi

    local sub_count=$(jq -r '.subscriptions | length' "$sub_db" 2>/dev/null)
    if [[ "$sub_count" -eq 0 ]]; then
        print_warning "暂无订阅"
        return 0
    fi

    echo -e "${YELLOW}共有 $sub_count 个订阅：${NC}"
    echo ""

    local index=1
    while IFS= read -r sub; do
        if [[ -z "$sub" || "$sub" == "null" ]]; then
            continue
        fi

        local name=$(echo "$sub" | jq -r '.name // "未命名"')
        local url=$(echo "$sub" | jq -r '.url // "N/A"')
        local type=$(echo "$sub" | jq -r '.type // "N/A"')
        local created=$(echo "$sub" | jq -r '.created // "N/A"')

        echo -e "${CYAN}[$index]${NC} ${YELLOW}$name${NC}"
        echo -e "  类型: ${GREEN}$type${NC}"
        echo -e "  创建时间: $created"
        echo -e "  订阅URL: ${BLUE}$url${NC}"
        echo ""

        ((index++))
    done < <(jq -c '.subscriptions[]' "$sub_db" 2>/dev/null)
}

# 删除订阅
delete_subscription() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           删除订阅                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    local sub_db="${DATA_DIR}/subscriptions.json"
    if [[ ! -f "$sub_db" ]]; then
        print_warning "暂无订阅"
        return 0
    fi

    local sub_count=$(jq -r '.subscriptions | length' "$sub_db" 2>/dev/null)
    if [[ "$sub_count" -eq 0 ]]; then
        print_warning "暂无订阅"
        return 0
    fi

    # 显示订阅列表
    echo -e "${YELLOW}订阅列表：${NC}"
    echo ""

    local index=1
    while IFS= read -r sub; do
        if [[ -z "$sub" || "$sub" == "null" ]]; then
            continue
        fi

        local name=$(echo "$sub" | jq -r '.name // "未命名"')
        local type=$(echo "$sub" | jq -r '.type // "N/A"')

        printf "${CYAN}[%d]${NC} ${YELLOW}%-30s${NC} (类型: %s)\n" "$index" "$name" "$type"
        ((index++))
    done < <(jq -c '.subscriptions[]' "$sub_db" 2>/dev/null)

    echo ""
    read -p "请输入订阅序号 (0取消): " sub_index

    if [[ "$sub_index" == "0" ]]; then
        print_info "取消删除"
        return 0
    fi

    # 验证输入
    if [[ ! "$sub_index" =~ ^[0-9]+$ ]] || [[ "$sub_index" -lt 1 ]] || [[ "$sub_index" -gt "$((index-1))" ]]; then
        print_error "无效的序号"
        return 1
    fi

    # 获取订阅信息
    local sub=$(jq -c ".subscriptions[$((sub_index-1))]" "$sub_db" 2>/dev/null)
    if [[ -z "$sub" || "$sub" == "null" ]]; then
        print_error "订阅不存在"
        return 1
    fi

    local name=$(echo "$sub" | jq -r '.name // "未命名"')
    local file=$(echo "$sub" | jq -r '.file // ""')

    echo ""
    read -p "确认删除订阅 '$name'? [y/N]: " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消删除"
        return 0
    fi

    # 删除订阅文件
    if [[ -n "$file" && -f "$file" ]]; then
        rm -f "$file"
        print_success "已删除订阅文件: $file"
    fi

    # 从数据库删除
    jq ".subscriptions |= del(.[$((sub_index-1))])" "$sub_db" > "${sub_db}.tmp"
    mv "${sub_db}.tmp" "$sub_db"

    # 删除元数据
    delete_subscription_metadata "$name"

    print_success "订阅 '$name' 已删除"
}

#================================================================
# 新增订阅管理功能
#================================================================

# 查看单个用户的所有订阅
show_user_subscriptions() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        查看用户订阅链接              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -f "$USERS_FILE" ]]; then
        print_error "暂无用户"
        return 1
    fi

    local user_count=$(jq -r '.users | length' "$USERS_FILE" 2>/dev/null)
    if [[ "$user_count" -eq 0 ]]; then
        print_error "暂无用户"
        return 1
    fi

    # 显示用户列表
    echo -e "${YELLOW}用户列表：${NC}"
    echo ""

    local index=1
    while IFS= read -r user; do
        if [[ -z "$user" || "$user" == "null" ]]; then
            continue
        fi

        local uid=$(echo "$user" | jq -r '.id')
        local uname=$(echo "$user" | jq -r '.username')
        local uemail=$(echo "$user" | jq -r '.email // "无邮箱"')

        printf "${CYAN}[%d]${NC} ${YELLOW}%-20s${NC} (%s)\n" "$index" "$uname" "$uemail"
        ((index++))
    done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

    echo ""
    read -p "请输入用户序号 (0取消): " user_index

    if [[ "$user_index" == "0" ]]; then
        return 0
    fi

    # 验证输入
    if [[ ! "$user_index" =~ ^[0-9]+$ ]] || [[ "$user_index" -lt 1 ]] || [[ "$user_index" -gt "$((index-1))" ]]; then
        print_error "无效的序号"
        return 1
    fi

    # 获取用户信息
    local user=$(jq -c ".users[$((user_index-1))]" "$USERS_FILE" 2>/dev/null)
    if [[ -z "$user" || "$user" == "null" ]]; then
        print_error "用户不存在"
        return 1
    fi

    local user_id=$(echo "$user" | jq -r '.id')
    local username=$(echo "$user" | jq -r '.username')

    echo ""
    echo -e "${CYAN}用户：${NC} ${YELLOW}$username${NC}"
    echo ""

    # 从元数据中查找该用户的订阅
    if [[ ! -f "$SUBSCRIPTION_META_FILE" ]]; then
        print_warning "该用户没有订阅"
        return 0
    fi

    local user_subs=$(jq -c ".subscriptions[] | select(.user_id == \"$user_id\")" "$SUBSCRIPTION_META_FILE" 2>/dev/null)

    if [[ -z "$user_subs" ]]; then
        print_warning "该用户没有订阅"
        return 0
    fi

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}订阅链接：${NC}"
    echo ""

    local link_count=0
    while IFS= read -r sub; do
        if [[ -z "$sub" ]]; then
            continue
        fi

        ((link_count++))
        local sub_name=$(echo "$sub" | jq -r '.name')
        local sub_type=$(echo "$sub" | jq -r '.type')
        local sub_url=$(echo "$sub" | jq -r '.url // "N/A"')

        echo -e "${YELLOW}[$link_count] $sub_name${NC} (${CYAN}$sub_type${NC})"
        echo -e "    ${GREEN}$sub_url${NC}"
        echo ""
    done <<< "$user_subs"

    if [[ $link_count -eq 0 ]]; then
        print_warning "未找到订阅"
    else
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        print_success "共 $link_count 个订阅"
    fi
}

# 更新订阅菜单
update_subscription_menu() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           更新订阅                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${YELLOW}请选择更新方式：${NC}"
    echo -e "${GREEN}1.${NC} 更新单个用户的所有订阅"
    echo -e "${GREEN}2.${NC} 更新所有用户的所有订阅"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-2]: " choice

    case $choice in
        1)
            # 更新单个用户
            if [[ ! -f "$USERS_FILE" ]]; then
                print_error "暂无用户"
                return 1
            fi

            local user_count=$(jq -r '.users | length' "$USERS_FILE" 2>/dev/null)
            if [[ "$user_count" -eq 0 ]]; then
                print_error "暂无用户"
                return 1
            fi

            # 显示用户列表
            echo ""
            echo -e "${YELLOW}用户列表：${NC}"
            echo ""

            local index=1
            while IFS= read -r user; do
                if [[ -z "$user" || "$user" == "null" ]]; then
                    continue
                fi

                local uid=$(echo "$user" | jq -r '.id')
                local uname=$(echo "$user" | jq -r '.username')
                local uemail=$(echo "$user" | jq -r '.email // "无邮箱"')

                printf "${CYAN}[%d]${NC} ${YELLOW}%-20s${NC} (%s)\n" "$index" "$uname" "$uemail"
                ((index++))
            done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

            echo ""
            read -p "请输入用户序号 (0取消): " user_index

            if [[ "$user_index" == "0" ]]; then
                return 0
            fi

            # 验证输入
            if [[ ! "$user_index" =~ ^[0-9]+$ ]] || [[ "$user_index" -lt 1 ]] || [[ "$user_index" -gt "$((index-1))" ]]; then
                print_error "无效的序号"
                return 1
            fi

            # 获取用户信息
            local user=$(jq -c ".users[$((user_index-1))]" "$USERS_FILE" 2>/dev/null)
            if [[ -z "$user" || "$user" == "null" ]]; then
                print_error "用户不存在"
                return 1
            fi

            local user_id=$(echo "$user" | jq -r '.id')
            local username=$(echo "$user" | jq -r '.username')

            echo ""
            print_info "正在更新用户 $username 的订阅..."
            echo ""

            update_user_subscriptions "$user_id"
            ;;
        2)
            # 更新所有用户
            echo ""
            read -p "确认更新所有用户的订阅? [y/N]: " confirm

            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                print_info "取消更新"
                return 0
            fi

            print_info "正在更新所有用户的订阅..."
            echo ""

            local total_users=0
            local updated_users=0

            while IFS= read -r user; do
                if [[ -z "$user" || "$user" == "null" ]]; then
                    continue
                fi

                ((total_users++))
                local user_id=$(echo "$user" | jq -r '.id')
                local username=$(echo "$user" | jq -r '.username')

                echo -e "${CYAN}[用户 $total_users]${NC} $username"

                if update_user_subscriptions "$user_id"; then
                    ((updated_users++))
                fi
                echo ""
            done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            print_success "更新完成！共更新 $updated_users/$total_users 个用户的订阅"
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac
}

# 增强的删除订阅菜单
delete_subscription_menu() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           删除订阅                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${YELLOW}请选择删除方式：${NC}"
    echo -e "${GREEN}1.${NC} 删除单个订阅（按序号）"
    echo -e "${GREEN}2.${NC} 删除用户的所有订阅"
    echo -e "${GREEN}3.${NC} 删除所有订阅"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-3]: " choice

    case $choice in
        1)
            # 删除单个订阅（调用原有函数）
            delete_subscription
            ;;
        2)
            # 删除用户的所有订阅
            if [[ ! -f "$USERS_FILE" ]]; then
                print_error "暂无用户"
                return 1
            fi

            local user_count=$(jq -r '.users | length' "$USERS_FILE" 2>/dev/null)
            if [[ "$user_count" -eq 0 ]]; then
                print_error "暂无用户"
                return 1
            fi

            # 显示用户列表
            echo ""
            echo -e "${YELLOW}用户列表：${NC}"
            echo ""

            local index=1
            while IFS= read -r user; do
                if [[ -z "$user" || "$user" == "null" ]]; then
                    continue
                fi

                local uid=$(echo "$user" | jq -r '.id')
                local uname=$(echo "$user" | jq -r '.username')
                local uemail=$(echo "$user" | jq -r '.email // "无邮箱"')

                printf "${CYAN}[%d]${NC} ${YELLOW}%-20s${NC} (%s)\n" "$index" "$uname" "$uemail"
                ((index++))
            done < <(jq -c '.users[]' "$USERS_FILE" 2>/dev/null)

            echo ""
            read -p "请输入用户序号 (0取消): " user_index

            if [[ "$user_index" == "0" ]]; then
                return 0
            fi

            # 验证输入
            if [[ ! "$user_index" =~ ^[0-9]+$ ]] || [[ "$user_index" -lt 1 ]] || [[ "$user_index" -gt "$((index-1))" ]]; then
                print_error "无效的序号"
                return 1
            fi

            # 获取用户信息
            local user=$(jq -c ".users[$((user_index-1))]" "$USERS_FILE" 2>/dev/null)
            if [[ -z "$user" || "$user" == "null" ]]; then
                print_error "用户不存在"
                return 1
            fi

            local user_id=$(echo "$user" | jq -r '.id')
            local username=$(echo "$user" | jq -r '.username')

            echo ""
            read -p "确认删除用户 $username 的所有订阅? [y/N]: " confirm

            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                print_info "取消删除"
                return 0
            fi

            # 删除该用户的所有订阅
            local deleted_count=0
            local sub_db="${DATA_DIR}/subscriptions.json"

            if [[ -f "$sub_db" ]]; then
                # 获取该用户的所有订阅名称
                local user_sub_names=()
                if [[ -f "$SUBSCRIPTION_META_FILE" ]]; then
                    while IFS= read -r sub_name; do
                        [[ -n "$sub_name" && "$sub_name" != "null" ]] && user_sub_names+=("$sub_name")
                    done < <(jq -r ".subscriptions[] | select(.user_id == \"$user_id\") | .name" "$SUBSCRIPTION_META_FILE" 2>/dev/null)
                fi

                for sub_name in "${user_sub_names[@]}"; do
                    # 删除订阅文件
                    local sub_file=$(jq -r ".subscriptions[] | select(.name == \"$sub_name\") | .file" "$sub_db" 2>/dev/null)
                    if [[ -n "$sub_file" && -f "$sub_file" ]]; then
                        rm -f "$sub_file"
                    fi

                    # 从数据库删除
                    jq ".subscriptions |= map(select(.name != \"$sub_name\"))" "$sub_db" > "${sub_db}.tmp"
                    mv "${sub_db}.tmp" "$sub_db"

                    # 删除元数据
                    delete_subscription_metadata "$sub_name"

                    ((deleted_count++))
                done
            fi

            echo ""
            print_success "已删除用户 $username 的 $deleted_count 个订阅"
            ;;
        3)
            # 删除所有订阅
            local sub_db="${DATA_DIR}/subscriptions.json"
            if [[ ! -f "$sub_db" ]]; then
                print_warning "暂无订阅"
                return 0
            fi

            local sub_count=$(jq -r '.subscriptions | length' "$sub_db" 2>/dev/null)
            if [[ "$sub_count" -eq 0 ]]; then
                print_warning "暂无订阅"
                return 0
            fi

            echo ""
            echo -e "${RED}警告：此操作将删除所有 $sub_count 个订阅！${NC}"
            echo ""
            read -p "确认删除所有订阅? [y/N]: " confirm

            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                print_info "取消删除"
                return 0
            fi

            # 删除所有订阅文件
            while IFS= read -r sub_file; do
                [[ -n "$sub_file" && -f "$sub_file" ]] && rm -f "$sub_file"
            done < <(jq -r '.subscriptions[].file' "$sub_db" 2>/dev/null)

            # 清空数据库
            echo '{"subscriptions":[]}' > "$sub_db"

            # 清空元数据
            if [[ -f "$SUBSCRIPTION_META_FILE" ]]; then
                echo '{"subscriptions":[]}' > "$SUBSCRIPTION_META_FILE"
            fi

            echo ""
            print_success "已删除所有 $sub_count 个订阅"
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac
}
