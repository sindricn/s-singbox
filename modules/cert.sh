#!/bin/bash

# =============================================================================
# sing-box 证书管理模块
# 功能：TLS 证书申请、续期、管理
# =============================================================================

# 证书存储目录（使用官方标准路径）
# 证书存放在配置目录下
CERT_DIR="${SINGBOX_DIR:-/etc/sing-box}/certs"
# acme.sh 存放在数据目录下
ACME_DIR="${DATA_DIR:-/var/lib/sing-box}/acme"
ACME_SH="${ACME_DIR}/acme.sh"

# =============================================================================
# acme.sh 安装和初始化
# =============================================================================

# 检查 acme.sh 是否安装
check_acme_installed() {
    if [[ -f "$ACME_SH" ]]; then
        return 0
    else
        return 1
    fi
}

# 安装 acme.sh
install_acme() {
    print_info "安装 acme.sh..."

    if check_acme_installed; then
        print_warn "acme.sh 已安装"
        return 0
    fi

    # 创建目录
    mkdir -p "$ACME_DIR"

    # 下载并安装 acme.sh
    curl -sL https://get.acme.sh | sh -s -- --install-online \
        --home "$ACME_DIR" \
        --config-home "${ACME_DIR}/config" \
        --cert-home "$CERT_DIR"

    if [[ $? -eq 0 ]]; then
        print_success "acme.sh 安装成功"

        # 设置自动续期
        "${ACME_SH}" --upgrade --auto-upgrade

        return 0
    else
        print_error "acme.sh 安装失败"
        return 1
    fi
}

# 卸载 acme.sh
uninstall_acme() {
    print_info "卸载 acme.sh..."

    if check_acme_installed; then
        "${ACME_SH}" --uninstall
        rm -rf "$ACME_DIR"
        print_success "acme.sh 已卸载"
    else
        print_warn "acme.sh 未安装"
    fi
}

# =============================================================================
# 证书申请
# =============================================================================

# 使用 HTTP-01 验证申请证书
issue_cert_http() {
    local domain=$1
    local webroot=$2

    print_info "使用 HTTP-01 验证申请证书: $domain"

    if [[ -z "$webroot" ]]; then
        webroot="/var/www/html"
    fi

    # 确保 webroot 存在
    mkdir -p "$webroot"

    # 申请证书
    "${ACME_SH}" --issue -d "$domain" \
        --webroot "$webroot" \
        --keylength ec-256 \
        --force

    if [[ $? -eq 0 ]]; then
        install_cert "$domain"
        return 0
    else
        print_error "证书申请失败"
        return 1
    fi
}

# 使用 DNS API 申请证书
issue_cert_dns() {
    local domain=$1
    local dns_provider=$2

    print_info "使用 DNS API 申请证书: $domain"

    # 常见 DNS 提供商
    echo "请选择 DNS 提供商:"
    echo "1) Cloudflare"
    echo "2) Aliyun"
    echo "3) DNSPod"
    echo "4) 其他"

    read -p "请选择 [1]: " provider_choice
    provider_choice=${provider_choice:-1}

    local dns_hook=""
    case "$provider_choice" in
        1)
            # Cloudflare
            read -p "请输入 Cloudflare Email: " cf_email
            read -p "请输入 Cloudflare API Key: " cf_key

            export CF_Email="$cf_email"
            export CF_Key="$cf_key"

            dns_hook="dns_cf"
            ;;
        2)
            # Aliyun
            read -p "请输入阿里云 Access Key ID: " ali_key
            read -p "请输入阿里云 Access Key Secret: " ali_secret

            export Ali_Key="$ali_key"
            export Ali_Secret="$ali_secret"

            dns_hook="dns_ali"
            ;;
        3)
            # DNSPod
            read -p "请输入 DNSPod ID: " dp_id
            read -p "请输入 DNSPod Key: " dp_key

            export DP_Id="$dp_id"
            export DP_Key="$dp_key"

            dns_hook="dns_dp"
            ;;
        *)
            print_error "不支持的 DNS 提供商"
            return 1
            ;;
    esac

    # 申请证书
    "${ACME_SH}" --issue -d "$domain" \
        --dns "$dns_hook" \
        --keylength ec-256 \
        --force

    if [[ $? -eq 0 ]]; then
        install_cert "$domain"
        return 0
    else
        print_error "证书申请失败"
        return 1
    fi
}

# 使用 Standalone 模式申请证书
issue_cert_standalone() {
    local domain=$1
    local port=${2:-80}

    print_info "使用 Standalone 模式申请证书: $domain"

    # 检查端口是否被占用
    if netstat -tuln | grep -q ":${port} "; then
        print_error "端口 $port 已被占用，请先停止占用该端口的服务"
        return 1
    fi

    # 申请证书
    "${ACME_SH}" --issue -d "$domain" \
        --standalone \
        --httpport "$port" \
        --keylength ec-256 \
        --force

    if [[ $? -eq 0 ]]; then
        install_cert "$domain"
        return 0
    else
        print_error "证书申请失败"
        return 1
    fi
}

# =============================================================================
# 证书安装和管理
# =============================================================================

# 安装证书到指定目录
install_cert() {
    local domain=$1

    local cert_path="${CERT_DIR}/${domain}/fullchain.pem"
    local key_path="${CERT_DIR}/${domain}/${domain}.key"

    print_info "安装证书到: $CERT_DIR/$domain"

    mkdir -p "${CERT_DIR}/${domain}"

    "${ACME_SH}" --install-cert -d "$domain" \
        --ecc \
        --fullchain-file "$cert_path" \
        --key-file "$key_path" \
        --reloadcmd "systemctl reload sing-box 2>/dev/null || true"

    if [[ $? -eq 0 ]]; then
        print_success "证书安装成功"
        print_info "证书路径: $cert_path"
        print_info "私钥路径: $key_path"

        # 设置权限
        chmod 644 "$cert_path"
        chmod 600 "$key_path"

        return 0
    else
        print_error "证书安装失败"
        return 1
    fi
}

# 续期证书
renew_cert() {
    local domain=$1

    print_info "续期证书: $domain"

    "${ACME_SH}" --renew -d "$domain" --ecc --force

    if [[ $? -eq 0 ]]; then
        print_success "证书续期成功"
        systemctl reload sing-box 2>/dev/null || true
        return 0
    else
        print_error "证书续期失败"
        return 1
    fi
}

# 续期所有证书
renew_all_certs() {
    print_info "续期所有证书..."

    "${ACME_SH}" --renew-all --force

    if [[ $? -eq 0 ]]; then
        print_success "所有证书已续期"
        systemctl reload sing-box 2>/dev/null || true
    else
        print_error "部分证书续期失败"
    fi
}

# 列出所有证书
list_certs() {
    print_info "已安装的证书:"

    if ! check_acme_installed; then
        print_warn "acme.sh 未安装"
        return 1
    fi

    "${ACME_SH}" --list

    echo ""
    print_info "证书存储目录: $CERT_DIR"

    if [[ -d "$CERT_DIR" ]]; then
        echo ""
        ls -lh "$CERT_DIR"
    fi
}

# 删除证书
remove_cert() {
    local domain=$1

    print_info "删除证书: $domain"

    # 确认删除
    read -p "确认删除域名 $domain 的证书? [y/N]: " confirm
    confirm=${confirm:-N}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        return 0
    fi

    # 删除证书
    "${ACME_SH}" --remove -d "$domain" --ecc

    # 删除证书文件
    if [[ -d "${CERT_DIR}/${domain}" ]]; then
        rm -rf "${CERT_DIR}/${domain}"
    fi

    print_success "证书已删除"
}

# =============================================================================
# 自签名证书
# =============================================================================

# 生成自签名证书
generate_self_signed_cert() {
    local domain=$1
    local days=${2:-365}

    print_info "生成自签名证书: $domain (有效期: $days 天)"

    local cert_dir="${CERT_DIR}/${domain}"
    mkdir -p "$cert_dir"

    local cert_path="${cert_dir}/fullchain.pem"
    local key_path="${cert_dir}/${domain}.key"

    # 生成私钥和证书
    openssl req -x509 -newkey rsa:4096 \
        -keyout "$key_path" \
        -out "$cert_path" \
        -days "$days" \
        -nodes \
        -subj "/CN=$domain"

    if [[ $? -eq 0 ]]; then
        print_success "自签名证书生成成功"
        print_info "证书路径: $cert_path"
        print_info "私钥路径: $key_path"

        # 设置权限
        chmod 644 "$cert_path"
        chmod 600 "$key_path"

        return 0
    else
        print_error "证书生成失败"
        return 1
    fi
}

# =============================================================================
# 证书信息查看
# =============================================================================

# 查看证书详情
show_cert_info() {
    local domain=$1

    local cert_path="${CERT_DIR}/${domain}/fullchain.pem"

    if [[ ! -f "$cert_path" ]]; then
        print_error "证书不存在: $domain"
        return 1
    fi

    print_info "证书详细信息: $domain"

    openssl x509 -in "$cert_path" -text -noout | grep -A 2 "Validity"
    openssl x509 -in "$cert_path" -text -noout | grep "Subject:"
    openssl x509 -in "$cert_path" -text -noout | grep "DNS:"

    echo ""
    print_info "证书文件:"
    ls -lh "${CERT_DIR}/${domain}/"
}

# 检查证书过期时间
check_cert_expiry() {
    local domain=$1

    local cert_path="${CERT_DIR}/${domain}/fullchain.pem"

    if [[ ! -f "$cert_path" ]]; then
        print_error "证书不存在: $domain"
        return 1
    fi

    local expiry_date=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)

    print_info "证书过期时间: $expiry_date"

    # 计算剩余天数
    local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
    local current_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

    if [[ $days_left -lt 0 ]]; then
        print_error "证书已过期!"
    elif [[ $days_left -lt 30 ]]; then
        print_warn "证书将在 $days_left 天后过期"
    else
        print_success "证书剩余 $days_left 天有效期"
    fi
}

# =============================================================================
# 证书管理菜单
# =============================================================================

cert_management_menu() {
    while true; do
        clear
        print_header "证书管理"

        echo "1)  安装 acme.sh"
        echo "2)  申请证书 (HTTP-01)"
        echo "3)  申请证书 (DNS API)"
        echo "4)  申请证书 (Standalone)"
        echo "5)  续期证书"
        echo "6)  续期所有证书"
        echo "7)  列出证书"
        echo "8)  删除证书"
        echo "9)  生成自签名证书"
        echo "10) 查看证书信息"
        echo "11) 检查证书过期"
        echo ""
        echo "0)  返回主菜单"
        echo ""

        read -p "请选择: " choice

        case "$choice" in
            1)
                install_acme
                read -p "按回车键继续..."
                ;;
            2)
                read -p "请输入域名: " domain
                read -p "请输入 WebRoot 路径 [/var/www/html]: " webroot
                webroot=${webroot:-/var/www/html}
                issue_cert_http "$domain" "$webroot"
                read -p "按回车键继续..."
                ;;
            3)
                read -p "请输入域名: " domain
                issue_cert_dns "$domain"
                read -p "按回车键继续..."
                ;;
            4)
                read -p "请输入域名: " domain
                read -p "请输入端口 [80]: " port
                port=${port:-80}
                issue_cert_standalone "$domain" "$port"
                read -p "按回车键继续..."
                ;;
            5)
                read -p "请输入域名: " domain
                renew_cert "$domain"
                read -p "按回车键继续..."
                ;;
            6)
                renew_all_certs
                read -p "按回车键继续..."
                ;;
            7)
                list_certs
                read -p "按回车键继续..."
                ;;
            8)
                read -p "请输入域名: " domain
                remove_cert "$domain"
                read -p "按回车键继续..."
                ;;
            9)
                read -p "请输入域名: " domain
                read -p "请输入有效期(天) [365]: " days
                days=${days:-365}
                generate_self_signed_cert "$domain" "$days"
                read -p "按回车键继续..."
                ;;
            10)
                read -p "请输入域名: " domain
                show_cert_info "$domain"
                read -p "按回车键继续..."
                ;;
            11)
                read -p "请输入域名: " domain
                check_cert_expiry "$domain"
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
