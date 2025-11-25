#!/bin/bash

# 配置修复和重新生成脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "======================================"
echo "  sing-box 配置修复工具"  
echo "======================================"
echo ""

echo "[1] 加载模块..."
source "$PROJECT_ROOT/modules/common.sh"
source "$PROJECT_ROOT/modules/config_generator_singbox.sh"

echo ""
echo "[2] 备份现有配置..."
if [[ -f "/opt/s-singbox/config.json" ]]; then
    cp /opt/s-singbox/config.json /opt/s-singbox/config.json.backup.$(date +%Y%m%d_%H%M%S)
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
echo "[4] 验证配置文件..."
if sing-box check -c /opt/s-singbox/config.json; then
    echo "✓ 配置文件验证通过"
else
    echo "❌ 配置文件验证失败"
    echo "   请检查配置文件: /opt/s-singbox/config.json"
    exit 1
fi

echo ""
echo "[5] 重启 sing-box 服务..."
if systemctl restart sing-box; then
    echo "✓ 服务重启成功"
    sleep 2
    if systemctl is-active --quiet sing-box; then
        echo "✓ 服务运行正常"
    else
        echo "❌ 服务启动失败"
        echo "   查看日志: journalctl -u sing-box -n 50"
        exit 1
    fi
else
    echo "❌ 服务重启失败"
    exit 1
fi

echo ""
echo "[6] 检查服务日志（最近10行）..."
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

