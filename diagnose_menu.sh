#!/bin/bash

echo "=========================================="
echo "  sing-box 菜单显示诊断脚本"
echo "=========================================="
echo ""

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

echo "📂 脚本目录: $SCRIPT_DIR"
echo ""

# 设置变量
DATA_DIR="${SCRIPT_DIR}/data"
MODULES_DIR="${SCRIPT_DIR}/modules"
SINGBOX_BINARY="/usr/local/bin/sing-box"

# ============================================
# 1. 文件检查
# ============================================
echo "1️⃣  文件存在性检查："
echo "-------------------------------------------"

files_to_check=(
    "modules/common.sh"
    "modules/ui_helper.sh"
    "modules/smart_tips.sh"
    "singbox-manager.sh"
)

for file in "${files_to_check[@]}"; do
    if [[ -f "$file" ]]; then
        size=$(ls -lh "$file" | awk '{print $5}')
        echo "   ✅ $file ($size)"
    else
        echo "   ❌ $file 不存在"
    fi
done
echo ""

# ============================================
# 2. 语法检查
# ============================================
echo "2️⃣  语法检查："
echo "-------------------------------------------"

for file in "${files_to_check[@]}"; do
    if [[ -f "$file" ]]; then
        if bash -n "$file" 2>/dev/null; then
            echo "   ✅ $file"
        else
            echo "   ❌ $file 语法错误："
            bash -n "$file" 2>&1 | sed 's/^/      /'
        fi
    fi
done
echo ""

# ============================================
# 3. 加载模块测试
# ============================================
echo "3️⃣  模块加载测试："
echo "-------------------------------------------"

# 加载 common.sh
echo "   📦 加载 common.sh..."
if [[ -f "${MODULES_DIR}/common.sh" ]]; then
    if source "${MODULES_DIR}/common.sh" 2>&1; then
        echo "      ✅ 加载成功"
    else
        echo "      ❌ 加载失败："
        source "${MODULES_DIR}/common.sh" 2>&1 | sed 's/^/         /'
        exit 1
    fi
else
    echo "      ❌ 文件不存在"
    exit 1
fi

# 检查颜色变量
echo "   🎨 检查颜色变量..."
for color in RED GREEN YELLOW BLUE CYAN NC; do
    if [[ -n "${!color}" ]]; then
        echo "      ✅ $color 已定义"
    else
        echo "      ❌ $color 未定义"
    fi
done

# 加载 ui_helper.sh
echo "   📦 加载 ui_helper.sh..."
if [[ -f "${MODULES_DIR}/ui_helper.sh" ]]; then
    # 捕获加载过程的输出
    load_output=$(source "${MODULES_DIR}/ui_helper.sh" 2>&1)
    load_status=$?
    
    if [[ $load_status -eq 0 ]]; then
        echo "      ✅ 加载成功 (退出码: $load_status)"
    else
        echo "      ❌ 加载失败 (退出码: $load_status)"
        if [[ -n "$load_output" ]]; then
            echo "      错误输出："
            echo "$load_output" | sed 's/^/         /'
        fi
        exit 1
    fi
    
    # 显示加载输出（如果有）
    if [[ -n "$load_output" ]]; then
        echo "      加载输出："
        echo "$load_output" | sed 's/^/         /'
    fi
else
    echo "      ❌ 文件不存在"
    exit 1
fi
echo ""

# ============================================
# 4. 函数检查
# ============================================
echo "4️⃣  函数存在性检查："
echo "-------------------------------------------"

functions_to_check=(
    "show_enhanced_main_menu"
    "get_service_status"
    "get_nodes_count"
    "get_users_count"
    "get_enabled_users_count"
    "get_bindings_count"
    "draw_title_box"
    "show_menu_item"
)

for func in "${functions_to_check[@]}"; do
    if declare -f "$func" &>/dev/null; then
        echo "   ✅ $func"
    else
        echo "   ❌ $func 不存在"
    fi
done
echo ""

# ============================================
# 5. 依赖变量检查
# ============================================
echo "5️⃣  依赖变量检查："
echo "-------------------------------------------"

vars_to_check=(
    "SCRIPT_DIR"
    "DATA_DIR"
    "MODULES_DIR"
    "SINGBOX_BINARY"
    "RED"
    "GREEN"
    "YELLOW"
    "BLUE"
    "CYAN"
    "NC"
)

for var in "${vars_to_check[@]}"; do
    if [[ -n "${!var}" ]]; then
        echo "   ✅ $var = ${!var}"
    else
        echo "   ❌ $var 未定义"
    fi
done
echo ""

# ============================================
# 6. 终端能力检查
# ============================================
echo "6️⃣  终端能力检查："
echo "-------------------------------------------"

echo "   📺 TERM: $TERM"
echo "   🌐 LANG: $LANG"
echo ""

echo "   Unicode 框线字符测试："
echo "      ╔═══╗"
echo "      ║   ║"
echo "      ╚═══╝"
echo ""

echo "   颜色测试："
echo -e "      ${RED}红色${NC} ${GREEN}绿色${NC} ${YELLOW}黄色${NC} ${BLUE}蓝色${NC} ${CYAN}青色${NC}"
echo ""

# ============================================
# 7. 尝试调用菜单
# ============================================
echo "7️⃣  尝试调用增强菜单："
echo "-------------------------------------------"

if declare -f show_enhanced_main_menu &>/dev/null; then
    echo "   ✅ show_enhanced_main_menu 函数存在，正在调用..."
    echo ""
    echo "========== 菜单输出开始 =========="
    show_enhanced_main_menu
    echo "========== 菜单输出结束 =========="
    echo ""
else
    echo "   ❌ show_enhanced_main_menu 函数不存在"
    echo ""
    echo "   可用的 show 函数："
    declare -F | grep show | sed 's/^/      /'
fi

echo ""
echo "=========================================="
echo "  诊断完成"
echo "=========================================="
