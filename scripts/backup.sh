#!/bin/bash

# =============================================================================

umask 077
# backup.sh - 配置和数据备份脚本
# 备份所有配置、数据文件，并支持恢复
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载模块
source "${SCRIPT_DIR}/modules/common.sh"

# =============================================================================
# 配置
# =============================================================================

# 使用官方标准路径
readonly SINGBOX_CONFIG_DIR="/etc/sing-box"
readonly SINGBOX_DATA_DIR="/var/lib/sing-box"

BACKUP_ROOT_DIR="${SCRIPT_DIR}/backups"
MAX_BACKUPS=10

backup_archive_is_safe() {
    local archive="$1" member type
    while IFS= read -r member; do
        member="${member#./}"
        [[ -z "$member" ]] && continue
        if [[ "$member" == /* || "$member" =~ ^[A-Za-z]: || "$member" =~ (^|/)\.\.(/|$) ]]; then
            return 1
        fi
    done < <(tar -tzf "$archive" 2>/dev/null) || return 1
    while IFS= read -r type; do
        [[ "$type" == "-" || "$type" == "d" ]] || return 1
    done < <(tar -tvzf "$archive" 2>/dev/null | cut -c1) || return 1
}

backup_file_is_managed() {
    local root target
    root=$(realpath -m "$BACKUP_ROOT_DIR") || return 1
    target=$(realpath -m "$1") || return 1
    [[ "$target" == "$root"/*.tar.gz ]]
}

# =============================================================================
# 创建备份
# =============================================================================

create_backup() {
    local description=${1:-"manual"}
    description=$(printf '%s' "$description" | tr -cd 'A-Za-z0-9._-')
    description=${description:-manual}

    print_header "创建备份"

    # 创建备份目录
    local timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_ROOT_DIR" || return 1
    local backup_dir
    backup_dir=$(mktemp -d "${BACKUP_ROOT_DIR}/${timestamp}_${description}_XXXXXX") || return 1
    log_info "备份目录: $backup_dir"

    # 备份数据文件
    if [[ -d "$SINGBOX_DATA_DIR" ]]; then
        log_info "备份数据文件..."
        cp -a "$SINGBOX_DATA_DIR" "${backup_dir}/data" || { rm -rf -- "$backup_dir"; return 1; }
        check_item "数据文件" "ok"
    fi

    # 备份 sing-box 配置
    if [[ -f ${SINGBOX_CONFIG_DIR}/config.json ]]; then
        log_info "备份 sing-box 配置..."
        mkdir -p "${backup_dir}/singbox"
        cp -- "${SINGBOX_CONFIG_DIR}/config.json" "${backup_dir}/singbox/" || { rm -rf -- "$backup_dir"; return 1; }
        check_item "sing-box 配置" "ok"
    fi

    # 备份证书（如果存在）
    if [[ -d ${SINGBOX_CONFIG_DIR}/certs ]]; then
        log_info "备份证书..."
        cp -a "${SINGBOX_CONFIG_DIR}/certs" "${backup_dir}/singbox/" || { rm -rf -- "$backup_dir"; return 1; }
        check_item "证书文件" "ok"
    fi

    # 创建备份信息文件
    cat > "${backup_dir}/backup_info.txt" <<EOF
备份信息
========================================
创建时间: $(date)
描述: $description
主机名: $(hostname)
操作系统: $(uname -a)
========================================

备份内容:
EOF

    find "$backup_dir" -type f | sed "s|${backup_dir}/||" >> "${backup_dir}/backup_info.txt"

    # 压缩备份
    log_info "压缩备份..."
    local archive_file="${backup_dir}.tar.gz"

    if tar -czf "$archive_file" -C "$BACKUP_ROOT_DIR" "$(basename "$backup_dir")"; then
        log_success "备份已压缩: $archive_file"

        # 删除临时目录
        rm -rf -- "$backup_dir"
        chmod 600 "$archive_file"

        # 清理旧备份
        cleanup_old_backups

        log_success "备份完成"
        echo "$archive_file"
        return 0
    else
        log_error "压缩失败"
        return 1
    fi
}

check_item() {
    local item=$1
    local result=$2

    if [[ "$result" == "ok" ]]; then
        echo -e "  ${GREEN}✓${NC} $item"
    else
        echo -e "  ${RED}✗${NC} $item"
    fi
}

# =============================================================================
# 清理旧备份
# =============================================================================

cleanup_old_backups() {
    local backups=()
    mapfile -t backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    if [[ ${#backups[@]} -gt $MAX_BACKUPS ]]; then
        log_info "清理旧备份..."

        local to_delete=("${backups[@]:$MAX_BACKUPS}")

        for file in "${to_delete[@]}"; do
            rm -f "$file"
        done

        log_info "已删除 ${#to_delete[@]} 个旧备份"
    fi
}

# =============================================================================
# 列出备份
# =============================================================================

list_backups() {
    print_header "备份列表"

    local backups=()
    mapfile -t backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    if [[ ${#backups[@]} -eq 0 ]]; then
        print_info "没有可用的备份"
        return 0
    fi

    local index=1
    for backup in "${backups[@]}"; do
        local filename=$(basename "$backup")
        local size=$(du -h "$backup" | cut -f1)
        local date=$(stat -c %y "$backup" 2>/dev/null || stat -f "%Sm" "$backup")

        echo -e "${CYAN}[$index]${NC} $filename"
        echo -e "    大小: $size"
        echo -e "    时间: $date"
        echo ""

        ((index++))
    done
}

# =============================================================================
# 恢复备份
# =============================================================================

restore_backup() {
    local backup_file=$1

    if [[ -z "$backup_file" ]]; then
        # 列出可用备份
        list_backups

        # 让用户选择
        read -p "$(echo -e ${CYAN}选择要恢复的备份编号:${NC} )" -r choice

        local backups=()
        mapfile -t backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

        if [[ $choice -ge 1 ]] && [[ $choice -le ${#backups[@]} ]]; then
            backup_file="${backups[$((choice-1))]}"
        else
            log_error "无效的选择"
            return 1
        fi
    fi

    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi

    print_header "恢复备份"

    log_warn "即将恢复备份: $(basename "$backup_file")"
    log_warn "当前配置和数据将被覆盖！"

    if ! confirm "确认恢复"; then
        log_info "取消恢复"
        return 0
    fi

    # 创建当前配置的备份
    log_info "备份当前配置..."
    create_backup "before_restore" &>/dev/null

    if ! backup_archive_is_safe "$backup_file"; then
        log_error "备份归档包含不安全路径、链接或已损坏"
        return 1
    fi

    # 解压备份
    local temp_dir
    temp_dir=$(mktemp -d /tmp/singbox_restore_XXXXXX) || return 1

    log_info "解压备份..."
    if ! tar -xzf "$backup_file" -C "$temp_dir" --no-same-owner --no-same-permissions; then
        log_error "解压失败"
        rm -rf -- "$temp_dir"
        return 1
    fi

    # 找到解压的目录
    local extracted_dir
    extracted_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
    if [[ -z "$extracted_dir" || ! -f "${extracted_dir}/backup_info.txt" ]]; then
        rm -rf -- "$temp_dir"
        log_error "备份结构无效"
        return 1
    fi

    if [[ -f "${extracted_dir}/singbox/config.json" ]] && ! jq -e 'type == "object"' "${extracted_dir}/singbox/config.json" >/dev/null 2>&1; then
        rm -rf -- "$temp_dir"
        log_error "备份中的 sing-box 配置无效"
        return 1
    fi
    if [[ -f "${extracted_dir}/singbox/config.json" ]] && command -v sing-box >/dev/null 2>&1 \
        && ! sing-box check -c "${extracted_dir}/singbox/config.json" >/dev/null 2>&1; then
        rm -rf -- "$temp_dir"
        log_error "备份中的 sing-box 配置未通过内核校验"
        return 1
    fi
    if [[ -d "${extracted_dir}/data" ]]; then
        while IFS= read -r -d '' json_file; do
            if ! jq -e . "$json_file" >/dev/null 2>&1; then
                rm -rf -- "$temp_dir"
                log_error "备份包含无效 JSON: $(basename "$json_file")"
                return 1
            fi
        done < <(find "${extracted_dir}/data" -type f -name '*.json' -print0)
    fi

    local rollback_dir
    rollback_dir=$(mktemp -d /tmp/singbox_restore_rollback_XXXXXX) || { rm -rf -- "$temp_dir"; return 1; }
    [[ ! -d "$SINGBOX_DATA_DIR" ]] || cp -a "$SINGBOX_DATA_DIR" "${rollback_dir}/data"
    [[ ! -d "$SINGBOX_CONFIG_DIR" ]] || cp -a "$SINGBOX_CONFIG_DIR" "${rollback_dir}/singbox"

    # 恢复数据文件
    if [[ -d "${extracted_dir}/data" ]]; then
        log_info "恢复数据文件..."
        rm -rf -- "$SINGBOX_DATA_DIR"
        cp -a "${extracted_dir}/data" "$SINGBOX_DATA_DIR" || {
            rm -rf -- "$SINGBOX_DATA_DIR"; [[ ! -d "${rollback_dir}/data" ]] || cp -a "${rollback_dir}/data" "$SINGBOX_DATA_DIR"
            rm -rf -- "$temp_dir" "$rollback_dir"; return 1
        }
        check_item "数据文件" "ok"
    fi

    # 恢复 sing-box 配置
    if [[ -f "${extracted_dir}/singbox/config.json" ]]; then
        log_info "恢复 sing-box 配置..."
        mkdir -p "${SINGBOX_CONFIG_DIR}"
        cp -- "${extracted_dir}/singbox/config.json" "${SINGBOX_CONFIG_DIR}/config.json" || {
            rm -rf -- "$SINGBOX_DATA_DIR" "$SINGBOX_CONFIG_DIR"
            [[ ! -d "${rollback_dir}/data" ]] || cp -a "${rollback_dir}/data" "$SINGBOX_DATA_DIR"
            [[ ! -d "${rollback_dir}/singbox" ]] || cp -a "${rollback_dir}/singbox" "$SINGBOX_CONFIG_DIR"
            rm -rf -- "$temp_dir" "$rollback_dir"; return 1
        }
        check_item "sing-box 配置" "ok"
    fi

    # 恢复证书
    if [[ -d "${extracted_dir}/singbox/certs" ]]; then
        log_info "恢复证书..."
        rm -rf -- "${SINGBOX_CONFIG_DIR}/certs"
        cp -a "${extracted_dir}/singbox/certs" "${SINGBOX_CONFIG_DIR}/" || {
            rm -rf -- "$SINGBOX_DATA_DIR" "$SINGBOX_CONFIG_DIR"
            [[ ! -d "${rollback_dir}/data" ]] || cp -a "${rollback_dir}/data" "$SINGBOX_DATA_DIR"
            [[ ! -d "${rollback_dir}/singbox" ]] || cp -a "${rollback_dir}/singbox" "$SINGBOX_CONFIG_DIR"
            rm -rf -- "$temp_dir" "$rollback_dir"; return 1
        }
        check_item "证书文件" "ok"
    fi

    # 清理临时文件
    # 重启服务
    if systemctl is-active sing-box &>/dev/null; then
        log_info "重启服务..."
        if ! systemctl restart sing-box; then
            log_error "恢复后的服务启动失败，正在回滚"
            rm -rf -- "$SINGBOX_DATA_DIR" "$SINGBOX_CONFIG_DIR"
            [[ ! -d "${rollback_dir}/data" ]] || cp -a "${rollback_dir}/data" "$SINGBOX_DATA_DIR"
            [[ ! -d "${rollback_dir}/singbox" ]] || cp -a "${rollback_dir}/singbox" "$SINGBOX_CONFIG_DIR"
            systemctl restart sing-box >/dev/null 2>&1 || true
            rm -rf -- "$temp_dir" "$rollback_dir"
            return 1
        fi
    fi

    rm -rf -- "$temp_dir" "$rollback_dir"

    log_success "恢复完成"
}

# =============================================================================
# 删除备份
# =============================================================================

delete_backup() {
    local backup_file=$1

    if [[ -z "$backup_file" ]]; then
        list_backups

        read -p "$(echo -e ${CYAN}选择要删除的备份编号:${NC} )" -r choice

        local backups=()
        mapfile -t backups < <(find "$BACKUP_ROOT_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

        if [[ $choice -ge 1 ]] && [[ $choice -le ${#backups[@]} ]]; then
            backup_file="${backups[$((choice-1))]}"
        else
            log_error "无效的选择"
            return 1
        fi
    fi

    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi
    if ! backup_file_is_managed "$backup_file"; then
        log_error "只能删除备份目录中的 .tar.gz 文件"
        return 1
    fi

    log_warn "即将删除备份: $(basename "$backup_file")"

    if confirm "确认删除"; then
        rm -f "$backup_file"
        log_success "备份已删除"
    else
        log_info "取消删除"
    fi
}

# =============================================================================
# 主菜单
# =============================================================================

show_menu() {
    print_header "s-singbox 备份管理"

    echo "1. 创建备份"
    echo "2. 列出备份"
    echo "3. 恢复备份"
    echo "4. 删除备份"
    echo "5. 退出"
    echo ""

    read -p "$(echo -e ${CYAN}请选择:${NC} )" -r choice

    case $choice in
        1)
            read -p "$(echo -e ${CYAN}备份描述 [manual]:${NC} )" -r desc
            desc=${desc:-manual}
            create_backup "$desc"
            ;;
        2)
            list_backups
            ;;
        3)
            restore_backup
            ;;
        4)
            delete_backup
            ;;
        5)
            exit 0
            ;;
        *)
            log_error "无效的选择"
            ;;
    esac

    echo ""
    read -p "$(echo -e ${CYAN}按回车键继续...${NC})"
    show_menu
}

# =============================================================================
# 命令行参数处理
# =============================================================================

if [[ $# -eq 0 ]]; then
    # 无参数，显示菜单
    show_menu
else
    # 有参数，执行对应命令
    case $1 in
        create|backup)
            create_backup "${2:-manual}"
            ;;
        list)
            list_backups
            ;;
        restore)
            restore_backup "$2"
            ;;
        delete)
            delete_backup "$2"
            ;;
        *)
            echo "用法: $0 {create|list|restore|delete} [参数]"
            exit 1
            ;;
    esac
fi
