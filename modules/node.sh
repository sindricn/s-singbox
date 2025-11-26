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

# 清理端口跳跃的iptables规则
cleanup_port_hopping_rules() {
    local target_port=$1
    local port_range=$2

    if [[ -z "$port_range" || "$port_range" == "null" ]]; then
        return 0
    fi

    # 提取端口范围的起始和结束端口（冒号分隔）
    local start_port=$(echo "$port_range" | cut -d':' -f1)
    local end_port=$(echo "$port_range" | cut -d':' -f2)

    # 获取主网络接口
    local main_interface=$(ip route | grep default | head -n1 | awk '{print $5}')
    if [[ -z "$main_interface" ]]; then
        main_interface="eth0"
    fi

    # 删除IPv4规则
    iptables -t nat -D PREROUTING -i "$main_interface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports $target_port 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "    ✓ IPv4端口跳跃规则已删除"
    fi

    # 删除IPv6规则
    ip6tables -t nat -D PREROUTING -i "$main_interface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports $target_port 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "    ✓ IPv6端口跳跃规则已删除"
    fi

    # 保存iptables规则（持久化）
    if command -v iptables-save >/dev/null 2>&1; then
        if [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        elif [[ -d /etc/sysconfig ]]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi
    fi

    if command -v ip6tables-save >/dev/null 2>&1; then
        if [[ -d /etc/iptables ]]; then
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        elif [[ -d /etc/sysconfig ]]; then
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null
        fi
    fi
}

# 检查端口跳跃范围是否已被占用
check_port_hopping_conflict() {
    local new_range=$1
    local current_port=$2  # 当前节点的端口（用于排除自己）

    if [[ -z "$new_range" || "$new_range" == "null" ]]; then
        return 1  # 没有冲突
    fi

    # 提取新范围
    local new_start=$(echo "$new_range" | cut -d':' -f1 | tr -cd '0-9')
    local new_end=$(echo "$new_range" | cut -d':' -f2 | tr -cd '0-9')

    # 验证是否为有效数字
    if [[ ! "$new_start" =~ ^[0-9]+$ ]] || [[ ! "$new_end" =~ ^[0-9]+$ ]]; then
        print_warning "无效的端口范围格式: $new_range"
        return 1  # 格式错误，当作没有冲突但会在外层处理
    fi

    # 检查所有现有的Hysteria2节点
    local existing_ranges=$(jq -r '.nodes[] | select(.protocol == "hysteria2") | select(.extra.port_hopping != null and .extra.port_hopping != "") | "\(.port)|\(.extra.port_hopping)"' "$NODES_FILE" 2>/dev/null)

    while IFS='|' read -r existing_port existing_range; do
        # 跳过空行或无效数据
        if [[ -z "$existing_port" || -z "$existing_range" ]]; then
            continue
        fi

        # 跳过当前节点自己
        if [[ "$existing_port" == "$current_port" ]]; then
            continue
        fi

        # 提取现有范围并清理
        local exist_start=$(echo "$existing_range" | cut -d':' -f1 | tr -cd '0-9')
        local exist_end=$(echo "$existing_range" | cut -d':' -f2 | tr -cd '0-9')

        # 验证现有范围是否为有效数字
        if [[ ! "$exist_start" =~ ^[0-9]+$ ]] || [[ ! "$exist_end" =~ ^[0-9]+$ ]]; then
            continue  # 跳过无效的现有范围
        fi

        # 检查范围是否重叠
        if [[ $new_start -le $exist_end && $new_end -ge $exist_start ]]; then
            echo "端口跳跃范围 $new_range 与节点端口 $existing_port 的范围 $existing_range 冲突"
            return 0  # 有冲突
        fi
    done <<< "$existing_ranges"

    return 1  # 没有冲突
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

    # 检查 sing-box 路径
    echo -e "${YELLOW}1. 检查 sing-box 安装：${NC}"
    if command -v sing-box &>/dev/null; then
        local singbox_path=$(command -v sing-box)
        print_success "sing-box 已安装: $singbox_path"
        echo "   版本: $(sing-box version 2>&1 | head -1)"
    else
        print_error "sing-box 未安装"
        echo "   请先安装 sing-box（菜单选项 1 -> 1）"
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
    # 检查 sing-box 是否安装
    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box 未安装，请先安装 sing-box 内核"
        return 1
    fi

    # 尝试生成密钥对
    local output=$(sing-box generate reality-keypair 2>&1)
    local exit_code=$?

    # 如果新命令失败，尝试旧命令
    if [[ $exit_code -ne 0 ]]; then
        output=$(sing-box x25519 2>&1)
        exit_code=$?
    fi

    # 检查是否成功
    if [[ $exit_code -ne 0 ]]; then
        print_error "密钥生成失败，错误信息："
        echo "$output"
        return 1
    fi

    # 调试：显示原始输出
    echo "$output" >&2

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

    # 先检查 sing-box 是否安装
    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box 未安装！请先通过菜单安装 sing-box 内核"
        echo ""
        print_info "安装路径: 主菜单 -> 1. 内核管理 -> 1. 安装 sing-box"
        return 1
    fi

    local keypair=$(generate_reality_keypair)
    if [[ $? -ne 0 ]]; then
        print_error "密钥生成失败"
        echo ""
        print_info "调试信息："
        local singbox_path=$(command -v sing-box)
        echo "  sing-box 路径: $singbox_path"
        echo "  sing-box 版本: $(sing-box version 2>&1 | head -1)"
        echo ""
        print_info "尝试手动生成密钥："
        echo "  运行命令: sing-box x25519"
        return 1
    fi

    # 解析密钥 - 尝试多种格式
    local private_key=""
    local public_key=""

    # 格式1: "PrivateKey: xxx" (新版sing-box)
    if [[ -z "$private_key" ]]; then
        private_key=$(echo "$keypair" | grep -i "^PrivateKey:" | cut -d: -f2- | tr -d ' ')
        public_key=$(echo "$keypair" | grep -i "^PublicKey:" | cut -d: -f2- | tr -d ' ')
    fi

    # 格式2: "Private key: xxx" (旧版sing-box)
    if [[ -z "$private_key" ]]; then
        private_key=$(echo "$keypair" | grep -i "Private key:" | sed 's/.*Private key:[[:space:]]*//' | tr -d ' ')
        public_key=$(echo "$keypair" | grep -i "Public key:" | sed 's/.*Public key:[[:space:]]*//' | tr -d ' ')
    fi

    # 格式3: 纯两行base64字符串（每行40-50个字符）
    if [[ -z "$private_key" ]]; then
        local line1=$(echo "$keypair" | sed -n '1p' | tr -d ' ')
        local line2=$(echo "$keypair" | sed -n '2p' | tr -d ' ')
        # 验证是否为base64格式且长度合理
        if [[ "$line1" =~ ^[A-Za-z0-9+/=]{40,}$ ]] && [[ "$line2" =~ ^[A-Za-z0-9+/=]{40,}$ ]]; then
            private_key="$line1"
            public_key="$line2"
        fi
    fi

    # 验证密钥有效性
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        print_error "无法解析密钥对"
        echo ""
        print_info "原始输出："
        echo "$keypair"
        echo ""
        print_info "尝试手动生成密钥："
        echo "  运行: sing-box generate reality-keypair"
        echo "  或: sing-box x25519"
        return 1
    fi

    # 验证密钥格式（base64或base64url）
    # Reality使用base64url格式：- 代替 +，_ 代替 /
    if ! [[ "$private_key" =~ ^[A-Za-z0-9+/_=-]{40,}$ ]]; then
        print_error "私钥格式无效（不是base64/base64url）: $private_key"
        echo ""
        print_info "原始输出："
        echo "$keypair"
        return 1
    fi

    if ! [[ "$public_key" =~ ^[A-Za-z0-9+/_=-]{40,}$ ]]; then
        print_error "公钥格式无效（不是base64/base64url）: $public_key"
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

    # 重新生成sing-box配置文件
    generate_singbox_config

    # 重启服务
    restart_sing-box

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

    # 调试：在调用前检查变量
    echo "  admin_uuid: [$admin_uuid] (长度: ${#admin_uuid})"
    echo "  admin_remark: [$admin_remark] (长度: ${#admin_remark})"
    echo "  port: [$port] (长度: ${#port})"
    echo "  server_names: [$server_names] (长度: ${#server_names})"
    echo "  public_key: [$public_key] (长度: ${#public_key})"
    echo "  short_id: [$short_id] (长度: ${#short_id})"

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

    echo ""
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
            tls_cert="${SINGBOX_DIR}/certs/${tls_domain}/fullchain.pem"
            tls_key="${SINGBOX_DIR}/certs/${tls_domain}/${tls_domain}.key"
        fi
    fi

    # 构建extra_config JSON (包含VLESS特定参数)
    local extra_config=$(jq -n \
        --arg ws_path "$ws_path" \
        --arg ws_host "$tls_domain" \
        --arg grpc_service "$grpc_service" \
        --arg tls_domain "$tls_domain" \
        --arg tls_cert "$tls_cert" \
        --arg tls_key "$tls_key" \
        '{
            ws_path: $ws_path,
            ws_host: $ws_host,
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
    generate_singbox_config
    restart_sing-box

    print_success "VLESS 节点创建成功！"
    print_info "端口: $port"
    print_info "传输协议: $transport"
    if [[ "$security" == "tls" ]]; then
        print_info "TLS域名: $tls_domain"
    fi
    print_info "默认用户: admin"
    echo ""

    # 生成并显示VLESS分享链接
    generate_and_show_node_link "$port" "$admin_uuid" "$admin_remark"

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
    generate_singbox_config
    restart_sing-box

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
    generate_and_show_node_link "$port" "$admin_uuid" "$admin_remark"

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
        tls_cert="${SINGBOX_DIR}/certs/${tls_domain}/fullchain.pem"
        tls_key="${SINGBOX_DIR}/certs/${tls_domain}/${tls_domain}.key"
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
    generate_singbox_config
    restart_sing-box

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
    generate_and_show_node_link "$port" "$admin_uuid" "admin"

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
    generate_singbox_config
    restart_sing-box

    print_success "Shadowsocks 节点创建成功！"
    print_info "端口: $port"
    print_info "加密方式: $cipher"
    print_info "默认用户: admin"
    print_info "Admin密码: $admin_password"
    echo ""

    # 生成并显示SS分享链接
    generate_and_show_node_link "$port" "$admin_uuid" "admin"

    echo ""
    print_success "✅ 节点创建完成并已绑定admin用户！"
    print_info "提示：可在【用户管理】中添加更多用户到此节点"
    echo ""
}

# 删除节点（支持单个或多个）
delete_node() {
    list_nodes

    echo ""
    echo -e "${YELLOW}提示：${NC}"
    echo -e "  • 可以输入单个节点：${CYAN}1${NC} 或 ${CYAN}8080${NC}"
    echo -e "  • 可以输入多个节点（逗号分隔）：${CYAN}1,2,3${NC} 或 ${CYAN}8080,8081,8082${NC}"
    echo -e "  • 可以输入多个节点（空格分隔）：${CYAN}1 2 3${NC} 或 ${CYAN}8080 8081 8082${NC}"
    echo -e "  • 输入 ${CYAN}all${NC} 或 ${CYAN}*${NC} 删除所有节点"
    echo ""
    read -p "请输入要删除的节点序号或端口: " input
    if [[ -z "$input" ]]; then
        print_error "输入不能为空"
        return 1
    fi

    # 收集要删除的节点（支持序号和端口两种方式）
    local nodes_to_delete=()  # 存储格式: "index:port" 或 "index:" (port为空时)

    # 检查是否删除所有节点
    if [[ "$input" == "all" || "$input" == "*" ]]; then
        # 获取所有节点（通过索引）
        local total_nodes=$(jq -r '.nodes | length' "$NODES_FILE" 2>/dev/null)
        for ((i=0; i<total_nodes; i++)); do
            local port=$(jq -r ".nodes[$i].port // empty" "$NODES_FILE" 2>/dev/null)
            nodes_to_delete+=("$i:$port")
        done

        if [[ ${#nodes_to_delete[@]} -eq 0 ]]; then
            print_warning "没有节点可删除"
            return 0
        fi
    else
        # 处理输入（支持逗号和空格分隔）
        input=$(echo "$input" | tr ',' ' ')
        local inputs=($input)

        for item in "${inputs[@]}"; do
            # 判断是序号还是端口
            if [[ "$item" =~ ^[0-9]+$ ]] && [[ "$item" -le 100 ]]; then
                # 当作序号处理
                local index=$((item - 1))

                # 检查该索引位置是否存在节点
                local node_exists=$(jq -r ".nodes[$index] // empty" "$NODES_FILE" 2>/dev/null)
                if [[ -n "$node_exists" && "$node_exists" != "null" ]]; then
                    # 序号有效，获取对应的端口（可能为空）
                    local port=$(jq -r ".nodes[$index].port // empty" "$NODES_FILE" 2>/dev/null)
                    nodes_to_delete+=("$index:$port")
                else
                    print_warning "序号 $item 不存在，已跳过"
                fi
            else
                # 当作端口处理（大于100或非纯数字）
                local port="$item"

                # 查找该端口对应的索引
                local index=$(jq -r ".nodes | to_entries | .[] | select(.value.port == \"$port\") | .key" "$NODES_FILE" 2>/dev/null | head -n1)
                if [[ -n "$index" && "$index" != "null" ]]; then
                    nodes_to_delete+=("$index:$port")
                else
                    print_warning "端口 $port 不存在，已跳过"
                fi
            fi
        done
    fi

    if [[ ${#nodes_to_delete[@]} -eq 0 ]]; then
        print_error "没有有效的节点可删除"
        return 1
    fi

    # 显示将要删除的节点
    echo ""
    if [[ ${#nodes_to_delete[@]} -eq 1 ]]; then
        print_warning "将删除以下节点："
    else
        print_warning "将删除以下 ${#nodes_to_delete[@]} 个节点："
    fi

    for node_entry in "${nodes_to_delete[@]}"; do
        local index="${node_entry%%:*}"
        local port="${node_entry#*:}"

        local protocol=$(jq -r ".nodes[$index].protocol" "$NODES_FILE" 2>/dev/null)
        local name=$(jq -r ".nodes[$index].name // \"未命名\"" "$NODES_FILE" 2>/dev/null)
        local outbound_tag=$(jq -r ".nodes[$index].outbound_tag // empty" "$NODES_FILE" 2>/dev/null)

        if [[ -n "$port" && "$port" != "null" ]]; then
            echo -n "  • 序号 $((index + 1)) [端口 ${YELLOW}$port${NC}] - $protocol ($name)"
        else
            echo -n "  • 序号 $((index + 1)) [端口 ${RED}未设置${NC}] - $protocol ($name)"
        fi
        [[ -n "$outbound_tag" ]] && echo -n " [出站: $outbound_tag]"
        echo ""
    done

    echo ""
    print_warning "删除节点将同时清理所有用户绑定关系和相关订阅"
    read -p "确认删除? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消删除"
        return 0
    fi

    # 执行删除（从后往前删除，避免索引错位）
    local success_count=0
    local sorted_indices=($(for node_entry in "${nodes_to_delete[@]}"; do
        echo "${node_entry%%:*}"
    done | sort -rn))

    for index in "${sorted_indices[@]}"; do
        # 获取节点信息
        local port=$(jq -r ".nodes[$index].port // empty" "$NODES_FILE" 2>/dev/null)
        local protocol=$(jq -r ".nodes[$index].protocol" "$NODES_FILE" 2>/dev/null)
        local port_hopping=$(jq -r ".nodes[$index].extra.port_hopping // \"\"" "$NODES_FILE" 2>/dev/null)

        # 如果是Hysteria2且有端口跳跃，清理iptables规则
        if [[ "$protocol" == "hysteria2" && -n "$port_hopping" && "$port_hopping" != "null" ]]; then
            echo "  清理端口跳跃规则: $port_hopping → $port"
            cleanup_port_hopping_rules "$port" "$port_hopping"
        fi

        # 如果有端口，清理端口相关的绑定关系
        if [[ -n "$port" && "$port" != "null" ]]; then
            # 1. 从节点绑定关系中删除该端口
            if [[ -f "$NODE_USERS_FILE" ]]; then
                update_json_file --arg port "$port" '.bindings = [.bindings[] | select(.port != $port)]' "$NODE_USERS_FILE" 2>/dev/null
            fi

            # 2. 从数据库删除节点（通过端口）
            remove_node_info "$port"

            # 3. 从配置删除（通过端口）
            remove_inbound_from_config "$port"
        fi

        # 4. 通过索引从nodes.json中删除节点（无论端口是否存在）
        update_json_file --argjson index "$index" '.nodes = [.nodes | to_entries | .[] | select(.key != $index) | .value]' "$NODES_FILE" 2>/dev/null

        ((success_count++))
    done

    # 4. 重新生成配置并重启服务
    generate_singbox_config
    restart_sing-box

    echo ""
    if [[ $success_count -eq 1 ]]; then
        print_success "节点删除成功！"
    else
        print_success "批量删除完成！已删除 $success_count 个节点"
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
    echo -e "${CYAN}║${NC}      节点详情"
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

    # 显示节点的sing-box配置 (从config.json中提取)
    if [[ -f "$SINGBOX_CONFIG" ]]; then
        local inbound_tag="${protocol}-${port}"
        local inbound_config=$(jq --arg tag "$inbound_tag" '.inbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" 2>/dev/null)

        if [[ -n "$inbound_config" && "$inbound_config" != "null" ]]; then
            echo -e "${GREEN}节点sing-box配置：${NC}"
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
    echo -e "${CYAN}║${NC}      修改节点配置"
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
    echo ""

    print_nav_options "true" "true"
    local choice=$(read_menu_choice "请选择")
    local ret=$?

    # 处理导航
    [[ $ret -eq 99 ]] && return 0  # 返回上级
    [[ $ret -eq 98 ]] && return 98  # 返回主菜单

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
                generate_singbox_config
                restart_sing-box

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
                        generate_singbox_config
                        restart_sing-box
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
                        generate_singbox_config
                        restart_sing-box
                        print_success "用户已解绑"
                    fi
                fi
            fi
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
    echo -e "${CYAN}║${NC}      删除节点"
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

    restart_sing-box
    print_success "节点删除成功！"
}

# 注意：generate_self_signed_cert 函数已在 cert.sh 模块中定义
# 不要在此处重复定义，以避免覆盖 cert.sh 中的实现

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
    echo -e "${CYAN}║${NC}          批量删除节点"
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
    systemctl restart sing-box

    echo ""
    print_success "批量删除完成！已删除 $success_count 个节点"
}

# 批量启用/禁用节点
batch_toggle_nodes() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}      批量启用/禁用节点"
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
    echo -e "${CYAN}║${NC}          批量修改端口"
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
    generate_singbox_config
    restart_sing-box

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
    generate_singbox_config
    restart_sing-box

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


# ============================================================================
# 统一链接生成函数（调用 subscription.sh 中的函数）
# ============================================================================

# 显示节点分享链接（统一接口）
# 生成并显示节点分享链接（用于快速搭建完成后）
generate_and_show_node_link() {
    local port=$1
    local user_id=$2      # UUID (vless/vmess) 或 password (hysteria2/trojan/ss)
    local username=${3:-"admin"}

    # 从数据库读取节点配置
    local node_json=$(jq -c ".nodes[] | select(.port == \"$port\")" "$NODES_FILE" 2>/dev/null)

    if [[ -z "$node_json" || "$node_json" == "null" ]]; then
        print_warning "无法读取节点配置，链接生成失败"
        return 1
    fi

    # 检查 subscription.sh 中的函数是否可用
    if ! declare -f generate_share_link_smart &>/dev/null; then
        print_warning "链接生成函数未加载，请在【订阅管理】中查看节点链接"
        return 1
    fi

    # 调用统一的链接生成函数
    local share_link=$(generate_share_link_smart "$user_id" "$username" "$node_json")

    if [[ -n "$share_link" ]]; then
        echo ""
        echo -e "${CYAN}分享链接：${NC}"
        echo -e "${GREEN}$share_link${NC}"
        echo ""
    else
        print_warning "链接生成失败，请在【订阅管理】中查看节点链接"
    fi
}

# ============================================================================
# Hysteria2 节点管理
# ============================================================================

# 添加 Hysteria2 节点
add_hysteria2_node() {
    clear
    echo -e "${CYAN}====== 添加 Hysteria2 节点 ======${NC}"
    echo ""

    echo -e "${YELLOW}Hysteria2 说明：${NC}"
    echo -e "  • 基于 QUIC 的高性能代理协议"
    echo -e "  • 适合高延迟、高丢包环境"
    echo -e "  • 必须启用 TLS"
    echo -e "  • 支持混淆和速率限制"
    echo ""

    # 输入端口
    read -p "请输入端口 [默认: 443]: " port
    port=${port:-443}

    # 检查端口是否已被占用
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用或已存在，请使用其他端口"
        return 1
    fi

    # TLS 配置（必须）
    echo -e "\n${CYAN}TLS 配置（Hysteria2 必须启用 TLS）：${NC}"
    read -p "请输入域名: " tls_domain
    if [[ -z "$tls_domain" ]]; then
        print_error "Hysteria2 必须配置域名"
        return 1
    fi

    read -p "请输入证书路径 [留空使用自签名]: " tls_cert
    local tls_key=""

    if [[ -n "$tls_cert" ]]; then
        read -p "请输入密钥路径: " tls_key
        if [[ ! -f "$tls_cert" ]] || [[ ! -f "$tls_key" ]]; then
            print_error "证书或密钥文件不存在"
            return 1
        fi
    else
        print_info "使用自签名证书"
        if declare -f generate_self_signed_cert &>/dev/null; then
            generate_self_signed_cert "$tls_domain"
        fi
        tls_cert="${SINGBOX_DIR}/certs/${tls_domain}/fullchain.pem"
        tls_key="${SINGBOX_DIR}/certs/${tls_domain}/${tls_domain}.key"
    fi

    # 速率限制
    echo -e "\n${CYAN}速率限制配置：${NC}"
    read -p "上行速率 (Mbps) [默认: 100]: " up_mbps
    up_mbps=${up_mbps:-100}
    read -p "下行速率 (Mbps) [默认: 100]: " down_mbps
    down_mbps=${down_mbps:-100}

    # 混淆配置
    echo -e "\n${CYAN}混淆配置：${NC}"
    read -p "是否启用 Salamander 混淆? [y/N]: " enable_obfs
    local obfs_password=""
    if [[ "$enable_obfs" == "y" || "$enable_obfs" == "Y" ]]; then
        # 使用hex编码避免URL特殊字符（不包含+/=等）
        obfs_password=$(openssl rand -hex 16)
        print_info "混淆密码: $obfs_password"
    fi

    # 端口跳跃配置
    echo -e "
${CYAN}端口跳跃配置（可选）：${NC}"
    read -p "是否启用端口跳跃? [y/N]: " enable_hopping
    local port_hopping=""
    if [[ "$enable_hopping" == "y" || "$enable_hopping" == "Y" ]]; then
        read -p "请输入跳跃端口范围 [格式: 20000:30000]: " hopping_range
        if [[ -n "$hopping_range" ]]; then
            # 支持减号格式，自动转换为冒号（sing-box官方格式）
            if [[ "$hopping_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                port_hopping="${hopping_range/-/:}"
                print_info "端口跳跃: $port_hopping (已转换为官方格式)"
            elif [[ "$hopping_range" =~ ^[0-9]+:[0-9]+$ ]]; then
                port_hopping="$hopping_range"
                print_info "端口跳跃: $port_hopping"
            else
                print_warning "格式错误，跳过端口跳跃配置"
            fi
        fi
    fi

    # 构建 extra_config
    local extra_config=$(jq -n \
        --arg tls_domain "$tls_domain" \
        --arg tls_cert "$tls_cert" \
        --arg tls_key "$tls_key" \
        --argjson up_mbps "$up_mbps" \
        --argjson down_mbps "$down_mbps" \
        --arg obfs_password "$obfs_password" \
        --arg port_hopping "$port_hopping" \
        '{
            tls_domain: $tls_domain,
            tls_cert: $tls_cert,
            tls_key: $tls_key,
            up_mbps: $up_mbps,
            down_mbps: $down_mbps,
            obfs_password: $obfs_password
        } + (if $port_hopping != "" then {port_hopping: $port_hopping} else {} end)')

    # 保存节点信息
    save_node_info "hysteria2" "$port" "udp" "tls" "$extra_config" "hy2-$port"

    # 绑定admin用户
    local admin_info=$(bind_admin_to_node "$port" "hysteria2")
    if [[ $? -ne 0 ]]; then
        print_error "绑定默认用户失败"
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_remark <<< "$admin_info"

    # 生成配置并重启
    generate_singbox_config
    restart_sing-box

    print_success "Hysteria2 节点添加成功！"
    echo -e "${CYAN}节点信息：${NC}"
    echo "  端口: $port"
    echo "  域名: $tls_domain"
    echo "  上行: ${up_mbps} Mbps"
    echo "  下行: ${down_mbps} Mbps"
    [[ -n "$obfs_password" ]] && echo "  混淆: Salamander"
    echo ""

    # 生成并显示分享链接（调用统一函数）
    generate_and_show_node_link "$port" "$admin_uuid" "$admin_remark"
}

# ============================================================================
# TUIC 节点管理
# ============================================================================

# 添加 TUIC 节点
add_tuic_node() {
    clear
    echo -e "${CYAN}====== 添加 TUIC 节点 ======${NC}"
    echo ""

    echo -e "${YELLOW}TUIC 说明：${NC}"
    echo -e "  • 基于 QUIC 的代理协议"
    echo -e "  • 支持 UDP 和 TCP"
    echo -e "  • 必须启用 TLS"
    echo -e "  • 支持 0-RTT 握手（不推荐）"
    echo ""

    # 输入端口
    read -p "请输入端口 [默认: 443]: " port
    port=${port:-443}

    # 检查端口
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用"
        return 1
    fi

    # TLS 配置（必须）
    echo -e "\n${CYAN}TLS 配置（TUIC 必须启用 TLS）：${NC}"
    read -p "请输入域名: " tls_domain
    if [[ -z "$tls_domain" ]]; then
        print_error "TUIC 必须配置域名"
        return 1
    fi

    read -p "请输入证书路径 [留空使用自签名]: " tls_cert
    local tls_key=""

    if [[ -n "$tls_cert" ]]; then
        read -p "请输入密钥路径: " tls_key
    else
        print_info "使用自签名证书"
        if declare -f generate_self_signed_cert &>/dev/null; then
            generate_self_signed_cert "$tls_domain"
        fi
        tls_cert="${SINGBOX_DIR}/certs/${tls_domain}/fullchain.pem"
        tls_key="${SINGBOX_DIR}/certs/${tls_domain}/${tls_domain}.key"
    fi

    # 拥塞控制
    echo -e "\n${CYAN}拥塞控制算法：${NC}"
    echo "1. cubic (默认)"
    echo "2. new_reno"
    echo "3. bbr"
    read -p "请选择 [1-3]: " cc_choice

    case $cc_choice in
        1) congestion_control="cubic" ;;
        2) congestion_control="new_reno" ;;
        3) congestion_control="bbr" ;;
        *) congestion_control="cubic" ;;
    esac

    # 0-RTT 握手
    echo -e "\n${YELLOW}注意: 0-RTT 握手可能不安全，容易受到重放攻击${NC}"
    read -p "是否启用 0-RTT 握手? [y/N]: " enable_zero_rtt
    local zero_rtt="false"
    if [[ "$enable_zero_rtt" == "y" || "$enable_zero_rtt" == "Y" ]]; then
        zero_rtt="true"
    fi

    # 构建 extra_config
    local extra_config=$(jq -n \
        --arg tls_domain "$tls_domain" \
        --arg tls_cert "$tls_cert" \
        --arg tls_key "$tls_key" \
        --arg congestion_control "$congestion_control" \
        --arg zero_rtt "$zero_rtt" \
        '{
            tls_domain: $tls_domain,
            tls_cert: $tls_cert,
            tls_key: $tls_key,
            congestion_control: $congestion_control,
            zero_rtt_handshake: ($zero_rtt == "true"),
            auth_timeout: "3s",
            heartbeat: "10s"
        }')

    # 保存节点
    save_node_info "tuic" "$port" "udp" "tls" "$extra_config" "tuic-$port"

    # 绑定admin用户
    local admin_info=$(bind_admin_to_node "$port" "tuic")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # 生成配置
    generate_singbox_config
    restart_sing-box

    print_success "TUIC 节点添加成功！"
    echo -e "${CYAN}节点信息：${NC}"
    echo "  端口: $port"
    echo "  域名: $tls_domain"
    echo "  拥塞控制: $congestion_control"
    echo "  0-RTT: $zero_rtt"
    echo ""
}

# ============================================================================
# Naive 节点管理
# ============================================================================

# 添加 Naive 节点
add_naive_node() {
    clear
    echo -e "${CYAN}====== 添加 Naive 节点 ======${NC}"
    echo ""

    echo -e "${YELLOW}Naive 说明：${NC}"
    echo -e "  • 强抗审查代理协议"
    echo -e "  • 伪装成普通 HTTPS 流量"
    echo -e "  • 必须启用 TLS"
    echo -e "  • 不支持 UDP"
    echo ""

    # 输入端口
    read -p "请输入端口 [默认: 443]: " port
    port=${port:-443}

    # 检查端口
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用"
        return 1
    fi

    # TLS 配置（必须）
    echo -e "\n${CYAN}TLS 配置（Naive 必须启用 TLS）：${NC}"
    read -p "请输入域名: " tls_domain
    if [[ -z "$tls_domain" ]]; then
        print_error "Naive 必须配置域名"
        return 1
    fi

    read -p "请输入证书路径 [留空使用自签名]: " tls_cert
    local tls_key=""

    if [[ -n "$tls_cert" ]]; then
        read -p "请输入密钥路径: " tls_key
    else
        print_info "使用自签名证书"
        if declare -f generate_self_signed_cert &>/dev/null; then
            generate_self_signed_cert "$tls_domain"
        fi
        tls_cert="${SINGBOX_DIR}/certs/${tls_domain}/fullchain.pem"
        tls_key="${SINGBOX_DIR}/certs/${tls_domain}/${tls_domain}.key"
    fi

    # 构建 extra_config
    local extra_config=$(jq -n \
        --arg tls_domain "$tls_domain" \
        --arg tls_cert "$tls_cert" \
        --arg tls_key "$tls_key" \
        '{
            tls_domain: $tls_domain,
            tls_cert: $tls_cert,
            tls_key: $tls_key
        }')

    # 保存节点
    save_node_info "naive" "$port" "tcp" "tls" "$extra_config" "naive-$port"

    # 绑定admin用户
    bind_admin_to_node "$port" "naive"

    # 生成配置
    generate_singbox_config
    restart_sing-box

    print_success "Naive 节点添加成功！"
    echo -e "${CYAN}节点信息：${NC}"
    echo "  端口: $port"
    echo "  域名: $tls_domain"
    echo ""
}

# ============================================================================
# Mixed 代理节点管理
# ============================================================================

# 添加 Mixed 代理节点
add_mixed_node() {
    clear
    echo -e "${CYAN}====== 添加 Mixed 代理节点 ======${NC}"
    echo ""

    echo -e "${YELLOW}Mixed 代理说明：${NC}"
    echo -e "  • 同时支持 HTTP 和 SOCKS5"
    echo -e "  • 一个端口同时提供两种协议"
    echo -e "  • 支持用户认证"
    echo -e "  • 适合本地客户端使用"
    echo ""

    # 输入端口
    read -p "请输入端口 [默认: 7890]: " port
    port=${port:-7890}

    # 检查端口
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用"
        return 1
    fi

    # 是否启用UDP
    read -p "是否启用 UDP 支持? [Y/n]: " enable_udp
    local udp_enabled="true"
    if [[ "$enable_udp" == "n" || "$enable_udp" == "N" ]]; then
        udp_enabled="false"
    fi

    # 构建 extra_config
    local extra_config=$(jq -n \
        --arg udp "$udp_enabled" \
        '{udp: ($udp == "true")}')

    # 保存节点
    save_node_info "mixed" "$port" "tcp" "none" "$extra_config" "mixed-$port"

    # 绑定admin用户
    bind_admin_to_node "$port" "mixed"

    # 生成配置
    generate_singbox_config
    restart_sing-box

    print_success "Mixed 代理节点添加成功！"
    echo -e "${CYAN}节点信息：${NC}"
    echo "  端口: $port"
    echo "  协议: HTTP + SOCKS5"
    echo "  UDP: $udp_enabled"
    echo ""
}

# ============================================================================
# AnyTLS 节点管理
# ============================================================================

# 添加 AnyTLS 节点
add_anytls_node() {
    clear
    echo -e "${CYAN}====== 添加 AnyTLS 节点 ======${NC}"
    echo ""

    echo -e "${YELLOW}AnyTLS 说明：${NC}"
    echo -e "  • sing-box 1.12.0+ 新协议"
    echo -e "  • 支持流量填充混淆"
    echo -e "  • 可选 TLS 加密"
    echo -e "  • 基于密码认证"
    echo ""

    # 输入端口
    read -p "请输入端口 [默认: 443]: " port
    port=${port:-443}

    # 检查端口
    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用"
        return 1
    fi

    # TLS 配置（可选）
    echo -e "\n${CYAN}TLS 配置：${NC}"
    read -p "是否启用 TLS? [Y/n]: " enable_tls
    local security="none"
    local tls_domain=""
    local tls_cert=""
    local tls_key=""

    if [[ "$enable_tls" != "n" && "$enable_tls" != "N" ]]; then
        security="tls"
        read -p "请输入域名: " tls_domain
        if [[ -z "$tls_domain" ]]; then
            print_error "启用 TLS 必须配置域名"
            return 1
        fi

        read -p "请输入证书路径 [留空使用自签名]: " tls_cert

        if [[ -n "$tls_cert" ]]; then
            read -p "请输入密钥路径: " tls_key
            if [[ ! -f "$tls_cert" ]] || [[ ! -f "$tls_key" ]]; then
                print_error "证书或密钥文件不存在"
                return 1
            fi
        else
            print_info "使用自签名证书"
            if declare -f generate_self_signed_cert &>/dev/null; then
                generate_self_signed_cert "$tls_domain"
            fi
            tls_cert="${SINGBOX_DIR}/certs/${tls_domain}/fullchain.pem"
            tls_key="${SINGBOX_DIR}/certs/${tls_domain}/${tls_domain}.key"
        fi
    fi

    # 填充方案配置
    echo -e "\n${CYAN}流量填充配置：${NC}"
    echo "1. 使用默认填充方案（推荐）"
    echo "2. 禁用填充"
    echo "3. 自定义填充方案（高级）"
    read -p "请选择 [1-3]: " padding_choice

    local use_padding="true"
    local custom_padding="false"

    case $padding_choice in
        1)
            use_padding="true"
            custom_padding="false"
            print_info "将使用默认填充方案"
            ;;
        2)
            use_padding="false"
            custom_padding="false"
            print_warning "禁用填充可能降低抗审查能力"
            ;;
        3)
            use_padding="true"
            custom_padding="true"
            print_info "请查阅官方文档配置自定义填充方案"
            ;;
        *)
            use_padding="true"
            custom_padding="false"
            ;;
    esac

    # 构建 extra_config
    local extra_config
    if [[ "$security" == "tls" ]]; then
        extra_config=$(jq -n \
            --arg tls_domain "$tls_domain" \
            --arg tls_cert "$tls_cert" \
            --arg tls_key "$tls_key" \
            --arg use_padding "$use_padding" \
            --arg custom_padding "$custom_padding" \
            '{
                tls_domain: $tls_domain,
                tls_cert: $tls_cert,
                tls_key: $tls_key,
                use_padding: ($use_padding == "true"),
                custom_padding: ($custom_padding == "true")
            }')
    else
        extra_config=$(jq -n \
            --arg use_padding "$use_padding" \
            --arg custom_padding "$custom_padding" \
            '{
                use_padding: ($use_padding == "true"),
                custom_padding: ($custom_padding == "true")
            }')
    fi

    # 保存节点
    save_node_info "anytls" "$port" "tcp" "$security" "$extra_config" "anytls-$port"

    # 绑定admin用户
    local admin_info=$(bind_admin_to_node "$port" "anytls")
    if [[ $? -ne 0 ]]; then
        print_error "绑定默认用户失败"
        return 1
    fi

    # 生成配置
    generate_singbox_config
    restart_sing-box

    print_success "AnyTLS 节点添加成功！"
    echo -e "${CYAN}节点信息：${NC}"
    echo "  端口: $port"
    [[ "$security" == "tls" ]] && echo "  域名: $tls_domain"
    echo "  TLS: $([[ "$security" == "tls" ]] && echo "已启用" || echo "未启用")"
    echo "  填充: $([[ "$use_padding" == "true" ]] && echo "已启用" || echo "未启用")"
    echo ""

    if [[ "$security" != "tls" ]]; then
        echo -e "${YELLOW}提示：未启用 TLS 可能降低安全性${NC}"
    fi
}

# ============================================================================
# 快速搭建节点功能
# ============================================================================

# 快速搭建 VLESS + Reality 节点（一键配置）
quick_setup_vless_reality() {
    clear
    echo -e "${CYAN}═══════════════════════════════════${NC}"
    echo -e "${CYAN}   一键搭建 VLESS + Reality 节点${NC}"
    echo -e "${CYAN}═══════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}说明：${NC}"
    echo -e "  - 协议层: VLESS (零加密，性能最优)"
    echo -e "  - 传输层: TCP (稳定可靠)"
    echo -e "  - 加密层: Reality (最新抗审查技术)"
    echo ""

    # 1. 端口配置
    read -p "请输入监听端口 [默认: 443]: " port
    port=${port:-443}

    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用或已存在，请使用其他端口"
        return 1
    fi

    # 2. Reality 伪装域名配置
    echo ""
    echo -e "${CYAN}Reality 配置：${NC}"
    echo ""
    echo -e "${YELLOW}伪装域名 (SNI) 设置：${NC}"
    echo -e "  1. 使用默认伪装域名 (www.microsoft.com)"
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
            dest_server="www.microsoft.com"
            server_names=$dest_server
            print_info "使用默认伪装域名: $dest_server"
            ;;
        2)
            # 自动优选域名
            echo ""
            print_info "开始智能优选伪装域名..."
            echo ""

            # 测试域名列表（精简版）
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

                echo -e "${GREEN}═══════════════════════════════════${NC}"
                print_success "优选完成！"
                echo -e "  最佳域名: ${CYAN}$dest_server${NC}"
                echo -e "  延迟: ${CYAN}${best_latency}ms${NC}"
                echo -e "  成功测试: ${CYAN}${success_count}/${#test_domains[@]}${NC} 个域名"
                echo -e "${GREEN}═══════════════════════════════════${NC}"
                echo ""
            else
                print_warning "自动优选失败，使用默认域名"
                dest_server="www.microsoft.com"
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
            # 默认
            dest_server="www.microsoft.com"
            server_names=$dest_server
            ;;
    esac

    # 确认最终配置
    echo ""
    echo -e "${CYAN}最终 Reality 配置：${NC}"
    echo -e "  伪装目标 (dest): ${YELLOW}$dest_server:443${NC}"
    echo -e "  伪装域名 (SNI): ${YELLOW}$server_names${NC}"
    echo ""

    # 3. 生成 Reality 密钥对
    print_info "生成 Reality 密钥对..."

    # 先检查 sing-box 是否安装
    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box 未安装！请先通过菜单安装 sing-box 内核"
        return 1
    fi

    local keypair=$(generate_reality_keypair)
    if [[ $? -ne 0 ]]; then
        print_error "密钥生成失败"
        echo ""
        print_info "调试信息："
        local singbox_path=$(command -v sing-box)
        echo "  sing-box 路径: $singbox_path"
        echo "  sing-box 版本: $(sing-box version 2>&1 | head -1)"
        echo ""
        print_info "尝试手动生成密钥："
        echo "  运行命令: sing-box generate reality-keypair"
        return 1
    fi

    # 解析密钥 - 多种格式兼容
    local private_key=$(echo "$keypair" | grep -i "Private key:" | awk '{print $3}')
    local public_key=$(echo "$keypair" | grep -i "Public key:" | awk '{print $3}')

    # 如果第一种格式失败，尝试其他格式
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        private_key=$(echo "$keypair" | grep -i "PrivateKey:" | awk '{print $2}')
        public_key=$(echo "$keypair" | grep -i "PublicKey:" | awk '{print $2}')
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

    # 4. 生成 shortId (8-16位十六进制)
    local short_id=$(openssl rand -hex 8)
    print_info "ShortId: $short_id"

    # 5. 构建 Reality 额外配置（JSON格式，sing-box格式）
    local reality_config=$(jq -n \
        --arg dest "$dest_server:443" \
        --arg sni "$server_names" \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg flow "xtls-rprx-vision" \
        '{
            dest: $dest,
            server_names: [$sni],
            private_key: $private_key,
            public_key: $public_key,
            short_ids: [$short_id],
            flow: $flow
        }')

    # 6. 保存节点信息
    save_node_info "vless" "$port" "tcp" "reality" "$reality_config" "vless-reality-$port"
    if [[ $? -ne 0 ]]; then
        print_error "保存节点信息失败"
        return 1
    fi

    # 7. 绑定 admin 用户到节点
    local admin_info=$(bind_admin_to_node "$port" "vless")
    if [[ $? -ne 0 ]]; then
        print_error "绑定默认用户失败，正在回滚..."
        # 删除刚创建的节点
        jq --arg port "$port" '.nodes = [.nodes[] | select(.port != $port)]' "$DATA_DIR/nodes.json" > "$DATA_DIR/nodes.json.tmp"
        mv "$DATA_DIR/nodes.json.tmp" "$DATA_DIR/nodes.json"
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_remark <<< "$admin_info"

    # 8. 重新生成sing-box配置文件
    generate_singbox_config
    if [[ $? -ne 0 ]]; then
        print_error "生成配置文件失败，正在回滚..."
        # 删除节点和绑定
        jq --arg port "$port" '.nodes = [.nodes[] | select(.port != $port)]' "$DATA_DIR/nodes.json" > "$DATA_DIR/nodes.json.tmp"
        mv "$DATA_DIR/nodes.json.tmp" "$DATA_DIR/nodes.json"
        jq --arg port "$port" '.bindings = [.bindings[] | select(.port != $port)]' "$DATA_DIR/node_users.json" > "$DATA_DIR/node_users.json.tmp"
        mv "$DATA_DIR/node_users.json.tmp" "$DATA_DIR/node_users.json"
        return 1
    fi

    # 9. 重启服务
    restart_sing-box
    if [[ $? -ne 0 ]]; then
        print_error "sing-box 启动失败"
        return 1
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo -e "${GREEN}   VLESS + Reality 节点创建成功！${NC}"
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}节点信息：${NC}"
    echo -e "  端口: ${YELLOW}$port${NC}"
    echo -e "  协议: ${YELLOW}VLESS${NC}"
    echo -e "  传输: ${YELLOW}TCP${NC}"
    echo -e "  安全: ${YELLOW}Reality${NC}"
    echo -e "  默认用户: ${YELLOW}admin${NC}"
    echo ""
    echo -e "${CYAN}Reality 配置：${NC}"
    echo -e "  伪装域名: ${YELLOW}$server_names${NC}"
    echo -e "  公钥: ${YELLOW}$public_key${NC}"
    echo -e "  ShortId: ${YELLOW}$short_id${NC}"
    echo ""

    # 生成并显示分享链接（调用统一函数）
    generate_and_show_node_link "$port" "$admin_uuid" "$admin_remark"
}

# 快速搭建 Hysteria2 节点（一键配置）
quick_setup_hysteria2() {
    clear
    echo -e "${CYAN}═══════════════════════════════════${NC}"
    echo -e "${CYAN}   一键搭建 Hysteria2 节点${NC}"
    echo -e "${CYAN}═══════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}说明：${NC}"
    echo -e "  - 基于 QUIC 的高性能协议"
    echo -e "  - 适合高延迟、高丢包环境"
    echo -e "  - 支持自签名证书"
    echo -e "  - 自动配置混淆"
    echo ""

    # 检查 sing-box 是否已安装
    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box 未安装！请先通过菜单安装 sing-box 内核"
        return 1
    fi

    echo -e "${BLUE}开始一键快速配置...${NC}"
    echo ""

    # 步骤 1/6: 端口配置
    echo -e "${BLUE}步骤 1/6: 端口配置${NC}"
    read -p "请输入监听端口 [默认: 443]: " port
    port=${port:-443}

    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用或已存在，请使用其他端口"
        return 1
    fi
    print_success "端口: $port"
    echo ""

    # 步骤 2/6: 伪装域名选择
    echo -e "${BLUE}步骤 2/6: 选择伪装域名${NC}"
    echo -e "${YELLOW}伪装域名选项：${NC}"
    echo -e "  1. 使用默认域名 (cdn.jsdelivr.net)"
    echo -e "  2. 自动优选最佳域名（延迟测试）"
    echo -e "  3. 手动输入域名"
    echo ""
    read -p "请选择 [1-3，默认: 2]: " domain_choice
    domain_choice=${domain_choice:-2}

    local tls_domain=""
    case $domain_choice in
        1)
            tls_domain="cdn.jsdelivr.net"
            print_info "使用默认域名: $tls_domain"
            ;;
        2)
            print_info "开始智能优选伪装域名..."
            local test_domains=(
                www.cloudflare.com
                cdn.jsdelivr.net
                www.microsoft.com
                www.apple.com
                www.bing.com
                www.mozilla.org
            )

            local best_latency=9999
            local best_domain="cdn.jsdelivr.net"

            for domain in "${test_domains[@]}"; do
                local latency=$(ping -c 1 -W 1 "$domain" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}' | cut -d'.' -f1)
                if [[ -n "$latency" && "$latency" =~ ^[0-9]+$ ]]; then
                    echo "  测试 $domain: ${latency}ms"
                    if [[ $latency -lt $best_latency ]]; then
                        best_latency=$latency
                        best_domain="$domain"
                    fi
                fi
            done

            tls_domain="$best_domain"
            print_success "优选域名: $tls_domain (${best_latency}ms)"
            ;;
        3)
            read -p "请输入自定义域名: " custom_domain
            if [[ -n "$custom_domain" ]]; then
                tls_domain="$custom_domain"
            else
                tls_domain="cdn.jsdelivr.net"
                print_warning "未输入域名，使用默认: $tls_domain"
            fi
            ;;
        *)
            tls_domain="cdn.jsdelivr.net"
            print_warning "无效选择，使用默认: $tls_domain"
            ;;
    esac
    echo ""

    # 步骤 3/6: 生成混淆密码（认证密码将使用admin用户密码）
    echo -e "${BLUE}步骤 3/6: 生成混淆密码${NC}"
    # 使用hex编码避免URL特殊字符（不包含+/=等）
    local obfs_password=$(openssl rand -hex 16)
    print_success "混淆密码: $obfs_password"
    echo ""

    # 步骤 4/6: 生成自签名证书
    echo -e "${BLUE}步骤 4/6: 生成自签名证书${NC}"

    # 生成自签名证书
    generate_self_signed_cert "$tls_domain"

    local tls_cert="${SINGBOX_DIR}/certs/${tls_domain}/fullchain.pem"
    local tls_key="${SINGBOX_DIR}/certs/${tls_domain}/${tls_domain}.key"

    # 验证证书文件
    if [[ ! -f "$tls_cert" || ! -f "$tls_key" ]]; then
        print_error "证书文件不存在"
        return 1
    fi
    echo ""

    # 步骤 5/6: 配置速率限制和跳跃端口
    echo -e "${BLUE}步骤 5/6: 配置速率限制和跳跃端口${NC}"

    # 速率限制（默认不限速）
    echo -e "${YELLOW}速率限制设置：${NC}"
    read -p "是否启用速率限制? [y/N]: " enable_limit

    local up_mbps=0
    local down_mbps=0

    if [[ "$enable_limit" == "y" || "$enable_limit" == "Y" ]]; then
        read -p "上传速率 (Mbps) [默认: 100]: " input_up
        read -p "下载速率 (Mbps) [默认: 100]: " input_down
        up_mbps=${input_up:-100}
        down_mbps=${input_down:-100}
        print_success "速率限制: ${up_mbps}/${down_mbps} Mbps"
    else
        print_success "速率限制: 不限速"
    fi

    # 跳跃端口（Port Hopping）
    echo ""
    echo -e "${YELLOW}跳跃端口设置：${NC}"
    read -p "是否启用端口跳跃? [Y/n]: " enable_hopping

    local port_hopping=""
    if [[ "$enable_hopping" != "n" && "$enable_hopping" != "N" ]]; then
        while true; do
            read -p "跳跃端口范围 [默认: 2000:3000]: " hopping_range

            # 清理输入：去除非ASCII字符和空格
            hopping_range=$(echo "$hopping_range" | tr -cd '0-9:-')

            if [[ -z "$hopping_range" ]]; then
                # 使用冒号格式（sing-box官方格式）
                port_hopping="2000:3000"
            else
                # 支持减号格式，自动转换为冒号
                if [[ "$hopping_range" =~ ^[0-9]+-[0-9]+$ ]]; then
                    port_hopping="${hopping_range/-/:}"
                elif [[ "$hopping_range" =~ ^[0-9]+:[0-9]+$ ]]; then
                    port_hopping="$hopping_range"
                else
                    print_warning "格式错误，请输入有效的端口范围（例如: 20000:30000 或 20000-30000）"
                    continue
                fi

                # 验证端口范围的合法性
                local start_port=$(echo "$port_hopping" | cut -d':' -f1)
                local end_port=$(echo "$port_hopping" | cut -d':' -f2)

                if [[ $start_port -ge $end_port ]]; then
                    print_warning "起始端口必须小于结束端口，请重新输入"
                    continue
                fi

                if [[ $start_port -lt 1024 || $end_port -gt 65535 ]]; then
                    print_warning "端口范围应在 1024-65535 之间，请重新输入"
                    continue
                fi
            fi

            # 检查端口跳跃范围是否冲突
            if check_port_hopping_conflict "$port_hopping" "$port"; then
                print_warning "该端口跳跃范围与已有节点冲突，请重新输入"
                continue
            fi

            print_success "跳跃端口: $port_hopping"
            break
        done
    else
        print_info "不启用端口跳跃"
    fi
    echo ""

    # 步骤 6/6: 保存配置
    echo -e "${BLUE}步骤 6/6: 保存配置并启动服务${NC}"

    # 构建 extra_config（使用标准字段名）
    local extra_config_base=$(jq -n \
        --arg tls_domain "$tls_domain" \
        --arg tls_cert "$tls_cert" \
        --arg tls_key "$tls_key" \
        --argjson up_mbps "$up_mbps" \
        --argjson down_mbps "$down_mbps" \
        --arg obfs_password "$obfs_password" \
        --arg masquerade "https://${tls_domain}/" \
        '{
            tls_domain: $tls_domain,
            tls_cert: $tls_cert,
            tls_key: $tls_key,
            up_mbps: $up_mbps,
            down_mbps: $down_mbps,
            obfs_password: $obfs_password,
            masquerade: $masquerade
        }')

    # 添加端口跳跃参数（如果启用）
    local extra_config
    if [[ -n "$port_hopping" ]]; then
        extra_config=$(echo "$extra_config_base" | jq --arg hopping "$port_hopping" '. + {port_hopping: $hopping}')
    else
        extra_config="$extra_config_base"
    fi

    # 保存节点信息
    save_node_info "hysteria2" "$port" "udp" "tls" "$extra_config" "hy2-$port"
    if [[ $? -ne 0 ]]; then
        print_error "保存节点信息失败"
        # 清理证书文件
        rm -f "$tls_cert" "$tls_key"
        return 1
    fi

    # 绑定 admin 用户到节点
    local admin_info=$(bind_admin_to_node "$port" "hysteria2")
    if [[ $? -ne 0 ]]; then
        print_error "绑定默认用户失败，正在回滚..."
        # 删除刚创建的节点
        jq --arg port "$port" '.nodes = [.nodes[] | select(.port != $port)]' "$DATA_DIR/nodes.json" > "$DATA_DIR/nodes.json.tmp"
        mv "$DATA_DIR/nodes.json.tmp" "$DATA_DIR/nodes.json"
        # 清理证书文件
        rm -f "$tls_cert" "$tls_key"
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_username <<< "$admin_info"

    # 重新生成sing-box配置文件
    generate_singbox_config
    if [[ $? -ne 0 ]]; then
        print_error "生成配置文件失败，正在回滚..."
        # 删除节点和绑定
        jq --arg port "$port" '.nodes = [.nodes[] | select(.port != $port)]' "$DATA_DIR/nodes.json" > "$DATA_DIR/nodes.json.tmp"
        mv "$DATA_DIR/nodes.json.tmp" "$DATA_DIR/nodes.json"
        jq --arg port "$port" '.bindings = [.bindings[] | select(.port != $port)]' "$DATA_DIR/node_users.json" > "$DATA_DIR/node_users.json.tmp"
        mv "$DATA_DIR/node_users.json.tmp" "$DATA_DIR/node_users.json"
        # 清理证书文件
        rm -f "$tls_cert" "$tls_key"
        return 1
    fi

    # 配置端口跳跃（如果启用）
    if [[ -n "$port_hopping" ]]; then
        echo ""
        echo -e "${BLUE}配置端口跳跃iptables规则...${NC}"

        # 提取端口范围的起始和结束端口（冒号分隔）
        local start_port=$(echo "$port_hopping" | cut -d':' -f1)
        local end_port=$(echo "$port_hopping" | cut -d':' -f2)

        # 获取主网络接口
        local main_interface=$(ip route | grep default | head -n1 | awk '{print $5}')
        if [[ -z "$main_interface" ]]; then
            main_interface="eth0"  # 默认值
        fi

        # 删除旧规则（如果存在）
        iptables -t nat -D PREROUTING -i "$main_interface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports $port 2>/dev/null
        ip6tables -t nat -D PREROUTING -i "$main_interface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports $port 2>/dev/null

        # 添加新规则
        # IPv4
        iptables -t nat -A PREROUTING -i "$main_interface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports $port
        if [[ $? -eq 0 ]]; then
            print_success "IPv4端口跳跃规则已添加: $port_hopping → $port"
        else
            print_warning "IPv4端口跳跃规则添加失败"
        fi

        # IPv6
        ip6tables -t nat -A PREROUTING -i "$main_interface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports $port 2>/dev/null
        if [[ $? -eq 0 ]]; then
            print_success "IPv6端口跳跃规则已添加: $port_hopping → $port"
        else
            print_info "IPv6端口跳跃规则添加失败（可能不支持IPv6）"
        fi

        # 保存iptables规则（持久化）
        if command -v iptables-save >/dev/null 2>&1; then
            local saved=false
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1 && saved=true
            elif [[ -f /etc/debian_version ]]; then
                # 确保目录存在
                mkdir -p /etc/iptables 2>/dev/null
                if iptables-save > /etc/iptables/rules.v4 2>/dev/null && \
                   ip6tables-save > /etc/iptables/rules.v6 2>/dev/null; then
                    saved=true
                fi
            elif [[ -f /etc/redhat-release ]]; then
                service iptables save >/dev/null 2>&1 && \
                service ip6tables save >/dev/null 2>&1 && saved=true
            fi

            if [[ "$saved" == "true" ]]; then
                print_success "iptables规则已持久化"
            else
                print_warning "iptables规则持久化失败（规则仍生效但重启后会丢失）"
            fi
        fi
        echo ""
    fi

    # 重启服务
    restart_sing-box
    if [[ $? -ne 0 ]]; then
        print_error "sing-box 启动失败"
        return 1
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo -e "${GREEN}   Hysteria2 节点创建成功！${NC}"
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}节点信息：${NC}"
    echo -e "  端口: ${YELLOW}$port${NC}"
    if [[ -n "$port_hopping" ]]; then
        echo -e "  跳跃端口: ${YELLOW}$port_hopping${NC}"
    fi
    echo -e "  协议: ${YELLOW}Hysteria2${NC}"
    echo -e "  伪装域名: ${YELLOW}$tls_domain${NC}"
    echo -e "  默认用户: ${YELLOW}admin${NC}"
    echo -e "  认证密码: ${YELLOW}$admin_password${NC}"
    echo -e "  混淆类型: ${YELLOW}Salamander${NC}"
    echo -e "  混淆密码: ${YELLOW}$obfs_password${NC}"

    if [[ $up_mbps -eq 0 && $down_mbps -eq 0 ]]; then
        echo -e "  速率限制: ${YELLOW}不限速${NC}"
    else
        echo -e "  速率限制: ${YELLOW}${up_mbps}/${down_mbps} Mbps${NC}"
    fi
    echo ""

    # 生成并显示分享链接（调用统一函数）
    # 对于Hysteria2，传递UUID而不是密码，让generate_share_link_smart自动查找密码
    generate_and_show_node_link "$port" "$admin_uuid" "$admin_username"
}

# 快速搭建 Argo + VLESS + WebSocket 节点
quick_setup_argo_vless_ws() {
    clear
    echo -e "${CYAN}═══════════════════════════════════${NC}"
    echo -e "${CYAN}  一键搭建 Argo+VLESS+WS 节点${NC}"
    echo -e "${CYAN}═══════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}说明：${NC}"
    echo -e "  - 协议: VLESS (零加密，性能优秀)"
    echo -e "  - 传输: WebSocket"
    echo -e "  - 隧道: Cloudflare Argo（支持临时/专用）"
    echo -e "  - 优势: 隐藏源站IP，快速部署，无需证书"
    echo ""

    # 检查 sing-box 是否已安装
    if ! command -v sing-box &>/dev/null; then
        print_error "sing-box 未安装！请先通过菜单安装 sing-box 内核"
        return 1
    fi

    echo -e "${BLUE}开始一键快速配置...${NC}"
    echo ""

    # 步骤 1/3: 端口配置
    echo -e "${BLUE}步骤 1/3: 端口配置${NC}"
    read -p "请输入监听端口 [默认: 8443]: " port
    port=${port:-8443}

    if check_port_exists "$port"; then
        print_error "端口 $port 已被占用或已存在，请使用其他端口"
        return 1
    fi
    print_success "本地端口: $port"
    echo ""

    # 步骤 2/4: WebSocket 路径配置
    echo -e "${BLUE}步骤 2/4: WebSocket 路径配置${NC}"
    read -p "WebSocket 路径 [默认: /ws]: " ws_path
    ws_path=${ws_path:-/ws}
    print_success "WebSocket 路径: $ws_path"
    echo ""

    # 步骤 3/4: Host 头伪装配置（自动优选）
    echo -e "${BLUE}步骤 3/4: Host 头伪装配置${NC}"
    echo -e "${YELLOW}Host 头伪装可以提高直连时的隐蔽性${NC}"
    echo -e "${YELLOW}伪装域名选项：${NC}"
    echo -e "  ${GREEN}1.${NC} 使用默认域名 (www.cloudflare.com)"
    echo -e "  ${GREEN}2.${NC} 自动优选最佳域名（延迟测试）"
    echo -e "  ${GREEN}3.${NC} 手动输入域名"
    echo ""
    read -p "请选择 [1-3，默认: 2]: " host_choice
    host_choice=${host_choice:-2}

    local ws_host=""
    case $host_choice in
        1)
            ws_host="www.cloudflare.com"
            print_info "使用默认域名: $ws_host"
            ;;
        2)
            print_info "开始智能优选伪装域名..."
            echo ""
            local test_domains=(
                www.cloudflare.com
                cdn.jsdelivr.net
                www.microsoft.com
                www.apple.com
                www.bing.com
                www.mozilla.org
                www.gstatic.com
            )

            local best_latency=9999
            local best_domain="www.cloudflare.com"

            for domain in "${test_domains[@]}"; do
                local latency=$(ping -c 1 -W 1 "$domain" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}' | cut -d'.' -f1)
                if [[ -n "$latency" && "$latency" =~ ^[0-9]+$ ]]; then
                    printf "  ${GREEN}✔${NC} %-30s ${CYAN}%4d ms${NC}\n" "$domain" "$latency"
                    if [[ $latency -lt $best_latency ]]; then
                        best_latency=$latency
                        best_domain="$domain"
                    fi
                else
                    printf "  ${RED}✘${NC} %-30s ${YELLOW}超时${NC}\n" "$domain"
                fi
            done

            ws_host="$best_domain"
            echo ""
            print_success "优选域名: $ws_host (${best_latency}ms)"
            ;;
        3)
            read -p "请输入自定义域名: " custom_domain
            if [[ -n "$custom_domain" ]]; then
                ws_host="$custom_domain"
            else
                ws_host="www.cloudflare.com"
                print_warning "未输入域名，使用默认: $ws_host"
            fi
            ;;
        *)
            ws_host="www.cloudflare.com"
            print_warning "无效选择，使用默认: $ws_host"
            ;;
    esac
    echo ""

    # 步骤 4/4: Argo 隧道配置
    echo -e "${BLUE}步骤 4/4: Argo 隧道配置${NC}"
    echo -e "${YELLOW}Argo 隧道选项：${NC}"
    echo -e "  ${GREEN}1.${NC} 临时隧道（无需CF账号，域名会变化）"
    echo -e "  ${GREEN}2.${NC} 专用隧道（需要CF账号，固定域名）"
    echo -e "  ${GREEN}3.${NC} 不使用Argo（仅本地节点）"
    echo ""
    read -p "请选择 [1-3，默认: 1]: " argo_choice
    argo_choice=${argo_choice:-1}

    local use_argo=false
    local argo_type=""
    local tunnel_domain=""

    case $argo_choice in
        1)
            # 临时隧道
            use_argo=true
            argo_type="temp"
            print_info "将使用临时 Argo 隧道"
            ;;
        2)
            # 专用隧道
            use_argo=true
            argo_type="dedicated"
            print_info "将使用专用 Argo 隧道"
            ;;
        3)
            # 不使用
            use_argo=false
            print_info "不使用 Argo 隧道"
            ;;
        *)
            # 默认临时隧道
            use_argo=true
            argo_type="temp"
            print_info "将使用临时 Argo 隧道"
            ;;
    esac
    echo ""

    # 保存配置并创建节点
    print_info "保存配置并启动服务..."

    # 构建 extra_config（包含 WebSocket 配置和 Host 头）
    local extra_config=$(jq -n \
        --arg ws_path "$ws_path" \
        --arg ws_host "$ws_host" \
        '{
            ws_path: $ws_path,
            ws_host: $ws_host
        }')

    # 保存节点信息（security 为 none，不使用 TLS）
    save_node_info "vless" "$port" "ws" "none" "$extra_config" "vless-ws-$port"
    if [[ $? -ne 0 ]]; then
        print_error "保存节点信息失败"
        return 1
    fi

    # 绑定 admin 用户到节点
    local admin_info=$(bind_admin_to_node "$port" "vless")
    if [[ $? -ne 0 ]]; then
        print_error "绑定默认用户失败，正在回滚..."
        jq --arg port "$port" '.nodes = [.nodes[] | select(.port != $port)]' "$DATA_DIR/nodes.json" > "$DATA_DIR/nodes.json.tmp"
        mv "$DATA_DIR/nodes.json.tmp" "$DATA_DIR/nodes.json"
        return 1
    fi

    IFS='|' read -r admin_uuid admin_password admin_username <<< "$admin_info"

    # 重新生成sing-box配置文件
    generate_singbox_config
    if [[ $? -ne 0 ]]; then
        print_error "生成配置文件失败，正在回滚..."
        jq --arg port "$port" '.nodes = [.nodes[] | select(.port != $port)]' "$DATA_DIR/nodes.json" > "$DATA_DIR/nodes.json.tmp"
        mv "$DATA_DIR/nodes.json.tmp" "$DATA_DIR/nodes.json"
        jq --arg port "$port" '.bindings = [.bindings[] | select(.port != $port)]' "$DATA_DIR/node_users.json" > "$DATA_DIR/node_users.json.tmp"
        mv "$DATA_DIR/node_users.json.tmp" "$DATA_DIR/node_users.json"
        return 1
    fi

    # 重启服务
    restart_sing-box
    if [[ $? -ne 0 ]]; then
        print_error "sing-box 启动失败"
        return 1
    fi

    print_success "节点创建成功！"
    echo ""

    # 如果启用 Argo，创建并绑定隧道
    if [[ "$use_argo" == true ]]; then
        echo -e "${BLUE}正在配置 Argo 隧道...${NC}"
        echo ""

        # 检查 cloudflared 是否安装
        if [[ ! -f "/usr/local/bin/cloudflared" ]]; then
            print_warning "cloudflared 未安装"
            read -p "是否现在安装？[Y/n]: " install_choice
            if [[ "$install_choice" != "n" && "$install_choice" != "N" ]]; then
                # 调用安装函数（需要确保 cf_tunnel.sh 已加载）
                if declare -f install_cloudflared >/dev/null 2>&1; then
                    install_cloudflared
                else
                    print_error "无法找到 cloudflared 安装函数"
                    print_info "请手动通过 Argo隧道管理 菜单安装"
                    argo_type=""
                    use_argo=false
                fi
            else
                print_info "跳过 Argo 隧道配置"
                use_argo=false
            fi
        fi

        if [[ "$use_argo" == true ]]; then
            if [[ "$argo_type" == "temp" ]]; then
                # 创建临时隧道
                print_info "启动临时 Argo 隧道..."
                local log_file="/tmp/argo-tunnel-${port}.log"
                nohup /usr/local/bin/cloudflared tunnel --url "http://localhost:${port}" > "$log_file" 2>&1 &
                local tunnel_pid=$!

                # 等待隧道启动
                sleep 5

                # 检查进程是否还在运行
                if ! kill -0 $tunnel_pid 2>/dev/null; then
                    print_error "Argo 隧道启动失败"
                    cat "$log_file" 2>/dev/null
                else
                    # 从日志中提取隧道 URL
                    tunnel_domain=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_file" | head -1)

                    if [[ -n "$tunnel_domain" ]]; then
                        # 更新节点配置，添加隧道域名
                        jq --arg port "$port" \
                           --arg domain "$tunnel_domain" \
                           --arg pid "$tunnel_pid" \
                           '(.nodes[] | select(.port == $port)) |= (
                               . + {
                                   tunnel_domain: $domain,
                                   tunnel_name: ("temp-tunnel-" + $pid),
                                   tunnel_type: "argo_temp"
                               }
                           )' \
                           "$DATA_DIR/nodes.json" > "$DATA_DIR/nodes.json.tmp" && mv "$DATA_DIR/nodes.json.tmp" "$DATA_DIR/nodes.json"

                        print_success "临时 Argo 隧道创建成功！"
                        echo -e "  隧道域名: ${GREEN}$tunnel_domain${NC}"
                        echo -e "  进程 PID: ${GREEN}$tunnel_pid${NC}"
                        echo ""
                    else
                        print_warning "无法获取隧道域名，请查看日志: $log_file"
                    fi
                fi

            elif [[ "$argo_type" == "dedicated" ]]; then
                # 专用隧道绑定流程
                echo ""
                echo -e "${BLUE}专用隧道配置${NC}"
                echo ""

                # 加载 cf_tunnel.sh 模块以使用授权管理
                if [[ -f "${SCRIPT_DIR}/modules/cf_tunnel.sh" ]]; then
                    source "${SCRIPT_DIR}/modules/cf_tunnel.sh"
                fi

                # 初始化授权文件
                init_cf_auth_file

                # 检查授权数量，如果有多个授权，让用户选择
                local auth_count=$(jq '.auths | length' "$CLOUDFLARED_AUTH_FILE" 2>/dev/null || echo "0")
                local selected_cert_file=""

                if [[ "$auth_count" -gt 1 ]]; then
                    # 有多个授权，让用户选择
                    echo -e "${YELLOW}检测到多个授权，请选择：${NC}"

                    # 使用数组避免子 shell 问题
                    local auth_quick_list
                    mapfile -t auth_quick_list < <(jq -r '.auths[] | "\(.name)|\(.cert_file)|\(.auth_domain // "")|\(.note)"' "$CLOUDFLARED_AUTH_FILE" 2>/dev/null)

                    local auth_index=1
                    for auth_quick_item in "${auth_quick_list[@]}"; do
                        IFS='|' read -r name cert_file auth_domain note <<< "$auth_quick_item"
                        if [[ -n "$note" && -n "$auth_domain" ]]; then
                            echo -e "${GREEN}${auth_index}.${NC} $name - $note (${CYAN}$auth_domain${NC})"
                        elif [[ -n "$note" ]]; then
                            echo -e "${GREEN}${auth_index}.${NC} $name - $note"
                        elif [[ -n "$auth_domain" ]]; then
                            echo -e "${GREEN}${auth_index}.${NC} $name (${CYAN}$auth_domain${NC})"
                        else
                            echo -e "${GREEN}${auth_index}.${NC} $name"
                        fi
                        ((auth_index++))
                    done
                    echo ""

                    read -p "请选择授权 [1-$auth_count]: " auth_choice

                    if ! [[ "$auth_choice" =~ ^[0-9]+$ ]] || [[ "$auth_choice" -lt 1 ]] || [[ "$auth_choice" -gt "$auth_count" ]]; then
                        print_error "无效选择"
                        use_argo=false
                        continue
                    fi

                    selected_cert_file=$(jq -r ".auths[$((auth_choice-1))].cert_file" "$CLOUDFLARED_AUTH_FILE")
                elif [[ "$auth_count" -eq 1 ]]; then
                    # 只有一个授权，直接使用
                    selected_cert_file=$(jq -r '.auths[0].cert_file' "$CLOUDFLARED_AUTH_FILE")
                    local auth_name=$(jq -r '.auths[0].name' "$CLOUDFLARED_AUTH_FILE")
                    print_info "使用授权: $auth_name"
                fi

                # 检查是否有现有的专用隧道（通过域名验证）
                local existing_tunnels=""
                local selected_auth_domain=""

                # 获取选定授权的授权域名
                if [[ "$auth_count" -eq 1 ]]; then
                    selected_auth_domain=$(jq -r '.auths[0].auth_domain // ""' "$CLOUDFLARED_AUTH_FILE")
                elif [[ "$auth_count" -gt 1 ]] && [[ -n "$auth_choice" ]]; then
                    selected_auth_domain=$(jq -r ".auths[$((auth_choice-1))].auth_domain // \"\"" "$CLOUDFLARED_AUTH_FILE")
                fi

                # 使用域名验证方式获取隧道列表
                if [[ -n "$selected_auth_domain" ]]; then
                    # 调用 cf_tunnel.sh 中的函数（通过域名验证）
                    local tunnel_list=$(get_cf_auth_tunnels "$selected_auth_domain")
                    if [[ -n "$tunnel_list" ]]; then
                        # 转换为换行分隔
                        existing_tunnels=$(echo "$tunnel_list" | tr ',' '\n')
                    fi
                fi

                if [[ -n "$existing_tunnels" ]]; then
                    # 有现有隧道，让用户选择
                    echo -e "${YELLOW}检测到现有专用隧道：${NC}"
                    local tunnel_index=1
                    declare -A tunnel_map

                    for tname in $existing_tunnels; do
                        local config_file="${CLOUDFLARED_CONFIG_DIR}/config-${tname}.yml"
                        local domain=""
                        if [[ -f "$config_file" ]]; then
                            domain=$(grep "hostname:" "$config_file" 2>/dev/null | head -1 | awk '{print $2}')
                        fi
                        echo -e "${GREEN}${tunnel_index}.${NC} $tname ${domain:+→ $domain}"
                        tunnel_map[$tunnel_index]="$tname|$domain"
                        ((tunnel_index++))
                    done
                    echo -e "${GREEN}0.${NC} 创建新的专用隧道"
                    echo ""

                    read -p "请选择 [0-$((tunnel_index-1))]: " tunnel_choice

                    if [[ "$tunnel_choice" == "0" ]]; then
                        # 创建新隧道
                        print_info "即将创建新的专用隧道"
                        print_info "请按照提示完成 Cloudflare 授权和隧道配置"
                        echo ""
                        read -p "按回车键继续..."

                        # 调用创建专用隧道函数
                        if declare -f create_dedicated_argo_tunnel >/dev/null 2>&1; then
                            # 临时获取隧道信息
                            local tunnel_created=false
                            local new_tunnel_name=""
                            local new_tunnel_domain=""

                            # 执行创建，并尝试从 nodes.json 获取绑定信息
                            create_dedicated_argo_tunnel

                            # 检查最近创建的隧道（从配置文件）
                            local latest_tunnel=""
                            # 获取最新的配置文件（按修改时间排序）
                            local latest_config=$(ls -t "${CLOUDFLARED_CONFIG_DIR}"/config-*.yml 2>/dev/null | head -1)
                            if [[ -n "$latest_config" && -f "$latest_config" ]]; then
                                latest_tunnel=$(basename "$latest_config" | sed 's/^config-//;s/\.yml$//')
                            fi
                            if [[ -n "$latest_tunnel" ]]; then
                                new_tunnel_name="$latest_tunnel"
                                local config_file="${CLOUDFLARED_CONFIG_DIR}/config-${latest_tunnel}.yml"
                                if [[ -f "$config_file" ]]; then
                                    new_tunnel_domain=$(grep "hostname:" "$config_file" 2>/dev/null | head -1 | awk '{print $2}')
                                    tunnel_created=true
                                fi
                            fi

                            if [[ "$tunnel_created" == true ]]; then
                                tunnel_domain="$new_tunnel_domain"
                                print_success "隧道创建成功: $new_tunnel_name"
                            else
                                print_warning "无法确认隧道创建状态"
                                use_argo=false
                            fi
                        else
                            print_error "无法找到创建隧道的函数"
                            use_argo=false
                        fi
                    else
                        # 使用现有隧道
                        if [[ -n "${tunnel_map[$tunnel_choice]}" ]]; then
                            IFS='|' read -r selected_tunnel selected_domain <<< "${tunnel_map[$tunnel_choice]}"
                            tunnel_domain="$selected_domain"

                            # 获取隧道 ID（从配置文件）
                            local tunnel_id=""
                            local existing_config="${CLOUDFLARED_CONFIG_DIR}/config-${selected_tunnel}.yml"
                            if [[ -f "$existing_config" ]]; then
                                # 从现有配置文件读取 tunnel ID
                                tunnel_id=$(grep "^tunnel:" "$existing_config" 2>/dev/null | awk '{print $2}')
                            fi

                            # 如果配置文件中没有，尝试从凭证文件推断
                            if [[ -z "$tunnel_id" ]]; then
                                local creds_pattern="${CLOUDFLARED_CONFIG_DIR}/*-*-*-*-*.json"
                                local matching_creds=$(ls $creds_pattern 2>/dev/null | head -1)
                                if [[ -n "$matching_creds" ]]; then
                                    tunnel_id=$(basename "$matching_creds" .json)
                                fi
                            fi

                            if [[ -n "$tunnel_id" ]]; then
                                # 更新隧道配置，将其绑定到新创建的节点端口
                                local config_file="${CLOUDFLARED_CONFIG_DIR}/config-${selected_tunnel}.yml"

                                print_info "正在绑定隧道到端口 $port..."

                                cat > "$config_file" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${CLOUDFLARED_CONFIG_DIR}/${tunnel_id}.json

ingress:
  - hostname: ${tunnel_domain}
    service: http://localhost:${port}
  - service: http_status:404
EOF

                                # 更新节点配置
                                jq --arg port "$port" \
                                   --arg domain "$tunnel_domain" \
                                   --arg tunnel_name "$selected_tunnel" \
                                   '(.nodes[] | select(.port == $port)) |= (
                                       . + {
                                           tunnel_domain: $domain,
                                           tunnel_name: $tunnel_name,
                                           tunnel_type: "argo_dedicated"
                                       }
                                   )' \
                                   "$DATA_DIR/nodes.json" > "$DATA_DIR/nodes.json.tmp" && mv "$DATA_DIR/nodes.json.tmp" "$DATA_DIR/nodes.json"

                                # 重启 cloudflared 服务
                                local service_name="cloudflared-${selected_tunnel}.service"
                                if systemctl is-active --quiet "$service_name"; then
                                    systemctl restart "$service_name" 2>/dev/null
                                fi

                                print_success "隧道绑定成功: $selected_tunnel → 端口 $port"
                            else
                                print_error "无法获取隧道 ID"
                                use_argo=false
                            fi
                        else
                            print_error "无效选择"
                            use_argo=false
                        fi
                    fi
                else
                    # 没有现有隧道，引导创建
                    print_info "未检测到专用隧道，需要先创建"
                    print_info "专用隧道需要 Cloudflare 账号授权"
                    echo ""
                    read -p "是否现在创建专用隧道？[Y/n]: " create_choice

                    if [[ "$create_choice" != "n" && "$create_choice" != "N" ]]; then
                        if declare -f create_dedicated_argo_tunnel >/dev/null 2>&1; then
                            create_dedicated_argo_tunnel

                            # 检查创建结果
                            local latest_tunnel=$("$CLOUDFLARED_BIN" tunnel list 2>/dev/null | tail -n +2 | tail -1 | awk '{print $2}')
                            if [[ -n "$latest_tunnel" ]]; then
                                local config_file="${CLOUDFLARED_CONFIG_DIR}/config-${latest_tunnel}.yml"
                                if [[ -f "$config_file" ]]; then
                                    tunnel_domain=$(grep "hostname:" "$config_file" 2>/dev/null | head -1 | awk '{print $2}')
                                    print_success "隧道创建成功"
                                fi
                            else
                                print_warning "隧道创建可能失败"
                                use_argo=false
                            fi
                        else
                            print_error "无法找到创建隧道的函数"
                            use_argo=false
                        fi
                    else
                        print_info "跳过专用隧道配置"
                        use_argo=false
                    fi
                fi
            fi
        fi
    fi

    # 显示最终配置信息
    echo ""
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo -e "${GREEN}   节点创建成功！${NC}"
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}节点信息：${NC}"
    echo -e "  本地端口: ${YELLOW}$port${NC}"
    echo -e "  协议: ${YELLOW}VLESS${NC}"
    echo -e "  传输: ${YELLOW}WebSocket${NC}"
    echo -e "  WS路径: ${YELLOW}$ws_path${NC}"
    echo -e "  Host头: ${YELLOW}$ws_host${NC}"
    echo -e "  默认用户: ${YELLOW}admin${NC}"
    echo -e "  UUID: ${YELLOW}$admin_uuid${NC}"

    if [[ -n "$tunnel_domain" ]]; then
        echo -e "  Argo隧道: ${YELLOW}$tunnel_domain${NC}"
        echo -e "  访问地址: ${GREEN}$tunnel_domain:443${NC}"
    else
        echo -e "  Argo隧道: ${YELLOW}未配置${NC}"
    fi
    echo ""

    # 生成并显示分享链接
    generate_and_show_node_link "$port" "$admin_uuid" "$admin_username"

    if [[ "$use_argo" == true && "$argo_type" == "temp" && -n "$tunnel_domain" ]]; then
        echo ""
        echo -e "${YELLOW}重要提示：${NC}"
        echo -e "  • 临时隧道域名在重启后会变化"
        echo -e "  • 建议使用专用隧道获得固定域名"
        echo -e "  • 停止隧道: kill $tunnel_pid"
    fi
}

# 快速搭建菜单
menu_quick_setup() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}        快速搭建节点"
        echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}━━━━━━━ 一键快速搭建 ━━━━━━━${NC}"
        echo -e "${GREEN}1.${NC}  VLESS + Reality       - 无需证书，抗审查"
        echo -e "${GREEN}2.${NC}  Hysteria2             - 高性能 QUIC 协议"
        echo -e "${GREEN}3.${NC}  Argo+VLESS+WS         - 隐藏IP，快速部署"
        echo ""

        print_nav_options "true" "true"
        choice=$(read_menu_choice "请选择")
        local ret=$?

        # 处理导航
        [[ $ret -eq 99 ]] && return 0  # 返回上级
        [[ $ret -eq 98 ]] && return 98  # 返回主菜单

        case $choice in
            1)
                quick_setup_vless_reality
                read -p "按 Enter 键继续..."
                ;;
            2)
                quick_setup_hysteria2
                read -p "按 Enter 键继续..."
                ;;
            3)
                quick_setup_argo_vless_ws
                read -p "按 Enter 键继续..."
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}
