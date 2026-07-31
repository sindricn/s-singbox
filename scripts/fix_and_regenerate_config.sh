#!/bin/bash

# 配置修复和重新生成脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'
DATA_DIR="/var/lib/sing-box"
SINGBOX_DIR="/etc/sing-box"
SINGBOX_CONFIG="${SINGBOX_DIR}/config.json"
SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
USERS_FILE="${DATA_DIR}/users.json"
NODES_FILE="${DATA_DIR}/nodes.json"
NODE_USERS_FILE="${DATA_DIR}/node_users.json"
SUBSCRIPTION_DIR="${DATA_DIR}/subscriptions"

echo "======================================"
echo "  sing-box 配置修复工具"  
echo "======================================"
echo ""

echo "[1] 加载模块..."
source "$PROJECT_ROOT/modules/common.sh"
source "$PROJECT_ROOT/modules/config_generator_singbox.sh"
source "$PROJECT_ROOT/modules/zz_singbox_114.sh"
initialize_runtime_state || exit 1

echo ""
echo "[2] 备份现有配置..."
if [[ -f "/etc/sing-box/config.json" ]]; then
    cp /etc/sing-box/config.json /etc/sing-box/config.json.backup.$(date +%Y%m%d_%H%M%S)
    echo "✓ 配置已备份"
else
    echo "⚠️  没有找到现有配置"
fi

echo ""
echo "[3] 重新生成配置..."
if generate_singbox_config; then
    echo "✓ 配置生成成功"
else
    echo "❌ 配置生成失败"
    exit 1
fi

echo ""
echo "[4] 事务化重启并验证 sing-box 服务..."
if ! restart_sing-box; then
    echo "❌ 服务重启失败，配置和数据已回滚"
    exit 1
fi

echo ""
echo "[5] 检查服务日志（最近10行）..."
journalctl -u sing-box -n 10 --no-pager

echo ""
echo "======================================"
echo "  修复完成"
echo "======================================"
echo ""
echo "请检查："
echo "1. 是否还有 domain_resolver 警告"
echo "2. Hysteria2 节点是否可以正常连接"
echo ""
echo "如果仍有问题，运行诊断："
echo "  bash scripts/diagnose_hy2.sh"

