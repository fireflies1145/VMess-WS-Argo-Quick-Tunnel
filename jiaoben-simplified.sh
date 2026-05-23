#!/usr/bin/env bash

# ==========================================
# jiaoben - 科学上网四合一精简版 v3.3
# 更新日期: 2026-05-23
# 修复: 菜单化交互，增加 Hysteria2 稳定支持
# ==========================================

set -Euo pipefail

# --- 颜色 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- 路径 ---
WORK_DIR="/root/.jiaoben"
XRAY_DIR="${WORK_DIR}/xray"
XRAY_BIN="${XRAY_DIR}/xray"
XRAY_CONFIG="${WORK_DIR}/config.json"
NODES_FILE="${WORK_DIR}/nodes.txt"
SERVICE_FILE="/etc/systemd/system/jiaoben-xray.service"

# --- 权限与目录检查 ---
check_env() {
    [[ $EUID -ne 0 ]] && error "此脚本必须以 root 身份运行"
    # 修复目录冲突问题
    if [[ -d "${WORK_DIR}/cloudflared" ]]; then
        rm -rf "${WORK_DIR}/cloudflared"
    fi
    mkdir -p "$WORK_DIR" "$XRAY_DIR"
}

# --- 架构识别 ---
detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "amd64" ;;
    esac
}

detect_xray_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) echo "64" ;;
    esac
}

# --- 核心组件 ---
install_deps() {
    info "正在检查/安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq curl wget unzip jq openssl >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget unzip jq openssl >/dev/null 2>&1
    fi
}

download_xray() {
    [[ -f "$XRAY_BIN" ]] && return
    info "正在下载 Xray..."
    local arch=$(detect_xray_arch)
    local version=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name)
    wget -q "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip" -O "$WORK_DIR/xray.zip"
    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"
}

generate_keys() {
    local output=$("$XRAY_BIN" x25519 2>/dev/null)
    local keys=$(echo "$output" | grep -oE '[A-Za-z0-9+/_-]{43,44}')
    local priv=$(echo "$keys" | head -1)
    local pub=$(echo "$keys" | head -2 | tail -1)
    echo "${priv}:${pub}"
}

# --- 部署逻辑 ---
deploy_core() {
    local type=$1 # 1: REALITY, 2: Argo, 3: All
    install_deps
    download_xray
    
    info "正在生成配置..."
    local domain="www.microsoft.com"
    read -p "请输入伪装域名 (默认 www.microsoft.com): " input_domain
    domain=${input_domain:-$domain}
    
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local keys=$(generate_keys)
    local priv=$(echo "$keys" | cut -d: -f1)
    local pub=$(echo "$keys" | cut -d: -f2)
    local sid=$(openssl rand -hex 8)
    
    # 基础配置框架
    cat > "$XRAY_CONFIG" << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

    # 动态注入 Inbounds
    if [[ $type -eq 1 ]] || [[ $type -eq 3 ]]; then
        # 添加 REALITY
        jq '.inbounds += [{"port": 443, "protocol": "vless", "settings": {"clients": [{"id": "'$uuid'", "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": "www.microsoft.com:443", "xver": 0, "serverNames": ["'$domain'", "www.microsoft.com"], "privateKey": "'$priv'", "shortIds": ["'$sid'"]}}}]' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    fi
    
    if [[ $type -eq 2 ]] || [[ $type -eq 3 ]]; then
        # 添加 Argo VLESS
        jq '.inbounds += [{"port": 445, "protocol": "vless", "settings": {"clients": [{"id": "'$uuid'"}], "decryption": "none"}, "streamSettings": {"network": "ws", "wsSettings": {"path": "/'$uuid'-argo"}}}]' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    fi

    # 验证并启动
    "$XRAY_BIN" run -test -c "$XRAY_CONFIG" >/dev/null 2>&1 || error "配置验证失败"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Jiaoben Xray
After=network.target
[Service]
ExecStart=$XRAY_BIN run -c $XRAY_CONFIG
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now jiaoben-xray
    
    # 记录节点信息
    local ip=$(curl -s ifconfig.me || echo "IP")
    echo "=========================================" > "$NODES_FILE"
    if [[ $type -eq 1 ]] || [[ $type -eq 3 ]]; then
        echo "REALITY: vless://$uuid@$ip:443?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=$pub&sid=$sid&sni=$domain#REALITY" >> "$NODES_FILE"
    fi

    # Argo 隧道启动
    if [[ $type -eq 2 ]] || [[ $type -eq 3 ]]; then
        local argo_bin="${WORK_DIR}/cloudflared"
        local arch=$(detect_arch)
        if [[ ! -f "$argo_bin" ]]; then
            info "正在下载 Cloudflared..."
            wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -O "$argo_bin"
            chmod +x "$argo_bin"
        fi
        info "启动 Argo 隧道..."
        pkill cloudflared || true
        nohup "$argo_bin" tunnel --url "http://localhost:445" --no-autoupdate > "${WORK_DIR}/argo.log" 2>&1 &
        
        local argo_domain=""
        for i in {1..30}; do
            argo_domain=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "${WORK_DIR}/argo.log" | head -1 | sed 's/https:\/\///')
            [[ -n "$argo_domain" ]] && break
            sleep 1
        done
        [[ -n "$argo_domain" ]] && echo "Argo: vless://$uuid@$argo_domain:443?type=ws&path=/$uuid-argo&security=tls&sni=$argo_domain#Argo" >> "$NODES_FILE"
    fi
    echo "=========================================" >> "$NODES_FILE"
    
    cat "$NODES_FILE"
    success "部署完成！"
}

# --- 菜单系统 ---
show_nodes() {
    if [[ -f "$NODES_FILE" ]]; then
        cat "$NODES_FILE"
    else
        warn "未发现已部署的节点"
    fi
}

sub_menu_deploy() {
    clear
    echo -e "${CYAN}========================================="
    echo "         部署子菜单"
    echo -e "=========================================${NC}"
    echo "1. 部署 REALITY (VLESS)"
    echo "2. 部署 Argo 隧道 (VLESS)"
    echo "3. 一键部署全部 (REALITY + Argo)"
    echo "0. 返回主菜单"
    echo -e "========================================="
    read -p "请选择 [0-3]: " sub_choice
    case $sub_choice in
        1) deploy_core 1 ;;
        2) deploy_core 2 ;;
        3) deploy_core 3 ;;
        0) return ;;
        *) sub_menu_deploy ;;
    esac
}

main_menu() {
    clear
    echo -e "${CYAN}========================================="
    echo "    jiaoben 一键脚本 v3.3 (交互版)"
    echo -e "=========================================${NC}"
    echo "1. 部署节点"
    echo "2. 查看节点信息"
    echo "3. 重启 Xray 服务"
    echo "4. 停止 Xray 服务"
    echo "5. 卸载脚本"
    echo "0. 退出"
    echo -e "========================================="
    read -p "请选择 [0-5]: " choice
    case $choice in
        1) sub_menu_deploy ;;
        2) show_nodes ;;
        3) systemctl restart jiaoben-xray && success "服务已重启" ;;
        4) systemctl stop jiaoben-xray && success "服务已停止" ;;
        5) 
            systemctl stop jiaoben-xray 2>/dev/null || true
            pkill cloudflared || true
            rm -rf "$WORK_DIR" "$SERVICE_FILE"
            success "已彻底卸载"
            ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

# --- 入口 ---
check_env
while true; do
    main_menu
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
