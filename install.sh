#!/usr/bin/env bash
# ==========================================
# jiaoben - 代理节点一键部署系统 v4.2
# 更新日期: 2026-06-07
# 修复: pkill 拼写、service_exists、端口检测、ACME验证等
# ==========================================
set -Euo pipefail

VERSION="4.2"

# --- 加载公共库（如果存在） ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/common.sh" ]]; then
    source "$SCRIPT_DIR/common.sh"
fi

# --- 基础配置（确保 common.sh 未加载时也有默认值） ---
export WORKDIR_BASE="${WORKDIR_BASE:-/root/.jiaoben}"
export INFO_FILE="${WORKDIR_BASE}/all_nodes_info.txt"

# --- 颜色定义（防止 common.sh 未加载） ---
: "${RED:=\\033[0;31m}"
: "${GREEN:=\\033[0;32m}"
: "${YELLOW:=\\033[1;33m}"
: "${BLUE:=\\033[0;34m}"
: "${CYAN:=\\033[0;36m}"
: "${NC:=\\033[0m}"

# --- 日志函数 ---
_log_info()  { echo -e "${GREEN}[INFO]${NC}    $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
_log_warn()  { echo -e "${YELLOW}[WARN]${NC}    $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
_log_error() { echo -e "${RED}[ERROR]${NC}   $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }
_log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# 如果 common.sh 已定义则跳过
if ! declare -f info &>/dev/null; then
    info()    { _log_info "$*"; }
    success() { _log_success "$*"; }
    warn()    { _log_warn "$*"; }
    error()   { _log_error "$*"; exit 1; }
fi

# --- 错误陷阱 ---
set_error_trap() { trap '_log_error "脚本在第 ${LINENO} 行出错"; exit 1' ERR; }
set_error_trap

# ==========================================
# 路径常量
# ==========================================
readonly WORK_DIR="${WORKDIR_BASE}"
readonly XRAY_DIR="${WORK_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly HY2_BIN="${WORK_DIR}/hysteria"
readonly ARGO_BIN="${WORK_DIR}/cloudflared"
readonly XRAY_CONFIG="${WORK_DIR}/config.json"
readonly HY2_CONFIG="${WORK_DIR}/hy2_config.yaml"
readonly NODES_FILE="${INFO_FILE}"

# ==========================================
# 参数支持
# ==========================================
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "jiaoben v${VERSION}"
    exit 0
fi

# ==========================================
# 环境检查
# ==========================================
check_env() {
    [[ $EUID -ne 0 ]] && error "此脚本必须以 root 身份运行"

    # 安装必要工具
    if ! command -v ss &>/dev/null; then
        info "安装 iproute2 (ss 命令)..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq iproute2 >/dev/null 2>&1 || true
        elif command -v yum &>/dev/null; then
            yum install -y -q iproute >/dev/null 2>&1 || true
        fi
    fi

    # 解决目录/文件冲突
    [[ -d "$ARGO_BIN" ]] && rm -rf "$ARGO_BIN"
    [[ -d "$HY2_BIN" ]] && rm -rf "$HY2_BIN"
    mkdir -p "$WORK_DIR" "$XRAY_DIR"
}

# ==========================================
# 架构识别
# ==========================================
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)              echo "amd64" ;;
    esac
}

detect_xray_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "64" ;;
        aarch64|arm64)  echo "arm64-v8a" ;;
        *)              echo "64" ;;
    esac
}

# ==========================================
# 端口检测（增强版：同时检测 TCP 和 UDP）
# ==========================================
check_port() {
    local port="$1"
    local proto="${2:-tcp}"   # tcp / udp / both

    local ss_opts=""
    local netstat_opts=""
    case "$proto" in
        tcp)  ss_opts="-tlnp"; netstat_opts="-tlnp" ;;
        udp)  ss_opts="-ulnp"; netstat_opts="-ulnp" ;;
        both) ss_opts="-tulnp"; netstat_opts="-tulnp" ;;
    esac

    if { ss "$ss_opts" 2>/dev/null || netstat "$netstat_opts" 2>/dev/null; } | grep -q ":${port} "; then
        warn "端口 $port ($proto) 已被占用:"
        ss "$ss_opts" 2>/dev/null | grep ":${port} " || netstat "$netstat_opts" 2>/dev/null | grep ":${port} "
        return 1
    fi
    return 0
}

# ==========================================
# 节点信息输出
# ==========================================
append_node() {
    local name="$1"
    local link="$2"
    init_info_file() { [[ ! -f "$NODES_FILE" ]] && echo "# jiaoben 节点信息" > "$NODES_FILE"; }
    init_info_file
    {
        echo ""
        echo "┌─────────────────────────────────────────────"
        echo "│ $name"
        echo "├─────────────────────────────────────────────"
        echo "$link"
        echo "└─────────────────────────────────────────────"
    } >> "$NODES_FILE"
}

print_nodes() {
    if [[ ! -f "$NODES_FILE" ]]; then
        warn "未发现节点信息"
        return
    fi
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            📋 节点部署信息                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
    cat "$NODES_FILE"
    echo ""
}

# ==========================================
# SHA256 校验
# ==========================================
verify_sha256() {
    local file="$1"
    local expected="$2"
    [[ -z "$expected" ]] && return 0

    local actual
    actual=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
    if [[ -z "$actual" ]]; then
        actual=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
    fi

    if [[ "$actual" != "$expected" ]]; then
        rm -f "$file"
        error "SHA256 校验失败: 期望 $expected, 实际 $actual"
    fi
    info "SHA256 校验通过 ✓"
}

# ==========================================
# 下载辅助（带重试和校验）
# ==========================================
download_file() {
    local url="$1"
    local dest="$2"
    local desc="$3"
    local retries=3

    for i in $(seq 1 $retries); do
        info "下载 $desc (尝试 $i/$retries)..."
        if wget -q --timeout=60 --show-progress "$url" -O "$dest" 2>/dev/null; then
            [[ -s "$dest" ]] && return 0
        fi
        # fallback: 使用 curl
        if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$dest" 2>/dev/null; then
            [[ -s "$dest" ]] && return 0
        fi
        rm -f "$dest"
        warn "下载失败，${i}s 后重试..."
        sleep "$i"
    done
    error "下载 $desc 失败，请检查网络连接"
}

# ==========================================
# 组件下载
# ==========================================
install_deps() {
    info "检查安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq curl wget unzip jq openssl coreutils iproute2 >/dev/null 2>&1 || true
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget unzip jq openssl coreutils iproute >/dev/null 2>&1 || true
    fi
}

download_xray() {
    [[ -f "$XRAY_BIN" ]] && return

    local arch version zip_url
    arch=$(detect_xray_arch)

    # 获取版本号（带重试）
    info "获取 Xray 最新版本..."
    for i in 1 2 3; do
        version=$(curl -fsSL --connect-timeout 10 \
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
            2>/dev/null | jq -r .tag_name 2>/dev/null || echo "")
        [[ -n "$version" && "$version" != "null" ]] && break
        sleep 2
    done
    [[ -z "$version" || "$version" == "null" ]] && error "无法获取 Xray 版本号（可能触发 GitHub API 限流）"

    zip_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
    download_file "$zip_url" "$WORK_DIR/xray.zip" "Xray ${version}"

    # SHA256 校验
    local expected=""
    if wget -q "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip.dgst" \
        -O "$WORK_DIR/xray.zip.dgst" 2>/dev/null; then
        expected=$(grep -oP 'SHA256=\K[a-f0-9]{64}' "$WORK_DIR/xray.zip.dgst" 2>/dev/null || echo "")
    fi
    if [[ -n "$expected" ]]; then
        verify_sha256 "$WORK_DIR/xray.zip" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
    rm -f "$WORK_DIR/xray.zip.dgst"

    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"
    success "Xray 下载完成: $version"
}

download_hy2() {
    [[ -f "$HY2_BIN" ]] && return

    local arch bin_url
    arch=$(detect_arch)
    bin_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    download_file "$bin_url" "$HY2_BIN" "Hysteria2"

    # SHA256 校验
    local expected=""
    expected=$(curl -fsSL --connect-timeout 10 "${bin_url}.sha256" 2>/dev/null | cut -d' ' -f1 || echo "")
    if [[ -n "$expected" ]]; then
        verify_sha256 "$HY2_BIN" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
    chmod +x "$HY2_BIN"
    success "Hysteria2 下载完成"
}

download_argo() {
    [[ -f "$ARGO_BIN" ]] && return

    local arch bin_url
    arch=$(detect_arch)
    bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    download_file "$bin_url" "$ARGO_BIN" "Cloudflared"

    # SHA256 校验
    local expected=""
    expected=$(curl -fsSL --connect-timeout 10 "${bin_url}.sha256" 2>/dev/null | cut -d' ' -f1 || echo "")
    if [[ -n "$expected" ]]; then
        verify_sha256 "$ARGO_BIN" "$expected"
    else
        warn "未找到 SHA256 校验值，跳过校验"
    fi
    chmod +x "$ARGO_BIN"
    success "Cloudflared 下载完成"
}

# ==========================================
# 密钥生成
# ==========================================
generate_keys() {
    local output priv pub
    output=$("$XRAY_BIN" x25519 2>/dev/null) || error "Xray 二进制无法执行"

    # 尝试新格式
    priv=$(echo "$output" | grep -oP 'Private key:\s*\K\S+')
    pub=$(echo "$output" | grep -oP 'Public key:\s*\K\S+')

    # fallback: 旧版 xray 输出格式，更精确的正则
    if [[ -z "$priv" || -z "$pub" ]]; then
        # X25519 密钥为 43 字符 Base64（标准无填充）
        local keys
        keys=$(echo "$output" | grep -oE '[A-Za-z0-9+/]{43}' | head -2)
        priv=$(echo "$keys" | head -1)
        pub=$(echo "$keys" | head -2 | tail -1)
    fi

    [[ -z "$priv" || -z "$pub" ]] && error "生成密钥失败，请检查 Xray 二进制"
    echo "${priv}:${pub}"
}

# ==========================================
# 部署 Hysteria2
# ==========================================
deploy_hy2() {
    download_hy2
    info "正在配置 Hysteria2..."

    # --- 端口配置 ---
    local port=""
    while true; do
        read -p "监听端口（回车随机分配 10000-59999）: " port
        if [[ -z "$port" ]]; then
            # 随机端口
            port=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]')
            port=$(( port % 50000 + 10000 ))
            info "随机端口: $port"
            break
        fi
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
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

    if [[ "$port_hop_enabled" == "yes" ]]; then
        local default_port_end=$((port + 75))
        [[ "$default_port_end" -gt 65535 ]] && default_port_end=65535
        local port_end=""
        while true; do
            read -p "跳跃范围结束端口（起始 ${port}，默认 ${default_port_end}）: " port_end
            port_end="${port_end:-$default_port_end}"
            if [[ "$port_end" =~ ^[0-9]+$ ]] && [[ "$port_end" -gt "$port" ]] && [[ "$port_end" -le 65535 ]]; then
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
    echo " 1) 自签证书（SNI 伪装为 www.bing.com，客户端需跳过验证）"
    echo " 2) ACME 自动申请（域名需已解析到本机，不支持 CDN 代理）"
    echo " 3) 自定义证书文件"
    echo ""

    while true; do
        read -p "请选择 [1-3]（默认 1）: " cert_choice
        cert_choice="${cert_choice:-1}"
        case "$cert_choice" in
            1)
                cert_method="self"
                sni="www.bing.com"
                insecure="1"
                if [[ ! -f "${WORK_DIR}/hy2.crt" || ! -f "${WORK_DIR}/hy2.key" ]]; then
                    info "正在生成自签证书 (CN: ${sni})..."
                    openssl req -newkey rsa:2048 -nodes -keyout "${WORK_DIR}/hy2.key" \
                        -x509 -days 3650 -out "${WORK_DIR}/hy2.crt" \
                        -subj "/CN=${sni}" 2>/dev/null || error "自签证书生成失败"
                    chmod 600 "${WORK_DIR}/hy2.key"
                    chmod 644 "${WORK_DIR}/hy2.crt"
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
                    if [[ "$acme_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]+)?(\.[a-zA-Z]{2,})$ ]]; then
                        # 前置 DNS 检查
                        info "检查域名解析..."
                        local resolved_ip
                        resolved_ip=$(dig +short "$acme_domain" 2>/dev/null | tail -1 || \
                                      nslookup "$acme_domain" 2>/dev/null | grep -oP 'Address:\s*\K[0-9.]+' | tail -1 || echo "")
                        if [[ -z "$resolved_ip" ]]; then
                            warn "域名 $acme_domain 无法解析，ACME 验证可能失败"
                            read -p "是否继续？[y/N]: " cont
                            [[ ! "${cont,,}" =~ ^y(es)?$ ]] && continue 2
                        else
                            info "域名解析到: $resolved_ip"
                        fi
                        break
                    fi
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
                    [[ -n "$cert_file" && -f "$cert_file" ]] && break
                    warn "文件不存在，请重新输入"
                done
                while true; do
                    read -p "私钥文件路径（privkey.pem / .key）: " key_file
                    [[ -n "$key_file" && -f "$key_file" ]] && break
                    warn "文件不存在，请重新输入"
                done
                sni=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN\s*=\s*//' | head -n1) || sni=""
                [[ -n "$sni" ]] && info "证书 CN: $sni"
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
    echo " 1) 限速 100 Mbps（上下行）"
    echo " 2) 不限速"
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
    local pass
    pass=$(openssl rand -hex 16 2>/dev/null || od -An -N16 -x /dev/urandom | tr -d '[:space:]')
    info "认证密码: ${pass}"

    # --- 构建配置 ---
    local tls_block=""
    case "$cert_method" in
        self|custom)
            tls_block="  cert: ${cert_file}\n  key: ${key_file}"
            ;;
        acme)
            tls_block="  acme:\n    domains:\n      - ${acme_domain}\n    email: ${acme_email}"
            ;;
    esac

    local bandwidth_block=""
    if [[ "$limit_speed" == "yes" ]]; then
        bandwidth_block="bandwidth:\n  up: ${speed_up} mbps\n  down: ${speed_down} mbps"
    fi

    cat > "$HY2_CONFIG" <<EOF
listen: ${listen_addr}

tls:
$(echo -e "$tls_block")

auth: ${pass}

$(echo -e "$bandwidth_block")

sniff:
  enable: true
  timeout: 2s

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false
EOF

    if [[ "$port_hop_enabled" == "yes" ]]; then
        cat >> "$HY2_CONFIG" <<EOF

portHopping:
  interval: ${port_hop_interval}
EOF
    fi

    if [[ "$cert_method" == "self" || "$cert_method" == "custom" ]]; then
        cat >> "$HY2_CONFIG" <<EOF

masquerade:
  type: proxy
  proxy:
    url: https://${sni}
    rewriteHost: true
    insecure: ${insecure}
EOF
    fi

    chmod 600 "$HY2_CONFIG"
    info "Hysteria2 配置已写入: $HY2_CONFIG"

    # --- 防火墙规则 ---
    local colon_range
    colon_range=$(echo "$firewall_port_range" | tr '-' ':')
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow proto udp from any to any port "$colon_range" 2>/dev/null || true
        info "UFW 规则已添加: ${colon_range}/udp"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port="${colon_range}/udp" --permanent 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "firewalld 规则已添加: ${colon_range}/udp"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p udp --dport "$colon_range" -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p udp --dport "$colon_range" -j ACCEPT 2>/dev/null || true
        info "iptables 规则已添加: ${colon_range}/udp（重启后失效，请安装 iptables-persistent）"
    fi

    # --- 启动服务 ---
    cat > "/etc/systemd/system/jiaoben-hy2.service" <<EOF
[Unit]
Description=jiaoben Hysteria2 Service
After=network.target

[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${HY2_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now jiaoben-hy2

    # --- 生成节点链接 ---
    local link_sni="$sni"
    [[ -z "$link_sni" ]] && link_sni="www.bing.com"

    local hy2_link="hysteria2://${pass}@${link_sni}:${port}?insecure=${insecure:-0}&sni=${link_sni}#Hysteria2"
    if [[ "$port_hop_enabled" == "yes" ]]; then
        hy2_link="${hy2_link}&mport=${port_hop_range}"
    fi

    append_node "Hysteria2" "$hy2_link"
    success "Hysteria2 部署完成！"
}

# ==========================================
# Argo 隧道域名获取
# ==========================================
get_argo_domain() {
    for i in $(seq 1 15); do
        local domain
        domain=$(grep -oP 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "${WORK_DIR}/argo.log" 2>/dev/null | head -1 | sed 's|https://||')
        if [[ -n "$domain" ]]; then
            echo "$domain"
            return 0
        fi
        sleep 1
    done
    return 1
}

# ==========================================
# 配置备份
# ==========================================
backup_config() {
    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
}

# ==========================================
# 服务存在性检查（修复版）
# ==========================================
service_exists() {
    [[ -f "/etc/systemd/system/jiaoben-$1.service" ]]
}

# ==========================================
# 核心部署逻辑
# ==========================================
deploy_core() {
    local mode=$1
    install_deps

    # mode 4 不清空节点文件（累积），其他模式清空
    [[ "$mode" -eq 4 ]] || : > "$NODES_FILE"

    # --- REALITY (VLESS) ---
    if [[ "$mode" -eq 1 || "$mode" -eq 4 ]]; then
        download_xray
        check_port 443 tcp || warn "端口 443 冲突，REALITY 可能启动失败"

        info "正在配置 REALITY..."
        local uuid priv pub sid domain
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "")
        [[ -z "$uuid" ]] && uuid=$(od -An -N16 -x /dev/urandom | tr -d '[:space:]' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-4\3-\4-/')
        local keys
        keys=$(generate_keys)
        priv=$(echo "$keys" | cut -d: -f1)
        pub=$(echo "$keys" | cut -d: -f2)
        sid=$(openssl rand -hex 8 2>/dev/null || od -An -N8 -x /dev/urandom | tr -d '[:space:]')
        domain="www.microsoft.com"

        backup_config
        cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$uuid", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${domain}:443",
        "xver": 0,
        "serverNames": ["$domain"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
        chmod 600 "$XRAY_CONFIG"

        cat > "/etc/systemd/system/jiaoben-xray.service" <<EOF
[Unit]
Description=jiaoben Xray Service
After=network.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now jiaoben-xray

        local reality_link="vless://${uuid}@$(curl -s4 ifconfig.me 2>/dev/null || curl -s6 ifconfig.me 2>/dev/null || echo 'YOUR_IP'):443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#REALITY"
        append_node "REALITY (VLESS)" "$reality_link"
        success "REALITY 部署完成！"
    fi

    # --- Argo 隧道 ---
    if [[ "$mode" -eq 2 || "$mode" -eq 4 ]]; then
        download_xray
        download_argo

        local argo_port=""
        while true; do
            read -p "Argo 本地端口（回车随机）: " argo_port
            if [[ -z "$argo_port" ]]; then
                argo_port=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]')
                argo_port=$(( argo_port % 40000 + 20000 ))
                info "随机端口: $argo_port"
                break
            fi
            if [[ "$argo_port" =~ ^[0-9]+$ ]] && [[ "$argo_port" -ge 1 ]] && [[ "$argo_port" -le 65535 ]]; then
                if check_port "$argo_port" tcp; then
                    break
                fi
            else
                warn "端口号无效"
            fi
        done

        local uuid path
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "")
        [[ -z "$uuid" ]] && uuid=$(od -An -N16 -x /dev/urandom | tr -d '[:space:]' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-4\3-\4-/')
        path="/$(openssl rand -hex 8 2>/dev/null || od -An -N8 -x /dev/urandom | tr -d '[:space:]')"

        backup_config
        cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $argo_port,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$uuid" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "$path" }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
        chmod 600 "$XRAY_CONFIG"

        # Xray service
        cat > "/etc/systemd/system/jiaoben-xray.service" <<EOF
[Unit]
Description=jiaoben Xray Service
After=network.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now jiaoben-xray

        # Cloudflared service
        cat > "/etc/systemd/system/jiaoben-argo.service" <<EOF
[Unit]
Description=jiaoben Cloudflared Argo Tunnel
After=network.target jiaoben-xray.service

[Service]
Type=simple
ExecStart=${ARGO_BIN} tunnel --url http://127.0.0.1:${argo_port} --no-autoupdate
Restart=on-failure
RestartSec=5s
StandardOutput=append:${WORK_DIR}/argo.log
StandardError=append:${WORK_DIR}/argo.log

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now jiaoben-argo

        # 获取 Argo 域名
        local argo_domain=""
        info "等待 Argo 隧道建立（最多 15 秒）..."
        if argo_domain=$(get_argo_domain); then
            success "Argo 域名获取成功: $argo_domain"
        else
            warn "Argo 域名获取超时，使用备用域名"
            # 多个备用域名
            local fallback_domains=("yg1.ygkkk.dpdns.org" "argo.xxx.xxx")
            argo_domain="${fallback_domains[0]}"
            warn "如果备用域名失效，请查看日志: cat ${WORK_DIR}/argo.log"
        fi

        local encoded_path
        encoded_path=$(printf '%s' "$path" | sed 's|/|%2F|g')
        local argo_link="vless://${uuid}@${argo_domain}:443?encryption=none&type=ws&path=${encoded_path}&security=tls&sni=${argo_domain}&fp=chrome#Argo"
        append_node "Argo 隧道 (VLESS)" "$argo_link"
        success "Argo 部署完成！"
    fi

    # --- Hysteria2 ---
    if [[ "$mode" -eq 3 || "$mode" -eq 4 ]]; then
        deploy_hy2
    fi

    clear
    print_nodes
    success "部署任务完成！"
}

# ==========================================
# 服务管理
# ==========================================
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

stop_services() {
    local found=0
    for svc in xray hy2 argo; do
        if service_exists "$svc"; then
            systemctl stop "jiaoben-$svc"
            success "已停止 jiaoben-$svc"
            found=1
        fi
    done
    [[ $found -eq 0 ]] && warn "未发现任何 jiaoben 服务"
}

# ==========================================
# 卸载
# ==========================================
uninstall_all() {
    echo ""
    warn "⚠️  即将删除所有 jiaoben 组件和配置！"
    echo ""
    echo "以下将被删除："
    echo "  1. 所有 systemd 服务 (jiaoben-xray, jiaoben-hy2, jiaoben-argo)"
    echo "  2. 工作目录: $WORK_DIR"
    echo "  3. 所有配置文件和密钥"
    echo ""
    read -p "确认卸载？请输入 yes 确认: " confirm
    if [[ "$confirm" != "yes" ]]; then
        info "已取消"
        return
    fi

    info "正在卸载所有组件..."

    for svc in xray hy2 argo; do
        if service_exists "$svc"; then
            systemctl disable --now "jiaoben-$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/jiaoben-${svc}.service"
            info "已移除 jiaoben-$svc"
        fi
    done

    # 停止残留进程（使用正确的 pkill）
    for proc in cloudflared xray hysteria; do
        if pgrep -f "$proc" >/dev/null 2>&1; then
            info "终止残留进程: $proc"
            pkill -9 -f "$proc" 2>/dev/null || killall -9 "$proc" 2>/dev/null || true
        fi
    done

    rm -rf "$WORK_DIR"
    systemctl daemon-reload
    success "已彻底卸载"
}

# ==========================================
# 主菜单
# ==========================================
main_menu() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}   jiaoben 一键脚本 v${VERSION}${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo "1. 部署 REALITY (VLESS)       — 端口 443，高性能"
    echo "2. 部署 Argo 隧道 (VLESS)     — 无需暴露真实 IP"
    echo "3. 部署 Hysteria2             — 基于 QUIC，低延迟"
    echo "4. 一键部署全部"
    echo "5. 查看节点信息"
    echo "6. 停止/重启服务"
    echo "7. 彻底卸载"
    echo "0. 退出"
    echo -e "${CYAN}=========================================${NC}"
    read -p "请选择 [0-7]: " choice

    case $choice in
        1) deploy_core 1 ;;
        2) deploy_core 2 ;;
        3) deploy_core 3 ;;
        4) : > "$NODES_FILE"; deploy_core 4 ;;
        5) print_nodes ;;
        6)
            echo ""
            echo "1) 重启所有服务"
            echo "2) 停止所有服务"
            read -p "请选择 [1-2]: " sub
            case $sub in
                1) restart_services ;;
                2) stop_services ;;
                *) warn "无效选择" ;;
            esac
            ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

# ==========================================
# 入口
# ==========================================
check_env

while true; do
    main_menu
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo ""
done