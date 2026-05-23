#!/usr/bin/env bash
# ==========================================
# jiaoben - 科学上网四合一精简版
# 一个脚本完成安装、管理、卸载
# ==========================================

set -Euo pipefail

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 日志函数 ---
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# --- 配置 ---
WORK_DIR="${HOME}/.jiaoben"
mkdir -p "$WORK_DIR"

# --- 系统检测 ---
check_system() {
    info "检查系统环境..."
    [[ $EUID -ne 0 ]] && error "此脚本必须以 root 身份运行"
    [[ ! -f /etc/os-release ]] && error "无法识别操作系统"
    
    source /etc/os-release
    OS=$ID
    
    if command -v apt-get &> /dev/null; then
        PKG_MGR="apt-get"; PKG_UPDATE="apt-get update"; PKG_INSTALL="apt-get install -y"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"; PKG_UPDATE="yum update -y"; PKG_INSTALL="yum install -y"
    else
        error "不支持的包管理器"
    fi
    success "系统检查完成: $OS"
}

# --- 依赖安装 ---
install_deps() {
    info "安装系统依赖..."
    $PKG_UPDATE > /dev/null 2>&1 || true
    local deps="curl wget unzip jq qrencode openssl"
    $PKG_INSTALL $deps > /dev/null 2>&1
    success "依赖安装完成"
}

# --- 工具函数 ---
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_port() { shuf -i 10000-65000 -n 1; }
gen_password() { openssl rand -base64 16; }
get_ip() { curl -s --connect-timeout 5 https://api.ipify.org || echo "127.0.0.1"; }

# --- 下载二进制 ---
download_xray() {
    info "下载 Xray..."
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    if [[ ! -f "$WORK_DIR/xray/xray" ]]; then
        mkdir -p "$WORK_DIR/xray"
        wget -q "$url" -O "$WORK_DIR/xray/xray.zip" || error "Xray 下载失败"
        unzip -qo "$WORK_DIR/xray/xray.zip" -d "$WORK_DIR/xray" || error "Xray 解压失败"
        chmod +x "$WORK_DIR/xray/xray"
        rm -f "$WORK_DIR/xray/xray.zip"
    fi
    success "Xray 已就绪"
}

download_hysteria() {
    info "下载 Hysteria2..."
    local url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64"
    if [[ ! -f "$WORK_DIR/hysteria2/hysteria" ]]; then
        mkdir -p "$WORK_DIR/hysteria2"
        wget -q "$url" -O "$WORK_DIR/hysteria2/hysteria" || error "Hysteria2 下载失败"
        chmod +x "$WORK_DIR/hysteria2/hysteria"
    fi
    success "Hysteria2 已就绪"
}

download_cloudflared() {
    info "下载 Cloudflared..."
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    if [[ ! -f "$WORK_DIR/cloudflared/cloudflared" ]]; then
        mkdir -p "$WORK_DIR/cloudflared"
        wget -q "$url" -O "$WORK_DIR/cloudflared/cloudflared" || error "Cloudflared 下载失败"
        chmod +x "$WORK_DIR/cloudflared/cloudflared"
    fi
    success "Cloudflared 已就绪"
}

# --- 部署 REALITY ---
deploy_reality() {
    info "部署 REALITY..."
    download_xray
    local port=$(gen_port); local uuid=$(gen_uuid); local ip=$(get_ip)
    local keys=$("$WORK_DIR/xray/xray" x25519)
    local private_key=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
    local public_key=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')
    local short_id=$(openssl rand -hex 8)

    cat > "$WORK_DIR/xray/reality.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $port, "protocol": "vless",
    "settings": {"clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "www.google.com:443", "xver": 0,
        "serverNames": ["www.google.com", "images.google.com"],
        "privateKey": "$private_key", "shortIds": ["$short_id"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    cat > /etc/systemd/system/xray-reality.service <<EOF
[Unit]
Description=Xray REALITY Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=$WORK_DIR/xray/xray -c $WORK_DIR/xray/reality.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now xray-reality
    local link="vless://$uuid@$ip:$port?encryption=none&security=reality&sni=www.google.com&fp=chrome&pbk=$public_key&sid=$short_id&flow=xtls-rprx-vision#REALITY-$ip"
    echo -e "\n=== REALITY 节点 ===\n$link\n" >> "$WORK_DIR/nodes.txt"
    success "REALITY 部署完成"
    echo -e "${GREEN}节点链接:${NC} $link"
}

# --- 部署 Hysteria2 ---
deploy_hysteria2() {
    info "部署 Hysteria2..."
    download_hysteria
    local port=$(gen_port); local password=$(gen_password); local ip=$(get_ip)
    openssl req -newkey rsa:2048 -nodes -keyout "$WORK_DIR/hysteria2/server.key" -x509 -days 3650 -out "$WORK_DIR/hysteria2/server.crt" -subj "/CN=www.bing.com" >/dev/null 2>&1

    cat > "$WORK_DIR/hysteria2/config.yaml" <<EOF
listen: :$port
tls:
  cert: $WORK_DIR/hysteria2/server.crt
  key: $WORK_DIR/hysteria2/server.key
auth:
  type: password
  password: $password
EOF
    cat > /etc/systemd/system/hy2.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=$WORK_DIR/hysteria2/hysteria -c $WORK_DIR/hysteria2/config.yaml server
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now hy2
    local link="hysteria2://$password@$ip:$port/?sni=www.bing.com&insecure=1#Hy2-$ip"
    echo -e "\n=== Hysteria2 节点 ===\n$link\n" >> "$WORK_DIR/nodes.txt"
    success "Hysteria2 部署完成"
    echo -e "${GREEN}节点链接:${NC} $link"
}

# --- 部署 Argo 隧道 ---
deploy_argo() {
    local protocol=${1:-vless}
    info "部署 Argo 隧道 ($protocol)..."
    download_xray; download_cloudflared
    local port=$(gen_port); local uuid=$(gen_uuid); local wspath="/$(openssl rand -hex 4)"
    
    cat > "$WORK_DIR/xray/argo.json" <<EOF
{
  "inbounds": [{
    "port": $port, "listen": "127.0.0.1", "protocol": "$protocol",
    "settings": {"clients": [{"id": "$uuid"}]$( [[ "$protocol" == "vless" ]] && echo ', "decryption": "none"' )},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "$wspath"}}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    cat > /etc/systemd/system/xray-argo.service <<EOF
[Unit]
Description=Xray Argo Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=$WORK_DIR/xray/xray -c $WORK_DIR/xray/argo.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now xray-argo
    
    info "正在获取 Argo 域名 (约需 10-30 秒)..."
    nohup "$WORK_DIR/cloudflared/cloudflared" tunnel --url "http://127.0.0.1:$port" > "$WORK_DIR/cloudflared.log" 2>&1 &
    local cf_pid=$!
    local argo_domain=""
    for i in {1..60}; do
        argo_domain=$(grep -oE 'https://[-a-zA-Z0-9.]+\.trycloudflare\.com' "$WORK_DIR/cloudflared.log" | head -n 1 | sed 's#https://##' || true)
        [[ -n "$argo_domain" ]] && break
        sleep 1
    done

    if [[ -n "$argo_domain" ]]; then
        local link=""
        if [[ "$protocol" == "vmess" ]]; then
            local vmess_json=$(cat <<EOF
{"v":"2","ps":"Argo-VMess","add":"www.cloudflare.com","port":"443","id":"$uuid","aid":"0","scy":"auto","net":"ws","type":"none","host":"$argo_domain","path":"$wspath","tls":"tls","sni":"$argo_domain"}
EOF
)
            link="vmess://$(echo -n "$vmess_json" | base64 | tr -d '\n')"
        else
            link="vless://$uuid@www.cloudflare.com:443?encryption=none&security=tls&sni=$argo_domain&type=ws&host=$argo_domain&path=$wspath#Argo-VLESS"
        fi
        echo -e "\n=== Argo ($protocol) 节点 ===\n$link\n" >> "$WORK_DIR/nodes.txt"
        success "Argo 隧道部署完成"
        echo -e "${GREEN}节点链接:${NC} $link"
    else
        warn "Argo 域名获取失败，请检查日志: $WORK_DIR/cloudflared.log"
    fi
}

# --- 管理面板 ---
management_panel() {
    while true; do
        echo -e "\n=== 管理面板 ==="
        echo "1. 查看所有节点"
        echo "2. 启动所有服务"
        echo "3. 停止所有服务"
        echo "4. 查看服务状态"
        echo "5. 查看日志"
        echo "6. 返回主菜单"
        read -p "请选择: " choice
        case $choice in
            1) echo -e "\n--- 已安装节点信息 ---"; cat "$WORK_DIR/nodes.txt" 2>/dev/null || echo "暂无节点信息" ;;
            2) systemctl start xray-reality hy2 xray-argo 2>/dev/null; success "服务已尝试启动" ;;
            3) systemctl stop xray-reality hy2 xray-argo 2>/dev/null; success "服务已尝试停止" ;;
            4) systemctl status xray-reality hy2 xray-argo 2>/dev/null || true ;;
            5) journalctl -u xray-reality -u hy2 -u xray-argo -n 20 ;;
            6) break ;;
            *) warn "无效选择" ;;
        esac
    done
}

# --- 卸载 ---
uninstall_all() {
    read -p "确认卸载所有服务？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    systemctl stop xray-reality hy2 xray-argo 2>/dev/null || true
    systemctl disable xray-reality hy2 xray-argo 2>/dev/null || true
    rm -f /etc/systemd/system/xray-reality.service /etc/systemd/system/hy2.service /etc/systemd/system/xray-argo.service
    systemctl daemon-reload
    rm -rf "$WORK_DIR"
    success "卸载完成"
}

# --- 主菜单 ---
main_menu() {
    while true; do
        echo -e "\n========================================="
        echo "  jiaoben - 科学上网四合一精简版"
        echo "========================================="
        echo "1. 部署 REALITY"
        echo "2. 部署 Hysteria2"
        echo "3. 部署 VMess + Argo"
        echo "4. 部署 VLESS + Argo"
        echo "5. 管理面板"
        echo "6. 卸载全部"
        echo "0. 退出"
        read -p "请选择: " choice
        case $choice in
            1) deploy_reality ;;
            2) deploy_hysteria2 ;;
            3) deploy_argo vmess ;;
            4) deploy_argo vless ;;
            5) management_panel ;;
            6) uninstall_all ;;
            0) exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

check_system
install_deps
main_menu
