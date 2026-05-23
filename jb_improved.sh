#!/bin/bash
# jiaoben 管理脚本 - 改进版本
# 支持帮助信息、参数验证、安全检查

# 加载公共配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# 设置错误处理
set_error_trap

# 显示帮助信息
show_help() {
    cat << 'HELP'
╔════════════════════════════════════════════════════════════════╗
║           jiaoben 节点管理工具 - 使用帮助                      ║
╚════════════════════════════════════════════════════════════════╝

用法: jb [命令] [选项]

命令:
  status              显示所有服务状态
  start <service>     启动指定服务
  stop <service>      停止指定服务
  restart <service>   重启指定服务
  logs <service>      查看指定服务的日志
  list                列出所有可用服务
  nodes               显示所有节点信息
  help                显示此帮助信息

服务列表:
  xray-reality        XRay Reality 服务
  xray-vless          XRay VLESS 服务
  hy2                 Hysteria 2 服务
  argo-tunnel         Cloudflare Argo 隧道

示例:
  jb status                    # 查看所有服务状态
  jb start hy2                 # 启动 Hysteria 2 服务
  jb logs xray-reality         # 查看 XRay Reality 日志
  jb nodes                     # 显示所有节点链接

选项:
  --help, -h          显示此帮助信息
  --version, -v       显示版本信息

HELP
}

# 显示版本信息
show_version() {
    echo "jiaoben v2.0.0 (DeepSeek Enhanced)"
    echo "最后更新: 2026-05-23"
}

# 参数验证
validate_service() {
    local service="$1"
    local valid_services=("xray-reality" "xray-vless" "hy2" "argo-tunnel")
    
    for valid in "${valid_services[@]}"; do
        if [ "$service" = "$valid" ]; then
            return 0
        fi
    done
    
    log_error "无效的服务: $service"
    log_info "有效的服务: ${valid_services[*]}"
    return 1
}

# 显示服务状态
show_status() {
    local service="$1"
    
    if [ -z "$service" ]; then
        # 显示所有服务状态
        log_info "=== 所有服务状态 ==="
        systemctl list-units --type=service --all | grep -E "xray|hy2|argo" || \
            log_warn "未找到相关服务"
    else
        # 显示指定服务状态
        validate_service "$service" || return 1
        systemctl status "jiaoben-$service" 2>/dev/null || \
            log_error "服务 $service 不存在或未安装"
    fi
}

# 启动服务
start_service() {
    local service="$1"
    [ -z "$service" ] && { log_error "请指定要启动的服务"; return 1; }
    validate_service "$service" || return 1
    
    log_info "正在启动服务: $service"
    sudo systemctl start "jiaoben-$service" || { log_error "启动失败"; return 1; }
    log_info "服务 $service 已启动"
}

# 停止服务
stop_service() {
    local service="$1"
    [ -z "$service" ] && { log_error "请指定要停止的服务"; return 1; }
    validate_service "$service" || return 1
    
    log_info "正在停止服务: $service"
    sudo systemctl stop "jiaoben-$service" || { log_error "停止失败"; return 1; }
    log_info "服务 $service 已停止"
}

# 重启服务
restart_service() {
    local service="$1"
    [ -z "$service" ] && { log_error "请指定要重启的服务"; return 1; }
    validate_service "$service" || return 1
    
    log_info "正在重启服务: $service"
    sudo systemctl restart "jiaoben-$service" || { log_error "重启失败"; return 1; }
    log_info "服务 $service 已重启"
}

# 查看日志
show_logs() {
    local service="$1"
    [ -z "$service" ] && { log_error "请指定要查看日志的服务"; return 1; }
    validate_service "$service" || return 1
    
    log_info "=== 服务日志: $service (最近 50 行) ==="
    sudo journalctl -u "jiaoben-$service" -n 50 -f || \
        log_error "无法获取日志"
}

# 列出所有服务
list_services() {
    log_info "=== 可用的服务 ==="
    echo "  • xray-reality    - XRay Reality 协议服务"
    echo "  • xray-vless      - XRay VLESS 协议服务"
    echo "  • hy2             - Hysteria 2 协议服务"
    echo "  • argo-tunnel     - Cloudflare Argo 隧道"
}

# 显示节点信息
show_nodes() {
    log_info "=== 所有节点信息 ==="
    get_all_nodes
}

# 主程序
main() {
    # 检查参数
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        status)
            show_status "$@"
            ;;
        start)
            start_service "$@"
            ;;
        stop)
            stop_service "$@"
            ;;
        restart)
            restart_service "$@"
            ;;
        logs)
            show_logs "$@"
            ;;
        list)
            list_services
            ;;
        nodes)
            show_nodes
            ;;
        help|--help|-h)
            show_help
            ;;
        version|--version|-v)
            show_version
            ;;
        *)
            log_error "未知命令: $command"
            echo "使用 'jb help' 查看帮助信息"
            exit 1
            ;;
    esac
}

# 执行主程序
main "$@"
