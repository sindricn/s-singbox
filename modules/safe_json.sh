#!/bin/bash

#================================================================
# 安全的JSON操作模块
# 提供文件锁和原子操作，防止并发写入导致JSON损坏
#================================================================

# 安全地更新JSON文件
# 用法: safe_json_update "jq表达式" "文件路径" [jq参数...]
safe_json_update() {
    local jq_expr="$1"
    local file="$2"
    shift 2
    local jq_args=("$@")

    # 验证文件存在
    if [[ ! -f "$file" ]]; then
        log_error "文件不存在: $file"
        return 1
    fi

    # 创建锁文件
    local lock_file="${file}.lock"
    local lock_fd=200

    # 使用flock获取排他锁（最多等待10秒）
    exec 200>"$lock_file"
    if ! flock -x -w 10 200; then
        log_error "无法获取文件锁: $file (可能有其他进程正在操作)"
        return 1
    fi

    # 在锁保护下执行操作
    local tmp_file err_file
    tmp_file=$(mktemp "${file}.tmp.XXXXXX") || { flock -u 200; return 1; }
    err_file=$(mktemp "${file}.err.XXXXXX") || { rm -f "$tmp_file"; flock -u 200; return 1; }
    local success=false

    # 先验证原始文件格式
    if ! jq empty "$file" >/dev/null 2>&1; then
        log_error "原始JSON文件格式错误: $file"
        flock -u 200
        return 1
    fi

    # 执行jq操作
    if jq "${jq_args[@]}" "$jq_expr" "$file" > "$tmp_file" 2>"$err_file"; then
        # 验证生成的JSON格式
        if jq empty "$tmp_file" >/dev/null 2>&1; then
            # 原子替换
            if mv "$tmp_file" "$file"; then
                success=true
            else
                log_error "替换文件失败: $file"
            fi
        else
            log_error "生成的JSON格式错误"
            if [[ -s "$err_file" ]]; then
                cat "$err_file" >&2
            fi
        fi
    else
        log_error "jq执行失败"
        if [[ -s "$err_file" ]]; then
            cat "$err_file" >&2
        fi
    fi

    # 清理
    rm -f "$tmp_file" "$err_file"

    # 释放锁
    flock -u 200
    rm -f "$lock_file"

    $success && return 0 || return 1
}

# 安全地添加数组元素
# 用法: safe_json_append "文件路径" ".array" "元素JSON"
safe_json_append() {
    local file="$1"
    local array_path="$2"
    local element="$3"

    # 创建锁文件
    local lock_file="${file}.lock"
    exec 200>"$lock_file"

    if ! flock -x -w 10 200; then
        log_error "无法获取文件锁: $file"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${file}.tmp.XXXXXX") || { flock -u 200; return 1; }
    local success=false

    # 验证原始文件
    if ! jq empty "$file" >/dev/null 2>&1; then
        log_error "原始JSON格式错误: $file"
        flock -u 200
        return 1
    fi

    # 执行追加操作
    if jq "${array_path} += [$element]" "$file" > "$tmp_file" 2>/dev/null; then
        if jq empty "$tmp_file" >/dev/null 2>&1; then
            if mv "$tmp_file" "$file"; then
                success=true
            fi
        fi
    fi

    rm -f "$tmp_file"
    flock -u 200
    rm -f "$lock_file"

    $success && return 0 || return 1
}

# 安全地修改数组元素
# 用法: safe_json_modify "文件路径" "jq map表达式"
safe_json_modify() {
    local file="$1"
    local map_expr="$2"

    safe_json_update "$map_expr" "$file"
}

# 安全地删除数组元素
# 用法: safe_json_delete "文件路径" "数组路径" "删除条件"
safe_json_delete() {
    local file="$1"
    local array_path="$2"
    local condition="$3"

    safe_json_update "${array_path} = [${array_path}[] | select($condition)]" "$file"
}
