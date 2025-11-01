#!/bin/bash

# 模拟完整的主程序加载流程
SCRIPT_DIR="/c/code/s-singbox"
cd "$SCRIPT_DIR"

DATA_DIR="${SCRIPT_DIR}/data"
MODULES_DIR="${SCRIPT_DIR}/modules"
SINGBOX_BINARY="/usr/local/bin/sing-box"

echo "=== 测试完整加载流程 ==="
echo ""

# 1. 加载 common.sh
if [[ -f "${MODULES_DIR}/common.sh" ]]; then
    source "${MODULES_DIR}/common.sh"
    echo "✅ common.sh 已加载"
fi

# 2. 加载 ui_helper.sh（使用修复后的方式）
if [[ -f "${MODULES_DIR}/ui_helper.sh" ]]; then
    source "${MODULES_DIR}/ui_helper.sh"
    if declare -f show_enhanced_main_menu &>/dev/null; then
        echo "✅ ui_helper.sh 已加载，增强菜单可用"
    else
        echo "❌ ui_helper.sh 已加载但函数不可用"
    fi
fi

echo ""
echo "=== 函数验证 ==="
declare -f show_enhanced_main_menu &>/dev/null && echo "✅ show_enhanced_main_menu" || echo "❌ show_enhanced_main_menu"
declare -f get_nodes_count &>/dev/null && echo "✅ get_nodes_count" || echo "❌ get_nodes_count"
declare -f get_service_status &>/dev/null && echo "✅ get_service_status" || echo "❌ get_service_status"

echo ""
echo "=== 调用增强菜单 ==="
echo ""
show_enhanced_main_menu | head -25

