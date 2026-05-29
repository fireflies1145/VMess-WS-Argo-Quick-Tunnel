#!/usr/bin/env bash

# ==========================================
# jiaoben - 科学上网四合一精简版 v4.0
# 更新日期: 2026-05-29
# 优化: 安全校验、Argo systemd、代码清理
# ==========================================

set -Euo pipefail

# --- 颜色与日志 ---
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
    # 解决目录/文件冲突
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

# --- SHA256 校验 ---
verify_sha256() {
    local file="$1"
    local expected="$2"
    [[ -z "$expected" ]] && return 0
    local actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$file"
        error "SHA256 校验失败: 期望 $expected, 实际 $actual"
    fi
    info "SHA256 校验通过 ✓"
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
    local zip_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"

    wget -q "$zip_url" -O "$WORK_DIR/xray.zip"
    # SHA256 校验（从 release metadata 获取）
    local sha=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | \
        jq -r ".assets[] | select(.name==\"Xray-linux-${arch}.zip\") | .name" 2>/dev/null)
    if [[ -n "$sha" ]]; then
        wget -q "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip.dgst" \
            -O "$WORK_DIR/xray.zip.dgst" 2>/dev/null || true
        local expected=$(grep -oP 'SHA256=\K[a-f0-9]{64}' "$WORK_DIR/xray.zip.dgst" 2>/dev/null || echo "")
        [[ -n "$expected" ]] && verify_sha256 "$WORK_DIR/xray.zip" "$expected"
        rm -f "$WORK_DIR/xray.zip.dgst"
    fi

    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"
    info "Xray 下载完成: $version"
}

download_hy2() {
    [[ -f "$HY2_BIN" ]] && return
    info "正在下载 Hysteria2..."
    local arch=$(detect_arch)
    local bin_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    wget -q "$bin_url" -O "$HY2_BIN"
    # SHA256 校验
    local sha_url="${bin_url}.sha256"
    local expected=$(curl -fsSL "$sha_url" 2>/dev/null | cut -d' ' -f1 || echo "")
    [[ -n "$expected" ]] && verify_sha256 "$HY2_BIN" "$expected"
    chmod +x "$HY2_BIN"
    info "Hysteria2 下载完成"
}

download_argo() {
    [[ -f "$ARGO_BIN" ]] && return
    info "正在下载 Cloudflared..."
    local arch=$(detect_arch)
    local bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    wget -q "$bin_url" -O "$ARGO_BIN"
    # SHA256 校验
    local sha_url="${bin_url}.sha256"
    local expected=$(curl -fsSL "$sha_url" 2>/dev/null | cut -d' ' -f1 || echo "")
    [[ -n "$expected" ]] && verify_sha256 "$ARGO_BIN" "$expected"
    chmod +x "$ARGO_BIN"
    info "Cloudflared 下载完成"
}

# --- 功能逻辑 ---
generate_keys() {
    local output
    output=$("$XRAY_BIN" x25519 2>/dev/null)
    local priv pub
    priv=$(echo "$output" | grep -oP 'Private key:\s*\K\S+')
    pub=$(echo "$output" | grep -oP 'Public key:\s*\K\S+')
    if [[ -z "$priv" || -z "$pub" ]]; then
        # fallback: 旧版解析
        local keys=$(echo "$output" | grep -oE '[A-Za-z0-9+/_-]{43,44}')
        priv=$(echo "$keys" | head -1)
        pub=$(echo "$keys" | head -2 | tail -1)
    fi
    echo "${priv}:${pub}"
}

deploy_hy2() {
    download_hy2
    info "正在配置 Hysteria2..."
    local port=444
    local pass=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
    local domain="www.bing.com"
    openssl req -newkey rsa:2048 -nodes -keyout "${WORK_DIR}/hy2.key" -x509 -days 3650 -out "${WORK_DIR}/hy2.crt" -subj "/CN=www.bing.com" >/dev/null 2>&1

    cat > "$HY2_CONFIG" <<EOF
listen: :$port
tls:
  cert: ${WORK_DIR}/hy2.crt
  key: ${WORK_DIR}/hy2.key
auth:
  type: password
  password: $pass
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
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now jiaoben-hy2
    local ip=$(curl -s ifconfig.me || echo "IP")
    local link="hysteria2://$pass@$ip:$port?insecure=1&sni=$domain#Hy2"
    echo "Hysteria2: $link" >> "$NODES_FILE"
    success "Hysteria2 部署完成"
}

# --- Argo systemd 服务 ---
create_argo_service() {
    local argo_domain="$1"
    cat > "/etc/systemd/system/jiaoben-argo.service" <<EOF
[Unit]
Description=Jiaoben Cloudflare Argo Tunnel
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$ARGO_BIN tunnel --url http://127.0.0.1:8080 --no-autoupdate
Restart=on-failure
RestartSec=10
StandardOutput=append:${WORK_DIR}/argo.log
StandardError=append:${WORK_DIR}/argo.log
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now jiaoben-argo
}

# --- 获取 Argo 域名 ---
get_argo_domain() {
    local max_wait=30
    info "正在获取 Argo 域名..."
    for i in $(seq 1 $max_wait); do
        local domain=$(grep -aoP 'https://[a-z0-9-]+\.trycloudflare\.com' "${WORK_DIR}/argo.log" 2>/dev/null | head -1 | sed 's/https:\/\///')
        [[ -n "$domain" ]] && echo "$domain" && return 0
        sleep 2
    done
    return 1
}

deploy_core() {
    local mode=$1
    install_deps
    [[ "$mode" -eq 4 ]] || echo "=========================================" > "$NODES_FILE"

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
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable --now jiaoben-xray
        local ip=$(curl -s ifconfig.me || echo "IP")
        echo "REALITY: vless://$uuid@$ip:443?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=$pub&sid=$sid&sni=$domain#REALITY" >> "$NODES_FILE"
        success "REALITY 部署完成"
    fi

    if [[ "$mode" -eq 3 ]] || [[ "$mode" -eq 4 ]]; then
        deploy_hy2
    fi

    if [[ "$mode" -eq 2 ]] || [[ "$mode" -eq 4 ]]; then
        download_xray
        download_argo
        info "正在配置 Argo 隧道..."
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        local path="/$(openssl rand -hex 4)"
        if [[ ! -f "$XRAY_CONFIG" ]]; then
            cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
        fi
        jq --arg uuid "$uuid" --arg path "$path" \
            '.inbounds += [{"listen": "127.0.0.1", "port": 8080, "protocol": "vless", "settings": {"clients": [{"id": $uuid}], "decryption": "none"}, "streamSettings": {"network": "ws", "wsSettings": {"path": $path}}}]' \
            "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
        systemctl restart jiaoben-xray

        # 停止旧进程，使用 systemd 管理
        pkill cloudflared 2>/dev/null || true
        : > "${WORK_DIR}/argo.log"
        create_argo_service

        local argo_domain=""
        if argo_domain=$(get_argo_domain); then
            success "Argo 域名获取成功: $argo_domain"
        else
            warn "Argo 域名获取超时，使用优选域名作为备用"
            argo_domain="yg1.ygkkk.dpdns.org"
        fi
        local encoded_path=$(printf '%s' "$path" | sed 's|/|%2F|g')
        echo "Argo: vless://$uuid@${argo_domain}:443?type=ws&path=${encoded_path}&security=tls&sni=${argo_domain}#Argo" >> "$NODES_FILE"
    fi

    [[ "$mode" -eq 4 ]] || echo "=========================================" >> "$NODES_FILE"
    [[ "$mode" -eq 4 ]] && echo "=========================================" >> "$NODES_FILE"
    clear
    cat "$NODES_FILE"
    success "部署任务完成！"
}

# --- 服务管理辅助 ---
service_exists() {
    systemctl list-unit-files "jiaoben-$1.service" &>/dev/null
}

restart_services() {
    local found=0
    for svc in xray hy2 argo; do
        if service_exists "$svc"; then
            systemctl restart "jiaoben-$svc"
            success "已重启 jiaoben-$svc"
            found=1
        fi
    done
    [[ $found -eq 0 ]] && warn "未发现任何 jiaoben 服务"
}

uninstall_all() {
    info "正在卸载所有组件..."
    for svc in xray hy2 argo; do
        if service_exists "$svc"; then
            systemctl disable --now "jiaoben-$svc" 2>/dev/null
            rm -f "/etc/systemd/system/jiaoben-${svc}.service"
            info "已移除 jiaoben-$svc"
        fi
    done
    pkill cloudflared 2>/dev/null || true
    rm -rf "$WORK_DIR"
    systemctl daemon-reload
    success "已彻底卸载"
}

main_menu() {
    clear
    echo -e "${CYAN}========================================="
    echo "    jiaoben 一键脚本 v4.0"
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
        4) echo "=========================================" > "$NODES_FILE"; deploy_core 4 ;;
        5) [[ -f "$NODES_FILE" ]] && cat "$NODES_FILE" || warn "未发现节点信息" ;;
        6) restart_services ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

check_env
while true; do
    main_menu
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
