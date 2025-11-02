#!/bin/bash

# =============================================================================
# quick_wizard.sh - 快速部署向导模块
# 帮助新用户快速完成初始配置
# =============================================================================

# 依赖检查（严格模式兼容）
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# 加载依赖模块
if ! declare -f print_error &>/dev/null; then
    if [[ -f "${SCRIPT_DIR}/modules/common.sh" ]]; then
        source "${SCRIPT_DIR}/modules/common.sh"
    fi
fi

# 加载UI模块（如果可用）
if [[ -f "${SCRIPT_DIR:-}/modules/ui_helper.sh" ]]; then
    source "${SCRIPT_DIR}/modules/ui_helper.sh"
fi

# =============================================================================
# 向导步骤定义
# =============================================================================

# 向导步骤状态
WIZARD_STEP_1_DONE=false  # 添加节点
WIZARD_STEP_2_DONE=false  # 添加用户
WIZARD_STEP_3_DONE=false  # 绑定关系
WIZARD_STEP_4_DONE=false  # 生成配置
WIZARD_STEP_5_DONE=false  # 启动服务

# =============================================================================
# 向导显示函数
# =============================================================================

# 显示欢迎界面
show_wizard_welcome() {
    clear

    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "快速部署向导" 68
    else
        print_header "快速部署向导"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}欢迎使用 sing-box 快速部署向导！${NC}"
    echo ""
    echo -e "本向导将引导您完成以下步骤："
    echo ""
    echo -e "  ${CYAN}1.${NC} 添加第一个代理节点"
    echo -e "  ${CYAN}2.${NC} 创建第一个用户账号"
    echo -e "  ${CYAN}3.${NC} 绑定用户到节点"
    echo -e "  ${CYAN}4.${NC} 生成配置文件"
    echo -e "  ${CYAN}5.${NC} 启动 sing-box 服务"
    echo ""
    echo -e "${GREEN}预计耗时: 5-10 分钟${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if declare -f confirm_action &>/dev/null; then
        if ! confirm_action "是否开始向导" "y"; then
            return 1
        fi
    else
        read -p "$(echo -e ${CYAN}是否开始向导? [Y/n]: ${NC})" response
        response=${response:-Y}
        if [[ ! "$response" =~ ^[Yy] ]]; then
            return 1
        fi
    fi

    return 0
}

# 显示步骤标题
show_wizard_step() {
    local step=$1
    local title=$2
    local total=${3:-5}

    clear

    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "快速部署向导 - 步骤 $step/$total" 68
    else
        print_header "快速部署向导 - 步骤 $step/$total"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}${BOLD}${title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# 显示进度条
show_wizard_progress() {
    local current=$1
    local total=${2:-5}

    echo ""
    echo -e "${CYAN}总体进度:${NC}"

    if declare -f show_progress_bar &>/dev/null; then
        show_progress_bar $current $total 50 "完成"
    else
        local percentage=$((current * 100 / total))
        echo -e "${YELLOW}$percentage% 完成 ($current/$total)${NC}"
    fi
    echo ""
}

# 显示步骤完成
show_step_complete() {
    local message=$1

    echo ""
    if declare -f draw_separator &>/dev/null; then
        draw_separator 68
    fi
    echo -e "${GREEN}✔ $message${NC}"
    if declare -f draw_separator &>/dev/null; then
        draw_separator 68
    fi
    echo ""
}

# =============================================================================
# 向导步骤 1: 添加节点
# =============================================================================

wizard_step_add_node() {
    show_wizard_step 1 "添加代理节点"

    echo -e "${YELLOW}提示:${NC} 请选择要添加的节点类型"
    echo ""
    echo -e "  ${CYAN}1)${NC} VMess (推荐)"
    echo -e "  ${CYAN}2)${NC} VLESS"
    echo -e "  ${CYAN}3)${NC} Trojan"
    echo -e "  ${CYAN}4)${NC} Shadowsocks"
    echo -e "  ${CYAN}5)${NC} Hysteria2"
    echo ""
    read -p "$(echo -e ${CYAN}请选择协议 [1-5]: ${NC})" protocol_choice

    case "$protocol_choice" in
        1)
            echo ""
            echo -e "${CYAN}正在添加 VMess 节点...${NC}"
            if declare -f add_node &>/dev/null; then
                # 调用node.sh的add_node函数，传入协议类型
                add_node "vmess"
                if [[ $? -eq 0 ]]; then
                    WIZARD_STEP_1_DONE=true
                    show_step_complete "VMess 节点添加成功"
                    return 0
                else
                    print_error "节点添加失败"
                    return 1
                fi
            else
                print_error "节点管理模块未加载"
                return 1
            fi
            ;;
        2)
            echo ""
            echo -e "${CYAN}正在添加 VLESS 节点...${NC}"
            if declare -f add_node &>/dev/null; then
                add_node "vless"
                if [[ $? -eq 0 ]]; then
                    WIZARD_STEP_1_DONE=true
                    show_step_complete "VLESS 节点添加成功"
                    return 0
                fi
            fi
            ;;
        3)
            echo ""
            echo -e "${CYAN}正在添加 Trojan 节点...${NC}"
            if declare -f add_node &>/dev/null; then
                add_node "trojan"
                if [[ $? -eq 0 ]]; then
                    WIZARD_STEP_1_DONE=true
                    show_step_complete "Trojan 节点添加成功"
                    return 0
                fi
            fi
            ;;
        4)
            echo ""
            echo -e "${CYAN}正在添加 Shadowsocks 节点...${NC}"
            if declare -f add_node &>/dev/null; then
                add_node "shadowsocks"
                if [[ $? -eq 0 ]]; then
                    WIZARD_STEP_1_DONE=true
                    show_step_complete "Shadowsocks 节点添加成功"
                    return 0
                fi
            fi
            ;;
        5)
            echo ""
            echo -e "${CYAN}正在添加 Hysteria2 节点...${NC}"
            if declare -f add_node &>/dev/null; then
                add_node "hysteria2"
                if [[ $? -eq 0 ]]; then
                    WIZARD_STEP_1_DONE=true
                    show_step_complete "Hysteria2 节点添加成功"
                    return 0
                fi
            fi
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac

    return 1
}

# =============================================================================
# 向导步骤 2: 添加用户
# =============================================================================

wizard_step_add_user() {
    show_wizard_step 2 "创建用户账号"

    echo -e "${YELLOW}提示:${NC} 请输入用户信息"
    echo ""

    # 输入用户名
    while true; do
        read -p "$(echo -e ${CYAN}用户名: ${NC})" username
        if [[ -z "$username" ]]; then
            print_error "用户名不能为空"
            continue
        fi

        # 检查用户名是否存在
        if declare -f username_exists &>/dev/null; then
            if username_exists "$username"; then
                print_error "用户名已存在，请使用其他用户名"
                continue
            fi
        fi
        break
    done

    # 输入邮箱
    while true; do
        read -p "$(echo -e ${CYAN}邮箱\ \(可选\):\ ${NC})" email
        if [[ -z "$email" ]]; then
            email="${username}@example.com"
            echo -e "${GRAY}使用默认邮箱: $email${NC}"
            break
        fi

        # 验证邮箱格式
        if declare -f validate_email &>/dev/null; then
            if validate_email "$email"; then
                break
            else
                print_error "邮箱格式无效"
            fi
        else
            break
        fi
    done

    # 添加用户
    echo ""
    echo -e "${CYAN}正在创建用户...${NC}"

    if declare -f add_user &>/dev/null; then
        # 调用user.sh的add_user函数
        # 需要模拟交互输入
        echo -e "$username\n$email\n" | add_user
        if [[ $? -eq 0 ]]; then
            WIZARD_STEP_2_DONE=true
            show_step_complete "用户 '$username' 创建成功"
            return 0
        else
            print_error "用户创建失败"
            return 1
        fi
    else
        print_error "用户管理模块未加载"
        return 1
    fi
}

# =============================================================================
# 向导步骤 3: 绑定用户到节点
# =============================================================================

wizard_step_bind_user() {
    show_wizard_step 3 "绑定用户到节点"

    echo -e "${YELLOW}提示:${NC} 将用户绑定到节点以允许访问"
    echo ""

    # 获取节点列表
    local nodes_count=$(get_nodes_count 2>/dev/null || echo "0")
    if [[ "$nodes_count" == "0" ]]; then
        print_error "没有可用的节点，请先添加节点"
        return 1
    fi

    # 获取用户列表
    local users_count=$(get_users_count 2>/dev/null || echo "0")
    if [[ "$users_count" == "0" ]]; then
        print_error "没有可用的用户，请先添加用户"
        return 1
    fi

    echo -e "${CYAN}正在绑定用户到节点...${NC}"
    echo ""

    if declare -f bind_user_to_node &>/dev/null; then
        bind_user_to_node
        if [[ $? -eq 0 ]]; then
            WIZARD_STEP_3_DONE=true
            show_step_complete "用户绑定成功"
            return 0
        else
            print_error "绑定失败"
            return 1
        fi
    else
        print_error "绑定管理模块未加载"
        return 1
    fi
}

# =============================================================================
# 向导步骤 4: 生成配置
# =============================================================================

wizard_step_generate_config() {
    show_wizard_step 4 "生成配置文件"

    echo -e "${YELLOW}提示:${NC} 根据节点和用户生成 sing-box 配置文件"
    echo ""

    echo -e "${CYAN}正在生成配置...${NC}"

    if declare -f generate_config &>/dev/null; then
        generate_config
        if [[ $? -eq 0 ]]; then
            WIZARD_STEP_4_DONE=true
            show_step_complete "配置文件生成成功"
            return 0
        else
            print_error "配置生成失败"
            return 1
        fi
    else
        print_error "配置生成模块未加载"
        return 1
    fi
}

# =============================================================================
# 向导步骤 5: 启动服务
# =============================================================================

wizard_step_start_service() {
    show_wizard_step 5 "启动 sing-box 服务"

    echo -e "${YELLOW}提示:${NC} 启动服务使配置生效"
    echo ""

    # 检查服务状态
    local service_status=$(get_service_status 2>/dev/null || echo "unknown")

    if [[ "$service_status" == "running" ]]; then
        echo -e "${YELLOW}服务已在运行，将重启服务以应用新配置${NC}"
        echo ""

        if declare -f confirm_action &>/dev/null; then
            if ! confirm_action "是否重启服务" "y"; then
                return 1
            fi
        fi

        if declare -f restart_singbox &>/dev/null; then
            restart_singbox
        else
            systemctl restart sing-box
        fi
    else
        echo -e "${CYAN}正在启动服务...${NC}"

        if declare -f start_singbox &>/dev/null; then
            start_singbox
        else
            systemctl start sing-box
        fi
    fi

    if [[ $? -eq 0 ]]; then
        WIZARD_STEP_5_DONE=true
        show_step_complete "服务启动成功"

        # 等待服务完全启动
        sleep 2

        # 验证服务状态
        if systemctl is-active --quiet sing-box; then
            echo -e "${GREEN}✔ 服务运行正常${NC}"
        else
            print_error "服务启动失败，请查看日志"
            return 1
        fi

        return 0
    else
        print_error "服务启动失败"
        return 1
    fi
}

# =============================================================================
# 向导完成界面
# =============================================================================

show_wizard_complete() {
    clear

    if declare -f draw_title_box &>/dev/null; then
        draw_title_box "快速部署完成！" 68
    else
        print_header "快速部署完成！"
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}恭喜！您已成功完成 sing-box 的初始配置${NC}"
    echo ""
    echo -e "已完成的步骤:"
    echo -e "  ${GREEN}✔${NC} 添加代理节点"
    echo -e "  ${GREEN}✔${NC} 创建用户账号"
    echo -e "  ${GREEN}✔${NC} 绑定用户到节点"
    echo -e "  ${GREEN}✔${NC} 生成配置文件"
    echo -e "  ${GREEN}✔${NC} 启动 sing-box 服务"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}下一步操作建议:${NC}"
    echo ""
    echo -e "  ${CYAN}•${NC} 使用 ${YELLOW}主菜单 > 查看状态${NC} 检查服务运行情况"
    echo -e "  ${CYAN}•${NC} 使用 ${YELLOW}主菜单 > 查看日志${NC} 查看服务日志"
    echo -e "  ${CYAN}•${NC} 使用 ${YELLOW}主菜单 > 用户管理${NC} 查看用户连接信息"
    echo -e "  ${CYAN}•${NC} 使用 ${YELLOW}主菜单 > 证书管理${NC} 配置 TLS 证书（推荐）"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if declare -f wait_for_key &>/dev/null; then
        wait_for_key "按回车键返回主菜单"
    else
        read -p "按回车键返回主菜单..."
    fi
}

# =============================================================================
# 主向导流程
# =============================================================================

run_quick_wizard() {
    # 显示欢迎界面
    if ! show_wizard_welcome; then
        print_info "已取消向导"
        return 0
    fi

    local current_step=0
    local total_steps=5

    # 步骤 1: 添加节点
    current_step=1
    if ! wizard_step_add_node; then
        print_error "向导中断于步骤 $current_step"
        if declare -f wait_for_key &>/dev/null; then
            wait_for_key "按回车键继续"
        else
            read -p "按回车键继续..."
        fi
        return 1
    fi
    if declare -f wait_for_key &>/dev/null; then
        wait_for_key "按回车键继续下一步"
    else
        read -p "按回车键继续下一步..."
    fi

    # 步骤 2: 添加用户
    current_step=2
    if ! wizard_step_add_user; then
        print_error "向导中断于步骤 $current_step"
        if declare -f wait_for_key &>/dev/null; then
            wait_for_key "按回车键继续"
        else
            read -p "按回车键继续..."
        fi
        return 1
    fi
    if declare -f wait_for_key &>/dev/null; then
        wait_for_key "按回车键继续下一步"
    else
        read -p "按回车键继续下一步..."
    fi

    # 步骤 3: 绑定用户到节点
    current_step=3
    if ! wizard_step_bind_user; then
        print_error "向导中断于步骤 $current_step"
        if declare -f wait_for_key &>/dev/null; then
            wait_for_key "按回车键继续"
        else
            read -p "按回车键继续..."
        fi
        return 1
    fi
    if declare -f wait_for_key &>/dev/null; then
        wait_for_key "按回车键继续下一步"
    else
        read -p "按回车键继续下一步..."
    fi

    # 步骤 4: 生成配置
    current_step=4
    if ! wizard_step_generate_config; then
        print_error "向导中断于步骤 $current_step"
        if declare -f wait_for_key &>/dev/null; then
            wait_for_key "按回车键继续"
        else
            read -p "按回车键继续..."
        fi
        return 1
    fi
    if declare -f wait_for_key &>/dev/null; then
        wait_for_key "按回车键继续下一步"
    else
        read -p "按回车键继续下一步..."
    fi

    # 步骤 5: 启动服务
    current_step=5
    if ! wizard_step_start_service; then
        print_error "向导中断于步骤 $current_step"
        if declare -f wait_for_key &>/dev/null; then
            wait_for_key "按回车键继续"
        else
            read -p "按回车键继续..."
        fi
        return 1
    fi

    # 显示完成界面
    show_wizard_complete

    return 0
}

# =============================================================================
# 模块初始化
# =============================================================================

log_debug "quick_wizard.sh 模块已加载"
