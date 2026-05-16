#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# 科学上网四合一全自动部署脚本
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 基础配置
ARCH="$(uname -m)"
INFO_FILE="${HOME}/all_nodes_info.txt"
: > "$INFO_FILE"

# 打印信息函数
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err() { printf "${RED}[x]${NC} %s\n" "$*"; }

# 架构检查
case "$ARCH" in
    x86_64|amd64) XRAY_PKG="Xray-linux-64.zip"; CF_BIN="cloudflared-linux-amd64"; HY_BIN="hysteria-linux-amd64" ;;
    aarch64|arm64) XRAY_PKG="Xray-linux-arm64-v8a.zip"; CF_BIN="cloudflared-linux-arm64"; HY_BIN="hysteria-linux-arm64" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac

# 依赖检查
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { err "缺少依赖: $1"; exit 1; }
}
for cmd in curl unzip openssl grep sed base64 tr head; do need_cmd "$cmd"; done

# 端口检测
check_port() {
    local port="$1"
    (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1 && return 0
    command -v ss >/dev/null 2>&1 && ss -tlnp 2>/dev/null | grep -q ":$port " && return 0
    return 1
}

# 随机端口
get_random_port() {
    local port
    while true; do
        port=$(( ( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 50000) + 10000 ))
        ! check_port "$port" && echo "$port" && return 0
    done
}

# 获取公网 IP
get_ip() {
    curl -s --connect-timeout 5 https://api.ipify.org || echo "127.0.0.1"
}

# --- 模块 1: VLESS + TCP + REALITY ---
deploy_reality() {
    info "正在部署 [1/4] VLESS + TCP + REALITY (偷 Apple)..."
    local workdir="${HOME}/vless-reality"
    mkdir -p "$workdir" && cd "$workdir"
    
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_PKG}" -o xray.zip
    unzip -qo xray.zip xray geoip.dat geosite.dat && chmod +x xray && rm xray.zip

    local port=$(get_random_port)
    local uuid=$(./xray uuid)
    local keys=$(./xray x25519)
    local private_key=$(echo "$keys" | grep "PrivateKey:" | awk -F': ' '{print $2}')
    local public_key=$(echo "$keys" | grep "PublicKey):" | awk -F': ' '{print $2}')
    local short_id=$(openssl rand -hex 8)
    local ip=$(get_ip)

    cat > config.json <<EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "port": $port, "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": false, "dest": "www.apple.com:443", "xver": 0,
                "serverNames": ["www.apple.com", "images.apple.com"],
                "privateKey": "$private_key",
                "shortIds": ["$short_id"]
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    nohup ./xray run > xray.log 2>&1 &
    echo $! > xray.pid
    
    local link="vless://$uuid@$ip:$port?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=$public_key&sid=$short_id&flow=xtls-rprx-vision#REALITY-Apple"
    {
        echo "--- VLESS + TCP + REALITY ---"
        echo "Address: $ip"
        echo "Port: $port"
        echo "UUID: $uuid"
        echo "PublicKey: $public_key"
        echo "ShortID: $short_id"
        echo "SNI: www.apple.com"
        echo "Link: $link"
        echo ""
    } >> "$INFO_FILE"
}

# --- 模块 2: Hysteria 2 ---
deploy_hy2() {
    info "正在部署 [2/4] Hysteria 2 (偷 Bing)..."
    local workdir="${HOME}/hy2"
    mkdir -p "$workdir" && cd "$workdir"
    
    curl -fsSL "https://github.com/apernet/hysteria/releases/latest/download/${HY_BIN}" -o hysteria
    chmod +x hysteria

    local port=$(get_random_port)
    local password=$(openssl rand -hex 16)
    local ip=$(get_ip)
    
    openssl req -newkey rsa:2048 -nodes -keyout server.key -x509 -days 3650 -out server.crt -subj "/CN=www.bing.com" >/dev/null 2>&1

    cat > config.yaml <<EOF
listen: :$port
tls:
  cert: $workdir/server.crt
  key: $workdir/server.key
auth:
  type: password
  password: $password
ignoreClientBandwidth: true
EOF
    nohup ./hysteria server --config config.yaml > hy2.log 2>&1 &
    echo $! > hy2.pid
    
    local link="hysteria2://$password@$ip:$port/?sni=www.bing.com&insecure=1#Hy2-Bing"
    {
        echo "--- Hysteria 2 ---"
        echo "Address: $ip"
        echo "Port: $port"
        echo "Password: $password"
        echo "SNI: www.bing.com"
        echo "Link: $link"
        echo ""
    } >> "$INFO_FILE"
}

# --- 模块 3 & 4: Argo 隧道 ---
deploy_argo() {
    local proto="$1"
    local step="$2"
    info "正在部署 [$step/4] $proto + Argo 隧道..."
    local workdir="${HOME}/${proto}-argo"
    mkdir -p "$workdir" && cd "$workdir"
    
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_PKG}" -o xray.zip
    unzip -qo xray.zip xray geoip.dat geosite.dat && chmod +x xray && rm xray.zip
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/${CF_BIN}" -o cloudflared
    chmod +x cloudflared

    local port=$(get_random_port)
    local uuid=$(./xray uuid)
    local wspath="/$(openssl rand -hex 8)"
    
    if [ "$proto" == "vmess" ]; then
        cat > config.json <<EOF
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":$port,"protocol":"vmess","settings":{"clients":[{"id":"$uuid"}]},"streamSettings":{"network":"ws","wsSettings":{"path":"$wspath"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
    else
        cat > config.json <<EOF
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":$port,"protocol":"vless","settings":{"clients":[{"id":"$uuid"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$wspath"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
    fi

    nohup ./xray run > xray.log 2>&1 &
    echo $! > xray.pid
    nohup ./cloudflared tunnel --url "http://127.0.0.1:$port" > cf.log 2>&1 &
    echo $! > cf.pid

    local argo_domain=""
    for i in {1..60}; do
        argo_domain=$(grep -oE 'https://[-a-zA-Z0-9.]+\.trycloudflare\.com' cf.log | head -n 1 | sed 's#https://##' || true)
        [ -n "$argo_domain" ] && break
        sleep 1
    done

    if [ -n "$argo_domain" ]; then
        if [ "$proto" == "vmess" ]; then
            local vmess_json=$(cat <<EOF
{"v":"2","ps":"Argo-VMess","add":"yg1.ygkkk.dpdns.org","port":"443","id":"$uuid","aid":"0","scy":"auto","net":"ws","type":"none","host":"$argo_domain","path":"$wspath","tls":"tls","sni":"$argo_domain"}
EOF
)
            local link="vmess://$(echo -n "$vmess_json" | base64 | tr -d '\n')"
        else
            local link="vless://$uuid@yg1.ygkkk.dpdns.org:443?encryption=none&security=tls&sni=$argo_domain&type=ws&host=$argo_domain&path=$wspath#Argo-VLESS"
        fi
        {
            echo "--- $proto + Argo 隧道 ---"
            echo "Argo Domain: $argo_domain"
            echo "UUID: $uuid"
            echo "Path: $wspath"
            echo "Link: $link"
            echo ""
        } >> "$INFO_FILE"
    else
        warn "$proto Argo 域名获取失败"
    fi
}

# 执行全自动部署
clear
echo -e "${CYAN}==========================================${NC}"
echo -e "${PURPLE}       科学上网四合一全自动部署           ${NC}"
echo -e "${CYAN}==========================================${NC}"
echo -e "${YELLOW}正在开始全自动部署，请稍候...${NC}"
echo ""

deploy_reality
deploy_hy2
deploy_argo "vmess" "3"
deploy_argo "vless" "4"

echo -e "${CYAN}==========================================${NC}"
echo -e "${GREEN}             部署完成！                 ${NC}"
echo -e "${CYAN}==========================================${NC}"
cat "$INFO_FILE"
echo -e "${CYAN}==========================================${NC}"
echo -e "${YELLOW}所有节点信息已保存至: $INFO_FILE${NC}"
echo -e "${CYAN}==========================================${NC}"
