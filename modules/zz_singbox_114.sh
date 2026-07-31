#!/bin/bash

# sing-box 1.13.15 stable compatibility layer.
# The legacy filename is retained to preserve module load order and upgrade compatibility.

SINGBOX_API_ADDR="${SINGBOX_API_ADDR:-127.0.0.1:10085}"
TRAFFIC_COUNTERS_FILE="${TRAFFIC_COUNTERS_FILE:-${DATA_DIR}/traffic_counters.json}"
SINGBOX_BUILD_DIR="${SINGBOX_BUILD_DIR:-${DATA_DIR}/build}"
SINGBOX_GO_DIR="${SINGBOX_GO_DIR:-${DATA_DIR}/toolchains/go}"
RUNTIME_STATE_DIR="${RUNTIME_STATE_DIR:-${DATA_DIR}/.last-known-good}"
RUNTIME_TX_DIR="${RUNTIME_TX_DIR:-${DATA_DIR}/.pending-transaction}"
MANAGER_SCRIPT="${MANAGER_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/singbox-manager.sh}"

get_singbox_bin() {
    if [[ -n "${SINGBOX_BIN:-}" && -x "${SINGBOX_BIN}" ]]; then
        printf '%s\n' "$SINGBOX_BIN"
    elif [[ -x "/usr/local/bin/sing-box" ]]; then
        printf '%s\n' "/usr/local/bin/sing-box"
    elif command -v sing-box >/dev/null 2>&1; then
        command -v sing-box
    else
        printf '%s\n' "/usr/local/bin/sing-box"
    fi
}

get_singbox_version_number() {
    local bin version
    bin=$(get_singbox_bin)
    [[ -x "$bin" ]] || return 1
    version=$("$bin" version 2>/dev/null | sed -n 's/^sing-box version[[:space:]]\+v\?\([^[:space:]]\+\).*/\1/p' | head -1)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    echo "$version"
}

singbox_version_at_least() {
    local minimum="$1" current
    current=$(get_singbox_version_number) || return 1
    version_ge "$current" "$minimum"
}

singbox_supports_snell_inbound() {
    singbox_version_at_least 1.14.0
}

warn_if_stats_capability_missing() {
    local bin
    bin=$(get_singbox_bin)
    [[ -x "$bin" ]] || return 0
    if ! "$bin" version 2>/dev/null | grep -q 'with_v2ray_api'; then
        print_warning "当前为官方普通 sing-box 内核：节点创建与代理功能正常"
        print_info "用户流量统计、流量限额和最近活跃状态不可用；可在内核管理中手动安装定制内核"
        return 1
    fi
}

singbox_has_build_tag() {
    local tag=$1 bin
    bin=$(get_singbox_bin)
    [[ "$tag" =~ ^[A-Za-z0-9_.-]+$ && -x "$bin" ]] || return 1
    "$bin" version 2>/dev/null | grep -Eq "(^|[ ,])${tag}([ ,]|$)"
}

singbox_has_stats_capability() {
    singbox_has_build_tag with_v2ray_api
}

ensure_singbox_stats_capability() {
    [[ "${SINGBOX_SKIP_KERNEL_PREFLIGHT:-0}" == "1" ]] && return 0
    singbox_has_stats_capability && return 0

    local bin answer="" version start_after_install=true
    bin=$(get_singbox_bin)
    if [[ -x "$bin" ]]; then
        print_warning "检测到普通 sing-box 内核，缺少 with_v2ray_api 流量统计能力"
    else
        print_warning "尚未安装 sing-box 定制内核"
    fi

    case "${SINGBOX_AUTO_REPAIR_STATS_KERNEL:-prompt}" in
        1|yes|true) answer="y" ;;
        0|no|false) answer="n" ;;
        *)
            if [[ -t 0 ]]; then
                echo -e "${YELLOW}脚本将从官方源码构建带 with_v2ray_api 的内核，首次执行可能需要数分钟。${NC}"
                read -r -p "是否立即安装/修复定制内核并继续? [Y/n]: " answer
                answer=${answer:-y}
            else
                print_error "非交互任务无法自动确认内核安装"
                print_info "请运行 s-singbox，进入【sing-box 管理 → 更新/修复定制内核】"
                return 1
            fi
            ;;
    esac

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        print_error "当前配置需要带 with_v2ray_api 的 sing-box 定制内核"
        print_info "可进入【sing-box 管理 → 更新/修复定制内核】后重试"
        return 1
    fi

    version=$(resolve_singbox_version stable) || {
        print_error "无法解析最新 sing-box 稳定版本"
        return 1
    }
    print_info "正在自动修复 sing-box 定制内核（目标版本: v${version}）..."
    [[ -f "$SINGBOX_CONFIG" ]] || start_after_install=false
    build_and_install_singbox "$version" "$start_after_install" || return 1
    if ! singbox_has_stats_capability; then
        print_error "定制内核安装后能力校验仍未通过"
        return 1
    fi
    print_success "with_v2ray_api 能力已就绪，继续原操作"
}

atomic_write_json() {
    local target=$1
    local content=$2
    local tmp
    mkdir -p "$(dirname "$target")" || return 1
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$content" | jq . > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$target"
}

ss_key_length() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) echo 32 ;;
        *) echo 0 ;;
    esac
}

effective_ss_method() {
    local method=$1
    if [[ "$method" == 2022-* ]]; then echo "$method"; else echo "2022-blake3-aes-128-gcm"; fi
}

migrate_shadowsocks_nodes_114() {
    local data node index method length master changed=false
    data=$(cat "$NODES_FILE") || return 1
    while IFS= read -r index; do
        node=$(echo "$data" | jq -c --argjson i "$index" '.nodes[$i]') || return 1
        method=$(effective_ss_method "$(echo "$node" | jq -r '.extra.method // .extra.cipher // "2022-blake3-aes-128-gcm"')")
        master=$(echo "$node" | jq -r '.extra.master_password // ""')
        if [[ -z "$master" ]]; then
            length=$(ss_key_length "$method")
            master=$(openssl rand -base64 "$length" | tr -d '\r\n') || return 1
        fi
        data=$(echo "$data" | jq --argjson i "$index" --arg method "$method" --arg master "$master" '.nodes[$i].extra = ((.nodes[$i].extra // {}) + {method:$method,master_password:$master} | del(.cipher))') || return 1
        changed=true
    done < <(echo "$data" | jq -r '.nodes | to_entries[] | select(.value.protocol=="shadowsocks") | .key')
    [[ "$changed" == false ]] || atomic_write_json "$NODES_FILE" "$data"
}

derive_ss2022_key() {
    local seed=$1
    local method=$2
    local length
    length=$(ss_key_length "$method")
    [[ "$length" -gt 0 ]] || return 1
    printf '%s' "$seed" | openssl dgst -sha256 -binary | head -c "$length" | base64 | tr -d '\r\n'
}

node_tls_insecure() {
    local extra=$1
    local explicit cert subject issuer
    explicit=$(echo "$extra" | jq -r '.tls_insecure // empty')
    if [[ "$explicit" == "true" || "$explicit" == "false" ]]; then
        echo "$explicit"
        return
    fi
    cert=$(echo "$extra" | jq -r '.tls_cert // ""')
    if [[ -f "$cert" ]] && command -v openssl >/dev/null 2>&1; then
        subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed -E 's/^subject[= ]*//; s/[[:space:]]//g')
        issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed -E 's/^issuer[= ]*//; s/[[:space:]]//g')
        if [[ -n "$subject" && "$subject" == "$issuer" ]]; then
            echo true
            return
        fi
    fi
    echo false
}

split_host_port() {
    local endpoint=$1 default_port=${2:-443}
    if [[ "$endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$endpoint" =~ ^([^:]+):([0-9]+)$ ]]; then
        printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        endpoint=${endpoint#\[}
        endpoint=${endpoint%\]}
        printf '%s|%s\n' "$endpoint" "$default_port"
    fi
}

format_uri_host() {
    local host=$1
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]\n' "$host"
    else
        printf '%s\n' "$host"
    fi
}

urlencode() {
    printf '%s' "$1" | jq -sRr @uri
}

generate_114_tls_server() {
    local security=$1
    local extra=$2
    if [[ "$security" == "reality" ]]; then
        local server server_port private_key short_id server_name endpoint parsed
        endpoint=$(echo "$extra" | jq -r '.dest // .handshake_server // ""')
        parsed=$(split_host_port "$endpoint" 443)
        server=${parsed%|*}
        server_port=${parsed##*|}
        private_key=$(echo "$extra" | jq -r '.private_key // ""')
        short_id=$(echo "$extra" | jq -r '.short_ids[0] // .short_id // ""')
        server_name=$(echo "$extra" | jq -r '.server_names[0] // .tls_domain // ""')
        [[ -n "$server" && -n "$private_key" && -n "$server_name" ]] || {
            print_error "Reality 缺少 dest/private_key/server_names"
            return 1
        }
        jq -n --arg sn "$server_name" --arg server "$server" --argjson port "$server_port" \
            --arg key "$private_key" --arg sid "$short_id" \
            '{enabled:true,server_name:$sn,reality:{enabled:true,handshake:{server:$server,server_port:$port},private_key:$key,short_id:[$sid]}}'
        return
    fi

    local cert key domain
    cert=$(echo "$extra" | jq -r '.tls_cert // .cert_file // ""')
    key=$(echo "$extra" | jq -r '.tls_key // .key_file // ""')
    domain=$(echo "$extra" | jq -r '.tls_domain // ""')
    [[ -n "$cert" && -n "$key" && -f "$cert" && -f "$key" ]] || {
        print_error "TLS 证书或密钥不存在: $cert / $key"
        return 1
    }
    jq -n --arg cert "$cert" --arg key "$key" --arg domain "$domain" \
        '{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}'
}

generate_114_transport() {
    local transport=$1
    local extra=$2
    case "$transport" in
        ""|tcp) echo '{}' ;;
        ws) jq -n --arg path "$(echo "$extra" | jq -r '.ws_path // "/"')" \
            --arg host "$(echo "$extra" | jq -r '.ws_host // ""')" \
            '{type:"ws",path:$path} + (if $host != "" then {headers:{Host:$host}} else {} end)' ;;
        grpc) jq -n --arg service "$(echo "$extra" | jq -r '.grpc_service // .service_name // "grpc"')" \
            '{type:"grpc",service_name:$service}' ;;
        h2|http) jq -n --arg path "$(echo "$extra" | jq -r '.http_path // "/"')" \
            --arg host "$(echo "$extra" | jq -r '.http_host // ""')" \
            '{type:"http",path:$path} + (if $host != "" then {host:[$host]} else {} end)' ;;
        *) print_error "不支持的传输层: $transport"; return 1 ;;
    esac
}

build_114_users() {
    local protocol=$1
    local security=$2
    local extra=$3
    local ids=$4
    local users='[]' id user username password item method key expire limit used alter_id
    method=$(effective_ss_method "$(echo "$extra" | jq -r '.method // .cipher // "2022-blake3-aes-128-gcm"')")
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        user=$(jq -c --arg id "$id" '.users[] | select(.id == $id and (.enabled // true) == true)' "$USERS_FILE" 2>/dev/null | head -1)
        [[ -n "$user" ]] || continue
        expire=$(echo "$user" | jq -r '.expire_date // "unlimited"')
        [[ "$expire" == unlimited || "$expire" > "$(date +%Y-%m-%d)" ]] || continue
        limit=$(echo "$user" | jq -r '.traffic_limit_gb // "unlimited"'); used=$(echo "$user" | jq -r '.traffic_used_gb // 0')
        if singbox_has_stats_capability && [[ "$limit" != unlimited ]] \
            && awk -v used="$used" -v limit="$limit" 'BEGIN {exit !(used >= limit)}'; then
            continue
        fi
        username=$(echo "$user" | jq -r '.username // .id')
        password=$(echo "$user" | jq -r '.password // ""')
        case "$protocol" in
            vless)
                if [[ "$security" == "reality" ]]; then
                    item=$(jq -n --arg name "$username" --arg uuid "$id" '{name:$name,uuid:$uuid,flow:"xtls-rprx-vision"}')
                else
                    item=$(jq -n --arg name "$username" --arg uuid "$id" '{name:$name,uuid:$uuid}')
                fi ;;
            vmess)
                alter_id=$(echo "$extra" | jq -r '.alter_id // 0')
                [[ "$alter_id" =~ ^[0-9]+$ && "$alter_id" -le 65535 ]] || return 1
                item=$(jq -n --arg name "$username" --arg uuid "$id" --argjson alter_id "$alter_id" '{name:$name,uuid:$uuid,alterId:$alter_id}') ;;
            trojan|hysteria2|anytls|shadowtls) item=$(jq -n --arg name "$username" --arg password "$password" '{name:$name,password:$password}') ;;
            hysteria) item=$(jq -n --arg name "$username" --arg auth_str "$password" '{name:$name,auth_str:$auth_str}') ;;
            snell) item=$(jq -n --arg name "$username" --arg userkey "$password" '{name:$name,userkey:$userkey}') ;;
            tuic) item=$(jq -n --arg name "$username" --arg uuid "$id" --arg password "$password" '{name:$name,uuid:$uuid,password:$password}') ;;
            naive|http|socks|mixed) item=$(jq -n --arg username "$username" --arg password "$password" '{username:$username,password:$password}') ;;
            shadowsocks)
                if [[ "$method" == 2022-* ]]; then
                    key=$(derive_ss2022_key "${id}:${password}" "$method") || return 1
                    item=$(jq -n --arg name "$username" --arg password "$key" '{name:$name,password:$password}')
                else
                    item=$(jq -n --arg name "$username" --arg password "$password" '{name:$name,password:$password}')
                fi ;;
            *) return 1 ;;
        esac
        users=$(echo "$users" | jq --argjson item "$item" '. + [$item]') || return 1
    done <<< "$ids"
    echo "$users"
}

generate_114_inbound() {
    local node=$1 users=$2
    local protocol port transport security extra base tls trans method master obfs padding fallback_server fallback_port masquerade psk version handshake_server handshake_port mode
    protocol=$(echo "$node" | jq -r '.protocol')
    port=$(echo "$node" | jq -r '.port | tonumber')
    transport=$(echo "$node" | jq -r '.transport // "tcp"')
    security=$(echo "$node" | jq -r '.security // "none"')
    extra=$(echo "$node" | jq -c '.extra // {}')
    base=$(jq -n --arg type "$protocol" --arg tag "${protocol}-${port}" --argjson port "$port" --argjson users "$users" \
        '{type:$type,tag:$tag,listen:"0.0.0.0",listen_port:$port,users:$users}') || return 1

    case "$protocol" in
        vless|vmess|trojan)
            if [[ "$protocol" == "trojan" || "$security" == "tls" || "$security" == "reality" ]]; then
                tls=$(generate_114_tls_server "$security" "$extra") || return 1
                base=$(echo "$base" | jq --argjson tls "$tls" '.tls=$tls') || return 1
            fi
            if [[ "$protocol" == "trojan" ]]; then
                fallback_server=$(echo "$extra" | jq -r '.fallback_dest // ""')
                fallback_port=$(echo "$extra" | jq -r '.fallback_port // ""')
                if [[ -n "$fallback_server" ]]; then
                    [[ "$fallback_port" =~ ^[0-9]+$ && "$fallback_port" -ge 1 && "$fallback_port" -le 65535 ]] || {
                        print_error "Trojan 回落端口无效: $fallback_port"
                        return 1
                    }
                    base=$(echo "$base" | jq --arg server "$fallback_server" --argjson port "$fallback_port" '.fallback={server:$server,server_port:$port}') || return 1
                fi
            fi
            if [[ "$transport" != "tcp" && -n "$transport" ]]; then
                trans=$(generate_114_transport "$transport" "$extra") || return 1
                base=$(echo "$base" | jq --argjson t "$trans" '.transport=$t') || return 1
            fi ;;
        shadowsocks)
            method=$(effective_ss_method "$(echo "$extra" | jq -r '.method // .cipher // "2022-blake3-aes-128-gcm"')")
            master=$(echo "$extra" | jq -r '.master_password // ""')
            [[ "$method" != 2022-* || -n "$master" ]] || { print_error "Shadowsocks 2022 主密钥缺失"; return 1; }
            base=$(echo "$base" | jq --arg method "$method" --arg password "$master" '.method=$method | .password=$password') ;;
        hysteria2)
            tls=$(generate_114_tls_server tls "$extra") || return 1
            base=$(echo "$base" | jq --argjson tls "$tls" '.tls=$tls')
            obfs=$(echo "$extra" | jq -r '.obfs_password // ""')
            [[ -n "$obfs" ]] && base=$(echo "$base" | jq --arg p "$obfs" '.obfs={type:"salamander",password:$p}')
            masquerade=$(echo "$extra" | jq -r '.masquerade // ""')
            [[ -n "$masquerade" ]] && base=$(echo "$base" | jq --arg value "$masquerade" '.masquerade=$value')
            base=$(echo "$base" | jq --argjson up "$(echo "$extra" | jq -r '.up_mbps // 0')" --argjson down "$(echo "$extra" | jq -r '.down_mbps // 0')" \
                'if $up > 0 then .up_mbps=$up else . end | if $down > 0 then .down_mbps=$down else . end') ;;
        hysteria)
            tls=$(generate_114_tls_server tls "$extra") || return 1
            base=$(echo "$base" | jq --argjson tls "$tls" '.tls=$tls')
            base=$(echo "$base" | jq --argjson up "$(echo "$extra" | jq -r '.up_mbps // 0')" --argjson down "$(echo "$extra" | jq -r '.down_mbps // 0')" \
                'if $up > 0 and $down > 0 then .up_mbps=$up | .down_mbps=$down else error("Hysteria up/down required") end') || return 1
            obfs=$(echo "$extra" | jq -r '.obfs // ""')
            [[ -z "$obfs" ]] || base=$(echo "$base" | jq --arg obfs "$obfs" '.obfs=$obfs') ;;
        shadowtls)
            version=$(echo "$extra" | jq -r '.version // 3')
            [[ "$version" == "3" ]] || { print_error "仅支持 ShadowTLS v3 多用户入站"; return 1; }
            handshake_server=$(echo "$extra" | jq -r '.handshake_server // ""')
            handshake_port=$(echo "$extra" | jq -r '.handshake_port // 443')
            [[ -n "$handshake_server" && "$handshake_port" =~ ^[0-9]+$ && "$handshake_port" -ge 1 && "$handshake_port" -le 65535 ]] || {
                print_error "ShadowTLS 握手服务器配置无效"; return 1;
            }
            base=$(echo "$base" | jq --argjson version "$version" --arg server "$handshake_server" --argjson server_port "$handshake_port" \
                --argjson strict "$(echo "$extra" | jq -r '.strict_mode // true')" --arg wildcard "$(echo "$extra" | jq -r '.wildcard_sni // "off"')" \
                '.version=$version | .handshake={server:$server,server_port:$server_port} | .strict_mode=$strict | if $wildcard != "off" then .wildcard_sni=$wildcard else . end') || return 1 ;;
        snell)
            if ! singbox_supports_snell_inbound; then
                print_error "Snell 入站需要 sing-box 1.14.0 或更高版本；当前内核不支持"
                return 1
            fi
            version=$(echo "$extra" | jq -r '.version // 5')
            psk=$(echo "$extra" | jq -r '.psk // ""')
            [[ "$version" == "5" || "$version" == "6" ]] || { print_error "Snell 入站版本必须为 5 或 6"; return 1; }
            [[ -n "$psk" ]] || { print_error "Snell PSK 不能为空"; return 1; }
            if [[ "$version" == "6" && ( ${#psk} -lt 12 || ${#psk} -gt 255 ) ]]; then
                print_error "Snell v6 PSK 长度必须为 12-255 字节"; return 1
            fi
            base=$(echo "$base" | jq --argjson version "$version" --arg psk "$psk" '.version=$version | .psk=$psk') || return 1
            if [[ "$version" == "5" ]]; then
                mode=$(echo "$extra" | jq -r '.obfs_mode // "none"')
                [[ "$mode" == "none" || "$mode" == "http" ]] || return 1
                base=$(echo "$base" | jq --arg mode "$mode" '.obfs_mode=$mode')
            else
                mode=$(echo "$extra" | jq -r '.mode // "default"')
                [[ "$mode" == "default" || "$mode" == "unshaped" || "$mode" == "unsafe-raw" ]] || return 1
                base=$(echo "$base" | jq --arg mode "$mode" '.mode=$mode')
            fi ;;
        tuic)
            tls=$(generate_114_tls_server tls "$extra") || return 1
            tls=$(echo "$tls" | jq '.alpn=["h3"]') || return 1
            base=$(echo "$base" | jq --argjson tls "$tls" --arg cc "$(echo "$extra" | jq -r '.congestion_control // "cubic"')" \
                --argjson zrtt "$(echo "$extra" | jq -r '.zero_rtt_handshake // false')" \
                '.tls=$tls | .congestion_control=$cc | .auth_timeout="3s" | .zero_rtt_handshake=$zrtt | .heartbeat="10s"') ;;
        naive)
            tls=$(generate_114_tls_server tls "$extra") || return 1
            base=$(echo "$base" | jq --argjson tls "$tls" --arg cc "$(echo "$extra" | jq -r '.quic_congestion_control // "bbr"')" '.tls=$tls | .quic_congestion_control=$cc') ;;
        anytls)
            tls=$(generate_114_tls_server tls "$extra") || return 1
            padding=$(echo "$extra" | jq -c '.padding_scheme // empty')
            base=$(echo "$base" | jq --argjson tls "$tls" '.tls=$tls')
            [[ -n "$padding" ]] && base=$(echo "$base" | jq --argjson p "$padding" '.padding_scheme=$p') ;;
        http)
            [[ "$security" == "tls" ]] && { tls=$(generate_114_tls_server tls "$extra") || return 1; base=$(echo "$base" | jq --argjson tls "$tls" '.tls=$tls'); } ;;
        socks|mixed) : ;;
        *) print_error "未实现的入站协议: $protocol"; return 1 ;;
    esac
    echo "$base"
}

_generate_singbox_config_114() (
    local lock_file="${DATA_DIR}/config.lock" lock_fd nodes users_file bindings outbounds_file
    mkdir -p "$DATA_DIR" "$(dirname "$SINGBOX_CONFIG")" || return 1
    exec {lock_fd}>"$lock_file" || return 1
    command -v flock >/dev/null 2>&1 && flock -x "$lock_fd"
    users_file="$USERS_FILE"; bindings="$NODE_USERS_FILE"; outbounds_file="${DATA_DIR}/outbounds.json"
    [[ -f "$NODES_FILE" ]] || atomic_write_json "$NODES_FILE" '{"nodes":[]}'
    [[ -f "$users_file" ]] || atomic_write_json "$users_file" '{"users":[]}'
    [[ -f "$bindings" ]] || atomic_write_json "$bindings" '{"bindings":[]}'
    [[ -f "$outbounds_file" ]] || atomic_write_json "$outbounds_file" '{"outbounds":[],"endpoints":[]}'
    migrate_shadowsocks_nodes_114 || return 1
    migrate_outbounds_114 "$outbounds_file" || return 1

    local inbounds='[]' node port protocol ids inbound active_names inbound_tags used_tags resolved_tags custom_outbounds='[]' custom_endpoints='[]'
    while IFS= read -r node; do
        [[ "$(echo "$node" | jq -r '.enabled // true')" == "true" ]] || continue
        port=$(echo "$node" | jq -r '.port // empty')
        protocol=$(echo "$node" | jq -r '.protocol // empty')
        [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || { print_error "节点端口无效: $protocol/$port"; return 1; }
        ids=$(jq -r --arg port "$port" '.bindings[] | select((.port|tostring) == $port) | .users[]?' "$bindings")
        users=$(build_114_users "$protocol" "$(echo "$node" | jq -r '.security // "none"')" "$(echo "$node" | jq -c '.extra // {}')" "$ids") || return 1
        if [[ $(echo "$users" | jq length) -eq 0 ]]; then
            print_warning "节点 $protocol/$port 没有启用的认证用户，已安全停用该入站"
            continue
        fi
        inbound=$(generate_114_inbound "$node" "$users") || return 1
        inbounds=$(echo "$inbounds" | jq --argjson v "$inbound" '. + [$v]') || return 1
    done < <(jq -c '.nodes[]' "$NODES_FILE")

    inbound_tags=$(echo "$inbounds" | jq -c '[.[].tag]')
    active_names=$(echo "$inbounds" | jq -c '[.[].users[]? | (.name // .username)] | unique')
    used_tags=$(jq -c '[.nodes[].outbound_tag? | select(. != null and . != "")] | unique' "$NODES_FILE")
    if ! jq -e '((.outbounds // []) + (.endpoints // [])) | group_by(.tag) | all(length == 1)' "$outbounds_file" >/dev/null; then
        print_error "出站库存在重复标签（outbounds/endpoints 标签必须全局唯一）"
        return 1
    fi
    resolved_tags=$(jq -c --argjson roots "$used_tags" '
      def closure($tags):
        ([.outbounds[]? | select(.tag as $tag | $tags | index($tag)) | ((.outbounds[]?), .detour?) | select(. != null and . != "")] +
         [.endpoints[]? | select(.tag as $tag | $tags | index($tag)) | .detour? | select(. != null and . != "")] +
         $tags | unique) as $next |
        if ($next | length) == ($tags | length) then $next else closure($next) end;
      closure($roots)
    ' "$outbounds_file") || return 1
    local missing_tags
    missing_tags=$(jq -r --argjson tags "$resolved_tags" '
      [((.outbounds // []) + (.endpoints // []))[]?.tag, "direct-out"] as $available |
      [$tags[] as $tag | select($available | index($tag) | not) | $tag] | join(", ")
    ' "$outbounds_file") || return 1
    if [[ -n "$missing_tags" ]]; then
        print_error "节点或策略出站引用了不存在的标签: $missing_tags"
        return 1
    fi
    custom_outbounds=$(jq --argjson tags "$resolved_tags" '[(.outbounds // [])[] | select(.tag as $t | $tags | index($t))]' "$outbounds_file") || return 1
    custom_endpoints=$(jq --argjson tags "$resolved_tags" '[(.endpoints // [])[] | select(.tag as $t | $tags | index($t))]' "$outbounds_file") || return 1
    if echo "$custom_outbounds" | jq -e 'any(.[]; .type == "naive")' >/dev/null 2>&1 \
        && ! singbox_has_build_tag with_naive_outbound; then
        print_error "当前内核不支持已启用的 Naive 出站（缺少 with_naive_outbound）"
        print_info "请移除该出站引用，或安装同时提供 Cronet/libcronet.so 的外部定制内核"
        return 1
    fi
    local outbound_tags full route_rules='[]' endpoints warp_config='{}'
    endpoints="$custom_endpoints"
    outbound_tags=$(jq -n --argjson o "$custom_outbounds" --argjson e "$custom_endpoints" '([$o[].tag] + [$e[].tag] + ["direct-out"]) | unique')
    while IFS= read -r node; do
        local otag itag
        otag=$(echo "$node" | jq -r '.outbound_tag // empty')
        itag="$(echo "$node" | jq -r '.protocol')-$(echo "$node" | jq -r '.port')"
        echo "$inbound_tags" | jq -e --arg tag "$itag" 'index($tag) != null' >/dev/null || continue
        if [[ -n "$otag" ]]; then
            route_rules=$(echo "$route_rules" | jq --arg in "$itag" --arg out "$otag" '. + [{inbound:[$in],action:"route",outbound:$out}]')
        elif [[ "$(echo "$node" | jq -r '.warp_outbound // false')" == true ]]; then
            route_rules=$(echo "$route_rules" | jq --arg in "$itag" '. + [{inbound:[$in],action:"route",outbound:"warp-ep"}]')
        fi
    done < <(jq -c '.nodes[]' "$NODES_FILE")

    if jq -e '.nodes[] | select(.warp_outbound == true)' "$NODES_FILE" >/dev/null 2>&1; then
        warp_config=$(get_warp_config) || return 1
        if echo "$outbound_tags" | jq -e 'index("warp-ep") != null' >/dev/null; then
            print_error "自定义出站标签 warp-ep 与内置 WARP 标签冲突"
            return 1
        fi
        local warp_endpoint
        warp_endpoint=$(echo "$warp_config" | jq '{type:"wireguard",tag:"warp-ep",name:"wgcf",mtu:1280,address:(.local_address // ["172.16.0.2/32"]),private_key:.private_key,peers:[{address:.server,port:.server_port,public_key:.peer_public_key,allowed_ips:["0.0.0.0/0","::/0"],reserved:[0,0,0]}]}') || return 1
        endpoints=$(echo "$endpoints" | jq --argjson ep "$warp_endpoint" '. + [$ep]') || return 1
        outbound_tags=$(echo "$outbound_tags" | jq '. + ["warp-ep"] | unique') || return 1
    fi

    full=$(jq -n --argjson inbounds "$inbounds" --argjson custom "$custom_outbounds" --argjson rules "$route_rules" --argjson endpoints "$endpoints" \
        '{log:{level:"info",timestamp:true},dns:{servers:[{type:"https",tag:"dns-remote",server:"1.1.1.1",server_port:443,path:"/dns-query",domain_resolver:"dns-local"},{type:"local",tag:"dns-local"}],final:"dns-remote"},inbounds:$inbounds,endpoints:$endpoints,outbounds:([{type:"direct",tag:"direct-out"}] + $custom),route:{default_domain_resolver:"dns-local",rules:([{protocol:"dns",action:"route",outbound:"direct-out"}] + $rules),final:"direct-out",auto_detect_interface:true}}') || return 1

    if singbox_has_stats_capability; then
        full=$(echo "$full" | jq --argjson in_tags "$inbound_tags" --argjson out_tags "$outbound_tags" \
            --argjson users "$active_names" --arg listen "$SINGBOX_API_ADDR" \
            '.experimental.v2ray_api={listen:$listen,stats:{enabled:true,inbounds:$in_tags,outbounds:$out_tags,users:$users}}') || return 1
    else
        print_warning "当前为官方普通内核：节点配置将正常生成，流量统计增强功能已停用"
    fi

    local candidate bin
    candidate=$(mktemp "${SINGBOX_CONFIG}.candidate.XXXXXX") || return 1
    printf '%s\n' "$full" | jq . > "$candidate" || { rm -f "$candidate"; return 1; }
    chmod 600 "$candidate"
    bin=$(get_singbox_bin)
    if [[ -x "$bin" ]]; then
        if ! "$bin" check -c "$candidate"; then
            print_error "sing-box check 未通过，保留当前配置"
            rm -f "$candidate"
            return 1
        fi
    fi
    mv -f "$candidate" "$SINGBOX_CONFIG"
    chmod 600 "$SINGBOX_CONFIG" "$USERS_FILE" "$NODES_FILE" "$NODE_USERS_FILE" "$outbounds_file" 2>/dev/null || true
    print_success "sing-box 稳定版配置已生成并通过检查: $SINGBOX_CONFIG"
)

create_user_limits_units() {
    local unit_dir limit_service limit_timer
    unit_dir=$(dirname "$SINGBOX_SERVICE")
    limit_service="${unit_dir}/sing-box-user-limits.service"
    limit_timer="${unit_dir}/sing-box-user-limits.timer"
    cat > "$limit_service" <<EOF
[Unit]
Description=Enforce sing-box user traffic and expiration limits
After=sing-box.service

[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=${MANAGER_SCRIPT} --enforce-limits
EOF
    cat > "$limit_timer" <<'EOF'
[Unit]
Description=Periodically enforce sing-box user limits

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$limit_service" "$limit_timer"
}

ensure_user_limits_timer() {
    local unit_dir
    unit_dir=$(dirname "$SINGBOX_SERVICE")
    if [[ ! -f "${unit_dir}/sing-box-user-limits.service" || ! -f "${unit_dir}/sing-box-user-limits.timer" ]]; then
        create_user_limits_units || return 1
        systemctl daemon-reload
    fi
    systemctl enable --now sing-box-user-limits.timer >/dev/null 2>&1
}

create_systemd_service() {
    local bin
    bin=$(get_singbox_bin)
    mkdir -p "$(dirname "$SINGBOX_SERVICE")" "$DATA_DIR"
    local service="[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
WorkingDirectory=${DATA_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${bin} run -c ${SINGBOX_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target"
    printf '%s\n' "$service" > "$SINGBOX_SERVICE"
    chmod 644 "$SINGBOX_SERVICE"
    create_user_limits_units
}

version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

resolve_singbox_version() {
    local channel=${1:-stable}
    local explicit=${2:-}
    if [[ -n "$explicit" ]]; then
        [[ "$explicit" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
        echo "$explicit"
        return
    fi
    local releases version auth_args=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    releases=$(curl -fsSL --retry 3 --connect-timeout 15 "${auth_args[@]}" 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=30' 2>/dev/null || true)
    if [[ "$channel" == "beta" ]]; then
        version=$(echo "$releases" | jq -r '[.[] | select(.prerelease == true and .draft == false)][0].tag_name // empty' 2>/dev/null | sed 's/^v//')
    else
        version=$(echo "$releases" | jq -r '[.[] | select(.prerelease == false and .draft == false)][0].tag_name // empty' 2>/dev/null | sed 's/^v//')
    fi
    if [[ -z "$version" ]]; then
        version=$(git ls-remote --tags --refs https://github.com/SagerNet/sing-box.git 'v*' 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/v##' | {
            if [[ "$channel" == beta ]]; then grep -E '[.-](alpha|beta|rc)[.-]?[0-9]+'; else grep -Ev '[.-](alpha|beta|rc)[.-]?[0-9]+'; fi
        } | sort -V | tail -n1)
    fi
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    echo "$version"
}

ensure_singbox_go() {
    local minimum=${1:-1.24.0}
    local go_bin current arch api file url sha tmp download_version
    go_bin=$(command -v go 2>/dev/null || true)
    if [[ -n "$go_bin" ]]; then
        current=$($go_bin version | sed -n 's/.*go\([0-9][0-9.]*\).*/\1/p')
        if [[ -n "$current" ]] && version_ge "$current" "$minimum"; then
            echo "$go_bin"
            return
        fi
    fi

    # 优先复用项目之前下载并校验过的 Go 工具链，避免失败重试时重复下载。
    if [[ -x "$SINGBOX_GO_DIR/bin/go" ]]; then
        current=$($SINGBOX_GO_DIR/bin/go version 2>/dev/null | sed -n 's/.*go\([0-9][0-9.]*\).*/\1/p')
        if [[ -n "$current" ]] && version_ge "$current" "$minimum"; then
            printf '%s\n' "$SINGBOX_GO_DIR/bin/go"
            return
        fi
    fi

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l|armv6l) arch=armv6l ;;
        *) print_error "不支持自动安装 Go 的架构: $arch" >&2; return 1 ;;
    esac
    api=$(curl -fsSL --retry 3 --connect-timeout 15 'https://go.dev/dl/?mode=json') || return 1
    file=$(echo "$api" | jq -c --arg arch "$arch" \
        '[.[] | select(.stable == true) | . as $release | .files[] | select(.os=="linux" and .arch==$arch and .kind=="archive") | . + {go_version:($release.version | ltrimstr("go"))}][0]') || return 1
    download_version=$(echo "$file" | jq -r '.go_version // empty')
    [[ -n "$download_version" ]] && version_ge "$download_version" "$minimum" || {
        print_error "Go 官方稳定版低于 sing-box 要求的 $minimum" >&2
        return 1
    }
    url="https://go.dev/dl/$(echo "$file" | jq -r '.filename')"
    sha=$(echo "$file" | jq -r '.sha256')
    [[ -n "$sha" && "$sha" != null ]] || return 1
    tmp=$(mktemp -d) || return 1
    if ! curl -fL --retry 3 "$url" -o "$tmp/go.tgz"; then
        rm -rf "$tmp"
        return 1
    fi
    # ensure_singbox_go 的标准输出只能包含最终可执行路径；校验成功提示不得被命令替换捕获。
    if ! echo "$sha  $tmp/go.tgz" | sha256sum -c - >/dev/null; then
        print_error "Go 工具链 SHA256 校验失败" >&2
        rm -rf "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$SINGBOX_GO_DIR")"
    rm -rf "$SINGBOX_GO_DIR"
    mkdir -p "$SINGBOX_GO_DIR"
    tar -xzf "$tmp/go.tgz" --strip-components=1 -C "$SINGBOX_GO_DIR" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    current=$($SINGBOX_GO_DIR/bin/go version | sed -n 's/.*go\([0-9][0-9.]*\).*/\1/p')
    [[ -n "$current" ]] && version_ge "$current" "$minimum" || return 1
    printf '%s\n' "$SINGBOX_GO_DIR/bin/go"
}

normalize_singbox_build_tags() {
    local tags_file=$1 excluded_tags=${2:-} raw token excluded result="" seen=" " skip
    local IFS=$' \t\n'
    [[ -f "$tags_file" ]] || return 1

    # 官方不同版本可能使用逗号、空格或换行分隔；Go 1.25 不接受逗号与空格混用。
    raw=$(tr ',\r\n\t' '    ' < "$tags_file") || return 1
    excluded_tags=${excluded_tags//,/ }
    for token in $raw with_v2ray_api; do
        if [[ ! "$token" =~ ^[A-Za-z0-9_.-]+$ ]]; then
            print_error "发现非法 Go 构建标签: $token" >&2
            return 1
        fi
        skip=false
        for excluded in $excluded_tags; do
            [[ "$token" == "$excluded" ]] && { skip=true; break; }
        done
        $skip && continue
        if [[ "$seen" != *" $token "* ]]; then
            result+="${result:+,}${token}"
            seen+="$token "
        fi
    done
    [[ -n "$result" ]] || return 1
    printf '%s\n' "$result"
}

select_singbox_build_jobs() {
    local cpus=1 mem_kb=0 jobs
    if command -v nproc >/dev/null 2>&1; then
        cpus=$(nproc 2>/dev/null || echo 1)
    elif command -v getconf >/dev/null 2>&1; then
        cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    fi
    [[ "$cpus" =~ ^[0-9]+$ && "$cpus" -ge 1 ]] || cpus=1
    [[ -r /proc/meminfo ]] && mem_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    [[ "$mem_kb" =~ ^[0-9]+$ ]] || mem_kb=0

    if [[ "$mem_kb" -gt 0 && "$mem_kb" -lt 1572864 ]]; then
        jobs=1
    elif [[ "$mem_kb" -gt 0 && "$mem_kb" -lt 3145728 ]]; then
        jobs=2
    else
        jobs=$cpus
        [[ "$jobs" -le 4 ]] || jobs=4
    fi
    [[ "$jobs" -le "$cpus" ]] || jobs=$cpus
    printf '%s\n' "$jobs"
}

run_singbox_go_build() {
    local source=$1 go_bin=$2 tags=$3 ldflags=$4 candidate=$5
    local jobs timeout_value heartbeat build_log build_pid start_time elapsed latest build_status mem_mb=0
    jobs=$(select_singbox_build_jobs)
    timeout_value=${SINGBOX_BUILD_TIMEOUT:-30m}
    heartbeat=${SINGBOX_BUILD_HEARTBEAT_SECONDS:-15}
    [[ "$timeout_value" =~ ^[1-9][0-9]*[smh]$ ]] || timeout_value=30m
    [[ "$heartbeat" =~ ^[1-9][0-9]*$ && "$heartbeat" -le 60 ]] || heartbeat=15
    [[ -r /proc/meminfo ]] && mem_mb=$(awk '/^MemAvailable:/ {printf "%d", $2/1024; exit}' /proc/meminfo)
    build_log="${candidate}.build.log"
    start_time=$SECONDS

    print_info "编译资源: 并发=${jobs}, 可用内存约=${mem_mb:-0}MB, 超时=${timeout_value}"
    (
        cd "$source" || exit 1
        export CGO_ENABLED=0 GOMAXPROCS="$jobs"
        if command -v timeout >/dev/null 2>&1; then
            timeout "$timeout_value" "$go_bin" build -v -p "$jobs" -trimpath -tags "$tags" \
                -ldflags "$ldflags" -o "$candidate" ./cmd/sing-box
        else
            "$go_bin" build -v -p "$jobs" -trimpath -tags "$tags" -ldflags "$ldflags" -o "$candidate" ./cmd/sing-box
        fi
    ) > "$build_log" 2>&1 &
    build_pid=$!

    while kill -0 "$build_pid" 2>/dev/null; do
        sleep "$heartbeat"
        kill -0 "$build_pid" 2>/dev/null || break
        elapsed=$((SECONDS - start_time))
        latest=$(tail -n 1 "$build_log" 2>/dev/null | tr -d '\r' | cut -c1-120)
        print_info "内核仍在编译：已用时 ${elapsed}s${latest:+，当前: $latest}"
    done

    if wait "$build_pid"; then
        build_status=0
    else
        build_status=$?
    fi
    if [[ "$build_status" -ne 0 ]]; then
        if [[ "$build_status" -eq 124 ]]; then
            print_error "sing-box 编译超过 ${timeout_value}，已自动终止"
        else
            print_error "sing-box 编译失败（退出码: $build_status）"
        fi
        echo "----- 编译日志（最后 80 行）-----"
        tail -n 80 "$build_log" 2>/dev/null || true
        echo "---------------------------------"
        return "$build_status"
    fi
    rm -f "$build_log"
    print_success "sing-box 编译完成，用时 $((SECONDS - start_time)) 秒"
}

build_and_install_singbox() {
    local version=$1 start_after_install=${2:-true} go_bin work source tags tags_file ldflags candidate target backup required_go was_active=false
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { print_error "非法版本号: $version"; return 1; }
    mkdir -p "$SINGBOX_BUILD_DIR"
    work=$(mktemp -d "${SINGBOX_BUILD_DIR}/build.XXXXXX") || return 1
    source="$work/source"; candidate="$work/sing-box"
    print_info "拉取 sing-box v${version} 源码..."
    if ! git -c advice.detachedHead=false clone --depth 1 --single-branch --branch "v${version}" https://github.com/SagerNet/sing-box.git "$source"; then
        rm -rf "$work"; print_error "源码下载失败"; return 1
    fi
    [[ -f "$source/release/LDFLAGS" ]] || { rm -rf "$work"; print_error "官方构建元数据缺失"; return 1; }
    if [[ -n "${SINGBOX_BUILD_TAGS_FILE:-}" ]]; then
        tags_file="$SINGBOX_BUILD_TAGS_FILE"
    elif [[ -f "$source/release/DEFAULT_BUILD_TAGS_OTHERS" ]]; then
        # 与官方 release/local/common.sh 保持一致。完整 DEFAULT_BUILD_TAGS 中的
        # with_naive_outbound 需要额外构建 Chromium/Cronet 和 libcronet.so。
        tags_file="$source/release/DEFAULT_BUILD_TAGS_OTHERS"
    else
        tags_file="$source/release/DEFAULT_BUILD_TAGS"
    fi
    [[ -f "$tags_file" ]] || { rm -rf "$work"; print_error "官方本地构建标签文件缺失"; return 1; }
    required_go=$(awk '$1 == "go" { print $2 } $1 == "toolchain" { sub(/^go/, "", $2); print $2 }' "$source/go.mod" | sort -V | tail -n1)
    required_go=${required_go:-1.24.0}
    go_bin=$(ensure_singbox_go "$required_go") || { rm -rf "$work"; print_error "无法准备 Go ${required_go}+ 工具链"; return 1; }
    if [[ "$go_bin" == *$'\n'* || ! -x "$go_bin" ]]; then
        rm -rf "$work"
        print_error "Go 工具链路径无效: ${go_bin//$'\n'/, }"
        return 1
    fi
    tags=$(normalize_singbox_build_tags "$tags_file" "with_naive_outbound") || {
        rm -rf "$work"
        print_error "无法解析官方 sing-box 构建标签"
        return 1
    }
    ldflags=$(tr '\n' ' ' < "$source/release/LDFLAGS")
    print_info "编译 sing-box（启用 with_v2ray_api）..."
    print_info "构建标签: $tags"
    if ! run_singbox_go_build "$source" "$go_bin" "$tags" "$ldflags" "$candidate"; then
        rm -rf "$work"; print_error "sing-box 编译失败"; return 1
    fi
    chmod 755 "$candidate"
    "$candidate" version || { rm -rf "$work"; return 1; }
    "$candidate" version | grep -q 'with_v2ray_api' || { rm -rf "$work"; print_error "候选内核缺少 with_v2ray_api 构建标签"; return 1; }
    [[ ! -f "$SINGBOX_CONFIG" ]] || "$candidate" check -c "$SINGBOX_CONFIG" || { rm -rf "$work"; print_error "候选内核无法加载当前配置"; return 1; }
    target="${SINGBOX_INSTALL_BIN:-/usr/local/bin/sing-box}"
    mkdir -p "$(dirname "$target")"
    backup="${target}.backup.$(date +%Y%m%d_%H%M%S)"
    systemctl is-active --quiet sing-box 2>/dev/null && was_active=true
    [[ -f "$target" ]] && cp -a "$target" "$backup"
    systemctl stop sing-box 2>/dev/null || true
    if ! install -m 0755 "$candidate" "${target}.new" || ! mv -f "${target}.new" "$target"; then
        if [[ -f "$backup" ]]; then cp -a "$backup" "$target"; else rm -f "$target"; fi
        $was_active && systemctl start sing-box 2>/dev/null || true
        rm -rf "$work"; return 1
    fi
    if ! create_systemd_service; then
        print_error "systemd 服务文件创建失败，正在回滚内核"
        if [[ -f "$backup" ]]; then cp -a "$backup" "$target"; else rm -f "$target"; fi
        $was_active && systemctl start sing-box 2>/dev/null || true
        rm -rf "$work"
        return 1
    fi
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl enable --now sing-box-user-limits.timer >/dev/null 2>&1 || print_warning "用户限制定时器启用失败"
    if [[ "$start_after_install" == true ]]; then
        if ! systemctl restart sing-box || { sleep 2; ! systemctl is-active --quiet sing-box; }; then
            print_error "新内核启动失败，正在自动回滚"
            if [[ -f "$backup" ]]; then cp -a "$backup" "$target"; else rm -f "$target"; fi
            systemctl daemon-reload
            $was_active && systemctl restart sing-box 2>/dev/null || true
            rm -rf "$work"; return 1
        fi
    fi
    printf '%s\n' "$version" > "${DATA_DIR}/installed_version"
    chmod 600 "${DATA_DIR}/installed_version"
    rm -rf "$work"
    print_success "sing-box v${version} 定制内核安装成功（with_v2ray_api）"
}

prepare_singbox_storage() {
    umask 077
    mkdir -p "$DATA_DIR" "$SUBSCRIPTION_DIR" "$SINGBOX_DIR"
    atomic_write_json "$USERS_FILE" "$([[ -f "$USERS_FILE" ]] && cat "$USERS_FILE" || echo '{"users":[]}')" || return 1
    atomic_write_json "$NODES_FILE" "$([[ -f "$NODES_FILE" ]] && cat "$NODES_FILE" || echo '{"nodes":[]}')" || return 1
    atomic_write_json "$NODE_USERS_FILE" "$([[ -f "$NODE_USERS_FILE" ]] && cat "$NODE_USERS_FILE" || echo '{"bindings":[]}')" || return 1
    [[ -f "${DATA_DIR}/outbounds.json" ]] || atomic_write_json "${DATA_DIR}/outbounds.json" '{"outbounds":[],"endpoints":[]}'
    [[ -f "$TRAFFIC_COUNTERS_FILE" ]] || atomic_write_json "$TRAFFIC_COUNTERS_FILE" '{"users":{}}'
}

install_sing-box() {
    prepare_singbox_storage || return 1
    echo -e "${CYAN}1.${NC} 最新稳定版（推荐）"
    echo -e "${CYAN}2.${NC} 最新测试版"
    echo -e "${CYAN}3.${NC} 指定版本"
    read -p "请选择 [1-3，默认1]: " choice
    choice=${choice:-1}
    local channel=stable explicit="" version start_after_install=true
    case "$choice" in
        1) channel=stable ;;
        2) channel=beta ;;
        3) read -p "版本号（如 1.13.15）: " explicit ;;
        *) print_error "无效选择"; return 1 ;;
    esac
    version=$(resolve_singbox_version "$channel" "$explicit") || { print_error "无法解析目标版本"; return 1; }
    [[ -f "$SINGBOX_CONFIG" ]] || start_after_install=false
    build_and_install_singbox "$version" "$start_after_install" || return 1
    [[ -f "$SINGBOX_CONFIG" ]] || create_default_config || return 1
    generate_singbox_config || return 1
    restart_sing-box
}

update_sing-box() {
    prepare_singbox_storage || return 1
    echo -e "${CYAN}1.${NC} 最新稳定版（推荐）"
    echo -e "${CYAN}2.${NC} 最新测试版"
    echo -e "${CYAN}3.${NC} 指定版本"
    read -p "请选择 [1-3，默认1]: " choice
    choice=${choice:-1}
    local channel=stable explicit="" version
    case "$choice" in
        1) channel=stable ;;
        2) channel=beta ;;
        3) read -p "目标版本: " explicit ;;
        *) return 1 ;;
    esac
    version=$(resolve_singbox_version "$channel" "$explicit") || return 1
    build_and_install_singbox "$version"
}

resolve_tunnel_endpoint() {
    local tunnel=$1 default_port=443 authority
    [[ "$tunnel" == http://* ]] && default_port=80
    authority=${tunnel#*://}
    authority=${authority%%/*}
    authority=${authority%%\?*}
    authority=${authority%%\#*}
    authority=${authority##*@}
    split_host_port "$authority" "$default_port"
}

resolve_subscription_host() {
    local node=$1 host="" tunnel parsed security
    tunnel=$(echo "$node" | jq -r '.tunnel_domain // ""')
    if [[ -n "$tunnel" && "$tunnel" != null ]]; then
        parsed=$(resolve_tunnel_endpoint "$tunnel") || return 1
        host=${parsed%|*}
    fi
    [[ -n "$host" ]] || host=$(echo "$node" | jq -r '.extra.server_address // ""')
    security=$(echo "$node" | jq -r '.security // "none"')
    if [[ -z "$host" && "$security" == reality ]]; then
        host=$(get_public_ip 2>/dev/null || true)
        [[ -n "$host" ]] || {
            print_error "无法获取 Reality 节点的服务器公网 IPv4，拒绝生成可能指向 CDN 的无效订阅" >&2
            return 1
        }
    fi
    if [[ -z "$host" && "$security" == none ]]; then
        host=$(get_public_ip 2>/dev/null || true)
    fi
    [[ -n "$host" ]] || host=$(get_subscription_domain_hint 2>/dev/null || true)
    [[ -n "$host" ]] || host=$(get_public_ip 2>/dev/null || true)
    host=${host#\[}
    host=${host%\]}
    if [[ -z "$host" || "$host" == null ]]; then
        print_error "无法确定节点服务器地址：请先配置服务器域名，或确认服务器可获取公网 IPv4" >&2
        return 1
    fi
    echo "$host"
}

resolve_subscription_port() {
    local node=$1 tunnel parsed
    tunnel=$(echo "$node" | jq -r '.tunnel_domain // ""')
    if [[ -n "$tunnel" && "$tunnel" != null ]]; then
        parsed=$(resolve_tunnel_endpoint "$tunnel") || return 1
        echo "${parsed##*|}"
    else
        echo "$node" | jq -r '.port'
    fi
}

get_subscription_user() {
    local id=$1
    jq -c --arg id "$id" '.users[] | select(.id == $id)' "$USERS_FILE" 2>/dev/null | head -1
}

subscription_ss_password() {
    local node=$1 user=$2 method master user_key
    method=$(effective_ss_method "$(echo "$node" | jq -r '.extra.method // .extra.cipher // "2022-blake3-aes-128-gcm"')")
    if [[ "$method" == 2022-* ]]; then
        master=$(echo "$node" | jq -r '.extra.master_password // ""')
        [[ -n "$master" ]] || return 1
        user_key=$(derive_ss2022_key "$(echo "$user" | jq -r '.id'):$(echo "$user" | jq -r '.password')" "$method")
        echo "${master}:${user_key}"
    else
        echo "$user" | jq -r '.password'
    fi
}

generate_share_link_smart() {
    local user_id=$1 ignored=${2:-} node=$3 user protocol host uri_host port name password uuid extra security transport insecure insecure_flag query method ss_password
    user=$(get_subscription_user "$user_id")
    [[ -n "$user" ]] || return 1
    [[ "$(echo "$node" | jq -r '.enabled // true')" == "true" ]] || return 1
    protocol=$(echo "$node" | jq -r '.protocol')
    host=$(resolve_subscription_host "$node") || return 1
    uri_host=$(format_uri_host "$host")
    port=$(resolve_subscription_port "$node")
    name="$(echo "$node" | jq -r '.name // .tag // .protocol')-$(echo "$user" | jq -r '.username')"
    password=$(echo "$user" | jq -r '.password'); uuid=$(echo "$user" | jq -r '.id')
    extra=$(echo "$node" | jq -c '.extra // {}'); security=$(echo "$node" | jq -r '.security // "none"'); transport=$(echo "$node" | jq -r '.transport // "tcp"')
    insecure=$(node_tls_insecure "$extra")
    [[ "$insecure" == true ]] && insecure_flag=1 || insecure_flag=0
    case "$protocol" in
        vless)
            query="encryption=none&security=$security&type=$transport"
            [[ "$security" == reality ]] && query+="&flow=xtls-rprx-vision&sni=$(urlencode "$(echo "$extra" | jq -r '.server_names[0] // .tls_domain')")&fp=chrome&pbk=$(urlencode "$(echo "$extra" | jq -r '.public_key')")&sid=$(urlencode "$(echo "$extra" | jq -r '.short_ids[0] // ""')")"
            [[ "$security" == tls ]] && query+="&sni=$(urlencode "$(echo "$extra" | jq -r '.tls_domain')")&allowInsecure=$insecure_flag"
            [[ "$transport" == tcp ]] && query+="&headerType=none"
            [[ "$transport" == ws ]] && query+="&path=$(urlencode "$(echo "$extra" | jq -r '.ws_path // "/"')")&host=$(urlencode "$(echo "$extra" | jq -r '.ws_host // ""')")"
            [[ "$transport" == grpc ]] && query+="&serviceName=$(urlencode "$(echo "$extra" | jq -r '.grpc_service // "grpc"')")"
            [[ "$transport" == http ]] && query+="&path=$(urlencode "$(echo "$extra" | jq -r '.http_path // "/"')")&host=$(urlencode "$(echo "$extra" | jq -r '.http_host // ""')")"
            echo "vless://${uuid}@${uri_host}:${port}?${query}#$(urlencode "$name")" ;;
        vmess)
            local vmess_net="$transport" vmess_path vmess_host
            [[ "$vmess_net" == http ]] && vmess_net=h2
            vmess_path=$(echo "$extra" | jq -r 'if .http_path != null and .http_path != "" then .http_path elif .grpc_service != null and .grpc_service != "" then .grpc_service else (.ws_path // "") end')
            vmess_host=$(echo "$extra" | jq -r '.http_host // .ws_host // ""')
            jq -cn --arg ps "$name" --arg add "$host" --arg port "$port" --arg id "$uuid" --arg net "$vmess_net" --argjson insecure "$insecure" \
                --arg tls "$([[ "$security" == tls ]] && echo tls || echo '')" --arg sni "$(echo "$extra" | jq -r '.tls_domain // ""')" \
                --arg host "$vmess_host" --arg path "$vmess_path" --arg aid "$(echo "$extra" | jq -r '.alter_id // 0')" --arg scy "$(echo "$extra" | jq -r '.cipher // "auto"')" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:$aid,scy:$scy,net:$net,type:"none",host:$host,path:$path,tls:$tls,sni:$sni,allowInsecure:$insecure}' | base64_encode | sed 's#^#vmess://#' ;;
        trojan)
            query="security=tls&sni=$(urlencode "$(echo "$extra" | jq -r '.tls_domain')")&allowInsecure=${insecure}&type=${transport}"
            [[ "$transport" == ws ]] && query+="&path=$(urlencode "$(echo "$extra" | jq -r '.ws_path // "/"')")&host=$(urlencode "$(echo "$extra" | jq -r '.ws_host // ""')")"
            [[ "$transport" == grpc ]] && query+="&serviceName=$(urlencode "$(echo "$extra" | jq -r '.grpc_service // "grpc"')")"
            echo "trojan://$(urlencode "$password")@${uri_host}:${port}?${query}#$(urlencode "$name")" ;;
        shadowsocks)
            method=$(effective_ss_method "$(echo "$extra" | jq -r '.method // .cipher // "2022-blake3-aes-128-gcm"')"); ss_password=$(subscription_ss_password "$node" "$user")
            echo "ss://$(base64_encode "${method}:${ss_password}")@${uri_host}:${port}#$(urlencode "$name")" ;;
        hysteria2)
            query="sni=$(urlencode "$(echo "$extra" | jq -r '.tls_domain')")&insecure=$([[ "$insecure" == true ]] && echo 1 || echo 0)"
            [[ -n "$(echo "$extra" | jq -r '.obfs_password // ""')" ]] && query+="&obfs=salamander&obfs-password=$(urlencode "$(echo "$extra" | jq -r '.obfs_password')")"
            [[ -n "$(echo "$extra" | jq -r '.port_hopping // ""')" ]] && query+="&mport=$(echo "$extra" | jq -r '.port_hopping')"
            echo "hysteria2://$(urlencode "$password")@${uri_host}:${port}?${query}#$(urlencode "$name")" ;;
        hysteria)
            query="protocol=udp&upmbps=$(echo "$extra" | jq -r '.up_mbps')&downmbps=$(echo "$extra" | jq -r '.down_mbps')&peer=$(urlencode "$(echo "$extra" | jq -r '.tls_domain')")&insecure=$([[ "$insecure" == true ]] && echo 1 || echo 0)"
            [[ -z "$(echo "$extra" | jq -r '.obfs // ""')" ]] || query+="&obfs=$(urlencode "$(echo "$extra" | jq -r '.obfs')")"
            echo "hysteria://$(urlencode "$password")@${uri_host}:${port}?${query}#$(urlencode "$name")" ;;
        shadowtls)
            echo "shadowtls://$(urlencode "$password")@${uri_host}:${port}?version=3&host=$(urlencode "$(echo "$extra" | jq -r '.handshake_server')")#$(urlencode "$name")" ;;
        snell)
            local snell_client_version
            snell_client_version=$(echo "$extra" | jq -r 'if (.version // 5) == 5 then 4 else 6 end')
            query="version=${snell_client_version}&userkey=$(urlencode "$password")"
            [[ "$snell_client_version" != "4" ]] || query+="&obfs=$(urlencode "$(echo "$extra" | jq -r '.obfs_mode // "none"')")"
            [[ "$snell_client_version" != "6" ]] || query+="&mode=$(urlencode "$(echo "$extra" | jq -r '.mode // "default"')")"
            echo "snell://$(urlencode "$(echo "$extra" | jq -r '.psk')")@${uri_host}:${port}?${query}#$(urlencode "$name")" ;;
        tuic)
            query="sni=$(urlencode "$(echo "$extra" | jq -r '.tls_domain')")&alpn=h3&congestion_control=$(urlencode "$(echo "$extra" | jq -r '.congestion_control // "cubic"')")&udp_relay_mode=native&allow_insecure=${insecure_flag}&zero_rtt_handshake=$([[ "$(echo "$extra" | jq -r '.zero_rtt_handshake // false')" == true ]] && echo 1 || echo 0)&heartbeat=10s"
            echo "tuic://${uuid}:$(urlencode "$password")@${uri_host}:${port}?${query}#$(urlencode "$name")" ;;
        naive)
            echo "naive+https://$(urlencode "$(echo "$user" | jq -r '.username')"):$(urlencode "$password")@${uri_host}:${port}#$(urlencode "$name")" ;;
        anytls)
            echo "anytls://$(urlencode "$password")@${uri_host}:${port}?security=tls&sni=$(urlencode "$(echo "$extra" | jq -r '.tls_domain')")&allowInsecure=${insecure}#$(urlencode "$name")" ;;
        http)
            echo "$([[ "$security" == tls ]] && echo https || echo http)://$(urlencode "$(echo "$user" | jq -r '.username')"):$(urlencode "$password")@${uri_host}:${port}#$(urlencode "$name")" ;;
        socks|mixed)
            echo "socks5://$(urlencode "$(echo "$user" | jq -r '.username')"):$(urlencode "$password")@${uri_host}:${port}#$(urlencode "$name")" ;;
        *) return 1 ;;
    esac
}

client_tls_for_node() {
    local node=$1 extra security protocol insecure tls server sni
    extra=$(echo "$node" | jq -c '.extra // {}'); security=$(echo "$node" | jq -r '.security // "none"'); protocol=$(echo "$node" | jq -r '.protocol'); insecure=$(node_tls_insecure "$extra")
    sni=$(echo "$extra" | jq -r '.tls_domain // .server_names[0] // ""')
    tls=$(jq -n --arg sni "$sni" --argjson insecure "$insecure" '{enabled:true,server_name:$sni,insecure:$insecure}')
    [[ "$protocol" == tuic ]] && tls=$(echo "$tls" | jq '.alpn=["h3"]')
    if [[ "$security" == reality ]]; then
        tls=$(echo "$tls" | jq --arg pk "$(echo "$extra" | jq -r '.public_key')" --arg sid "$(echo "$extra" | jq -r '.short_ids[0] // ""')" '.reality={enabled:true,public_key:$pk,short_id:$sid} | .utls={enabled:true,fingerprint:"chrome"}')
    fi
    echo "$tls"
}

node_to_singbox_outbound() {
    local node=$1 user=$2 protocol host port tag password uuid username extra security transport out tls trans method
    [[ "$(echo "$node" | jq -r '.enabled // true')" == "true" ]] || return 1
    protocol=$(echo "$node" | jq -r '.protocol')
    host=$(resolve_subscription_host "$node") || return 1
    port=$(resolve_subscription_port "$node")
    tag="$(echo "$node" | jq -r '.name // .tag // .protocol')-${port}"; password=$(echo "$user" | jq -r '.password'); uuid=$(echo "$user" | jq -r '.id'); username=$(echo "$user" | jq -r '.username')
    extra=$(echo "$node" | jq -c '.extra // {}'); security=$(echo "$node" | jq -r '.security // "none"'); transport=$(echo "$node" | jq -r '.transport // "tcp"')
    case "$protocol" in
        vless) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg uuid "$uuid" '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid}')
            [[ "$security" == reality ]] && out=$(echo "$out" | jq '.flow="xtls-rprx-vision"') ;;
        vmess) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg uuid "$uuid" --arg security "$(echo "$extra" | jq -r '.cipher // "auto"')" --argjson alter_id "$(echo "$extra" | jq -r '.alter_id // 0')" '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:$security,alter_id:$alter_id}') ;;
        trojan) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg password "$password" '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password}') ;;
        shadowsocks) method=$(effective_ss_method "$(echo "$extra" | jq -r '.method // .cipher // "2022-blake3-aes-128-gcm"')"); password=$(subscription_ss_password "$node" "$user"); out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg method "$method" --arg password "$password" '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:$password}') ;;
        hysteria2) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg password "$password" '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password}')
            [[ -n "$(echo "$extra" | jq -r '.obfs_password // ""')" ]] && out=$(echo "$out" | jq --arg p "$(echo "$extra" | jq -r '.obfs_password')" '.obfs={type:"salamander",password:$p}')
            [[ -n "$(echo "$extra" | jq -r '.port_hopping // ""')" ]] && out=$(echo "$out" | jq --arg ports "$(echo "$extra" | jq -r '.port_hopping')" '.server_ports=[$ports] | .hop_interval="30s" | del(.server_port)')
            out=$(echo "$out" | jq --argjson up "$(echo "$extra" | jq -r '.up_mbps // 0')" --argjson down "$(echo "$extra" | jq -r '.down_mbps // 0')" 'if $up > 0 then .up_mbps=$up else . end | if $down > 0 then .down_mbps=$down else . end') ;;
        hysteria) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg auth_str "$password" \
            --argjson up "$(echo "$extra" | jq -r '.up_mbps')" --argjson down "$(echo "$extra" | jq -r '.down_mbps')" \
            '{type:"hysteria",tag:$tag,server:$server,server_port:$port,auth_str:$auth_str,up_mbps:$up,down_mbps:$down}')
            [[ -z "$(echo "$extra" | jq -r '.obfs // ""')" ]] || out=$(echo "$out" | jq --arg obfs "$(echo "$extra" | jq -r '.obfs')" '.obfs=$obfs') ;;
        shadowtls) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg password "$password" \
            '{type:"shadowtls",tag:$tag,server:$server,server_port:$port,version:3,password:$password}') ;;
        snell) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg psk "$(echo "$extra" | jq -r '.psk')" \
            --arg userkey "$password" --argjson version "$(echo "$extra" | jq -r 'if (.version // 5) == 5 then 4 else 6 end')" \
            '{type:"snell",tag:$tag,server:$server,server_port:$port,version:$version,psk:$psk,userkey:$userkey}')
            if [[ "$(echo "$extra" | jq -r '.version // 5')" == "5" ]]; then
                out=$(echo "$out" | jq --arg mode "$(echo "$extra" | jq -r '.obfs_mode // "none"')" '.obfs_mode=$mode')
            else
                out=$(echo "$out" | jq --arg mode "$(echo "$extra" | jq -r '.mode // "default"')" '.mode=$mode')
            fi ;;
        tuic) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --arg cc "$(echo "$extra" | jq -r '.congestion_control // "cubic"')" \
            --argjson zrtt "$(echo "$extra" | jq -r '.zero_rtt_handshake // false')" \
            '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$password,congestion_control:$cc,udp_relay_mode:"native",zero_rtt_handshake:$zrtt,heartbeat:"10s"}') ;;
        naive) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg username "$username" --arg password "$password" '{type:"naive",tag:$tag,server:$server,server_port:$port,username:$username,password:$password}') ;;
        anytls) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg password "$password" '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password}') ;;
        http) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg username "$username" --arg password "$password" '{type:"http",tag:$tag,server:$server,server_port:$port,username:$username,password:$password}') ;;
        socks|mixed) out=$(jq -n --arg tag "$tag" --arg server "$host" --argjson port "$port" --arg username "$username" --arg password "$password" '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5",username:$username,password:$password}') ;;
        *) return 1 ;;
    esac
    if [[ "$security" == tls || "$security" == reality || "$protocol" =~ ^(trojan|hysteria|hysteria2|tuic|naive|anytls|shadowtls)$ ]]; then
        tls=$(client_tls_for_node "$node") || return 1; out=$(echo "$out" | jq --argjson tls "$tls" '.tls=$tls')
    fi
    if [[ "$transport" != tcp && "$protocol" =~ ^(vless|vmess|trojan)$ ]]; then
        trans=$(generate_114_transport "$transport" "$extra") || return 1; out=$(echo "$out" | jq --argjson t "$trans" '.transport=$t')
    fi
    echo "$out"
}

generate_singbox_subscription_config() {
    local nodes=$1 user_id=$2 ignored=${3:-} user outbounds='[]' node outbound tags selector urltest
    user=$(get_subscription_user "$user_id"); [[ -n "$user" ]] || return 1
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        outbound=$(node_to_singbox_outbound "$node" "$user") || continue
        outbounds=$(echo "$outbounds" | jq --argjson o "$outbound" '. + [$o]')
    done < <(echo "$nodes" | jq -c '.[]')
    [[ $(echo "$outbounds" | jq length) -gt 0 ]] || return 1
    tags=$(echo "$outbounds" | jq -c '[.[].tag]')
    selector=$(jq -n --argjson tags "$tags" '{type:"selector",tag:"主代理",outbounds:( $tags + ["直连"] )}')
    urltest=$(jq -n --argjson tags "$tags" '{type:"urltest",tag:"自动选择",outbounds:$tags,url:"https://www.gstatic.com/generate_204",interval:"5m",tolerance:50}')
    outbounds=$(echo "$outbounds" | jq --argjson s "$selector" --argjson u "$urltest" '. = [$s,$u] + . + [{type:"direct",tag:"直连"}]')
    jq -n --argjson out "$outbounds" '{log:{level:"error",timestamp:true},dns:{servers:[{type:"https",tag:"dns-remote",server:"1.1.1.1",server_port:443,path:"/dns-query",domain_resolver:"dns-local"},{type:"local",tag:"dns-local"}],final:"dns-remote"},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080},{type:"tun",tag:"tun-in",interface_name:"singtun0",address:["172.19.0.1/30"],auto_route:true,strict_route:true,stack:"system",mtu:9000}],outbounds:$out,route:{default_domain_resolver:"dns-local",rules:[{ip_is_private:true,action:"route",outbound:"直连"},{domain_suffix:[".cn"],action:"route",outbound:"直连"}],final:"主代理",auto_detect_interface:true}}'
}

generate_clash_config() {
    local nodes=$1 user_id=$2 ignored=${3:-} user node protocol name host port password uuid extra security transport insecure method ss_password proxies='' names=''
    user=$(get_subscription_user "$user_id"); [[ -n "$user" ]] || return 1
    while IFS= read -r node; do
        protocol=$(echo "$node" | jq -r '.protocol')
        name=$(echo "$node" | jq -r '.name // .tag // .protocol')
        host=$(resolve_subscription_host "$node") || return 1
        port=$(resolve_subscription_port "$node")
        password=$(echo "$user" | jq -r '.password'); uuid=$(echo "$user" | jq -r '.id'); extra=$(echo "$node" | jq -c '.extra // {}'); security=$(echo "$node" | jq -r '.security // "none"'); transport=$(echo "$node" | jq -r '.transport // "tcp"'); insecure=$(node_tls_insecure "$extra")
        name="$(escape_yaml_string "$name-$port-$(echo "$user" | jq -r '.username')")"
        case "$protocol" in
            vless)
                local clash_transport="$transport"
                [[ "$clash_transport" == http ]] && clash_transport=h2
                proxies+="  - {name: \"$name\", type: vless, server: \"$host\", port: $port, uuid: \"$uuid\", network: \"$clash_transport\", tls: $([[ "$security" == none ]] && echo false || echo true), udp: true"
                [[ "$security" == reality ]] && proxies+=", flow: xtls-rprx-vision, servername: \"$(echo "$extra" | jq -r '.server_names[0]')\", reality-opts: {public-key: \"$(echo "$extra" | jq -r '.public_key')\", short-id: \"$(echo "$extra" | jq -r '.short_ids[0] // ""')\"}, client-fingerprint: chrome"
                [[ "$security" == tls ]] && proxies+=", servername: \"$(echo "$extra" | jq -r '.tls_domain')\", skip-cert-verify: $insecure"
                [[ "$transport" == ws ]] && proxies+=", ws-opts: {path: \"$(echo "$extra" | jq -r '.ws_path // "/"')\", headers: {Host: \"$(echo "$extra" | jq -r '.ws_host // ""')\"}}"
                [[ "$transport" == grpc ]] && proxies+=", grpc-opts: {grpc-service-name: \"$(echo "$extra" | jq -r '.grpc_service // "grpc"')\"}"
                [[ "$transport" == http ]] && proxies+=", h2-opts: {path: \"$(echo "$extra" | jq -r '.http_path // "/"')\", host: [\"$(echo "$extra" | jq -r '.http_host // ""')\"]}"
                proxies+="}\n" ;;
            vmess)
                local clash_transport="$transport"
                [[ "$clash_transport" == http ]] && clash_transport=h2
                proxies+="  - {name: \"$name\", type: vmess, server: \"$host\", port: $port, uuid: \"$uuid\", alterId: $(echo "$extra" | jq -r '.alter_id // 0'), cipher: $(echo "$extra" | jq -r '.cipher // "auto"'), network: \"$clash_transport\", tls: $([[ "$security" == tls ]] && echo true || echo false), skip-cert-verify: $insecure"
                [[ "$security" == tls ]] && proxies+=", servername: \"$(echo "$extra" | jq -r '.tls_domain')\""
                [[ "$transport" == ws ]] && proxies+=", ws-opts: {path: \"$(echo "$extra" | jq -r '.ws_path // "/"')\", headers: {Host: \"$(echo "$extra" | jq -r '.ws_host // ""')\"}}"
                [[ "$transport" == grpc ]] && proxies+=", grpc-opts: {grpc-service-name: \"$(echo "$extra" | jq -r '.grpc_service // "grpc"')\"}"
                [[ "$transport" == http ]] && proxies+=", h2-opts: {path: \"$(echo "$extra" | jq -r '.http_path // "/"')\", host: [\"$(echo "$extra" | jq -r '.http_host // ""')\"]}"
                proxies+="}\n" ;;
            trojan)
                proxies+="  - {name: \"$name\", type: trojan, server: \"$host\", port: $port, password: \"$(escape_yaml_string "$password")\", sni: \"$(echo "$extra" | jq -r '.tls_domain')\", skip-cert-verify: $insecure, udp: true, network: \"$transport\""
                [[ "$transport" == ws ]] && proxies+=", ws-opts: {path: \"$(echo "$extra" | jq -r '.ws_path // "/"')\", headers: {Host: \"$(echo "$extra" | jq -r '.ws_host // ""')\"}}"
                [[ "$transport" == grpc ]] && proxies+=", grpc-opts: {grpc-service-name: \"$(echo "$extra" | jq -r '.grpc_service // "grpc"')\"}"
                proxies+="}\n" ;;
            shadowsocks) method=$(effective_ss_method "$(echo "$extra" | jq -r '.method // .cipher // "2022-blake3-aes-128-gcm"')"); ss_password=$(subscription_ss_password "$node" "$user"); proxies+="  - {name: \"$name\", type: ss, server: \"$host\", port: $port, cipher: \"$method\", password: \"$(escape_yaml_string "$ss_password")\", udp: true}\n" ;;
            hysteria2)
                proxies+="  - {name: \"$name\", type: hysteria2, server: \"$host\", port: $port, password: \"$(escape_yaml_string "$password")\", sni: \"$(echo "$extra" | jq -r '.tls_domain')\", skip-cert-verify: $insecure, udp: true"
                [[ -n "$(echo "$extra" | jq -r '.obfs_password // ""')" ]] && proxies+=", obfs: salamander, obfs-password: \"$(escape_yaml_string "$(echo "$extra" | jq -r '.obfs_password')")\""
                [[ -n "$(echo "$extra" | jq -r '.port_hopping // ""')" ]] && proxies+=", ports: \"$(echo "$extra" | jq -r '.port_hopping' | tr ':' '-')\""
                [[ "$(echo "$extra" | jq -r '.up_mbps // 0')" -gt 0 ]] && proxies+=", up: \"$(echo "$extra" | jq -r '.up_mbps') Mbps\""
                [[ "$(echo "$extra" | jq -r '.down_mbps // 0')" -gt 0 ]] && proxies+=", down: \"$(echo "$extra" | jq -r '.down_mbps') Mbps\""
                proxies+="}\n" ;;
            hysteria)
                proxies+="  - {name: \"$name\", type: hysteria, server: \"$host\", port: $port, auth-str: \"$(escape_yaml_string "$password")\", sni: \"$(echo "$extra" | jq -r '.tls_domain')\", skip-cert-verify: $insecure, up: \"$(echo "$extra" | jq -r '.up_mbps') Mbps\", down: \"$(echo "$extra" | jq -r '.down_mbps') Mbps\""
                [[ -z "$(echo "$extra" | jq -r '.obfs // ""')" ]] || proxies+=", obfs: \"$(escape_yaml_string "$(echo "$extra" | jq -r '.obfs')")\""
                proxies+="}\n" ;;
            snell)
                local clash_snell_version
                clash_snell_version=$(echo "$extra" | jq -r 'if (.version // 5) == 5 then 4 else 6 end')
                proxies+="  - {name: \"$name\", type: snell, server: \"$host\", port: $port, psk: \"$(escape_yaml_string "$(echo "$extra" | jq -r '.psk')")\", version: $clash_snell_version, userkey: \"$(escape_yaml_string "$password")\"}\n" ;;
            shadowtls) continue ;;
            tuic) proxies+="  - {name: \"$name\", type: tuic, server: \"$host\", port: $port, uuid: \"$uuid\", password: \"$(escape_yaml_string "$password")\", sni: \"$(echo "$extra" | jq -r '.tls_domain')\", skip-cert-verify: $insecure, congestion-controller: \"$(echo "$extra" | jq -r '.congestion_control // "cubic"')\", udp-relay-mode: native}\n" ;;
            naive) proxies+="  - {name: \"$name\", type: naive, server: \"$host\", port: $port, username: \"$(echo "$user" | jq -r '.username')\", password: \"$(escape_yaml_string "$password")\", sni: \"$(echo "$extra" | jq -r '.tls_domain')\", skip-cert-verify: $insecure}\n" ;;
            anytls) proxies+="  - {name: \"$name\", type: anytls, server: \"$host\", port: $port, password: \"$(escape_yaml_string "$password")\", sni: \"$(echo "$extra" | jq -r '.tls_domain')\", skip-cert-verify: $insecure}\n" ;;
            http)
                proxies+="  - {name: \"$name\", type: http, server: \"$host\", port: $port, username: \"$(escape_yaml_string "$(echo "$user" | jq -r '.username')")\", password: \"$(escape_yaml_string "$password")\""
                [[ "$security" == tls ]] && proxies+=", tls: true, sni: \"$(echo "$extra" | jq -r '.tls_domain')\", skip-cert-verify: $insecure"
                proxies+="}\n" ;;
            socks|mixed) proxies+="  - {name: \"$name\", type: socks5, server: \"$host\", port: $port, username: \"$(echo "$user" | jq -r '.username')\", password: \"$(escape_yaml_string "$password")\", udp: true}\n" ;;
            *) continue ;;
        esac
        names+="      - \"$name\"\n"
    done < <(echo "$nodes" | jq -c '.[]')
    [[ -n "$proxies" ]] || return 1
    printf 'port: 7890\nsocks-port: 7891\nallow-lan: false\nmode: rule\nlog-level: info\nproxies:\n%bproxy-groups:\n  - name: "主代理"\n    type: select\n    proxies:\n%b      - DIRECT\nrules:\n  - MATCH,主代理\n' "$proxies" "$names"
}

get_user_email_from_config() {
    local uuid=$1
    jq -r --arg id "$uuid" '.users[] | select(.id == $id) | (.username // .id)' "$USERS_FILE" 2>/dev/null | head -1
}

query_user_raw_traffic() {
    local username=$1 bin stats up down
    singbox_has_stats_capability || return 1
    bin=$(get_singbox_bin); [[ -x "$bin" ]] || return 1
    stats=$("$bin" api statsquery --server="$SINGBOX_API_ADDR" -pattern "user>>>${username}>>>traffic" 2>/dev/null) || return 1
    up=$(echo "$stats" | jq -r --arg n "user>>>${username}>>>traffic>>>uplink" '[.stat[]? | select(.name==$n) | .value] | add // 0')
    down=$(echo "$stats" | jq -r --arg n "user>>>${username}>>>traffic>>>downlink" '[.stat[]? | select(.name==$n) | .value] | add // 0')
    [[ "$up" =~ ^[0-9]+$ && "$down" =~ ^[0-9]+$ ]] || return 1
    echo $((up + down))
}

update_user_traffic_usage() (
    local uuid=$1 username raw state last total delta now users new_state gb user_lock_fd counter_lock_fd
    exec {user_lock_fd}>"${USERS_FILE}.lock" || return 1
    exec {counter_lock_fd}>"${TRAFFIC_COUNTERS_FILE}.lock" || return 1
    if command -v flock >/dev/null 2>&1; then
        flock -x "$user_lock_fd" || return 1
        flock -x "$counter_lock_fd" || return 1
    fi
    username=$(get_user_email_from_config "$uuid"); [[ -n "$username" ]] || return 1
    raw=$(query_user_raw_traffic "$username") || return 1
    [[ -f "$TRAFFIC_COUNTERS_FILE" ]] || atomic_write_json "$TRAFFIC_COUNTERS_FILE" '{"users":{}}'
    state=$(cat "$TRAFFIC_COUNTERS_FILE")
    last=$(echo "$state" | jq -r --arg id "$uuid" '.users[$id].last_raw // 0'); total=$(echo "$state" | jq -r --arg id "$uuid" '.users[$id].total_bytes // 0')
    if [[ "$raw" -ge "$last" ]]; then delta=$((raw-last)); else delta=$raw; fi
    total=$((total+delta)); now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    new_state=$(echo "$state" | jq --arg id "$uuid" --argjson raw "$raw" --argjson total "$total" --arg now "$now" --argjson changed "$([[ "$delta" -gt 0 ]] && echo true || echo false)" \
        '.users[$id] = ((.users[$id] // {}) + {last_raw:$raw,total_bytes:$total,last_seen:$now} + (if $changed then {last_change:$now} else {} end))') || return 1
    atomic_write_json "$TRAFFIC_COUNTERS_FILE" "$new_state" || return 1
    gb=$(awk -v b="$total" 'BEGIN {printf "%.3f", b/1073741824}')
    users=$(jq --arg id "$uuid" --arg used "$gb" '(.users[] | select(.id==$id) | .traffic_used_gb)=$used' "$USERS_FILE") || return 1
    atomic_write_json "$USERS_FILE" "$users" || return 1
    echo "$gb"
)

get_user_traffic_summary() {
    local username=$1 raw
    raw=$(query_user_raw_traffic "$username") || { echo N/A; return; }
    awk -v b="$raw" 'BEGIN {printf "%.2f MB", b/1048576}'
}

reload_users_transactionally() {
    generate_singbox_config || return 1
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        restart_sing-box
    else
        commit_data_transaction
    fi
}

api_disable_user() {
    local uuid="${1:-}" data
    [[ -n "$uuid" ]] || { print_error "api_disable_user 缺少用户 UUID"; return 1; }
    jq -e --arg id "$uuid" '.users | any(.id == $id)' "$USERS_FILE" >/dev/null 2>&1 || {
        print_error "用户不存在: $uuid"
        return 1
    }
    begin_data_transaction || return 1
    data=$(jq --arg id "$uuid" '(.users[] | select(.id==$id) | .enabled)=false' "$USERS_FILE") || { rollback_data_transaction; return 1; }
    atomic_write_json "$USERS_FILE" "$data" && reload_users_transactionally || { rollback_data_transaction; return 1; }
}

api_enable_user() {
    local uuid="${1:-}" data
    [[ -n "$uuid" ]] || { print_error "api_enable_user 缺少用户 UUID"; return 1; }
    jq -e --arg id "$uuid" '.users | any(.id == $id)' "$USERS_FILE" >/dev/null 2>&1 || {
        print_error "用户不存在: $uuid"
        return 1
    }
    begin_data_transaction || return 1
    data=$(jq --arg id "$uuid" '(.users[] | select(.id==$id) | .enabled)=true' "$USERS_FILE") || { rollback_data_transaction; return 1; }
    atomic_write_json "$USERS_FILE" "$data" && reload_users_transactionally || { rollback_data_transaction; return 1; }
}

api_add_user() {
    local inbound_tag="${1:-}" user_json="${2:-}" port identity user_id
    [[ -n "$inbound_tag" && -n "$user_json" ]] || { print_error "api_add_user 缺少 inbound_tag 或用户 JSON"; return 1; }
    echo "$user_json" | jq -e . >/dev/null 2>&1 || { print_error "api_add_user 用户 JSON 无效"; return 1; }
    port=${inbound_tag##*-}
    identity=$(echo "$user_json" | jq -r '.id // .uuid // .email // .name // .username // empty')
    user_id=$(jq -r --arg key "$identity" '.users[] | select(.id==$key or .email==$key or .username==$key) | .id' "$USERS_FILE" 2>/dev/null | head -1)
    [[ -n "$user_id" ]] || { print_error "用户尚未写入 users.json，拒绝仅修改运行时 API"; return 1; }
    jq -e --arg port "$port" --arg id "$user_id" '.bindings[] | select((.port|tostring)==$port and ((.users // []) | index($id)))' "$NODE_USERS_FILE" >/dev/null 2>&1 || {
        print_error "用户尚未持久化绑定到 $inbound_tag"
        return 1
    }
    reload_users_transactionally
}

api_remove_user() {
    local inbound_tag="${1:-}" identity="${2:-}" port user_id still_active
    [[ -n "$inbound_tag" && -n "$identity" ]] || { print_error "api_remove_user 缺少 inbound_tag 或用户标识"; return 1; }
    port=${inbound_tag##*-}
    user_id=$(jq -r --arg key "$identity" '.users[] | select(.id==$key or .email==$key or .username==$key) | .id' "$USERS_FILE" 2>/dev/null | head -1)
    if [[ -n "$user_id" ]]; then
        still_active=$(jq -r --arg id "$user_id" '.users[] | select(.id==$id) | (.enabled // true)' "$USERS_FILE")
        if [[ "$still_active" == true ]] && jq -e --arg port "$port" --arg id "$user_id" '.bindings[] | select((.port|tostring)==$port and ((.users // []) | index($id)))' "$NODE_USERS_FILE" >/dev/null 2>&1; then
            print_error "用户仍处于启用和绑定状态，请先更新持久化数据"
            return 1
        fi
    fi
    reload_users_transactionally
}

list_outbounds() {
    init_outbound_file
    local index=1 outbound
    while IFS= read -r outbound; do
        printf '[%d] %s (%s) %s:%s\n' "$index" "$(echo "$outbound" | jq -r '.tag')" "$(echo "$outbound" | jq -r '.type')" "$(echo "$outbound" | jq -r '.server // "N/A"')" "$(echo "$outbound" | jq -r '.server_port // "N/A"')"
        ((index++))
    done < <(jq -c '.outbounds[]' "$OUTBOUND_FILE")
}

apply_outbound_changes() {
    if ! generate_singbox_config || ! restart_sing-box; then
        print_error "出站变更应用失败，数据和配置已回滚"
        return 1
    fi
}

modify_outbound_server() {
    local index=$1 tag=$2 protocol=$3 current_address current_port address port data
    current_address=$(jq -r ".outbounds[$((index-1))].server // \"\"" "$OUTBOUND_FILE"); current_port=$(jq -r ".outbounds[$((index-1))].server_port // 0" "$OUTBOUND_FILE")
    read -p "服务器地址 [$current_address]: " address; address=${address:-$current_address}
    read -p "端口 [$current_port]: " port; port=${port:-$current_port}
    [[ "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]] || return 1
    data=$(jq --argjson i "$((index-1))" --arg address "$address" --argjson port "$port" '.outbounds[$i].server=$address | .outbounds[$i].server_port=$port' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" && apply_outbound_changes
}

modify_outbound_auth() {
    local index=$1 tag=$2 protocol=$3 username="" password data
    case "$protocol" in http|socks|naive) read -p "用户名: " username ;; esac
    read -p "密码: " password
    data=$(jq --argjson i "$((index-1))" --arg u "$username" --arg p "$password" '.outbounds[$i].password=$p | if $u != "" then .outbounds[$i].username=$u else . end' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" && apply_outbound_changes
}

migrate_outbounds_114() {
    local file=$1 data
    data=$(jq '
      def compact_object:
        with_entries(select(.value != null and .value != ""));
      def legacy_transport:
        (.streamSettings // {}) as $stream |
        ($stream.network // "tcp") as $network |
        if $network == "ws" then
          {transport: ({type:"ws",path:($stream.wsSettings.path // "/")} +
            (if (($stream.wsSettings.headers // {}) | length) > 0 then {headers:$stream.wsSettings.headers} else {} end))}
        elif $network == "grpc" then
          {transport:{type:"grpc",service_name:($stream.grpcSettings.serviceName // "grpc")}}
        elif ($network == "h2" or $network == "http") then
          {transport: ({type:"http",path:($stream.httpSettings.path // "/")} +
            (if (($stream.httpSettings.host // []) | length) > 0 then {host:$stream.httpSettings.host} else {} end))}
        elif $network == "httpupgrade" then
          {transport: ({type:"httpupgrade",path:($stream.httpupgradeSettings.path // "/")} +
            (if ($stream.httpupgradeSettings.host // "") != "" then {host:$stream.httpupgradeSettings.host} else {} end))}
        elif $network == "quic" then
          {transport:{type:"quic"}}
        else {} end;
      def legacy_tls:
        (.streamSettings // {}) as $stream |
        ($stream.security // "none") as $security |
        if $security == "tls" then
          {tls: ({enabled:true,
                  server_name:($stream.tlsSettings.serverName // ""),
                  insecure:($stream.tlsSettings.allowInsecure // false)} +
                 (if (($stream.tlsSettings.alpn // []) | length) > 0 then {alpn:$stream.tlsSettings.alpn} else {} end) |
                 compact_object)}
        elif $security == "reality" then
          {tls:{enabled:true,
                server_name:($stream.realitySettings.serverName // ""),
                reality:{enabled:true,
                         public_key:($stream.realitySettings.publicKey // ""),
                         short_id:($stream.realitySettings.shortId // "")},
                utls:{enabled:true,fingerprint:($stream.realitySettings.fingerprint // "chrome")}}}
        else {} end;
      .outbounds = ((.outbounds // []) | map(
        if (.settings? != null) then
          . as $o |
          (.type // .protocol) as $legacy_type |
          (if $legacy_type == "freedom" then "direct" elif $legacy_type == "blackhole" then "block" else $legacy_type end) as $type |
          ({type:$type,tag:.tag} +
           (if (."settings"."vnext"[0]? != null) then
              (."settings"."vnext"[0] as $server |
               $server.users[0] as $user |
               {server:$server.address,server_port:$server.port,uuid:$user.id} +
               (if $type == "vmess" then
                  {security:($user.security // "auto"),alter_id:($user.alterId // 0)}
                else
                  {flow:($user.flow // "")}
                end))
            elif (."settings"."servers"[0]? != null) then
              (."settings"."servers"[0] as $server |
               {server:($server.address // $o.server),server_port:($server.port // $o.server_port),
                username:($server.users[0].user // $o.username),
                password:($server.users[0].pass // $server.password // $o.password),
                method:($server.method // $o.method),version:($server.version // $o.version)})
            else
              {server:$o.server,server_port:$o.server_port,uuid:$o.uuid,
               username:$o.username,password:$o.password,method:$o.method} +
              (if $type == "vmess" then
                 {security:($o.security // "auto"),alter_id:($o.alter_id // $o.alterId // 0)}
               elif $type == "vless" then {flow:$o.flow}
               else {} end)
            end) +
           ($o | legacy_tls) +
           ($o | legacy_transport) +
           (if ($o.mux.enabled // false) then {multiplex:{enabled:true}} else {} end) |
           compact_object)
        else
          . as $o |
          ((.type = (.type // .protocol) | del(.protocol,.streamSettings,.mux)) +
           (if ($o.streamSettings? != null) then ($o | legacy_tls) + ($o | legacy_transport) else {} end) +
           (if ($o.mux.enabled // false) then {multiplex:{enabled:true}} else {} end))
        end
      )) |
      .endpoints = (.endpoints // [])
      ' "$file") || return 1
    atomic_write_json "$file" "$data"
}

save_flat_outbound() {
    local outbound=$1 data
    init_outbound_file
    data=$(jq --argjson o "$outbound" '.outbounds = ([.outbounds[] | select(.tag != $o.tag)] + [$o])' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" || return 1
    print_success "出站已保存: $(echo "$outbound" | jq -r '.tag')"
    prompt_bind_outbound_to_node "$(echo "$outbound" | jq -r '.tag')"
}

add_vless_outbound() {
    local tag server port uuid mode flow="" sni insecure=false tls transport=tcp path="" outbound t
    read -p "出站标签: " tag; [[ -n "$tag" ]] || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [443]: " port; port=${port:-443}
    read -p "UUID: " uuid; [[ -n "$uuid" ]] || return 1
    echo "1. TLS  2. Reality  3. 无 TLS"; read -p "安全模式 [1]: " mode; mode=${mode:-1}
    echo "1. TCP  2. WebSocket  3. gRPC  4. HTTP"; read -p "传输 [1]: " t; case "$t" in 2) transport=ws;; 3) transport=grpc;; 4) transport=http;; esac
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid}')
    case "$mode" in
        2)
            read -p "Reality SNI: " sni; read -p "Reality 公钥: " public_key; read -p "Reality short-id: " short_id
            outbound=$(echo "$outbound" | jq --arg sni "$sni" --arg pk "$public_key" --arg sid "$short_id" '.flow="xtls-rprx-vision" | .tls={enabled:true,server_name:$sni,reality:{enabled:true,public_key:$pk,short_id:$sid},utls:{enabled:true,fingerprint:"chrome"}}') ;;
        3) : ;;
        *) read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}; read -p "允许自签名证书? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && insecure=true
            outbound=$(echo "$outbound" | jq --arg sni "$sni" --argjson insecure "$insecure" '.tls={enabled:true,server_name:$sni,insecure:$insecure}') ;;
    esac
    if [[ "$transport" != tcp ]]; then
        read -p "传输路径/服务名: " path
        case "$transport" in ws) tls=$(jq -n --arg p "${path:-/}" '{type:"ws",path:$p}');; grpc) tls=$(jq -n --arg p "${path:-grpc}" '{type:"grpc",service_name:$p}');; http) tls=$(jq -n --arg p "${path:-/}" '{type:"http",path:$p}');; esac
        outbound=$(echo "$outbound" | jq --argjson t "$tls" '.transport=$t')
    fi
    save_flat_outbound "$outbound"
}

add_trojan_outbound() {
    local tag server port password sni insecure=false outbound
    read -p "出站标签: " tag; read -p "服务器地址: " server; read -p "端口 [443]: " port; port=${port:-443}; read -p "密码: " password
    [[ -n "$tag" && -n "$server" && -n "$password" ]] || return 1
    read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}; read -p "允许自签名证书? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && insecure=true
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" --arg sni "$sni" --argjson insecure "$insecure" '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni,insecure:$insecure}}')
    save_flat_outbound "$outbound"
}

add_naive_outbound() {
    local tag server port username password sni insecure=false outbound
    if ! singbox_has_build_tag with_naive_outbound; then
        print_error "当前定制内核不包含 with_naive_outbound，无法添加 Naive 出站"
        print_info "上游 Naive 出站需要独立 Chromium/Cronet 工具链和 libcronet.so，不属于官方本地构建能力"
        return 1
    fi
    read -p "出站标签: " tag; read -p "服务器地址: " server; read -p "端口 [443]: " port; port=${port:-443}; read -p "用户名: " username; read -p "密码: " password
    [[ -n "$tag" && -n "$server" && -n "$username" && -n "$password" ]] || return 1
    read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}; read -p "允许自签名证书? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && insecure=true
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg username "$username" --arg password "$password" --arg sni "$sni" --argjson insecure "$insecure" '{type:"naive",tag:$tag,server:$server,server_port:$port,username:$username,password:$password,tls:{enabled:true,server_name:$sni,insecure:$insecure}}')
    save_flat_outbound "$outbound"
}

add_anytls_outbound() {
    local tag server port password sni insecure=false outbound
    read -p "出站标签: " tag; read -p "服务器地址: " server; read -p "端口 [443]: " port; port=${port:-443}; read -p "密码: " password
    [[ -n "$tag" && -n "$server" && -n "$password" ]] || return 1
    read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}; read -p "允许自签名证书? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && insecure=true
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" --arg sni "$sni" --argjson insecure "$insecure" '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni,insecure:$insecure}}')
    save_flat_outbound "$outbound"
}

copy_runtime_state() {
    local destination=$1 file
    mkdir -p "$destination" || return 1
    for file in "$NODES_FILE" "$NODE_USERS_FILE" "$USERS_FILE" "${DATA_DIR}/outbounds.json" "$TRAFFIC_COUNTERS_FILE" \
        "${DATA_DIR}/subscriptions.json" "${DATA_DIR}/subscription_metadata.json" "${DATA_DIR}/port_hopping.json" \
        "${DATA_DIR}/domains.json" "${DATA_DIR}/cf_auths.json" "${DATA_DIR}/subscription_port.txt" \
        "${DATA_DIR}/default_domain.txt" "${DATA_DIR}/server_domain.txt" "${DATA_DIR}/host_domain.txt"; do
        [[ -f "$file" ]] && cp -a "$file" "$destination/$(basename "$file")"
    done
    [[ -f "$SINGBOX_CONFIG" ]] && cp -a "$SINGBOX_CONFIG" "$destination/config.json"
    if [[ -d "$SUBSCRIPTION_DIR" ]]; then
        mkdir -p "$destination/subscriptions"
        cp -a "$SUBSCRIPTION_DIR/." "$destination/subscriptions/"
    fi
}

initialize_runtime_state() {
    [[ -d "$RUNTIME_STATE_DIR" ]] && return 0
    copy_runtime_state "$RUNTIME_STATE_DIR"
}

begin_data_transaction() {
    [[ -d "$RUNTIME_TX_DIR" ]] && return 0
    if [[ -d "$RUNTIME_STATE_DIR" ]]; then
        cp -a "$RUNTIME_STATE_DIR" "$RUNTIME_TX_DIR"
    else
        copy_runtime_state "$RUNTIME_TX_DIR"
    fi
}

rollback_data_transaction() {
    local source="$RUNTIME_TX_DIR" file
    [[ -d "$source" ]] || source="$RUNTIME_STATE_DIR"
    [[ -d "$source" ]] || return 0
    for file in nodes.json node_users.json users.json outbounds.json traffic_counters.json subscriptions.json subscription_metadata.json \
        port_hopping.json domains.json cf_auths.json subscription_port.txt default_domain.txt server_domain.txt host_domain.txt; do
        if [[ -f "$source/$file" ]]; then
            cp -a "$source/$file" "${DATA_DIR}/$file" || return 1
        else
            rm -f "${DATA_DIR}/$file" || return 1
        fi
    done
    rm -rf "$SUBSCRIPTION_DIR" || return 1
    if [[ -d "$source/subscriptions" ]]; then
        mkdir -p "$SUBSCRIPTION_DIR" || return 1
        cp -a "$source/subscriptions/." "$SUBSCRIPTION_DIR/" || return 1
    fi
    if [[ -f "$source/config.json" ]]; then
        cp -a "$source/config.json" "$SINGBOX_CONFIG" || return 1
    else
        rm -f "$SINGBOX_CONFIG" || return 1
    fi
    rm -rf "$RUNTIME_TX_DIR"
    rm -f "${DATA_DIR}/.config-awaiting-activation"
}

recover_interrupted_transaction() {
    [[ -d "$RUNTIME_TX_DIR" || -f "${DATA_DIR}/.config-awaiting-activation" ]] || return 0
    if [[ ! -d "$RUNTIME_TX_DIR" && ! -d "$RUNTIME_STATE_DIR" ]]; then
        print_error "检测到待激活配置，但没有可用事务快照，拒绝自动覆盖现有数据"
        return 1
    fi
    print_warning "检测到上次未完成的配置事务，正在恢复最后可用状态"
    rollback_data_transaction || {
        print_error "未完成事务恢复失败，请检查 $RUNTIME_TX_DIR 和 $RUNTIME_STATE_DIR"
        return 1
    }
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl restart sing-box || {
            print_error "事务数据已恢复，但 sing-box 服务重启失败"
            return 1
        }
    fi
    print_success "未完成的配置事务已恢复"
}

commit_data_transaction() {
    local fresh="${RUNTIME_STATE_DIR}.new" previous="${RUNTIME_STATE_DIR}.previous"
    rm -rf "$fresh"
    copy_runtime_state "$fresh" || return 1
    rm -rf "$previous"
    [[ ! -d "$RUNTIME_STATE_DIR" ]] || mv "$RUNTIME_STATE_DIR" "$previous" || return 1
    if ! mv "$fresh" "$RUNTIME_STATE_DIR"; then
        [[ ! -d "$previous" ]] || mv "$previous" "$RUNTIME_STATE_DIR"
        return 1
    fi
    rm -rf "$previous"
    rm -rf "$RUNTIME_TX_DIR"
    rm -f "${DATA_DIR}/.config-awaiting-activation"
}

# 在配置事务提交前同步现有订阅，防止节点增删、禁用或用户解绑后继续分发旧节点。
sync_runtime_subscriptions() {
    local meta_file="${DATA_DIR}/subscription_metadata.json" user_id port active
    [[ -f "$meta_file" ]] || return 0
    declare -f update_user_subscriptions >/dev/null 2>&1 || return 0
    declare -f remove_user_subscriptions_by_id >/dev/null 2>&1 || return 0

    while IFS= read -r user_id; do
        [[ -n "$user_id" ]] || continue
        if ! jq -e --arg id "$user_id" '.users[] | select(.id == $id)' "$USERS_FILE" >/dev/null 2>&1; then
            remove_user_subscriptions_by_id "$user_id" || return 1
            continue
        fi

        active=false
        while IFS= read -r port; do
            [[ -n "$port" ]] || continue
            if jq -e --arg port "$port" '.nodes[] | select((.port|tostring) == $port and (.enabled // true) == true)' "$NODES_FILE" >/dev/null 2>&1; then
                active=true
                break
            fi
        done < <(jq -r --arg id "$user_id" '.bindings[] | select((.users // []) | index($id)) | (.port|tostring)' "$NODE_USERS_FILE" 2>/dev/null)

        if [[ "$active" == true ]]; then
            update_user_subscriptions "$user_id" || return 1
        else
            remove_user_subscriptions_by_id "$user_id" || return 1
        fi
    done < <(jq -r '[.subscriptions[].user_id] | unique[]?' "$meta_file" 2>/dev/null)
}

save_node_info() {
    local protocol=$1 port=$2 transport=$3 security=$4 extra=$5 name=${6:-"${1}-${2}"} data node
    begin_data_transaction || return 1
    node=$(jq -n --arg name "$name" --arg protocol "$protocol" --arg port "$port" --arg transport "$transport" --arg security "$security" --argjson extra "$extra" \
        '{name:$name,protocol:$protocol,port:$port,transport:$transport,security:$security,extra:$extra,created:(now|todate)}') || { rollback_data_transaction; return 1; }
    data=$(jq --arg port "$port" --argjson node "$node" '.nodes = ([.nodes[] | select((.port|tostring) != $port)] + [$node])' "$NODES_FILE") || { rollback_data_transaction; return 1; }
    atomic_write_json "$NODES_FILE" "$data" || { rollback_data_transaction; return 1; }
}

generate_singbox_config() {
    begin_data_transaction || {
        print_error "无法创建配置事务快照"
        return 1
    }
    if _generate_singbox_config_114; then
        : > "${DATA_DIR}/.config-awaiting-activation"
        return 0
    fi
    rollback_data_transaction
    print_error "配置生成失败，数据文件已自动回滚"
    return 1
}

socket_listens_on_port() {
    local port="$1" network="$2" output=""
    if command -v ss >/dev/null 2>&1; then
        case "$network" in
            tcp) output=$(ss -H -ltn 2>/dev/null) ;;
            udp) output=$(ss -H -lun 2>/dev/null) ;;
            both)
                socket_listens_on_port "$port" tcp && socket_listens_on_port "$port" udp
                return $?
                ;;
            *) return 1 ;;
        esac
    elif command -v netstat >/dev/null 2>&1; then
        case "$network" in
            tcp) output=$(netstat -ltn 2>/dev/null) ;;
            udp) output=$(netstat -lun 2>/dev/null) ;;
            both)
                socket_listens_on_port "$port" tcp && socket_listens_on_port "$port" udp
                return $?
                ;;
            *) return 1 ;;
        esac
    else
        return 2
    fi
    awk -v port="$port" '{address=$4; sub(/^.*:/,"",address); if (address == port) found=1} END {exit !found}' <<< "$output"
}

verify_configured_inbound_listeners() {
    [[ -f "$SINGBOX_CONFIG" ]] || return 1
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        print_warning "缺少 ss/netstat，无法执行节点端口监听自检"
        return 0
    fi

    local attempt port type network missing
    for attempt in 1 2 3 4 5; do
        missing=""
        while IFS=$'\t' read -r port type; do
            type=${type%$'\r'}
            [[ -n "$port" ]] || continue
            case "$type" in
                hysteria|hysteria2|tuic) network="udp" ;;
                naive|shadowsocks) network="both" ;;
                *) network="tcp" ;;
            esac
            socket_listens_on_port "$port" "$network" || missing+=" ${port}/${network}"
        done < <(jq -r '.inbounds[]? | [(.listen_port|tostring), .type] | @tsv' "$SINGBOX_CONFIG" 2>/dev/null)
        [[ -z "$missing" ]] && return 0
        [[ "$attempt" -lt 5 ]] && sleep 1
    done
    print_error "以下节点端口未监听:${missing}"
    return 1
}

restart_sing-box() {
    print_info "重启 sing-box..."
    if [[ -f "${DATA_DIR}/.config-awaiting-activation" ]] && ! sync_runtime_subscriptions; then
        print_error "订阅同步失败，正在恢复旧配置和数据"
        rollback_data_transaction
        return 1
    fi
    if systemctl restart sing-box && { sleep 2; systemctl is-active --quiet sing-box; }; then
        if ! verify_configured_inbound_listeners; then
            print_error "sing-box 进程存活，但节点监听未就绪，正在恢复旧配置"
            rollback_data_transaction
            systemctl restart sing-box 2>/dev/null || true
            return 1
        fi
        if declare -f sync_active_node_firewall_ports >/dev/null 2>&1 \
            && ! sync_active_node_firewall_ports; then
            print_error "节点端口自动放行失败，正在恢复旧配置"
            rollback_data_transaction
            systemctl restart sing-box 2>/dev/null || true
            return 1
        fi
        if ! commit_data_transaction; then
            print_error "服务已启动，但事务快照提交失败，正在恢复旧配置和数据"
            rollback_data_transaction || print_error "事务回滚失败，请立即检查 $RUNTIME_TX_DIR 和 $RUNTIME_STATE_DIR"
            systemctl restart sing-box 2>/dev/null || true
            systemctl is-active --quiet sing-box 2>/dev/null || print_error "快照提交失败后服务未恢复，请检查 journalctl -u sing-box"
            return 1
        fi
        print_success "sing-box 重启成功"
        print_info "节点监听与本机防火墙已检查"
        if declare -f print_required_cloud_firewall_ports >/dev/null 2>&1; then
            print_required_cloud_firewall_ports
        else
            print_info "云服务器安全组仍需放行对应 TCP/UDP 端口"
        fi
        return 0
    fi

    print_error "sing-box 重启失败，正在恢复最后可用配置和数据"
    rollback_data_transaction
    systemctl restart sing-box 2>/dev/null || true
    systemctl is-active --quiet sing-box 2>/dev/null || print_error "回滚后服务仍未恢复，请检查 journalctl -u sing-box"
    return 1
}
