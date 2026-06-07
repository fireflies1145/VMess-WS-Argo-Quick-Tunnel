#!/bin/bash
# ==========================================
# jiaoben 管理脚本 - 改进版本 v2.1
# 更新日期: 2026-06-07
# 修复: service_exists 逻辑、兼容数据格式
# ==========================================
set -Euo pipefail

# 加载公共配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/common.sh" ]]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "[ERROR] 未找到 common.sh，请确保在同一目录下运行" >&2
    exit 1
fi

set_error_trap

# ==========================================
# 服务存在性检查（修复版）
# ==========================================
service_exists() {
    [[ -f "/etc/systemd/system/jiaoben-$1.service" ]]
}

# ==========================================
# 帮助信息
# ==========================================
show_help() {
    cat <<'HELP'
╔════════════════════════════════════════════════════════════════╗
║              jiaoben 节点管理工具 - 使用帮助                  ║
╚════════════════════════════════════════════════════════════════╝

用法: jb [命令] [选项]

命令:
  status    显示所有服务状态
  start     启动指定服务
  stop      停止指定服务
  restart   重启指定服务
  logs      查看指定服务的日志
  list      列出所有可用服务
  nodes     显示所有节点信息
  help      显示此帮助信息

服务列表:
  xray      Xray 服务
  hy2       Hysteria 2 服务
  argo      Cloudflare Argo 隧道

示例:
  jb status          # 查看所有服务状态
  jb start hy2       # 启动 Hysteria 2 服务
  jb logs xray       # 查看 Xray 日志
  jb nodes           # 显示所有节点链接

选项:
  --help, -h         显示此帮助信息
  --version, -v      显示版本信息
HELP
}

# ==========================================
# 版本信息
# ==========================================
show_version() {
    echo "jiaoben 管理工具 v2.1"
    echo "最后更新: 2026-06-07"
}

# ==========================================
# 参数验证
# ==========================================
validate_service() {
    local service="$1"
    local valid_services=("xray" "hy2" "argo")

    for valid in "${valid_services[@]}"; do
        if [[ "$service" == "$valid" ]]; then
            return 0
        fi
    done

    log_error "无效的服务: $service"
    log_info "有效的服务: ${valid_services[*]}"
    return 1
}

# ==========================================
# 显示服务状态
# ==========================================
show_status() {
    local service="$1"

    if [[ -z "$service" ]]; then
        log_info "=== 所有 jiaoben 服务状态 ==="
        local found=0
        for svc in xray hy2 argo; do
            if service_exists "$svc"; then
                systemctl status "jiaoben-$svc" --no-pager -l 2>/dev/null || true
                echo ""
                found=1
            fi
        done
        [[ $found -eq 0 ]] && log_warn "未发现任何 jiaoben 服务"
    else
        validate_service "$service" || return 1
        if service_exists "$service"; then
            systemctl status "jiaoben-$service" --no-pager -l 2>/dev/null || true
        else
            log_error "服务 $service 不存在或未安装"
            return 1
        fi
    fi
}

# ==========================================
# 启动服务
# ==========================================
start_service() {
    local service="$1"
    [[ -z "$service" ]] && { log_error "请指定要启动的服务"; return 1; }
    validate_service "$service" || return 1
    if ! service_exists "$service"; then
        log_error "服务 $service 未安装"
        return 1
    fi
    log_info "正在启动服务: $service"
    systemctl start "jiaoben-$service" || { log_error "启动失败"; return 1; }
    log_success "服务 $service 已启动"
}

# ==========================================
# 停止服务
# ==========================================
stop_service() {
    local service="$1"
    [[ -z "$service" ]] && { log_error "请指定要停止的服务"; return 1; }
    validate_service "$service" || return 1
    if ! service_exists "$service"; then
        log_error "服务 $service 未安装"
        return 1
    fi
    log_info "正在停止服务: $service"
    systemctl stop "jiaoben-$service" || { log_error "停止失败"; return 1; }
    log_success "服务 $service 已停止"
}

# ==========================================
# 重启服务
# ==========================================
restart_service() {
    local service="$1"
    [[ -z "$service" ]] && { log_error "请指定要重启的服务"; return 1; }
    validate_service "$service" || return 1
    if ! service_exists "$service"; then
        log_error "服务 $service 未安装"
        return 1
    fi
    log_info "正在重启服务: $service"
    systemctl restart "jiaoben-$service" || { log_error "重启失败"; return 1; }
    log_success "服务 $service 已重启"
}

# ==========================================
# 查看日志
# ==========================================
show_logs() {
    local service="$1"
    [[ -z "$service" ]] && { log_error "请指定要查看日志的服务"; return 1; }
    validate_service "$service" || return 1
    if ! service_exists "$service"; then
        log_error "服务 $service 未安装"
        return 1
    fi
    log_info "=== 服务日志: $service（实时，Ctrl+C 退出）==="
    journalctl -u "jiaoben-$service" -n 50 -f 2>/dev/null || \
        log_error "无法获取日志（可能需要 root 权限）"
}

# ==========================================
# 列出所有服务
# ==========================================
list_services() {
    log_info "=== 可用的服务 ==="
    echo "  • xray  - Xray 协议服务 (VLESS + REALITY / WebSocket)"
    echo "  • hy2   - Hysteria 2 协议服务 (QUIC)"
    echo "  • argo  - Cloudflare Argo 隧道"

    echo ""
    log_info "=== 已安装的服务 ==="
    local found=0
    for svc in xray hy2 argo; do
        if service_exists "$svc"; then
            local status
            status=$(systemctl is-active "jiaoben-$svc" 2>/dev/null || echo "unknown")
            echo "  • jiaoben-$svc  [$status]"
            found=1
        fi
    done
    [[ $found -eq 0 ]] && echo "  （无）"
}

# ==========================================
# 显示节点信息
# ==========================================
show_nodes() {
    log_info "=== 所有节点信息 ==="
    if [[ -f "$INFO_FILE" ]]; then
        cat "$INFO_FILE"
    else
        log_warn "未发现节点信息文件"
    fi
}

# ==========================================
# 主程序
# ==========================================
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    local command="$1"
    shift

    case "$command" in
        status)     show_status "$@" ;;
        start)      start_service "$@" ;;
        stop)       stop_service "$@" ;;
        restart)    restart_service "$@" ;;
        logs)       show_logs "$@" ;;
        list)       list_services ;;
        nodes)      show_nodes ;;
        help|--help|-h)     show_help ;;
        version|--version|-v) show_version ;;
        *)
            log_error "未知命令: $command"
            echo "使用 'jb help' 查看帮助信息"
            exit 1
            ;;
    esac
}

main "$@"