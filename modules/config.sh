#!/bin/bash

#================================================================
# 配置管理模块
# 功能：查看配置、编辑配置、备份配置、恢复配置、验证配置
#================================================================

archive_members_are_safe() {
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

# 激活待验证配置但暂不提交数据事务，供还需要执行防火墙等后置步骤的流程使用。
activate_singbox_pending_transaction() {
    systemctl restart sing-box >/dev/null 2>&1 || return 1
    sleep 2
    systemctl is-active --quiet sing-box
}

# 清理所有Hysteria2端口跳跃的iptables规则
cleanup_all_port_hopping_rules() {
    local nodes_source="${1:-$NODES_FILE}"
    if [[ ! -f "$nodes_source" ]]; then
        return 0
    fi

    local hy2_nodes=$(jq -r '.nodes[] | select(.protocol == "hysteria2") | select(.extra.port_hopping != null and .extra.port_hopping != "") | "\(.port)|\(.extra.port_hopping)"' "$nodes_source" 2>/dev/null)

    if [[ -z "$hy2_nodes" ]]; then
        return 0
    fi

    local failed=0
    while IFS='|' read -r port port_hopping; do
        [[ -z "$port" || -z "$port_hopping" ]] && continue
        echo "  清理端口 $port 的跳跃规则: $port_hopping"

        # 调用清理函数（如果存在）
        if declare -f cleanup_port_hopping_rules >/dev/null 2>&1; then
            cleanup_port_hopping_rules "$port" "$port_hopping" || failed=1
        else
            # 手动清理
            local start_port=$(echo "$port_hopping" | cut -d':' -f1)
            local end_port=$(echo "$port_hopping" | cut -d':' -f2)
            local main_interface=$(ip route | grep default | head -n1 | awk '{print $5}')
            [[ -z "$main_interface" ]] && main_interface="eth0"

            iptables -t nat -D PREROUTING -i "$main_interface" -p udp --dport "${start_port}:${end_port}" -j REDIRECT --to-ports "$port" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -i "$main_interface" -p udp --dport "${start_port}:${end_port}" -j REDIRECT --to-ports "$port" 2>/dev/null || true
        fi
    done <<< "$hy2_nodes"

    return "$failed"
}

restore_port_hopping_rules_from_nodes_file() {
    local nodes_source="$1" port port_hopping
    [[ -f "$nodes_source" ]] || return 0
    declare -f apply_port_hopping_rules >/dev/null 2>&1 || return 1
    while IFS='|' read -r port port_hopping; do
        [[ -n "$port" && -n "$port_hopping" ]] || continue
        apply_port_hopping_rules "$port" "$port_hopping" || return 1
    done < <(jq -r '.nodes[] | select(.protocol == "hysteria2") | select(.extra.port_hopping != null and .extra.port_hopping != "") | "\(.port)|\(.extra.port_hopping)"' "$nodes_source" 2>/dev/null)
}

# 查看当前配置
show_config() {
    clear
    echo -e "${CYAN}====== 当前配置 ======${NC}\n"

    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        print_error "配置文件不存在"
        return 1
    fi

    # 使用 jq 格式化显示
    if command -v jq &>/dev/null; then
        jq . "$SINGBOX_CONFIG" | less
    else
        less "$SINGBOX_CONFIG"
    fi
}

# 编辑配置文件
edit_config() {
    clear
    echo -e "${CYAN}====== 编辑配置 ======${NC}\n"

    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
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
    "$editor" "$SINGBOX_CONFIG"

    # 验证配置
    if validate_config; then
        read -p "配置验证通过，是否重启服务使配置生效? [Y/n]: " restart_confirm
        if [[ "$restart_confirm" != "n" && "$restart_confirm" != "N" ]]; then
            restart_sing-box
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

    if [[ -f "$SINGBOX_CONFIG" ]]; then
        cp "$SINGBOX_CONFIG" "$backup_file"
        print_success "配置已备份到: $backup_file"

        # 保留最近10个备份
        local backups=()
        mapfile -t backups < <(find "$backup_dir" -maxdepth 1 -type f -name 'config_*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
        if [[ ${#backups[@]} -gt 10 ]]; then
            local old_backups=("${backups[@]:10}")
            rm -f -- "${old_backups[@]}"
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
    if [[ -f "$SINGBOX_CONFIG" ]]; then
        cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.before_restore"
    fi

    # 恢复配置
    cp "$selected_backup" "$SINGBOX_CONFIG"
    print_success "配置已恢复"

    # 验证并重启
    if validate_config; then
        read -p "配置验证通过，是否重启服务? [Y/n]: " restart_confirm
        if [[ "$restart_confirm" != "n" && "$restart_confirm" != "N" ]]; then
            restart_sing-box
        fi
    else
        print_error "恢复的配置无效，请检查"
        cp "${SINGBOX_CONFIG}.before_restore" "$SINGBOX_CONFIG"
        print_info "已回滚到恢复前的配置"
    fi
}

# 验证配置
validate_config() {
    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        print_error "配置文件不存在"
        return 1
    fi

    print_info "正在验证配置..."

    # JSON 语法验证
    if ! jq empty "$SINGBOX_CONFIG" 2>/dev/null; then
        print_error "JSON 格式错误"
        return 1
    fi

    # 使用 sing-box 内置验证
    if command -v sing-box &>/dev/null; then
        if sing-box check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then
            print_success "配置验证通过"
            return 0
        else
            print_error "配置验证失败"
            sing-box check -c "$SINGBOX_CONFIG"
            return 1
        fi
    else
        print_warning "sing-box 未安装，跳过内置验证"
        return 0
    fi
}

# 导出配置
export_config() {
    clear
    echo -e "${CYAN}====== 导出配置 ======${NC}\n"

    local export_dir="${DATA_DIR}/exports"
    mkdir -p "$export_dir"

    local export_file="${export_dir}/singbox_config_$(date +%Y%m%d_%H%M%S).tar.gz"

    print_info "正在导出配置..."

    # 创建临时目录
    local temp_dir=$(mktemp -d)

    if [[ ! -f "$SINGBOX_CONFIG" ]] || ! cp -- "$SINGBOX_CONFIG" "${temp_dir}/config.json"; then
        rm -rf -- "$temp_dir"
        print_error "主配置不存在或无法复制"
        return 1
    fi

    local data_file
    for data_file in users.json nodes.json node_users.json outbounds.json traffic_counters.json \
        subscriptions.json subscription_metadata.json port_hopping.json domains.json; do
        [[ ! -f "${DATA_DIR}/${data_file}" ]] || cp -- "${DATA_DIR}/${data_file}" "${temp_dir}/${data_file}" || {
            rm -rf -- "$temp_dir"
            print_error "复制数据文件失败: $data_file"
            return 1
        }
    done
    if [[ -d "$SUBSCRIPTION_DIR" ]]; then
        mkdir -p "${temp_dir}/subscriptions"
        cp -a "$SUBSCRIPTION_DIR/." "${temp_dir}/subscriptions/" || {
            rm -rf -- "$temp_dir"
            print_error "复制订阅文件失败"
            return 1
        }
    fi

    # 打包
    if ! tar -czf "$export_file" -C "$temp_dir" . 2>/dev/null; then
        rm -rf -- "$temp_dir"
        print_error "导出打包失败"
        return 1
    fi

    rm -rf -- "$temp_dir"
    chmod 600 "$export_file" 2>/dev/null || true

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

    print_warning "导入将以事务方式替换现有配置和数据"
    begin_data_transaction || return 1

    local temp_dir=""
    if [[ "$import_file" == *.tar.gz ]]; then
        if ! archive_members_are_safe "$import_file"; then
            print_error "归档包含绝对路径、上级路径、链接或损坏成员，拒绝导入"
            rollback_data_transaction
            return 1
        fi
        temp_dir=$(mktemp -d) || { rollback_data_transaction; return 1; }
        if ! tar -xzf "$import_file" -C "$temp_dir" --no-same-owner --no-same-permissions; then
            rm -rf -- "$temp_dir"
            rollback_data_transaction
            print_error "解压导入文件失败"
            return 1
        fi

        [[ -f "${temp_dir}/config.json" ]] || {
            rm -rf -- "$temp_dir"; rollback_data_transaction
            print_error "归档缺少 config.json"; return 1
        }

        local spec filename root_key
        for spec in 'users.json|users' 'nodes.json|nodes' 'node_users.json|bindings' \
            'outbounds.json|outbounds' 'traffic_counters.json|users' 'subscriptions.json|subscriptions' \
            'subscription_metadata.json|subscriptions' 'port_hopping.json|configs' 'domains.json|domains'; do
            IFS='|' read -r filename root_key <<< "$spec"
            [[ ! -f "${temp_dir}/${filename}" ]] || jq -e --arg key "$root_key" \
                'type == "object" and has($key)' "${temp_dir}/${filename}" >/dev/null 2>&1 || {
                rm -rf -- "$temp_dir"; rollback_data_transaction
                print_error "导入数据结构无效: $filename"; return 1
            }
        done
        jq -e 'type == "object"' "${temp_dir}/config.json" >/dev/null 2>&1 || {
            rm -rf -- "$temp_dir"; rollback_data_transaction
            print_error "config.json 不是有效对象"; return 1
        }

        cp -- "${temp_dir}/config.json" "$SINGBOX_CONFIG" || { rm -rf -- "$temp_dir"; rollback_data_transaction; return 1; }
        for filename in users.json nodes.json node_users.json outbounds.json traffic_counters.json \
            subscriptions.json subscription_metadata.json port_hopping.json domains.json; do
            [[ ! -f "${temp_dir}/${filename}" ]] || cp -- "${temp_dir}/${filename}" "${DATA_DIR}/${filename}" || {
                rm -rf -- "$temp_dir"; rollback_data_transaction; return 1
            }
        done
        if [[ -d "${temp_dir}/subscriptions" ]]; then
            rm -rf -- "$SUBSCRIPTION_DIR"
            mkdir -p "$SUBSCRIPTION_DIR" || { rm -rf -- "$temp_dir"; rollback_data_transaction; return 1; }
            cp -a "${temp_dir}/subscriptions/." "$SUBSCRIPTION_DIR/" || { rm -rf -- "$temp_dir"; rollback_data_transaction; return 1; }
        fi
    elif [[ "$import_file" == *.json ]]; then
        if ! jq -e 'type == "object"' "$import_file" >/dev/null 2>&1 || ! cp -- "$import_file" "$SINGBOX_CONFIG"; then
            rollback_data_transaction
            print_error "无效的 JSON 配置文件"
            return 1
        fi
    else
        rollback_data_transaction
        print_error "不支持的文件格式"
        return 1
    fi

    if ! validate_config; then
        [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
        rollback_data_transaction
        print_error "导入的配置无效，已恢复原数据"
        return 1
    fi

    read -p "是否立即重启服务应用导入? [Y/n]: " restart_confirm
    if [[ "$restart_confirm" != "n" && "$restart_confirm" != "N" ]]; then
        if ! activate_singbox_pending_transaction; then
            [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
            rollback_data_transaction
            systemctl restart sing-box >/dev/null 2>&1 || true
            print_error "服务启动失败，导入已回滚"
            return 1
        fi
    fi
    if ! commit_data_transaction; then
        [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
        rollback_data_transaction
        print_error "导入快照提交失败，已回滚"
        return 1
    fi
    [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir"
    chmod 600 "$DATA_DIR"/*.json "$SINGBOX_CONFIG" 2>/dev/null || true
    print_success "配置导入成功"
}

# 重置用户数据
reset_users() {
    clear
    echo -e "${CYAN}====== 重置用户数据 ======${NC}\n"

    print_warning "此操作将删除所有用户数据和绑定关系！"
    echo -e "${YELLOW}节点配置将被保留${NC}"
    echo ""
    read -p "确认重置用户数据? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消重置"
        return 0
    fi

    # 二次确认
    read -p "再次确认? 输入 YES 继续: " confirm2
    if [[ "$confirm2" != "YES" ]]; then
        print_info "取消重置"
        return 0
    fi

    begin_data_transaction || return 1
    printf '%s\n' '{"users":[]}' > "$USERS_FILE" \
        && printf '%s\n' '{"bindings":[]}' > "$NODE_USERS_FILE" \
        && printf '%s\n' '{"subscriptions":[]}' > "${DATA_DIR}/subscriptions.json" \
        && printf '%s\n' '{"subscriptions":[]}' > "${DATA_DIR}/subscription_metadata.json" \
        && printf '%s\n' '{"users":{}}' > "${DATA_DIR}/traffic_counters.json" || {
        rollback_data_transaction; print_error "重置用户数据写入失败"; return 1
    }
    find "$SUBSCRIPTION_DIR" -mindepth 1 -maxdepth 1 -delete 2>/dev/null || {
        rollback_data_transaction; print_error "清理订阅文件失败"; return 1
    }
    if ! declare -f init_admin_user >/dev/null 2>&1 || ! init_admin_user; then
        rollback_data_transaction; print_error "重新创建 admin 用户失败"; return 1
    fi
    local admin_id
    admin_id=$(jq -r '.users[] | select(.username == "admin") | .id' "$USERS_FILE" 2>/dev/null | head -1)
    if [[ -z "$admin_id" ]] || ! jq --arg user "$admin_id" \
        '{bindings:[.nodes[] | select(.port != null) | {port:(.port|tostring),protocol:(.protocol // "unknown"),users:[$user]}]}' \
        "$NODES_FILE" > "${NODE_USERS_FILE}.tmp" || ! mv "${NODE_USERS_FILE}.tmp" "$NODE_USERS_FILE"; then
        rm -f "${NODE_USERS_FILE}.tmp"
        rollback_data_transaction
        print_error "重新绑定 admin 到保留节点失败"
        return 1
    fi
    if ! generate_singbox_config || ! activate_singbox_pending_transaction || ! commit_data_transaction; then
        rollback_data_transaction
        systemctl restart sing-box >/dev/null 2>&1 || true
        print_error "重置应用失败，已恢复原数据"
        return 1
    fi
    print_success "用户、绑定、订阅和流量账本已重置"
}

# 重置节点数据
reset_nodes() {
    clear
    echo -e "${CYAN}====== 重置节点数据 ======${NC}\n"

    print_warning "此操作将删除所有节点配置和绑定关系！"
    echo -e "${YELLOW}用户数据将被保留${NC}"
    echo ""
    read -p "确认重置节点数据? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消重置"
        return 0
    fi

    # 二次确认
    read -p "再次确认? 输入 YES 继续: " confirm2
    if [[ "$confirm2" != "YES" ]]; then
        print_info "取消重置"
        return 0
    fi

    begin_data_transaction || return 1
    printf '%s\n' '{"nodes":[]}' > "$NODES_FILE" \
        && printf '%s\n' '{"bindings":[]}' > "$NODE_USERS_FILE" \
        && printf '%s\n' '{"subscriptions":[]}' > "${DATA_DIR}/subscriptions.json" \
        && printf '%s\n' '{"subscriptions":[]}' > "${DATA_DIR}/subscription_metadata.json" \
        && printf '%s\n' '{"configs":[]}' > "${DATA_DIR}/port_hopping.json" || {
        rollback_data_transaction; print_error "重置节点数据写入失败"; return 1
    }
    find "$SUBSCRIPTION_DIR" -mindepth 1 -maxdepth 1 -delete 2>/dev/null || {
        rollback_data_transaction; print_error "清理订阅文件失败"; return 1
    }
    if ! generate_singbox_config || ! activate_singbox_pending_transaction; then
        rollback_data_transaction; systemctl restart sing-box >/dev/null 2>&1 || true
        print_error "新配置无法激活，节点重置已回滚"; return 1
    fi
    if ! cleanup_all_port_hopping_rules "${RUNTIME_TX_DIR}/nodes.json"; then
        rollback_data_transaction
        restore_port_hopping_rules_from_nodes_file "${RUNTIME_STATE_DIR}/nodes.json" || true
        systemctl restart sing-box >/dev/null 2>&1 || true
        print_error "端口跳跃规则清理失败，节点重置已回滚"; return 1
    fi
    if ! commit_data_transaction; then
        rollback_data_transaction
        restore_port_hopping_rules_from_nodes_file "${RUNTIME_STATE_DIR}/nodes.json" || true
        systemctl restart sing-box >/dev/null 2>&1 || true
        print_error "节点重置提交失败，已回滚"; return 1
    fi
    print_success "节点、绑定、订阅和端口跳跃配置已重置"
}

# 重置所有数据
reset_all_data() {
    clear
    echo -e "${CYAN}====== 重置所有数据 ======${NC}\n"

    print_warning "此操作将删除所有节点和用户配置！"
    echo -e "${RED}所有数据将被清空！${NC}"
    echo ""
    read -p "确认重置所有数据? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消重置"
        return 0
    fi

    # 二次确认
    read -p "再次确认? 输入 YES 继续: " confirm2
    if [[ "$confirm2" != "YES" ]]; then
        print_info "取消重置"
        return 0
    fi

    begin_data_transaction || return 1
    printf '%s\n' '{"users":[]}' > "$USERS_FILE" \
        && printf '%s\n' '{"nodes":[]}' > "$NODES_FILE" \
        && printf '%s\n' '{"bindings":[]}' > "$NODE_USERS_FILE" \
        && printf '%s\n' '{"outbounds":[],"endpoints":[]}' > "${DATA_DIR}/outbounds.json" \
        && printf '%s\n' '{"users":{}}' > "${DATA_DIR}/traffic_counters.json" \
        && printf '%s\n' '{"subscriptions":[]}' > "${DATA_DIR}/subscriptions.json" \
        && printf '%s\n' '{"subscriptions":[]}' > "${DATA_DIR}/subscription_metadata.json" \
        && printf '%s\n' '{"configs":[]}' > "${DATA_DIR}/port_hopping.json" \
        && printf '%s\n' '{"domains":[],"certificates":[]}' > "${DATA_DIR}/domains.json" \
        && printf '%s\n' '{"auths":[]}' > "${DATA_DIR}/cf_auths.json" || {
        rollback_data_transaction; print_error "重置数据写入失败"; return 1
    }
    rm -f -- "${DATA_DIR}/default_domain.txt" "${DATA_DIR}/server_domain.txt" "${DATA_DIR}/host_domain.txt"
    find "$SUBSCRIPTION_DIR" -mindepth 1 -maxdepth 1 -delete 2>/dev/null || {
        rollback_data_transaction; print_error "清理订阅文件失败"; return 1
    }
    if ! declare -f init_admin_user >/dev/null 2>&1 || ! init_admin_user; then
        rollback_data_transaction; print_error "重新创建 admin 用户失败"; return 1
    fi
    if declare -f generate_singbox_config >/dev/null 2>&1; then
        generate_singbox_config || { rollback_data_transaction; return 1; }
    elif declare -f create_default_config >/dev/null 2>&1; then
        create_default_config || { rollback_data_transaction; return 1; }
    else
        rollback_data_transaction; print_error "缺少配置生成函数"; return 1
    fi
    if ! activate_singbox_pending_transaction; then
        rollback_data_transaction; systemctl restart sing-box >/dev/null 2>&1 || true
        print_error "重置后的配置无法启动，已恢复原数据"; return 1
    fi
    if ! cleanup_all_port_hopping_rules "${RUNTIME_TX_DIR}/nodes.json"; then
        rollback_data_transaction
        restore_port_hopping_rules_from_nodes_file "${RUNTIME_STATE_DIR}/nodes.json" || true
        systemctl restart sing-box >/dev/null 2>&1 || true
        print_error "端口跳跃规则清理失败，完整重置已回滚"; return 1
    fi
    if ! commit_data_transaction; then
        rollback_data_transaction
        restore_port_hopping_rules_from_nodes_file "${RUNTIME_STATE_DIR}/nodes.json" || true
        systemctl restart sing-box >/dev/null 2>&1 || true
        print_error "完整重置提交失败，已回滚"; return 1
    fi
    print_success "所有运行数据已重置（证书文件和程序工具链保留）"
}

# 配置优化建议
config_suggestions() {
    clear
    echo -e "${CYAN}====== 配置优化建议 ======${NC}\n"

    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        print_error "配置文件不存在"
        return 1
    fi

    echo -e "${CYAN}正在分析配置...${NC}\n"

    # 检查日志配置
    local log_level=$(jq -r '.log.loglevel // "none"' "$SINGBOX_CONFIG")
    if [[ "$log_level" == "debug" ]]; then
        echo -e "${YELLOW}建议：${NC}日志级别为 debug，生产环境建议使用 warning"
    fi

    # 检查 stats 配置
    local has_stats=$(jq -r '.stats // {} | length' "$SINGBOX_CONFIG")
    if [[ "$has_stats" -eq 0 ]]; then
        echo -e "${YELLOW}建议：${NC}未启用流量统计，无法查看流量信息"
    fi

    # 检查 sniffing 配置
    local inbounds=$(jq -r '.inbounds[] | select(.sniffing.enabled != true) | .port' "$SINGBOX_CONFIG" 2>/dev/null)
    if [[ -n "$inbounds" ]]; then
        echo -e "${YELLOW}建议：${NC}以下端口未启用流量嗅探：$inbounds"
    fi

    # 检查 routing 规则
    local routing_rules=$(jq -r '.routing.rules // [] | length' "$SINGBOX_CONFIG")
    if [[ "$routing_rules" -lt 2 ]]; then
        echo -e "${YELLOW}建议：${NC}路由规则较少，可能需要添加更多分流规则"
    fi

    echo ""
    print_info "优化建议分析完成"
}
