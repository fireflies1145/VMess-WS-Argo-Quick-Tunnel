#!/usr/bin/env bash
set -Euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
prompt() { echo -e "${CYAN}[INPUT]${NC} $*"; }

WORK_DIR="${HOME}/.jiaoben"
mkdir -p "$WORK_DIR"
NODES_FILE="${WORK_DIR}/nodes.txt"
XRAY_DIR="${WORK_DIR}/xray"
XRAY_BIN="${XRAY_DIR}/xray"
XRAY_CONFIG="${WORK_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/jiaoben-xray.service"

check_root() {
    [[ $EUID -ne 0 ]] && error "此脚本需要 root 权限运行"
}

detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) error "不支持的架构: $arch" ;;
    esac
}

download_file() {
    local url="$1" output="$2"
    curl -fsSL --connect-timeout 10 "$url" -o "$output" || error "下载失败: $url"
}

install_xray() {
    [[ -f "$XRAY_BIN" ]] && return
    local arch=$(detect_arch)
    local version=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    info "安装 Xray v$version..."
    mkdir -p "$XRAY_DIR"
    download_file "https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip" "$WORK_DIR/xray.zip"
    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"
}

generate_keys() {
    local output=$("$XRAY_BIN" x25519)
    # 使用正则表达式精确提取 Base64 字符串 (43-44位，含 Base64URL 字符)
    local keys=$(echo "$output" | grep -oE '[A-Za-z0-9_-]{43,44}')
    local priv=$(echo "$keys" | head -1)
    local pub=$(echo "$keys" | head -2 | tail -1)
    echo "${priv}:${pub}"
}

deploy_config() {
    local domain=$1 port_vless=$2 port_hy2=$3 port_argo=$4
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local keys=$(generate_keys)
    local priv=$(echo "$keys" | cut -d: -f1)
    local pub=$(echo "$keys" | cut -d: -f2)
    local sid=$(openssl rand -hex 8)
    local pass=$(openssl rand -base64 12)

    [[ -z "$priv" || -z "$pub" ]] && error "密钥生成失败"

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
          "show": false, "dest": "www.microsoft.com:443", "xver": 0,
          "serverNames": ["$domain", "www.microsoft.com"],
          "privateKey": "$priv", "shortIds": ["$sid"]
        }
      }
    },
    {
      "port": $port_hy2, "protocol": "hysteria2",
      "settings": {"clients": [{"password": "$pass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "$domain", "alpn": ["h3"]}}
    },
    {
      "port": $port_argo, "protocol": "vless",
      "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/$uuid-argo"}}
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    
    # 验证配置
    "$XRAY_BIN" run -test -c "$XRAY_CONFIG" >/dev/null 2>&1 || error "配置验证失败"
    
    # 写入 systemd
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
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now jiaoben-xray 2>/dev/null || true

    # 保存节点
    local ip=$(curl -s ifconfig.me || echo "IP")
    {
        echo "=== 节点信息 ==="
        echo "REALITY: vless://$uuid@$ip:$port_vless?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=$pub&sid=$sid&sni=$domain#REALITY"
        echo "Hysteria2: hysteria2://$pass@$ip:$port_hy2?insecure=1&sni=$domain#Hy2"
    } > "$NODES_FILE"
    
    echo "$uuid"
}

setup_argo() {
    local port=$1 uuid=$2
    local argo_bin="$WORK_DIR/cloudflared"
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) error "不支持的架构: $arch" ;;
    esac
    [[ ! -f "$argo_bin" ]] && download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" "$argo_bin" && chmod +x "$argo_bin"
    
    info "启动 Argo 隧道..."
    nohup "$argo_bin" tunnel --url "http://localhost:$port" --no-autoupdate > "$WORK_DIR/argo.log" 2>&1 &
    
    local domain=""
    for i in {1..30}; do
        domain=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$WORK_DIR/argo.log" | head -1 | sed 's/https:\/\///')
        [[ -n "$domain" ]] && break
        sleep 1
    done
    
    if [[ -n "$domain" ]]; then
        success "Argo 域名: $domain"
        echo "Argo: vless://$uuid@$domain:443?type=ws&path=/$uuid-argo&security=tls&sni=$domain#Argo" >> "$NODES_FILE"
    fi
}

# --- 主逻辑 ---
check_root
install_xray
read -p "请输入伪装域名 (默认 www.microsoft.com): " domain
domain=${domain:-www.microsoft.com}
uuid=$(deploy_config "$domain" 443 444 445)
setup_argo 445 "$uuid"
success "部署完成！"
cat "$NODES_FILE"
