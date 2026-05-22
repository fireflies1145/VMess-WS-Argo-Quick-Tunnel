#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Jiaoben 统一管理快捷工具 (Pro 版)
# 特性：Systemd 服务管理, 实时日志查看
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

INFO_FILE="${HOME}/all_nodes_info.txt"
SERVICES=("xray-reality" "hy2" "xray-vmess-argo" "cf-vmess-argo" "xray-vless-argo" "cf-vless-argo")

info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err() { printf "${RED}[x]${NC} %s\n" "$*"; }

show_menu() {
    clear
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${PURPLE}       Jiaoben 快捷管理工具 (Pro)       ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN} 1.${NC} 查看所有节点链接"
    echo -e "${GREEN} 2.${NC} 检查服务运行状态 (Systemd)"
    echo -e "${GREEN} 3.${NC} 查看实时服务日志"
    echo -e "${GREEN} 4.${NC} 重启所有节点服务"
    echo -e "${GREEN} 5.${NC} 停止所有节点服务"
    echo -e "${GREEN} 6.${NC} 卸载并清理所有节点"
    echo -e "${RED} 0.${NC} 退出"
    echo -e "${CYAN}==========================================${NC}"
    printf "请选择 [0-6]: "
}

view_nodes() {
    if [ ! -s "$INFO_FILE" ]; then
        warn "暂无已部署的节点信息。"
    else
        echo -e "${CYAN}--- 当前已部署节点信息 ---${NC}"
        cat "$INFO_FILE"
    fi
}

check_status() {
    echo -e "${CYAN}--- 服务运行状态 ---${NC}"
    for svc in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            printf "%-20s: ${GREEN}运行中${NC}\n" "$svc"
        else
            printf "%-20s: ${RED}已停止${NC}\n" "$svc"
        fi
    done
}

view_logs() {
    echo -e "${CYAN}请选择要查看日志的服务:${NC}"
    select svc in "${SERVICES[@]}" "退出"; do
        [ "$svc" == "退出" ] && break
        [ -n "$svc" ] && sudo journalctl -u "$svc" -f -n 50
        break
    done
}

restart_all() {
    info "正在重启所有服务..."
    for svc in "${SERVICES[@]}"; do
        sudo systemctl restart "$svc" 2>/dev/null || true
    done
    info "重启完成。"
}

stop_all() {
    info "正在停止所有服务..."
    for svc in "${SERVICES[@]}"; do
        sudo systemctl stop "$svc" 2>/dev/null || true
    done
    info "停止完成。"
}

uninstall_all() {
    printf "${RED}确定要卸载并清理所有节点吗？(y/N): ${NC}"
    read -r confirm
    if [[ "${confirm,,}" =~ ^y(es)?$ ]]; then
        stop_all
        info "正在禁用服务并清理文件..."
        for svc in "${SERVICES[@]}"; do
            sudo systemctl disable "$svc" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/${svc}.service"
        done
        sudo systemctl daemon-reload
        rm -rf "${HOME}/vless-reality" "${HOME}/hy2" "${HOME}/vmess-argo" "${HOME}/vless-argo"
        rm -f "$INFO_FILE"
        info "清理完成。"
    else
        info "已取消卸载。"
    fi
}

while true; do
    show_menu
    read -r choice || break
    case "$choice" in
        1) view_nodes ;;
        2) check_status ;;
        3) view_logs ;;
        4) restart_all ;;
        5) stop_all ;;
        6) uninstall_all ;;
        0) exit 0 ;;
        *) warn "无效选择" ;;
    esac
    echo -e "\n按回车键返回菜单..."
    read -r
done
