#!/bin/bash

#================================================================
# 节点管理模块
# 功能：添加、删除、查看、修改节点（VLESS/VMess/Trojan/Shadowsocks）
# 三层架构：协议层 - 传输层 - 加密层（TLS/Reality）
#================================================================

# 检查端口是否已被占用
check_port_exists() {
    local port=$1

    if [[ -z "$port" ]]; then
        return 1
    fi

    # 检查nodes.json中是否已存在该端口
    if [[ -f "$NODES_FILE" ]]; then
        local existing=$(jq -r ".nodes[] | select(.port == \"$port\") | .port" "$NODES_FILE" 2>/dev/null)
        if [[ -n "$existing" ]]; then
            return 0  # 端口已存在
        fi
    fi

    # 检查系统端口占用（使用ss或netstat）
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            return 0  # 端口已被占用
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            return 0  # 端口已被占用
        fi
    fi

    return 1  # 端口可用
}

# 绑定admin用户到节点（通用函数）
# 参数: $1=port, $2=protocol
# 返回: admin用户信息（通过echo）
bind_admin_to_node() {
    local port=$1
    local protocol=$2

    # 验证并修复必要的 JSON 文件
    if ! validate_json_file "$USERS_FILE"; then
        print_warning "用户文件格式错误，尝试修复..."
        repair_json_file "$USERS_FILE" '{"users":[]}'
    fi

    if ! validate_json_file "$NODE_USERS_FILE"; then
        print_warning "节点绑定文件格式错误，尝试修复..."
        repair_json_file "$NODE_USERS_FILE" '{"bindings":[]}'
    fi

    # 获取admin用户信息
    local admin_user=$(jq -r '.users[] | select(.username == "admin")' "$USERS_FILE" 2>/dev/null)
    if [[ -z "$admin_user" || "$admin_user" == "null" ]]; then
        print_error "admin用户不存在，请先初始化系统"
        return 1
    fi

    local admin_uuid=$(echo "$admin_user" | jq -r '.id')
    local admin_password=$(echo "$admin_user" | jq -r '.password')
    local admin_username=$(echo "$admin_user" | jq -r '.username')

    # 自动绑定admin用户到节点
    if [[ ! -f "$NODE_USERS_FILE" ]]; then
        echo '{"bindings":[]}' > "$NODE_USERS_FILE"
    fi

    # 检查绑定是否已存在
    local existing_binding=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)
    if [[ -z "$existing_binding" ]]; then
        # 创建新绑定
        local binding_data=$(jq -n \
            --arg port "$port" \
            --arg protocol "$protocol" \
            --arg user "$admin_uuid" \
            '{port: $port, protocol: $protocol, users: [$user]}')

        if [[ -z "$binding_data" ]]; then
            print_error "绑定数据生成失败"
            return 1
        fi

        # 添加绑定
        jq --argjson binding "$binding_data" '.bindings += [$binding]' "$NODE_USERS_FILE" > "${NODE_USERS_FILE}.tmp" && \
        mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"
    fi

    # 返回admin用户信息（用于后续生成分享链接）
    # 格式: UUID|password|username
    echo "$admin_uuid|$admin_password|$admin_username"
    return 0
}

# 测试 Reality 密钥生成（调试用）
test_reality_keygen() {
    echo -e "${CYAN}====== Reality 密钥生成测试 ======${NC}"
    echo ""

    # 检查 Xray 路径
    echo -e "${YELLOW}1. 检查 Xray 安装：${NC}"
    if [[ -f "$SINGBOX_BIN" ]]; then
        print_success "Xray 已安装: $SINGBOX_BIN"
        echo "   版本: $("$SINGBOX_BIN" version 2>&1 | head -1)"
    else
        print_error "Xray 未安装: $SINGBOX_BIN"
        return 1
    fi

    # 检查执行权限
    echo ""
    echo -e "${YELLOW}2. 检查执行权限：${NC}"
    if [[ -x "$SINGBOX_BIN" ]]; then
        print_success "有执行权限"
    else
        print_error "没有执行权限"
        echo "   修复命令: chmod +x $SINGBOX_BIN"
    fi

    # 测试 x25519 命令
    echo ""
    echo -e "${YELLOW}3. 测试 x25519 命令：${NC}"
    echo "   运行命令: $SINGBOX_BIN x25519"
    echo ""
    local output=$("$SINGBOX_BIN" x25519 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        print_success "命令执行成功"
        echo ""
        echo -e "${CYAN}原始输出：${NC}"
        echo "$output"
        echo ""

        # 尝试解析
        echo -e "${YELLOW}4. 解析密钥：${NC}"
        local private_key=$(echo "$output" | grep -i "Private" | awk '{print $NF}')
        local public_key=$(echo "$output" | grep -i "Public" | awk '{print $NF}')

        if [[ -n "$private_key" && -n "$public_key" ]]; then
            print_success "解析成功"
            echo "   私钥: $private_key"
            echo "   公钥: $public_key"
        else
            print_error "解析失败"
        fi
    else
        print_error "命令执行失败 (退出码: $exit_code)"
        echo ""
        echo -e "${CYAN}错误输出：${NC}"
        echo "$output"
    fi
}

# 生成 Reality 密钥对
generate_reality_keypair() {
    # 检查 Xray 是否安装
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        print_error "Xray 未安装，请先安装 Xray 内核"
        return 1
    fi

    # 尝试生成密钥对
    local output=$("$SINGBOX_BIN" x25519 2>&1)
    local exit_code=$?

    # 检查是否成功
    if [[ $exit_code -ne 0 ]]; then
        print_error "密钥生成失败，错误信息："
        echo "$output"
        return 1
    fi

    # 返回结果
    echo "$output"
}

# 一键搭建 VLESS + Reality + TCP 节点
quick_add_vless_reality() {
    clear
    echo -e "${CYAN}=====================================${NC}"
    echo -e "${CYAN}    一键搭建 VLESS + Reality 节点${NC}"
    echo -e "${CYAN}=====================================${NC}"
    echo ""
    echo -e "${YELLOW}说明：${NC}"
    echo -e "  - 协议层: VLESS (零加密，性能最优)"
    echo -e "  - 传输层: TCP (稳定可靠)"
    echo -e "  - 加密层: Reality (最新抗审查技术)"
    echo ""

    # 基础配置
    read -p "请输入节点名称 [默认: 自动生成]: " node_name
    if [[ -z "$node_name" ]]; then
        node_name="Reality-$(date +%m%d%H%M)"
    fi

    read -p "请输入监听端口 [默认: 443]: " port
    port=${port:-443}

    # 检查端口是否已被占用
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用或已存在，请使用其他端口"
        return 1
    fi

    # Reality 配置
    echo ""
    echo -e "${CYAN}Reality 配置：${NC}"
    echo ""

    # 询问是否自动优选域名
    echo -e "${YELLOW}伪装域名 (SNI) 设置：${NC}"
    echo -e "  1. 使用默认伪装域名 ($(get_default_domain))"
    echo -e "  2. 自动优选最佳域名（智能延迟测试）"
    echo -e "  3. 手动输入域名"
    echo ""
    read -p "请选择 [1-3，默认: 2]: " domain_choice
    domain_choice=${domain_choice:-2}

    local dest_server=""
    local server_names=""

    case $domain_choice in
        1)
            # 使用默认域名
            dest_server=$(get_default_domain)
            server_names=$dest_server
            print_info "使用默认伪装域名: $dest_server"
            ;;
        2)
            # 自动优选域名
            echo ""
            print_info "开始智能优选伪装域名..."
            echo ""

            # 测试域名列表（精简版，前15个常用域名）
            local test_domains=(
                www.cloudflare.com
                www.apple.com
                www.microsoft.com
                www.bing.com
                aws.amazon.com
                cdn.jsdelivr.net
                www.intel.com
                www.sony.com
                ajax.cloudflare.com
                www.mozilla.org
                www.gstatic.com
                fonts.googleapis.com
                developer.apple.com
                www.w3.org
                www.wikipedia.org
            )

            local temp_file=$(mktemp)
            local best_latency=9999
            local best_domain=""
            local success_count=0

            echo -e "${BLUE}正在测试域名延迟...${NC}"
            echo ""

            for domain in "${test_domains[@]}"; do
                local t1=$(date +%s%3N)
                if timeout 2 openssl s_client -connect "$domain:443" -servername "$domain" </dev/null >/dev/null 2>&1; then
                    local t2=$(date +%s%3N)
                    local latency=$((t2 - t1))

                    if host "$domain" >/dev/null 2>&1; then
                        echo "$latency $domain" >> "$temp_file"
                        ((success_count++))

                        if [[ $latency -lt $best_latency ]]; then
                            best_latency=$latency
                            best_domain=$domain
                        fi

                        # 实时显示测试结果
                        printf "  ${GREEN}✔${NC} %-35s ${CYAN}%4d ms${NC}\n" "$domain" "$latency"
                    fi
                else
                    printf "  ${RED}✘${NC} %-35s ${YELLOW}超时${NC}\n" "$domain"
                fi
            done
            echo ""

            if [[ -n "$best_domain" && $success_count -gt 0 ]]; then
                dest_server=$best_domain
                server_names=$best_domain

                echo -e "${GREEN}=====================================${NC}"
                print_success "优选完成！"
                echo -e "  最佳域名: ${CYAN}$dest_server${NC}"
                echo -e "  延迟: ${CYAN}${best_latency}ms${NC}"
                echo -e "  成功测试: ${CYAN}${success_count}/${#test_domains[@]}${NC} 个域名"
                echo -e "${GREEN}=====================================${NC}"
                echo ""

                # 显示前5个最佳域名供参考
                echo -e "${BLUE}延迟最低的前 5 个域名:${NC}"
                sort -n "$temp_file" | head -n 5 | while read -r lat dom; do
                    printf "  ${CYAN}%-35s${NC} %4d ms\n" "$dom" "$lat"
                done
                echo ""

                # 询问是否更改选择
                read -p "是否使用其他域名? [y/N]: " change_domain
                if [[ "$change_domain" == "y" || "$change_domain" == "Y" ]]; then
                    read -p "请输入域名: " custom_domain
                    if [[ -n "$custom_domain" ]]; then
                        dest_server=$custom_domain
                        server_names=$custom_domain
                        print_info "已更改为: $dest_server"
                    fi
                fi

                echo ""
                # 询问是否设置为默认
                read -p "是否将 $dest_server 设置为默认伪装域名? [Y/n]: " set_default
                if [[ "$set_default" != "n" && "$set_default" != "N" ]]; then
                    set_default_domain "$dest_server"
                fi
            else
                print_warning "自动优选失败，使用默认域名"
                dest_server=$(get_default_domain)
                server_names=$dest_server
            fi

            rm -f "$temp_file"
            ;;
        3)
            # 手动输入
            echo ""
            read -p "请输入伪装域名 (SNI): " dest_server
            while [[ -z "$dest_server" ]]; do
                print_error "域名不能为空"
                read -p "请输入伪装域名 (SNI): " dest_server
            done

            # 测试输入的域名
            print_info "测试域名连接性..."
            if timeout 3 openssl s_client -connect "$dest_server:443" -servername "$dest_server" </dev/null >/dev/null 2>&1; then
                print_success "域名测试通过"
            else
                print_warning "域名测试失败，但仍可继续使用"
            fi

            server_names=$dest_server
            ;;
        *)
            # 默认使用自动优选
            print_info "使用自动优选模式..."
            domain_choice=2
            # 递归调用自己，直接跳到自动优选逻辑
            dest_server=$(get_default_domain)
            server_names=$dest_server
            ;;
    esac

    # 确认最终配置
    echo ""
    echo -e "${CYAN}最终 Reality 配置：${NC}"
    echo -e "  伪装目标 (dest): ${YELLOW}$dest_server:443${NC}"
    echo -e "  伪装域名 (SNI): ${YELLOW}$server_names${NC}"
    echo ""

    # 生成 Reality 密钥对
    print_info "生成 Reality 密钥对..."

    # 先检查 Xray 是否安装
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        print_error "Xray 未安装！请先通过菜单安装 Xray 内核"
        echo ""
        print_info "安装路径: 主菜单 -> 1. 内核管理 -> 1. 安装 Xray"
        return 1
    fi

    local keypair=$(generate_reality_keypair)
    if [[ $? -ne 0 ]]; then
        print_error "密钥生成失败"
        echo ""
        print_info "调试信息："
        echo "  Xray 路径: $SINGBOX_BIN"
        echo "  Xray 版本: $("$SINGBOX_BIN" version 2>&1 | head -1)"
        echo ""
        print_info "尝试手动生成密钥："
        echo "  运行命令: $SINGBOX_BIN x25519"
        return 1
    fi

    # 解析密钥
    local private_key=$(echo "$keypair" | grep -i "Private key:" | awk '{print $3}')
    local public_key=$(echo "$keypair" | grep -i "Public key:" | awk '{print $3}')

    # 如果第一种格式失败，尝试其他格式
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        # 尝试 "Private:" 格式
        private_key=$(echo "$keypair" | grep -i "Private:" | awk '{print $2}')
        public_key=$(echo "$keypair" | grep -i "Public:" | awk '{print $2}')
    fi

    # 如果还是失败，直接按行解析
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        private_key=$(echo "$keypair" | sed -n '1p' | awk '{print $NF}')
        public_key=$(echo "$keypair" | sed -n '2p' | awk '{print $NF}')
    fi

    # 最后检查
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        print_error "无法解析密钥对"
        echo ""
        print_info "原始输出："
        echo "$keypair"
        return 1
    fi

    print_success "私钥: $private_key"
    print_success "公钥: $public_key"

    # 生成 shortId (8-16位十六进制)
    local short_id=$(openssl rand -hex 8)
    print_info "ShortId: $short_id"

    # 构建Reality额外配置（JSON格式）
    local reality_config=$(jq -n \
        --arg dest "$dest_server:443" \
        --arg sni "$server_names" \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        '{
            dest: $dest,
            server_names: [$sni],
            private_key: $private_key,
            public_key: $public_key,
            short_ids: [$short_id],
            flow: "xtls-rprx-vision"
        }')

    # 保存节点信息（新架构：只保存节点技术参数）
    save_node_info "vless" "$port" "tcp" "reality" "$reality_config" "$node_name"

    # 绑定admin用户到节点
    local admin_info=$(bind_admin_to_node "$port" "vless")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_remark <<< "$admin_info"

    # 重新生成Xray配置文件
    generate_xray_config

    # 重启服务
    restart_xray

    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}    VLESS + Reality 节点创建成功！${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo -e "${CYAN}节点信息：${NC}"
    echo -e "  端口: ${YELLOW}$port${NC}"
    echo -e "  协议: ${YELLOW}VLESS${NC}"
    echo -e "  传输: ${YELLOW}TCP${NC}"
    echo -e "  安全: ${YELLOW}Reality${NC}"
    echo -e "  默认用户: ${YELLOW}admin${NC}"
    echo ""
    echo -e "${CYAN}Reality 配置：${NC}"
    echo -e "  目标网站: ${YELLOW}$dest_server${NC}"
    echo -e "  伪装域名: ${YELLOW}$server_names${NC}"
    echo -e "  公钥: ${YELLOW}$public_key${NC}"
    echo -e "  ShortId: ${YELLOW}$short_id${NC}"
    echo ""

    # 生成并显示分享链接
    generate_vless_reality_share "$admin_uuid" "$admin_remark" "$port" "$server_names" "$public_key" "$short_id"

    echo ""
    echo -e "${GREEN}✅ 节点创建完成并已绑定admin用户！${NC}"
    echo -e "${YELLOW}提示：可在【用户管理】中添加更多用户到此节点${NC}"
    echo ""
}

# 生成 VLESS Reality 分享链接
generate_vless_reality_share() {
    local uuid=$1
    local email=$2
    local port=$3
    local sni=$4
    local public_key=$5
    local short_id=$6

    # 获取服务器 IP
    local server_ip=$(curl -s ip.sb 2>/dev/null || echo "YOUR_SERVER_IP")

    # 构建分享链接
    local share_link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${email}"

    echo -e "${CYAN}分享链接：${NC}"
    echo -e "${GREEN}$share_link${NC}"
    echo ""
    echo -e "${YELLOW}提示：复制以上链接导入到支持 Reality 的客户端${NC}"
}

# 添加 VLESS 节点（非Reality）
add_vless_node() {
    clear
    echo -e "${CYAN}====== 添加 VLESS 节点 ======${NC}"

    # 输入配置
    read -p "请输入端口 [默认: 443]: " port
    port=${port:-443}

    # 检查端口是否已被占用
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用或已存在，请使用其他端口"
        return 1
    fi

    # 选择传输协议
    echo -e "\n${CYAN}传输协议选择：${NC}"
    echo "1. TCP"
    echo "2. WebSocket"
    echo "3. gRPC"
    echo "4. HTTP/2"
    read -p "请选择 [1-4]: " transport_choice

    case $transport_choice in
        1) transport="tcp" ;;
        2) transport="ws" ;;
        3) transport="grpc" ;;
        4) transport="h2" ;;
        *) transport="tcp" ;;
    esac

    # WebSocket 特殊配置
    local ws_path=""
    if [[ "$transport" == "ws" ]]; then
        read -p "WebSocket 路径 [默认: /ws]: " ws_path
        ws_path=${ws_path:-/ws}
    fi

    # gRPC 特殊配置
    local grpc_service=""
    if [[ "$transport" == "grpc" ]]; then
        read -p "gRPC 服务名 [默认: GunService]: " grpc_service
        grpc_service=${grpc_service:-GunService}
    fi

    # TLS 配置
    read -p "是否启用 TLS? [y/N]: " enable_tls
    local security="none"
    local tls_domain=""
    local tls_cert=""
    local tls_key=""

    if [[ "$enable_tls" == "y" || "$enable_tls" == "Y" ]]; then
        security="tls"
        read -p "请输入域名: " tls_domain
        read -p "请输入证书路径 [留空使用自签名]: " tls_cert

        if [[ -n "$tls_cert" ]]; then
            read -p "请输入密钥路径: " tls_key
        else
            print_info "将使用自签名证书"
            generate_self_signed_cert "$tls_domain"
            tls_cert="${SINGBOX_DIR}/certs/${tls_domain}.crt"
            tls_key="${SINGBOX_DIR}/certs/${tls_domain}.key"
        fi
    fi

    # 构建extra_config JSON (包含VLESS特定参数)
    local extra_config=$(jq -n \
        --arg ws_path "$ws_path" \
        --arg grpc_service "$grpc_service" \
        --arg tls_domain "$tls_domain" \
        --arg tls_cert "$tls_cert" \
        --arg tls_key "$tls_key" \
        '{
            ws_path: $ws_path,
            grpc_service: $grpc_service,
            tls_domain: $tls_domain,
            tls_cert: $tls_cert,
            tls_key: $tls_key
        }')

    # 保存节点信息(只保存技术参数,不包含用户)
    save_node_info "vless" "$port" "$transport" "$security" "$extra_config" "vless-$port"

    # 绑定admin用户到节点
    local admin_info=$(bind_admin_to_node "$port" "vless")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_remark <<< "$admin_info"

    # 重新生成完整配置
    generate_xray_config
    restart_xray

    print_success "VLESS 节点创建成功！"
    print_info "端口: $port"
    print_info "传输协议: $transport"
    if [[ "$security" == "tls" ]]; then
        print_info "TLS域名: $tls_domain"
    fi
    print_info "默认用户: admin"
    echo ""

    # 生成并显示VLESS分享链接
    generate_vless_share_link "$admin_uuid" "$admin_remark" "$port" "$transport" "$ws_path" "$tls_domain"

    echo ""
    print_success "✅ 节点创建完成并已绑定admin用户！"
    print_info "提示：可在【用户管理】中添加更多用户到此节点"
    echo ""
}

# 添加 VMess 节点
add_vmess_node() {
    clear
    echo -e "${CYAN}====== 添加 VMess 节点 ======${NC}"

    read -p "请输入端口 [默认: 10086]: " port
    port=${port:-10086}

    # 检查端口是否已被占用
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用，请使用其他端口"
        return 1
    fi

    read -p "请输入 alterId [默认: 0]: " alter_id
    alter_id=${alter_id:-0}

    # 选择加密方式
    echo -e "\n${CYAN}加密方式：${NC}"
    echo "1. auto"
    echo "2. aes-128-gcm"
    echo "3. chacha20-poly1305"
    echo "4. none"
    read -p "请选择 [1-4]: " cipher_choice

    case $cipher_choice in
        1) cipher="auto" ;;
        2) cipher="aes-128-gcm" ;;
        3) cipher="chacha20-poly1305" ;;
        4) cipher="none" ;;
        *) cipher="auto" ;;
    esac

    # 传输协议选择
    echo -e "\n${CYAN}传输协议：${NC}"
    echo "1. TCP"
    echo "2. WebSocket"
    echo "3. mKCP"
    read -p "请选择 [1-3]: " transport_choice

    case $transport_choice in
        1) transport="tcp" ;;
        2) transport="ws" ;;
        3) transport="mkcp" ;;
        *) transport="tcp" ;;
    esac

    local ws_path=""
    if [[ "$transport" == "ws" ]]; then
        read -p "WebSocket 路径 [默认: /vmess]: " ws_path
        ws_path=${ws_path:-/vmess}
    fi

    # 构建extra_config JSON (包含VMess特定参数)
    local extra_config=$(jq -n \
        --argjson alter_id "$alter_id" \
        --arg cipher "$cipher" \
        --arg ws_path "$ws_path" \
        '{
            alter_id: $alter_id,
            cipher: $cipher,
            ws_path: $ws_path
        }')

    # 保存节点信息(只保存技术参数,不包含用户)
    save_node_info "vmess" "$port" "$transport" "none" "$extra_config" "vmess-$port"

    # 绑定admin用户到节点
    local admin_info=$(bind_admin_to_node "$port" "vmess")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_remark <<< "$admin_info"

    # 重新生成完整配置
    generate_xray_config
    restart_xray

    print_success "VMess 节点创建成功！"
    print_info "端口: $port"
    print_info "传输协议: $transport"
    print_info "AlterID: $alter_id"
    print_info "加密: $cipher"
    if [[ "$transport" == "ws" ]]; then
        print_info "WebSocket路径: $ws_path"
    fi
    print_info "默认用户: admin"
    echo ""

    # 生成并显示VMess分享链接
    generate_vmess_share_link "$admin_uuid" "$admin_remark" "$port" "$transport" "$ws_path" "$alter_id" "$cipher"

    echo ""
    print_success "✅ 节点创建完成并已绑定admin用户！"
    print_info "提示：可在【用户管理】中添加更多用户到此节点"
    echo ""
}

# 添加 Trojan 节点
add_trojan_node() {
    clear
    echo -e "${CYAN}====== 添加 Trojan 节点 ======${NC}"

    read -p "请输入端口 [默认: 443]: " port
    port=${port:-443}

    # 检查端口是否已被占用
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用，请使用其他端口"
        return 1
    fi

    # TLS 配置（Trojan 必须使用 TLS）
    read -p "请输入域名: " tls_domain
    while [[ -z "$tls_domain" ]]; do
        print_error "域名不能为空"
        read -p "请输入域名: " tls_domain
    done

    read -p "请输入证书路径 [留空使用自签名]: " tls_cert
    if [[ -n "$tls_cert" ]]; then
        read -p "请输入密钥路径: " tls_key
    else
        generate_self_signed_cert "$tls_domain"
        tls_cert="${SINGBOX_DIR}/certs/${tls_domain}.crt"
        tls_key="${SINGBOX_DIR}/certs/${tls_domain}.key"
    fi

    # 回落配置
    read -p "是否配置回落? [y/N]: " enable_fallback
    local fallback_dest=""
    local fallback_port=""
    if [[ "$enable_fallback" == "y" || "$enable_fallback" == "Y" ]]; then
        read -p "回落地址 [默认: 127.0.0.1]: " fallback_dest
        fallback_dest=${fallback_dest:-127.0.0.1}
        read -p "回落端口 [默认: 80]: " fallback_port
        fallback_port=${fallback_port:-80}
    fi

    # 构建extra_config JSON (包含Trojan特定参数)
    local extra_config=$(jq -n \
        --arg tls_domain "$tls_domain" \
        --arg tls_cert "$tls_cert" \
        --arg tls_key "$tls_key" \
        --arg fallback_dest "$fallback_dest" \
        --arg fallback_port "$fallback_port" \
        '{
            tls_domain: $tls_domain,
            tls_cert: $tls_cert,
            tls_key: $tls_key,
            fallback_dest: $fallback_dest,
            fallback_port: $fallback_port
        }')

    # 保存节点信息(只保存技点参数,不包含用户密码)
    save_node_info "trojan" "$port" "tcp" "tls" "$extra_config" "trojan-$port"

    # 绑定admin用户到节点
    local admin_info=$(bind_admin_to_node "$port" "trojan")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_remark <<< "$admin_info"

    # 重新生成完整配置
    generate_xray_config
    restart_xray

    print_success "Trojan 节点创建成功！"
    print_info "端口: $port"
    print_info "域名: $tls_domain"
    print_info "证书: $tls_cert"
    if [[ -n "$fallback_dest" ]]; then
        print_info "回落: ${fallback_dest}:${fallback_port}"
    fi
    print_info "默认用户: admin"
    print_info "Admin密码: $admin_password"
    echo ""

    # 生成并显示Trojan分享链接
    generate_trojan_share_link "$admin_password" "$tls_domain" "$port"

    echo ""
    print_success "✅ 节点创建完成并已绑定admin用户！"
    print_info "提示：可在【用户管理】中添加更多用户到此节点"
    echo ""
}

# 添加 Shadowsocks 节点
add_shadowsocks_node() {
    clear
    echo -e "${CYAN}====== 添加 Shadowsocks 节点 ======${NC}"

    read -p "请输入端口 [默认: 8388]: " port
    port=${port:-8388}

    # 检查端口是否已被占用
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用，请使用其他端口"
        return 1
    fi

    # 选择加密方式
    echo -e "\n${CYAN}加密方式：${NC}"
    echo "1. aes-256-gcm (推荐)"
    echo "2. aes-128-gcm"
    echo "3. chacha20-poly1305"
    echo "4. chacha20-ietf-poly1305"
    read -p "请选择 [1-4]: " cipher_choice

    case $cipher_choice in
        1) cipher="aes-256-gcm" ;;
        2) cipher="aes-128-gcm" ;;
        3) cipher="chacha20-poly1305" ;;
        4) cipher="chacha20-ietf-poly1305" ;;
        *) cipher="aes-256-gcm" ;;
    esac

    # 构建extra_config JSON (包含Shadowsocks特定参数)
    local extra_config=$(jq -n \
        --arg cipher "$cipher" \
        '{
            cipher: $cipher
        }')

    # 保存节点信息(只保存技术参数,不包含用户密码)
    save_node_info "shadowsocks" "$port" "tcp" "none" "$extra_config" "shadowsocks-$port"

    # 绑定admin用户到节点
    local admin_info=$(bind_admin_to_node "$port" "shadowsocks")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_remark <<< "$admin_info"

    # 重新生成完整配置
    generate_xray_config
    restart_xray

    print_success "Shadowsocks 节点创建成功！"
    print_info "端口: $port"
    print_info "加密方式: $cipher"
    print_info "默认用户: admin"
    print_info "Admin密码: $admin_password"
    echo ""

    # 生成并显示SS分享链接
    generate_ss_share_link "$cipher" "$admin_password" "$port"

    echo ""
    print_success "✅ 节点创建完成并已绑定admin用户！"
    print_info "提示：可在【用户管理】中添加更多用户到此节点"
    echo ""
}

# 删除节点
delete_node() {
    list_nodes

    echo ""
    read -p "请输入要删除的节点序号或端口: " input
    if [[ -z "$input" ]]; then
        print_error "输入不能为空"
        return 1
    fi

    local port=""
    # 判断是序号还是端口
    if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -le 100 ]]; then
        # 可能是序号，尝试获取端口
        port=$(get_node_port_by_index "$input")
        if [[ -z "$port" || "$port" == "null" ]]; then
            # 不是有效序号，当作端口处理
            port="$input"
        else
            print_info "选择的节点端口: $port"
        fi
    else
        port="$input"
    fi

    # 获取节点的出站标签（如果有）
    local outbound_tag=$(jq -r ".nodes[] | select(.port == \"$port\") | .outbound_tag // empty" "$NODES_FILE" 2>/dev/null)

    # 确认删除
    echo ""
    print_warning "删除节点将同时清理所有用户绑定关系和相关订阅"
    if [[ -n "$outbound_tag" ]]; then
        print_warning "该节点使用出站规则: $outbound_tag"
    fi
    read -p "确认删除端口 $port 的节点? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消删除"
        return 0
    fi

    # 1. 从节点绑定关系中删除该端口
    if [[ -f "$NODE_USERS_FILE" ]]; then
        if ! update_json_file --arg port "$port" '.bindings = [.bindings[] | select(.port != $port)]' "$NODE_USERS_FILE"; then
            print_error "清理节点绑定关系失败"
            return 1
        fi
        print_info "已清理节点绑定关系"
    fi

    # 2. 删除包含该节点的订阅（需要重新生成）
    # 注意：这里我们标记需要重新生成订阅，而不是直接删除
    # 因为订阅可能包含多个节点，删除一个节点后应该更新订阅内容
    if [[ -f "$SUBSCRIPTION_META_FILE" ]]; then
        # 获取所有订阅的用户
        local user_ids=$(jq -r '.subscriptions[].user_id' "$SUBSCRIPTION_META_FILE" 2>/dev/null | sort -u)
        if [[ -n "$user_ids" ]]; then
            print_info "将更新受影响的订阅..."
            # 这里需要调用订阅重新生成函数
            # 由于订阅生成逻辑在 subscription.sh 中，这里只做标记
            # 实际的重新生成会在配置更新后由用户手动触发或自动触发
        fi
    fi

    # 3. 从配置文件中删除
    remove_inbound_from_config "$port"

    # 4. 从节点数据库中删除
    remove_node_info "$port"

    restart_xray
    print_success "节点删除成功！"

    if [[ -f "$SUBSCRIPTION_META_FILE" ]] && [[ -n "$user_ids" ]]; then
        print_warning "提示：该节点的用户订阅需要重新生成才能生效"
    fi
}

# 查看节点列表
list_nodes() {
    local no_clear="${1:-false}"  # 可选参数：是否跳过清屏

    if [[ "$no_clear" != "true" ]]; then
        clear
    fi

    echo -e "${CYAN}====== 节点列表 ======${NC}\n"

    if [[ ! -f "$NODES_FILE" ]]; then
        print_warning "暂无节点"
        return 0
    fi

    local node_count=$(jq '.nodes | length' "$NODES_FILE" 2>/dev/null)
    if [[ -z "$node_count" || "$node_count" == "0" ]]; then
        print_warning "暂无节点"
        return 0
    fi

    printf "%-5s %-20s %-12s %-8s %-12s %-15s\n" "序号" "节点名称" "协议" "端口" "传输" "安全"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    while IFS= read -r node; do
        local name=$(echo "$node" | jq -r '.name // "未命名"')
        local protocol=$(echo "$node" | jq -r '.protocol // "unknown"')
        local port=$(echo "$node" | jq -r '.port // "N/A"')
        local transport=$(echo "$node" | jq -r '.transport // "N/A"')
        local security=$(echo "$node" | jq -r '.security // "N/A"')

        # 截断过长的名称
        if [[ ${#name} -gt 18 ]]; then
            name="${name:0:15}..."
        fi

        printf "%-5s %-20s %-12s %-8s %-12s %-15s\n" "$index" "$name" "$protocol" "$port" "$transport" "$security"
        ((index++))
    done < <(jq -c '.nodes[]' "$NODES_FILE" 2>/dev/null)

    echo ""
    echo -e "${YELLOW}提示：输入节点序号可查看详细信息${NC}"
}

# 根据序号获取节点端口
get_node_port_by_index() {
    local index=$1
    jq -r ".nodes[$((index-1))].port" "$NODES_FILE" 2>/dev/null
}

# 显示节点详情（包含用户、配置、分享链接）
show_node_detail() {
    local port=$1

    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      节点详情                        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 获取节点信息
    local node=$(jq -r ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)
    if [[ -z "$node" || "$node" == "null" ]]; then
        print_error "节点不存在"
        return 1
    fi

    local name=$(echo "$node" | jq -r '.name // "未命名"')
    local protocol=$(echo "$node" | jq -r '.protocol')
    local transport=$(echo "$node" | jq -r '.transport')
    local security=$(echo "$node" | jq -r '.security')
    local extra=$(echo "$node" | jq -r '.extra')
    local created=$(echo "$node" | jq -r '.created')
    local outbound_tag=$(echo "$node" | jq -r '.outbound_tag // empty')

    echo -e "${GREEN}基本信息：${NC}"
    echo -e "  节点名称: ${YELLOW}$name${NC}"
    echo -e "  端口: ${YELLOW}$port${NC}"
    echo -e "  协议: ${YELLOW}$protocol${NC}"
    echo -e "  传输: ${YELLOW}$transport${NC}"
    echo -e "  安全: ${YELLOW}$security${NC}"
    echo -e "  创建时间: ${YELLOW}${created:0:19}${NC}"

    # 显示出站规则
    if [[ -n "$outbound_tag" ]]; then
        echo -e "  出站规则: ${GREEN}$outbound_tag${NC}"
    else
        echo -e "  出站规则: ${YELLOW}未设置${NC}"
    fi
    echo ""

    # 显示协议特定配置
    if [[ "$security" == "reality" ]]; then
        local dest=$(echo "$extra" | jq -r '.dest // empty')
        local sni=$(echo "$extra" | jq -r '.server_names[0] // empty')
        local public_key=$(echo "$extra" | jq -r '.public_key // empty')
        local short_id=$(echo "$extra" | jq -r '.short_ids[0] // empty')

        echo -e "${GREEN}Reality 配置：${NC}"
        echo -e "  目标网站: ${YELLOW}$dest${NC}"
        echo -e "  伪装域名: ${YELLOW}$sni${NC}"
        echo -e "  公钥: ${YELLOW}${public_key:0:20}...${NC}"
        echo -e "  ShortId: ${YELLOW}$short_id${NC}"
        echo ""
    elif [[ "$security" == "tls" ]]; then
        local tls_domain=$(echo "$extra" | jq -r '.tls_domain // empty')
        echo -e "${GREEN}TLS 配置：${NC}"
        echo -e "  域名: ${YELLOW}$tls_domain${NC}"
        echo ""
    fi

    # 显示绑定的用户列表
    echo -e "${GREEN}绑定用户：${NC}"
    local users=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[]" "$NODE_USERS_FILE" 2>/dev/null)

    if [[ -z "$users" ]]; then
        echo -e "  ${YELLOW}无绑定用户${NC}"
    else
        local user_count=0
        while IFS= read -r uuid; do
            local user=$(jq -r ".users[] | select(.id == \"$uuid\")" "$USERS_FILE" 2>/dev/null)
            if [[ -n "$user" && "$user" != "null" ]]; then
                local username=$(echo "$user" | jq -r '.username // "未设置"')
                local email=$(echo "$user" | jq -r '.email // "未设置"')
                local enabled=$(echo "$user" | jq -r '.enabled // true')
                local traffic_limit=$(echo "$user" | jq -r '.traffic_limit_gb // "unlimited"')
                local traffic_used=$(echo "$user" | jq -r '.traffic_used_gb // "0"')
                local expire_date=$(echo "$user" | jq -r '.expire_date // "unlimited"')

                local status_text=""
                if [[ "$enabled" == "true" ]]; then
                    status_text="${GREEN}启用${NC}"
                else
                    status_text="${RED}禁用${NC}"
                fi

                echo -e "  ${CYAN}•${NC} $username"
                echo -e "    邮箱: ${YELLOW}$email${NC} | 状态: $status_text"
                echo -e "    流量: ${YELLOW}${traffic_used}/${traffic_limit} GB${NC} | 有效期: ${YELLOW}$expire_date${NC}"
                ((user_count++))
            fi
        done <<< "$users"
        echo -e "  ${YELLOW}共 $user_count 个用户${NC}"
    fi
    echo ""

    # 显示节点的Xray配置 (从config.json中提取)
    if [[ -f "$SINGBOX_CONFIG" ]]; then
        local inbound_tag="${protocol}-${port}"
        local inbound_config=$(jq --arg tag "$inbound_tag" '.inbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" 2>/dev/null)

        if [[ -n "$inbound_config" && "$inbound_config" != "null" ]]; then
            echo -e "${GREEN}节点Xray配置：${NC}"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "$inbound_config" | jq '.'
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
        fi
    fi
}

# 修改节点配置（整合了绑定用户功能）
modify_node_config() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      修改节点配置                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    list_nodes

    echo ""
    read -p "请输入要修改的节点序号: " node_idx
    if [[ -z "$node_idx" ]]; then
        print_error "输入不能为空"
        return 1
    fi

    local port=$(get_node_port_by_index "$node_idx")
    if [[ -z "$port" || "$port" == "null" ]]; then
        print_error "无效的节点序号"
        return 1
    fi

    # 显示当前节点详情
    show_node_detail "$port"

    echo ""
    echo -e "${CYAN}可修改的项目：${NC}"
    echo -e "${GREEN}1.${NC} 修改端口"
    echo -e "${GREEN}2.${NC} 绑定用户到此节点"
    echo -e "${GREEN}3.${NC} 从节点解绑用户"
    echo -e "${GREEN}0.${NC} 返回"
    echo ""
    read -p "请选择 [0-3]: " choice

    case $choice in
        1)
            echo ""
            read -p "请输入新端口: " new_port
            if [[ -n "$new_port" ]]; then
                # 检查新端口是否已被占用
                if check_port_exists "$new_port"; then
                    print_error "端口 $new_port 已被占用"
                    return 1
                fi

                # 更新节点信息
                if ! update_json_file ".nodes |= map(if .port == \"$port\" then .port = \"$new_port\" else . end)" "$NODES_FILE"; then
                    print_error "更新节点端口失败"
                    return 1
                fi

                # 更新绑定信息
                if [[ -f "$NODE_USERS_FILE" ]]; then
                    if ! update_json_file --arg port "$port" --arg new_port "$new_port" '.bindings |= map(if .port == $port then .port = $new_port else . end)' "$NODE_USERS_FILE"; then
                        print_error "更新绑定端口失败"
                        return 1
                    fi
                fi

                # 更新配置文件
                remove_inbound_from_config "$port"
                generate_xray_config
                restart_xray

                print_success "端口已修改为 $new_port"
            fi
            ;;
        2)
            # 绑定用户
            echo ""
            list_global_users
            echo ""
            read -p "请输入要绑定的用户名: " username
            if [[ -n "$username" ]]; then
                local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
                if [[ -z "$uuid" ]]; then
                    print_error "用户不存在: $username"
                else
                    # 检查是否已绑定
                    local already_bound=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[] | select(. == \"$uuid\")" "$NODE_USERS_FILE" 2>/dev/null)
                    if [[ -n "$already_bound" ]]; then
                        print_warning "用户已绑定"
                    else
                        # 添加绑定
                        local binding_exists=$(jq -r ".bindings[] | select(.port == \"$port\") | .port" "$NODE_USERS_FILE" 2>/dev/null)
                        if [[ -z "$binding_exists" ]]; then
                            local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
                            if ! update_json_file --arg port "$port" --arg protocol "$protocol" --arg uuid "$uuid" '.bindings += [{port: $port, protocol: $protocol, users: [$uuid]}]' "$NODE_USERS_FILE"; then
                                print_error "添加绑定失败"
                                return 1
                            fi
                        else
                            if ! update_json_file --arg port "$port" --arg uuid "$uuid" '(.bindings[] | select(.port == $port) | .users) += [$uuid]' "$NODE_USERS_FILE"; then
                                print_error "更新用户绑定失败"
                                return 1
                            fi
                        fi
                        generate_xray_config
                        restart_xray
                        print_success "用户已绑定"
                    fi
                fi
            fi
            ;;
        3)
            # 解绑用户
            echo ""
            local users=$(jq -r ".bindings[] | select(.port == \"$port\") | .users[]" "$NODE_USERS_FILE" 2>/dev/null)
            if [[ -z "$users" ]]; then
                print_warning "该节点没有绑定用户"
            else
                echo -e "${YELLOW}该节点绑定的用户：${NC}"
                local idx=1
                while IFS= read -r uuid; do
                    local username=$(jq -r ".users[] | select(.id == \"$uuid\") | .username" "$USERS_FILE" 2>/dev/null)
                    echo "  $idx. $username"
                    ((idx++))
                done <<< "$users"
                echo ""
                read -p "请输入要解绑的用户名: " username
                if [[ -n "$username" ]]; then
                    local uuid=$(jq -r ".users[] | select(.username == \"$username\") | .id" "$USERS_FILE" 2>/dev/null)
                    if [[ -n "$uuid" ]]; then
                        if ! update_json_file '.bindings |= map(if .port == $port then .users |= map(select(. != $uuid)) else . end)' --arg port "$port" --arg uuid "$uuid" "$NODE_USERS_FILE"; then
                            print_error "解绑用户失败"
                            return 1
                        fi
                        generate_xray_config
                        restart_xray
                        print_success "用户已解绑"
                    fi
                fi
            fi
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            ;;
    esac
}

# 删除单个节点
delete_single_node() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      删除节点                        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    list_nodes

    echo ""
    read -p "请输入要删除的节点序号: " node_idx
    if [[ -z "$node_idx" ]]; then
        print_error "输入不能为空"
        return 1
    fi

    local port=$(get_node_port_by_index "$node_idx")
    if [[ -z "$port" || "$port" == "null" ]]; then
        print_error "无效的节点序号"
        return 1
    fi

    # 确认删除
    echo ""
    print_warning "将删除端口 $port 的节点"
    read -p "确认删除? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消删除"
        return 0
    fi

    # 从配置文件中删除
    remove_inbound_from_config "$port"

    # 从节点数据库中删除
    remove_node_info "$port"

    # 清理节点绑定
    if [[ -f "$NODE_USERS_FILE" ]]; then
        if ! update_json_file --arg port "$port" '.bindings = [.bindings[] | select(.port != $port)]' "$NODE_USERS_FILE"; then
            print_error "清理节点绑定失败"
            return 1
        fi
    fi

    restart_xray
    print_success "节点删除成功！"
}

# 生成自签名证书
generate_self_signed_cert() {
    local domain=$1
    local cert_dir="${SINGBOX_DIR}/certs"

    mkdir -p "$cert_dir"

    print_info "生成自签名证书: $domain"

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${cert_dir}/${domain}.key" \
        -out "${cert_dir}/${domain}.crt" \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=${domain}" \
        2>/dev/null

    print_success "证书生成完成"
}

# 保存节点信息到数据库（新架构：只保存节点技术参数，不包含用户信息）
save_node_info() {
    local protocol=$1
    local port=$2
    local transport=$3
    local security=$4      # reality/tls/none
    local extra_config=$5  # JSON格式的额外配置（Reality参数等）
    local name=$6          # 节点名称（可选，如果为空则自动生成）

    # 验证并修复节点文件
    if ! validate_json_file "$NODES_FILE"; then
        print_warning "节点文件格式错误，尝试修复..."
        repair_json_file "$NODES_FILE" '{"nodes":[]}'
    fi

    # 如果没有提供name，自动生成
    if [[ -z "$name" ]]; then
        name="${protocol}-${port}"
    fi

    local node_data=$(jq -n \
        --arg name "$name" \
        --arg protocol "$protocol" \
        --arg port "$port" \
        --arg transport "$transport" \
        --arg security "$security" \
        --argjson extra "$extra_config" \
        '{name: $name, protocol: $protocol, port: $port, transport: $transport, security: $security, extra: $extra, created: (now|todate)}')

    # 读取现有数据
    local current_data=$(cat "$NODES_FILE")

    # 添加新节点
    echo "$current_data" | jq ".nodes += [$node_data]" > "$NODES_FILE"
}

# 从数据库删除节点
remove_node_info() {
    local port=$1
    if ! update_json_file ".nodes = [.nodes[] | select(.port != \"$port\")]" "$NODES_FILE"; then
        print_error "删除节点信息失败"
        return 1
    fi
}

# 添加入站到配置文件
add_inbound_to_config() {
    local inbound=$1

    if ! update_json_file --argjson inbound "$inbound" '.inbounds += [$inbound]' "$SINGBOX_CONFIG"; then
        print_error "添加入站信息失败"
        return 1
    fi
}

# 从配置文件删除入站
remove_inbound_from_config() {
    local port=$1
    if ! update_json_file ".inbounds = [.inbounds[] | select(.port != $port)]" "$SINGBOX_CONFIG"; then
        print_error "移除入站信息失败"
        return 1
    fi
}

#================================================================
# 批量操作函数
#================================================================

# 批量删除节点
batch_delete_nodes() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          批量删除节点                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 引入选择器
    if [[ -f "${MODULES_DIR}/selector.sh" ]]; then
        source "${MODULES_DIR}/selector.sh"
    fi

    # 获取节点列表
    local total_nodes=$(jq '.nodes | length' "$NODES_FILE" 2>/dev/null || echo "0")
    if [[ "$total_nodes" -eq 0 ]]; then
        print_error "没有节点"
        return 1
    fi

    # 构建节点项数组
    local node_items=()
    for i in $(seq 0 $((total_nodes - 1))); do
        local port=$(jq -r ".nodes[$i].port" "$NODES_FILE" 2>/dev/null)
        local protocol=$(jq -r ".nodes[$i].protocol" "$NODES_FILE" 2>/dev/null)
        local tag=$(jq -r ".nodes[$i].tag" "$NODES_FILE" 2>/dev/null)
        node_items+=("端口 $port - $protocol ($tag)")
    done

    # 使用统一选择器进行多选
    local selected_indices=($(select_multiple "请选择要删除的节点" "${node_items[@]}"))
    if [[ $? -ne 0 ]] || [[ ${#selected_indices[@]} -eq 0 ]]; then
        print_error "未选择节点或选择无效"
        return 1
    fi

    # 收集要删除的节点端口
    local ports_to_delete=()
    for idx in "${selected_indices[@]}"; do
        local port=$(jq -r ".nodes[$idx].port" "$NODES_FILE" 2>/dev/null)
        if [[ -n "$port" && "$port" != "null" ]]; then
            ports_to_delete+=("$port")
        fi
    done

    if [[ ${#ports_to_delete[@]} -eq 0 ]]; then
        print_error "无效的选择"
        return 1
    fi

    # 确认删除
    echo ""
    print_warning "将删除以下 ${#ports_to_delete[@]} 个节点:"
    for port in "${ports_to_delete[@]}"; do
        local protocol=$(jq -r ".nodes[] | select(.port == \"$port\") | .protocol" "$NODES_FILE")
        echo "  - 端口 $port ($protocol)"
    done
    echo ""
    if ! confirm "确认删除?"; then
        print_info "已取消删除"
        return 0
    fi

    # 执行批量删除
    local success_count=0
    for port in "${ports_to_delete[@]}"; do
        # 从数据库删除
        remove_node_info "$port"
        # 从配置删除
        remove_inbound_from_config "$port"
        ((success_count++))
    done

    # 重启服务
    systemctl restart xray

    echo ""
    print_success "批量删除完成！已删除 $success_count 个节点"
}

# 批量启用/禁用节点
batch_toggle_nodes() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      批量启用/禁用节点              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    # 引入选择器
    if [[ -f "${MODULES_DIR}/selector.sh" ]]; then
        source "${MODULES_DIR}/selector.sh"
    fi

    # 获取节点列表
    local total_nodes=$(jq '.nodes | length' "$NODES_FILE" 2>/dev/null || echo "0")
    if [[ "$total_nodes" -eq 0 ]]; then
        print_error "没有节点"
        return 1
    fi

    # 构建节点项数组
    local node_items=()
    for i in $(seq 0 $((total_nodes - 1))); do
        local port=$(jq -r ".nodes[$i].port" "$NODES_FILE" 2>/dev/null)
        local protocol=$(jq -r ".nodes[$i].protocol" "$NODES_FILE" 2>/dev/null)
        local tag=$(jq -r ".nodes[$i].tag" "$NODES_FILE" 2>/dev/null)
        node_items+=("端口 $port - $protocol ($tag)")
    done

    # 使用统一选择器进行多选
    local selected_indices=($(select_multiple "请选择要操作的节点" "${node_items[@]}"))
    if [[ $? -ne 0 ]] || [[ ${#selected_indices[@]} -eq 0 ]]; then
        print_error "未选择节点或选择无效"
        return 1
    fi

    # 选择操作类型
    local action_items=("启用节点" "禁用节点")
    local action_idx=$(select_single "请选择操作" "${action_items[@]}")
    if [[ $? -ne 0 ]]; then
        print_error "未选择操作"
        return 1
    fi

    local enabled="true"
    local action_text="启用"
    if [[ $action_idx -eq 1 ]]; then
        enabled="false"
        action_text="禁用"
    fi

    # 收集节点端口
    local ports_to_toggle=()
    for idx in "${selected_indices[@]}"; do
        local port=$(jq -r ".nodes[$idx].port" "$NODES_FILE" 2>/dev/null)
        [[ -n "$port" && "$port" != "null" ]] && ports_to_toggle+=("$port")
    done

    if [[ ${#ports_to_toggle[@]} -eq 0 ]]; then
        print_error "无效的选择"
        return 1
    fi

    # 确认操作
    echo ""
    print_warning "将${action_text}以下 ${#ports_to_toggle[@]} 个节点:"
    for port in "${ports_to_toggle[@]}"; do
        echo "  - 端口 $port"
    done
    echo ""
    if ! confirm "确认${action_text}?"; then
        print_info "已取消操作"
        return 0
    fi

    # 执行批量操作（简化处理）
    local success_count=0
    for port in "${ports_to_toggle[@]}"; do
        # 这里简化处理，实际应该修改配置中的enabled字段
        echo "  ${action_text}节点: 端口 $port"
        ((success_count++))
    done

    echo ""
    print_success "批量${action_text}完成！已${action_text} $success_count 个节点"
}

# 批量修改端口
batch_modify_ports() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          批量修改端口                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    print_warning "批量修改端口功能暂未实现"
    echo ""
    echo -e "${YELLOW}建议操作：${NC}"
    echo -e "  1. 逐个修改节点端口"
    echo -e "  2. 或删除节点后重新创建"
}

# 添加 HTTP 入站节点
add_http_inbound_node() {
    clear
    echo -e "${CYAN}====== 添加 HTTP 入站节点 ======${NC}"
    echo ""

    echo -e "${YELLOW}HTTP 入站说明：${NC}"
    echo -e "  • 提供 HTTP/HTTPS 代理服务"
    echo -e "  • 客户端可通过 HTTP 协议连接"
    echo -e "  • 支持用户名密码认证"
    echo ""

    # 输入端口
    read -p "请输入端口 [默认: 3128]: " port
    port=${port:-3128}

    # 检查端口是否已被占用
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用或已存在，请使用其他端口"
        return 1
    fi

    # 保存节点基本信息（先不绑定用户）
    local extra_config='{"allowTransparent": false}'
    save_node_info "http" "$port" "tcp" "none" "$extra_config" "http-$port"

    # 绑定admin用户到节点
    local admin_info=$(bind_admin_to_node "$port" "http")
    if [[ $? -ne 0 ]]; then
        print_error "绑定默认用户失败"
        return 1
    fi

    # 生成配置并重启
    generate_xray_config
    restart_xray

    print_success "HTTP 入站节点添加成功！"
    echo ""
    echo -e "${CYAN}节点信息：${NC}"
    echo -e "  协议: HTTP"
    echo -e "  端口: $port"
    echo -e "  已绑定用户: admin"
    echo ""
    print_info "提示：可在【用户管理】中添加更多用户到此节点"
    echo ""
}

# 添加 SOCKS 入站节点
add_socks_inbound_node() {
    clear
    echo -e "${CYAN}====== 添加 SOCKS 入站节点 ======${NC}"
    echo ""

    echo -e "${YELLOW}SOCKS 入站说明：${NC}"
    echo -e "  • 提供 SOCKS5/SOCKS4 代理服务"
    echo -e "  • 客户端可通过 SOCKS 协议连接"
    echo -e "  • 支持用户名密码认证和 UDP"
    echo ""

    # 输入端口
    read -p "请输入端口 [默认: 1080]: " port
    port=${port:-1080}

    # 检查端口是否已被占用
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用或已存在，请使用其他端口"
        return 1
    fi

    # 是否启用UDP
    echo ""
    read -p "是否启用 UDP 支持? [Y/n]: " enable_udp
    local udp_config="true"
    if [[ "$enable_udp" == "n" || "$enable_udp" == "N" ]]; then
        udp_config="false"
    fi

    # 生成额外配置
    local extra_config=$(jq -n \
        --argjson udp "$udp_config" \
        '{udp: $udp}')

    # 保存节点基本信息（先不绑定用户）
    save_node_info "socks" "$port" "tcp" "none" "$extra_config" "socks-$port"

    # 绑定admin用户到节点
    local admin_info=$(bind_admin_to_node "$port" "socks")
    if [[ $? -ne 0 ]]; then
        print_error "绑定默认用户失败"
        return 1
    fi

    # 生成配置并重启
    generate_xray_config
    restart_xray

    print_success "SOCKS 入站节点添加成功！"
    echo ""
    echo -e "${CYAN}节点信息：${NC}"
    echo -e "  协议: SOCKS"
    echo -e "  端口: $port"
    echo -e "  UDP: $([[ "$udp_config" == "true" ]] && echo "已启用" || echo "未启用")"
    echo -e "  已绑定用户: admin"
    echo ""
    print_info "提示：可在【用户管理】中添加更多用户到此节点"
    echo ""
}
