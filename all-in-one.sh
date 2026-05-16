#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# 科学上网四合一集成脚本
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
READ_TIMEOUT=30

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

# 菜单界面
show_menu() {
    clear
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${PURPLE}       科学上网四合一集成脚本           ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN} 1.${NC} 部署 VLESS + TCP + REALITY (偷 Apple)"
    echo -e "${GREEN} 2.${NC} 部署 Hysteria 2 (偷 Bing, 无跳跃)"
    echo -e "${GREEN} 3.${NC} 部署 VMess + WS + Argo 隧道"
    echo -e "${GREEN} 4.${NC} 部署 VLESS + WS + Argo 隧道"
    echo -e "${RED} 0.${NC} 退出脚本"
    echo -e "${CYAN}==========================================${NC}"
    printf "请选择 [0-4]: "
}

# --- 模块 1: VLESS + TCP + REALITY ---
deploy_reality() {
    info "正在部署 VLESS + TCP + REALITY..."
    local workdir="${HOME}/vless-reality"
    mkdir -p "$workdir" && cd "$workdir"
    
    # 下载 Xray
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
    echo -e "\n${GREEN}部署成功！${NC}"
    echo -e "节点链接: ${BLUE}$link${NC}"
}

# --- 模块 2: Hysteria 2 ---
deploy_hy2() {
    info "正在部署 Hysteria 2..."
    local workdir="${HOME}/hy2"
    mkdir -p "$workdir" && cd "$workdir"
    
    curl -fsSL "https://github.com/apernet/hysteria/releases/latest/download/${HY_BIN}" -o hysteria
    chmod +x hysteria

    local port=$(get_random_port)
    local password=$(openssl rand -hex 16)
    local ip=$(get_ip)
    
    # 生成自签证书
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
    echo -e "\n${GREEN}部署成功！${NC}"
    echo -e "节点链接: ${BLUE}$link${NC}"
}

# --- 模块 3 & 4: Argo 隧道 (通用逻辑) ---
deploy_argo() {
    local proto="$1" # vmess or vless
    info "正在部署 $proto + Argo 隧道..."
    local workdir="${HOME}/${proto}-argo"
    mkdir -p "$workdir" && cd "$workdir"
    
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_PKG}" -o xray.zip
    unzip -qo xray.zip xray geoip.dat geosite.dat && chmod +x xray && rm xray.zip
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/${CF_BIN}" -o cloudflared
    chmod +x cloudflared

    local port=$(get_random_port)
    local uuid=$(./xray uuid)
    local wspath="/$(openssl rand -hex 8)"
    
    # 配置文件
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

    info "等待 Argo 域名分配..."
    local argo_domain=""
    for i in {1..60}; do
        argo_domain=$(grep -oE 'https://[-a-zA-Z0-9.]+\.trycloudflare\.com' cf.log | head -n 1 | sed 's#https://##' || true)
        [ -n "$argo_domain" ] && break
        sleep 1
    done

    if [ -z "$argo_domain" ]; then err "Argo 域名获取失败"; return; fi

    if [ "$proto" == "vmess" ]; then
        local vmess_json=$(cat <<EOF
{"v":"2","ps":"Argo-VMess","add":"www.visa.com.sg","port":"443","id":"$uuid","aid":"0","scy":"auto","net":"ws","type":"none","host":"$argo_domain","path":"$wspath","tls":"tls","sni":"$argo_domain"}
EOF
)
        local link="vmess://$(echo -n "$vmess_json" | base64 | tr -d '\n')"
    else
        local link="vless://$uuid@www.visa.com.sg:443?encryption=none&security=tls&sni=$argo_domain&type=ws&host=$argo_domain&path=$wspath#Argo-VLESS"
    fi
    
    echo -e "\n${GREEN}部署成功！${NC}"
    echo -e "节点链接: ${BLUE}$link${NC}"
}

# 主循环
while true; do
    show_menu
    read -r choice || break
    case "$choice" in
        1) deploy_reality ;;
        2) deploy_hy2 ;;
        3) deploy_argo "vmess" ;;
        4) deploy_argo "vless" ;;
        0) exit 0 ;;
        *) warn "无效选择" ;;
    esac
    echo -e "\n按回车键返回菜单..."
    read -r
done
