#!/bin/bash

# =============================================================================
# sing-box 域名管理模块
# 功能：域名配置、证书关联、域名解析管理
# =============================================================================

DATA_DIR="./data"
DOMAINS_FILE="${DATA_DIR}/domains.json"
CERT_DIR="/usr/local/singbox/certs"

# =============================================================================
# 域名数据初始化
# =============================================================================

init_domains_file() {
    if [[ ! -f "$DOMAINS_FILE" ]]; then
        cat > "$DOMAINS_FILE" <<EOF
{
  "domains": []
}
EOF
        print_success "domains.json 初始化完成"
    fi
}

# =============================================================================
# 域名操作函数
# =============================================================================

# 添加域名
add_domain() {
    print_info "添加域名配置"

    # 输入域名信息
    read -p "请输入域名: " domain

    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 检查域名是否已存在
    local existing=$(jq -r --arg domain "$domain" '.domains[] | select(.domain == $domain)' "$DOMAINS_FILE" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        print_error "域名已存在: $domain"
        return 1
    fi

    # 输入域名用途
    echo "请选择域名用途:"
    echo "1) TLS 证书域名"
    echo "2) SNI 路由域名"
    echo "3) 节点绑定域名"
    read -p "请选择 [1]: " purpose_choice
    purpose_choice=${purpose_choice:-1}

    local purpose=""
    case "$purpose_choice" in
        1) purpose="tls" ;;
        2) purpose="sni" ;;
        3) purpose="node" ;;
        *) purpose="tls" ;;
    esac

    # 证书配置
    local cert_path=""
    local key_path=""
    local cert_status="未配置"

    if [[ "$purpose" == "tls" || "$purpose" == "node" ]]; then
        read -p "是否配置证书? [Y/n]: " config_cert
        config_cert=${config_cert:-Y}

        if [[ "$config_cert" =~ ^[Yy]$ ]]; then
            # 检查证书是否已存在
            if [[ -f "${CERT_DIR}/${domain}/fullchain.cer" ]]; then
                cert_path="${CERT_DIR}/${domain}/fullchain.cer"
                key_path="${CERT_DIR}/${domain}/${domain}.key"
                cert_status="已配置"
                print_info "检测到已存在的证书"
            else
                read -p "请输入证书路径: " cert_path
                read -p "请输入私钥路径: " key_path

                # 验证文件存在
                if [[ -f "$cert_path" && -f "$key_path" ]]; then
                    cert_status="已配置"
                else
                    print_warn "证书文件不存在，将保存路径但标记为未验证"
                    cert_status="未验证"
                fi
            fi
        fi
    fi

    # 关联节点
    local associated_nodes="[]"
    read -p "是否关联到节点? [y/N]: " assoc_nodes
    assoc_nodes=${assoc_nodes:-N}

    if [[ "$assoc_nodes" =~ ^[Yy]$ ]]; then
        source modules/node.sh
        list_nodes

        read -p "请输入节点端口 (多个用空格分隔): " ports

        if [[ -n "$ports" ]]; then
            for port in $ports; do
                associated_nodes=$(echo "$associated_nodes" | jq --arg port "$port" '. += [$port]')
            done
        fi
    fi

    # 生成域名配置
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local domain_config=$(jq -n \
        --arg domain "$domain" \
        --arg purpose "$purpose" \
        --arg cert_path "$cert_path" \
        --arg key_path "$key_path" \
        --arg cert_status "$cert_status" \
        --arg timestamp "$timestamp" \
        --argjson nodes "$associated_nodes" \
        '{
            domain: $domain,
            purpose: $purpose,
            certificate: {
                cert_path: $cert_path,
                key_path: $key_path,
                status: $cert_status
            },
            associated_nodes: $nodes,
            created_at: $timestamp,
            last_update: $timestamp
        }')

    # 添加到 domains.json
    local domains_data=$(cat "$DOMAINS_FILE")
    domains_data=$(echo "$domains_data" | jq --argjson domain "$domain_config" '.domains += [$domain]')
    echo "$domains_data" | jq '.' > "$DOMAINS_FILE"

    print_success "域名添加成功: $domain"
    print_info "用途: $purpose"
    print_info "证书状态: $cert_status"

    return 0
}

# 删除域名
delete_domain() {
    list_domains

    read -p "请输入要删除的域名: " domain

    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 检查域名是否存在
    local existing=$(jq -r --arg domain "$domain" '.domains[] | select(.domain == $domain)' "$DOMAINS_FILE" 2>/dev/null)

    if [[ -z "$existing" ]]; then
        print_error "域名不存在: $domain"
        return 1
    fi

    # 确认删除
    read -p "确认删除域名 $domain? [y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return 0
    fi

    # 从 domains.json 删除
    local domains_data=$(cat "$DOMAINS_FILE")
    domains_data=$(echo "$domains_data" | jq --arg domain "$domain" '.domains = [.domains[] | select(.domain != $domain)]')
    echo "$domains_data" | jq '.' > "$DOMAINS_FILE"

    print_success "域名已删除: $domain"

    # 询问是否删除证书
    read -p "是否同时删除证书文件? [y/N]: " delete_cert
    delete_cert=${delete_cert:-N}

    if [[ "$delete_cert" =~ ^[Yy]$ ]]; then
        if [[ -d "${CERT_DIR}/${domain}" ]]; then
            rm -rf "${CERT_DIR}/${domain}"
            print_success "证书文件已删除"
        fi
    fi

    return 0
}

# 列出所有域名
list_domains() {
    print_info "域名列表:"

    local domains=$(jq -r '.domains[]' "$DOMAINS_FILE" 2>/dev/null)

    if [[ -z "$domains" ]]; then
        print_warn "暂无域名配置"
        return 0
    fi

    # 表头
    printf "%-30s %-10s %-15s %-10s\n" "域名" "用途" "证书状态" "关联节点"
    printf "%-30s %-10s %-15s %-10s\n" "----" "----" "--------" "--------"

    # 遍历域名
    local domain_count=$(jq '.domains | length' "$DOMAINS_FILE")

    for ((i=0; i<domain_count; i++)); do
        local domain_obj=$(jq -r ".domains[$i]" "$DOMAINS_FILE")
        local domain=$(echo "$domain_obj" | jq -r '.domain')
        local purpose=$(echo "$domain_obj" | jq -r '.purpose')
        local cert_status=$(echo "$domain_obj" | jq -r '.certificate.status')
        local node_count=$(echo "$domain_obj" | jq '.associated_nodes | length')

        printf "%-30s %-10s %-15s %-10s\n" "$domain" "$purpose" "$cert_status" "$node_count"
    done

    echo ""
}

# 查看域名详情
show_domain_info() {
    read -p "请输入域名: " domain

    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    local domain_obj=$(jq -r --arg domain "$domain" '.domains[] | select(.domain == $domain)' "$DOMAINS_FILE" 2>/dev/null)

    if [[ -z "$domain_obj" ]]; then
        print_error "域名不存在: $domain"
        return 1
    fi

    print_info "域名详细信息: $domain"
    echo ""
    echo "$domain_obj" | jq '.'
    echo ""

    # 检查证书有效期
    local cert_path=$(echo "$domain_obj" | jq -r '.certificate.cert_path')

    if [[ -f "$cert_path" ]]; then
        print_info "证书信息:"
        openssl x509 -in "$cert_path" -noout -dates
    fi
}

# 更新域名证书
update_domain_cert() {
    list_domains

    read -p "请输入域名: " domain

    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 检查域名是否存在
    local existing=$(jq -r --arg domain "$domain" '.domains[] | select(.domain == $domain)' "$DOMAINS_FILE" 2>/dev/null)

    if [[ -z "$existing" ]]; then
        print_error "域名不存在: $domain"
        return 1
    fi

    read -p "请输入新的证书路径: " cert_path
    read -p "请输入新的私钥路径: " key_path

    # 验证文件存在
    local cert_status="未验证"
    if [[ -f "$cert_path" && -f "$key_path" ]]; then
        cert_status="已配置"
        print_success "证书文件验证通过"
    else
        print_warn "证书文件不存在"
    fi

    # 更新配置
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local domains_data=$(cat "$DOMAINS_FILE")

    domains_data=$(echo "$domains_data" | jq --arg domain "$domain" --arg cert "$cert_path" --arg key "$key_path" --arg status "$cert_status" --arg time "$timestamp" \
        '(.domains[] | select(.domain == $domain) | .certificate.cert_path) = $cert |
         (.domains[] | select(.domain == $domain) | .certificate.key_path) = $key |
         (.domains[] | select(.domain == $domain) | .certificate.status) = $status |
         (.domains[] | select(.domain == $domain) | .last_update) = $time')

    echo "$domains_data" | jq '.' > "$DOMAINS_FILE"

    print_success "域名证书已更新"
}

# 关联域名到节点
associate_domain_to_node() {
    list_domains

    read -p "请输入域名: " domain

    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    # 列出节点
    source modules/node.sh
    list_nodes

    read -p "请输入节点端口: " port

    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 更新关联
    local domains_data=$(cat "$DOMAINS_FILE")
    domains_data=$(echo "$domains_data" | jq --arg domain "$domain" --arg port "$port" \
        '(.domains[] | select(.domain == $domain) | .associated_nodes) += [$port] |
         (.domains[] | select(.domain == $domain) | .associated_nodes) |= unique')

    echo "$domains_data" | jq '.' > "$DOMAINS_FILE"

    print_success "域名已关联到节点: $port"
}

# 解除域名关联
disassociate_domain_from_node() {
    list_domains

    read -p "请输入域名: " domain

    if [[ -z "$domain" ]]; then
        print_error "域名不能为空"
        return 1
    fi

    read -p "请输入要解除关联的节点端口: " port

    if [[ -z "$port" ]]; then
        print_error "端口不能为空"
        return 1
    fi

    # 更新关联
    local domains_data=$(cat "$DOMAINS_FILE")
    domains_data=$(echo "$domains_data" | jq --arg domain "$domain" --arg port "$port" \
        '(.domains[] | select(.domain == $domain) | .associated_nodes) -= [$port]')

    echo "$domains_data" | jq '.' > "$DOMAINS_FILE"

    print_success "已解除域名与节点的关联"
}

# 批量申请证书
batch_request_certs() {
    print_info "批量申请证书..."

    local domain_count=$(jq '.domains | length' "$DOMAINS_FILE")

    if [[ $domain_count -eq 0 ]]; then
        print_warn "暂无域名配置"
        return 0
    fi

    for ((i=0; i<domain_count; i++)); do
        local domain_obj=$(jq -r ".domains[$i]" "$DOMAINS_FILE")
        local domain=$(echo "$domain_obj" | jq -r '.domain')
        local cert_status=$(echo "$domain_obj" | jq -r '.certificate.status')

        if [[ "$cert_status" == "未配置" ]]; then
            echo ""
            print_info "为域名申请证书: $domain"

            # 调用证书管理模块
            source modules/cert.sh

            echo "请选择验证方式:"
            echo "1) HTTP-01"
            echo "2) DNS API"
            echo "3) Standalone"
            echo "0) 跳过"
            read -p "请选择 [1]: " method_choice
            method_choice=${method_choice:-1}

            case "$method_choice" in
                1)
                    issue_cert_http "$domain"
                    ;;
                2)
                    issue_cert_dns "$domain"
                    ;;
                3)
                    issue_cert_standalone "$domain"
                    ;;
                0)
                    print_info "跳过: $domain"
                    continue
                    ;;
            esac

            # 更新证书路径
            if [[ -f "${CERT_DIR}/${domain}/fullchain.cer" ]]; then
                local cert_path="${CERT_DIR}/${domain}/fullchain.cer"
                local key_path="${CERT_DIR}/${domain}/${domain}.key"

                local domains_data=$(cat "$DOMAINS_FILE")
                domains_data=$(echo "$domains_data" | jq --arg domain "$domain" --arg cert "$cert_path" --arg key "$key_path" \
                    '(.domains[] | select(.domain == $domain) | .certificate.cert_path) = $cert |
                     (.domains[] | select(.domain == $domain) | .certificate.key_path) = $key |
                     (.domains[] | select(.domain == $domain) | .certificate.status) = "已配置"')

                echo "$domains_data" | jq '.' > "$DOMAINS_FILE"
            fi
        fi
    done

    print_success "批量证书申请完成"
}

# =============================================================================
# 域名管理菜单
# =============================================================================

domain_menu() {
    while true; do
        clear
        print_header "域名管理"

        echo "1)  添加域名"
        echo "2)  删除域名"
        echo "3)  列出域名"
        echo "4)  查看域名详情"
        echo "5)  更新域名证书"
        echo "6)  关联域名到节点"
        echo "7)  解除域名关联"
        echo "8)  批量申请证书"
        echo ""
        echo "0)  返回主菜单"
        echo ""

        read -p "请选择: " choice

        case "$choice" in
            1)
                add_domain
                read -p "按回车键继续..."
                ;;
            2)
                delete_domain
                read -p "按回车键继续..."
                ;;
            3)
                list_domains
                read -p "按回车键继续..."
                ;;
            4)
                show_domain_info
                read -p "按回车键继续..."
                ;;
            5)
                update_domain_cert
                read -p "按回车键继续..."
                ;;
            6)
                associate_domain_to_node
                read -p "按回车键继续..."
                ;;
            7)
                disassociate_domain_from_node
                read -p "按回车键继续..."
                ;;
            8)
                batch_request_certs
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
init_domains_file
