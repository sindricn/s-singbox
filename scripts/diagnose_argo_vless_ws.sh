#!/bin/bash

#================================================================
# Argo + VLESS + WS + TLS 节点诊断脚本
#================================================================

SINGBOX_CONFIG="/etc/sing-box/config.json"
NODES_FILE="/var/lib/sing-box/nodes.json"

echo "====================================="
echo " Argo + VLESS + WS + TLS 节点诊断"
echo "====================================="
echo ""

# 1. 检查节点配置
echo "[1] 检查节点配置 (nodes.json)"
echo "-------------------------------------"

if [[ ! -f "$NODES_FILE" ]]; then
    echo "❌ 节点文件不存在: $NODES_FILE"
    exit 1
fi

# 查找 VLESS + WS + TLS 节点
vless_ws_nodes=$(jq -r '.nodes[] | select(.protocol == "vless" and .transport == "ws" and .security == "tls") | "\(.port)|\(.extra.ws_path)|\(.extra.tls_domain)|\(.extra.tls_cert)|\(.extra.tls_key)|\(.tunnel_domain // "无")"' "$NODES_FILE" 2>/dev/null)

if [[ -z "$vless_ws_nodes" ]]; then
    echo "❌ 未找到 VLESS + WS + TLS 节点"
    exit 1
fi

echo "$vless_ws_nodes" | while IFS='|' read -r port ws_path tls_domain tls_cert tls_key tunnel_domain; do
    echo "找到节点:"
    echo "  端口: $port"
    echo "  WS路径: $ws_path"
    echo "  TLS域名: $tls_domain"
    echo "  证书: $tls_cert"
    echo "  密钥: $tls_key"
    echo "  Argo隧道: $tunnel_domain"
    echo ""

    # 检查证书文件
    if [[ -f "$tls_cert" ]]; then
        echo "  ✓ 证书文件存在"
    else
        echo "  ✗ 证书文件不存在: $tls_cert"
    fi

    if [[ -f "$tls_key" ]]; then
        echo "  ✓ 密钥文件存在"
    else
        echo "  ✗ 密钥文件不存在: $tls_key"
    fi
    echo ""
done

# 2. 检查 sing-box 配置
echo "[2] 检查 sing-box 配置 (config.json)"
echo "-------------------------------------"

if [[ ! -f "$SINGBOX_CONFIG" ]]; then
    echo "❌ 配置文件不存在: $SINGBOX_CONFIG"
    exit 1
fi

# 提取第一个 VLESS inbound
first_port=$(echo "$vless_ws_nodes" | head -1 | cut -d'|' -f1)

echo "检查端口 $first_port 的 inbound 配置:"
echo ""

inbound=$(jq ".inbounds[] | select(.listen_port == $first_port)" "$SINGBOX_CONFIG" 2>/dev/null)

if [[ -z "$inbound" ]]; then
    echo "❌ 未找到端口 $first_port 的 inbound 配置"
    exit 1
fi

echo "完整 inbound 配置:"
echo "$inbound" | jq '.'
echo ""

# 检查关键字段
echo "字段检查:"
echo "  type: $(echo "$inbound" | jq -r '.type')"
echo "  listen_port: $(echo "$inbound" | jq -r '.listen_port')"
echo "  users: $(echo "$inbound" | jq '.users | length') 个"

# 检查 TLS 配置
tls_enabled=$(echo "$inbound" | jq -r '.tls.enabled // false')
echo "  tls.enabled: $tls_enabled"

if [[ "$tls_enabled" == "true" ]]; then
    echo "  tls.server_name: $(echo "$inbound" | jq -r '.tls.server_name // "未设置"')"
    echo "  tls.certificate_path: $(echo "$inbound" | jq -r '.tls.certificate_path // "未设置"')"
    echo "  tls.key_path: $(echo "$inbound" | jq -r '.tls.key_path // "未设置"')"
else
    echo "  ❌ TLS 未启用！"
fi

# 检查 transport 配置
transport_type=$(echo "$inbound" | jq -r '.transport.type // "未设置"')
echo "  transport.type: $transport_type"

if [[ "$transport_type" == "ws" ]]; then
    echo "  transport.path: $(echo "$inbound" | jq -r '.transport.path // "未设置"')"
else
    echo "  ❌ Transport 不是 ws！"
fi

echo ""

# 3. 检查 sing-box 服务状态
echo "[3] 检查 sing-box 服务状态"
echo "-------------------------------------"

if systemctl is-active --quiet sing-box; then
    echo "✓ sing-box 服务运行中"
else
    echo "✗ sing-box 服务未运行"
    echo ""
    echo "最近的错误日志:"
    journalctl -u sing-box -n 20 --no-pager | tail -10
fi

echo ""

# 4. 检查端口监听
echo "[4] 检查端口监听状态"
echo "-------------------------------------"

echo "$vless_ws_nodes" | while IFS='|' read -r port _ _ _ _ _; do
    if ss -tlnp | grep -q ":$port "; then
        echo "✓ 端口 $port 正在监听"
        ss -tlnp | grep ":$port "
    else
        echo "✗ 端口 $port 未监听"
    fi
done

echo ""

# 5. 检查 Argo 隧道（如果配置）
echo "[5] 检查 Argo 隧道状态"
echo "-------------------------------------"

echo "$vless_ws_nodes" | while IFS='|' read -r port _ _ _ _ tunnel_domain; do
    if [[ "$tunnel_domain" != "无" && "$tunnel_domain" != "null" ]]; then
        echo "端口 $port 绑定了 Argo 隧道: $tunnel_domain"

        # 检查是否是临时隧道
        if [[ "$tunnel_domain" =~ trycloudflare\.com ]]; then
            echo "  类型: 临时隧道"
            # 查找进程
            pid=$(pgrep -f "cloudflared tunnel --url http://localhost:$port" | head -1)
            if [[ -n "$pid" ]]; then
                echo "  ✓ cloudflared 进程运行中 (PID: $pid)"
            else
                echo "  ✗ cloudflared 进程未运行"
            fi
        else
            echo "  类型: 专用隧道"
            # 查找专用隧道服务
            tunnel_name=$(jq -r ".nodes[] | select(.port == \"$port\") | .tunnel_name // \"\"" "$NODES_FILE")
            if [[ -n "$tunnel_name" && "$tunnel_name" != "null" ]]; then
                service_name="cloudflared-${tunnel_name}.service"
                if systemctl is-active --quiet "$service_name"; then
                    echo "  ✓ 专用隧道服务运行中: $service_name"
                else
                    echo "  ✗ 专用隧道服务未运行: $service_name"
                fi
            fi
        fi
    else
        echo "端口 $port 未绑定 Argo 隧道"
    fi
    echo ""
done

# 6. 生成测试命令
echo "[6] 测试建议"
echo "-------------------------------------"

echo "$vless_ws_nodes" | while IFS='|' read -r port ws_path tls_domain _ _ tunnel_domain; do
    echo "端口 $port 的测试命令:"
    echo ""

    if [[ "$tunnel_domain" != "无" && "$tunnel_domain" != "null" ]]; then
        # 有 Argo 隧道
        clean_domain=$(echo "$tunnel_domain" | sed -E 's|^https?://||')
        echo "  # 测试 Argo 隧道连接 (HTTPS)"
        echo "  curl -v --insecure https://${clean_domain}${ws_path} \\"
        echo "       -H 'Host: ${tls_domain}' \\"
        echo "       -H 'Upgrade: websocket' \\"
        echo "       -H 'Connection: Upgrade'"
    else
        # 没有 Argo 隧道
        echo "  # 测试本地 WebSocket + TLS"
        echo "  curl -v --insecure https://localhost:${port}${ws_path} \\"
        echo "       -H 'Host: ${tls_domain}' \\"
        echo "       -H 'Upgrade: websocket' \\"
        echo "       -H 'Connection: Upgrade'"
    fi
    echo ""
done

echo "====================================="
echo " 诊断完成"
echo "====================================="
