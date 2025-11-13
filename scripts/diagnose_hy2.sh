#!/bin/bash

# Hysteria2 配置诊断脚本
# 用于检查 Hysteria2 节点的配置问题

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_ROOT/data"
NODES_FILE="$DATA_DIR/nodes.json"
CONFIG_FILE="/opt/s-singbox/config.json"

echo "======================================"
echo "  Hysteria2 配置诊断工具"
echo "======================================"
echo ""

# 1. 检查节点数据文件
echo "[1] 检查节点数据文件..."
if [[ ! -f "$NODES_FILE" ]]; then
    echo "❌ 节点文件不存在: $NODES_FILE"
    exit 1
fi

# 查找Hysteria2节点
hy2_count=$(jq '[.nodes[] | select(.protocol == "hysteria2")] | length' "$NODES_FILE" 2>/dev/null)
if [[ "$hy2_count" -eq 0 ]]; then
    echo "⚠️  没有找到 Hysteria2 节点"
    exit 0
fi

echo "✓ 找到 $hy2_count 个 Hysteria2 节点"
echo ""

# 2. 检查每个节点的配置
echo "[2] 检查节点配置详情..."
jq -r '.nodes[] | select(.protocol == "hysteria2") | 
    "节点端口: \(.port)\n" +
    "  extra.obfs_password: \(.extra.obfs_password // "❌ 未设置")\n" +
    "  extra.tls_domain: \(.extra.tls_domain // "❌ 未设置")\n" +
    "  extra.tls_cert: \(.extra.tls_cert // "❌ 未设置")\n" +
    "  extra.port_hopping: \(.extra.port_hopping // "未启用")\n" +
    "  extra.up_mbps: \(.extra.up_mbps // 0)\n" +
    "  extra.down_mbps: \(.extra.down_mbps // 0)\n"' \
    "$NODES_FILE"

echo ""

# 3. 检查配置文件
echo "[3] 检查 sing-box 配置文件..."
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "⚠️  配置文件不存在: $CONFIG_FILE"
    echo "   提示：需要运行 singbox-manager.sh 生成配置"
    exit 0
fi

# 检查Hysteria2 inbound配置
echo "✓ 配置文件存在，检查 Hysteria2 inbound..."
jq '.inbounds[] | select(.type == "hysteria2") | 
    {
        port: .listen_port,
        has_obfs: (.obfs != null),
        obfs_type: .obfs.type,
        has_tls: (.tls != null),
        has_masquerade: (.masquerade != null)
    }' "$CONFIG_FILE" 2>/dev/null

echo ""

# 4. 检查sing-box服务状态和日志
echo "[4] 检查 sing-box 服务状态..."
if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet sing-box; then
        echo "✓ sing-box 服务运行中"
        echo ""
        echo "最近的日志（包含警告/错误）："
        journalctl -u sing-box -n 20 --no-pager 2>/dev/null | grep -E "WARN|ERROR|hysteria2|obfs|domain_resolver" || echo "  无相关日志"
    else
        echo "⚠️  sing-box 服务未运行"
    fi
else
    echo "⚠️  无法检查服务状态（systemctl 不可用）"
fi

echo ""
echo "======================================"
echo "  诊断完成"
echo "======================================"
echo ""
echo "如果发现问题，请按以下步骤修复："
echo "1. 如果 obfs_password 未设置：重新创建 Hysteria2 节点"
echo "2. 如果配置文件中没有 obfs 字段：运行配置生成命令"
echo "3. 如果有 domain_resolver 警告：重新生成配置（已修复）"

