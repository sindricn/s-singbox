#!/bin/bash

# =============================================================================
# sing-box 出站规则管理模块
# 功能：出站配置管理、路由规则、分流策略
# =============================================================================

DATA_DIR="./data"
OUTBOUNDS_FILE="${DATA_DIR}/outbounds.json"
ROUTE_RULES_FILE="${DATA_DIR}/route_rules.json"
SINGBOX_CONFIG_FILE="/usr/local/singbox/config.json"

# =============================================================================
# 出站数据初始化
# =============================================================================

init_outbounds_file() {
    if [[ ! -f "$OUTBOUNDS_FILE" ]]; then
        cat > "$OUTBOUNDS_FILE" <<EOF
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
        print_success "outbounds.json 初始化完成"
    fi
}

init_route_rules_file() {
    if [[ ! -f "$ROUTE_RULES_FILE" ]]; then
        cat > "$ROUTE_RULES_FILE" <<EOF
{
  "rules": [
    {
      "protocol": "dns",
      "outbound": "dns-out"
    },
    {
      "rule_set": "geosite-cn",
      "outbound": "direct"
    },
    {
      "rule_set": "geoip-cn",
      "outbound": "direct"
    },
    {
      "ip_is_private": true,
      "outbound": "direct"
    }
  ],
  "rule_sets": [
    {
      "type": "remote",
      "tag": "geosite-cn",
      "format": "binary",
      "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs",
      "download_detour": "direct"
    },
    {
      "type": "remote",
      "tag": "geoip-cn",
      "format": "binary",
      "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs",
      "download_detour": "direct"
    }
  ],
  "final": "direct"
}
EOF
        print_success "route_rules.json 初始化完成"
    fi
}

# =============================================================================
# 出站管理函数
# =============================================================================

# 添加出站
add_outbound() {
    print_info "添加出站配置"

    echo "请选择出站类型:"
    echo "1) Direct (直连)"
    echo "2) Block (拦截)"
    echo "3) DNS (DNS 出站)"
    echo "4) Selector (选择器)"
    echo "5) URLTest (自动选择)"
    echo "0) 返回"

    read -p "请选择 [1]: " type_choice
    type_choice=${type_choice:-1}

    case "$type_choice" in
        1)
            add_direct_outbound
            ;;
        2)
            add_block_outbound
            ;;
        3)
            add_dns_outbound
            ;;
        4)
            add_selector_outbound
            ;;
        5)
            add_urltest_outbound
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac
}

# 添加 Direct 出站
add_direct_outbound() {
    read -p "请输入出站标签: " tag

    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    local existing=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUNDS_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        print_error "标签已存在: $tag"
        return 1
    fi

    # 生成出站配置
    local outbound=$(jq -n \
        --arg tag "$tag" \
        '{
            type: "direct",
            tag: $tag
        }')

    # 添加到 outbounds.json
    local outbounds_data=$(cat "$OUTBOUNDS_FILE")
    outbounds_data=$(echo "$outbounds_data" | jq --argjson outbound "$outbound" '.outbounds += [$outbound]')
    echo "$outbounds_data" | jq '.' > "$OUTBOUNDS_FILE"

    print_success "Direct 出站添加成功: $tag"
}

# 添加 Block 出站
add_block_outbound() {
    read -p "请输入出站标签: " tag

    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    local existing=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUNDS_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        print_error "标签已存在: $tag"
        return 1
    fi

    # 生成出站配置
    local outbound=$(jq -n \
        --arg tag "$tag" \
        '{
            type: "block",
            tag: $tag
        }')

    # 添加到 outbounds.json
    local outbounds_data=$(cat "$OUTBOUNDS_FILE")
    outbounds_data=$(echo "$outbounds_data" | jq --argjson outbound "$outbound" '.outbounds += [$outbound]')
    echo "$outbounds_data" | jq '.' > "$OUTBOUNDS_FILE"

    print_success "Block 出站添加成功: $tag"
}

# 添加 DNS 出站
add_dns_outbound() {
    local tag="dns-out"

    # 生成出站配置
    local outbound=$(jq -n \
        '{
            type: "dns",
            tag: "dns-out"
        }')

    # 检查是否已存在
    local existing=$(jq -r '.outbounds[] | select(.tag == "dns-out")' "$OUTBOUNDS_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        print_warn "DNS 出站已存在"
        return 0
    fi

    # 添加到 outbounds.json
    local outbounds_data=$(cat "$OUTBOUNDS_FILE")
    outbounds_data=$(echo "$outbounds_data" | jq --argjson outbound "$outbound" '.outbounds += [$outbound]')
    echo "$outbounds_data" | jq '.' > "$OUTBOUNDS_FILE"

    print_success "DNS 出站添加成功"
}

# 添加 Selector 出站
add_selector_outbound() {
    read -p "请输入选择器标签: " tag

    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 检查标签是否已存在
    local existing=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$OUTBOUNDS_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        print_error "标签已存在: $tag"
        return 1
    fi

    # 输入出站列表
    read -p "请输入出站标签列表 (用空格分隔): " outbounds_list

    if [[ -z "$outbounds_list" ]]; then
        print_error "出站列表不能为空"
        return 1
    fi

    # 构建出站数组
    local outbounds_array="[]"
    for outbound_tag in $outbounds_list; do
        outbounds_array=$(echo "$outbounds_array" | jq --arg tag "$outbound_tag" '. += [$tag]')
    done

    # 生成出站配置
    local outbound=$(jq -n \
        --arg tag "$tag" \
        --argjson outbounds "$outbounds_array" \
        '{
            type: "selector",
            tag: $tag,
            outbounds: $outbounds,
            default: $outbounds[0]
        }')

    # 添加到 outbounds.json
    local outbounds_data=$(cat "$OUTBOUNDS_FILE")
    outbounds_data=$(echo "$outbounds_data" | jq --argjson outbound "$outbound" '.outbounds += [$outbound]')
    echo "$outbounds_data" | jq '.' > "$OUTBOUNDS_FILE"

    print_success "Selector 出站添加成功: $tag"
}

# 添加 URLTest 出站
add_urltest_outbound() {
    read -p "请输入 URLTest 标签: " tag

    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 输入出站列表
    read -p "请输入出站标签列表 (用空格分隔): " outbounds_list

    if [[ -z "$outbounds_list" ]]; then
        print_error "出站列表不能为空"
        return 1
    fi

    # 构建出站数组
    local outbounds_array="[]"
    for outbound_tag in $outbounds_list; do
        outbounds_array=$(echo "$outbounds_array" | jq --arg tag "$outbound_tag" '. += [$tag]')
    done

    # 输入测试参数
    read -p "请输入测试 URL [https://www.google.com/generate_204]: " test_url
    test_url=${test_url:-https://www.google.com/generate_204}

    read -p "请输入测试间隔(秒) [300]: " interval
    interval=${interval:-300}

    # 生成出站配置
    local outbound=$(jq -n \
        --arg tag "$tag" \
        --argjson outbounds "$outbounds_array" \
        --arg url "$test_url" \
        --arg interval "${interval}s" \
        '{
            type: "urltest",
            tag: $tag,
            outbounds: $outbounds,
            url: $url,
            interval: $interval
        }')

    # 添加到 outbounds.json
    local outbounds_data=$(cat "$OUTBOUNDS_FILE")
    outbounds_data=$(echo "$outbounds_data" | jq --argjson outbound "$outbound" '.outbounds += [$outbound]')
    echo "$outbounds_data" | jq '.' > "$OUTBOUNDS_FILE"

    print_success "URLTest 出站添加成功: $tag"
}

# 删除出站
delete_outbound() {
    list_outbounds

    read -p "请输入要删除的出站标签: " tag

    if [[ -z "$tag" ]]; then
        print_error "标签不能为空"
        return 1
    fi

    # 禁止删除默认出站
    if [[ "$tag" == "direct" || "$tag" == "block" ]]; then
        print_error "不能删除默认出站: $tag"
        return 1
    fi

    # 确认删除
    read -p "确认删除出站 $tag? [y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return 0
    fi

    # 从 outbounds.json 删除
    local outbounds_data=$(cat "$OUTBOUNDS_FILE")
    outbounds_data=$(echo "$outbounds_data" | jq --arg tag "$tag" '.outbounds = [.outbounds[] | select(.tag != $tag)]')
    echo "$outbounds_data" | jq '.' > "$OUTBOUNDS_FILE"

    print_success "出站已删除: $tag"
}

# 列出所有出站
list_outbounds() {
    print_info "出站列表:"

    local outbounds=$(jq -r '.outbounds[]' "$OUTBOUNDS_FILE" 2>/dev/null)

    if [[ -z "$outbounds" ]]; then
        print_warn "暂无出站配置"
        return 0
    fi

    # 表头
    printf "%-20s %-15s\n" "标签" "类型"
    printf "%-20s %-15s\n" "----" "----"

    # 遍历出站
    local outbound_count=$(jq '.outbounds | length' "$OUTBOUNDS_FILE")

    for ((i=0; i<outbound_count; i++)); do
        local outbound=$(jq -r ".outbounds[$i]" "$OUTBOUNDS_FILE")
        local tag=$(echo "$outbound" | jq -r '.tag')
        local type=$(echo "$outbound" | jq -r '.type')

        printf "%-20s %-15s\n" "$tag" "$type"
    done

    echo ""
}

# =============================================================================
# 路由规则管理
# =============================================================================

# 添加路由规则
add_route_rule() {
    print_info "添加路由规则"

    echo "请选择规则类型:"
    echo "1) 域名规则"
    echo "2) IP 规则"
    echo "3) GeoSite 规则"
    echo "4) GeoIP 规则"
    echo "5) 端口规则"
    echo "6) 协议规则"
    echo "0) 返回"

    read -p "请选择 [1]: " rule_type
    rule_type=${rule_type:-1}

    case "$rule_type" in
        1)
            add_domain_rule
            ;;
        2)
            add_ip_rule
            ;;
        3)
            add_geosite_rule
            ;;
        4)
            add_geoip_rule
            ;;
        5)
            add_port_rule
            ;;
        6)
            add_protocol_rule
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac
}

# 添加域名规则
add_domain_rule() {
    read -p "请输入域名 (支持通配符): " domain

    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 列出出站
    list_outbounds

    read -p "请输入目标出站标签: " outbound

    if [[ -z "$outbound" ]]; then
        print_error "出站标签不能为空"
        return 1
    fi

    # 生成规则
    local rule=$(jq -n \
        --arg domain "$domain" \
        --arg outbound "$outbound" \
        '{
            domain: [$domain],
            outbound: $outbound
        }')

    # 添加到 route_rules.json
    local rules_data=$(cat "$ROUTE_RULES_FILE")
    rules_data=$(echo "$rules_data" | jq --argjson rule "$rule" '.rules += [$rule]')
    echo "$rules_data" | jq '.' > "$ROUTE_RULES_FILE"

    print_success "域名规则添加成功"
}

# 添加 IP 规则
add_ip_rule() {
    read -p "请输入 IP/CIDR: " ip_cidr

    if [[ -z "$ip_cidr" ]]; then
        print_error "IP/CIDR 不能为空"
        return 1
    fi

    # 列出出站
    list_outbounds

    read -p "请输入目标出站标签: " outbound

    if [[ -z "$outbound" ]]; then
        print_error "出站标签不能为空"
        return 1
    fi

    # 生成规则
    local rule=$(jq -n \
        --arg ip "$ip_cidr" \
        --arg outbound "$outbound" \
        '{
            ip_cidr: [$ip],
            outbound: $outbound
        }')

    # 添加到 route_rules.json
    local rules_data=$(cat "$ROUTE_RULES_FILE")
    rules_data=$(echo "$rules_data" | jq --argjson rule "$rule" '.rules += [$rule]')
    echo "$rules_data" | jq '.' > "$ROUTE_RULES_FILE"

    print_success "IP 规则添加成功"
}

# 添加 GeoSite 规则
add_geosite_rule() {
    echo "常用 GeoSite:"
    echo "  - geosite-cn (中国网站)"
    echo "  - geosite-google (Google)"
    echo "  - geosite-facebook (Facebook)"
    echo "  - geosite-category-ads (广告)"

    read -p "请输入 GeoSite 标签: " geosite

    if [[ -z "$geosite" ]]; then
        print_error "GeoSite 标签不能为空"
        return 1
    fi

    # 列出出站
    list_outbounds

    read -p "请输入目标出站标签: " outbound

    if [[ -z "$outbound" ]]; then
        print_error "出站标签不能为空"
        return 1
    fi

    # 生成规则
    local rule=$(jq -n \
        --arg geosite "$geosite" \
        --arg outbound "$outbound" \
        '{
            rule_set: $geosite,
            outbound: $outbound
        }')

    # 添加到 route_rules.json
    local rules_data=$(cat "$ROUTE_RULES_FILE")
    rules_data=$(echo "$rules_data" | jq --argjson rule "$rule" '.rules += [$rule]')
    echo "$rules_data" | jq '.' > "$ROUTE_RULES_FILE"

    print_success "GeoSite 规则添加成功"
}

# 添加 GeoIP 规则
add_geoip_rule() {
    echo "常用 GeoIP:"
    echo "  - geoip-cn (中国 IP)"
    echo "  - geoip-private (私有 IP)"

    read -p "请输入 GeoIP 标签: " geoip

    if [[ -z "$geoip" ]]; then
        print_error "GeoIP 标签不能为空"
        return 1
    fi

    # 列出出站
    list_outbounds

    read -p "请输入目标出站标签: " outbound

    if [[ -z "$outbound" ]]; then
        print_error "出站标签不能为空"
        return 1
    fi

    # 生成规则
    local rule=$(jq -n \
        --arg geoip "$geoip" \
        --arg outbound "$outbound" \
        '{
            rule_set: $geoip,
            outbound: $outbound
        }')

    # 添加到 route_rules.json
    local rules_data=$(cat "$ROUTE_RULES_FILE")
    rules_data=$(echo "$rules_data" | jq --argjson rule "$rule" '.rules += [$rule]')
    echo "$rules_data" | jq '.' > "$ROUTE_RULES_FILE"

    print_success "GeoIP 规则添加成功"
}

# 添加端口规则
add_port_rule() {
    read -p "请输入端口或端口范围 (例如: 80 或 8000-9000): " port

    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 列出出站
    list_outbounds

    read -p "请输入目标出站标签: " outbound

    if [[ -z "$outbound" ]]; then
        print_error "出站标签不能为空"
        return 1
    fi

    # 生成规则
    local rule=$(jq -n \
        --arg port "$port" \
        --arg outbound "$outbound" \
        '{
            port: [$port],
            outbound: $outbound
        }')

    # 添加到 route_rules.json
    local rules_data=$(cat "$ROUTE_RULES_FILE")
    rules_data=$(echo "$rules_data" | jq --argjson rule "$rule" '.rules += [$rule]')
    echo "$rules_data" | jq '.' > "$ROUTE_RULES_FILE"

    print_success "端口规则添加成功"
}

# 添加协议规则
add_protocol_rule() {
    echo "支持的协议:"
    echo "  - dns"
    echo "  - http"
    echo "  - tls"
    echo "  - quic"

    read -p "请输入协议: " protocol

    if [[ -z "$protocol" ]]; then
        print_error "协议不能为空"
        return 1
    fi

    # 列出出站
    list_outbounds

    read -p "请输入目标出站标签: " outbound

    if [[ -z "$outbound" ]]; then
        print_error "出站标签不能为空"
        return 1
    fi

    # 生成规则
    local rule=$(jq -n \
        --arg protocol "$protocol" \
        --arg outbound "$outbound" \
        '{
            protocol: $protocol,
            outbound: $outbound
        }')

    # 添加到 route_rules.json
    local rules_data=$(cat "$ROUTE_RULES_FILE")
    rules_data=$(echo "$rules_data" | jq --argjson rule "$rule" '.rules += [$rule]')
    echo "$rules_data" | jq '.' > "$ROUTE_RULES_FILE"

    print_success "协议规则添加成功"
}

# 列出路由规则
list_route_rules() {
    print_info "路由规则列表:"

    local rules_data=$(cat "$ROUTE_RULES_FILE")

    echo "$rules_data" | jq '.'
}

# 设置默认出站
set_default_outbound() {
    list_outbounds

    read -p "请输入默认出站标签: " outbound

    if [[ -z "$outbound" ]]; then
        print_error "出站标签不能为空"
        return 1
    fi

    # 更新 final 字段
    local rules_data=$(cat "$ROUTE_RULES_FILE")
    rules_data=$(echo "$rules_data" | jq --arg outbound "$outbound" '.final = $outbound')
    echo "$rules_data" | jq '.' > "$ROUTE_RULES_FILE"

    print_success "默认出站已设置: $outbound"
}

# =============================================================================
# 出站管理菜单
# =============================================================================

outbound_menu() {
    while true; do
        clear
        print_header "出站规则管理"

        echo "== 出站管理 =="
        echo "1)  添加出站"
        echo "2)  删除出站"
        echo "3)  列出出站"
        echo ""
        echo "== 路由规则 =="
        echo "4)  添加路由规则"
        echo "5)  列出路由规则"
        echo "6)  设置默认出站"
        echo ""
        echo "0)  返回主菜单"
        echo ""

        read -p "请选择: " choice

        case "$choice" in
            1)
                add_outbound
                read -p "按回车键继续..."
                ;;
            2)
                delete_outbound
                read -p "按回车键继续..."
                ;;
            3)
                list_outbounds
                read -p "按回车键继续..."
                ;;
            4)
                add_route_rule
                read -p "按回车键继续..."
                ;;
            5)
                list_route_rules
                read -p "按回车键继续..."
                ;;
            6)
                set_default_outbound
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# 通用打印函数
# =============================================================================

print_header() {
    echo ""
    echo -e "\033[32m======================================\033[0m"
    echo -e "\033[32m  $1\033[0m"
    echo -e "\033[32m======================================\033[0m"
    echo ""
}

print_info() {
    echo -e "\033[34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[32m[SUCCESS]\033[0m $1"
}

print_error() {
    echo -e "\033[31m[ERROR]\033[0m $1"
}

print_warn() {
    echo -e "\033[33m[WARN]\033[0m $1"
}

# 初始化
init_outbounds_file
init_route_rules_file
