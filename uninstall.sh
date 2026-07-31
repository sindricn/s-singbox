#!/bin/bash

# =============================================================================
# sing-box 卸载脚本
# 功能：完全卸载 sing-box 及相关配置
# =============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
readonly SINGBOX_DATA_DIR="/var/lib/sing-box"

# 打印函数
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_header() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
}

# =============================================================================
# 确认卸载
# =============================================================================

confirm_uninstall() {
    print_header "sing-box 卸载程序"

    print_warn "此操作将完全卸载 sing-box 及其所有配置"
    echo ""
    echo "将会删除以下内容:"
    echo "  - sing-box 二进制文件"
    echo "  - systemd 服务文件"
    echo "  - 配置文件和数据文件"
    echo "  - 证书文件"
    echo "  - 日志文件"
    echo ""

    read -p "确认卸载? 请输入 'yes' 确认: " confirm

    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消卸载"
        exit 0
    fi

    echo ""
    read -p "是否保留数据文件（用户、节点、绑定数据）? [y/N]: " keep_data
    keep_data=${keep_data:-N}

    echo ""
    read -p "是否保留证书文件? [y/N]: " keep_certs
    keep_certs=${keep_certs:-N}
}

# =============================================================================
# 停止服务
# =============================================================================

stop_service() {
    print_info "停止 sing-box 服务..."

    if systemctl is-active --quiet sing-box; then
        systemctl stop sing-box
        print_success "服务已停止"
    else
        print_info "服务未运行"
    fi

    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        systemctl disable sing-box
        print_success "服务已禁用"
    fi
    systemctl disable --now sing-box-user-limits.timer 2>/dev/null || true
    systemctl disable --now sing-box-subscription-health.timer 2>/dev/null || true
    systemctl disable --now sing-box-subscription.service 2>/dev/null || true
}

# =============================================================================
# 删除服务文件
# =============================================================================

remove_service() {
    print_info "删除 systemd 服务文件..."

    local service_files=(
        "/etc/systemd/system/sing-box.service"
        "/etc/systemd/system/sing-box-user-limits.service"
        "/etc/systemd/system/sing-box-user-limits.timer"
        "/etc/systemd/system/sing-box-subscription.service"
        "/etc/systemd/system/sing-box-subscription-health.service"
        "/etc/systemd/system/sing-box-subscription-health.timer"
        "/usr/lib/systemd/system/sing-box.service"
        "/lib/systemd/system/sing-box.service"
    )

    for service_file in "${service_files[@]}"; do
        if [[ -f "$service_file" ]]; then
            rm -f "$service_file"
            print_success "已删除: $service_file"
        fi
    done

    # 重新加载 systemd
    systemctl daemon-reload
    print_success "systemd 已重新加载"
}

# =============================================================================
# 删除二进制文件
# =============================================================================

remove_binary() {
    print_info "删除 sing-box 二进制文件..."

    local binary_paths=(
        "/usr/local/bin/sing-box"
        "/usr/bin/sing-box"
        "/usr/sbin/sing-box"
    )

    for binary in "${binary_paths[@]}"; do
        if [[ -f "$binary" ]]; then
            rm -f "$binary"
            print_success "已删除: $binary"
        fi
    done
}

# =============================================================================
# 删除配置文件
# =============================================================================

remove_config() {
    print_info "删除配置文件..."

    local config_dirs=(
        "/usr/local/singbox"
        "/etc/sing-box"
        "/etc/singbox"
    )

    for config_dir in "${config_dirs[@]}"; do
        if [[ -d "$config_dir" ]]; then
            # 显示要删除的内容
            print_info "发现配置目录: $config_dir"
            if [[ -f "${config_dir}/config.json" ]]; then
                print_info "  包含配置文件: config.json"
            fi
            if [[ -d "${config_dir}/certs" ]]; then
                local cert_count=$(find "${config_dir}/certs" -type f 2>/dev/null | wc -l)
                print_info "  包含证书文件: ${cert_count} 个"
            fi

            # 如果保留证书，先备份
            if [[ "$keep_certs" =~ ^[Yy]$ && -d "${config_dir}/certs" ]]; then
                local backup_dir="/tmp/singbox-certs-backup-$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$backup_dir"
                cp -r "${config_dir}/certs" "$backup_dir/"
                print_info "证书已备份到: $backup_dir"
            fi

            rm -rf "$config_dir"
            print_success "已删除: $config_dir"
        else
            print_info "配置目录不存在: $config_dir"
        fi
    done

    # 额外检查是否有遗留的配置文件
    local extra_configs=(
        "/root/sing-box/config.json"
        "/home/*/sing-box/config.json"
    )

    for config_pattern in "${extra_configs[@]}"; do
        for config_file in $config_pattern; do
            if [[ -f "$config_file" ]]; then
                print_warn "发现遗留配置文件: $config_file"
                read -p "是否删除? [y/N]: " delete_extra
                if [[ "$delete_extra" =~ ^[Yy]$ ]]; then
                    rm -f "$config_file"
                    print_success "已删除: $config_file"
                fi
            fi
        done
    done
}

# =============================================================================
# 删除数据文件
# =============================================================================

remove_data() {
    if [[ "$keep_data" =~ ^[Yy]$ ]]; then
        print_info "保留数据文件"

        # 备份数据文件
        local data_dir="$SINGBOX_DATA_DIR"

        if [[ -d "$data_dir" ]]; then
            local backup_dir
            backup_dir=$(mktemp -d /tmp/singbox-data-backup-XXXXXX) || return 1
            cp -a "$data_dir/." "$backup_dir/" || return 1
            print_success "数据已备份到: $backup_dir"
        fi
    else
        print_info "删除数据文件..."

        local data_dir="$SINGBOX_DATA_DIR"

        if [[ -d "$data_dir" ]]; then
            rm -rf -- "$data_dir"
            print_success "数据文件已删除"
        fi
    fi
}

# =============================================================================
# 删除日志文件
# =============================================================================

remove_logs() {
    print_info "删除日志文件..."

    local log_dirs=(
        "/var/log/singbox"
        "/var/log/sing-box"
    )

    for log_dir in "${log_dirs[@]}"; do
        if [[ -d "$log_dir" ]]; then
            rm -rf "$log_dir"
            print_success "已删除: $log_dir"
        fi
    done
}

# =============================================================================
# 清理防火墙规则
# =============================================================================

cleanup_firewall() {
    print_info "清理防火墙规则..."

    # 检测防火墙类型
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        print_info "检测到 firewalld"
        # 注意：这里不自动删除规则，因为可能影响其他服务
        print_warn "请手动检查并删除 sing-box 相关的防火墙规则"
    elif command -v ufw &>/dev/null; then
        print_info "检测到 ufw"
        print_warn "请手动检查并删除 sing-box 相关的防火墙规则"
    fi
}

# =============================================================================
# 删除管理脚本
# =============================================================================

remove_manager_script() {
    read -p "是否删除 sing-box 管理脚本? [y/N]: " remove_script
    remove_script=${remove_script:-N}

    if [[ "$remove_script" =~ ^[Yy]$ ]]; then
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

        print_warn "将删除管理脚本目录: $script_dir"
        read -p "确认删除? [y/N]: " confirm_delete
        confirm_delete=${confirm_delete:-N}

        if [[ "$confirm_delete" =~ ^[Yy]$ ]]; then
            # 删除所有管理脚本
            rm -rf "${script_dir}/modules"
            rm -rf "${script_dir}/templates"
            rm -rf "${script_dir}/scripts"
            rm -f "${script_dir}/singbox-manager.sh"
            rm -f "${script_dir}/uninstall.sh"

            print_success "管理脚本已删除"
            print_info "目录保留: $script_dir"
        fi
    fi
}

# =============================================================================
# 卸载 acme.sh
# =============================================================================

uninstall_acme() {
    read -p "是否卸载 acme.sh? [y/N]: " uninstall_acme
    uninstall_acme=${uninstall_acme:-N}

    if [[ "$uninstall_acme" =~ ^[Yy]$ ]]; then
        local acme_dir="/usr/local/singbox/acme"

        if [[ -f "${acme_dir}/acme.sh" ]]; then
            print_info "卸载 acme.sh..."
            "${acme_dir}/acme.sh" --uninstall
            rm -rf "$acme_dir"
            print_success "acme.sh 已卸载"
        fi
    fi
}

# =============================================================================
# 显示卸载总结
# =============================================================================

show_summary() {
    print_header "卸载完成"

    echo "已完成以下操作:"
    echo "  ✓ 停止并禁用服务"
    echo "  ✓ 删除服务文件"
    echo "  ✓ 删除二进制文件"
    echo "  ✓ 删除配置文件"

    if [[ "$keep_data" =~ ^[Yy]$ ]]; then
        echo "  ✓ 数据文件已备份"
    else
        echo "  ✓ 删除数据文件"
    fi

    if [[ "$keep_certs" =~ ^[Yy]$ ]]; then
        echo "  ✓ 证书文件已备份"
    fi

    echo "  ✓ 删除日志文件"
    echo ""

    print_success "sing-box 已成功卸载"

    if [[ "$keep_data" =~ ^[Yy]$ || "$keep_certs" =~ ^[Yy]$ ]]; then
        echo ""
        print_info "备份文件保存在 /tmp 目录下，请及时转移"
    fi
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi

    # 确认卸载
    confirm_uninstall

    echo ""
    print_header "开始卸载"

    # 执行卸载步骤
    stop_service
    echo ""

    remove_service
    echo ""

    remove_binary
    echo ""

    remove_config
    echo ""

    remove_data
    echo ""

    remove_logs
    echo ""

    cleanup_firewall
    echo ""

    uninstall_acme
    echo ""

    remove_manager_script
    echo ""

    # 显示总结
    show_summary
}

# 运行主函数
main
