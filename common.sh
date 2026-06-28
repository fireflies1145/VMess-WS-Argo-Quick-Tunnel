#!/bin/bash
# ==========================================
# jiaoben 项目公共配置文件
# 所有脚本都应通过 source 加载此文件以保证一致性
# ==========================================

# --- 基础路径配置 ---
export WORKDIR_BASE="${WORKDIR_BASE:-/root/.jiaoben}"
export INFO_FILE="${WORKDIR_BASE}/all_nodes_info.txt"
export CONFIG_DIR="${WORKDIR_BASE}/config"
export LOG_DIR="${WORKDIR_BASE}/logs"

# --- 颜色定义 ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m'

# --- 日志函数 ---
log_info()  { echo -e "${GREEN}[INFO]${NC}    $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}    $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC}   $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# 简写别名
info()    { log_info "$*"; }
success() { log_success "$*"; }
warn()    { log_warn "$*"; }
error()   { log_error "$*"; exit 1; }

# --- 文件权限设置 ---
secure_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        chmod 600 "$file"
        log_info "设置文件 $file 权限为 600"
    fi
}

# --- 权限检查（兼容 root 和非 root 用户） ---
check_sudo() {
    # 如果已经是 root，直接返回
    [[ $EUID -eq 0 ]] && return 0
    # 检查 sudo 权限
    if ! sudo -n true 2>/dev/null; then
        log_error "需要 sudo 权限。请使用 root 运行，或配置 NOPASSWD。"
        exit 1
    fi
}

# --- 安全的 UUID 生成 ---
generate_uuid() {
    # 优先使用内核接口
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen
    else
        # fallback：手动构造 UUID v4 格式
        local hex variant_char
        hex=$(od -An -N16 -x /dev/urandom 2>/dev/null | tr -d '[:space:]')
        [[ ${#hex} -ge 32 ]] || hex=$(openssl rand -hex 16 2>/dev/null)
        # 设置 UUID v4 variant 位 (10xx = 8/9/a/b)
        variant_char=$(printf '%x' $(( 0x8 | (0x${hex:16:1} & 0x3) )))
        echo "${hex:0:8}-${hex:8:4}-4${hex:12:3}-${variant_char}${hex:16:3}-${hex:20:12}"
    fi
}

# --- 安全的随机密码生成 ---
generate_password() {
    local len="${1:-16}"
    openssl rand -hex "$len" 2>/dev/null || \
        od -An -N"$len" -x /dev/urandom 2>/dev/null | tr -d '[:space:]' | head -c "$((len * 2))"
}

# --- 创建必要目录 ---
init_directories() {
    mkdir -p "$WORKDIR_BASE" "$CONFIG_DIR" "$LOG_DIR"
    chmod 700 "$WORKDIR_BASE"
}

# --- 初始化节点信息文件 ---
init_info_file() {
    if [[ ! -f "$INFO_FILE" ]]; then
        echo "# jiaoben 节点信息 - $(date)" > "$INFO_FILE"
        secure_file "$INFO_FILE"
    fi
}

# --- 添加节点信息（兼容纯文本和 JSON 双格式） ---
add_node_info() {
    local protocol="$1"
    local link="$2"
    local name="${3:-$(date +%s)}"

    init_info_file

    # 纯文本格式（供 print_nodes 使用）
    {
        echo ""
        echo "┌─────────────────────────────────────────────"
        echo "│ $name ($protocol)"
        echo "├─────────────────────────────────────────────"
        echo "$link"
        echo "└─────────────────────────────────────────────"
    } >> "$INFO_FILE"

    secure_file "$INFO_FILE"
}

# --- 获取所有节点信息 ---
get_all_nodes() {
    if [[ -f "$INFO_FILE" ]]; then
        cat "$INFO_FILE"
    else
        echo "无节点信息"
    fi
}

# --- 错误处理 ---
handle_error() {
    log_error "脚本在第 $1 行出错"
    exit 1
}

set_error_trap() {
    # 使用 -E 让 ERR trap 在函数中也生效
    set -E
    trap 'handle_error ${LINENO}' ERR
}