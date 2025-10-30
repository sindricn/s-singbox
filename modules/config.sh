#!/bin/bash

# =============================================================================
# config.sh - 配置管理基础模块
# 提供配置文件路径管理、备份恢复等功能
# =============================================================================

# 依赖检查
if [[ -z "${SCRIPT_DIR}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if ! declare -f print_error &>/dev/null; then
    source "${SCRIPT_DIR}/modules/common.sh"
fi

# =============================================================================
# 配置路径
# =============================================================================

# sing-box 配置目录
SINGBOX_CONFIG_DIR="${SINGBOX_CONFIG_DIR:-/usr/local/singbox}"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config.json"

# 备份目录
CONFIG_BACKUP_DIR="${SINGBOX_CONFIG_DIR}/backups"

# 最大备份数量
MAX_CONFIG_BACKUPS=10

# =============================================================================
# 路径管理
# =============================================================================

get_config_dir() {
    echo "$SINGBOX_CONFIG_DIR"
}

get_config_file() {
    echo "$SINGBOX_CONFIG_FILE"
}

get_backup_dir() {
    echo "$CONFIG_BACKUP_DIR"
}

ensure_config_dir() {
    ensure_dir "$SINGBOX_CONFIG_DIR"
    ensure_dir "$CONFIG_BACKUP_DIR"
}

# =============================================================================
# 配置文件检查
# =============================================================================

config_exists() {
    [[ -f "$SINGBOX_CONFIG_FILE" ]]
}

config_is_valid() {
    if ! config_exists; then
        return 1
    fi

    # 验证 JSON 格式
    if ! jq empty "$SINGBOX_CONFIG_FILE" 2>/dev/null; then
        return 1
    fi

    return 0
}

# =============================================================================
# 配置备份
# =============================================================================

backup_config() {
    local description=${1:-"manual"}

    if ! config_exists; then
        log_warn "配置文件不存在，无需备份"
        return 0
    fi

    ensure_config_dir

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${CONFIG_BACKUP_DIR}/config.${timestamp}.${description}.bak"

    if cp "$SINGBOX_CONFIG_FILE" "$backup_file"; then
        log_success "配置已备份: $backup_file"

        # 清理旧备份
        cleanup_old_config_backups

        echo "$backup_file"
        return 0
    else
        log_error "配置备份失败"
        return 1
    fi
}

# =============================================================================
# 清理旧备份
# =============================================================================

cleanup_old_config_backups() {
    local backups=($(ls -t "${CONFIG_BACKUP_DIR}"/config.*.bak 2>/dev/null))

    if [[ ${#backups[@]} -gt $MAX_CONFIG_BACKUPS ]]; then
        local to_delete=("${backups[@]:$MAX_CONFIG_BACKUPS}")

        for file in "${to_delete[@]}"; do
            rm -f "$file"
            log_debug "删除旧备份: $file"
        done
    fi
}

# =============================================================================
# 配置恢复
# =============================================================================

restore_config() {
    local backup_file=$1

    if [[ -z "$backup_file" ]]; then
        # 如果没有指定备份文件，使用最新的
        backup_file=$(ls -t "${CONFIG_BACKUP_DIR}"/config.*.bak 2>/dev/null | head -1)

        if [[ -z "$backup_file" ]]; then
            log_error "没有可用的备份文件"
            return 1
        fi

        log_info "使用最新备份: $backup_file"
    fi

    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi

    # 验证备份文件
    if ! jq empty "$backup_file" 2>/dev/null; then
        log_error "备份文件格式无效"
        return 1
    fi

    # 备份当前配置（如果存在）
    if config_exists; then
        local current_backup="${CONFIG_BACKUP_DIR}/config.before_restore.$(date +%Y%m%d_%H%M%S).bak"
        cp "$SINGBOX_CONFIG_FILE" "$current_backup"
        log_info "当前配置已保存: $current_backup"
    fi

    # 恢复配置
    if cp "$backup_file" "$SINGBOX_CONFIG_FILE"; then
        log_success "配置已恢复: $backup_file"
        return 0
    else
        log_error "配置恢复失败"
        return 1
    fi
}

# =============================================================================
# 列出备份
# =============================================================================

list_config_backups() {
    local backups=($(ls -t "${CONFIG_BACKUP_DIR}"/config.*.bak 2>/dev/null))

    if [[ ${#backups[@]} -eq 0 ]]; then
        print_info "没有可用的备份"
        return 0
    fi

    print_header "配置备份列表"

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
# 配置导出
# =============================================================================

export_config() {
    local export_path=$1

    if [[ -z "$export_path" ]]; then
        export_path="${HOME}/singbox-config-$(date +%Y%m%d_%H%M%S).json"
    fi

    if ! config_exists; then
        log_error "配置文件不存在"
        return 1
    fi

    if cp "$SINGBOX_CONFIG_FILE" "$export_path"; then
        log_success "配置已导出: $export_path"
        echo "$export_path"
        return 0
    else
        log_error "配置导出失败"
        return 1
    fi
}

# =============================================================================
# 配置导入
# =============================================================================

import_config() {
    local import_path=$1

    if [[ ! -f "$import_path" ]]; then
        log_error "导入文件不存在: $import_path"
        return 1
    fi

    # 验证导入文件
    if ! jq empty "$import_path" 2>/dev/null; then
        log_error "导入文件格式无效"
        return 1
    fi

    # 备份当前配置
    if config_exists; then
        backup_config "before_import"
    fi

    # 导入配置
    ensure_config_dir

    if cp "$import_path" "$SINGBOX_CONFIG_FILE"; then
        log_success "配置已导入: $import_path"
        return 0
    else
        log_error "配置导入失败"
        return 1
    fi
}

# =============================================================================
# 配置验证
# =============================================================================

validate_config() {
    if ! config_exists; then
        log_error "配置文件不存在"
        return 1
    fi

    # JSON 格式验证
    if ! jq empty "$SINGBOX_CONFIG_FILE" 2>/dev/null; then
        log_error "配置文件 JSON 格式无效"
        return 1
    fi

    # sing-box 配置验证
    if command -v sing-box &>/dev/null; then
        if sing-box check -c "$SINGBOX_CONFIG_FILE" 2>/dev/null; then
            log_success "配置文件验证通过"
            return 0
        else
            log_error "sing-box 配置验证失败"
            return 1
        fi
    else
        log_warn "sing-box 未安装，跳过配置验证"
        return 0
    fi
}

# =============================================================================
# 配置信息
# =============================================================================

show_config_info() {
    print_header "配置信息"

    # 配置文件路径
    echo -e "${CYAN}配置文件:${NC} $SINGBOX_CONFIG_FILE"

    # 配置文件大小
    if config_exists; then
        local size=$(du -h "$SINGBOX_CONFIG_FILE" | cut -f1)
        echo -e "${CYAN}文件大小:${NC} $size"

        # 最后修改时间
        local mtime=$(stat -c %y "$SINGBOX_CONFIG_FILE" 2>/dev/null || stat -f "%Sm" "$SINGBOX_CONFIG_FILE")
        echo -e "${CYAN}修改时间:${NC} $mtime"

        # 配置验证
        echo -e -n "${CYAN}配置状态:${NC} "
        if config_is_valid; then
            echo -e "${GREEN}有效${NC}"
        else
            echo -e "${RED}无效${NC}"
        fi
    else
        echo -e "${CYAN}状态:${NC} ${YELLOW}不存在${NC}"
    fi

    # 备份信息
    local backups=($(ls -t "${CONFIG_BACKUP_DIR}"/config.*.bak 2>/dev/null))
    echo -e "${CYAN}备份数量:${NC} ${#backups[@]}"

    if [[ ${#backups[@]} -gt 0 ]]; then
        local latest_backup=$(basename "${backups[0]}")
        echo -e "${CYAN}最新备份:${NC} $latest_backup"
    fi

    echo ""
}

# =============================================================================
# 配置重置
# =============================================================================

reset_config() {
    if ! confirm "确认重置配置文件（将删除现有配置）"; then
        log_info "取消重置"
        return 0
    fi

    # 备份现有配置
    if config_exists; then
        backup_config "before_reset"
    fi

    # 删除配置文件
    if [[ -f "$SINGBOX_CONFIG_FILE" ]]; then
        rm -f "$SINGBOX_CONFIG_FILE"
        log_info "配置文件已删除"
    fi

    log_success "配置已重置"
}

# =============================================================================
# 配置差异比较
# =============================================================================

diff_config() {
    local file1=$1
    local file2=${2:-$SINGBOX_CONFIG_FILE}

    if [[ ! -f "$file1" ]]; then
        log_error "文件不存在: $file1"
        return 1
    fi

    if [[ ! -f "$file2" ]]; then
        log_error "文件不存在: $file2"
        return 1
    fi

    # 使用 diff 或 jq 比较
    if command -v diff &>/dev/null; then
        diff -u "$file1" "$file2"
    else
        log_warn "diff 命令不可用，使用简单比较"
        if cmp -s "$file1" "$file2"; then
            echo "文件相同"
        else
            echo "文件不同"
        fi
    fi
}

# =============================================================================
# 模块初始化
# =============================================================================

# 确保配置目录存在
ensure_config_dir

log_debug "config.sh 模块已加载"
