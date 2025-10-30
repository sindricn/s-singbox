#!/bin/bash

# =============================================================================
# common.sh - 通用函数库
# 提供日志、颜色输出、工具函数等基础功能
# =============================================================================

# =============================================================================
# 颜色定义
# =============================================================================

export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export MAGENTA='\033[0;35m'
export NC='\033[0m' # No Color

# =============================================================================
# 日志级别
# =============================================================================

export LOG_LEVEL_DEBUG=0
export LOG_LEVEL_INFO=1
export LOG_LEVEL_WARN=2
export LOG_LEVEL_ERROR=3

# 默认日志级别
CURRENT_LOG_LEVEL=${LOG_LEVEL_INFO}

# 日志文件路径
LOG_FILE="/var/log/singbox/manager.log"

# =============================================================================
# 打印函数（输出到终端）
# =============================================================================

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

print_debug() {
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_DEBUG} ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

print_header() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
}

print_separator() {
    echo -e "${BLUE}--------------------------------------${NC}"
}

# =============================================================================
# 日志函数（写入日志文件）
# =============================================================================

# 确保日志目录存在
ensure_log_dir() {
    local log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir"
    fi
}

# 写入日志
log_write() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    ensure_log_dir
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

log_info() {
    log_write "INFO" "$@"
    print_info "$@"
}

log_success() {
    log_write "SUCCESS" "$@"
    print_success "$@"
}

log_error() {
    log_write "ERROR" "$@"
    print_error "$@"
}

log_warn() {
    log_write "WARN" "$@"
    print_warn "$@"
}

log_debug() {
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_DEBUG} ]]; then
        log_write "DEBUG" "$@"
        print_debug "$@"
    fi
}

# =============================================================================
# 权限检查
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此操作需要 root 权限"
        print_info "请使用 sudo 运行此脚本"
        return 1
    fi
    return 0
}

require_root() {
    if ! check_root; then
        exit 1
    fi
}

# =============================================================================
# 命令检查
# =============================================================================

check_command() {
    local cmd=$1
    if command -v "$cmd" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

require_command() {
    local cmd=$1
    local package=${2:-$cmd}

    if ! check_command "$cmd"; then
        print_error "缺少必需的命令: $cmd"
        print_info "请安装: $package"
        return 1
    fi
    return 0
}

check_commands() {
    local missing_commands=()

    for cmd in "$@"; do
        if ! check_command "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        print_error "缺少以下必需命令: ${missing_commands[*]}"
        return 1
    fi
    return 0
}

# =============================================================================
# 文件操作工具
# =============================================================================

# 检查文件是否存在
file_exists() {
    [[ -f "$1" ]]
}

# 检查目录是否存在
dir_exists() {
    [[ -d "$1" ]]
}

# 确保目录存在
ensure_dir() {
    local dir=$1
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log_debug "创建目录: $dir"
    fi
}

# 安全删除文件
safe_remove() {
    local file=$1
    if [[ -f "$file" ]]; then
        rm -f "$file"
        log_debug "删除文件: $file"
    fi
}

# 安全复制文件
safe_copy() {
    local src=$1
    local dst=$2

    if [[ ! -f "$src" ]]; then
        log_error "源文件不存在: $src"
        return 1
    fi

    cp "$src" "$dst"
    log_debug "复制文件: $src -> $dst"
}

# 安全移动文件
safe_move() {
    local src=$1
    local dst=$2

    if [[ ! -f "$src" ]]; then
        log_error "源文件不存在: $src"
        return 1
    fi

    mv "$src" "$dst"
    log_debug "移动文件: $src -> $dst"
}

# =============================================================================
# 字符串工具
# =============================================================================

# 去除字符串首尾空格
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

# 转换为小写
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# 转换为大写
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# 检查字符串是否为空
is_empty() {
    [[ -z "$1" ]]
}

# 检查字符串是否不为空
is_not_empty() {
    [[ -n "$1" ]]
}

# =============================================================================
# UUID 生成
# =============================================================================

generate_uuid() {
    # 尝试多种方法生成 UUID
    if check_command uuidgen; then
        uuidgen | to_lower
    elif check_command cat && [[ -e /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # 使用 /dev/urandom 生成 UUID v4
        local N B T
        for (( N=0; N < 16; ++N )); do
            B=$(( $RANDOM % 256 ))
            if (( N == 6 )); then
                printf '4%x' $(( B % 16 ))
            elif (( N == 8 )); then
                local T=$(( B % 4 ))
                printf '%x%x' $(( 8 + T )) $(( (B / 4) % 16 ))
            else
                printf '%02x' $B
            fi
            case $N in
                3 | 5 | 7 | 9) printf '-' ;;
            esac
        done
        echo
    fi
}

# =============================================================================
# 随机密码生成
# =============================================================================

generate_random_password() {
    local length=${1:-16}

    if check_command openssl; then
        openssl rand -base64 $((length * 2)) | tr -d '/+=' | head -c "$length"
    elif check_command /dev/urandom; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
    else
        # 降级方案
        date +%s%N | md5sum | head -c "$length"
    fi
    echo
}

# =============================================================================
# 确认提示
# =============================================================================

confirm() {
    local prompt="${1:-继续}"
    local default="${2:-n}"

    local yn_prompt
    if [[ "$default" == "y" || "$default" == "Y" ]]; then
        yn_prompt="[Y/n]"
    else
        yn_prompt="[y/N]"
    fi

    read -p "$(echo -e ${YELLOW}${prompt} ${yn_prompt}:${NC} )" -r
    REPLY=$(echo "$REPLY" | to_lower)

    if [[ -z "$REPLY" ]]; then
        REPLY="$default"
    fi

    [[ "$REPLY" == "y" ]]
}

# =============================================================================
# 输入读取
# =============================================================================

read_input() {
    local prompt=$1
    local default=$2
    local result

    if [[ -n "$default" ]]; then
        read -p "$(echo -e ${CYAN}${prompt}${NC} [${default}]: )" -r result
        result=${result:-$default}
    else
        read -p "$(echo -e ${CYAN}${prompt}${NC}: )" -r result
    fi

    echo "$result"
}

read_password() {
    local prompt=$1
    local result

    read -sp "$(echo -e ${CYAN}${prompt}${NC}: )" -r result
    echo >&2  # 换行
    echo "$result"
}

# =============================================================================
# 进程管理
# =============================================================================

# 检查进程是否运行
is_process_running() {
    local pid=$1
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 等待进程结束
wait_process() {
    local pid=$1
    local timeout=${2:-30}
    local elapsed=0

    while is_process_running "$pid"; do
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi
        sleep 1
        ((elapsed++))
    done
    return 0
}

# =============================================================================
# 系统信息
# =============================================================================

get_os_type() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

get_os_version() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$VERSION_ID"
    else
        echo "unknown"
    fi
}

get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "arm64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        *)
            echo "$arch"
            ;;
    esac
}

# =============================================================================
# 网络工具
# =============================================================================

# 检查端口是否占用
is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln | grep -q ":${port} "
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":${port} "
    else
        return 1
    fi
}

# 获取本机公网IP
get_public_ip() {
    local ip

    # 尝试多个服务
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# 时间工具
# =============================================================================

# 获取 ISO 8601 格式的时间戳
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# 获取 Unix 时间戳
get_unix_timestamp() {
    date +%s
}

# =============================================================================
# 数组工具
# =============================================================================

# 检查数组是否包含元素
array_contains() {
    local item=$1
    shift
    local array=("$@")

    for element in "${array[@]}"; do
        if [[ "$element" == "$item" ]]; then
            return 0
        fi
    done
    return 1
}

# 数组去重
array_unique() {
    local -a result=()
    for item in "$@"; do
        if ! array_contains "$item" "${result[@]}"; then
            result+=("$item")
        fi
    done
    echo "${result[@]}"
}

# =============================================================================
# 版本比较
# =============================================================================

version_compare() {
    local ver1=$1
    local ver2=$2

    if [[ "$ver1" == "$ver2" ]]; then
        echo 0
        return
    fi

    local IFS=.
    local i ver1_arr=($ver1) ver2_arr=($ver2)

    for ((i=0; i<${#ver1_arr[@]} || i<${#ver2_arr[@]}; i++)); do
        local v1=${ver1_arr[i]:-0}
        local v2=${ver2_arr[i]:-0}

        if ((10#$v1 > 10#$v2)); then
            echo 1
            return
        elif ((10#$v1 < 10#$v2)); then
            echo -1
            return
        fi
    done

    echo 0
}

# =============================================================================
# 初始化
# =============================================================================

# 设置日志级别
set_log_level() {
    case $(to_lower "$1") in
        debug)
            CURRENT_LOG_LEVEL=${LOG_LEVEL_DEBUG}
            ;;
        info)
            CURRENT_LOG_LEVEL=${LOG_LEVEL_INFO}
            ;;
        warn)
            CURRENT_LOG_LEVEL=${LOG_LEVEL_WARN}
            ;;
        error)
            CURRENT_LOG_LEVEL=${LOG_LEVEL_ERROR}
            ;;
        *)
            log_warn "未知的日志级别: $1，使用默认级别 INFO"
            ;;
    esac
}

# 模块加载完成
log_debug "common.sh 模块已加载"
