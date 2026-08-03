#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
cleanup_validation_tmp() {
    local status=$?
    if [[ -n "${KEEP_TMP:-}" ]]; then
        echo "保留验证目录: $TMP_DIR" >&2
    else
        rm -rf "$TMP_DIR"
    fi
    return "$status"
}
trap cleanup_validation_tmp EXIT

echo "[1/8] Bash 语法检查"
while IFS= read -r file; do
    bash -n "$file"
done < <(find "$ROOT_DIR" -type f -name '*.sh' \
    ! -name '*.bak' ! -name '*.backup*' ! -name '*_backup*' -print)

echo "[2/8] 废弃字段与旧路径检查"
if grep -RInE 'settings\.(clients|servers|vnext)|sniff:[[:space:]]*true|insecure:[[:space:]]*true|skip-cert-verify:[[:space:]]*true|bind_interface:[[:space:]]*"wgcf"|/opt/s-singbox/config\.json|/usr/local/sing-box/(sing-box|data)|/var/lib/sing-box/data|CAP_SYS_PTRACE|CAP_DAC_READ_SEARCH|mkcp|mKCP' \
    "$ROOT_DIR/modules" "$ROOT_DIR/scripts" "$ROOT_DIR/install.sh" "$ROOT_DIR/singbox-manager.sh" \
    --exclude='*.bak' --exclude='*.backup*' --exclude='*_backup*' --exclude='validate_all.sh'; then
    echo "发现仍在使用的废弃字段或旧路径" >&2
    exit 1
fi
grep -q 'with_v2ray_api' "$ROOT_DIR/modules/zz_singbox_114.sh"

echo "[3/8] 13 协议稳定版配置生成矩阵"
export RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY='' NC=''
export LOG_FILE="$TMP_DIR/manager.log" LOG_LEVEL=3
SINGBOX_DIR="$TMP_DIR/etc/sing-box"
SINGBOX_CONFIG="$SINGBOX_DIR/config.json"
SINGBOX_SERVICE="$TMP_DIR/sing-box.service"
DATA_DIR="$TMP_DIR/data"
USERS_FILE="$DATA_DIR/users.json"
NODES_FILE="$DATA_DIR/nodes.json"
NODE_USERS_FILE="$DATA_DIR/node_users.json"
SUBSCRIPTION_DIR="$DATA_DIR/subscriptions"
mkdir -p "$SINGBOX_DIR" "$DATA_DIR" "$SUBSCRIPTION_DIR"

export MOCK_CHECK_LOG="$TMP_DIR/sing-box-check.log"
cat > "$TMP_DIR/mock-sing-box-stats" <<'SH'
#!/bin/bash
case "${1:-}" in
    version) printf '%s\n' 'sing-box version 1.13.15' 'Tags: with_v2ray_api,with_clash_api' ;;
    check) printf '%s\n' "${*:2}" >> "${MOCK_CHECK_LOG:?}" ;;
    api) printf '%s\n' '{"stat":[]}' ;;
    *) exit 1 ;;
esac
SH
cat > "$TMP_DIR/mock-sing-box-ordinary" <<'SH'
#!/bin/bash
case "${1:-}" in
    version) printf '%s\n' 'sing-box version 1.13.15' 'Tags: with_quic,with_utls' ;;
    check) printf '%s\n' "${*:2}" >> "${MOCK_CHECK_LOG:?}" ;;
    *) exit 1 ;;
esac
SH
chmod +x "$TMP_DIR/mock-sing-box-stats" "$TMP_DIR/mock-sing-box-ordinary"
SINGBOX_BIN="$TMP_DIR/mock-sing-box-stats"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=example.com' \
    -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" >/dev/null 2>&1

cat > "$USERS_FILE" <<'JSON'
{"users":[{"id":"059032a9-7d40-4a96-9bb1-36823d848068","username":"fixture","password":"fixture-p@ss:#?/+","enabled":true}]}
JSON

jq -n --arg cert "$TMP_DIR/cert.pem" --arg key "$TMP_DIR/key.pem" '
  def tls: {tls_domain:"example.com",tls_cert:$cert,tls_key:$key,tls_insecure:true};
  {nodes:[
    {name:"vless",protocol:"vless",port:"21001",transport:"ws",security:"tls",extra:(tls+{ws_path:"/ws",ws_host:"example.com"})},
    {name:"vmess",protocol:"vmess",port:"21002",transport:"ws",security:"tls",extra:(tls+{alter_id:7,cipher:"auto",ws_path:"/vmess",ws_host:"example.com"})},
    {name:"trojan",protocol:"trojan",port:"21003",transport:"grpc",security:"tls",extra:(tls+{grpc_service:"trojan-grpc",fallback_dest:"127.0.0.1",fallback_port:"8080"})},
    {name:"ss",protocol:"shadowsocks",port:"21004",transport:"tcp",security:"none",extra:{method:"2022-blake3-aes-128-gcm",master_password:"MDEyMzQ1Njc4OWFiY2RlZg=="}},
    {name:"hy2",protocol:"hysteria2",port:"21005",transport:"udp",security:"tls",extra:(tls+{up_mbps:100,down_mbps:100,obfs_password:"fixture-obfs",port_hopping:"22000:22100",masquerade:"https://example.com/"})},
    {name:"tuic",protocol:"tuic",port:"21006",transport:"udp",security:"tls",extra:(tls+{congestion_control:"cubic",zero_rtt_handshake:false})},
    {name:"naive",protocol:"naive",port:"21007",transport:"tcp",security:"tls",extra:(tls+{quic_congestion_control:"bbr"})},
    {name:"mixed",protocol:"mixed",port:"21008",transport:"tcp",security:"none",extra:{}},
    {name:"http",protocol:"http",port:"21009",transport:"tcp",security:"none",extra:{}},
    {name:"socks",protocol:"socks",port:"21010",transport:"tcp",security:"none",extra:{}},
    {name:"anytls",protocol:"anytls",port:"21011",transport:"tcp",security:"tls",extra:(tls+{padding_scheme:["stop=8","0=30-30"]})},
    {name:"hysteria",protocol:"hysteria",port:"21012",transport:"udp",security:"tls",extra:(tls+{up_mbps:100,down_mbps:100,obfs:"fixture-hy-obfs"})},
    {name:"shadowtls",protocol:"shadowtls",port:"21013",transport:"tcp",security:"none",extra:{version:3,handshake_server:"example.com",handshake_port:443,strict_mode:true,wildcard_sni:"off",tls_domain:"example.com"}}
  ]}' > "$NODES_FILE"

jq -n '{bindings:([range(21001;21014) | {port:(tostring),protocol:"fixture",users:["059032a9-7d40-4a96-9bb1-36823d848068"]}])}' > "$NODE_USERS_FILE"
jq '.nodes[0].outbound_tag="strategy-main"' "$NODES_FILE" > "$NODES_FILE.tmp"
mv "$NODES_FILE.tmp" "$NODES_FILE"
cat > "$DATA_DIR/outbounds.json" <<'JSON'
{"outbounds":[
  {"type":"hysteria","tag":"fixture-hysteria","server":"hy.example.com","server_port":443,"up":"100 Mbps","down":"100 Mbps","auth_str":"password","tls":{"enabled":true,"server_name":"hy.example.com"}},
  {"type":"shadowtls","tag":"fixture-shadowtls","server":"st.example.com","server_port":443,"version":3,"password":"password","tls":{"enabled":true,"server_name":"st.example.com"}},
  {"type":"ssh","tag":"fixture-ssh","server":"ssh.example.com","server_port":22,"user":"root","password":"password"},
  {"type":"snell","tag":"fixture-snell","server":"snell.example.com","server_port":443,"version":6,"psk":"fixture-psk-123","mode":"default"},
  {"type":"tor","tag":"fixture-tor","executable_path":"/usr/bin/tor","data_directory":"/var/lib/sing-box/tor/fixture","torrc":{"ClientOnly":1}},
  {"type":"direct","tag":"fixture-direct"},
  {"type":"block","tag":"fixture-block"},
  {"type":"shadowsocks","tag":"strategy-leaf","server":"ss.example.com","server_port":8388,"method":"aes-256-gcm","password":"password","detour":"fixture-shadowtls"},
  {"type":"urltest","tag":"strategy-auto","outbounds":["strategy-leaf"],"url":"https://www.gstatic.com/generate_204","interval":"3m","tolerance":50,"idle_timeout":"30m"},
  {"type":"selector","tag":"strategy-main","outbounds":["strategy-auto","fixture-wg","direct-out"],"default":"strategy-auto"}
],"endpoints":[
  {"type":"wireguard","tag":"fixture-wg","mtu":1408,"address":["10.0.0.2/32"],"private_key":"YNXtAzepDqRv9H52osJVDQnznT5AM11eCK3ESpwSt04=","peers":[{"address":"wg.example.com","port":51820,"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=","allowed_ips":["0.0.0.0/0","::/0"],"reserved":[0,0,0]}]}
]}
JSON

# shellcheck source=/dev/null
source "$ROOT_DIR/modules/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/config_generator_singbox.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/domain.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/firewall.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/node.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/subscription.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/user.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/zz_singbox_114.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/modules/zzz_outbound_extended.sh"

write_project_kernel_metadata "$SINGBOX_BIN" "1.13.15" "validation-fixture"
singbox_has_online_user_capability

mkdir -p "$TMP_DIR/patch-source/experimental/clashapi/trafficontrol"
cat > "$TMP_DIR/patch-source/experimental/clashapi/trafficontrol/tracker.go" <<'GO'
package trafficontrol

func fixture() map[string]any {
	var processPath string
	var t struct{ Metadata struct{ User string } }
	return map[string]any{
		"processPath": processPath,
	}
}
GO
apply_clash_api_user_patch "$TMP_DIR/patch-source"
apply_clash_api_user_patch "$TMP_DIR/patch-source"
grep -q '"inboundUser":[[:space:]]*t.Metadata.User' "$TMP_DIR/patch-source/experimental/clashapi/trafficontrol/tracker.go"
[[ "$(grep -c '"inboundUser"' "$TMP_DIR/patch-source/experimental/clashapi/trafficontrol/tracker.go")" == 1 ]]

[[ "$(get_default_domain)" == "www.cloudflare.com" ]]
! is_reality_handshake_domain_compatible "www.microsoft.com"
is_reality_handshake_domain_compatible "www.cloudflare.com"
(
    getent() { printf '%s\n' '203.0.113.10 STREAM fixture.example.com'; }
    [[ "$(resolve_domain_ipv4 fixture.example.com)" == "203.0.113.10" ]]
)
(
    date() { echo 1000; }
    timeout() { shift; "$@"; }
    openssl() { return 0; }
    host() { return 127; }
    [[ "$(measure_reality_domain_latency www.cloudflare.com)" == "0" ]]
)

generate_singbox_config
jq -e '.inbounds | length == 13' "$SINGBOX_CONFIG" >/dev/null
for protocol in vless vmess trojan shadowsocks hysteria2 tuic naive mixed http socks anytls hysteria shadowtls; do
    jq -e --arg p "$protocol" '.inbounds[] | select(.type==$p)' "$SINGBOX_CONFIG" >/dev/null
done
jq -e '.experimental.v2ray_api.stats.enabled == true and (.experimental.v2ray_api.stats.users | index("fixture"))' "$SINGBOX_CONFIG" >/dev/null
jq -e '.experimental.clash_api.external_controller == "127.0.0.1:9090" and (.experimental.clash_api.secret | length >= 32)' "$SINGBOX_CONFIG" >/dev/null
[[ -s "$DATA_DIR/clash_api.secret" ]]
config_clash_secret=$(jq -r '.experimental.clash_api.secret' "$SINGBOX_CONFIG")
printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$DATA_DIR/clash_api.secret"
[[ "$(ensure_clash_api_secret)" == "$config_clash_secret" ]]
[[ "$(tr -d '\r\n' < "$DATA_DIR/clash_api.secret")" == "$config_clash_secret" ]]
(
    fetch_clash_api_connections() {
        printf '%s\n' '{"downloadTotal":2048,"uploadTotal":1024,"connections":[
          {"id":"1","metadata":{"network":"tcp","type":"vless/vless-21001","inboundUser":"fixture","sourceIP":"198.51.100.1","sourcePort":"50001","destinationIP":"203.0.113.1","destinationPort":"443"}},
          {"id":"2","metadata":{"network":"tcp","type":"vless/vless-21001","inboundUser":"fixture","sourceIP":"198.51.100.1","sourcePort":"50002","destinationIP":"203.0.113.2","destinationPort":"443"}},
          {"id":"3","metadata":{"network":"udp","type":"tuic/tuic-21006","inboundUser":"second-user","sourceIP":"198.51.100.2","sourcePort":"50003","destinationIP":"203.0.113.3","destinationPort":"443"}},
          {"id":"4","metadata":{"network":"tcp","type":"mixed/local-management","inboundUser":"fixture","sourceIP":"127.0.0.1","sourcePort":"50004","destinationIP":"127.0.0.1","destinationPort":"80"}}
        ],"memory":4096}'
    }
    refresh_connection_snapshot
    [[ "$(get_realtime_connection_count)" == 3 ]]
    [[ "$(get_realtime_online_users_count)" == 2 ]]
    [[ "$(get_node_realtime_stats vless 21001)" == '1|2' ]]
    [[ "$(get_node_realtime_stats tuic 21006)" == '1|1' ]]
    [[ "$(get_user_online_status '059032a9-7d40-4a96-9bb1-36823d848068')" == online ]]
    online_rows=$(get_realtime_online_user_rows)
    grep -Fq $'fixture\t-\tvless\t2' <<< "$online_rows"
    grep -Fq $'second-user\t-\ttuic\t1' <<< "$online_rows"

    fetch_clash_api_connections() {
        printf '%s\n' '{"connections":[{"metadata":{"network":"tcp","type":"vless/vless-21001"}}]}'
    }
    refresh_connection_snapshot
    [[ "$(get_realtime_connection_count)" == 1 ]]
    [[ "$(get_realtime_online_users_count)" == UNAVAILABLE ]]
    [[ "$(get_node_realtime_stats vless 21001)" == 'UNAVAILABLE|1' ]]

    fetch_clash_api_connections() { printf '%s\n' '{"connections":[]}'; }
    refresh_connection_snapshot
    [[ "$(get_realtime_connection_count)" == 0 ]]
    [[ "$(get_realtime_online_users_count)" == 0 ]]
    [[ "$(get_user_online_status '059032a9-7d40-4a96-9bb1-36823d848068')" == offline ]]

    fetch_clash_api_connections() { return 1; }
    ! refresh_connection_snapshot
    [[ -z "$CONNECTION_SNAPSHOT_JSON" ]]
    [[ "$CONNECTION_SNAPSHOT_STATE" == unavailable ]]
    [[ "$(get_user_online_status '059032a9-7d40-4a96-9bb1-36823d848068')" == unavailable ]]
)
jq -e '[.inbounds[] | select((.users | length) == 0)] | length == 0' "$SINGBOX_CONFIG" >/dev/null
jq -e '.inbounds[] | select(.type=="vmess") | .users[0].alterId == 7' "$SINGBOX_CONFIG" >/dev/null
jq -e '.inbounds[] | select(.type=="trojan") | (.fallback.server == "127.0.0.1" and .fallback.server_port == 8080)' "$SINGBOX_CONFIG" >/dev/null
jq -e '.inbounds[] | select(.type=="hysteria2") | .masquerade == "https://example.com/"' "$SINGBOX_CONFIG" >/dev/null
jq -e '.inbounds[] | select(.type=="hysteria") | (.up_mbps == 100 and .down_mbps == 100 and .users[0].auth_str == "fixture-p@ss:#?/+")' "$SINGBOX_CONFIG" >/dev/null
jq -e '.inbounds[] | select(.type=="shadowtls") | (.version == 3 and .handshake.server == "example.com" and .users[0].password == "fixture-p@ss:#?/+")' "$SINGBOX_CONFIG" >/dev/null
jq -e '.inbounds[] | select(.type=="socks") | (.users[0].username == "fixture" and .users[0].password == "fixture-p@ss:#?/+")' "$SINGBOX_CONFIG" >/dev/null
jq -e '[.inbounds[] | select(.listen != "0.0.0.0")] | length == 0' "$SINGBOX_CONFIG" >/dev/null
jq -e '.type == "http" and .path == "/legacy-h2"' <<< "$(generate_114_transport h2 '{"http_path":"/legacy-h2"}')" >/dev/null
jq -e '[.outbounds[].tag] | (index("strategy-main") != null and index("strategy-auto") != null and index("strategy-leaf") != null)' "$SINGBOX_CONFIG" >/dev/null
jq -e '[.outbounds[].tag] | (index("fixture-shadowtls") != null and index("fixture-hysteria") == null and index("fixture-ssh") == null and index("fixture-snell") == null and index("fixture-tor") == null)' "$SINGBOX_CONFIG" >/dev/null
jq -e '.outbounds[] | select(.tag=="strategy-leaf") | (.type=="shadowsocks" and .detour=="fixture-shadowtls")' "$SINGBOX_CONFIG" >/dev/null
jq -e '.endpoints[] | select(.type=="wireguard" and .tag=="fixture-wg")' "$SINGBOX_CONFIG" >/dev/null
jq -e '[.outbounds[].type] | (index("hysteria") != null and index("shadowtls") != null and index("ssh") != null and index("snell") != null and index("tor") != null and index("selector") != null and index("urltest") != null and index("direct") != null and index("block") != null)' "$DATA_DIR/outbounds.json" >/dev/null
jq -e '.endpoints[] | select(.type=="wireguard")' "$DATA_DIR/outbounds.json" >/dev/null

# 缺少项目监控组件的内核也必须能生成并校验完整节点配置。
stats_config="$SINGBOX_CONFIG"
SINGBOX_BIN="$TMP_DIR/mock-sing-box-ordinary"
SINGBOX_CONFIG="$SINGBOX_DIR/config-ordinary.json"
_generate_singbox_config_114
jq -e '((.experimental // {}) | has("v2ray_api") | not) and ((.experimental // {}) | has("clash_api") | not) and (.inbounds | length == 13)' "$SINGBOX_CONFIG" >/dev/null
grep -q -- '-c .*config-ordinary.json' "$MOCK_CHECK_LOG"
if [[ -n "${SINGBOX_VALIDATION_BIN:-}" && -x "$SINGBOX_VALIDATION_BIN" ]]; then
    validation_version=$("$SINGBOX_VALIDATION_BIN" version | sed -n 's/^sing-box version[[:space:]]\+v\?\([^[:space:]]\+\).*/\1/p' | head -1)
    if ! version_ge "$validation_version" 1.14.0; then
        old_validation_bin="$SINGBOX_BIN"
        SINGBOX_BIN="$SINGBOX_VALIDATION_BIN"
        snell_fixture='{"name":"snell","protocol":"snell","port":"21014","transport":"tcp","security":"none","extra":{"version":6,"psk":"fixture-snell-psk","mode":"default"}}'
        ! generate_114_inbound "$snell_fixture" '[{"name":"fixture","userkey":"fixture-p@ss:#?/+"}]' >/dev/null 2>&1
        SINGBOX_BIN="$old_validation_bin"
    fi
    "$SINGBOX_VALIDATION_BIN" check -c "$stats_config"
    "$SINGBOX_VALIDATION_BIN" check -c "$SINGBOX_CONFIG"
fi
SINGBOX_CONFIG="$stats_config"
SINGBOX_BIN="$TMP_DIR/mock-sing-box-stats"

echo "[4/8] 订阅协议字段检查"
nodes=$(jq -c '.nodes' "$NODES_FILE")
generate_clash_config "$nodes" "059032a9-7d40-4a96-9bb1-36823d848068" > "$TMP_DIR/clash.yaml"
grep -q 'name: "自动选择"' "$TMP_DIR/clash.yaml"
grep -q 'type: url-test' "$TMP_DIR/clash.yaml"
grep -q 'url: "https://www.gstatic.com/generate_204"' "$TMP_DIR/clash.yaml"
grep -A4 'name: "主代理"' "$TMP_DIR/clash.yaml" | grep -q '"自动选择"'
grep -q 'type: vless.*packet-encoding: xudp' "$TMP_DIR/clash.yaml"
grep -q 'ws-opts:.*path: "/vmess"' "$TMP_DIR/clash.yaml"
grep -q 'alterId: 7' "$TMP_DIR/clash.yaml"
grep -q 'grpc-opts:.*trojan-grpc' "$TMP_DIR/clash.yaml"
grep -q 'obfs-password: "fixture-obfs"' "$TMP_DIR/clash.yaml"
grep -q 'ports: "22000-22100"' "$TMP_DIR/clash.yaml"
grep -q 'up: "100 Mbps"' "$TMP_DIR/clash.yaml"
grep -q 'type: hysteria' "$TMP_DIR/clash.yaml"

generate_singbox_subscription_config "$nodes" "059032a9-7d40-4a96-9bb1-36823d848068" > "$TMP_DIR/client.json"
jq -e '.outbounds[] | select(.type=="selector" and .tag=="主代理") | (.default == "自动选择" and .outbounds[0] == "自动选择" and (.outbounds | index("直连") != null))' "$TMP_DIR/client.json" >/dev/null
jq -e '.outbounds[] | select(.type=="urltest" and .tag=="自动选择") | (.url == "https://www.gstatic.com/generate_204" and .interval == "5m" and .tolerance == 50)' "$TMP_DIR/client.json" >/dev/null
jq -e '.outbounds[] | select(.type=="vless") | .packet_encoding == "xudp"' "$TMP_DIR/client.json" >/dev/null
jq -e '.outbounds[] | select(.type=="hysteria2") | (.server_ports == ["22000:22100"] and (has("server_port")|not) and .hop_interval == "30s" and .obfs.type == "salamander")' "$TMP_DIR/client.json" >/dev/null
jq -e '.outbounds[] | select(.type=="vmess") | (.alter_id == 7 and .transport.type == "ws" and .transport.path == "/vmess")' "$TMP_DIR/client.json" >/dev/null
jq -e '.outbounds[] | select(.type=="trojan") | (.transport.type == "grpc" and .transport.service_name == "trojan-grpc")' "$TMP_DIR/client.json" >/dev/null
jq -e '.outbounds[] | select(.type=="hysteria") | (.auth_str == "fixture-p@ss:#?/+" and .up_mbps == 100 and .tls.server_name == "example.com")' "$TMP_DIR/client.json" >/dev/null
jq -e '.outbounds[] | select(.type=="shadowtls") | (.version == 3 and .password == "fixture-p@ss:#?/+" and .tls.server_name == "example.com")' "$TMP_DIR/client.json" >/dev/null
jq -e '.outbounds[] | select(.type=="tuic") | (.udp_relay_mode == "native" and .zero_rtt_handshake == false and .heartbeat == "10s" and .tls.alpn == ["h3"] and .tls.insecure == true)' "$TMP_DIR/client.json" >/dev/null

vless_node=$(jq -c '.nodes[] | select(.protocol=="vless")' "$NODES_FILE")
vless_link=$(generate_share_link_smart "059032a9-7d40-4a96-9bb1-36823d848068" "" "$vless_node")
[[ "$vless_link" == *'allowInsecure=1'* && "$vless_link" == *'type=ws'* && "$vless_link" == *'packetEncoding=xudp'* && "$vless_link" == *'path=%2Fws'* ]]

reality_node='[{"name":"reality","protocol":"vless","port":"21014","transport":"tcp","security":"reality","extra":{"server_address":"203.0.113.10","server_names":["www.cloudflare.com"],"public_key":"fixture-public-key","short_ids":["0123456789abcdef"]}}]'
generate_clash_config "$reality_node" "059032a9-7d40-4a96-9bb1-36823d848068" > "$TMP_DIR/reality-clash.yaml"
grep -q 'type: vless.*packet-encoding: xudp.*flow: xtls-rprx-vision.*reality-opts:' "$TMP_DIR/reality-clash.yaml"
(
    get_public_ip() { echo '203.0.113.10'; }
    direct_reality_output=$(generate_vless_reality_share "059032a9-7d40-4a96-9bb1-36823d848068" "fixture" "21014" "www.cloudflare.com" "fixture-public-key" "0123456789abcdef")
    [[ "$direct_reality_output" == *'packetEncoding=xudp'* ]]
)

tuic_node=$(jq -c '.nodes[] | select(.protocol=="tuic")' "$NODES_FILE")
tuic_link=$(generate_share_link_smart "059032a9-7d40-4a96-9bb1-36823d848068" "" "$tuic_node")
[[ "$tuic_link" == *'alpn=h3'* && "$tuic_link" == *'udp_relay_mode=native'* && "$tuic_link" == *'allow_insecure=1'* && "$tuic_link" == *'zero_rtt_handshake=0'* ]]

if [[ -n "${SINGBOX_VALIDATION_BIN:-}" && -x "$SINGBOX_VALIDATION_BIN" ]]; then
    # 项目默认内核不包含 with_naive_outbound；Naive 客户端结构单独做字段测试，
    # 真实内核检查覆盖其余官方本地构建支持的客户端出站。
    client_validation_nodes=$(echo "$nodes" | jq -c 'map(select(.protocol != "naive"))')
    generate_singbox_subscription_config "$client_validation_nodes" "059032a9-7d40-4a96-9bb1-36823d848068" > "$TMP_DIR/client-kernel-check.json"
    "$SINGBOX_VALIDATION_BIN" check -c "$TMP_DIR/client-kernel-check.json"
fi

hy2_node=$(jq -c '.nodes[] | select(.protocol=="hysteria2")' "$NODES_FILE")
hy2_link=$(generate_share_link_smart "059032a9-7d40-4a96-9bb1-36823d848068" "" "$hy2_node")
[[ "$hy2_link" == *'fixture-p%40ss%3A%23%3F%2F%2B@'* ]]

echo "[5/8] 管理调用链检查"
! grep -RIn 'generate_sing-box_config' "$ROOT_DIR/modules" "$ROOT_DIR/singbox-manager.sh" --include='*.sh'
! grep -RInE 'eval[[:space:]]+"?\$acme_cmd|sing-box[[:space:]]+test' "$ROOT_DIR/modules" "$ROOT_DIR/scripts" "$ROOT_DIR/singbox-manager.sh" --include='*.sh' --exclude='*.bak' --exclude='*.backup*' --exclude='*_backup*' --exclude='validate_all.sh'
! grep -RInE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh' "$ROOT_DIR/modules" "$ROOT_DIR/scripts" "$ROOT_DIR/install.sh" "$ROOT_DIR/singbox-manager.sh" --include='*.sh' --exclude='*.bak' --exclude='*.backup*' --exclude='*_backup*' --exclude='validate_all.sh'

# dev 在线安装入口必须克隆 dev，并保留显式环境变量覆盖，防止 process substitution 静默回退 main。
grep -q '^DEFAULT_BRANCH="dev"$' "$ROOT_DIR/install.sh"
grep -q 'INSTALL_BRANCH_OVERRIDE="${S_SINGBOX_BRANCH:-${BRANCH:-}}"' "$ROOT_DIR/install.sh"
grep -q 'git check-ref-format --branch "$BRANCH"' "$ROOT_DIR/install.sh"
grep -q 'CLONED_BRANCH.*branch --show-current' "$ROOT_DIR/install.sh"
grep -q 'os.path.commonpath' "$ROOT_DIR/modules/subscription.sh"
grep -q 'sing-box-subscription.service' "$ROOT_DIR/modules/subscription.sh"
grep -q 'sing-box-subscription-health.timer' "$ROOT_DIR/modules/subscription.sh"
grep -q 'subscription_server_is_healthy' "$ROOT_DIR/modules/subscription.sh"
grep -q 'ThreadingHTTPServer' "$ROOT_DIR/modules/subscription.sh"
grep -q 'ProtectHome=true' "$ROOT_DIR/modules/subscription.sh"
grep -q 'list_cf_http_compatible_nodes' "$ROOT_DIR/modules/cf_tunnel.sh"
grep -q 'and (.transport == "ws")' "$ROOT_DIR/modules/cf_tunnel.sh"
grep -q 'hysteria.*hysteria2.*tuic' "$ROOT_DIR/modules/firewall.sh"
grep -q 'readonly SINGBOX_DATA_DIR="/var/lib/sing-box"' "$ROOT_DIR/scripts/backup.sh"
grep -q 'readonly SINGBOX_DATA_DIR="/var/lib/sing-box"' "$ROOT_DIR/uninstall.sh"
grep -q 'add_hysteria_node' "$ROOT_DIR/singbox-manager.sh"
grep -q 'add_shadowtls_node' "$ROOT_DIR/singbox-manager.sh"
! grep -q 'add_snell_node' "$ROOT_DIR/singbox-manager.sh"
! grep -q 'add_snell_node' "$ROOT_DIR/modules/quick_wizard.sh"
grep -q 'singbox_supports_snell_inbound' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'add_snell_outbound' "$ROOT_DIR/modules/zzz_outbound_extended.sh"
grep -q 'bind_users_to_node_smart; wait_for_input' "$ROOT_DIR/singbox-manager.sh"
grep -q 'local port="${1:-}"' "$ROOT_DIR/modules/user_node_binding.sh"
! grep -q 'transport="h2"' "$ROOT_DIR/modules/node.sh"
! grep -q 'local admin_info=$(bind_admin_to_node' "$ROOT_DIR/modules/node.sh"
grep -q 'save_node_and_bind_admin' "$ROOT_DIR/modules/node.sh"
grep -q 'persist_port_hopping_rules' "$ROOT_DIR/modules/node.sh"
grep -q 'select_node_tls_domain' "$ROOT_DIR/modules/node.sh"
grep -q 'sync_active_node_firewall_ports' "$ROOT_DIR/modules/firewall.sh"
grep -q 'verify_configured_inbound_listeners' "$ROOT_DIR/modules/zz_singbox_114.sh"
! grep -q 'YOUR_SERVER_IP' "$ROOT_DIR/modules/node.sh"
! grep -q 'server_ip="127.0.0.1"' "$ROOT_DIR/modules/subscription.sh"
grep -q 'sync_runtime_subscriptions' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'api statsquery' "$ROOT_DIR/modules/monitor.sh"
! grep -q 'http://.*\/stats' "$ROOT_DIR/modules/monitor.sh"
grep -q 'if ! singbox_has_project_kernel_capability; then' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q '节点功能正常；实时连接或流量统计可能不可用' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'ensure_singbox_stats_capability' "$ROOT_DIR/modules/zz_singbox_114.sh"
! grep -q 'ensure_singbox_stats_capability' "$ROOT_DIR/singbox-manager.sh"
! sed -n '/^generate_singbox_config()/,/^}/p' "$ROOT_DIR/modules/zz_singbox_114.sh" | grep -q 'ensure_singbox_stats_capability'
! sed -n '/^add_naive_outbound()/,/^}/p' "$ROOT_DIR/modules/zz_singbox_114.sh" | grep -q 'ensure_singbox_stats_capability'
grep -q 'sha256sum -c - >/dev/null' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'Go 工具链路径无效' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'normalize_singbox_build_tags' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'DEFAULT_BUILD_TAGS_OTHERS' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'with_naive_outbound，无法添加 Naive 出站' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q '当前内核不支持已启用的 Naive 出站' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'DEFAULT_BUILD_TAGS_OTHERS' "$ROOT_DIR/scripts/validate_custom_kernel_build.sh"
grep -q 'run_singbox_go_build' "$ROOT_DIR/scripts/validate_custom_kernel_build.sh"
grep -q '内核仍在编译' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'download_and_install_prebuilt_singbox' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'SINGBOX_LOCAL_BUILD_FALLBACK' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'SINGBOX_PROJECT_KERNEL_VERSION="${SINGBOX_PROJECT_KERNEL_VERSION:-1.13.15}"' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'SINGBOX_PROJECT_KERNEL_REVISION="${SINGBOX_PROJECT_KERNEL_REVISION:-1}"' "$ROOT_DIR/modules/zz_singbox_114.sh"
grep -q 'SINGBOX_KERNEL_VERSION: 1.13.15' "$ROOT_DIR/.github/workflows/validate-custom-kernel.yml"
grep -q 'SINGBOX_KERNEL_REVISION: 1' "$ROOT_DIR/.github/workflows/validate-custom-kernel.yml"
grep -q 'asset_arch: amd64' "$ROOT_DIR/.github/workflows/validate-custom-kernel.yml"
grep -q 'asset_arch: arm64' "$ROOT_DIR/.github/workflows/validate-custom-kernel.yml"
grep -q 'warn_if_stats_capability_missing' "$ROOT_DIR/singbox-manager.sh"
grep -q 'ensure_subscription_server_runtime' "$ROOT_DIR/singbox-manager.sh"
(
    NODES_FILE="$TMP_DIR/empty-nodes.json"
    echo '{"nodes":[]}' > "$NODES_FILE"
    ss() {
        [[ "$*" == *-lun* ]] && echo 'UNCONN 0 0 0.0.0.0:24444 0.0.0.0:*'
        return 0
    }
    check_port_exists 24444
    ! check_port_exists 24445
    check_port_exists invalid
)
(
    save_node_info() { return 0; }
    bind_admin_to_node() { return 1; }
    rollback_data_transaction() { :; }
    ! save_node_and_bind_admin vless 443 tcp none '{}' fixture
)
validate_reality_keypair \
    'iH1wT46Q_W-grVuEQGP-mUNnY-5f_gk9_8jr_LM26Fw' \
    'AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y'
[[ "$(normalize_reality_server_name 'EXAMPLE.COM.')" == 'example.com' ]]
! normalize_reality_server_name 'https://example.com' >/dev/null 2>&1
empty_sid_tls=$(generate_114_tls_server reality '{"dest":"example.com:443","server_names":["example.com"],"private_key":"iH1wT46Q_W-grVuEQGP-mUNnY-5f_gk9_8jr_LM26Fw","public_key":"AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y","short_ids":[""]}')
jq -e '.reality.short_id == [""]' <<< "$empty_sid_tls" >/dev/null
! validate_reality_keypair \
    'iH1wT46Q_W-grVuEQGP-mUNnY-5f_gk9_8jr_LM26Fw' \
    'BJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y' >/dev/null 2>&1
(
    DATA_DIR="$TMP_DIR/reality-target-migration"
    NODES_FILE="$DATA_DIR/nodes.json"
    DEFAULT_DOMAIN_FILE="$DATA_DIR/default_domain.txt"
    mkdir -p "$DATA_DIR"
    printf '%s\n' '{"nodes":[{"protocol":"vless","port":"5005","security":"reality","extra":{"dest":"www.microsoft.com:443","server_names":["www.microsoft.com"],"private_key":"iH1wT46Q_W-grVuEQGP-mUNnY-5f_gk9_8jr_LM26Fw","public_key":"AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y","short_ids":["0123456789abcdef"]}}]}' > "$NODES_FILE"
    repair_reality_node_credentials_114
    jq -e '.nodes[0].extra | (.server_names == ["www.cloudflare.com"] and .dest == "www.cloudflare.com:443" and .dest_server == "www.cloudflare.com" and .dest_port == 443)' "$NODES_FILE" >/dev/null
)
(
    DATA_DIR="$TMP_DIR/reality-subscription-repair"
    USERS_FILE="$DATA_DIR/users.json"
    NODES_FILE="$DATA_DIR/nodes.json"
    NODE_USERS_FILE="$DATA_DIR/node_users.json"
    SUBSCRIPTION_DIR="$DATA_DIR/subscriptions"
    SUBSCRIPTION_META_FILE="$DATA_DIR/subscription_metadata.json"
    mkdir -p "$SUBSCRIPTION_DIR"
    user_id='059032a9-7d40-4a96-9bb1-36823d848068'
    printf '%s\n' '{"users":[{"id":"059032a9-7d40-4a96-9bb1-36823d848068","username":"fixture","email":"fixture@example.com","password":"password","enabled":true}]}' > "$USERS_FILE"
    printf '%s\n' '{"subscriptions":[{"name":"legacy","type":"raw"}]}' > "$SUBSCRIPTION_META_FILE"
    raw_file="$SUBSCRIPTION_DIR/legacy_${user_id}_raw.txt"
    printf '%s\n' "vless://${user_id}@203.0.113.10:5005?security=reality&sni=example.com&pbk=AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y&sid=0123456789abcdef" > "$raw_file"
    jq -n --arg file "$raw_file" '{subscriptions:[{name:"legacy",file:$file,type:"raw",user:"fixture"}]}' > "$DATA_DIR/subscriptions.json"
    printf '%s\n' '{"nodes":[{"protocol":"vless","port":"5005","security":"reality","extra":{"server_names":["EXAMPLE.COM."],"private_key":"iH1wT46Q_W-grVuEQGP-mUNnY-5f_gk9_8jr_LM26Fw","public_key":"BJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y","short_ids":["0123456789abcdef"]}}]}' > "$NODES_FILE"
    printf '%s\n' '{"bindings":[{"port":"5005","users":["059032a9-7d40-4a96-9bb1-36823d848068"]}]}' > "$NODE_USERS_FILE"
    repair_reality_node_credentials_114
    jq -e '.nodes[0].extra.public_key=="AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y" and .nodes[0].extra.server_names[0]=="example.com"' "$NODES_FILE" >/dev/null
    repair_subscription_metadata_114
    jq -e --arg id "$user_id" '.subscriptions[] | select(.name=="legacy" and .user_id==$id and .type=="raw")' "$SUBSCRIPTION_META_FILE" >/dev/null
    verify_reality_subscription_files_114
    sed -i 's/0123456789abcdef/fedcba9876543210/' "$raw_file"
    ! verify_reality_subscription_files_114 >/dev/null 2>&1

    printf '%s\n' '{"nodes":[
      {"protocol":"vless","port":"5005","security":"reality","extra":{"server_names":["example.com"],"public_key":"AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y","short_ids":["0123456789abcdef"]}},
      {"protocol":"vless","port":"5020","security":"reality","extra":{"server_names":["www.microsoft.com"],"public_key":"AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y","short_ids":["78dd7bc4b025236a"]}}
    ]}' > "$NODES_FILE"
    printf '%s\n' "{\"bindings\":[
      {\"port\":\"5005\",\"users\":[\"${user_id}\"]},
      {\"port\":\"5020\",\"users\":[\"${user_id}\"]}
    ]}" > "$NODE_USERS_FILE"
    printf '%s\n' "proxies:
  - {name: \"legacy-5005\", type: vless, server: \"203.0.113.10\", port: 5005, uuid: \"${user_id}\", servername: \"example.com\", reality-opts: {public-key: \"AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y\", short-id: \"0123456789abcdef\"}}
  - {name: \"new-5020\", type: vless, server: \"203.0.113.10\", port: 5020, uuid: \"${user_id}\", servername: \"www.microsoft.com\", reality-opts: {public-key: \"AJx5Xbkv2G-6LAb6MQauMjFB8xu0LkKClSbXbnX-m1Y\", short-id: \"78dd7bc4b025236a\"}}" > "$SUBSCRIPTION_DIR/legacy_${user_id}_clash.yaml"
    jq --arg type clash '.subscriptions[0].type=$type' "$SUBSCRIPTION_META_FILE" > "$SUBSCRIPTION_META_FILE.tmp"
    mv "$SUBSCRIPTION_META_FILE.tmp" "$SUBSCRIPTION_META_FILE"
    verify_reality_subscription_files_114
    sed -i 's/78dd7bc4b025236a/aaaaaaaaaaaaaaaa/' "$SUBSCRIPTION_DIR/legacy_${user_id}_clash.yaml"
    ! verify_reality_subscription_files_114 >/dev/null 2>&1
    sed -i 's/aaaaaaaaaaaaaaaa/78dd7bc4b025236a/' "$SUBSCRIPTION_DIR/legacy_${user_id}_clash.yaml"

    jq --arg type general '.subscriptions += [{name:"non-reality-missing",user_id:"unbound-user",type:$type}]' "$SUBSCRIPTION_META_FILE" > "$SUBSCRIPTION_META_FILE.tmp"
    mv "$SUBSCRIPTION_META_FILE.tmp" "$SUBSCRIPTION_META_FILE"
    verify_reality_subscription_files_114
)
[[ "$(split_host_port '[2001:db8::1]:8443' 443)" == '2001:db8::1|8443' ]]
[[ "$(format_uri_host '2001:db8::1')" == '[2001:db8::1]' ]]
tunnel_node='{"port":"21001","tunnel_domain":"https://[2001:db8::8]:8443/proxy?token=test"}'
[[ "$(resolve_subscription_host "$tunnel_node")" == '2001:db8::8' ]]
[[ "$(resolve_subscription_port "$tunnel_node")" == '8443' ]]
(
    get_subscription_domain_hint() { echo 'global.example.com'; }
    get_public_ip() { echo '203.0.113.10'; }
    node_with_address='{"extra":{"server_address":"node.example.com","tls_domain":"sni.example.com"}}'
    [[ "$(resolve_subscription_host "$node_with_address")" == node.example.com ]]
)
(
    get_subscription_domain_hint() { echo 'global.example.com'; }
    get_public_ip() { echo '203.0.113.10'; }
    legacy_tls_node='{"security":"tls","extra":{"tls_domain":"sni.example.com"}}'
    [[ "$(resolve_subscription_host "$legacy_tls_node")" == global.example.com ]]
)
(
    get_subscription_domain_hint() { echo 'global.example.com'; }
    get_public_ip() { echo '203.0.113.10'; }
    plain_node='{"security":"none","extra":{}}'
    [[ "$(resolve_subscription_host "$plain_node")" == 203.0.113.10 ]]
)
(
    get_subscription_domain_hint() { echo 'global.example.com'; }
    get_public_ip() { echo '203.0.113.10'; }
    reality_node='{"security":"reality","extra":{"tls_domain":"www.example.com"}}'
    [[ "$(resolve_subscription_host "$reality_node")" == 203.0.113.10 ]]
)
(
    domain_dir="$TMP_DIR/domain-choice"
    mkdir -p "$domain_dir"
    DATA_DIR="$domain_dir"
    printf '%s\n' 'server.example.com' > "$DATA_DIR/server_domain.txt"
    check_server_domain_resolution() { return 0; }
    select_node_tls_domain TUIC <<< "" >/dev/null
    [[ "$NODE_TLS_DOMAIN" == server.example.com && "$NODE_SERVER_ADDRESS" == server.example.com ]]
    select_node_tls_domain TUIC <<< $'n\ncustom.example.com\ny' >/dev/null
    [[ "$NODE_TLS_DOMAIN" == custom.example.com && "$NODE_SERVER_ADDRESS" == custom.example.com ]]
    get_public_ip() { echo '203.0.113.10'; }
    select_node_tls_domain TUIC <<< $'n\nsni.example.com\nn' >/dev/null
    [[ "$NODE_TLS_DOMAIN" == sni.example.com && "$NODE_SERVER_ADDRESS" == 203.0.113.10 ]]
)
(
    limited_users="$TMP_DIR/limited-users.json"
    USERS_FILE="$limited_users"
    printf '%s\n' '{"users":[{"id":"limited","username":"limited","password":"password","enabled":true,"traffic_limit_gb":"1","traffic_used_gb":"2"}]}' > "$USERS_FILE"
    singbox_has_stats_capability() { return 1; }
    jq -e 'length == 1' <<< "$(build_114_users vless none '{}' limited)" >/dev/null
    singbox_has_stats_capability() { return 0; }
    jq -e 'length == 0' <<< "$(build_114_users vless none '{}' limited)" >/dev/null
)
(
    SINGBOX_CONFIG="$TMP_DIR/listener-config.json"
    printf '%s\n' '{"inbounds":[{"type":"vless","listen_port":21001},{"type":"shadowsocks","listen_port":21004},{"type":"hysteria2","listen_port":21005},{"type":"naive","listen_port":21007}]}' > "$SINGBOX_CONFIG"
    ss() {
        [[ "$*" == *-ltn* ]] && printf '%s\n' 'LISTEN 0 128 0.0.0.0:21001 0.0.0.0:*'
        [[ "$*" == *-ltn* ]] && printf '%s\n' 'LISTEN 0 128 0.0.0.0:21004 0.0.0.0:*'
        [[ "$*" == *-ltn* ]] && printf '%s\n' 'LISTEN 0 128 0.0.0.0:21007 0.0.0.0:*'
        [[ "$*" == *-lun* ]] && printf '%s\n' 'UNCONN 0 0 0.0.0.0:21004 0.0.0.0:*'
        [[ "$*" == *-lun* ]] && printf '%s\n' 'UNCONN 0 0 0.0.0.0:21005 0.0.0.0:*'
        [[ "$*" == *-lun* ]] && printf '%s\n' 'UNCONN 0 0 0.0.0.0:21007 0.0.0.0:*'
    }
    verify_configured_inbound_listeners
    ss() {
        [[ "$*" == *-ltn* ]] && printf '%s\n' 'LISTEN 0 128 0.0.0.0:21001 0.0.0.0:*' 'LISTEN 0 128 0.0.0.0:21004 0.0.0.0:*' 'LISTEN 0 128 0.0.0.0:21007 0.0.0.0:*'
        [[ "$*" == *-lun* ]] && printf '%s\n' 'UNCONN 0 0 0.0.0.0:21004 0.0.0.0:*' 'UNCONN 0 0 0.0.0.0:21005 0.0.0.0:*'
    }
    ! verify_configured_inbound_listeners >/dev/null
)
(
    SINGBOX_CONFIG="$TMP_DIR/firewall-config.json"
    printf '%s\n' '{"inbounds":[{"type":"vless","listen_port":21001},{"type":"shadowsocks","listen_port":21004},{"type":"hysteria2","listen_port":21005},{"type":"naive","listen_port":21007}]}' > "$SINGBOX_CONFIG"
    NODES_FILE="$TMP_DIR/firewall-nodes.json"
    printf '%s\n' '{"nodes":[{"protocol":"hysteria2","port":"21005","extra":{"port_hopping":"22000:22100"}}]}' > "$NODES_FILE"
    : > "$TMP_DIR/firewall-calls"
    detect_firewall() { echo ufw; }
    ufw() { printf '%s\n' "$*" >> "$TMP_DIR/firewall-calls"; }
    sync_active_node_firewall_ports
    grep -q 'allow 21001/tcp' "$TMP_DIR/firewall-calls"
    grep -q 'allow 21004/tcp' "$TMP_DIR/firewall-calls"
    grep -q 'allow 21004/udp' "$TMP_DIR/firewall-calls"
    grep -q 'allow 21005/udp' "$TMP_DIR/firewall-calls"
    grep -q 'allow 22000:22100/udp' "$TMP_DIR/firewall-calls"
    grep -q 'allow 21007/tcp' "$TMP_DIR/firewall-calls"
    grep -q 'allow 21007/udp' "$TMP_DIR/firewall-calls"
)

(
    TRAFFIC_COUNTERS_FILE="$TMP_DIR/activity-counters.json"
    printf '%s\n' '{"users":{}}' > "$TRAFFIC_COUNTERS_FILE"
    : > "$TMP_DIR/traffic-updated-users"
    singbox_has_stats_capability() { return 0; }
    update_user_traffic_usage() {
        printf '%s\n' "$1" >> "$TMP_DIR/traffic-updated-users"
        echo "0.001"
    }
    USER_LIMITS_CHANGED=false
    check_traffic_limits >/dev/null
    grep -q '059032a9-7d40-4a96-9bb1-36823d848068' "$TMP_DIR/traffic-updated-users"

)
(
    before="$TMP_DIR/users-before-no-stats.json"
    cp "$USERS_FILE" "$before"
    rm -f "$TMP_DIR/traffic-called-without-stats"
    singbox_has_stats_capability() { return 1; }
    update_user_traffic_usage() {
        : > "$TMP_DIR/traffic-called-without-stats"
        return 1
    }
    USER_LIMITS_CHANGED=false
    check_traffic_limits >/dev/null
    cmp -s "$before" "$USERS_FILE"
    [[ ! -e "$TMP_DIR/traffic-called-without-stats" ]]
    [[ "$USER_LIMITS_CHANGED" == false ]]
)

stale_file="$SUBSCRIPTION_DIR/stale_ghost_raw.txt"
printf 'stale\n' > "$stale_file"
cat > "$DATA_DIR/subscription_metadata.json" <<'JSON'
{"subscriptions":[{"name":"stale_ghost","user_id":"ghost-user","type":"raw"}]}
JSON
jq -n --arg file "$stale_file" '{subscriptions:[{name:"stale_ghost",file:$file,type:"raw",user:"ghost"}]}' > "$DATA_DIR/subscriptions.json"
sync_runtime_subscriptions
jq -e '.subscriptions | length == 0' "$DATA_DIR/subscription_metadata.json" >/dev/null
jq -e '.subscriptions | length == 0' "$DATA_DIR/subscriptions.json" >/dev/null
[[ ! -e "$stale_file" ]]

cat > "$TMP_DIR/legacy-outbounds.json" <<'JSON'
{"outbounds":[
  {"protocol":"vless","tag":"legacy-reality-ws","settings":{"vnext":[{"address":"2001:db8::9","port":443,"users":[{"id":"059032a9-7d40-4a96-9bb1-36823d848068","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"ws","security":"reality","wsSettings":{"path":"/legacy","headers":{"Host":"edge.example.com"}},"realitySettings":{"serverName":"example.com","publicKey":"fixture-public-key","shortId":"0123456789abcdef","fingerprint":"chrome"}}},
  {"protocol":"vmess","tag":"legacy-vmess-grpc","settings":{"vnext":[{"address":"vmess.example.com","port":443,"users":[{"id":"059032a9-7d40-4a96-9bb1-36823d848068","security":"auto","alterId":0}]}]},"streamSettings":{"network":"grpc","security":"tls","grpcSettings":{"serviceName":"legacy-grpc"},"tlsSettings":{"serverName":"vmess.example.com","allowInsecure":false,"alpn":["h2"]}},"mux":{"enabled":true}},
  {"type":"trojan","tag":"legacy-flat-mux","server":"trojan.example.com","server_port":443,"password":"password","mux":{"enabled":true}}
]}
JSON
migrate_outbounds_114 "$TMP_DIR/legacy-outbounds.json"
jq -e '.outbounds[] | select(.tag=="legacy-reality-ws") | (.type=="vless" and .transport.type=="ws" and .transport.headers.Host=="edge.example.com" and .tls.reality.public_key=="fixture-public-key" and (has("settings")|not) and (has("streamSettings")|not))' "$TMP_DIR/legacy-outbounds.json" >/dev/null
jq -e '.outbounds[] | select(.tag=="legacy-vmess-grpc") | (.type=="vmess" and .alter_id==0 and .transport.service_name=="legacy-grpc" and .tls.server_name=="vmess.example.com" and .multiplex.enabled==true)' "$TMP_DIR/legacy-outbounds.json" >/dev/null
jq -e '.outbounds[] | select(.tag=="legacy-flat-mux") | (.type=="trojan" and .multiplex.enabled==true and (has("mux")|not))' "$TMP_DIR/legacy-outbounds.json" >/dev/null
jq -e '.endpoints == []' "$TMP_DIR/legacy-outbounds.json" >/dev/null
if grep -nE 'echo "\$outbound".*\.protocol|\.item\.protocol|\.mux\.(enabled|concurrency)' "$ROOT_DIR/modules/zzz_outbound_extended.sh"; then
    echo "扩展出站模块仍在读取旧 protocol/mux 字段" >&2
    exit 1
fi
grep -q 'add_wireguard_endpoint' "$ROOT_DIR/modules/zzz_outbound_extended.sh"
grep -q 'add_selector_outbound' "$ROOT_DIR/modules/zzz_outbound_extended.sh"
grep -q 'add_urltest_outbound' "$ROOT_DIR/modules/zzz_outbound_extended.sh"
(
    SINGBOX_CONFIG="$TMP_DIR/fresh-install-config.json"
    prepare_singbox_storage() { :; }
    resolve_singbox_version() { echo "1.13.15"; }
    build_and_install_singbox() { printf '%s' "$2" > "$TMP_DIR/fresh-install-start-flag"; }
    create_default_config() { echo '{}' > "$SINGBOX_CONFIG"; }
    generate_singbox_config() { :; }
    restart_sing-box() { :; }
    install_sing-box <<< "1"
)
[[ "$(cat "$TMP_DIR/fresh-install-start-flag")" == false ]]
create_systemd_service
grep -q -- '--enforce-limits' "$TMP_DIR/sing-box-user-limits.service"
grep -q 'OnUnitActiveSec=1min' "$TMP_DIR/sing-box-user-limits.timer"

echo "[6/8] UI 交互回归检查"
bash "$ROOT_DIR/scripts/validate_ui.sh" "$TMP_DIR"
bash "$ROOT_DIR/scripts/validate_kernel_preflight.sh"
if command -v python3 >/dev/null 2>&1; then
    bash "$ROOT_DIR/scripts/validate_subscription_server.sh"
else
    echo "跳过订阅服务并发检查：未安装 Python 3。"
fi

echo "[7/8] sing-box check"
if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c "$SINGBOX_CONFIG"
    sing-box check -c "$TMP_DIR/client.json"
else
    echo "跳过运行时检查：系统未安装 sing-box；安装后请重新运行本脚本。"
fi

echo "[8/8] 可选 Clash YAML 解析"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$TMP_DIR/clash.yaml"
else
    echo "跳过 YAML 解析：未安装 Python PyYAML。"
fi

echo "全部检查通过"
