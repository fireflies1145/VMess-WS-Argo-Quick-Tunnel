#!/usr/bin/env bash

# ==========================================
# jiaoben - 科学上网四合一精简版 v3.4
# 更新日期: 2026-05-23
# 修复: 集成 hy2.sh 核心功能 (独立二进制)
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
HY2_BIN="${WORK_DIR}/hysteria"
ARGO_BIN="${WORK_DIR}/cloudflared"
XRAY_CONFIG="${WORK_DIR}/config.json"
HY2_CONFIG="${WORK_DIR}/hy2_config.yaml"
NODES_FILE="${WORK_DIR}/nodes.txt"

# --- 权限与目录检查 ---
check_env() {
    [[ $EUID -ne 0 ]] && error "此脚本必须以 root 身份运行"
    # 彻底解决目录/文件冲突
    [[ -d "$ARGO_BIN" ]] && rm -rf "$ARGO_BIN"
    [[ -d "$HY2_BIN" ]] && rm -rf "$HY2_BIN"
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

# --- 组件下载 ---
install_deps() {
    info "检查安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq curl wget unzip jq openssl coreutils >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget unzip jq openssl coreutils >/dev/null 2>&1
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

download_hy2() {
    [[ -f "$HY2_BIN" ]] && return
    info "正在下载 Hysteria2..."
    local arch=$(detect_arch)
    # hysteria-linux-amd64 / hysteria-linux-arm64
    wget -q "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}" -O "$HY2_BIN"
    chmod +x "$HY2_BIN"
}

download_argo() {
    [[ -f "$ARGO_BIN" ]] && return
    info "正在下载 Cloudflared..."
    local arch=$(detect_arch)
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -O "$ARGO_BIN"
    chmod +x "$ARGO_BIN"
}

# --- 功能逻辑 ---
generate_keys() {
    local output=$("$XRAY_BIN" x25519 2>/dev/null)
    local keys=$(echo "$output" | grep -oE '[A-Za-z0-9+/_-]{43,44}')
    local priv=$(echo "$keys" | head -1)
    local pub=$(echo "$keys" | head -2 | tail -1)
    echo "${priv}:${pub}"
}

deploy_hy2() {
    download_hy2
    info "正在配置 Hysteria2..."
    local port=444
    local pass=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
    local domain="www.bing.com"
    
    # 生成自签证书
    openssl req -newkey rsa:2048 -nodes -keyout "${WORK_DIR}/hy2.key" -x509 -days 3650 -out "${WORK_DIR}/hy2.crt" -subj "/CN=www.bing.com" >/dev/null 2>&1

    cat > "$HY2_CONFIG" <<EOF
listen: :$port
tls:
  cert: ${WORK_DIR}/hy2.crt
  key: ${WORK_DIR}/hy2.key
auth:
  type: password
  password: $pass
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
log:
  level: warn
EOF

    cat > "/etc/systemd/system/jiaoben-hy2.service" <<EOF
[Unit]
Description=Jiaoben Hysteria2
After=network.target
[Service]
ExecStart=$HY2_BIN server -c $HY2_CONFIG
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now jiaoben-hy2
    
    local ip=$(curl -s ifconfig.me || echo "IP")
    local link="hysteria2://$pass@$ip:$port?insecure=1&sni=$domain#Hy2"
    echo "Hysteria2: $link" >> "$NODES_FILE"
    success "Hysteria2 部署成功"
}

deploy_core() {
    local mode=$1 # 1: REALITY, 2: Argo, 3: Hy2, 4: All
    install_deps
    
    # 初始化记录文件
    [[ "$mode" -eq 4 ]] || echo "=========================================" > "$NODES_FILE"

    # --- REALITY ---
    if [[ "$mode" -eq 1 ]] || [[ "$mode" -eq 4 ]]; then
        download_xray
        info "正在配置 REALITY..."
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        local keys=$(generate_keys)
        local priv=$(echo "$keys" | cut -d: -f1)
        local pub=$(echo "$keys" | cut -d: -f2)
        local sid=$(openssl rand -hex 8)
        local domain="www.microsoft.com"
        
        cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 443, "protocol": "vless",
    "settings": {"clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "www.microsoft.com:443", "xver": 0,
        "serverNames": ["$domain"], "privateKey": "$priv", "shortIds": ["$sid"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
        cat > "/etc/systemd/system/jiaoben-xray.service" <<EOF
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
        local ip=$(curl -s ifconfig.me || echo "IP")
        echo "REALITY: vless://$uuid@$ip:443?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=$pub&sid=$sid&sni=$domain#REALITY" >> "$NODES_FILE"
    fi

    # --- Hysteria2 ---
    if [[ "$mode" -eq 3 ]] || [[ "$mode" -eq 4 ]]; then
        deploy_hy2
    fi

    # --- Argo ---
    if [[ "$mode" -eq 2 ]] || [[ "$mode" -eq 4 ]]; then
        download_xray
        download_argo
        info "正在配置 Argo 隧道..."
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        # 如果 Xray 已经在运行，需要动态合并配置（这里简化为覆盖或追加）
        # 为简单起见，Argo 使用 445 端口
        if [[ ! -f "$XRAY_CONFIG" ]]; then
            cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
        fi
        # 使用 jq 追加 inbound
        jq '.inbounds += [{"port": 445, "protocol": "vless", "settings": {"clients": [{"id": "'$uuid'"}], "decryption": "none"}, "streamSettings": {"network": "ws", "wsSettings": {"path": "/'$uuid'-argo"}}}]' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
        systemctl restart jiaoben-xray
        
        pkill cloudflared || true
        nohup "$ARGO_BIN" tunnel --url "http://localhost:445" --no-autoupdate > "${WORK_DIR}/argo.log" 2>&1 &
        
        local argo_domain=""
        info "正在获取 Argo 域名..."
        for i in {1..30}; do
            argo_domain=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "${WORK_DIR}/argo.log" | head -1 | sed 's/https:\/\///')
            [[ -n "$argo_domain" ]] && break
            sleep 1
        done
        [[ -n "$argo_domain" ]] && echo "Argo: vless://$uuid@$argo_domain:443?type=ws&path=/$uuid-argo&security=tls&sni=$argo_domain#Argo" >> "$NODES_FILE"
    fi

    [[ "$mode" -eq 4 ]] || echo "=========================================" >> "$NODES_FILE"
    [[ "$mode" -eq 4 ]] && echo "=========================================" >> "$NODES_FILE"
    
    clear
    cat "$NODES_FILE"
    success "部署任务完成！"
}

# --- 菜单系统 ---
main_menu() {
    clear
    echo -e "${CYAN}========================================="
    echo "    jiaoben 一键脚本 v3.4 (全功能版)"
    echo -e "=========================================${NC}"
    echo "1. 部署 REALITY (VLESS)"
    echo "2. 部署 Hysteria2 (独立版)"
    echo "3. 部署 Argo 隧道 (VLESS)"
    echo "4. 一键部署全部 (以上所有)"
    echo "5. 查看节点信息"
    echo "6. 停止/重启服务"
    echo "7. 彻底卸载"
    echo "0. 退出"
    echo -e "========================================="
    read -p "请选择 [0-7]: " choice
    case $choice in
        1) deploy_core 1 ;;
        2) deploy_core 3 ;;
        3) deploy_core 2 ;;
        4) 
            echo "=========================================" > "$NODES_FILE"
            deploy_core 4 
            ;;
        5) [[ -f "$NODES_FILE" ]] && cat "$NODES_FILE" || warn "未发现节点信息" ;;
        6) 
            systemctl restart jiaoben-xray jiaoben-hy2 2>/dev/null || true
            success "服务已尝试重启"
            ;;
        7)
            systemctl disable --now jiaoben-xray jiaoben-hy2 2>/dev/null || true
            pkill cloudflared || true
            rm -rf "$WORK_DIR" /etc/systemd/system/jiaoben-*.service
            systemctl daemon-reload
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
