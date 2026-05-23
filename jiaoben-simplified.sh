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

# 颜色输出
color_print() {
    case $1 in
        red) echo -e "${RED}$2${NC}" ;;
        green) echo -e "${GREEN}$2${NC}" ;;
        yellow) echo -e "${YELLOW}$2${NC}" ;;
        blue) echo -e "${BLUE}$2${NC}" ;;
        cyan) echo -e "${CYAN}$2${NC}" ;;
        *) echo "$2" ;;
    esac
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行，请使用 sudo 或切换到 root 用户"
    fi
}

# 检测架构
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) error "不支持的架构: $arch (仅支持 x86_64 和 arm64)" ;;
    esac
}

# 下载文件带重试机制
download_file() {
    local url="$1"
    local output="$2"
    local retries=3
    local delay=5
    local attempt=1

    while [[ $attempt -le $retries ]]; do
        info "下载 $output (第 $attempt/$retries 次尝试)..."
        if command -v curl &>/dev/null; then
            if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$output"; then
                if [[ -s "$output" ]]; then
                    return 0
                else
                    warn "文件为空，重试中..."
                fi
            else
                warn "curl 下载失败，重试中..."
            fi
        elif command -v wget &>/dev/null; then
            if wget -q --timeout=10 --tries=1 "$url" -O "$output"; then
                if [[ -s "$output" ]]; then
                    return 0
                else
                    warn "文件为空，重试中..."
                fi
            else
                warn "wget 下载失败，重试中..."
            fi
        else
            error "未找到 curl 或 wget，请先安装"
        fi
        attempt=$((attempt + 1))
        [[ $attempt -le $retries ]] && sleep "$delay"
    done
    return 1
}

# 下载并安装 Xray
install_xray() {
    local arch
    arch=$(detect_arch)
    local xray_version
    xray_version=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    
    if [[ -z "$xray_version" ]]; then
        error "无法获取 Xray 最新版本信息"
    fi
    
    info "Xray 最新版本: v${xray_version}"
    local download_url="https://github.com/XTLS/Xray-core/releases/download/v${xray_version}/Xray-linux-${arch}.zip"
    local zip_file="${WORK_DIR}/xray.zip"
    
    rm -rf "$XRAY_DIR" 2>/dev/null
    mkdir -p "$XRAY_DIR"
    
    if ! download_file "$download_url" "$zip_file"; then
        error "Xray 下载失败，请检查网络连接"
    fi
    
    info "解压 Xray..."
    if ! unzip -qo "$zip_file" -d "$XRAY_DIR" 2>/dev/null; then
        error "Xray 解压失败，下载文件可能损坏"
    fi
    
    rm -f "$zip_file"
    
    if [[ ! -f "$XRAY_BIN" ]]; then
        error "Xray 二进制文件未找到，安装失败"
    fi
    
    chmod +x "$XRAY_BIN"
    success "Xray 安装成功 (v${xray_version})"
}

# 生成随机字符串
rand_str() {
    local length=${1:-16}
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
}

# 生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# 生成密钥对 (REALITY)
generate_keys() {
    local keys
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        error "密钥生成失败"
    fi
    local private_key
    local public_key
    private_key=$(echo "$keys" | grep "Private key:" | awk '{print $3}')
    public_key=$(echo "$keys" | grep "Public key:" | awk '{print $3}')
    echo "$private_key:$public_key"
}

# 生成 Short ID
generate_shortid() {
    openssl rand -hex 8
}

# 生成 Hysteria2 密码
generate_password() {
    openssl rand -base64 18 | tr -dc 'a-zA-Z0-9'
}

# 检查端口占用
check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 1
    fi
    return 0
}

# 获取可用端口
get_available_port() {
    local base_port=$1
    local port=$base_port
    while ! check_port "$port"; do
        port=$((port + 1))
        if [[ $port -gt $((base_port + 100)) ]]; then
            error "无法找到可用端口，请检查端口占用"
        fi
    done
    echo "$port"
}

# 部署配置
deploy_config() {
    local domain="$1"
    local port_vless="$2"
    local port_hysteria2="$3"
    local port_argo="$4"
    
    local uuid
    uuid=$(generate_uuid)
    local keys
    keys=$(generate_keys)
    local private_key
    private_key=$(echo "$keys" | cut -d: -f1)
    local public_key
    public_key=$(echo "$keys" | cut -d: -f2)
    local short_id
    short_id=$(generate_shortid)
    local password
    password=$(generate_password)
    
    local config_content
    config_content=$(cat << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${port_vless},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": [
            "${domain}",
            "www.microsoft.com"
          ],
          "privateKey": "${private_key}",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "port": ${port_hysteria2},
      "protocol": "hysteria2",
      "settings": {
        "clients": [
          {
            "password": "${password}"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${domain}",
          "alpn": ["h3"],
          "minVersion": "1.2",
          "maxVersion": "1.3"
        }
      }
    },
    {
      "port": ${port_argo},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/${uuid}-argo"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
)
    
    echo "$config_content" > "$XRAY_CONFIG"
    
    # 保存节点信息到文件
    {
        echo "=== 节点配置信息 ==="
        echo "部署时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "UUID: ${uuid}"
        echo "Domain: ${domain}"
        echo ""
        echo "--- REALITY (VLESS) ---"
        echo "Port: ${port_vless}"
        echo "Public Key: ${public_key}"
        echo "Short ID: ${short_id}"
        echo "VLESS Link: vless://${uuid}@$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):${port_vless}?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=${public_key}&sid=${short_id}&sni=${domain}#REALITY-${domain}"
        echo ""
        echo "--- Hysteria2 ---"
        echo "Port: ${port_hysteria2}"
        echo "Password: ${password}"
        echo "Hysteria2 Link: hysteria2://${password}@$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):${port_hysteria2}?insecure=1&sni=${domain}#Hysteria2-${domain}"
        echo ""
        echo "--- Argo Tunnel ---"
        echo "Port: ${port_argo}"
        echo "Path: /${uuid}-argo"
    } > "$NODES_FILE"
    
    # 返回需要用于 Argo 的 UUID
    echo "${uuid}"
}

# 设置 Systemd 服务
setup_systemd() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Jiaoben Xray Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable jiaoben-xray.service 2>/dev/null || true
}

# 启动 Argo 隧道并捕获域名
setup_argo() {
    local port=$1
    local argo_log="${WORK_DIR}/argo.log"
    
    info "配置 Argo Tunnel..."
    
    # 下载 cloudflared
    local argo_bin="${WORK_DIR}/cloudflared"
    if [[ ! -f "$argo_bin" ]]; then
        local arch
        arch=$(detect_arch)
        local argo_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
        if ! download_file "$argo_url" "$argo_bin"; then
            warn "cloudflared 下载失败，Argo 隧道将不可用"
            return 1
        fi
        chmod +x "$argo_bin"
    fi
    
    # 启动 cloudflared 隧道
    info "启动 Argo Tunnel (后台运行)..."
    nohup "$argo_bin" tunnel --url "http://localhost:${port}" --no-autoupdate > "$argo_log" 2>&1 &
    local argo_pid=$!
    echo "$argo_pid" > "${WORK_DIR}/argo.pid"
    
    # 等待域名生成 (最多等待 30 秒)
    local argo_domain=""
    local wait_count=0
    info "等待 Argo 分配域名..."
    while [[ $wait_count -lt 30 ]]; do
        argo_domain=$(grep -oP 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$argo_log" 2>/dev/null | head -1)
        if [[ -n "$argo_domain" ]]; then
            break
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    if [[ -z "$argo_domain" ]]; then
        warn "未能自动捕获 Argo 域名，请手动检查: ${argo_log}"
        return 1
    fi
    
    success "Argo 域名: ${argo_domain}"
    
    # 更新 nodes.txt 添加 Argo 链接
    local uuid
    uuid=$(grep "UUID:" "$NODES_FILE" | awk '{print $2}')
    
    cat >> "$NODES_FILE" << EOF
Argo Domain: ${argo_domain}
VLESS (Argo): vless://${uuid}@${argo_domain#https://}:443?type=ws&path=/${uuid}-argo&security=tls&sni=${argo_domain#https://}#Argo-${argo_domain#https://}
EOF
    
    echo "$argo_domain"
}

# 显示节点信息
display_nodes() {
    if [[ ! -f "$NODES_FILE" ]]; then
        error "节点信息文件不存在，请先部署"
    fi
    
    color_print cyan "========== 节点信息 =========="
    while IFS= read -r line; do
        case "$line" in
            ===*) color_print yellow "$line" ;;
            ---*) color_print blue "$line" ;;
            *Link:*) color_print green "$(echo "$line" | sed 's/^[[:space:]]*//')" ;;
            *) echo "$line" ;;
        esac
    done < "$NODES_FILE"
    echo ""
    color_print cyan "============================="
}

# 主部署流程
main_deploy() {
    check_root
    
    # 安装依赖
    if ! command -v unzip &>/dev/null; then
        info "安装 unzip..."
        apt-get update -qq && apt-get install -y -qq unzip || yum install -y -q unzip || error "无法安装 unzip"
    fi
    
    # 安装 Xray
    install_xray
    
    # 配置参数
    prompt "请输入伪装域名 (留空默认: www.microsoft.com):"
    read -r domain
    domain=${domain:-www.microsoft.com}
    
    local port_vless
    local port_hysteria2
    local port_argo
    
    port_vless=$(get_available_port 443)
    port_hysteria2=$(get_available_port $((port_vless + 1)))
    port_argo=$(get_available_port $((port_hysteria2 + 1)))
    
    info "端口分配: VLESS=${port_vless}, Hysteria2=${port_hysteria2}, Argo=${port_argo}"
    
    # 生成配置
    local uuid
    uuid=$(deploy_config "$domain" "$port_vless" "$port_hysteria2" "$port_argo")
    
    # 设置 systemd 服务
    setup_systemd
    
    # 启动服务
    info "启动 Xray 服务..."
    systemctl restart jiaoben-xray.service
    sleep 2
    
    if systemctl is-active --quiet jiaoben-xray.service; then
        success "Xray 服务运行中"
    else
        error "Xray 服务启动失败，请检查日志: journalctl -u jiaoben-xray.service"
    fi
    
    # 部署 Argo 隧道
    setup_argo "$port_argo" || warn "Argo 隧道部署不完整，请手动检查"
    
    # 显示节点
    echo ""
    success "部署完成！节点信息如下："
    display_nodes
}

# 管理面板
manage_panel() {
    local choice
    while true; do
        echo ""
        color_print cyan "========== 管理面板 =========="
        echo "1. 查看节点"
        echo "2. 重启服务"
        echo "3. 查看服务状态"
        echo "4. 查看日志"
        echo "5. 重新部署"
        echo "0. 退出"
        echo "================================"
        prompt "请选择 [0-5]:"
        read -r choice
        
        case "$choice" in
            1)
                if [[ -f "$NODES_FILE" ]]; then
                    display_nodes
                else
                    warn "节点信息文件不存在，请先部署"
                fi
                ;;
            2)
                info "重启 Xray 服务..."
                systemctl restart jiaoben-xray.service
                if systemctl is-active --quiet jiaoben-xray.service; then
                    success "服务已重启"
                else
                    error "服务重启失败"
                fi
                ;;
            3)
                systemctl status jiaoben-xray.service --no-pager 2>/dev/null || echo "服务未运行"
                ;;
            4)
                journalctl -u jiaoben-xray.service --no-pager -n 50 2>/dev/null || echo "无日志"
                ;;
            5)
                warn "重新部署将覆盖现有配置"
                prompt "确认重新部署? (y/n):"
                read -r confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    systemctl stop jiaoben-xray.service 2>/dev/null || true
                    main_deploy
                fi
                ;;
            0)
                info "退出管理面板"
                exit 0
                ;;
            *)
                warn "无效选择，请重新输入"
                ;;
        esac
    done
}

# 主菜单
main() {
    clear
    color_print cyan "========================================"
    color_print cyan "     Jiaoben Xray 一键部署脚本 v2.0"
    color_print cyan "========================================"
    
    if [[ ! -f "$XRAY_BIN" ]]; then
        info "未检测到 Xray 安装，开始部署..."
        main_deploy
    else
        prompt "检测到已有安装，进入管理面板? (y/n):"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            manage_panel
        else
            info "退出脚本"
            exit 0
        fi
    fi
}

# 入口点
main "$@"