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
LOG_FILE="${WORK_DIR}/deploy.log"
mkdir -p "$WORK_DIR"

# --- 系统检测 ---
check_system() {
    info "检查系统环境..."
    
    # 检查 Root 权限
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 身份运行"
    fi
    
    # 检查 OS
    if [[ ! -f /etc/os-release ]]; then
        error "无法识别操作系统"
    fi
    
    source /etc/os-release
    OS=$ID
    
    # 检查包管理器
    if command -v apt-get &> /dev/null; then
        PKG_MGR="apt-get"
        PKG_UPDATE="apt-get update"
        PKG_INSTALL="apt-get install -y"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"
        PKG_UPDATE="yum update -y"
        PKG_INSTALL="yum install -y"
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
get_ip() { curl -s https://api.ipify.org || echo "127.0.0.1"; }

# --- 下载二进制 ---
download_xray() {
    info "下载 Xray..."
    local url="https://github.com/XTLS/Xray-core/releases/download/v1.8.5/Xray-linux-64.zip"
    
    if [[ ! -f "$WORK_DIR/xray/xray" ]]; then
        mkdir -p "$WORK_DIR/xray"
        cd "$WORK_DIR/xray"
        wget -q "$url" -O xray.zip
        unzip -q xray.zip
        chmod +x xray
        rm -f xray.zip
    fi
    
    success "Xray 已就绪"
}

download_hysteria() {
    info "下载 Hysteria2..."
    local url="https://github.com/apernet/hysteria/releases/download/v2.1.5/hysteria-linux-amd64"
    
    if [[ ! -f "$WORK_DIR/hysteria2/hysteria" ]]; then
        mkdir -p "$WORK_DIR/hysteria2"
        wget -q "$url" -O "$WORK_DIR/hysteria2/hysteria"
        chmod +x "$WORK_DIR/hysteria2/hysteria"
    fi
    
    success "Hysteria2 已就绪"
}

download_cloudflared() {
    info "下载 Cloudflared..."
    local url="https://github.com/cloudflare/cloudflared/releases/download/2024.2.1/cloudflared-linux-amd64"
    
    if [[ ! -f "$WORK_DIR/cloudflared/cloudflared" ]]; then
        mkdir -p "$WORK_DIR/cloudflared"
        wget -q "$url" -O "$WORK_DIR/cloudflared/cloudflared"
        chmod +x "$WORK_DIR/cloudflared/cloudflared"
    fi
    
    success "Cloudflared 已就绪"
}

# --- 部署 REALITY ---
deploy_reality() {
    info "部署 REALITY..."
    download_xray
    
    local port=$(gen_port)
    local uuid=$(gen_uuid)
    local ip=$(get_ip)
    
    # 生成配置
    cat > "$WORK_DIR/xray/reality.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$uuid"}],
      "decryption": "none",
      "fallbacks": [{"dest": 443}]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.google.com:443",
        "xver": 0,
        "serverNames": ["www.google.com"],
        "privateKey": "$(openssl rand -hex 16)",
        "minClientVer": "",
        "maxClientVer": "",
        "maxTimeDiff": 0,
        "cipherSuites": "",
        "rules": []
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/xray-reality.service <<EOF
[Unit]
Description=Xray REALITY Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$WORK_DIR/xray/xray -c $WORK_DIR/xray/reality.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now xray-reality
    
    # 保存节点信息
    cat >> "$WORK_DIR/nodes.txt" <<EOF

=== REALITY ===
IP: $ip
Port: $port
UUID: $uuid
EOF
    
    success "REALITY 部署完成"
}

# --- 部署 Hysteria2 ---
deploy_hysteria2() {
    info "部署 Hysteria2..."
    download_hysteria
    
    local port=$(gen_port)
    local password=$(gen_password)
    local ip=$(get_ip)
    
    # 生成配置
    cat > "$WORK_DIR/hysteria2/config.yaml" <<EOF
listen: :$port
tls:
  cert: /etc/ssl/certs/ssl-cert-snakeoil.pem
  key: /etc/ssl/private/ssl-cert-snakeoil.key
auth:
  type: password
  password: $password
masquerade: https://www.bing.com
EOF
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/hy2.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$WORK_DIR/hysteria2/hysteria -c $WORK_DIR/hysteria2/config.yaml server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now hy2
    
    # 保存节点信息
    cat >> "$WORK_DIR/nodes.txt" <<EOF

=== Hysteria2 ===
IP: $ip
Port: $port
Password: $password
EOF
    
    success "Hysteria2 部署完成"
}

# --- 部署 Argo 隧道 ---
deploy_argo() {
    info "部署 Argo 隧道..."
    download_xray
    download_cloudflared
    
    local port=$(gen_port)
    local uuid=$(gen_uuid)
    local protocol=${1:-vless}
    
    # 生成 Xray 配置
    cat > "$WORK_DIR/xray/argo.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "protocol": "$protocol",
    "settings": {"clients": [{"id": "$uuid"}]},
    "streamSettings": {
      "network": "ws",
      "wsSettings": {"path": "/"}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/xray-argo.service <<EOF
[Unit]
Description=Xray Argo Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$WORK_DIR/xray/xray -c $WORK_DIR/xray/argo.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now xray-argo
    
    # 保存节点信息
    cat >> "$WORK_DIR/nodes.txt" <<EOF

=== Argo ($protocol) ===
Port: $port
UUID: $uuid
EOF
    
    success "Argo 隧道部署完成"
}

# --- 管理面板 ---
management_panel() {
    while true; do
        echo ""
        echo "=== 管理面板 ==="
        echo "1. 查看所有节点"
        echo "2. 启动所有服务"
        echo "3. 停止所有服务"
        echo "4. 查看服务状态"
        echo "5. 查看日志"
        echo "6. 返回主菜单"
        
        read -p "请选择: " choice
        
        case $choice in
            1) cat "$WORK_DIR/nodes.txt" 2>/dev/null || echo "暂无节点信息" ;;
            2) systemctl start xray-* hy2 xray-argo 2>/dev/null; success "所有服务已启动" ;;
            3) systemctl stop xray-* hy2 xray-argo 2>/dev/null; success "所有服务已停止" ;;
            4) systemctl status xray-* hy2 xray-argo 2>/dev/null ;;
            5) journalctl -u xray-reality -u hy2 -u xray-argo -n 20 ;;
            6) break ;;
            *) warn "无效选择" ;;
        esac
    done
}

# --- 卸载 ---
uninstall_all() {
    warn "即将卸载所有服务..."
    read -p "确认卸载？(yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        info "已取消"
        return
    fi
    
    systemctl stop xray-* hy2 xray-argo 2>/dev/null || true
    systemctl disable xray-* hy2 xray-argo 2>/dev/null || true
    rm -f /etc/systemd/system/xray-*.service /etc/systemd/system/hy2.service
    systemctl daemon-reload
    rm -rf "$WORK_DIR"
    
    success "卸载完成"
}

# --- 主菜单 ---
main_menu() {
    while true; do
        echo ""
        echo "========================================="
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
            0) success "再见!"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

# --- 主函数 ---
main() {
    check_system
    install_deps
    main_menu
}

main "$@"
