#!/usr/bin/env bash

# ==========================================
# jiaoben - 科学上网四合一精简版 v3.0
# 100% 自动化，支持 REALITY, Hy2, Argo
# ==========================================

set -Euo pipefail

# --- 颜色与图标 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

CHECK="[${GREEN}✓${NC}]"
XMARK="[${RED}✗${NC}]"
INFO="[${BLUE}i${NC}]"
WARN="[${YELLOW}!${NC}]"

# --- 全局变量 ---
WORK_DIR="/root/.jiaoben"
XRAY_DIR="${WORK_DIR}/xray"
XRAY_BIN="${XRAY_DIR}/xray"
XRAY_CONFIG="${WORK_DIR}/config.json"
NODES_FILE="${WORK_DIR}/nodes.txt"
ARGO_LOG="${WORK_DIR}/argo.log"
SERVICE_NAME="jiaoben-xray"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- 基础函数 ---
log_info() { echo -e "${INFO} $*"; }
log_success() { echo -e "${CHECK} ${GREEN}$*${NC}"; }
log_warn() { echo -e "${WARN} ${YELLOW}$*${NC}"; }
log_error() { echo -e "${XMARK} ${RED}$*${NC}"; exit 1; }

check_root() {
    [[ $EUID -ne 0 ]] && log_error "此脚本必须以 root 身份运行"
}

init_dir() {
    mkdir -p "$WORK_DIR" "$XRAY_DIR"
}

# --- 架构识别 ---
get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) log_error "不支持的架构: $arch" ;;
    esac
}

# Xray 特有的架构命名
get_xray_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) echo "64" ;;
    esac
}

# --- 依赖安装 ---
install_deps() {
    log_info "检查并安装必要依赖..."
    local deps="curl wget unzip jq openssl coreutils"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq $deps >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q $deps >/dev/null 2>&1
    fi
}

# --- 核心组件下载 ---
download_xray() {
    if [[ -f "$XRAY_BIN" ]]; then
        log_success "Xray 已安装"
        return
    fi
    log_info "正在下载 Xray..."
    local arch=$(get_xray_arch)
    local version=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name)
    local url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
    
    wget -q --show-progress "$url" -O "$WORK_DIR/xray.zip" || log_error "Xray 下载失败"
    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"
    log_success "Xray 安装成功 ($version)"
}

download_cloudflared() {
    local argo_bin="${WORK_DIR}/cloudflared"
    if [[ -f "$argo_bin" ]]; then
        return
    fi
    log_info "正在下载 Cloudflared..."
    local arch=$(get_arch)
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    wget -q --show-progress "$url" -O "$argo_bin" || log_error "Cloudflared 下载失败"
    chmod +x "$argo_bin"
    log_success "Cloudflared 安装成功"
}

# --- 密钥生成 ---
generate_keys() {
    local output=$("$XRAY_BIN" x25519)
    # 使用正则表达式提取 Base64URL 格式的密钥
    local keys=$(echo "$output" | grep -oE '[A-Za-z0-9_-]{43,44}')
    local priv=$(echo "$keys" | head -1)
    local pub=$(echo "$keys" | head -2 | tail -1)
    echo "${priv}:${pub}"
}

# --- 部署逻辑 ---
deploy() {
    init_dir
    install_deps
    download_xray
    download_cloudflared

    echo -e "\n${PURPLE}--- 配置参数 ---${NC}"
    read -p "请输入伪装域名 (默认 www.microsoft.com): " domain
    domain=${domain:-www.microsoft.com}
    
    local port_vless=443
    local port_hy2=444
    local port_argo=445
    
    log_info "生成配置文件..."
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local keys=$(generate_keys)
    local priv=$(echo "$keys" | cut -d: -f1)
    local pub=$(echo "$keys" | cut -d: -f2)
    local sid=$(openssl rand -hex 8)
    local pass=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')

    cat > "$XRAY_CONFIG" << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $port_vless, "protocol": "vless",
      "settings": {"clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "www.google.com:443", "xver": 0,
          "serverNames": ["$domain", "www.microsoft.com"],
          "privateKey": "$priv", "shortIds": ["$sid"]
        }
      }
    },
    {
      "port": $port_hy2, "protocol": "hysteria2",
      "settings": {"clients": [{"password": "$pass"}]},
      "streamSettings": {
        "network": "tcp", "security": "tls",
        "tlsSettings": {"serverName": "$domain", "alpn": ["h3"]}
      }
    },
    {
      "port": $port_argo, "protocol": "vless",
      "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
      "streamSettings": {
        "network": "ws", "wsSettings": {"path": "/$uuid-argo"}
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

    log_info "验证配置..."
    "$XRAY_BIN" run -test -c "$XRAY_CONFIG" >/dev/null 2>&1 || log_error "配置验证失败"

    log_info "设置 Systemd 服务..."
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Jiaoben Xray Service
After=network.target
[Service]
ExecStart=$XRAY_BIN run -c $XRAY_CONFIG
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    
    log_info "启动 Argo 隧道 (请稍候)..."
    pkill cloudflared || true
    nohup "${WORK_DIR}/cloudflared" tunnel --url "http://localhost:$port_argo" --no-autoupdate > "$ARGO_LOG" 2>&1 &
    
    local argo_domain=""
    for i in {1..30}; do
        argo_domain=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" | head -1 | sed 's/https:\/\///')
        [[ -n "$argo_domain" ]] && break
        sleep 1
    done

    local ip=$(curl -s --connect-timeout 5 ifconfig.me || curl -s ipinfo.io/ip || echo "YOUR_IP")
    
    # 写入节点文件
    {
        echo "========================================="
        echo "        jiaoben 节点分享信息"
        echo "========================================="
        echo -e "REALITY (VLESS):\nvless://$uuid@$ip:$port_vless?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=$pub&sid=$sid&sni=$domain#REALITY"
        echo -e "\nHysteria2:\nhysteria2://$pass@$ip:$port_hy2?insecure=1&sni=$domain#Hy2"
        if [[ -n "$argo_domain" ]]; then
            echo -e "\nArgo VLESS:\nvless://$uuid@$argo_domain:443?type=ws&path=/$uuid-argo&security=tls&sni=$argo_domain#Argo"
        else
            echo -e "\nArgo VLESS: [启动失败，请检查 $ARGO_LOG]"
        fi
        echo "========================================="
    } > "$NODES_FILE"

    echo -e "\n"
    cat "$NODES_FILE"
    log_success "部署完成！"
}

# --- 管理功能 ---
show_nodes() {
    [[ ! -f "$NODES_FILE" ]] && log_warn "未发现节点信息" || cat "$NODES_FILE"
}

uninstall() {
    log_warn "正在卸载所有组件..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    pkill cloudflared || true
    rm -rf "$WORK_DIR"
    log_success "卸载完成"
}

# --- 主菜单 ---
menu() {
    clear
    echo -e "${CYAN}"
    echo "========================================="
    echo "    jiaoben - 科学上网四合一精简版"
    echo "========================================="
    echo -e "${NC}"
    echo "1. 一键部署 (REALITY + Hy2 + Argo)"
    echo "2. 查看节点信息"
    echo "3. 重启服务"
    echo "4. 停止服务"
    echo "5. 卸载脚本"
    echo "0. 退出"
    echo -e "\n"
    read -p "请选择 [0-5]: " choice

    case $choice in
        1) deploy ;;
        2) show_nodes ;;
        3) systemctl restart "$SERVICE_NAME" && log_success "服务已重启" ;;
        4) systemctl stop "$SERVICE_NAME" && log_success "服务已停止" ;;
        5) uninstall ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

# --- 入口 ---
check_root
menu
