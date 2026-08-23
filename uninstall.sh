#!/usr/bin/env bash
# ==========================================
# jiaoben 卸载脚本 v2.1
# 更新日期: 2026-06-07
# 修复: pkill 拼写错误、路径可配置、进程清理增强
# ==========================================
set -Euo pipefail

# --- 加载公共库（如果存在） ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/common.sh" ]]; then
    source "$SCRIPT_DIR/common.sh"
fi

# --- 颜色定义 ---
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${NC:=\033[0m}"

# --- 日志函数 ---
_info()   { echo -e "${BLUE}[INFO]${NC}    $*"; }
_warn()   { echo -e "${YELLOW}[WARN]${NC}    $*"; }
_error()  { echo -e "${RED}[ERROR]${NC}   $*"; }
_success(){ echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# --- 可配置路径 ---
WORK_DIR="${WORKDIR_BASE:-/root/.jiaoben}"
MGMT_TOOL="/usr/local/bin/jb"

SERVICES=(
    "jiaoben-xray"
    "jiaoben-hy2"
    "jiaoben-argo"
)

# ==========================================
# 停止并禁用服务
# ==========================================
stop_services() {
    _info "正在停止所有服务..."
    for service in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            _info "停止服务: $service"
            systemctl stop "$service" 2>/dev/null || _warn "无法停止 $service"
        fi
        if systemctl is-enabled --quiet "$service" 2>/dev/null; then
            _info "禁用服务: $service"
            systemctl disable "$service" 2>/dev/null || _warn "无法禁用 $service"
        fi
    done
    _success "所有服务已停止"
}

# ==========================================
# 删除服务文件
# ==========================================
remove_service_files() {
    _info "正在删除服务文件..."
    for service in "${SERVICES[@]}"; do
        local service_file="/etc/systemd/system/${service}.service"
        if [[ -f "$service_file" ]]; then
            _info "删除: $service_file"
            rm -f "$service_file" 2>/dev/null || _warn "无法删除 $service_file"
        fi
    done
    _info "重新加载 systemd..."
    systemctl daemon-reload 2>/dev/null || true
    _success "服务文件已删除"
}

# ==========================================
# 清理残留进程（修复 pkill 拼写）
# ==========================================
cleanup_processes() {
    _info "正在清理残留进程..."
    # 只匹配本脚本安装目录下的二进制，避免误杀用户自建实例
    local bins="$WORK_DIR/xray/xray $WORK_DIR/hysteria $WORK_DIR/cloudflared"

    for bin in $bins; do
        if pgrep -f "^${bin}" >/dev/null 2>&1; then
            _info "终止进程: $bin"
            if command -v pkill &>/dev/null; then
                pkill -9 -f "^${bin}" 2>/dev/null || true
            else
                pgrep -f "^${bin}" | xargs -r kill -9 2>/dev/null || true
            fi
        fi
    done
    _success "进程清理完成"
}

# ==========================================
# 删除工作目录
# ==========================================
remove_work_directory() {
    _info "正在删除工作目录..."
    if [[ -d "$WORK_DIR" ]]; then
        _info "删除: $WORK_DIR"
        rm -rf "$WORK_DIR" 2>/dev/null || _warn "无法删除 $WORK_DIR"
        _success "工作目录已删除"
    else
        _warn "工作目录不存在: $WORK_DIR"
    fi
}

# ==========================================
# 删除管理工具
# ==========================================
remove_management_tool() {
    _info "正在删除管理工具..."
    if [[ -f "$MGMT_TOOL" ]]; then
        _info "删除: $MGMT_TOOL"
        rm -f "$MGMT_TOOL" 2>/dev/null || _warn "无法删除 $MGMT_TOOL"
        _success "管理工具已删除"
    else
        _warn "管理工具不存在: $MGMT_TOOL"
    fi
    if [[ -d /usr/local/lib/jiaoben ]]; then
        _info "删除: /usr/local/lib/jiaoben"
        rm -rf /usr/local/lib/jiaoben 2>/dev/null || _warn "无法删除 /usr/local/lib/jiaoben"
    fi
}

# ==========================================
# 卸载确认
# ==========================================
confirm_uninstall() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  ⚠️  警告：即将卸载 jiaoben 全部组件${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo "以下操作将被执行："
    echo "  1. 停止所有服务"
    echo "  2. 删除 systemd 服务文件"
    echo "  3. 清理残留进程"
    echo "  4. 删除工作目录: $WORK_DIR"
    echo "  5. 删除管理工具: $MGMT_TOOL"
    echo ""
    echo -e "${RED}此操作不可撤销！${NC}"
    echo ""
    read -p "确认卸载？请输入 yes 确认: " -r response

    if [[ "$response" != "yes" ]]; then
        _info "卸载已取消"
        exit 0
    fi
}

# ==========================================
# 完成信息
# ==========================================
show_completion_info() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}          ✅ 卸载完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "已删除的内容："
    echo "  ✓ 所有 systemd 服务"
    echo "  ✓ 工作目录: $WORK_DIR"
    echo "  ✓ 管理工具: $MGMT_TOOL"
    echo "  ✓ 残留进程"
    echo ""
    echo "如需重新部署，请运行："
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/run.sh)"
    echo ""
}

# ==========================================
# 主函数
# ==========================================
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    jiaoben 卸载脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    confirm_uninstall

    stop_services
    echo ""
    remove_service_files
    echo ""
    cleanup_processes
    echo ""
    remove_work_directory
    echo ""
    remove_management_tool
    echo ""

    show_completion_info
}

main "$@"