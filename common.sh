#!/bin/bash
# jiaoben 项目公共配置文件
# 所有脚本都应该通过 source 加载此文件以保证一致性

# 基础路径配置
export WORKDIR_BASE="/root/.jiaoben"
export INFO_FILE="${WORKDIR_BASE}/all_nodes_info.txt"
export CONFIG_DIR="${WORKDIR_BASE}/config"
export LOG_DIR="${WORKDIR_BASE}/logs"

# 颜色定义
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# 文件权限设置
secure_file() {
    local file="$1"
    if [ -f "$file" ]; then
        chmod 600 "$file"
        log_info "设置文件 $file 权限为 600"
    fi
}

# 检查 sudo 权限
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_error "需要 sudo 权限且未配置 NOPASSWD。请配置后重试。"
        exit 1
    fi
}

# 安全的随机数生成
generate_uuid() {
    cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1
}

# 创建必要的目录
init_directories() {
    mkdir -p "$WORKDIR_BASE" "$CONFIG_DIR" "$LOG_DIR"
    chmod 700 "$WORKDIR_BASE"
}

# 初始化信息文件（JSON 格式）
init_info_file() {
    if [ ! -f "$INFO_FILE" ]; then
        echo "[]" > "$INFO_FILE"
        secure_file "$INFO_FILE"
    fi
}

# 添加节点信息到 JSON 文件
add_node_info() {
    local protocol="$1"
    local link="$2"
    local name="${3:-$(date +%s)}"
    
    local temp_file=$(mktemp)
    jq --arg proto "$protocol" --arg link "$link" --arg name "$name" \
        '. += [{protocol: $proto, link: $link, name: $name, timestamp: now}]' \
        "$INFO_FILE" > "$temp_file"
    
    mv "$temp_file" "$INFO_FILE"
    secure_file "$INFO_FILE"
}

# 获取所有节点信息
get_all_nodes() {
    if [ -f "$INFO_FILE" ]; then
        jq -r '.[] | "\(.protocol): \(.link)"' "$INFO_FILE" 2>/dev/null || echo "无节点信息"
    fi
}

# 错误处理函数
handle_error() {
    local line_no=$1
    log_error "脚本在第 $line_no 行出错"
    exit 1
}

# 设置错误陷阱
set_error_trap() {
    trap 'handle_error ${LINENO}' ERR
}

