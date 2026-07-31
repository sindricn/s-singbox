#!/bin/bash

#================================================================
# 公共库模块 - Common Library
# 功能：统一日志系统、错误处理、工具函数
# 参考：s-hy2 最佳实践
#================================================================

# 严格模式（不使用 -e，保持错误处理可控）
set -uo pipefail

#================================================================
# 日志系统 - Logging System
#================================================================

# 日志级别
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_FATAL=4

# 当前日志级别（默认 INFO）
LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# 日志文件
LOG_FILE="${LOG_FILE:-/var/log/singbox-manager.log}"
LOG_DIR="$(dirname "$LOG_FILE")"

# 初始化日志目录
init_log_dir() {
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
}

# 日志函数 - 分级日志输出
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$

    # 根据日志级别输出
    if [[ $level -ge $LOG_LEVEL ]]; then
        local level_name=""
        local color=""

        case $level in
            $LOG_LEVEL_DEBUG)
                level_name="DEBUG"
                color="${BLUE}"
                ;;
            $LOG_LEVEL_INFO)
                level_name="INFO "
                color="${CYAN}"
                ;;
            $LOG_LEVEL_WARN)
                level_name="WARN "
                color="${YELLOW}"
                ;;
            $LOG_LEVEL_ERROR)
                level_name="ERROR"
                color="${RED}"
                ;;
            $LOG_LEVEL_FATAL)
                level_name="FATAL"
                color="${RED}"
                ;;
        esac

        # 终端输出（彩色）
        echo -e "${color}[${level_name}]${NC} $message"

        # 文件输出（无颜色）
        if [[ -w "$LOG_DIR" ]] || [[ -w "$LOG_FILE" ]]; then
            echo "[$timestamp] [$level_name] [PID:$pid] $message" >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

# 便捷日志函数
log_debug() { log $LOG_LEVEL_DEBUG "$@"; }
log_info() { log $LOG_LEVEL_INFO "$@"; }
log_warn() { log $LOG_LEVEL_WARN "$@"; }
log_error() { log $LOG_LEVEL_ERROR "$@"; }
log_fatal() { log $LOG_LEVEL_FATAL "$@"; }

# 兼容旧的打印函数（逐步迁移）
print_info() { log_info "$@"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; log_info "[SUCCESS] $*"; }
print_error() { log_error "$@"; }
print_warning() { log_warn "$@"; }

#================================================================
# 错误处理 - Error Handling
#================================================================

# 错误退出函数
error_exit() {
    local message="$1"
    local exit_code="${2:-1}"

    log_fatal "$message"

    # 调用清理函数（如果存在）
    if declare -f cleanup >/dev/null; then
        cleanup
    fi

    exit "$exit_code"
}

# 信号捕获 - 自动清理
setup_signal_handlers() {
    trap 'error_exit "脚本被中断 (SIGINT)" 130' INT
    trap 'error_exit "脚本被终止 (SIGTERM)" 143' TERM
    trap 'handle_error ${LINENO} ${BASH_LINENO} "$BASH_COMMAND" $?' ERR
}

# 错误处理函数 - 调用栈跟踪
handle_error() {
    local lineno=$1
    local bash_lineno=$2
    local command=$3
    local error_code=$4

    log_error "命令执行失败 (退出码: $error_code)"
    log_error "  行号: $lineno"
    log_error "  命令: $command"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        local annotation_file=${BASH_SOURCE[1]:-scripts/validate_all.sh}
        local annotation_command=${command//'%'/'%25'}
        [[ -z "${ROOT_DIR:-}" ]] || annotation_file=${annotation_file#"${ROOT_DIR}/"}
        annotation_command=${annotation_command//$'\r'/'%0D'}
        annotation_command=${annotation_command//$'\n'/'%0A'}
        echo "::error file=${annotation_file},line=${lineno},title=Shell validation failed::${annotation_command} (exit ${error_code})"
    fi

    # 打印调用栈
    log_debug "调用栈:"
    local frame=0
    while caller $frame; do
        ((frame++))
    done | while read line func file; do
        log_debug "  $file:$line ($func)"
    done
}

# 临时文件管理
declare -a TEMP_FILES=()

create_temp_file() {
    local temp_file=$(mktemp) || error_exit "无法创建临时文件"
    chmod 600 "$temp_file"
    TEMP_FILES+=("$temp_file")
    echo "$temp_file"
}

cleanup_temp_files() {
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file"
            log_debug "清理临时文件: $temp_file"
        fi
    done
    TEMP_FILES=()
}

# 清理函数（可被覆盖）
cleanup() {
    cleanup_temp_files
}

#================================================================
# 工具函数 - Utility Functions
#================================================================

# 检查命令是否存在
require_command() {
    local command=$1
    local package=${2:-$command}

    if ! command -v "$command" &>/dev/null; then
        error_exit "未找到命令: $command (请安装: $package)"
    fi
}

# 检查 root 权限
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本必须以 root 权限运行"
    fi
}

# 用户确认
confirm() {
    local prompt="${1:-确认操作}"
    local default="${2:-n}"

    local yn_prompt="[y/N]"
    [[ "$default" == "y" ]] && yn_prompt="[Y/n]"

    read -p "$prompt $yn_prompt: " response
    response=${response:-$default}

    [[ "$response" =~ ^[Yy]$ ]]
}

#================================================================
# UI 辅助函数 - UI Helper Functions
#================================================================

# 统一的 UI 导航返回码。调用方应先捕获返回码，再处理输出值。
readonly UI_CANCEL=97
readonly UI_MAIN_MENU=98
readonly UI_BACK=99

# 统一的边框样式
print_header() {
    local title="$1"
    local width=39
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    printf "${CYAN}║${NC}  %-${width}s\n" "$title"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
}

print_section_start() {
    echo -e "${CYAN}┌─────────────────────────────────────┐${NC}"
}

print_section_end() {
    echo -e "${CYAN}└─────────────────────────────────────┘${NC}"
}

print_divider() {
    echo -e "${CYAN}├─────────────────────────────────────┤${NC}"
}

# 统一的菜单项显示
print_menu_item() {
    local number="$1"
    local text="$2"
    local extra="${3:-}"
    echo -e "${CYAN}│${NC}  ${GREEN}${number}.${NC} ${text}${extra}"
}

print_menu_info() {
    local label="$1"
    local value="$2"
    echo -e "${CYAN}│${NC}  ${label}: ${value}"
}

# 统一的等待函数
wait_for_input() {
    local prompt="${1:-按回车键继续...}"
    read -p "$prompt"
}

# 统一的菜单导航提示
print_nav_options() {
    local show_back="${1:-true}"
    local show_main="${2:-true}"

    echo ""
    if [[ "$show_back" == "true" && "$show_main" == "true" ]]; then
        echo -e "${GRAY}提示: 输入 'b' 返回上级, 'm' 返回主菜单${NC}"
    elif [[ "$show_back" == "true" ]]; then
        echo -e "${GRAY}提示: 输入 'b' 返回上级${NC}"
    elif [[ "$show_main" == "true" ]]; then
        echo -e "${GRAY}提示: 输入 'm' 返回主菜单${NC}"
    fi
}

# 增强的菜单输入处理
read_menu_choice() {
    local prompt="${1:-请选择}"
    local allow_cancel="${2:-false}"
    local choice

    if ! read -r -p "$prompt: " choice; then
        return "$UI_CANCEL"
    fi

    # 处理导航快捷键
    case "$choice" in
        b|B) return "$UI_BACK" ;;
        m|M) return "$UI_MAIN_MENU" ;;
        q|Q)
            if [[ "$allow_cancel" == "true" ]]; then
                return "$UI_CANCEL"
            fi
            echo "$choice"
            return 0
            ;;
        *) echo "$choice"; return 0 ;;
    esac
}

# 确保 JSON 数据文件存在
ensure_json_file() {
    local target_file="$1"
    local default_payload
    if [[ -z "$2" ]]; then
        default_payload="{}"
    else
        default_payload="$2"
    fi

    # 已存在则直接返回
    if [[ -f "$target_file" ]]; then
        return 0
    fi

    local target_dir
    target_dir="$(dirname "$target_file")"

    # 确保所在目录存在
    if [[ ! -d "$target_dir" ]]; then
        if ! mkdir -p "$target_dir" 2>/dev/null; then
            error_exit "无法创建数据目录: $target_dir"
        fi
    fi

    # 写入默认内容
    if printf '%s\n' "$default_payload" > "$target_file"; then
        return 0
    fi

    error_exit "无法初始化数据文件: $target_file"
}

# 验证 JSON 文件格式是否正确
validate_json_file() {
    local file=$1

    # 文件不存在
    if [[ ! -f "$file" ]]; then
        log_error "JSON 文件不存在: $file"
        return 1
    fi

    # 使用 jq 验证 JSON 格式
    if ! jq empty "$file" >/dev/null 2>&1; then
        log_error "JSON 文件格式错误: $file"
        return 1
    fi

    return 0
}

# 安全修复损坏的 JSON 文件（备份后重新初始化）
repair_json_file() {
    local file=$1
    local default_content
    if [[ -z "$2" ]]; then
        default_content="{}"
    else
        default_content="$2"
    fi

    if [[ ! -f "$file" ]]; then
        log_warn "文件不存在，将创建新文件: $file"
        printf '%s\n' "$default_content" > "$file"
        return 0
    fi

    # 验证文件是否损坏
    if jq empty "$file" >/dev/null 2>&1; then
        log_info "JSON 文件格式正确: $file"
        return 0
    fi

    # 备份损坏的文件
    local backup_file="${file}.broken.$(date +%Y%m%d_%H%M%S)"
    cp "$file" "$backup_file" 2>/dev/null || true
    log_warn "JSON 文件已损坏，已备份到: $backup_file"

    # 重新初始化
    printf '%s\n' "$default_content" > "$file"
    log_info "已重新初始化 JSON 文件: $file"

    return 0
}

# 安全更新 JSON 文件（仅在 jq 成功时覆盖原文件）
update_json_file() {
    if [[ $# -lt 2 ]]; then
        log_error "update_json_file 调用参数不足"
        return 1
    fi

    local file="${!#}"         # 最后一个参数视为文件路径
    local args=("${@:1:$#-1}") # 除最后一个参数外的所有 jq 参数

    if [[ ! -f "$file" ]]; then
        log_error "update_json_file: 目标文件不存在: $file"
        return 1
    fi

    # 先验证原始文件格式
    if ! jq empty "$file" >/dev/null 2>&1; then
        log_error "JSON 文件格式错误，无法更新: $file"
        return 1
    fi

    # 创建临时文件
    local tmp_file
    tmp_file=$(mktemp) || {
        log_error "update_json_file: 无法创建临时文件"
        return 1
    }

    if jq "${args[@]}" "$file" > "$tmp_file" 2> "${tmp_file}.err"; then
        mv "$tmp_file" "$file"
        rm -f "${tmp_file}.err"
        return 0
    fi

    log_error "更新 JSON 文件失败: $file"
    if [[ -s "${tmp_file}.err" ]]; then
        while IFS= read -r line; do
            log_error "jq: $line"
        done < "${tmp_file}.err"
    fi
    rm -f "$tmp_file" "${tmp_file}.err"
    return 1
}

# IP 地址验证
validate_ip() {
    local ip=$1
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ ! $ip =~ $ip_regex ]]; then
        return 1
    fi

    # 验证每个字段 <= 255
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            return 1
        fi
    done

    return 0
}

# 域名验证
validate_domain() {
    local domain=$1
    local domain_regex='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'

    [[ $domain =~ $domain_regex ]]
}

# 端口验证
validate_port() {
    local port=$1

    if [[ ! $port =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ $port -lt 1 || $port -gt 65535 ]]; then
        return 1
    fi

    return 0
}

# 邮箱验证
validate_email() {
    local email=$1
    local email_regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    [[ $email =~ $email_regex ]]
}

# UUID 验证
validate_uuid() {
    local uuid=$1
    local uuid_regex='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    [[ $uuid =~ $uuid_regex ]]
}

# 路径安全验证（防目录遍历）
validate_path() {
    local path=$1

    # 不允许 .. 和绝对路径开头的 /
    if [[ $path =~ \.\. ]] || [[ $path =~ ^/ ]]; then
        return 1
    fi

    return 0
}

# 输入清理（防注入）
sanitize_input() {
    local input="$1"

    # 移除危险字符
    input="${input//;/}"   # 移除分号
    input="${input//|/}"   # 移除管道
    input="${input//&/}"   # 移除 &
    input="${input//\$/}"  # 移除 $
    input="${input//\`/}"  # 移除反引号
    input="${input//\(/}"  # 移除 (
    input="${input//\)/}"  # 移除 )
    input="${input//\{/}"  # 移除 {
    input="${input//\}/}"  # 移除 }
    input="${input//\[/}"  # 移除 [
    input="${input//\]/}"  # 移除 ]
    input="${input//</}"   # 移除 <
    input="${input//>/}"   # 移除 >

    echo "$input"
}

# 使用系统现有解析工具获取域名 IPv4，不强制依赖 dnsutils/bind-utils。
resolve_domain_ipv4() {
    local domain="${1:-}" result=""
    [[ -n "$domain" ]] || return 1
    if command -v getent >/dev/null 2>&1; then
        result=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    elif command -v dig >/dev/null 2>&1; then
        result=$(dig +short A "$domain" 2>/dev/null | awk '/^[0-9]+(\.[0-9]+){3}$/' | sort -u | tr '\n' ' ')
    elif command -v host >/dev/null 2>&1; then
        result=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}' | sort -u | tr '\n' ' ')
    elif command -v nslookup >/dev/null 2>&1; then
        result=$(nslookup -type=A "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | awk '/^[0-9]+(\.[0-9]+){3}$/' | sort -u | tr '\n' ' ')
    fi
    result=${result% }
    [[ -n "$result" ]] || return 1
    echo "$result"
}

# 获取公网 IP
get_public_ip() {
    local ip="" endpoint

    # 空响应也必须继续尝试，避免 curl 成功但无内容时错误回退到本机地址。
    for endpoint in \
        "https://api.ipify.org" \
        "https://icanhazip.com" \
        "https://ifconfig.me/ip" \
        "https://ipinfo.io/ip"; do
        ip=$(curl -fsS -4 --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]') || ip=""
        if [[ -n "$ip" ]] && validate_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done

    log_warn "无法获取有效公网 IPv4" >&2
    return 1
}

# 检查端口是否被占用
check_port_in_use() {
    local port=$1

    if ss -tunlp | grep -q ":$port "; then
        return 0  # 端口被占用
    fi

    return 1  # 端口未被占用
}

# 生成随机字符串
generate_random_string() {
    local length=${1:-16}
    local chars='A-Za-z0-9!@#$%^&*()_+'

    tr -dc "$chars" < /dev/urandom | head -c "$length"
}

# 生成安全密码
generate_secure_password() {
    local length=${1:-16}
    generate_random_string "$length"
}

# 检查系统类型
get_os_type() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$ID"
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# 检查系统版本
get_os_version() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$VERSION_ID"
    else
        echo "unknown"
    fi
}

# 进度条显示
show_progress() {
    local current=$1
    local total=$2
    local width=${3:-50}

    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))

    printf "\r["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%% (%d/%d)" "$percent" "$current" "$total"

    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# 等待任务完成（带超时）
wait_for_condition() {
    local timeout=${1:-30}
    local interval=${2:-1}
    shift 2
    [[ $# -gt 0 ]] || return 1

    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if "$@"; then
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_warn "等待超时: $*"
    return 1
}

# 重试执行（带指数退避）
retry_with_backoff() {
    local max_attempts=${1:-3}
    local initial_delay=${2:-1}
    shift 2
    [[ $# -gt 0 ]] || return 1

    local attempt=1
    local delay=$initial_delay

    while [[ $attempt -le $max_attempts ]]; do
        log_debug "尝试执行 (第 $attempt 次): $*"

        if "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "执行失败，${delay}秒后重试..."
            sleep "$delay"
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    log_error "执行失败，已达到最大重试次数: $max_attempts"
    return 1
}

#================================================================
# 初始化
#================================================================

# 初始化日志
init_log_dir

# 设置信号处理
setup_signal_handlers

# 注册清理函数
trap cleanup EXIT
