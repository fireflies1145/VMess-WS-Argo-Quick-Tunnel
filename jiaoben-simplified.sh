#!/usr/bin/env bash

# ==========================================
# jiaoben - 科学上网四合一精简版 v6.0
# 更新日期: 2026-06-07
# 优化: 全面 bug 修复、错误处理增强、安全加固、
#       防火墙持久化、健康检查、日志轮转、
#       多源 IP 检测、JSON 配置安全构建
# ==========================================

set -Eeuo pipefail

VERSION="6.0"

# --- 内联公共配置（不依赖 common.sh） ---
export WORKDIR_BASE="${HOME}/.jiaoben"
export INFO_FILE="${WORKDIR_BASE}/all_nodes_info.txt"

# 颜色定义
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m'

# 日志函数
info()    { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
success() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; exit 1; }

# --- 全局错误陷阱 ---
trap 'echo -e "${RED}[ERROR]${NC} 脚本在第 ${LINENO} 行出错，退出码: $?${NC}" >&2; exit 1' ERR

# --- 路径 ---
WORK_DIR="${WORKDIR_BASE}"
XRAY_DIR="${WORK_DIR}/xray"
XRAY_BIN="${XRAY_DIR}/xray"
HY2_BIN="${WORK_DIR}/hysteria"
ARGO_BIN="${WORK_DIR}/cloudflared"
XRAY_CONFIG="${WORK_DIR}/config.json"
HY2_CONFIG="${WORK_DIR}/hy2_config.yaml"
NODES_FILE="${INFO_FILE}"
ARGO_LOG="${WORK_DIR}/argo.log"

# --- 已知稳定版本（GitHub API 不可用时的 fallback） ---
KNOWN_XRAY_VERSION="v25.5.16"

# --- 参数支持 ---
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "jiaoben v${VERSION}"
    exit 0
fi

# --- 权限与目录检查 ---
check_env() {
    [[ $EUID -ne 0 ]] && error "此脚本必须以 root 身份运行"
    [[ -d "$ARGO_BIN" ]] && rm -rf "$ARGO_BIN"
    [[ -d "$HY2_BIN" ]] && rm -rf "$HY2_BIN"
    mkdir -p "$WORK_DIR" "$XRAY_DIR"
}

# --- 架构识别 ---
detect_arch() {
    local fmt="${1:-generic}"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            if [[ "$fmt" == "xray" ]]; then echo "64"; else echo "amd64"; fi ;;
        aarch64|arm64)
            if [[ "$fmt" == "xray" ]]; then echo "arm64-v8a"; else echo "arm64"; fi ;;
        *)
            if [[ "$fmt" == "xray" ]]; then echo "64"; else echo "amd64"; fi ;;
    esac
}

# --- 端口占用检测（支持 IPv4 + IPv6） ---
check_port() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        warn "端口 ${port} 已被占用:"
        ss -tlnp 2>/dev/null | grep ":${port} " || netstat -tlnp 2>/dev/null | grep ":${port} "
        return 1
    fi
    return 0
}

# --- 节点信息输出 ---
append_node() {
    local name="$1"
    local link="$2"
    {
        echo ""
        echo "┌─────────────────────────────────────────────"
        echo "│  ${name}"
        echo "├─────────────────────────────────────────────"
        echo "${link}"
        echo "└─────────────────────────────────────────────"
    } >> "$NODES_FILE"
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
    if [[ ! -f "$file" ]]; then
        error "校验文件不存在: ${file}"
    fi
    local actual
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$file"
        error "SHA256 校验失败: 期望 ${expected}, 实际 ${actual}"
    fi
    info "SHA256 校验通过 ✓"
}

# --- 下载辅助（带重试） ---
download_file() {
    local url="$1"
    local dest="$2"
    local desc="$3"
    local retries=3

    for i in $(seq 1 "$retries"); do
        info "下载 ${desc} (尝试 ${i}/${retries})..."
        if wget -q --timeout=30 "$url" -O "$dest" 2>/dev/null; then
            [[ -s "$dest" ]] && return 0
        fi
        rm -f "$dest"
        warn "下载失败，${i}s 后重试..."
        sleep "$i"
    done
    error "下载 ${desc} 失败，请检查网络连接"
}

# --- 安全下载 SHA256 校验值 ---
download_sha256() {
    local url="$1"
    local expected=""
    expected=$(curl -fsSL "$url" 2>/dev/null | head -1 | awk '{print $1}' || echo "")
    if [[ -n "$expected" ]] && [[ "$expected" =~ ^[a-f0-9]{64}$ ]]; then
        echo "$expected"
        return 0
    fi
    echo ""
}

# --- 包管理器安装依赖 ---
install_deps() {
    info "检查安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq curl wget unzip jq openssl coreutils >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl wget unzip jq openssl coreutils >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget unzip jq openssl coreutils >/dev/null 2>&1
    fi
}

# --- GitHub API 请求（支持 GITHUB_TOKEN 鉴权） ---
github_api() {
    local url="$1"
    local headers=(-H "Accept: application/vnd.github.v3+json")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers+=(-H "Authorization: token ${GITHUB_TOKEN}")
    fi
    curl -fsSL "${headers[@]}" "$url" 2>/dev/null || echo ""
}

# --- 获取 Xray 最新版本号（带 fallback） ---
get_xray_version() {
    local version=""
    version=$(github_api "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name 2>/dev/null || echo "")
    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
        return
    fi
    warn "GitHub API 不可用（可能被限流），使用已知稳定版本: ${KNOWN_XRAY_VERSION}"
    echo "$KNOWN_XRAY_VERSION"
}

# --- 组件下载（带 SHA256 校验） ---
download_xray() {
    [[ -f "$XRAY_BIN" ]] && return 0
    local arch
    arch=$(detect_arch xray)
    local version
    version=$(get_xray_version)

    local zip_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
    download_file "$zip_url" "$WORK_DIR/xray.zip" "Xray ${version}"

    local expected=""
    expected=$(download_sha256 "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip.dgst")
    if [[ -n "$expected" ]]; then
        verify_sha256 "$WORK_DIR/xray.zip" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
    rm -f "$WORK_DIR/xray.zip.dgst"

    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"
    info "Xray 下载完成: ${version}"
    return 0
}

download_hy2() {
    [[ -f "$HY2_BIN" ]] && return 0
    local arch
    arch=$(detect_arch)
    local bin_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    download_file "$bin_url" "$HY2_BIN" "Hysteria2"

    local expected=""
    expected=$(download_sha256 "${bin_url}.sha256")
    if [[ -z "$expected" ]]; then
        local arch_name
        arch_name=$(detect_arch)
        expected=$(github_api "https://api.github.com/repos/apernet/hysteria/releases/latest" \
            | jq -r ".body" 2>/dev/null \
            | grep -oP "hysteria-linux-${arch_name}\s+\K[a-f0-9]{64}" || echo "")
        [[ -n "$expected" ]] && [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]] && expected=""
    fi
    if [[ -n "$expected" ]]; then
        verify_sha256 "$HY2_BIN" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
    chmod +x "$HY2_BIN"
    info "Hysteria2 下载完成"
    return 0
}

download_argo() {
    [[ -f "$ARGO_BIN" ]] && return 0
    local arch
    arch=$(detect_arch)
    local bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    download_file "$bin_url" "$ARGO_BIN" "Cloudflared"

    local expected=""
    expected=$(download_sha256 "${bin_url}.sha256")
    if [[ -z "$expected" ]]; then
        local arch_name
        arch_name=$(detect_arch)
        expected=$(github_api "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
            | jq -r ".body" 2>/dev/null \
            | grep -oP "cloudflared-linux-${arch_name}\s+\K[a-f0-9]{64}" || echo "")
        [[ -n "$expected" ]] && [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]] && expected=""
    fi
    if [[ -n "$expected" ]]; then
        verify_sha256 "$ARGO_BIN" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
    chmod +x "$ARGO_BIN"
    info "Cloudflared 下载完成"
    return 0
}

# --- 密钥生成 ---
generate_keys() {
    local output
    output=$("$XRAY_BIN" x25519 2>/dev/null) || error "Xray x25519 命令执行失败"
    local priv pub
    priv=$(echo "$output" | grep -oP 'Private key:\s*\K\S+')
    pub=$(echo "$output" | grep -oP 'Public key:\s*\K\S+')
    if [[ -z "$priv" || -z "$pub" ]]; then
        local keys
        keys=$(echo "$output" | grep -oE '[A-Za-z0-9+/_-]{43,44}')
        priv=$(echo "$keys" | head -1)
        pub=$(echo "$keys" | head -2 | tail -1)
    fi
    [[ -z "$priv" || -z "$pub" ]] && error "生成密钥失败，请检查 Xray 二进制"
    echo "${priv}:${pub}"
}

# --- 获取公网 IP（多源 fallback，支持 IPv6） ---
get_public_ip() {
    local ip=""
    local ip_services=("ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "api.ipify.org" "checkip.amazonaws.com")

    for svc in "${ip_services[@]}"; do
        ip=$(curl -4 -s --max-time 5 "$svc" 2>/dev/null || echo "")
        [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    done

    for svc in "${ip_services[@]}"; do
        ip=$(curl -6 -s --max-time 5 "$svc" 2>/dev/null || echo "")
        [[ -n "$ip" ]] && echo "$ip" && return 0
    done

    warn "无法获取公网 IP，请手动填写"
    echo "YOUR_IP"
}

# --- 验证 IP 是否可达 ---
validate_ip() {
    local ip="$1"
    if [[ "$ip" == "YOUR_IP" ]] || [[ -z "$ip" ]]; then
        error "无法获取公网 IP，请检查网络连接后重试"
    fi
    info "检测到公网 IP: ${ip}"
}

# --- 备份现有配置 ---
backup_config() {
    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
}

# --- 验证 JSON 文件有效性 ---
validate_json() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    if ! jq empty "$file" 2>/dev/null; then
        warn "JSON 文件无效: ${file}"
        return 1
    fi
    return 0
}

# --- 防火墙规则管理（支持持久化） ---
add_firewall_rule() {
    local port_range="$1"
    local proto="${2:-udp}"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow proto "$proto" from any to any port "$port_range" 2>/dev/null || true
        info "UFW 规则已添加: ${port_range}/${proto}"
        return 0
    fi

    if command -v iptables &>/dev/null; then
        local colon_range="${port_range//-/:}"
        iptables -C INPUT -p "$proto" --dport "$colon_range" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p "$proto" --dport "$colon_range" -j ACCEPT 2>/dev/null || true
        info "iptables 规则已添加: ${colon_range}/${proto}"

        if command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            info "iptables 规则已持久化"
        fi
        return 0
    fi

    warn "未检测到防火墙工具，请手动开放端口: ${port_range}/${proto}"
}

# --- 日志轮转 ---
rotate_argo_log() {
    local log_file="$1"
    local max_size=$((10 * 1024 * 1024))

    if [[ -f "$log_file" ]] && [[ $(stat -c%s "$log_file" 2>/dev/null || echo 0) -gt $max_size ]]; then
        mv "$log_file" "${log_file}.old"
        info "Argo 日志已轮转（超过 10MB）"
    fi
}

# --- 服务健康检查 ---
health_check() {
    local service="$1"
    local max_wait="${2:-10}"
    local unit="jiaoben-${service}"

    for i in $(seq 1 "$max_wait"); do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            info "${service} 服务健康 ✓"
            return 0
        fi
        sleep 1
    done
    warn "${service} 服务未就绪，请检查: journalctl -u ${unit} -n 20"
    return 1
}

# ============================================================
#  部署 REALITY (VLESS)
# ============================================================
deploy_reality() {
    download_xray
    check_port 443 || warn "端口 443 冲突，REALITY 可能启动失败"
    info "正在配置 REALITY..."
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)
    local keys
    keys=$(generate_keys)
    local priv pub
    priv=$(echo "$keys" | cut -d: -f1)
    pub=$(echo "$keys" | cut -d: -f2)
    local sid
    sid=$(openssl rand -hex 8)
    local domain="www.microsoft.com"

    backup_config
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 443, "protocol": "vless",
    "settings": {"clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "www.microsoft.com:443", "xver": 0,
        "serverNames": ["${domain}"], "privateKey": "${priv}", "shortIds": ["${sid}"]
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
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now jiaoben-xray || error "REALITY 服务启动失败"
    health_check "xray" 5 || true

    local ip
    ip=$(get_public_ip)
    validate_ip "$ip"
    local real_link="vless://${uuid}@${ip}:443?type=tcp&security=reality&pbk=${pub}&fp=chrome&sni=${domain}&flow=xtls-rprx-vision&sid=${sid}#REALITY"
    append_node "REALITY (VLESS)" "$real_link"
    chmod 600 "$NODES_FILE"
    success "REALITY 部署完成"
}

# ============================================================
#  部署 Argo 隧道 (VLESS)
# ============================================================
create_argo_service() {
    cat > "/etc/systemd/system/jiaoben-argo.service" <<EOF
[Unit]
Description=Jiaoben Cloudflare Argo Tunnel
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=${ARGO_BIN} tunnel --url http://127.0.0.1:8080 --no-autoupdate
Restart=on-failure
RestartSec=10
StandardOutput=append:${ARGO_LOG}
StandardError=append:${ARGO_LOG}
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now jiaoben-argo || error "Argo 服务启动失败"
}

get_argo_domain() {
    local max_wait=30
    info "正在获取 Argo 域名..."
    for i in $(seq 1 "$max_wait"); do
        if ! pgrep -f "cloudflared tunnel" >/dev/null 2>&1; then
            warn "cloudflared 进程已退出，停止等待"
            return 1
        fi
        local domain
        domain=$(grep -aoP 'https://[a-z0-9-]+\.trycloudflare\.com' "${ARGO_LOG}" 2>/dev/null | head -1 | sed 's|https://||')
        [[ -n "$domain" ]] && echo "$domain" && return 0
        sleep 2
    done
    return 1
}

deploy_argo() {
    download_xray
    download_argo
    info "正在配置 Argo 隧道..."
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)
    local path="/$(openssl rand -hex 4)"

    backup_config

    # 安全构建/追加 JSON 配置
    if validate_json "$XRAY_CONFIG"; then
        if ! jq --arg uuid "$uuid" --arg path "$path" \
            '.inbounds += [{"listen": "127.0.0.1", "port": 8080, "protocol": "vless", "settings": {"clients": [{"id": $uuid}], "decryption": "none"}, "streamSettings": {"network": "ws", "wsSettings": {"path": $path}}}]' \
            "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"; then
            rm -f "${XRAY_CONFIG}.tmp"
            error "Xray 配置更新失败（jq 错误），已保留原配置"
        fi
        mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    else
        cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 8080,
    "protocol": "vless",
    "settings": {"clients": [{"id": "${uuid}"}], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "${path}"}}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
        info "已创建新的 Xray 配置"
    fi

    validate_json "$XRAY_CONFIG" || error "Xray 配置文件无效，请检查: ${XRAY_CONFIG}"

    systemctl restart jiaoben-xray 2>/dev/null || true

    pkill cloudflared 2>/dev/null || true
    : > "${ARGO_LOG}"
    create_argo_service
    rotate_argo_log "${ARGO_LOG}"

    local argo_domain=""
    if argo_domain=$(get_argo_domain); then
        success "Argo 域名获取成功: ${argo_domain}"
    else
        warn "Argo 域名获取超时"
        warn "请手动获取域名: journalctl -u jiaoben-argo -n 20"
        warn "或使用优选域名，但需确保域名可达"
        argo_domain="yg1.ygkkk.dpdns.org"
    fi
    local encoded_path
    encoded_path=$(printf '%s' "$path" | sed 's|/|%2F|g')
    local argo_link="vless://${uuid}@${argo_domain}:443?encryption=none&type=ws&path=${encoded_path}&security=tls&sni=${argo_domain}&fp=chrome#Argo"
    append_node "Argo 隧道 (VLESS)" "$argo_link"
    chmod 600 "$NODES_FILE"
    success "Argo 隧道部署完成"
}

# ============================================================
#  部署 Hysteria2
# ============================================================
deploy_hy2() {
    download_hy2
    info "正在配置 Hysteria2..."

    # --- 端口配置 ---
    local port=""
    while true; do
        read -r -p "监听端口（回车随机分配 10000-59999）: " port
        if [[ -z "$port" ]]; then
            port=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]') % 50000 + 10000 ))
            info "随机端口: ${port}"
            break
        fi
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
            warn "无效端口，请输入 1-65535 之间的数字"
            continue
        fi
        if ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            warn "端口 ${port} 已被占用（UDP），请更换"
            continue
        fi
        info "使用端口: ${port}"
        break
    done

    # --- 端口跳跃 ---
    local port_hop_enabled="no"
    local port_hop_range=""
    local port_hop_interval="25s"
    local listen_addr=":${port}"
    local firewall_port_range="$port"

    read -r -p "是否开启端口跳跃 [y/N]: " hop_choice
    [[ "${hop_choice,,}" =~ ^y(es)?$ ]] && port_hop_enabled="yes"

    if [[ "$port_hop_enabled" == "yes" ]]; then
        local default_port_end=$((port + 75))
        [[ "$default_port_end" -gt 65535 ]] && default_port_end=65535

        local hop_range_size=$((default_port_end - port))
        if [[ "$hop_range_size" -lt 50 ]]; then
            warn "当前端口 ${port} 距离 65535 较近，跳跃范围仅 ${hop_range_size} 个端口"
        fi

        local port_end=""
        while true; do
            read -r -p "跳跃范围结束端口（起始 ${port}，默认 ${default_port_end}）: " port_end
            port_end="${port_end:-$default_port_end}"
            if [[ "$port_end" =~ ^[0-9]+$ ]] && [[ "$port_end" -gt "$port" ]] && [[ "$port_end" -le 65535 ]]; then
                break
            fi
            warn "结束端口须大于 ${port} 且不超过 65535"
        done

        read -r -p "端口跳跃间隔（默认 25s）: " hop_interval
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

    echo ""
    echo "TLS 证书方式:"
    echo "  1) 自签证书（SNI 伪装为 www.bing.com，客户端需跳过验证）"
    echo "  2) ACME 自动申请（域名需已解析到本机，不支持 CDN 代理）"
    echo "  3) 自定义证书文件"
    echo ""

    while true; do
        read -r -p "请选择 [1-3]（默认 1）: " cert_choice
        cert_choice="${cert_choice:-1}"
        case "$cert_choice" in
            1)
                cert_method="self"
                sni="www.bing.com"
                insecure="1"
                if [[ ! -f "${WORK_DIR}/hy2.crt" ]] || [[ ! -f "${WORK_DIR}/hy2.key" ]]; then
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
                local acme_domain=""
                local acme_email=""
                while true; do
                    read -r -p "域名（需已解析到本机）: " acme_domain
                    [[ "$acme_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]+)?(\.[a-zA-Z]{2,})$ ]] && break
                    warn "域名格式不正确"
                done
                while true; do
                    read -r -p "邮箱（Let's Encrypt 通知用）: " acme_email
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
                    read -r -p "证书文件路径（fullchain.pem / .crt）: " cert_file
                    [[ -n "$cert_file" ]] && [[ -f "$cert_file" ]] && break
                    warn "文件不存在，请重新输入"
                done
                while true; do
                    read -r -p "私钥文件路径（privkey.pem / .key）: " key_file
                    [[ -n "$key_file" ]] && [[ -f "$key_file" ]] && break
                    warn "文件不存在，请重新输入"
                done
                sni=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN\s*=\s*//' | head -n1) || sni=""
                [[ -n "$sni" ]] && info "证书 CN: ${sni}"
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
        read -r -p "请选择 [1-2]（默认 2）: " speed_choice
        speed_choice="${speed_choice:-2}"
        case "$speed_choice" in
            1) limit_speed="yes"; speed_up="100"; speed_down="100"; info "限速: 100 Mbps"; break ;;
            2) limit_speed="no"; info "不限速"; break ;;
            *) warn "请输入 1 或 2" ;;
        esac
    done

    # --- 生成密码 ---
    local pass
    pass=$(openssl rand -hex 16)
    info "认证密码: ${pass}"

    # --- 构建配置 ---
    local bandwidth_block=""
    if [[ "$limit_speed" == "yes" ]]; then
        bandwidth_block="bandwidth:
  up: ${speed_up} mbps
  down: ${speed_down} mbps"
    fi

    cat > "$HY2_CONFIG" <<EOF
listen: ${listen_addr}

tls:
  cert: ${cert_file}
  key: ${key_file}

auth:
  type: password
  password: ${pass}

${bandwidth_block:+${bandwidth_block}
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
    info "配置文件已写入: ${HY2_CONFIG}"

    # --- 防火墙 ---
    add_firewall_rule "$firewall_port_range" "udp"

    # --- 启动服务 ---
    cat > "/etc/systemd/system/jiaoben-hy2.service" <<EOF
[Unit]
Description=Jiaoben Hysteria2
After=network.target
[Service]
ExecStart=${HY2_BIN} server -c ${HY2_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now jiaoben-hy2 || error "Hysteria2 服务启动失败"
    health_check "hy2" 5 || true

    # --- 生成分享链接 ---
    local ip
    ip=$(get_public_ip)
    validate_ip "$ip"
    local share_host="$ip"
    [[ "$ip" =~ : ]] && [[ ! "$ip" =~ \[ ]] && share_host="[${ip}]"

    local insecure_param=""
    [[ "$insecure" == "1" ]] && insecure_param="&insecure=1"

    local mport_param=""
    if [[ "$port_hop_enabled" == "yes" ]]; then
        local hop_int_num="${port_hop_interval//s/}"
        mport_param="&mport=${port_hop_range}&mportHopInt=${hop_int_num}"
    fi

    local link="hysteria2://${pass}@${share_host}:${port}?sni=${sni}${mport_param}${insecure_param}#Hy2"

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
    chmod 600 "$NODES_FILE"
    success "Hysteria2 部署完成"
}

# ============================================================
#  一键部署全部
# ============================================================
deploy_all() {
    : > "$NODES_FILE"
    deploy_reality
    deploy_argo
    deploy_hy2
    success "全部部署完成！"
    print_nodes
}

# --- 更新单个组件（安全方式：先备份再下载） ---
update_component() {
    local name="$1"
    local bin_path="$2"
    local download_fn="$3"
    local service="$4"

    local backup="${bin_path}.bak"
    [[ -f "$bin_path" ]] && cp "$bin_path" "$backup"

    rm -f "$bin_path"
    if "$download_fn"; then
        rm -f "$backup"
        systemctl restart "$service" 2>/dev/null && success "${name} 已更新并重启" || info "${name} 已更新（服务未运行）"
    else
        [[ -f "$backup" ]] && mv "$backup" "$bin_path"
        warn "${name} 更新失败，已恢复旧版本"
    fi
}

# ============================================================
#  服务更新
# ============================================================
update_services() {
    echo ""
    echo "可更新的组件:"
    echo "  1) Xray"
    echo "  2) Hysteria2"
    echo "  3) Cloudflared"
    echo "  4) 全部更新"
    echo "  0) 返回"
    echo ""
    read -r -p "请选择 [0-4]: " update_choice
    case "$update_choice" in
        1) update_component "Xray" "$XRAY_BIN" download_xray jiaoben-xray ;;
        2) update_component "Hysteria2" "$HY2_BIN" download_hy2 jiaoben-hy2 ;;
        3) update_component "Cloudflared" "$ARGO_BIN" download_argo jiaoben-argo ;;
        4)
            update_component "Xray" "$XRAY_BIN" download_xray jiaoben-xray
            update_component "Hysteria2" "$HY2_BIN" download_hy2 jiaoben-hy2
            update_component "Cloudflared" "$ARGO_BIN" download_argo jiaoben-argo
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

# ============================================================
#  服务管理
# ============================================================
service_exists() {
    systemctl list-unit-files "jiaoben-$1.service" &>/dev/null
}

restart_services() {
    local found=0
    for svc in xray hy2 argo; do
        if service_exists "$svc"; then
            if systemctl restart "jiaoben-$svc" 2>/dev/null; then
                success "已重启 jiaoben-${svc}"
            else
                warn "jiaoben-${svc} 重启失败"
            fi
            found=1
        fi
    done
    [[ $found -eq 0 ]] && warn "未发现任何 jiaoben 服务"
}

uninstall_all() {
    echo ""
    warn "⚠️  即将删除所有 jiaoben 组件和配置！"
    read -r -p "确认卸载？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { info "已取消"; return; }

    info "正在卸载所有组件..."
    for svc in xray hy2 argo; do
        if service_exists "$svc"; then
            systemctl disable --now "jiaoben-$svc" 2>/dev/null
            rm -f "/etc/systemd/system/jiaoben-${svc}.service"
            info "已移除 jiaoben-${svc}"
        fi
    done
    pkill cloudflared 2>/dev/null || true
    rm -rf "$WORK_DIR"
    systemctl daemon-reload
    success "已彻底卸载"
}

# ============================================================
#  主菜单
# ============================================================
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
    echo "6. 重启服务"
    echo "7. 更新组件"
    echo "8. 彻底卸载"
    echo "0. 退出"
    echo -e "========================================="
    read -r -p "请选择 [0-8]: " choice
    case $choice in
        1) deploy_reality ;;
        2) deploy_argo ;;
        3) deploy_hy2 ;;
        4) deploy_all ;;
        5) print_nodes ;;
        6) restart_services ;;
        7) update_services ;;
        8) uninstall_all ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

check_env
while true; do
    main_menu
    read -r -n 1 -s -p "按任意键返回主菜单..."
done
