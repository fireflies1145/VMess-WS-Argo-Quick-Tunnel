#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# 科学上网四合一全自动部署脚本 (Pro 版)
# 特性：Systemd 管理, 并发下载, 多系统适配
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

# 系统检查与依赖安装
install_dependencies() {
    info "正在检查系统环境并安装依赖..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                sudo apt update -y && sudo apt install -y curl unzip openssl grep sed coreutils procps jq
                ;;
            centos|rhel|almalinux|rocky)
                sudo yum install -y curl unzip openssl grep sed coreutils procps jq
                ;;
            *)
                warn "未知的发行版: $ID，请手动确保依赖已安装 (curl, unzip, openssl, jq)"
                ;;
        esac
    fi
}

# 架构检查
case "$ARCH" in
    x86_64|amd64) XRAY_PKG="Xray-linux-64.zip"; CF_BIN="cloudflared-linux-amd64"; HY_BIN="hysteria-linux-amd64" ;;
    aarch64|arm64) XRAY_PKG="Xray-linux-arm64-v8a.zip"; CF_BIN="cloudflared-linux-arm64"; HY_BIN="hysteria-linux-arm64" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac

# 端口检测与分配
get_random_port() {
    local port
    while true; do
        port=$(( ( RANDOM % 50000) + 10000 ))
        if ! ss -tln | grep -q ":$port "; then
            echo "$port" && return 0
        fi
    done
}

get_ip() {
    curl -s --connect-timeout 5 https://api.ipify.org || echo "127.0.0.1"
}

# 创建 Systemd 服务函数
create_service() {
    local name="$1"
    local exec_cmd="$2"
    local workdir="$3"
    
    cat <<EOF | sudo tee /etc/systemd/system/${name}.service >/dev/null
[Unit]
Description=${name} Service
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=${workdir}
ExecStart=${exec_cmd}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "${name}"
    sudo systemctl restart "${name}"
}

# --- 模块 1: VLESS + TCP + REALITY ---
deploy_reality() {
    info "正在部署 [1/4] VLESS + TCP + REALITY..."
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
    create_service "xray-reality" "${workdir}/xray run -c ${workdir}/config.json" "$workdir"
    
    local link="vless://$uuid@$ip:$port?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=$public_key&sid=$short_id&flow=xtls-rprx-vision#REALITY-Apple"
    {
        echo "--- VLESS + TCP + REALITY ---"
        echo "Link: $link"
        echo ""
    } >> "$INFO_FILE"
}

# --- 模块 2: Hysteria 2 ---
deploy_hy2() {
    info "正在部署 [2/4] Hysteria 2..."
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
    create_service "hy2" "${workdir}/hysteria server --config ${workdir}/config.yaml" "$workdir"
    
    local link="hysteria2://$password@$ip:$port/?sni=www.bing.com&insecure=1#Hy2-Bing"
    {
        echo "--- Hysteria 2 ---"
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
    
    # 避免重复下载
    [ -f xray ] || { curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_PKG}" -o xray.zip && unzip -qo xray.zip xray && chmod +x xray && rm xray.zip; }
    [ -f cloudflared ] || { curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/${CF_BIN}" -o cloudflared && chmod +x cloudflared; }

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

    create_service "xray-${proto}-argo" "${workdir}/xray run -c ${workdir}/config.json" "$workdir"
    
    # 启动 cloudflared 并捕获域名
    nohup ./cloudflared tunnel --url "http://127.0.0.1:$port" > cf.log 2>&1 &
    local cf_pid=$!
    
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
            echo "Link: $link"
            echo ""
        } >> "$INFO_FILE"
        # 转为 systemd 管理 cloudflared
        kill $cf_pid || true
        create_service "cf-${proto}-argo" "${workdir}/cloudflared tunnel --url http://127.0.0.1:$port" "$workdir"
    else
        warn "$proto Argo 域名获取失败"
    fi
}

# 执行
install_dependencies
deploy_reality
deploy_hy2
deploy_argo "vmess" "3"
deploy_argo "vless" "4"

# 安装管理工具
info "正在安装管理工具 'jb'..."
sudo cp /home/ubuntu/jiaoben/jb.sh /usr/local/bin/jb
sudo chmod +x /usr/local/bin/jb

clear
echo -e "${GREEN}部署完成！所有节点已通过 Systemd 运行。${NC}"
cat "$INFO_FILE"
echo -e "${YELLOW}输入 'jb' 即可管理服务。${NC}"
