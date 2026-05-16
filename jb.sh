#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Jiaoben 统一管理快捷工具
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

INFO_FILE="${HOME}/all_nodes_info.txt"

# 打印信息函数
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err() { printf "${RED}[x]${NC} %s\n" "$*"; }

show_menu() {
    clear
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${PURPLE}       Jiaoben 快捷管理工具             ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN} 1.${NC} 查看所有节点链接"
    echo -e "${GREEN} 2.${NC} 检查服务运行状态"
    echo -e "${GREEN} 3.${NC} 停止所有节点服务"
    echo -e "${GREEN} 4.${NC} 卸载并清理所有节点"
    echo -e "${GREEN} 5.${NC} 重新安装/更新快捷命令 (jb)"
    echo -e "${RED} 0.${NC} 退出"
    echo -e "${CYAN}==========================================${NC}"
    printf "请选择 [0-5]: "
}

view_nodes() {
    if [ ! -f "$INFO_FILE" ] || [ ! -s "$INFO_FILE" ]; then
        warn "暂无已部署的节点信息。"
    else
        echo -e "${CYAN}--- 当前已部署节点信息 ---${NC}"
        cat "$INFO_FILE"
    fi
}

check_status() {
    echo -e "${CYAN}--- 服务运行状态 ---${NC}"
    local found=false
    if pgrep -f "xray" >/dev/null; then info "Xray 正在运行"; found=true; fi
    if pgrep -f "hysteria" >/dev/null; then info "Hysteria 正在运行"; found=true; fi
    if pgrep -f "cloudflared" >/dev/null; then info "Cloudflared 正在运行"; found=true; fi
    
    if [ "$found" = false ]; then
        warn "未检测到任何正在运行的相关服务。"
    fi
}

stop_all() {
    info "正在停止所有服务..."
    pkill -f "xray" || true
    pkill -f "hysteria" || true
    pkill -f "cloudflared" || true
    info "所有服务已停止。"
}

uninstall_all() {
    printf "${RED}确定要卸载并清理所有节点吗？(y/N): ${NC}"
    read -r confirm
    if [[ "${confirm,,}" =~ ^y(es)?$ ]]; then
        stop_all
        info "正在清理工作目录..."
        rm -rf "${HOME}/vless-reality" "${HOME}/hy2" "${HOME}/vmess-argo" "${HOME}/vless-argo" "${HOME}/vless-argo-temp" "${HOME}/vmess-argo-temp"
        rm -f "$INFO_FILE"
        info "清理完成。"
    else
        info "已取消卸载。"
    fi
}

install_jb() {
    info "正在安装快捷命令 'jb'..."
    local script_path="$(readlink -f "$0")"
    if [ -w "/usr/local/bin" ]; then
        sudo ln -sf "$script_path" /usr/local/bin/jb
        sudo chmod +x /usr/local/bin/jb
        info "安装成功！现在你可以在任何地方输入 'jb' 来管理节点。"
    else
        # 如果没有权限，尝试写入 .bashrc
        if ! grep -q "alias jb=" "${HOME}/.bashrc"; then
            echo "alias jb='bash $script_path'" >> "${HOME}/.bashrc"
            info "已添加别名到 .bashrc，请执行 'source ~/.bashrc' 或重新登录后使用 'jb' 命令。"
        else
            info "快捷命令已存在。"
        fi
    fi
}

# 主循环
if [ $# -gt 0 ]; then
    case "$1" in
        view) view_nodes ;;
        status) check_status ;;
        stop) stop_all ;;
        uninstall) uninstall_all ;;
        install) install_jb ;;
        *) err "未知参数: $1" ;;
    esac
    exit 0
fi

while true; do
    show_menu
    read -r choice || break
    case "$choice" in
        1) view_nodes ;;
        2) check_status ;;
        3) stop_all ;;
        4) uninstall_all ;;
        5) install_jb ;;
        0) exit 0 ;;
        *) warn "无效选择" ;;
    esac
    echo -e "\n按回车键返回菜单..."
    read -r
done
