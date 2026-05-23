#!/usr/bin/env bash

# ==========================================
# jiaoben - 科学上网四合一精简版 v3.1
# 更新日期: 2026-05-23
# 修复: Cloudflared 下载架构识别 (amd64)
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

# --- 权限检查 ---
[[ $EUID -ne 0 ]] && error "此脚本必须以 root 身份运行"
mkdir -p "$WORK_DIR" "$XRAY_DIR"

# --- 架构识别 ---
detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) error "不支持的架构: $arch" ;;
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

# --- 核心功能 ---
install_deps() {
    info "正在安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq curl wget unzip jq openssl >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget unzip jq openssl >/dev/null 2>&1
    fi
}

download_xray() {
    [[ -f "$XRAY_BIN" ]] && return
    info "正在安装 Xray..."
    local arch=$(detect_xray_arch)
    local version=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name)
    wget -q "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip" -O "$WORK_DIR/xray.zip"
    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"
}

generate_keys() {
    local output=$("$XRAY_BIN" x25519)
    local keys=$(echo "$output" | grep -oE '[A-Za-z0-9_-]{43,44}')
    local priv=$(echo "$keys" | head -1)
    local pub=$(echo "$keys" | head -2 | tail -1)
    echo "${priv}:${pub}"
}

deploy() {
    install_deps
    download_xray
    
    read -p "请输入伪装域名 (默认 www.microsoft.com): " domain
    domain=${domain:-www.microsoft.com}
    
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
      "port": 443, "protocol": "vless",
      "settings": {"clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "www.microsoft.com:443", "xver": 0,
          "serverNames": ["$domain", "www.microsoft.com"],
          "privateKey": "$priv", "shortIds": ["$sid"]
        }
      }
    },
    {
      "port": 444, "protocol": "hysteria2",
      "settings": {"clients": [{"password": "$pass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "$domain", "alpn": ["h3"]}}
    },
    {
      "port": 445, "protocol": "vless",
      "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/$uuid-argo"}}
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
