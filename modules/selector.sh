#!/bin/bash

#================================================================
# 统一选择器模块
# 功能：提供统一的单选和多选交互界面
# 版本：v1.0.0
#================================================================

# 注意：颜色变量已在 xray-manager.sh 中定义为 readonly
# 此模块通过 source 引入，无需重复定义

#================================================================
# 单选函数
# 用法: selected_index=$(select_single "请选择" "${items[@]}")
# 返回: 选中项的索引（0-based）
#================================================================
select_single() {
    local prompt="$1"
    shift
    local items=("$@")

    if [[ ${#items[@]} -eq 0 ]]; then
        echo -e "${RED}错误: 没有可选项${NC}" >&2
        return 1
    fi

    # 显示列表
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    for i in "${!items[@]}"; do
        echo -e "${CYAN}[$((i+1))]${NC} ${items[$i]}"
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 获取选择
    local max_attempts=3
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        read -p "$prompt [1-${#items[@]}]: " choice

        # 验证输入
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#items[@]} ]]; then
            echo $((choice-1))
            return 0
        fi

        ((attempt++))
        if [[ $attempt -lt $max_attempts ]]; then
            echo -e "${YELLOW}无效选择，请重新输入 (${attempt}/${max_attempts})${NC}"
        fi
    done

    echo -e "${RED}超过最大尝试次数${NC}" >&2
    return 1
}

#================================================================
# 多选函数
# 用法: selected_indices=($(select_multiple "请选择" "${items[@]}"))
# 返回: 选中项的索引列表（空格分隔，0-based）
# 支持格式:
#   - 单个: 1
#   - 多个: 1,3,5
#   - 范围: 1-3
#   - 全部: all
#================================================================
select_multiple() {
    local prompt="$1"
    shift
    local items=("$@")

    if [[ ${#items[@]} -eq 0 ]]; then
        echo -e "${RED}错误: 没有可选项${NC}" >&2
        return 1
    fi

    # 显示列表
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    for i in "${!items[@]}"; do
        echo -e "${CYAN}[$((i+1))]${NC} ${items[$i]}"
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}支持格式：${NC}"
    echo "  单个: 1"
    echo "  多个: 1,3,5"
    echo "  范围: 1-3"
    echo "  全部: all"
    echo ""

    local max_attempts=3
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        read -p "$prompt: " input

        # 处理空输入
        if [[ -z "$input" ]]; then
            ((attempt++))
            echo -e "${YELLOW}请输入选择${NC}"
            continue
        fi

        # 处理 all
        if [[ "$input" == "all" ]]; then
            local all_indices=()
            for i in "${!items[@]}"; do
                all_indices+=("$i")
            done
            echo "${all_indices[@]}"
            return 0
        fi

        # 解析选择
        local selected_indices=()
        local valid=true

        IFS=',' read -ra parts <<< "$input"

        for part in "${parts[@]}"; do
            # 去除空格
            part=$(echo "$part" | tr -d ' ')

            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                # 范围选择
                local start=${BASH_REMATCH[1]}
                local end=${BASH_REMATCH[2]}

                if [[ $start -lt 1 ]] || [[ $end -gt ${#items[@]} ]] || [[ $start -gt $end ]]; then
                    valid=false
                    break
                fi

                for ((i=start; i<=end; i++)); do
                    selected_indices+=($((i-1)))
                done
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                # 单个选择
                if [[ $part -lt 1 ]] || [[ $part -gt ${#items[@]} ]]; then
                    valid=false
                    break
                fi
                selected_indices+=($((part-1)))
            else
                valid=false
                break
            fi
        done

        if [[ "$valid" == true ]] && [[ ${#selected_indices[@]} -gt 0 ]]; then
            # 去重并排序
            local unique_indices=($(printf '%s\n' "${selected_indices[@]}" | sort -nu))
            echo "${unique_indices[@]}"
            return 0
        fi

        ((attempt++))
        if [[ $attempt -lt $max_attempts ]]; then
            echo -e "${YELLOW}无效选择，请重新输入 (${attempt}/${max_attempts})${NC}"
        fi
    done

    echo -e "${RED}超过最大尝试次数${NC}" >&2
    return 1
}

#================================================================
# 确认提示函数
# 用法: confirm "确认删除?" && do_delete
# 返回: 0=确认, 1=取消
#================================================================
confirm() {
    local prompt="$1"
    local default="${2:-N}"  # 默认值 Y 或 N

    local prompt_text
    if [[ "$default" == "Y" ]]; then
        prompt_text="$prompt [Y/n]: "
    else
        prompt_text="$prompt [y/N]: "
    fi

    read -p "$prompt_text" response
    response=${response:-$default}

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

#================================================================
# 显示列表（带分页）
# 用法: show_list "标题" "${items[@]}"
#================================================================
show_list() {
    local title="$1"
    shift
    local items=("$@")

    local page_size=15
    local total=${#items[@]}
    local pages=$(( (total + page_size - 1) / page_size ))
    local current_page=1

    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  $title${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""

        local start=$(( (current_page - 1) * page_size ))
        local end=$(( start + page_size ))
        [[ $end -gt $total ]] && end=$total

        echo -e "${YELLOW}显示 $((start+1))-${end} / 共 ${total} 项${NC}"
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        for ((i=start; i<end; i++)); do
            echo -e "${CYAN}[$((i+1))]${NC} ${items[$i]}"
        done

        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        if [[ $pages -gt 1 ]]; then
            echo -e "${GREEN}[N]${NC} 下一页  ${GREEN}[P]${NC} 上一页  ${GREEN}[Q]${NC} 退出  (第 $current_page/$pages 页)"
            echo ""
            read -p "操作: " action

            case "$action" in
                [Nn])
                    if [[ $current_page -lt $pages ]]; then
                        ((current_page++))
                    else
                        echo -e "${YELLOW}已经是最后一页${NC}"
                        sleep 1
                    fi
                    ;;
                [Pp])
                    if [[ $current_page -gt 1 ]]; then
                        ((current_page--))
                    else
                        echo -e "${YELLOW}已经是第一页${NC}"
                        sleep 1
                    fi
                    ;;
                [Qq])
                    break
                    ;;
                *)
                    echo -e "${YELLOW}无效操作${NC}"
                    sleep 1
                    ;;
            esac
        else
            break
        fi
    done
}

#================================================================
# 搜索和过滤
# 用法: filtered=($(filter_items "keyword" "${items[@]}"))
#================================================================
filter_items() {
    local keyword="$1"
    shift
    local items=("$@")

    local filtered=()
    for item in "${items[@]}"; do
        if [[ "$item" =~ $keyword ]]; then
            filtered+=("$item")
        fi
    done

    echo "${filtered[@]}"
}

#================================================================
# 进度条显示
# 用法: show_progress 50 100 "处理中..."
#================================================================
show_progress() {
    local current=$1
    local total=$2
    local message="${3:-处理中}"

    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))

    printf "\r${CYAN}%s${NC} [" "$message"
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%%" "$percent"

    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

#================================================================
# 输入验证函数
#================================================================

# 验证端口号
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [[ $port -ge 1 ]] && [[ $port -le 65535 ]]; then
        return 0
    fi
    return 1
}

# 验证IP地址
validate_ip() {
    local ip=$1
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            if [[ $octet -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# 验证域名
validate_domain() {
    local domain=$1
    if [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# 验证邮箱
validate_email() {
    local email=$1
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

#================================================================
# 测试函数
#================================================================
test_selector() {
    echo "=== 统一选择器测试 ==="
    echo ""

    # 测试单选
    echo "测试 1: 单选"
    local test_items=("选项A" "选项B" "选项C")
    local selected=$(select_single "请选择一项" "${test_items[@]}")
    if [[ $? -eq 0 ]]; then
        echo "你选择了: ${test_items[$selected]}"
    fi
    echo ""

    # 测试多选
    echo "测试 2: 多选"
    local selected_multiple=($(select_multiple "请选择多项" "${test_items[@]}"))
    if [[ $? -eq 0 ]]; then
        echo "你选择了 ${#selected_multiple[@]} 项:"
        for idx in "${selected_multiple[@]}"; do
            echo "  - ${test_items[$idx]}"
        done
    fi
    echo ""

    # 测试确认
    echo "测试 3: 确认提示"
    if confirm "确认继续?"; then
        echo "用户确认"
    else
        echo "用户取消"
    fi
    echo ""

    # 测试列表显示
    echo "测试 4: 列表显示"
    local long_list=()
    for i in {1..25}; do
        long_list+=("项目 $i")
    done
    show_list "测试列表" "${long_list[@]}"
}

# 如果直接运行此脚本，执行测试
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    test_selector
fi
