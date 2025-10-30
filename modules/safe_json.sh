#!/bin/bash

# =============================================================================
# safe_json.sh - JSON 安全操作库
# 提供原子性操作、备份回滚机制、错误处理
# =============================================================================

# 依赖 common.sh
if [[ -z "${SCRIPT_DIR}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# 加载 common.sh（如果未加载）
if ! declare -f print_error &>/dev/null; then
    source "${SCRIPT_DIR}/modules/common.sh"
fi

# =============================================================================
# 配置
# =============================================================================

# 备份目录
JSON_BACKUP_DIR="${SCRIPT_DIR}/.backups"

# 最大备份数量
MAX_BACKUPS=10

# =============================================================================
# 备份管理
# =============================================================================

# 确保备份目录存在
ensure_backup_dir() {
    ensure_dir "$JSON_BACKUP_DIR"
}

# 创建文件备份
backup_json_file() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        log_debug "文件不存在，无需备份: $file"
        return 0
    fi

    ensure_backup_dir

    local filename=$(basename "$file")
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${JSON_BACKUP_DIR}/${filename}.${timestamp}.bak"

    if cp "$file" "$backup_file"; then
        log_debug "备份文件: $file -> $backup_file"

        # 清理旧备份
        cleanup_old_backups "$filename"

        echo "$backup_file"
        return 0
    else
        log_error "备份文件失败: $file"
        return 1
    fi
}

# 清理旧备份
cleanup_old_backups() {
    local filename=$1
    local backup_pattern="${JSON_BACKUP_DIR}/${filename}.*.bak"

    # 列出所有备份文件，按时间排序
    local backups=($(ls -t $backup_pattern 2>/dev/null))

    # 如果备份数超过最大值，删除旧备份
    if [[ ${#backups[@]} -gt $MAX_BACKUPS ]]; then
        local to_delete=("${backups[@]:$MAX_BACKUPS}")
        for file in "${to_delete[@]}"; do
            rm -f "$file"
            log_debug "删除旧备份: $file"
        done
    fi
}

# 恢复备份
restore_json_backup() {
    local backup_file=$1
    local target_file=$2

    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi

    if cp "$backup_file" "$target_file"; then
        log_info "恢复备份: $backup_file -> $target_file"
        return 0
    else
        log_error "恢复备份失败"
        return 1
    fi
}

# 列出备份
list_json_backups() {
    local filename=$1
    local backup_pattern="${JSON_BACKUP_DIR}/${filename}.*.bak"

    ls -lth $backup_pattern 2>/dev/null
}

# =============================================================================
# JSON 验证
# =============================================================================

# 验证 JSON 格式
validate_json() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        log_error "文件不存在: $file"
        return 1
    fi

    if jq empty "$file" 2>/dev/null; then
        return 0
    else
        log_error "JSON 格式无效: $file"
        return 1
    fi
}

# 验证 JSON 字符串
validate_json_string() {
    local json_string=$1

    if echo "$json_string" | jq empty 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# 安全读取
# =============================================================================

# 安全读取 JSON 文件
safe_read_json() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        log_error "JSON 文件不存在: $file"
        return 1
    fi

    if ! validate_json "$file"; then
        return 1
    fi

    cat "$file"
}

# 读取 JSON 字段
json_get_value() {
    local file=$1
    local path=$2

    if [[ ! -f "$file" ]]; then
        log_error "JSON 文件不存在: $file"
        return 1
    fi

    jq -r "$path" "$file" 2>/dev/null
}

# =============================================================================
# 安全写入
# =============================================================================

# 原子性写入 JSON 文件
safe_write_json() {
    local file=$1
    local content=$2

    # 验证 JSON 内容
    if ! validate_json_string "$content"; then
        log_error "JSON 内容格式无效"
        return 1
    fi

    # 创建临时文件
    local temp_file="${file}.tmp.$$"

    # 写入临时文件
    if ! echo "$content" | jq '.' > "$temp_file" 2>/dev/null; then
        log_error "写入临时文件失败"
        rm -f "$temp_file"
        return 1
    fi

    # 原子性替换
    if mv "$temp_file" "$file"; then
        log_debug "写入 JSON 文件: $file"
        return 0
    else
        log_error "替换文件失败"
        rm -f "$temp_file"
        return 1
    fi
}

# =============================================================================
# 安全修改
# =============================================================================

# 安全修改 JSON 文件
safe_modify_json() {
    local file=$1
    local jq_filter=$2

    if [[ ! -f "$file" ]]; then
        log_error "JSON 文件不存在: $file"
        return 1
    fi

    # 备份原文件
    local backup_file=$(backup_json_file "$file")
    if [[ $? -ne 0 ]]; then
        log_error "备份文件失败，取消修改"
        return 1
    fi

    # 创建临时文件
    local temp_file="${file}.tmp.$$"

    # 执行 jq 修改
    if ! jq "$jq_filter" "$file" > "$temp_file" 2>/dev/null; then
        log_error "jq 修改失败"
        rm -f "$temp_file"
        return 1
    fi

    # 验证修改后的 JSON
    if ! validate_json "$temp_file"; then
        log_error "修改后的 JSON 格式无效，回滚"
        rm -f "$temp_file"
        restore_json_backup "$backup_file" "$file"
        return 1
    fi

    # 原子性替换
    if mv "$temp_file" "$file"; then
        log_debug "修改 JSON 文件成功: $file"
        return 0
    else
        log_error "替换文件失败，回滚"
        rm -f "$temp_file"
        restore_json_backup "$backup_file" "$file"
        return 1
    fi
}

# =============================================================================
# 数组操作
# =============================================================================

# 向 JSON 数组添加元素
json_array_append() {
    local file=$1
    local array_path=$2
    local element=$3

    # 验证元素是 JSON 格式
    if ! validate_json_string "$element"; then
        log_error "元素不是有效的 JSON"
        return 1
    fi

    local jq_filter="${array_path} += [${element}]"
    safe_modify_json "$file" "$jq_filter"
}

# 从 JSON 数组删除元素（按索引）
json_array_delete_by_index() {
    local file=$1
    local array_path=$2
    local index=$3

    local jq_filter="del(${array_path}[${index}])"
    safe_modify_json "$file" "$jq_filter"
}

# 从 JSON 数组删除元素（按条件）
json_array_delete_by_condition() {
    local file=$1
    local array_path=$2
    local condition=$3

    local jq_filter="${array_path} |= map(select(${condition} | not))"
    safe_modify_json "$file" "$jq_filter"
}

# 更新 JSON 数组元素
json_array_update() {
    local file=$1
    local array_path=$2
    local condition=$3
    local update=$4

    local jq_filter="${array_path} |= map(if ${condition} then ${update} else . end)"
    safe_modify_json "$file" "$jq_filter"
}

# =============================================================================
# 对象操作
# =============================================================================

# 设置 JSON 对象字段
json_set_field() {
    local file=$1
    local path=$2
    local value=$3

    local jq_filter="${path} = ${value}"
    safe_modify_json "$file" "$jq_filter"
}

# 删除 JSON 对象字段
json_delete_field() {
    local file=$1
    local path=$2

    local jq_filter="del(${path})"
    safe_modify_json "$file" "$jq_filter"
}

# =============================================================================
# 批量操作
# =============================================================================

# 批量修改（事务性）
json_batch_modify() {
    local file=$1
    shift
    local filters=("$@")

    # 组合所有过滤器
    local combined_filter=""
    for filter in "${filters[@]}"; do
        if [[ -z "$combined_filter" ]]; then
            combined_filter="$filter"
        else
            combined_filter="${combined_filter} | ${filter}"
        fi
    done

    safe_modify_json "$file" "$combined_filter"
}

# =============================================================================
# 查询操作
# =============================================================================

# 查询 JSON
json_query() {
    local file=$1
    local query=$2

    if [[ ! -f "$file" ]]; then
        log_error "JSON 文件不存在: $file"
        return 1
    fi

    jq "$query" "$file" 2>/dev/null
}

# 查询并返回数组长度
json_array_length() {
    local file=$1
    local array_path=$2

    json_query "$file" "${array_path} | length"
}

# 检查字段是否存在
json_has_key() {
    local file=$1
    local path=$2

    local result=$(json_query "$file" "has(${path})")
    [[ "$result" == "true" ]]
}

# =============================================================================
# 合并操作
# =============================================================================

# 合并两个 JSON 对象
json_merge() {
    local file1=$1
    local file2=$2
    local output=$3

    if [[ ! -f "$file1" ]] || [[ ! -f "$file2" ]]; then
        log_error "源文件不存在"
        return 1
    fi

    local merged=$(jq -s '.[0] * .[1]' "$file1" "$file2" 2>/dev/null)

    if [[ $? -eq 0 ]]; then
        safe_write_json "$output" "$merged"
    else
        log_error "合并 JSON 失败"
        return 1
    fi
}

# =============================================================================
# 初始化空文件
# =============================================================================

# 初始化空 JSON 对象文件
init_json_object() {
    local file=$1
    safe_write_json "$file" '{}'
}

# 初始化空 JSON 数组文件
init_json_array() {
    local file=$1
    safe_write_json "$file" '[]'
}

# 初始化带结构的 JSON 文件
init_json_with_structure() {
    local file=$1
    local structure=$2

    if ! validate_json_string "$structure"; then
        log_error "结构不是有效的 JSON"
        return 1
    fi

    safe_write_json "$file" "$structure"
}

# =============================================================================
# 工具函数
# =============================================================================

# 格式化 JSON 文件
format_json_file() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        log_error "文件不存在: $file"
        return 1
    fi

    local temp_file="${file}.fmt.$$"

    if jq '.' "$file" > "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$file"
        log_info "格式化 JSON 文件: $file"
        return 0
    else
        log_error "格式化失败"
        rm -f "$temp_file"
        return 1
    fi
}

# 压缩 JSON 文件
compact_json_file() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        log_error "文件不存在: $file"
        return 1
    fi

    local temp_file="${file}.cpt.$$"

    if jq -c '.' "$file" > "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$file"
        log_info "压缩 JSON 文件: $file"
        return 0
    else
        log_error "压缩失败"
        rm -f "$temp_file"
        return 1
    fi
}

# =============================================================================
# 模块初始化
# =============================================================================

# 确保备份目录存在
ensure_backup_dir

log_debug "safe_json.sh 模块已加载"
