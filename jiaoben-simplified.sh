#!/usr/bin/env bash

# ==========================================
# jiaoben - 科学上网四合一精简版 v4.1
# 更新日期: 2026-05-29
# 优化: Bug修复、端口检测、卸载确认、代码清理
# ==========================================

set -Euo pipefail

VERSION="5.0"

# --- 内联公共配置（不依赖 common.sh） ---
export WORKDIR_BASE="/root/.jiaoben"
export INFO_FILE="${WORKDIR_BASE}/all_nodes_info.txt"

# 颜色定义
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m'

# 日志函数
log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }

# 设置错误陷阱
set_error_trap() { trap 'log_error "脚本在第 ${LINENO} 行出错"; exit 1' ERR; }
set_error_trap

# --- 使用内置日志函数 ---
info()    { log_info "$*"; }
success() { log_info "$*"; }
warn()    { log_warn "$*"; }
error()   { log_error "$*"; exit 1; }

# --- 路径 ---
WORK_DIR="${WORKDIR_BASE}"
XRAY_DIR="${WORK_DIR}/xray"
XRAY_BIN="${XRAY_DIR}/xray"
HY2_BIN="${WORK_DIR}/hysteria"
ARGO_BIN="${WORK_DIR}/cloudflared"
XRAY_CONFIG="${WORK_DIR}/config.json"
HY2_CONFIG="${WORK_DIR}/hy2_config.yaml"
NODES_FILE="${INFO_FILE}"

# --- 参数支持 ---
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "jiaoben v${VERSION}"
    exit 0
fi

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

# --- 端口占用检测 ---
check_port() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        warn "端口 $port 已被占用:"
        ss -tlnp 2>/dev/null | grep ":${port} " || netstat -tlnp 2>/dev/null | grep ":${port} "
        return 1
    fi
    return 0
}

# --- 节点信息输出 ---
append_node() {
    local name="$1"
    local link="$2"
    echo "" >> "$NODES_FILE"
    echo "┌─────────────────────────────────────────────" >> "$NODES_FILE"
    echo "│  $name" >> "$NODES_FILE"
    echo "├─────────────────────────────────────────────" >> "$NODES_FILE"
    echo "$link" >> "$NODES_FILE"
    echo "└─────────────────────────────────────────────" >> "$NODES_FILE"
}

print_nodes() {
    [[ ! -f "$NODES_FILE" ]] && { warn "未发现节点信息"; return; }
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           📋 节点部署信息                      ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    cat "$NODES_FILE"
    echo ""
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

# --- 下载辅助（带重试和校验） ---
download_file() {
    local url="$1"
    local dest="$2"
    local desc="$3"
    local retries=3

    for i in $(seq 1 $retries); do
        info "下载 $desc (尝试 $i/$retries)..."
        if wget -q --timeout=30 "$url" -O "$dest" 2>/dev/null; then
            [[ -s "$dest" ]] && return 0
        fi
        rm -f "$dest"
        warn "下载失败，${i}s 后重试..."
        sleep "$i"
    done
    error "下载 $desc 失败，请检查网络连接"
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
    local arch=$(detect_xray_arch)
    local version=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name)
    [[ -z "$version" || "$version" == "null" ]] && error "无法获取 Xray 版本号"

    local zip_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
    download_file "$zip_url" "$WORK_DIR/xray.zip" "Xray ${version}"

    # SHA256 校验（从 .dgst 文件获取）
    wget -q "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip.dgst" \
        -O "$WORK_DIR/xray.zip.dgst" 2>/dev/null || true
    local expected=$(grep -oP 'SHA256=\K[a-f0-9]{64}' "$WORK_DIR/xray.zip.dgst" 2>/dev/null || echo "")
    if [[ -n "$expected" ]]; then
        verify_sha256 "$WORK_DIR/xray.zip" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
    rm -f "$WORK_DIR/xray.zip.dgst"

    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"
    info "Xray 下载完成: $version"
}

download_hy2() {
    [[ -f "$HY2_BIN" ]] && return
    local arch=$(detect_arch)
    local bin_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    download_file "$bin_url" "$HY2_BIN" "Hysteria2"

    # SHA256 校验
    local sha_url="${bin_url}.sha256"
    local expected=$(curl -fsSL "$sha_url" 2>/dev/null | cut -d' ' -f1 || echo "")
    if [[ -n "$expected" ]]; then
        verify_sha256 "$HY2_BIN" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
    chmod +x "$HY2_BIN"
    info "Hysteria2 下载完成"
}

download_argo() {
    [[ -f "$ARGO_BIN" ]] && return
    local arch=$(detect_arch)
    local bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    download_file "$bin_url" "$ARGO_BIN" "Cloudflared"

    # SHA256 校验
    local sha_url="${bin_url}.sha256"
    local expected=$(curl -fsSL "$sha_url" 2>/dev/null | cut -d' ' -f1 || echo "")
    if [[ -n "$expected" ]]; then
        verify_sha256 "$ARGO_BIN" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
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
        # fallback: 旧版 xray 输出格式
        local keys=$(echo "$output" | grep -oE '[A-Za-z0-9+/_-]{43,44}')
        priv=$(echo "$keys" | head -1)
        pub=$(echo "$keys" | head -2 | tail -1)
    fi
    [[ -z "$priv" || -z "$pub" ]] && error "生成密钥失败，请检查 Xray 二进制"
    echo "${priv}:${pub}"
}

deploy_hy2() {
    download_hy2
    info "正在配置 Hysteria2..."
    
    # --- 端口配置 ---
    local port=""
    while true; do
        read -p "监听端口（回车随机分配 10000-59999）: " port
        if [ -z "$port" ]; then
            # 随机端口
            port=$(od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]')
            port=$(( port % 50000 + 10000 ))
            port=$(( port > 59999 ? 59999 : port ))
            info "随机端口: $port"
            break
        fi
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            warn "无效端口，请输入 1-65535 之间的数字"
            continue
        fi
        if ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            warn "端口 $port 已被占用（UDP），请更换"
            continue
        fi
        info "使用端口: $port"
        break
    done
    
    # --- 端口跳跃 ---
    local port_hop_enabled="no"
    local port_hop_range=""
    local port_hop_interval="25s"
    local listen_addr=":${port}"
    local firewall_port_range="$port"
    
    read -p "是否开启端口跳跃 [y/N]: " hop_choice
    [[ "${hop_choice,,}" =~ ^y(es)?$ ]] && port_hop_enabled="yes"
    
    if [ "$port_hop_enabled" = "yes" ]; then
        local default_port_end=$((port + 75))
        [ "$default_port_end" -gt 65535 ] && default_port_end=65535
        
        local port_end=""
        while true; do
            read -p "跳跃范围结束端口（起始 ${port}，默认 ${default_port_end}）: " port_end
            port_end="${port_end:-$default_port_end}"
            if [[ "$port_end" =~ ^[0-9]+$ ]] && [ "$port_end" -gt "$port" ] && [ "$port_end" -le 65535 ]; then
                break
            fi
            warn "结束端口须大于 ${port} 且不超过 65535"
        done
        
        read -p "端口跳跃间隔（默认 25s）: " hop_interval
        port_hop_interval="${hop_interval:-25s}"
        port_hop_range="${port}-${port_end}"
        listen_addr=":${port_hop_range}"
        firewall_port_range="${port}-${port_end}"
        info "端口跳跃: ${port_hop_range}  间隔: ${port_hop_interval}"
    fi
    
    # --- TLS 证书 ---
    local cert_method=""
    local cert_file=""
    local key_file=""
    local sni=""
    local insecure=""
    local acme_domain=""
    local acme_email=""
    
    echo ""
    echo "TLS 证书方式:"
    echo "  1) 自签证书（SNI 伪装为 www.bing.com，客户端需跳过验证）"
    echo "  2) ACME 自动申请（域名需已解析到本机，不支持 CDN 代理）"
    echo "  3) 自定义证书文件"
    echo ""
    
    while true; do
        read -p "请选择 [1-3]（默认 1）: " cert_choice
        cert_choice="${cert_choice:-1}"
        case "$cert_choice" in
            1)
                cert_method="self"
                sni="www.bing.com"
                insecure="1"
                if [ ! -f "${WORK_DIR}/hy2.crt" ] || [ ! -f "${WORK_DIR}/hy2.key" ]; then
                    info "正在生成自签证书 (CN: ${sni})..."
                    openssl req -newkey rsa:2048 -nodes -keyout "${WORK_DIR}/hy2.key" \
                        -x509 -days 3650 -out "${WORK_DIR}/hy2.crt" \
                        -subj "/CN=${sni}" 2>/dev/null || error "自签证书生成失败"
                    chmod 600 "${WORK_DIR}/hy2.key" "${WORK_DIR}/hy2.crt"
                    info "自签证书已生成"
                else
                    info "复用已有自签证书"
                fi
                cert_file="${WORK_DIR}/hy2.crt"
                key_file="${WORK_DIR}/hy2.key"
                break
                ;;
            2)
                cert_method="acme"
                warn "⚠ 注意：CDN 代理（如 Cloudflare 橙色云朵）会导致 ACME 验证失败！"
                
                while true; do
                    read -p "域名（需已解析到本机）: " acme_domain
                    [[ "$acme_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]+)?(\.[a-zA-Z]{2,})$ ]] && break
                    warn "域名格式不正确"
                done
                while true; do
                    read -p "邮箱（Let's Encrypt 通知用）: " acme_email
                    [[ "$acme_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
                    warn "邮箱格式不正确"
                done
                
                info "证书申请可能需要 1-2 分钟，启动后请耐心等待。"
                sni="$acme_domain"
                insecure=""
                break
                ;;
            3)
                cert_method="custom"
                while true; do
                    read -p "证书文件路径（fullchain.pem / .crt）: " cert_file
                    [ -n "$cert_file" ] && [ -f "$cert_file" ] && break
                    warn "文件不存在，请重新输入"
                done
                while true; do
                    read -p "私钥文件路径（privkey.pem / .key）: " key_file
                    [ -n "$key_file" ] && [ -f "$key_file" ] && break
                    warn "文件不存在，请重新输入"
                done
                sni=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN\s*=\s*//' | head -n1) || sni=""
                [ -n "$sni" ] && info "证书 CN: $sni"
                insecure=""
                break
                ;;
            *)
                warn "请输入 1、2 或 3"
                ;;
        esac
    done
    
    # --- 带宽限速 ---
    local limit_speed="no"
    local speed_up=""
    local speed_down=""
    
    echo ""
    echo "带宽限速:"
    echo "  1) 限速 100 Mbps（上下行）"
    echo "  2) 不限速"
    echo ""
    
    while true; do
        read -p "请选择 [1-2]（默认 2）: " speed_choice
        speed_choice="${speed_choice:-2}"
        case "$speed_choice" in
            1) limit_speed="yes"; speed_up="100"; speed_down="100"; info "限速: 100 Mbps"; break ;;
            2) limit_speed="no"; info "不限速"; break ;;
            *) warn "请输入 1 或 2" ;;
        esac
    done
    
    # --- 生成密码 ---
    local pass=$(openssl rand -hex 16)
    info "认证密码: ${pass}"
    
    # --- 构建配置 ---
    local tls_block=""
    case "$cert_method" in
        self|custom)
            tls_block="tls:\n  cert: ${cert_file}\n  key: ${key_file}"
            ;;
        acme)
            tls_block="tls:\n  acme:\n    domains:\n      - ${acme_domain}\n    email: ${acme_email}"
            ;;
    esac
    
    local bandwidth_block=""
    if [ "$limit_speed" = "yes" ]; then
        bandwidth_block="bandwidth:\n  up: ${speed_up} mbps\n  down: ${speed_down} mbps"
    fi
    
    cat > "$HY2_CONFIG" <<EOF
listen: ${listen_addr}

tls:
  cert: ${cert_file}
  key: ${key_file}

auth:
  type: password
  password: ${pass}

${bandwidth_block:+$bandwidth_block
}
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAliveInterval: 10s

log:
  level: warn
EOF
    
    chmod 600 "$HY2_CONFIG"
    info "配置文件已写入: $HY2_CONFIG"
    
    # --- 防火墙 ---
    if [ "$port_hop_enabled" = "yes" ]; then
        local colon_range="${firewall_port_range//-/:}"
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
            ufw allow proto udp from any to any port "$colon_range" 2>/dev/null || true
            info "UFW 规则已添加: ${colon_range}/udp"
        elif command -v iptables >/dev/null 2>&1; then
            iptables -C INPUT -p udp --dport "$colon_range" -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p udp --dport "$colon_range" -j ACCEPT 2>/dev/null || true
            info "iptables 规则已添加: ${colon_range}/udp"
        fi
    fi
    
    # --- 启动服务 ---
    cat > "/etc/systemd/system/jiaoben-hy2.service" <<EOF
[Unit]
Description=Jiaoben Hysteria2
After=network.target
[Service]
ExecStart=$HY2_BIN server -c $HY2_CONFIG
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now jiaoben-hy2
    
    # --- 生成分享链接 ---
    local ip=$(curl -s ifconfig.me || echo "IP")
    local share_host="$ip"
    [[ "$ip" =~ : ]] && [[ ! "$ip" =~ \[ ]] && share_host="[${ip}]"
    
    local insecure_param=""
    [ "$insecure" = "1" ] && insecure_param="&insecure=1"
    
    local mport_param=""
    if [ "$port_hop_enabled" = "yes" ]; then
        local hop_int_num="${port_hop_interval//s/}"
        mport_param="&mport=${port_hop_range}&mportHopInt=${hop_int_num}"
    fi
    
    local link="hysteria2://${pass}@${share_host}:${port}?sni=${sni}${mport_param}${insecure_param}#Hy2"
    
    # --- 保存节点信息 ---
    cat >> "$NODES_FILE" <<INFO_EOF

┌─────────────────────────────────────────────
│  Hysteria2
├─────────────────────────────────────────────
│  地址: ${share_host}
│  端口: ${port}
│  端口跳跃: ${port_hop_enabled}
│  密码: ${pass}
│  SNI: ${sni}
│  证书方式: ${cert_method}
│  分享链接:
${link}
└─────────────────────────────────────────────
INFO_EOF
    
    success "Hysteria2 部署完成"
}

# --- Argo systemd 服务 ---
create_argo_service() {
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

# --- 备份现有配置 ---
backup_config() {
    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
}

deploy_core() {
    local mode=$1
    install_deps
    [[ "$mode" -eq 4 ]] || : > "$NODES_FILE"

    if [[ "$mode" -eq 1 ]] || [[ "$mode" -eq 4 ]]; then
        download_xray
        check_port 443 || warn "端口 443 冲突，REALITY 可能启动失败"
        info "正在配置 REALITY..."
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        local keys=$(generate_keys)
        local priv=$(echo "$keys" | cut -d: -f1)
        local pub=$(echo "$keys" | cut -d: -f2)
        local sid=$(openssl rand -hex 8)
        local domain="www.microsoft.com"

        backup_config
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
        local real_link="vless://$uuid@$ip:443?type=tcp&security=reality&pbk=$pub&fp=chrome&sni=$domain&flow=xtls-rprx-vision&sid=$sid#REALITY"
        append_node "REALITY (VLESS)" "$real_link"
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

        backup_config
        if [[ ! -f "$XRAY_CONFIG" ]]; then
            cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
        fi

        if ! jq --arg uuid "$uuid" --arg path "$path" \
            '.inbounds += [{"listen": "127.0.0.1", "port": 8080, "protocol": "vless", "settings": {"clients": [{"id": $uuid}], "decryption": "none"}, "streamSettings": {"network": "ws", "wsSettings": {"path": $path}}}]' \
            "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"; then
            error "Xray 配置更新失败（jq 错误），已保留原配置"
        fi
        mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
        systemctl restart jiaoben-xray

        # 停止旧进程，使用 systemd 管理
        pkill cloudflared 2>/dev/null || true
        : > "${WORK_DIR}/argo.log"
        create_argo_service

        local argo_domain=""
        if argo_domain=$(get_argo_domain); then
            success "Argo 域名获取成功: $argo_domain"
        else
            warn "Argo 域名获取超时，使用优选域名: yg1.ygkkk.dpdns.org"
            argo_domain="yg1.ygkkk.dpdns.org"
        fi
        local encoded_path=$(printf '%s' "$path" | sed 's|/|%2F|g')
        local argo_link="vless://$uuid@${argo_domain}:443?encryption=none&type=ws&path=${encoded_path}&security=tls&sni=${argo_domain}&fp=chrome#Argo"
        append_node "Argo 隧道 (VLESS)" "$argo_link"
    fi

    clear
    print_nodes
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
    echo ""
    warn "⚠️  即将删除所有 jiaoben 组件和配置！"
    read -p "确认卸载？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { info "已取消"; return; }

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
    echo "    jiaoben 一键脚本 v${VERSION}"
    echo -e "=========================================${NC}"
    echo "1. 部署 REALITY (VLESS)"
    echo "2. 部署 Argo 隧道 (VLESS)"
    echo "3. 部署 Hysteria2 (支持端口跳跃/ACME)"
    echo "4. 一键部署全部 (以上所有)"
    echo "5. 查看节点信息"
    echo "6. 停止/重启服务"
    echo "7. 彻底卸载"
    echo "0. 退出"
    echo -e "========================================="
    read -p "请选择 [0-7]: " choice
    case $choice in
        1) deploy_core 1 ;;
        2) deploy_core 2 ;;
        3) deploy_core 3 ;;
        4) : > "$NODES_FILE"; deploy_core 4 ;;
        5) print_nodes ;;
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
