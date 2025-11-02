#!/bin/bash

#================================================================
# 域名和证书管理模块
# 功能：域名管理、证书管理、伪装域名优选
#================================================================

# 全局变量
DOMAIN_FILE="${DATA_DIR}/domains.json"
CERT_DIR="${XRAY_DIR}/certs"
DEFAULT_DOMAIN_FILE="${DATA_DIR}/default_domain.txt"

# 初始化域名数据文件
init_domain_file() {
    if [[ ! -f "$DOMAIN_FILE" ]]; then
        echo '{"domains":[],"certificates":[]}' > "$DOMAIN_FILE"
    fi
}

# 获取默认伪装域名
get_default_domain() {
    if [[ -f "$DEFAULT_DOMAIN_FILE" ]]; then
        cat "$DEFAULT_DOMAIN_FILE"
    else
        echo "www.microsoft.com"
    fi
}

# 设置默认伪装域名
set_default_domain() {
    local domain=$1
    echo "$domain" > "$DEFAULT_DOMAIN_FILE"
    print_success "默认伪装域名已设置为: $domain"
}

# 伪装域名优选（延迟测试 + DNS 解析验证）
test_best_reality_domains() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    Reality 伪装域名智能优选测试     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}测试说明：${NC}"
    echo -e "  ✓ 测试多个知名网站的连接延迟"
    echo -e "  ✓ 验证 DNS 解析和 TLS 握手"
    echo -e "  ✓ 智能推荐延迟最低的域名"
    echo ""

    print_info "开始智能优选伪装域名..."
    echo ""

    # 创建临时文件存储结果
    local temp_file=$(mktemp)

    # 测试域名列表（扩展版，包含更多常用域名）
    local domains=(
        www.cloudflare.com
        www.apple.com
        www.microsoft.com
        www.bing.com
        developer.apple.com
        www.gstatic.com
        fonts.gstatic.com
        fonts.googleapis.com
        res-1.cdn.office.net
        aws.amazon.com
        www.aws.com
        d1.awsstatic.com
        cdn.jsdelivr.net
        www.sony.com
        www.w3.org
        www.wikipedia.org
        ajax.cloudflare.com
        www.mozilla.org
        www.intel.com
        images.unsplash.com
    )

    local total=${#domains[@]}
    local count=0
    local success_count=0
    local best_latency=9999
    local best_domain=""

    echo -e "${BLUE}正在测试域名延迟...${NC}"
    echo ""

    for domain in "${domains[@]}"; do
        ((count++))

        # 记录开始时间（毫秒）
        local t1=$(date +%s%3N)

        # 测试连接（超时2秒）
        if timeout 2 openssl s_client -connect "$domain:443" -servername "$domain" </dev/null >/dev/null 2>&1; then
            local t2=$(date +%s%3N)
            local latency=$((t2 - t1))

            # 验证 DNS 解析（静默模式）
            if host "$domain" >/dev/null 2>&1; then
                echo "$latency $domain" >> "$temp_file"
                ((success_count++))

                # 更新最佳域名
                if [[ $latency -lt $best_latency ]]; then
                    best_latency=$latency
                    best_domain=$domain
                fi

                # 实时显示成功结果
                printf "  ${GREEN}✔${NC} [%2d/%2d] %-35s ${CYAN}%4d ms${NC}\n" "$count" "$total" "$domain" "$latency"
            fi
        else
            printf "  ${RED}✘${NC} [%2d/%2d] %-35s ${YELLOW}超时${NC}\n" "$count" "$total" "$domain"
        fi
    done

    echo ""

    # 检查是否有成功的结果
    if [[ ! -s "$temp_file" || $success_count -eq 0 ]]; then
        print_error "所有域名测试均失败，请检查网络连接"
        rm -f "$temp_file"
        return 1
    fi

    # 显示优选结果
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        优选结果 - 推荐域名          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}最佳域名:${NC} ${YELLOW}$best_domain${NC}"
    echo -e "${CYAN}延迟:${NC} ${YELLOW}${best_latency}ms${NC}"
    echo -e "${CYAN}成功测试:${NC} ${YELLOW}${success_count}/${total}${NC} 个域名"
    echo ""

    # 显示延迟最低的前10个域名
    echo -e "${BLUE}延迟最低的前 10 个域名：${NC}"
    echo ""
    printf "${CYAN}%-5s %-40s %10s${NC}\n" "序号" "域名" "延迟"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    sort -n "$temp_file" | head -n 10 | while read -r latency domain; do
        if [[ $latency -lt 200 ]]; then
            printf "${GREEN}%-5s %-40s %7s ms${NC}\n" "$index" "$domain" "$latency"
        elif [[ $latency -lt 500 ]]; then
            printf "${YELLOW}%-5s %-40s %7s ms${NC}\n" "$index" "$domain" "$latency"
        else
            printf "${RED}%-5s %-40s %7s ms${NC}\n" "$index" "$domain" "$latency"
        fi
        ((index++))
    done

    echo ""
    echo -e "${YELLOW}提示：${NC}"
    echo -e "  ${GREEN}●${NC} 绿色 (<200ms): 优秀，强烈推荐"
    echo -e "  ${YELLOW}●${NC} 黄色 (200-500ms): 良好，可以使用"
    echo -e "  ${RED}●${NC} 红色 (>500ms): 较慢，不推荐"
    echo ""

    # 保存推荐域名到文件
    local recommended_file="${DATA_DIR}/recommended_domains.txt"
    sort -n "$temp_file" | head -n 10 | awk '{print $2}' > "$recommended_file"
    print_success "推荐域名已保存到: $recommended_file"

    # 询问是否设置为默认伪装域名
    echo ""
    read -p "是否将延迟最低的域名 ($best_domain) 设置为默认伪装域名? [Y/n]: " set_default
    if [[ "$set_default" != "n" && "$set_default" != "N" ]]; then
        set_default_domain "$best_domain"
    else
        # 询问是否选择其他域名
        read -p "是否选择其他域名作为默认? [y/N]: " choose_other
        if [[ "$choose_other" == "y" || "$choose_other" == "Y" ]]; then
            read -p "请输入域名序号 (1-10): " domain_index
            if [[ "$domain_index" =~ ^[1-9]$|^10$ ]]; then
                local selected_domain=$(sort -n "$temp_file" | head -n 10 | sed -n "${domain_index}p" | awk '{print $2}')
                if [[ -n "$selected_domain" ]]; then
                    set_default_domain "$selected_domain"
                fi
            fi
        fi
    fi

    # 清理临时文件
    rm -f "$temp_file"
}

# 测试自定义域名
test_custom_domain() {
    clear
    echo -e "${CYAN}====== 测试自定义域名 ======${NC}"
    echo ""

    read -p "请输入要测试的域名: " domain
    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 验证域名格式
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        print_error "域名格式不正确"
        return 1
    fi

    echo ""
    print_info "开始测试域名: $domain"
    echo ""

    # DNS 解析测试
    print_info "1. DNS 解析测试..."
    if host "$domain" &>/dev/null; then
        local ip=$(host "$domain" | grep "has address" | awk '{print $4}' | head -1)
        print_success "DNS 解析成功: $ip"
    else
        print_error "DNS 解析失败"
        return 1
    fi

    # TLS 握手测试
    print_info "2. TLS 握手测试..."
    local t1=$(date +%s%3N)

    if timeout 3 openssl s_client -connect "$domain:443" -servername "$domain" </dev/null &>/dev/null; then
        local t2=$(date +%s%3N)
        local latency=$((t2 - t1))
        print_success "TLS 握手成功，延迟: ${latency}ms"

        # 询问是否设置为默认伪装域名
        echo ""
        read -p "是否将此域名设置为默认伪装域名? [y/N]: " set_default
        if [[ "$set_default" == "y" || "$set_default" == "Y" ]]; then
            set_default_domain "$domain"
        fi
    else
        print_error "TLS 握手失败"
        return 1
    fi
}

# DNS 解析测试
test_dns_resolution() {
    clear
    echo -e "${CYAN}====== DNS 解析测试 ======${NC}"
    echo ""

    read -p "请输入要测试的域名: " domain
    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    echo ""
    print_info "测试域名: $domain"
    echo ""

    # 使用 host 命令测试
    print_info "使用 host 命令测试..."
    if host "$domain"; then
        print_success "DNS 解析成功"
    else
        print_error "DNS 解析失败"
    fi

    echo ""

    # 使用 dig 命令测试（如果可用）
    if command -v dig &>/dev/null; then
        print_info "使用 dig 命令测试..."
        dig "$domain" +short
    fi

    echo ""

    # 使用 nslookup 命令测试（如果可用）
    if command -v nslookup &>/dev/null; then
        print_info "使用 nslookup 命令测试..."
        nslookup "$domain"
    fi
}

# 添加自定义域名
add_custom_domain() {
    clear
    echo -e "${CYAN}====== 添加自定义域名 ======${NC}"
    echo ""

    read -p "请输入域名: " domain
    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 验证域名格式
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        print_error "域名格式不正确"
        return 1
    fi

    # 测试 DNS 解析
    print_info "测试 DNS 解析..."
    if host "$domain" &>/dev/null; then
        local ip=$(host "$domain" | grep "has address" | awk '{print $4}' | head -1)
        print_success "DNS 解析成功: $ip"
    else
        print_warning "DNS 解析失败，但仍可添加"
    fi

    read -p "请输入备注 [可选]: " note

    # 保存域名
    init_domain_file
    local domain_data=$(jq -n \
        --arg domain "$domain" \
        --arg note "$note" \
        '{domain: $domain, note: $note, type: "custom", created: now|todate}')

    local current_data=$(cat "$DOMAIN_FILE")
    echo "$current_data" | jq ".domains += [$domain_data]" > "$DOMAIN_FILE"

    print_success "域名添加成功！"
}

# 查看域名列表
list_domains() {
    clear
    echo -e "${CYAN}====== 域名列表 ======${NC}\n"

    init_domain_file

    local domains=$(jq -r '.domains[] | "\(.domain)|\(.note)|\(.type)"' "$DOMAIN_FILE" 2>/dev/null)

    if [[ -z "$domains" ]]; then
        print_warning "暂无域名"
        return 0
    fi

    printf "%-5s %-40s %-20s %-15s\n" "序号" "域名" "备注" "类型"
    echo "--------------------------------------------------------------------------------------------"

    local index=1
    while IFS='|' read -r domain note type; do
        printf "%-5s %-40s %-20s %-15s\n" "$index" "$domain" "$note" "$type"
        ((index++))
    done <<< "$domains"
}

# 删除域名
delete_domain() {
    list_domains

    echo ""
    read -p "请输入要删除的域名序号: " index
    if [[ -z "$index" ]]; then
        print_error "序号不能为空"
        return 1
    fi

    # 获取域名
    local domain=$(jq -r ".domains[$((index-1))].domain" "$DOMAIN_FILE" 2>/dev/null)
    if [[ -z "$domain" || "$domain" == "null" ]]; then
        print_error "无效的序号"
        return 1
    fi

    print_info "将删除域名: $domain"
    read -p "确认删除? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消删除"
        return 0
    fi

    # 删除域名
    jq ".domains = [.domains[] | select(.domain != \"$domain\")]" "$DOMAIN_FILE" > "${DOMAIN_FILE}.tmp"
    mv "${DOMAIN_FILE}.tmp" "$DOMAIN_FILE"

    print_success "域名删除成功！"
}

# 添加证书
add_certificate() {
    clear
    echo -e "${CYAN}====== 添加证书 ======${NC}"
    echo ""

    read -p "请输入域名: " domain
    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    echo ""
    echo -e "${CYAN}证书类型：${NC}"
    echo "1. 自签名证书（自动生成）"
    echo "2. 手动导入证书"
    read -p "请选择 [1-2]: " cert_type

    local cert_file=""
    local key_file=""

    if [[ "$cert_type" == "1" ]]; then
        # 生成自签名证书
        print_info "生成自签名证书..."
        mkdir -p "$CERT_DIR"

        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "${CERT_DIR}/${domain}.key" \
            -out "${CERT_DIR}/${domain}.crt" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=${domain}" \
            2>/dev/null

        cert_file="${CERT_DIR}/${domain}.crt"
        key_file="${CERT_DIR}/${domain}.key"

        print_success "证书生成成功"
    else
        # 手动导入
        read -p "请输入证书文件路径: " cert_file
        read -p "请输入密钥文件路径: " key_file

        if [[ ! -f "$cert_file" ]]; then
            print_error "证书文件不存在: $cert_file"
            return 1
        fi

        if [[ ! -f "$key_file" ]]; then
            print_error "密钥文件不存在: $key_file"
            return 1
        fi

        # 复制到证书目录
        mkdir -p "$CERT_DIR"
        cp "$cert_file" "${CERT_DIR}/${domain}.crt"
        cp "$key_file" "${CERT_DIR}/${domain}.key"

        cert_file="${CERT_DIR}/${domain}.crt"
        key_file="${CERT_DIR}/${domain}.key"

        print_success "证书导入成功"
    fi

    # 保存证书信息
    init_domain_file
    local cert_data=$(jq -n \
        --arg domain "$domain" \
        --arg cert_file "$cert_file" \
        --arg key_file "$key_file" \
        --arg type "$([ "$cert_type" == "1" ] && echo "self-signed" || echo "imported")" \
        '{domain: $domain, cert_file: $cert_file, key_file: $key_file, type: $type, created: now|todate}')

    local current_data=$(cat "$DOMAIN_FILE")
    echo "$current_data" | jq ".certificates += [$cert_data]" > "$DOMAIN_FILE"

    echo ""
    echo -e "${CYAN}证书信息：${NC}"
    echo -e "  域名: $domain"
    echo -e "  证书: $cert_file"
    echo -e "  密钥: $key_file"
}

# 查看证书列表
list_certificates() {
    clear
    echo -e "${CYAN}====== 证书列表 ======${NC}\n"

    init_domain_file

    local certs=$(jq -r '.certificates[] | "\(.domain)|\(.type)|\(.cert_file)"' "$DOMAIN_FILE" 2>/dev/null)

    if [[ -z "$certs" ]]; then
        print_warning "暂无证书"
        return 0
    fi

    printf "%-5s %-40s %-20s %-50s\n" "序号" "域名" "类型" "证书路径"
    echo "---------------------------------------------------------------------------------------------------------------------"

    local index=1
    while IFS='|' read -r domain type cert_file; do
        local type_display="未知"
        [[ "$type" == "self-signed" ]] && type_display="自签名"
        [[ "$type" == "imported" ]] && type_display="导入"

        printf "%-5s %-40s %-20s %-50s\n" "$index" "$domain" "$type_display" "$cert_file"
        ((index++))
    done <<< "$certs"
}

# 删除证书
delete_certificate() {
    list_certificates

    echo ""
    read -p "请输入要删除的证书序号: " index
    if [[ -z "$index" ]]; then
        print_error "序号不能为空"
        return 1
    fi

    # 获取证书信息
    local domain=$(jq -r ".certificates[$((index-1))].domain" "$DOMAIN_FILE" 2>/dev/null)
    local cert_file=$(jq -r ".certificates[$((index-1))].cert_file" "$DOMAIN_FILE" 2>/dev/null)
    local key_file=$(jq -r ".certificates[$((index-1))].key_file" "$DOMAIN_FILE" 2>/dev/null)

    if [[ -z "$domain" || "$domain" == "null" ]]; then
        print_error "无效的序号"
        return 1
    fi

    print_info "将删除域名 $domain 的证书"
    read -p "是否同时删除证书文件? [y/N]: " delete_files

    # 删除证书记录
    jq ".certificates = [.certificates[] | select(.domain != \"$domain\")]" "$DOMAIN_FILE" > "${DOMAIN_FILE}.tmp"
    mv "${DOMAIN_FILE}.tmp" "$DOMAIN_FILE"

    # 删除文件
    if [[ "$delete_files" == "y" || "$delete_files" == "Y" ]]; then
        rm -f "$cert_file" "$key_file"
        print_success "证书记录和文件已删除"
    else
        print_success "证书记录已删除（文件保留）"
    fi
}

# 查看默认伪装域名
show_default_domain() {
    clear
    echo -e "${CYAN}====== 默认伪装域名 ======${NC}"
    echo ""
    local default_domain=$(get_default_domain)
    echo -e "${GREEN}当前默认伪装域名:${NC} $default_domain"
    echo ""
}

# 手动设置默认伪装域名
manual_set_default_domain() {
    clear
    echo -e "${CYAN}====== 设置默认伪装域名 ======${NC}"
    echo ""

    # 显示当前默认域名
    local current_default=$(get_default_domain)
    echo -e "${BLUE}当前默认域名:${NC} $current_default"
    echo ""

    read -p "请输入新的默认伪装域名: " domain
    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 验证域名格式
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        print_error "域名格式不正确"
        return 1
    fi

    set_default_domain "$domain"
}

# 服务器域名管理
manage_server_domain() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      服务器域名管理                  ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${YELLOW}服务器域名用途：${NC}"
    echo -e "  • TLS/HTTPS 证书绑定"
    echo -e "  • 节点订阅地址"
    echo -e "  • 客户端连接地址"
    echo ""

    echo -e "${GREEN}1.${NC} 查看当前域名"
    echo -e "${GREEN}2.${NC} 设置服务器域名"
    echo -e "${GREEN}3.${NC} 测试域名解析"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-3]: " choice

    case $choice in
        1)
            local server_domain=$(cat "${DATA_DIR}/server_domain.txt" 2>/dev/null || echo "未设置")
            echo ""
            echo -e "${CYAN}当前服务器域名:${NC} ${YELLOW}$server_domain${NC}"
            ;;
        2)
            echo ""
            read -p "请输入服务器域名: " domain
            if [[ -n "$domain" ]]; then
                echo "$domain" > "${DATA_DIR}/server_domain.txt"
                print_success "服务器域名已设置为: $domain"
            fi
            ;;
        3)
            echo ""
            read -p "请输入要测试的域名: " domain
            if [[ -n "$domain" ]]; then
                echo ""
                print_info "测试域名解析: $domain"
                if host "$domain" >/dev/null 2>&1; then
                    local ip=$(host "$domain" | grep "has address" | awk '{print $4}' | head -1)
                    print_success "解析成功: $domain -> $ip"
                else
                    print_error "解析失败: $domain"
                fi
            fi
            ;;
    esac
}

# 自动优选并设置SNI域名
auto_select_sni_domain() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    自动优选 SNI 伪装域名             ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 高质量域名列表（CDN节点多、稳定性高）
    local premium_domains=(
        www.microsoft.com
        www.apple.com
        www.cloudflare.com
        www.bing.com
        developer.apple.com
        www.cisco.com
        www.intel.com
        www.amd.com
        www.nvidia.com
        login.microsoftonline.com
    )

    echo -e "${YELLOW}正在测试高质量域名...${NC}"
    echo ""

    # 创建临时结果文件
    local temp_file=$(mktemp)
    local count=0
    local total=${#premium_domains[@]}

    for domain in "${premium_domains[@]}"; do
        ((count++))

        # 测试延迟
        local t1=$(date +%s%3N)
        if timeout 2 openssl s_client -connect "$domain:443" -servername "$domain" </dev/null >/dev/null 2>&1; then
            local t2=$(date +%s%3N)
            local latency=$((t2 - t1))

            # 验证DNS解析
            if host "$domain" >/dev/null 2>&1; then
                echo "$latency $domain" >> "$temp_file"
                printf "  ${GREEN}✔${NC} [%2d/%2d] %-35s ${CYAN}%4d ms${NC}\n" "$count" "$total" "$domain" "$latency"
            fi
        else
            printf "  ${RED}✘${NC} [%2d/%2d] %-35s ${YELLOW}超时${NC}\n" "$count" "$total" "$domain"
        fi
    done

    echo ""

    # 检查是否有成功结果
    if [[ ! -s "$temp_file" ]]; then
        print_error "所有域名测试失败，使用默认域名"
        rm -f "$temp_file"
        set_default_domain "www.microsoft.com"
        return 1
    fi

    # 获取最佳域名（延迟最低）
    local best_result=$(sort -n "$temp_file" | head -n 1)
    local best_latency=$(echo "$best_result" | awk '{print $1}')
    local best_domain=$(echo "$best_result" | awk '{print $2}')

    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        自动优选结果                  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}推荐域名:${NC} ${YELLOW}$best_domain${NC}"
    echo -e "${CYAN}延迟:${NC} ${YELLOW}${best_latency}ms${NC}"
    echo ""

    # 显示前5名
    echo -e "${BLUE}延迟最低的前 5 个域名：${NC}"
    echo ""
    printf "${CYAN}%-5s %-40s %10s${NC}\n" "序号" "域名" "延迟"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    sort -n "$temp_file" | head -n 5 | while read -r latency domain; do
        if [[ $latency -lt 200 ]]; then
            printf "${GREEN}%-5s %-40s %7s ms${NC}\n" "$index" "$domain" "$latency"
        elif [[ $latency -lt 500 ]]; then
            printf "${YELLOW}%-5s %-40s %7s ms${NC}\n" "$index" "$domain" "$latency"
        else
            printf "${RED}%-5s %-40s %7s ms${NC}\n" "$index" "$domain" "$latency"
        fi
        ((index++))
    done

    echo ""

    # 自动设置或让用户选择
    echo -e "${YELLOW}选择方式：${NC}"
    echo -e "${GREEN}1.${NC} 自动使用推荐域名 (${best_domain})"
    echo -e "${GREEN}2.${NC} 从上述列表中选择"
    echo -e "${GREEN}3.${NC} 手动输入其他域名"
    echo -e "${GREEN}0.${NC} 取消设置"
    echo ""
    read -p "请选择 [0-3, 默认: 1]: " choice
    choice=${choice:-1}

    case $choice in
        1)
            set_default_domain "$best_domain"
            ;;
        2)
            echo ""
            read -p "请输入域名序号 (1-5): " domain_index
            if [[ "$domain_index" =~ ^[1-5]$ ]]; then
                local selected_domain=$(sort -n "$temp_file" | head -n 5 | sed -n "${domain_index}p" | awk '{print $2}')
                if [[ -n "$selected_domain" ]]; then
                    set_default_domain "$selected_domain"
                else
                    print_error "无效的序号"
                fi
            else
                print_error "无效的序号"
            fi
            ;;
        3)
            echo ""
            read -p "请输入域名: " custom_domain
            if [[ -n "$custom_domain" ]]; then
                # 验证域名格式
                if [[ "$custom_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
                    set_default_domain "$custom_domain"
                else
                    print_error "域名格式不正确"
                fi
            fi
            ;;
        0)
            print_info "已取消设置"
            ;;
        *)
            print_error "无效选择"
            ;;
    esac

    # 清理临时文件
    rm -f "$temp_file"
}

# SNI 伪装域名管理
manage_sni_domain() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      SNI 伪装域名管理                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${YELLOW}SNI (Server Name Indication) 说明：${NC}"
    echo -e "  • Reality/TLS 协议的伪装域名"
    echo -e "  • 客户端 TLS 握手时发送的域名"
    echo -e "  • 建议使用大型网站域名"
    echo ""

    local default_domain=$(get_default_domain)
    echo -e "${BLUE}当前默认 SNI 域名:${NC} ${YELLOW}$default_domain${NC}"
    echo ""

    echo -e "${GREEN}1.${NC} 自动优选并设置 (推荐)"
    echo -e "${GREEN}2.${NC} 手动设置 SNI 域名"
    echo -e "${GREEN}3.${NC} 查看推荐域名列表"
    echo -e "${GREEN}4.${NC} 测试域名可用性"
    echo -e "${GREEN}5.${NC} 完整域名测试 (20+域名)"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-5]: " choice

    case $choice in
        1)
            auto_select_sni_domain
            ;;
        2)
            echo ""
            read -p "请输入 SNI 域名: " domain
            if [[ -n "$domain" ]]; then
                set_default_domain "$domain"
            fi
            ;;
        3)
            echo ""
            if [[ -f "${DATA_DIR}/recommended_domains.txt" ]]; then
                echo -e "${CYAN}推荐的 SNI 域名：${NC}"
                cat "${DATA_DIR}/recommended_domains.txt"
            else
                echo -e "${YELLOW}常用 SNI 域名推荐：${NC}"
                echo -e "  • www.microsoft.com"
                echo -e "  • www.apple.com"
                echo -e "  • www.cloudflare.com"
                echo -e "  • www.bing.com"
                echo -e "  • aws.amazon.com"
            fi
            ;;
        4)
            echo ""
            read -p "请输入要测试的域名: " domain
            if [[ -n "$domain" ]]; then
                echo ""
                print_info "测试 TLS 握手: $domain"
                if timeout 3 openssl s_client -connect "$domain:443" -servername "$domain" </dev/null >/dev/null 2>&1; then
                    print_success "TLS 握手成功: $domain"
                else
                    print_error "TLS 握手失败: $domain"
                fi
            fi
            ;;
        5)
            test_best_reality_domains
            ;;
    esac
}

# Host 伪装域名管理
manage_host_domain() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      Host 伪装域名管理               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${YELLOW}Host 伪装域名说明：${NC}"
    echo -e "  • WebSocket/HTTP 传输的 Host 头"
    echo -e "  • CDN 回源时使用的域名"
    echo -e "  • 与 SNI 可以不同"
    echo ""

    echo -e "${GREEN}1.${NC} 查看当前 Host 域名"
    echo -e "${GREEN}2.${NC} 设置 Host 域名"
    echo -e "${GREEN}3.${NC} 测试 Host 可用性"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-3]: " choice

    case $choice in
        1)
            local host_domain=$(cat "${DATA_DIR}/host_domain.txt" 2>/dev/null || echo "未设置")
            echo ""
            echo -e "${CYAN}当前 Host 域名:${NC} ${YELLOW}$host_domain${NC}"
            ;;
        2)
            echo ""
            read -p "请输入 Host 域名: " domain
            if [[ -n "$domain" ]]; then
                echo "$domain" > "${DATA_DIR}/host_domain.txt"
                print_success "Host 域名已设置为: $domain"
            fi
            ;;
        3)
            echo ""
            read -p "请输入要测试的域名: " domain
            if [[ -n "$domain" ]]; then
                echo ""
                print_info "测试 HTTP 连接: $domain"
                if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "https://$domain" | grep -q "200\|301\|302"; then
                    print_success "HTTP 连接成功: $domain"
                else
                    print_warning "HTTP 连接异常: $domain（可能仍可用作 Host）"
                fi
            fi
            ;;
    esac
}

# 域名管理菜单
domain_management_menu() {
    while true; do
        clear

        # 显示当前默认域名
        local default_domain=$(get_default_domain)

        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║          域名管理                    ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${BLUE}当前默认伪装域名:${NC} ${YELLOW}$default_domain${NC}"
        echo ""
        echo -e "${GREEN}1.${NC} 服务器域名"
        echo -e "${GREEN}2.${NC} SNI 伪装域名"
        echo -e "${GREEN}3.${NC} Host 伪装域名"
        echo -e "${GREEN}4.${NC} 优选域名测试"
        echo -e "${GREEN}5.${NC} 校验 DNS"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作 [0-5]: " choice

        case $choice in
            1) manage_server_domain ;;
            2) manage_sni_domain ;;
            3) manage_host_domain ;;
            4) test_best_reality_domains ;;
            5) test_dns_resolution ;;
            0) break ;;
            *) print_error "无效选择" ;;
        esac

        read -p "按 Enter 键继续..."
    done
}

# 修改证书
modify_certificate() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          修改证书                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 显示证书列表
    init_domain_file
    local certs=$(jq -r '.certificates[]' "$DOMAIN_FILE" 2>/dev/null)

    if [[ -z "$certs" ]]; then
        print_warning "暂无证书"
        return
    fi

    echo -e "${YELLOW}现有证书：${NC}"
    local index=1
    while read -r cert; do
        if [[ -n "$cert" ]]; then
            local domain=$(echo "$cert" | jq -r '.domain')
            echo -e "${GREEN}[$index]${NC} $domain"
            ((index++))
        fi
    done < <(jq -c '.certificates[]' "$DOMAIN_FILE" 2>/dev/null)

    echo ""
    read -p "请选择要修改的证书序号: " cert_index

    if [[ ! "$cert_index" =~ ^[0-9]+$ ]]; then
        print_error "无效的序号"
        return
    fi

    local cert=$(jq -c ".certificates[$((cert_index-1))]" "$DOMAIN_FILE" 2>/dev/null)
    if [[ -z "$cert" || "$cert" == "null" ]]; then
        print_error "证书不存在"
        return
    fi

    local domain=$(echo "$cert" | jq -r '.domain')
    echo ""
    echo -e "${CYAN}修改证书:${NC} $domain"
    echo ""
    echo -e "${GREEN}1.${NC} 更新证书文件路径"
    echo -e "${GREEN}2.${NC} 更新密钥文件路径"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-2]: " choice

    case $choice in
        1)
            echo ""
            read -p "请输入新的证书文件路径: " cert_path
            if [[ -n "$cert_path" ]]; then
                if [[ ! -f "$cert_path" ]]; then
                    print_warning "证书文件不存在: $cert_path"
                    read -p "是否仍要保存? [y/N]: " confirm
                    [[ "$confirm" != "y" ]] && return
                fi

                jq ".certificates[$((cert_index-1))].cert = \"$cert_path\"" "$DOMAIN_FILE" > "${DOMAIN_FILE}.tmp"
                mv "${DOMAIN_FILE}.tmp" "$DOMAIN_FILE"
                print_success "证书路径已更新"
            fi
            ;;
        2)
            echo ""
            read -p "请输入新的密钥文件路径: " key_path
            if [[ -n "$key_path" ]]; then
                if [[ ! -f "$key_path" ]]; then
                    print_warning "密钥文件不存在: $key_path"
                    read -p "是否仍要保存? [y/N]: " confirm
                    [[ "$confirm" != "y" ]] && return
                fi

                jq ".certificates[$((cert_index-1))].key = \"$key_path\"" "$DOMAIN_FILE" > "${DOMAIN_FILE}.tmp"
                mv "${DOMAIN_FILE}.tmp" "$DOMAIN_FILE"
                print_success "密钥路径已更新"
            fi
            ;;
    esac
}

# 自动申请证书
auto_apply_certificate() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      自动申请证书 (acme.sh)         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${YELLOW}支持的证书申请方式：${NC}"
    echo -e "  • Let's Encrypt (免费)"
    echo -e "  • ZeroSSL (免费)"
    echo -e "  • Buypass (免费)"
    echo ""

    # 检查 acme.sh 是否安装
    if ! command -v acme.sh &>/dev/null && [[ ! -f ~/.acme.sh/acme.sh ]]; then
        print_warning "acme.sh 未安装"
        echo ""
        read -p "是否现在安装 acme.sh? [y/N]: " install_acme
        if [[ "$install_acme" == "y" ]]; then
            echo ""
            print_info "正在安装 acme.sh..."
            curl https://get.acme.sh | sh -s email=my@example.com || {
                print_error "acme.sh 安装失败"
                return 1
            }
            source ~/.bashrc
            print_success "acme.sh 安装完成"
        else
            return
        fi
    fi

    echo ""
    read -p "请输入域名: " domain
    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return
    fi

    echo ""
    echo -e "${YELLOW}验证方式：${NC}"
    echo -e "${GREEN}1.${NC} HTTP 验证（需要80端口）"
    echo -e "${GREEN}2.${NC} DNS 验证（需要配置DNS API）"
    echo -e "${GREEN}3.${NC} 独立模式（需要80端口临时使用）"
    echo ""
    read -p "请选择验证方式 [1-3, 默认: 3]: " verify_method
    verify_method=${verify_method:-3}

    local acme_cmd=""
    case $verify_method in
        1)
            read -p "请输入网站根目录路径: " webroot
            if [[ -z "$webroot" ]]; then
                print_error "网站根目录不能为空"
                return
            fi
            acme_cmd="~/.acme.sh/acme.sh --issue -d $domain -w $webroot"
            ;;
        2)
            echo ""
            echo -e "${YELLOW}支持的 DNS 提供商：${NC}"
            echo -e "  • Cloudflare (cf)"
            echo -e "  • Aliyun (ali)"
            echo -e "  • DNSPod (dp)"
            echo ""
            read -p "请输入 DNS 提供商简称: " dns_provider
            read -p "请输入 API Key/Token: " api_key

            export CF_Token="$api_key"  # 示例，实际需根据提供商设置
            acme_cmd="~/.acme.sh/acme.sh --issue --dns dns_$dns_provider -d $domain"
            ;;
        3)
            acme_cmd="~/.acme.sh/acme.sh --issue -d $domain --standalone"
            ;;
        *)
            print_error "无效的验证方式"
            return
            ;;
    esac

    echo ""
    print_info "正在申请证书..."
    echo ""

    if eval "$acme_cmd"; then
        print_success "证书申请成功"

        # 安装证书到指定目录
        mkdir -p "$CERT_DIR/$domain"
        ~/.acme.sh/acme.sh --install-cert -d "$domain" \
            --key-file "$CERT_DIR/$domain/key.pem" \
            --fullchain-file "$CERT_DIR/$domain/cert.pem"

        # 添加到证书列表
        init_domain_file
        local cert_data=$(jq -n \
            --arg domain "$domain" \
            --arg cert "$CERT_DIR/$domain/cert.pem" \
            --arg key "$CERT_DIR/$domain/key.pem" \
            '{domain: $domain, cert: $cert, key: $key, auto: true, created: now|todate}')

        jq ".certificates += [$cert_data]" "$DOMAIN_FILE" > "${DOMAIN_FILE}.tmp"
        mv "${DOMAIN_FILE}.tmp" "$DOMAIN_FILE"

        echo ""
        echo -e "${CYAN}证书文件位置：${NC}"
        echo -e "  证书: ${GREEN}$CERT_DIR/$domain/cert.pem${NC}"
        echo -e "  密钥: ${GREEN}$CERT_DIR/$domain/key.pem${NC}"
        echo ""
        print_info "证书将自动续期"
    else
        print_error "证书申请失败"
        echo -e "${YELLOW}常见失败原因：${NC}"
        echo -e "  • 域名未正确解析到本服务器"
        echo -e "  • 80端口被占用（独立模式）"
        echo -e "  • DNS API配置错误（DNS验证）"
    fi
}

# 证书管理菜单
certificate_management_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║          证书管理                    ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}1.${NC} 查看证书"
        echo -e "${GREEN}2.${NC} 修改证书"
        echo -e "${GREEN}3.${NC} 添加自定义证书"
        echo -e "${GREEN}4.${NC} 删除证书"
        echo -e "${GREEN}5.${NC} 自动申请证书"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -p "请选择操作 [0-5]: " choice

        case $choice in
            1) list_certificates ;;
            2) modify_certificate ;;
            3) add_certificate ;;
            4) delete_certificate ;;
            5) auto_apply_certificate ;;
            0) break ;;
            *) print_error "无效选择" ;;
        esac

        read -p "按 Enter 键继续..."
    done
}
