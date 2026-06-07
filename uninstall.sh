#!/usr/bin/env bash
# ==========================================
# 科学上网四合一卸载脚本 v6.0
# 更新日期: 2026-06-07
# 用于完全卸载所有部署的服务和文件
# ==========================================

set -Eeuo pipefail

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 日志函数 ---
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# --- 配置（与 common.sh 和 jiaoben-simplified.sh 保持一致） ---
WORK_BASE="${HOME}/.jiaoben"
SERVICES=(
    "jiaoben-xray"
    "jiaoben-hy2"
    "jiaoben-argo"
)

# --- 错误陷阱 ---
trap 'echo -e "${RED}[ERROR]${NC} 脚本在第 ${LINENO} 行出错，退出码: $?${NC}" >&2; exit 1' ERR

# --- 卸载函数 ---

stop_services() {
    info "正在停止所有服务..."
    for service in "${SERVICES[@]}"; do
        if sudo systemctl is-active --quiet "$service" 2>/dev/null; then
            info "停止服务: ${service}"
            sudo systemctl stop "$service" 2>/dev/null || warn "无法停止 ${service}"
        fi
        if sudo systemctl is-enabled "$service" 2>/dev/null; then
            info "禁用服务: ${service}"
            sudo systemctl disable "$service" 2>/dev/null || warn "无法禁用 ${service}"
        fi
    done
    success "所有服务已停止"
}

remove_service_files() {
    info "正在删除服务文件..."
    for service in "${SERVICES[@]}"; do
        local service_file="/etc/systemd/system/${service}.service"
        if [[ -f "$service_file" ]]; then
            info "删除服务文件: ${service_file}"
            sudo rm -f "$service_file" 2>/dev/null || warn "无法删除 ${service_file}"
        fi
    done
    info "重新加载 systemd..."
    sudo systemctl daemon-reload 2>/dev/null
    success "服务文件已删除"
}

remove_work_directory() {
    info "正在删除工作目录..."
    if [[ -d "$WORK_BASE" ]]; then
        info "删除目录: ${WORK_BASE}"
        rm -rf "$WORK_BASE" 2>/dev/null || warn "无法删除 ${WORK_BASE}"
        success "工作目录已删除"
    else
        warn "工作目录不存在: ${WORK_BASE}"
    fi
}

remove_management_tool() {
    info "正在删除管理工具..."
    local tool_path="/usr/local/bin/jb"
    if [[ -f "$tool_path" ]]; then
        info "删除管理工具: ${tool_path}"
        sudo rm -f "$tool_path" 2>/dev/null || warn "无法删除 ${tool_path}"
        success "管理工具已删除"
    else
        warn "管理工具不存在: ${tool_path}"
    fi
}

cleanup_processes() {
    info "正在清理残留进程..."
    local processes=("xray" "hysteria" "cloudflared")
    for process in "${processes[@]}"; do
        if pgrep -f "$process" > /dev/null 2>&1; then
            info "杀死进程: ${process}"
            pkill -9 -f "$process" 2>/dev/null || warn "无法杀死 ${process}"
        fi
    done
    success "进程清理完成"
}

cleanup_firewall() {
    info "正在清理防火墙规则..."
    # 清理 UFW 规则
    if command -v ufw &>/dev/null; then
        ufw status 2>/dev/null | grep -i "jiaoben" || true
    fi
    # 清理持久化规则文件
    if [[ -f "/etc/iptables/rules.v4" ]]; then
        info "保留 iptables 持久化规则（可能包含其他服务的规则）"
    fi
    info "防火墙清理完成"
}

confirm_uninstall() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  警告：即将卸载四合一部署${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo "以下操作将被执行："
    echo "  1. 停止所有服务"
    echo "  2. 删除服务文件"
    echo "  3. 清理残留进程"
    echo "  4. 删除工作目录: ${WORK_BASE}"
    echo "  5. 删除管理工具: /usr/local/bin/jb"
    echo ""
    echo -e "${RED}此操作不可撤销！${NC}"
    echo ""
    read -p "确认卸载？(yes/no): " -r response
    if [[ "$response" != "yes" ]]; then
        info "卸载已取消"
        exit 0
    fi
}

show_completion_info() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  卸载完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "已删除的内容："
    echo "  ✓ 所有 Systemd 服务"
    echo "  ✓ 工作目录: ${WORK_BASE}"
    echo "  ✓ 管理工具: /usr/local/bin/jb"
    echo "  ✓ 残留进程"
    echo ""
    echo "如需重新部署，请运行："
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/jiaoben-simplified.sh)"
    echo ""
}

main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  科学上网四合一卸载脚本 v6.0${NC}"
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
    cleanup_firewall
    echo ""
    show_completion_info
}

main "$@"
