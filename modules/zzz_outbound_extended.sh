#!/bin/bash

# sing-box 1.14+ 出站扩展与统一管理层。
# 本模块按文件名最后加载，用于覆盖旧版 outbound.sh 中的 Xray 字段和仅-outbound 假设。

if [[ -n "${OUTBOUND_EXTENDED_MODULE_LOADED:-}" ]]; then
    return 0
fi
OUTBOUND_EXTENDED_MODULE_LOADED=1

OUTBOUND_FILE="${DATA_DIR}/outbounds.json"

init_outbound_file() {
    local data
    if [[ ! -f "$OUTBOUND_FILE" ]]; then
        atomic_write_json "$OUTBOUND_FILE" '{"outbounds":[],"endpoints":[]}'
        return
    fi
    if declare -f migrate_outbounds_114 >/dev/null 2>&1; then
        migrate_outbounds_114 "$OUTBOUND_FILE" || return 1
    fi
    data=$(jq '.outbounds = (.outbounds // []) | .endpoints = (.endpoints // [])' "$OUTBOUND_FILE") || {
        print_error "出站库 JSON 无效: $OUTBOUND_FILE"
        return 1
    }
    atomic_write_json "$OUTBOUND_FILE" "$data"
}

outbound_tag_exists() {
    local tag=$1
    jq -e --arg tag "$tag" '((.outbounds // []) + (.endpoints // []))[] | select(.tag == $tag)' "$OUTBOUND_FILE" >/dev/null 2>&1
}

validate_new_outbound_tag() {
    local tag=$1
    [[ -n "$tag" && "$tag" != *$'\n'* && "$tag" != *$'\r'* ]] || {
        print_error "标签不能为空或包含换行符"
        return 1
    }
    case "$tag" in
        direct-out|warp-ep)
            print_error "标签 '$tag' 为系统保留标签"
            return 1
            ;;
    esac
    if outbound_tag_exists "$tag"; then
        print_error "标签 '$tag' 已存在（outbound 与 endpoint 共用标签空间）"
        return 1
    fi
}

validate_port_value() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]
}

csv_to_json_array() {
    local value=$1
    jq -cn --arg value "$value" '$value | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique'
}

save_flat_outbound() {
    local outbound=$1 tag data
    init_outbound_file || return 1
    tag=$(echo "$outbound" | jq -r '.tag // empty')
    echo "$outbound" | jq -e 'type == "object" and (.type | type == "string") and (.tag | type == "string")' >/dev/null || {
        print_error "出站 JSON 缺少 type/tag"
        return 1
    }
    validate_new_outbound_tag "$tag" || return 1
    data=$(jq --argjson outbound "$outbound" '.outbounds += [$outbound]' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" || return 1
    print_success "出站已保存: $tag"
    prompt_bind_outbound_to_node "$tag"
}

save_flat_endpoint() {
    local endpoint=$1 tag data
    init_outbound_file || return 1
    tag=$(echo "$endpoint" | jq -r '.tag // empty')
    echo "$endpoint" | jq -e 'type == "object" and (.type | type == "string") and (.tag | type == "string")' >/dev/null || {
        print_error "Endpoint JSON 缺少 type/tag"
        return 1
    }
    validate_new_outbound_tag "$tag" || return 1
    data=$(jq --argjson endpoint "$endpoint" '.endpoints += [$endpoint]' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" || return 1
    print_success "Endpoint 已保存: $tag"
    prompt_bind_outbound_to_node "$tag"
}

add_hysteria_outbound() {
    local tag server port port_ranges up down auth obfs sni insecure=false answer outbound tls
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || { print_error "服务器地址不能为空"; return 1; }
    read -p "端口 [443]: " port; port=${port:-443}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "端口跳跃范围（逗号分隔，如 20000:21000；留空禁用）: " port_ranges
    read -p "上行带宽 [100 Mbps]: " up; up=${up:-100 Mbps}
    read -p "下行带宽 [100 Mbps]: " down; down=${down:-100 Mbps}
    read -p "认证密码: " auth; [[ -n "$auth" ]] || { print_error "认证密码不能为空"; return 1; }
    read -p "混淆密码（可留空）: " obfs
    read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}
    read -p "允许不安全证书? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && insecure=true
    tls=$(jq -n --arg sni "$sni" --argjson insecure "$insecure" '{enabled:true,server_name:$sni,insecure:$insecure}')
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg up "$up" --arg down "$down" --arg auth "$auth" --arg obfs "$obfs" --argjson tls "$tls" '
      {type:"hysteria",tag:$tag,server:$server,server_port:$port,up:$up,down:$down,auth_str:$auth,tls:$tls} |
      if $obfs != "" then .obfs=$obfs else . end') || return 1
    if [[ -n "$port_ranges" ]]; then
        local ranges
        ranges=$(csv_to_json_array "$port_ranges") || return 1
        outbound=$(echo "$outbound" | jq --argjson ranges "$ranges" 'del(.server_port) | .server_ports=$ranges | .hop_interval="30s"') || return 1
    fi
    save_flat_outbound "$outbound"
}

add_shadowtls_outbound() {
    local tag server port version password="" sni insecure=false answer outbound
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [443]: " port; port=${port:-443}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "ShadowTLS 版本 [3]（1/2/3）: " version; version=${version:-3}
    [[ "$version" =~ ^[123]$ ]] || { print_error "版本只能是 1、2 或 3"; return 1; }
    [[ "$version" == 1 ]] || { read -p "密码: " password; [[ -n "$password" ]] || { print_error "v2/v3 必须填写密码"; return 1; }; }
    read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}
    read -p "允许不安全证书? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && insecure=true
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --argjson version "$version" --arg password "$password" --arg sni "$sni" --argjson insecure "$insecure" '
      {type:"shadowtls",tag:$tag,server:$server,server_port:$port,version:$version,tls:{enabled:true,server_name:$sni,insecure:$insecure}} |
      if $password != "" then .password=$password else . end') || return 1
    save_flat_outbound "$outbound"
}

add_ssh_outbound() {
    local tag server port user auth_mode password="" key_path="" passphrase="" host_keys outbound keys
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "SSH 服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [22]: " port; port=${port:-22}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "SSH 用户 [root]: " user; user=${user:-root}
    echo "1. 密码认证  2. 私钥文件"
    read -p "认证方式 [1]: " auth_mode; auth_mode=${auth_mode:-1}
    case "$auth_mode" in
        1) read -p "SSH 密码: " password; [[ -n "$password" ]] || return 1 ;;
        2) read -p "私钥路径: " key_path; [[ -n "$key_path" ]] || return 1; read -p "私钥口令（可留空）: " passphrase ;;
        *) print_error "认证方式无效"; return 1 ;;
    esac
    read -p "固定主机公钥（多个用逗号分隔，留空接受所有）: " host_keys
    keys=$(csv_to_json_array "$host_keys") || return 1
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg user "$user" --arg password "$password" --arg key "$key_path" --arg passphrase "$passphrase" --argjson keys "$keys" '
      {type:"ssh",tag:$tag,server:$server,server_port:$port,user:$user} |
      if $password != "" then .password=$password else .private_key_path=$key | if $passphrase != "" then .private_key_passphrase=$passphrase else . end end |
      if ($keys|length)>0 then .host_key=$keys else . end') || return 1
    save_flat_outbound "$outbound"
}

add_snell_outbound() {
    local tag server port version psk userkey reuse=false answer network extra outbound
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [443]: " port; port=${port:-443}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "Snell 版本 [4]（4/6）: " version; version=${version:-4}; [[ "$version" == 4 || "$version" == 6 ]] || { print_error "仅支持 v4/v6"; return 1; }
    read -p "PSK: " psk; [[ -n "$psk" ]] || return 1
    if [[ "$version" == 6 && ${#psk} -lt 12 ]]; then print_error "Snell v6 PSK 至少 12 字节"; return 1; fi
    read -p "User Key（可留空）: " userkey
    read -p "启用连接复用? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && reuse=true
    read -p "网络（tcp/udp，留空表示全部）: " network; [[ -z "$network" || "$network" == tcp || "$network" == udp ]] || { print_error "网络类型无效"; return 1; }
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --argjson version "$version" --arg psk "$psk" --arg userkey "$userkey" --argjson reuse "$reuse" --arg network "$network" '
      {type:"snell",tag:$tag,server:$server,server_port:$port,version:$version,psk:$psk,reuse:$reuse} |
      if $userkey != "" then .userkey=$userkey else . end | if $network != "" then .network=$network else . end') || return 1
    if [[ "$version" == 4 ]]; then
        read -p "HTTP 混淆模式 [none]（none/http）: " extra; extra=${extra:-none}; [[ "$extra" == none || "$extra" == http ]] || return 1
        outbound=$(echo "$outbound" | jq --arg mode "$extra" '.obfs_mode=$mode')
        if [[ "$extra" == http ]]; then read -p "混淆 Host [bing.com]: " extra; extra=${extra:-bing.com}; outbound=$(echo "$outbound" | jq --arg host "$extra" '.obfs_host=$host'); fi
    else
        read -p "流量整形 [default]（default/unshaped/unsafe-raw）: " extra; extra=${extra:-default}
        [[ "$extra" == default || "$extra" == unshaped || "$extra" == unsafe-raw ]] || return 1
        outbound=$(echo "$outbound" | jq --arg mode "$extra" '.mode=$mode')
    fi
    save_flat_outbound "$outbound"
}

add_tor_outbound() {
    local tag executable data_directory extra_args args outbound
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "Tor 可执行文件 [/usr/bin/tor]: " executable; executable=${executable:-/usr/bin/tor}
    read -p "Tor 数据目录 [/var/lib/sing-box/tor/$tag]: " data_directory; data_directory=${data_directory:-/var/lib/sing-box/tor/$tag}
    read -p "额外启动参数（逗号分隔，可留空）: " extra_args
    args=$(csv_to_json_array "$extra_args") || return 1
    outbound=$(jq -n --arg tag "$tag" --arg executable "$executable" --arg directory "$data_directory" --argjson args "$args" '
      {type:"tor",tag:$tag,executable_path:$executable,data_directory:$directory,torrc:{ClientOnly:1}} |
      if ($args|length)>0 then .extra_args=$args else . end') || return 1
    print_warning "Tor 出站依赖目标系统已安装 tor；脚本不会自动修改系统 Tor 配置"
    save_flat_outbound "$outbound"
}

add_wireguard_endpoint() {
    local tag addresses private_key peer_address peer_port public_key psk allowed reserved mtu keepalive endpoint address_json allowed_json reserved_json
    read -p "Endpoint 标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "本地地址/CIDR（逗号分隔）: " addresses; address_json=$(csv_to_json_array "$addresses"); [[ $(echo "$address_json" | jq length) -gt 0 ]] || { print_error "至少需要一个本地地址"; return 1; }
    read -p "WireGuard 私钥（base64）: " private_key; [[ -n "$private_key" ]] || return 1
    read -p "Peer 地址: " peer_address; [[ -n "$peer_address" ]] || return 1
    read -p "Peer 端口 [51820]: " peer_port; peer_port=${peer_port:-51820}; validate_port_value "$peer_port" || { print_error "端口无效"; return 1; }
    read -p "Peer 公钥（base64）: " public_key; [[ -n "$public_key" ]] || return 1
    read -p "预共享密钥（可留空）: " psk
    read -p "Allowed IPs [0.0.0.0/0,::/0]: " allowed; allowed=${allowed:-0.0.0.0/0,::/0}; allowed_json=$(csv_to_json_array "$allowed")
    read -p "Reserved 字节 [0,0,0]: " reserved; reserved=${reserved:-0,0,0}
    reserved_json=$(csv_to_json_array "$reserved" | jq 'map(tonumber)') || { print_error "Reserved 必须是数字"; return 1; }
    echo "$reserved_json" | jq -e 'length == 3 and all(. >= 0 and . <= 255)' >/dev/null || { print_error "Reserved 必须是 3 个 0-255 字节"; return 1; }
    read -p "MTU [1408]: " mtu; mtu=${mtu:-1408}; [[ "$mtu" =~ ^[0-9]+$ && "$mtu" -ge 576 && "$mtu" -le 9000 ]] || { print_error "MTU 无效"; return 1; }
    read -p "Persistent Keepalive 秒数 [0]: " keepalive; keepalive=${keepalive:-0}; [[ "$keepalive" =~ ^[0-9]+$ ]] || return 1
    endpoint=$(jq -n --arg tag "$tag" --argjson address "$address_json" --arg private "$private_key" --arg peer "$peer_address" --argjson port "$peer_port" --arg public "$public_key" --arg psk "$psk" --argjson allowed "$allowed_json" --argjson reserved "$reserved_json" --argjson mtu "$mtu" --argjson keepalive "$keepalive" '
      {type:"wireguard",tag:$tag,mtu:$mtu,address:$address,private_key:$private,peers:[{address:$peer,port:$port,public_key:$public,allowed_ips:$allowed,reserved:$reserved}]} |
      if $psk != "" then .peers[0].pre_shared_key=$psk else . end |
      if $keepalive > 0 then .peers[0].persistent_keepalive_interval=$keepalive else . end') || return 1
    save_flat_endpoint "$endpoint"
}

add_http_outbound() {
    local tag server port tls_enabled username password sni insecure=false answer outbound
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [3128]: " port; port=${port:-3128}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "用户名（无认证可留空）: " username
    if [[ -n "$username" ]]; then read -p "密码: " password; [[ -n "$password" ]] || return 1; else password=""; fi
    read -p "启用 HTTPS 代理 TLS? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && tls_enabled=true || tls_enabled=false
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg username "$username" --arg password "$password" '{type:"http",tag:$tag,server:$server,server_port:$port} | if $username!="" then .username=$username | .password=$password else . end') || return 1
    if [[ "$tls_enabled" == true ]]; then
        read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}; read -p "允许不安全证书? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && insecure=true
        outbound=$(echo "$outbound" | jq --arg sni "$sni" --argjson insecure "$insecure" '.tls={enabled:true,server_name:$sni,insecure:$insecure}') || return 1
    fi
    save_flat_outbound "$outbound"
}

add_socks_outbound() {
    local tag server port version username password outbound
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [1080]: " port; port=${port:-1080}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "SOCKS 版本 [5]（4/4a/5）: " version; version=${version:-5}; [[ "$version" == 4 || "$version" == 4a || "$version" == 5 ]] || return 1
    read -p "用户名（无认证可留空）: " username
    if [[ -n "$username" ]]; then read -p "密码: " password; [[ -n "$password" ]] || return 1; else password=""; fi
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg version "$version" --arg username "$username" --arg password "$password" '{type:"socks",tag:$tag,server:$server,server_port:$port,version:$version} | if $username!="" then .username=$username | .password=$password else . end') || return 1
    save_flat_outbound "$outbound"
}

add_vmess_outbound() {
    local tag server port uuid security transport_choice transport=tcp path="" host="" tls_enabled=false sni insecure=false answer outbound transport_json
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [443]: " port; port=${port:-443}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "UUID: " uuid; [[ -n "$uuid" ]] || return 1
    read -p "加密 [auto]: " security; security=${security:-auto}
    echo "1.TCP  2.WebSocket  3.gRPC  4.HTTP"
    read -p "传输 [1]: " transport_choice; transport_choice=${transport_choice:-1}
    case "$transport_choice" in 1) transport=tcp ;; 2) transport=ws ;; 3) transport=grpc ;; 4) transport=http ;; *) return 1 ;; esac
    read -p "启用 TLS? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && tls_enabled=true
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg security "$security" '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:$security,alter_id:0}') || return 1
    if [[ "$transport" != tcp ]]; then
        read -p "路径/服务名: " path
        case "$transport" in
            ws) read -p "WebSocket Host（可留空）: " host; transport_json=$(jq -n --arg path "${path:-/}" --arg host "$host" '{type:"ws",path:$path} | if $host!="" then .headers={Host:$host} else . end') ;;
            grpc) transport_json=$(jq -n --arg service "${path:-grpc}" '{type:"grpc",service_name:$service}') ;;
            http) read -p "HTTP Host（可留空）: " host; transport_json=$(jq -n --arg path "${path:-/}" --arg host "$host" '{type:"http",path:$path} | if $host!="" then .host=[$host] else . end') ;;
        esac
        outbound=$(echo "$outbound" | jq --argjson transport "$transport_json" '.transport=$transport') || return 1
    fi
    if [[ "$tls_enabled" == true ]]; then
        read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}; read -p "允许不安全证书? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && insecure=true
        outbound=$(echo "$outbound" | jq --arg sni "$sni" --argjson insecure "$insecure" '.tls={enabled:true,server_name:$sni,insecure:$insecure}') || return 1
    fi
    save_flat_outbound "$outbound"
}

add_shadowsocks_outbound() {
    local tag server port method password network outbound
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [8388]: " port; port=${port:-8388}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    echo "常用方法: 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm / aes-256-gcm / chacha20-ietf-poly1305"
    read -p "加密方法: " method; [[ -n "$method" ]] || return 1
    read -p "密码/SS2022 密钥: " password; [[ -n "$password" ]] || return 1
    read -p "网络（tcp/udp，留空表示全部）: " network; [[ -z "$network" || "$network" == tcp || "$network" == udp ]] || return 1
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg method "$method" --arg password "$password" --arg network "$network" '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:$password} | if $network!="" then .network=$network else . end') || return 1
    save_flat_outbound "$outbound"
}

add_hysteria2_outbound() {
    local tag server port port_ranges password obfs sni insecure=false answer outbound ranges
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [443]: " port; port=${port:-443}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "端口跳跃范围（逗号分隔，留空禁用）: " port_ranges
    read -p "密码: " password; [[ -n "$password" ]] || return 1
    read -p "Salamander 混淆密码（可留空）: " obfs
    read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}; read -p "允许不安全证书? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && insecure=true
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" --arg obfs "$obfs" --arg sni "$sni" --argjson insecure "$insecure" '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni,insecure:$insecure}} | if $obfs!="" then .obfs={type:"salamander",password:$obfs} else . end') || return 1
    if [[ -n "$port_ranges" ]]; then ranges=$(csv_to_json_array "$port_ranges"); outbound=$(echo "$outbound" | jq --argjson ranges "$ranges" 'del(.server_port) | .server_ports=$ranges | .hop_interval="30s"'); fi
    save_flat_outbound "$outbound"
}

add_tuic_outbound() {
    local tag server port uuid password cc zero_rtt=false answer sni insecure=false outbound
    read -p "出站标签: " tag; validate_new_outbound_tag "$tag" || return 1
    read -p "服务器地址: " server; [[ -n "$server" ]] || return 1
    read -p "端口 [443]: " port; port=${port:-443}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    read -p "UUID: " uuid; [[ -n "$uuid" ]] || return 1
    read -p "密码: " password; [[ -n "$password" ]] || return 1
    read -p "拥塞控制 [cubic]: " cc; cc=${cc:-cubic}
    read -p "启用 0-RTT? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && zero_rtt=true
    read -p "TLS SNI [$server]: " sni; sni=${sni:-$server}; read -p "允许不安全证书? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && insecure=true
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --arg cc "$cc" --argjson zero "$zero_rtt" --arg sni "$sni" --argjson insecure "$insecure" '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$password,congestion_control:$cc,zero_rtt_handshake:$zero,tls:{enabled:true,server_name:$sni,insecure:$insecure}}') || return 1
    save_flat_outbound "$outbound"
}

available_strategy_tags() {
    local exclude=${1:-}
    jq -r --arg exclude "$exclude" '((.outbounds // []) + (.endpoints // []))[] | select(.tag != $exclude) | "  - \(.tag) (\(.type))"' "$OUTBOUND_FILE"
    echo "  - direct-out (direct, 系统内置)"
}

read_strategy_tags() {
    local self=$1 input tags missing
    available_strategy_tags "$self" >&2
    read -p "输入成员标签（逗号分隔）: " input
    tags=$(csv_to_json_array "$input") || return 1
    [[ $(echo "$tags" | jq length) -gt 0 ]] || { print_error "至少选择一个成员"; return 1; }
    if echo "$tags" | jq -e --arg self "$self" 'index($self) != null' >/dev/null; then print_error "策略不能直接引用自身"; return 1; fi
    missing=$(jq -r --argjson tags "$tags" '[((.outbounds // []) + (.endpoints // []))[]?.tag, "direct-out"] as $all | [$tags[] as $tag | select($all | index($tag) | not) | $tag] | join(", ")' "$OUTBOUND_FILE")
    [[ -z "$missing" ]] || { print_error "以下标签不存在: $missing"; return 1; }
    echo "$tags"
}

add_selector_outbound() {
    local tag tags default interrupt=false answer outbound
    read -p "Selector 标签: " tag; validate_new_outbound_tag "$tag" || return 1
    tags=$(read_strategy_tags "$tag") || return 1
    read -p "默认成员 [$(echo "$tags" | jq -r '.[0]')]: " default; default=${default:-$(echo "$tags" | jq -r '.[0]')}
    echo "$tags" | jq -e --arg default "$default" 'index($default) != null' >/dev/null || { print_error "默认成员不在成员列表中"; return 1; }
    read -p "切换时中断现有连接? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && interrupt=true
    outbound=$(jq -n --arg tag "$tag" --argjson tags "$tags" --arg default "$default" --argjson interrupt "$interrupt" '{type:"selector",tag:$tag,outbounds:$tags,default:$default,interrupt_exist_connections:$interrupt}')
    save_flat_outbound "$outbound"
}

add_urltest_outbound() {
    local tag tags url interval tolerance idle interrupt=false answer outbound
    read -p "URLTest 标签: " tag; validate_new_outbound_tag "$tag" || return 1
    tags=$(read_strategy_tags "$tag") || return 1
    read -p "测试 URL [https://www.gstatic.com/generate_204]: " url; url=${url:-https://www.gstatic.com/generate_204}
    read -p "测试间隔 [3m]: " interval; interval=${interval:-3m}
    read -p "容差毫秒 [50]: " tolerance; tolerance=${tolerance:-50}; [[ "$tolerance" =~ ^[0-9]+$ ]] || return 1
    read -p "空闲超时 [30m]: " idle; idle=${idle:-30m}
    read -p "切换时中断现有连接? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && interrupt=true
    outbound=$(jq -n --arg tag "$tag" --argjson tags "$tags" --arg url "$url" --arg interval "$interval" --argjson tolerance "$tolerance" --arg idle "$idle" --argjson interrupt "$interrupt" '{type:"urltest",tag:$tag,outbounds:$tags,url:$url,interval:$interval,tolerance:$tolerance,idle_timeout:$idle,interrupt_exist_connections:$interrupt}')
    save_flat_outbound "$outbound"
}

add_direct_outbound() {
    local tag outbound
    read -p "Direct 标签: " tag; validate_new_outbound_tag "$tag" || return 1
    outbound=$(jq -n --arg tag "$tag" '{type:"direct",tag:$tag}')
    save_flat_outbound "$outbound"
}

add_block_outbound() {
    local tag outbound
    read -p "Block 标签: " tag; validate_new_outbound_tag "$tag" || return 1
    outbound=$(jq -n --arg tag "$tag" '{type:"block",tag:$tag}')
    save_flat_outbound "$outbound"
}

managed_entries() {
    jq -c '[((.outbounds // []) | to_entries[]) | {kind:"outbound",index:.key,item:.value}] + [((.endpoints // []) | to_entries[]) | {kind:"endpoint",index:.key,item:.value}] | .[]' "$OUTBOUND_FILE"
}

list_outbounds() {
    init_outbound_file || return 1
    local count=0 entry kind type tag address port
    echo ""
    echo "已管理的出站与 Endpoint："
    while IFS= read -r entry; do
        ((count+=1))
        kind=$(echo "$entry" | jq -r '.kind')
        type=$(echo "$entry" | jq -r '.item.type')
        tag=$(echo "$entry" | jq -r '.item.tag')
        address=$(echo "$entry" | jq -r 'if .kind=="endpoint" then (.item.peers[0].address // "-") else (.item.server // "-") end')
        port=$(echo "$entry" | jq -r 'if .kind=="endpoint" then (.item.peers[0].port // "-") else (.item.server_port // (.item.server_ports // "-")) end')
        printf '[%d] %-9s %-14s %-24s %s:%s\n' "$count" "$kind" "$type" "$tag" "$address" "$port"
    done < <(managed_entries)
    [[ $count -gt 0 ]] || echo "  暂无自定义出站"
}

show_outbound_status() {
    init_outbound_file || return 1
    local out_count endpoint_count bound_count
    out_count=$(jq '(.outbounds // []) | length' "$OUTBOUND_FILE")
    endpoint_count=$(jq '(.endpoints // []) | length' "$OUTBOUND_FILE")
    bound_count=$(jq '[.nodes[] | select((.outbound_tag // "") != "")] | length' "$NODES_FILE" 2>/dev/null || echo 0)
    echo "出站库: ${out_count} 个 outbound，${endpoint_count} 个 endpoint；已绑定节点: ${bound_count}"
}

entry_by_number() {
    local number=$1
    managed_entries | sed -n "${number}p"
}

bind_tag_to_nodes() {
    local tag=$1 mode index count data
    [[ -f "$NODES_FILE" ]] || { print_error "节点文件不存在"; return 1; }
    count=$(jq '.nodes | length' "$NODES_FILE")
    [[ $count -gt 0 ]] || { print_warning "暂无节点"; return 0; }
    echo "1. 应用到全部节点"
    jq -r '.nodes | to_entries[] | "\(.key+2). \(.value.name // .value.protocol)-\(.value.port) [当前: \(.value.outbound_tag // "direct-out")]"' "$NODES_FILE"
    read -p "请选择: " mode
    if [[ "$mode" == 1 ]]; then
        data=$(jq --arg tag "$tag" '.nodes |= map(.outbound_tag=$tag | del(.warp_outbound))' "$NODES_FILE") || return 1
    elif [[ "$mode" =~ ^[0-9]+$ && "$mode" -ge 2 && "$mode" -le $((count+1)) ]]; then
        index=$((mode-2))
        data=$(jq --argjson index "$index" --arg tag "$tag" '.nodes[$index].outbound_tag=$tag | del(.nodes[$index].warp_outbound)' "$NODES_FILE") || return 1
    else
        print_error "选择无效"
        return 1
    fi
    atomic_write_json "$NODES_FILE" "$data" || return 1
    apply_outbound_changes
}

prompt_bind_outbound_to_node() {
    local tag=$1 answer
    read -p "是否立即绑定到节点? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        if declare -f commit_data_transaction >/dev/null 2>&1; then
            commit_data_transaction || {
                print_error "出站已写入，但最后可用数据快照更新失败"
                return 1
            }
        fi
        return 0
    fi
    bind_tag_to_nodes "$tag"
}

apply_outbound_to_node() {
    local count number entry tag
    list_outbounds || return 1
    count=$(managed_entries | wc -l)
    [[ $count -gt 0 ]] || return 0
    read -p "选择要应用的序号: " number
    [[ "$number" =~ ^[0-9]+$ && "$number" -ge 1 && "$number" -le "$count" ]] || { print_error "序号无效"; return 1; }
    entry=$(entry_by_number "$number"); tag=$(echo "$entry" | jq -r '.item.tag')
    bind_tag_to_nodes "$tag"
}

disable_outbound_from_node() {
    local count mode index data
    count=$(jq '.nodes | length' "$NODES_FILE" 2>/dev/null || echo 0)
    [[ $count -gt 0 ]] || { print_warning "暂无节点"; return 0; }
    echo "1. 全部节点恢复直连"
    jq -r '.nodes | to_entries[] | "\(.key+2). \(.value.name // .value.protocol)-\(.value.port) [当前: \(.value.outbound_tag // "direct-out")]"' "$NODES_FILE"
    read -p "请选择: " mode
    if [[ "$mode" == 1 ]]; then
        data=$(jq '.nodes |= map(del(.outbound_tag,.warp_outbound))' "$NODES_FILE") || return 1
    elif [[ "$mode" =~ ^[0-9]+$ && "$mode" -ge 2 && "$mode" -le $((count+1)) ]]; then
        index=$((mode-2)); data=$(jq --argjson index "$index" 'del(.nodes[$index].outbound_tag,.nodes[$index].warp_outbound)' "$NODES_FILE") || return 1
    else
        print_error "选择无效"; return 1
    fi
    atomic_write_json "$NODES_FILE" "$data" && apply_outbound_changes
}

check_outbound_consistency() {
    local mode=${1:-silent} missing duplicates
    init_outbound_file || return 1
    duplicates=$(jq -r '((.outbounds // []) + (.endpoints // [])) | group_by(.tag) | map(select(length>1) | .[0].tag) | join(", ")' "$OUTBOUND_FILE")
    missing=$(jq -r --slurpfile nodes "$NODES_FILE" '[((.outbounds // []) + (.endpoints // []))[]?.tag, "direct-out", "warp-ep"] as $all | [$nodes[0].nodes[]?.outbound_tag? as $tag | select($tag != null and $tag != "" and ($all | index($tag) | not)) | $tag] | unique | join(", ")' "$OUTBOUND_FILE" 2>/dev/null || true)
    if [[ -n "$duplicates" || -n "$missing" ]]; then
        [[ -z "$duplicates" ]] || print_error "重复标签: $duplicates"
        [[ -z "$missing" ]] || print_error "节点引用不存在的标签: $missing"
        return 1
    fi
    [[ "$mode" == verbose ]] && print_success "出站库、Endpoint 与节点引用一致"
}

rename_managed_entry() {
    local kind=$1 index=$2 old_tag=$3 new_tag data
    read -p "新标签: " new_tag; validate_new_outbound_tag "$new_tag" || return 1
    data=$(jq --arg kind "$kind" --argjson index "$index" --arg old "$old_tag" --arg new "$new_tag" '
      if $kind=="outbound" then .outbounds[$index].tag=$new else .endpoints[$index].tag=$new end |
      .outbounds |= map(
        (if (.outbounds? // [] | index($old)) != null then .outbounds |= map(if .==$old then $new else . end) else . end) |
        if .detour==$old then .detour=$new else . end
      ) |
      .endpoints |= map(if .detour==$old then .detour=$new else . end)
    ' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" || return 1
    if [[ -f "$NODES_FILE" ]]; then
        data=$(jq --arg old "$old_tag" --arg new "$new_tag" '.nodes |= map(if .outbound_tag==$old then .outbound_tag=$new else . end)' "$NODES_FILE") || return 1
        atomic_write_json "$NODES_FILE" "$data" || return 1
    fi
    apply_outbound_changes
}

modify_entry_server() {
    local kind=$1 index=$2 current_server current_port server port data
    if [[ "$kind" == endpoint ]]; then
        current_server=$(jq -r --argjson i "$index" '.endpoints[$i].peers[0].address // ""' "$OUTBOUND_FILE")
        current_port=$(jq -r --argjson i "$index" '.endpoints[$i].peers[0].port // 0' "$OUTBOUND_FILE")
    else
        current_server=$(jq -r --argjson i "$index" '.outbounds[$i].server // empty' "$OUTBOUND_FILE")
        current_port=$(jq -r --argjson i "$index" '.outbounds[$i].server_port // empty' "$OUTBOUND_FILE")
        [[ -n "$current_server" && -n "$current_port" ]] || { print_error "该类型没有通用 server/server_port 字段"; return 1; }
    fi
    read -p "服务器 [$current_server]: " server; server=${server:-$current_server}
    read -p "端口 [$current_port]: " port; port=${port:-$current_port}; validate_port_value "$port" || { print_error "端口无效"; return 1; }
    data=$(jq --arg kind "$kind" --argjson i "$index" --arg server "$server" --argjson port "$port" 'if $kind=="endpoint" then .endpoints[$i].peers[0].address=$server | .endpoints[$i].peers[0].port=$port else .outbounds[$i].server=$server | .outbounds[$i].server_port=$port end' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" && apply_outbound_changes
}

modify_entry_auth() {
    local kind=$1 index=$2 type=$3 username password uuid psk key_path passphrase private_key public_key data mode
    if [[ "$kind" == endpoint ]]; then
        read -p "WireGuard 私钥（回车保持不变）: " private_key
        read -p "Peer 公钥（回车保持不变）: " public_key
        read -p "预共享密钥（输入 - 删除，回车保持不变）: " psk
        data=$(jq --argjson i "$index" --arg private "$private_key" --arg public "$public_key" --arg psk "$psk" '
          if $private!="" then .endpoints[$i].private_key=$private else . end |
          if $public!="" then .endpoints[$i].peers[0].public_key=$public else . end |
          if $psk=="-" then del(.endpoints[$i].peers[0].pre_shared_key) elif $psk!="" then .endpoints[$i].peers[0].pre_shared_key=$psk else . end
        ' "$OUTBOUND_FILE") || return 1
        atomic_write_json "$OUTBOUND_FILE" "$data" && apply_outbound_changes
        return
    fi
    case "$type" in
        http|socks|naive)
            read -p "用户名（输入 - 删除认证）: " username
            if [[ "$username" == - ]]; then
                data=$(jq --argjson i "$index" 'del(.outbounds[$i].username,.outbounds[$i].password)' "$OUTBOUND_FILE")
            else
                read -p "密码: " password; [[ -n "$username" && -n "$password" ]] || return 1
                data=$(jq --argjson i "$index" --arg username "$username" --arg password "$password" '.outbounds[$i].username=$username | .outbounds[$i].password=$password' "$OUTBOUND_FILE")
            fi
            ;;
        vless|vmess)
            read -p "新 UUID: " uuid; [[ -n "$uuid" ]] || return 1
            data=$(jq --argjson i "$index" --arg uuid "$uuid" '.outbounds[$i].uuid=$uuid' "$OUTBOUND_FILE")
            ;;
        hysteria)
            read -p "新认证密码: " password; [[ -n "$password" ]] || return 1
            data=$(jq --argjson i "$index" --arg password "$password" 'del(.outbounds[$i].auth) | .outbounds[$i].auth_str=$password' "$OUTBOUND_FILE")
            ;;
        trojan|shadowsocks|hysteria2|anytls|shadowtls)
            read -p "新密码: " password; [[ -n "$password" ]] || return 1
            data=$(jq --argjson i "$index" --arg password "$password" '.outbounds[$i].password=$password' "$OUTBOUND_FILE")
            ;;
        tuic)
            read -p "新 UUID（回车保持不变）: " uuid
            read -p "新密码（回车保持不变）: " password
            [[ -n "$uuid" || -n "$password" ]] || return 0
            data=$(jq --argjson i "$index" --arg uuid "$uuid" --arg password "$password" 'if $uuid!="" then .outbounds[$i].uuid=$uuid else . end | if $password!="" then .outbounds[$i].password=$password else . end' "$OUTBOUND_FILE")
            ;;
        snell)
            read -p "新 PSK: " psk; [[ -n "$psk" ]] || return 1
            if [[ $(jq -r --argjson i "$index" '.outbounds[$i].version' "$OUTBOUND_FILE") == 6 && ${#psk} -lt 12 ]]; then print_error "Snell v6 PSK 至少 12 字节"; return 1; fi
            data=$(jq --argjson i "$index" --arg psk "$psk" '.outbounds[$i].psk=$psk' "$OUTBOUND_FILE")
            ;;
        ssh)
            echo "1. 密码认证  2. 私钥文件"
            read -p "认证方式: " mode
            if [[ "$mode" == 1 ]]; then
                read -p "新密码: " password; [[ -n "$password" ]] || return 1
                data=$(jq --argjson i "$index" --arg password "$password" 'del(.outbounds[$i].private_key,.outbounds[$i].private_key_path,.outbounds[$i].private_key_passphrase) | .outbounds[$i].password=$password' "$OUTBOUND_FILE")
            elif [[ "$mode" == 2 ]]; then
                read -p "私钥路径: " key_path; [[ -n "$key_path" ]] || return 1; read -p "私钥口令（可留空）: " passphrase
                data=$(jq --argjson i "$index" --arg key "$key_path" --arg passphrase "$passphrase" 'del(.outbounds[$i].password,.outbounds[$i].private_key) | .outbounds[$i].private_key_path=$key | if $passphrase!="" then .outbounds[$i].private_key_passphrase=$passphrase else del(.outbounds[$i].private_key_passphrase) end' "$OUTBOUND_FILE")
            else
                return 1
            fi
            ;;
        *) print_error "该类型没有可统一修改的认证字段，请使用完整 JSON 编辑"; return 1 ;;
    esac
    [[ -n "$data" ]] || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" && apply_outbound_changes
}

modify_entry_detour() {
    local kind=$1 index=$2 tag=$3 detour data missing
    echo "可用上游标签（留空表示直接连接）："
    available_strategy_tags "$tag"
    read -p "Detour 标签: " detour
    if [[ -n "$detour" ]]; then
        missing=$(jq -r --arg tag "$detour" '[((.outbounds // []) + (.endpoints // []))[]?.tag, "direct-out"] | index($tag) == null' "$OUTBOUND_FILE")
        [[ "$missing" == false ]] || { print_error "上游标签不存在: $detour"; return 1; }
    fi
    data=$(jq --arg kind "$kind" --argjson i "$index" --arg detour "$detour" '
      if $kind=="outbound" then
        if $detour=="" then del(.outbounds[$i].detour) else .outbounds[$i].detour=$detour end
      else
        if $detour=="" then del(.endpoints[$i].detour) else .endpoints[$i].detour=$detour end
      end
    ' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" && apply_outbound_changes
}

modify_outbound_mux_config() {
    local index=$1 type protocol max_connections min_streams padding=false answer data
    type=$(jq -r --argjson i "$index" '.outbounds[$i].type' "$OUTBOUND_FILE")
    [[ "$type" == vless || "$type" == vmess || "$type" == trojan || "$type" == shadowsocks ]] || { print_error "仅 VLESS/VMess/Trojan/Shadowsocks 支持 multiplex"; return 1; }
    read -p "启用 Multiplex? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        data=$(jq --argjson i "$index" 'del(.outbounds[$i].multiplex,.outbounds[$i].mux)' "$OUTBOUND_FILE") || return 1
    else
        read -p "协议 [h2mux]（h2mux/smux/yamux）: " protocol; protocol=${protocol:-h2mux}; [[ "$protocol" == h2mux || "$protocol" == smux || "$protocol" == yamux ]] || return 1
        read -p "最大连接数 [4]: " max_connections; max_connections=${max_connections:-4}; [[ "$max_connections" =~ ^[0-9]+$ && "$max_connections" -gt 0 ]] || return 1
        read -p "每连接最小流数 [4]: " min_streams; min_streams=${min_streams:-4}; [[ "$min_streams" =~ ^[0-9]+$ && "$min_streams" -gt 0 ]] || return 1
        read -p "启用 Padding? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] && padding=true
        data=$(jq --argjson i "$index" --arg protocol "$protocol" --argjson connections "$max_connections" --argjson streams "$min_streams" --argjson padding "$padding" 'del(.outbounds[$i].mux) | .outbounds[$i].multiplex={enabled:true,protocol:$protocol,max_connections:$connections,min_streams:$streams,padding:$padding}' "$OUTBOUND_FILE") || return 1
    fi
    atomic_write_json "$OUTBOUND_FILE" "$data" && apply_outbound_changes
}

replace_managed_entry_json() {
    local kind=$1 index=$2 old_tag=$3 raw new_tag data
    echo "请输入单行 sing-box JSON（必须保留 type/tag，标签不可与其他条目冲突）"
    read -r raw
    echo "$raw" | jq -e 'type=="object" and (.type|type=="string") and (.tag|type=="string")' >/dev/null || { print_error "JSON 无效"; return 1; }
    new_tag=$(echo "$raw" | jq -r '.tag')
    if [[ "$new_tag" != "$old_tag" ]]; then
        validate_new_outbound_tag "$new_tag" || return 1
    fi
    data=$(jq --arg kind "$kind" --argjson i "$index" --argjson item "$raw" 'if $kind=="outbound" then .outbounds[$i]=$item else .endpoints[$i]=$item end' "$OUTBOUND_FILE") || return 1
    if [[ "$new_tag" != "$old_tag" ]]; then
        data=$(echo "$data" | jq --arg old "$old_tag" --arg new "$new_tag" '
          .outbounds |= map((if ((.outbounds // []) | index($old)) != null then .outbounds |= map(if .==$old then $new else . end) else . end) | if .detour==$old then .detour=$new else . end) |
          .endpoints |= map(if .detour==$old then .detour=$new else . end)
        ') || return 1
    fi
    atomic_write_json "$OUTBOUND_FILE" "$data" || return 1
    if [[ "$new_tag" != "$old_tag" && -f "$NODES_FILE" ]]; then
        data=$(jq --arg old "$old_tag" --arg new "$new_tag" '.nodes |= map(if .outbound_tag==$old then .outbound_tag=$new else . end)' "$NODES_FILE") || return 1
        atomic_write_json "$NODES_FILE" "$data" || return 1
    fi
    apply_outbound_changes
}

modify_outbound() {
    local count number entry kind index type tag choice
    list_outbounds || return 1; count=$(managed_entries | wc -l); [[ $count -gt 0 ]] || return 0
    read -p "选择要修改的序号: " number
    [[ "$number" =~ ^[0-9]+$ && "$number" -ge 1 && "$number" -le "$count" ]] || { print_error "序号无效"; return 1; }
    entry=$(entry_by_number "$number"); kind=$(echo "$entry" | jq -r '.kind'); index=$(echo "$entry" | jq -r '.index'); type=$(echo "$entry" | jq -r '.item.type'); tag=$(echo "$entry" | jq -r '.item.tag')
    echo "1. 修改标签  2. 修改服务器/端口  3. 修改认证  4. 修改上游链路/Detour  5. 修改 Multiplex  6. 高级：替换完整 JSON"
    read -p "请选择: " choice
    case "$choice" in
        1) rename_managed_entry "$kind" "$index" "$tag" ;;
        2) modify_entry_server "$kind" "$index" ;;
        3) modify_entry_auth "$kind" "$index" "$type" ;;
        4) modify_entry_detour "$kind" "$index" "$tag" ;;
        5) [[ "$kind" == outbound ]] && modify_outbound_mux_config "$index" "$tag" || { print_error "Endpoint 不支持 Multiplex"; return 1; } ;;
        6) replace_managed_entry_json "$kind" "$index" "$tag" ;;
        *) print_error "选择无效"; return 1 ;;
    esac
}

delete_outbound() {
    local count number entry kind index tag references answer data
    list_outbounds || return 1; count=$(managed_entries | wc -l); [[ $count -gt 0 ]] || return 0
    read -p "选择要删除的序号: " number
    [[ "$number" =~ ^[0-9]+$ && "$number" -ge 1 && "$number" -le "$count" ]] || { print_error "序号无效"; return 1; }
    entry=$(entry_by_number "$number"); kind=$(echo "$entry" | jq -r '.kind'); index=$(echo "$entry" | jq -r '.index'); tag=$(echo "$entry" | jq -r '.item.tag')
    references=$(jq -r --arg tag "$tag" '[(.outbounds[]? | select(((.outbounds // []) | index($tag)) or .detour==$tag) | .tag), (.endpoints[]? | select(.detour==$tag) | .tag)] | join(", ")' "$OUTBOUND_FILE")
    if [[ -n "$references" ]]; then
        print_error "'$tag' 仍被策略出站引用: $references；请先修改或删除这些策略"
        return 1
    fi
    read -p "确认删除 '$tag'? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] || return 0
    data=$(jq --arg kind "$kind" --argjson i "$index" 'if $kind=="outbound" then del(.outbounds[$i]) else del(.endpoints[$i]) end' "$OUTBOUND_FILE") || return 1
    atomic_write_json "$OUTBOUND_FILE" "$data" || return 1
    if [[ -f "$NODES_FILE" ]]; then
        data=$(jq --arg tag "$tag" '.nodes |= map(if .outbound_tag==$tag then del(.outbound_tag) else . end)' "$NODES_FILE") || return 1
        atomic_write_json "$NODES_FILE" "$data" || return 1
    fi
    apply_outbound_changes
}

outbound_management_menu() {
    local choice protocol_choice
    while true; do
        clear
        print_header "出站规则管理（sing-box 1.14+）"
        show_outbound_status
        echo "1. 查看  2. 添加  3. 应用到节点  4. 恢复直连  5. 修改  6. 删除  7. 一致性检查  0. 返回"
        read -p "请选择 [0-7]: " choice
        case "$choice" in
            1) list_outbounds; wait_for_input ;;
            2)
                clear
                echo " 1.HTTP  2.SOCKS  3.VLESS  4.VMess  5.Trojan  6.Shadowsocks"
                echo " 7.Hysteria2  8.TUIC  9.Naive(需Cronet内核)  10.AnyTLS  11.Hysteria v1"
                echo "12.ShadowTLS  13.SSH  14.Snell  15.Tor  16.WireGuard Endpoint"
                echo "17.Selector  18.URLTest  19.Direct  20.Block  0.返回"
                read -p "请选择协议: " protocol_choice
                case "$protocol_choice" in
                    1) add_http_outbound ;; 2) add_socks_outbound ;; 3) add_vless_outbound ;; 4) add_vmess_outbound ;;
                    5) add_trojan_outbound ;; 6) add_shadowsocks_outbound ;; 7) add_hysteria2_outbound ;; 8) add_tuic_outbound ;;
                    9) add_naive_outbound ;; 10) add_anytls_outbound ;; 11) add_hysteria_outbound ;; 12) add_shadowtls_outbound ;;
                    13) add_ssh_outbound ;; 14) add_snell_outbound ;; 15) add_tor_outbound ;; 16) add_wireguard_endpoint ;;
                    17) add_selector_outbound ;; 18) add_urltest_outbound ;; 19) add_direct_outbound ;; 20) add_block_outbound ;;
                    0) continue ;; *) print_error "选择无效" ;;
                esac
                wait_for_input
                ;;
            3) apply_outbound_to_node; wait_for_input ;;
            4) disable_outbound_from_node; wait_for_input ;;
            5) modify_outbound; wait_for_input ;;
            6) delete_outbound; wait_for_input ;;
            7) check_outbound_consistency verbose; wait_for_input ;;
            0) return ;;
            *) print_error "选择无效"; sleep 1 ;;
        esac
    done
}
