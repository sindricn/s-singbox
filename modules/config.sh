#!/bin/bash

#================================================================
# 配置管理模块
# 功能：查看配置、编辑配置、备份配置、恢复配置、验证配置
#================================================================

# 查看当前配置
show_config() {
    clear
    echo -e "${CYAN}====== 当前配置 ======${NC}\n"

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_error "配置文件不存在"
        return 1
    fi

    # 使用 jq 格式化显示
    if command -v jq &>/dev/null; then
        jq . "$XRAY_CONFIG" | less
    else
        less "$XRAY_CONFIG"
    fi
}

# 编辑配置文件
edit_config() {
    clear
    echo -e "${CYAN}====== 编辑配置 ======${NC}\n"

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_error "配置文件不存在"
        return 1
    fi

    print_warning "编辑前将自动备份配置"

    # 备份
    backup_config

    # 选择编辑器
    local editor=""
    if command -v vim &>/dev/null; then
        editor="vim"
    elif command -v vi &>/dev/null; then
        editor="vi"
    elif command -v nano &>/dev/null; then
        editor="nano"
    else
        print_error "未找到可用的编辑器"
        return 1
    fi

    print_info "使用 $editor 编辑配置"
    "$editor" "$XRAY_CONFIG"

    # 验证配置
    if validate_config; then
        read -p "配置验证通过，是否重启服务使配置生效? [Y/n]: " restart_confirm
        if [[ "$restart_confirm" != "n" && "$restart_confirm" != "N" ]]; then
            restart_xray
        fi
    else
        print_error "配置验证失败，请修正错误"
        read -p "是否恢复备份? [y/N]: " restore_confirm
        if [[ "$restore_confirm" == "y" || "$restore_confirm" == "Y" ]]; then
            restore_config
        fi
    fi
}

# 备份配置
backup_config() {
    local backup_dir="${DATA_DIR}/backups"
    mkdir -p "$backup_dir"

    local backup_file="${backup_dir}/config_$(date +%Y%m%d_%H%M%S).json"

    if [[ -f "$XRAY_CONFIG" ]]; then
        cp "$XRAY_CONFIG" "$backup_file"
        print_success "配置已备份到: $backup_file"

        # 保留最近10个备份
        local backup_count=$(ls -1 "$backup_dir"/config_*.json 2>/dev/null | wc -l)
        if [[ $backup_count -gt 10 ]]; then
            ls -t "$backup_dir"/config_*.json | tail -n +11 | xargs rm -f
            print_info "已清理旧备份文件"
        fi
    else
        print_error "配置文件不存在，无法备份"
        return 1
    fi
}

# 恢复配置
restore_config() {
    clear
    echo -e "${CYAN}====== 恢复配置 ======${NC}\n"

    local backup_dir="${DATA_DIR}/backups"

    if [[ ! -d "$backup_dir" ]]; then
        print_error "备份目录不存在"
        return 1
    fi

    # 列出备份文件
    local backups=$(ls -t "$backup_dir"/config_*.json 2>/dev/null)

    if [[ -z "$backups" ]]; then
        print_error "没有可用的备份"
        return 1
    fi

    echo -e "${CYAN}可用的备份：${NC}"
    local index=1
    declare -A backup_map

    while IFS= read -r backup; do
        local filename=$(basename "$backup")
        local timestamp=$(stat -c %y "$backup" 2>/dev/null | cut -d'.' -f1)
        echo "$index. $filename ($timestamp)"
        backup_map[$index]="$backup"
        ((index++))
    done <<< "$backups"

    echo ""
    read -p "请选择要恢复的备份 [1-$((index-1))]: " choice

    if [[ -z "${backup_map[$choice]}" ]]; then
        print_error "无效选择"
        return 1
    fi

    local selected_backup="${backup_map[$choice]}"

    # 验证备份文件
    if ! jq empty "$selected_backup" 2>/dev/null; then
        print_error "备份文件损坏"
        return 1
    fi

    # 备份当前配置
    if [[ -f "$XRAY_CONFIG" ]]; then
        cp "$XRAY_CONFIG" "${XRAY_CONFIG}.before_restore"
    fi

    # 恢复配置
    cp "$selected_backup" "$XRAY_CONFIG"
    print_success "配置已恢复"

    # 验证并重启
    if validate_config; then
        read -p "配置验证通过，是否重启服务? [Y/n]: " restart_confirm
        if [[ "$restart_confirm" != "n" && "$restart_confirm" != "N" ]]; then
            restart_xray
        fi
    else
        print_error "恢复的配置无效，请检查"
        cp "${XRAY_CONFIG}.before_restore" "$XRAY_CONFIG"
        print_info "已回滚到恢复前的配置"
    fi
}

# 验证配置
validate_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_error "配置文件不存在"
        return 1
    fi

    print_info "正在验证配置..."

    # JSON 语法验证
    if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
        print_error "JSON 格式错误"
        return 1
    fi

    # 使用 xray 内置验证
    if [[ -f "$XRAY_BIN" ]]; then
        if "$XRAY_BIN" test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
            print_success "配置验证通过"
            return 0
        else
            print_error "配置验证失败"
            "$XRAY_BIN" test -config "$XRAY_CONFIG"
            return 1
        fi
    else
        print_warning "Xray 未安装，跳过内置验证"
        return 0
    fi
}

# 导出配置
export_config() {
    clear
    echo -e "${CYAN}====== 导出配置 ======${NC}\n"

    local export_dir="${DATA_DIR}/exports"
    mkdir -p "$export_dir"

    local export_file="${export_dir}/xray_config_$(date +%Y%m%d_%H%M%S).tar.gz"

    print_info "正在导出配置..."

    # 创建临时目录
    local temp_dir=$(mktemp -d)

    # 复制配置文件
    cp "$XRAY_CONFIG" "${temp_dir}/"
    cp "$USERS_FILE" "${temp_dir}/" 2>/dev/null
    cp "$NODES_FILE" "${temp_dir}/" 2>/dev/null

    # 打包
    tar -czf "$export_file" -C "$temp_dir" . 2>/dev/null

    rm -rf "$temp_dir"

    if [[ -f "$export_file" ]]; then
        print_success "配置已导出到: $export_file"
    else
        print_error "导出失败"
        return 1
    fi
}

# 导入配置
import_config() {
    clear
    echo -e "${CYAN}====== 导入配置 ======${NC}\n"

    read -p "请输入配置文件路径: " import_file

    if [[ ! -f "$import_file" ]]; then
        print_error "文件不存在"
        return 1
    fi

    print_warning "导入前将备份当前配置"
    backup_config

    # 检查文件类型
    if [[ "$import_file" == *.tar.gz ]]; then
        # 解压导入
        local temp_dir=$(mktemp -d)
        tar -xzf "$import_file" -C "$temp_dir" 2>/dev/null

        if [[ -f "${temp_dir}/config.json" ]]; then
            cp "${temp_dir}/config.json" "$XRAY_CONFIG"
        fi

        if [[ -f "${temp_dir}/users.json" ]]; then
            cp "${temp_dir}/users.json" "$USERS_FILE"
        fi

        if [[ -f "${temp_dir}/nodes.json" ]]; then
            cp "${temp_dir}/nodes.json" "$NODES_FILE"
        fi

        rm -rf "$temp_dir"

    elif [[ "$import_file" == *.json ]]; then
        # JSON 配置文件
        if jq empty "$import_file" 2>/dev/null; then
            cp "$import_file" "$XRAY_CONFIG"
        else
            print_error "无效的 JSON 文件"
            return 1
        fi
    else
        print_error "不支持的文件格式"
        return 1
    fi

    # 验证并重启
    if validate_config; then
        print_success "配置导入成功"
        read -p "是否重启服务? [Y/n]: " restart_confirm
        if [[ "$restart_confirm" != "n" && "$restart_confirm" != "N" ]]; then
            restart_xray
        fi
    else
        print_error "导入的配置无效"
        restore_config
    fi
}

# 重置配置
reset_config() {
    clear
    echo -e "${CYAN}====== 重置配置 ======${NC}\n"

    print_warning "此操作将删除所有节点和用户配置！"
    read -p "确认重置配置? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消重置"
        return 0
    fi

    # 二次确认
    read -p "再次确认重置配置? 输入 YES 继续: " confirm2
    if [[ "$confirm2" != "YES" ]]; then
        print_info "取消重置"
        return 0
    fi

    # 备份当前配置
    backup_config

    # 创建默认配置
    create_default_config

    # 重置数据文件
    echo '{"users":[]}' > "$USERS_FILE"
    echo '{"nodes":[]}' > "$NODES_FILE"

    restart_xray

    print_success "配置已重置为默认值"
}

# 配置优化建议
config_suggestions() {
    clear
    echo -e "${CYAN}====== 配置优化建议 ======${NC}\n"

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_error "配置文件不存在"
        return 1
    fi

    echo -e "${CYAN}正在分析配置...${NC}\n"

    # 检查日志配置
    local log_level=$(jq -r '.log.loglevel // "none"' "$XRAY_CONFIG")
    if [[ "$log_level" == "debug" ]]; then
        echo -e "${YELLOW}建议：${NC}日志级别为 debug，生产环境建议使用 warning"
    fi

    # 检查 stats 配置
    local has_stats=$(jq -r '.stats // {} | length' "$XRAY_CONFIG")
    if [[ "$has_stats" -eq 0 ]]; then
        echo -e "${YELLOW}建议：${NC}未启用流量统计，无法查看流量信息"
    fi

    # 检查 sniffing 配置
    local inbounds=$(jq -r '.inbounds[] | select(.sniffing.enabled != true) | .port' "$XRAY_CONFIG" 2>/dev/null)
    if [[ -n "$inbounds" ]]; then
        echo -e "${YELLOW}建议：${NC}以下端口未启用流量嗅探：$inbounds"
    fi

    # 检查 routing 规则
    local routing_rules=$(jq -r '.routing.rules // [] | length' "$XRAY_CONFIG")
    if [[ "$routing_rules" -lt 2 ]]; then
        echo -e "${YELLOW}建议：${NC}路由规则较少，可能需要添加更多分流规则"
    fi

    echo ""
    print_info "优化建议分析完成"
}
