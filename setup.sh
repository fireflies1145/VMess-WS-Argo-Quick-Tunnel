#!/usr/bin/env bash
# ==========================================
# jiaoben - 代理节点一键部署系统 v4.3
# 更新日期: 2026-06-07
# 修复: xray 二进制有效性校验、错误陷阱连锁、set -u 兼容
# ==========================================
set -Euo pipefail

VERSION="4.4"

# --- 加载公共库 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/common.sh" ]]; then
    source "$SCRIPT_DIR/common.sh"
fi

# ==========================================
# 基础配置
# ==========================================
export WORKDIR_BASE="${WORKDIR_BASE:-/root/.jiaoben}"
export INFO_FILE="${WORKDIR_BASE}/all_nodes_info.txt"

# --- 颜色（兼容 bash 3.x） ---
if [[ -z "${RED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
fi

# --- 日志函数 ---
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log_info()    { echo -e "${GREEN}[INFO]${NC}    $(_ts) - $1"; }
_log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $(_ts) - $1" >&2; }
_log_error()   { echo -e "${RED}[ERROR]${NC}   $(_ts) - $1" >&2; }
_log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(_ts) - $1"; }

# 如果 common.sh 未定义则使用本地版本
if ! declare -f info &>/dev/null; then
    info()    { _log_info "$*"; }
    success() { _log_success "$*"; }
    warn()    { _log_warn "$*"; }
    error()   { _log_error "$*"; exit 1; }
fi

# --- 错误陷阱（抑制连锁触发） ---
_error_trap_fired=0
_error_trap_handler() {
    # 防止 trap 连锁触发
    [[ $_error_trap_fired -eq 1 ]] && return
    _error_trap_fired=1
    trap - ERR
    _log_error "脚本在第 ${1:-?} 行出错，正在退出..."
    exit 1
}
trap '_error_trap_handler ${LINENO}' ERR

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
    [[ $EUID -ne 0 ]] && { _log_error "此脚本必须以 root 身份运行"; exit 1; }

    # 确保基础工具可用
    if ! command -v ss &>/dev/null; then
        _log_info "安装 iproute2 (ss 命令)..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq iproute2 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y -q iproute 2>/dev/null || true
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
    local a; a=$(uname -m)
    case "$a" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)              echo "amd64" ;;
    esac
}

detect_xray_arch() {
    local a; a=$(uname -m)
    case "$a" in
        x86_64|amd64)   echo "64" ;;
        aarch64|arm64)  echo "arm64-v8a" ;;
        *)              echo "64" ;;
    esac
}

# ==========================================
# 端口检测
# ==========================================
check_port() {
    local port="$1"
    local proto="${2:-tcp}"

    local ss_opt netstat_opt
    case "$proto" in
        tcp)  ss_opt="-tlnp"; netstat_opt="-tlnp" ;;
        udp)  ss_opt="-ulnp"; netstat_opt="-ulnp" ;;
        both) ss_opt="-tulnp"; netstat_opt="-tulnp" ;;
        *)    ss_opt="-tlnp"; netstat_opt="-tlnp" ;;
    esac

    local occupied
    occupied=$(ss "$ss_opt" 2>/dev/null || netstat "$netstat_opt" 2>/dev/null || true)
    if echo "$occupied" | grep -q ":${port} "; then
        _log_warn "端口 $port ($proto) 已被占用:"
        echo "$occupied" | grep ":${port} "
        return 1
    fi
    return 0
}

# ==========================================
# SHA256 校验
# ==========================================
verify_sha256() {
    local file="$1" expected="$2" actual
    [[ -z "$expected" ]] && return 0
    actual=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
    [[ -z "$actual" ]] && actual=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
    [[ -z "$actual" ]] && actual=$(openssl dgst -sha256 "$file" 2>/dev/null | cut -d' ' -f2)
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$file"
        _log_error "SHA256 校验失败: 期望 $expected, 实际 $actual"; exit 1
    fi
    _log_info "SHA256 校验通过 ✓"
}

# ==========================================
# 下载辅助
# ==========================================
download_file() {
    local url="$1" dest="$2" desc="$3" retries=3 i

    for i in $(seq 1 $retries); do
        _log_info "下载 $desc (尝试 $i/$retries)..."
        if wget -q --timeout=60 --show-progress "$url" -O "$dest" 2>/dev/null; then
            [[ -s "$dest" ]] && return 0
        fi
        if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$dest" 2>/dev/null; then
            [[ -s "$dest" ]] && return 0
        fi
        rm -f "$dest"
        _log_warn "下载失败，${i}s 后重试..."
        sleep "$i"
    done
    _log_error "下载 $desc 失败，请检查网络连接"; exit 1
}

# ==========================================
# 安装系统依赖
# ==========================================
install_deps() {
    _log_info "检查安装依赖..."
    local pkgs="curl wget unzip jq openssl coreutils"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq $pkgs 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y -q $pkgs 2>/dev/null || true
    fi
}

# ==========================================
# 下载 Xray（带有效性校验）
# ==========================================
download_xray() {
    # 如果二进制已存在，先校验是否能运行
    if [[ -f "$XRAY_BIN" ]]; then
        _log_info "检测到已有 Xray 二进制，校验中..."
        if "$XRAY_BIN" version &>/dev/null; then
            _log_info "Xray 二进制有效，跳过下载"
            return 0
        else
            _log_warn "Xray 二进制无效，重新下载..."
            rm -f "$XRAY_BIN"
        fi
    fi

    local arch version zip_url
    arch=$(detect_xray_arch)

    _log_info "获取 Xray 最新版本..."
    for i in 1 2 3; do
        version=$(curl -fsSL --connect-timeout 10 \
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
            2>/dev/null | jq -r .tag_name 2>/dev/null || echo "")
        [[ -n "$version" && "$version" != "null" ]] && break
        sleep 2
    done
    [[ -z "$version" || "$version" == "null" ]] && {
        _log_error "无法获取 Xray 版本号（可能触发 GitHub API 限流）"; exit 1;
    }

    zip_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
    download_file "$zip_url" "$WORK_DIR/xray.zip" "Xray ${version}"

    # SHA256 校验
    local expected=""
    if wget -q "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip.dgst" \
        -O "$WORK_DIR/xray.zip.dgst" 2>/dev/null; then
        expected=$(grep -oP 'SHA256=\K[a-f0-9]{64}' "$WORK_DIR/xray.zip.dgst" 2>/dev/null || echo "")
    fi
    [[ -n "$expected" ]] && verify_sha256 "$WORK_DIR/xray.zip" "$expected"

    rm -f "$WORK_DIR/xray.zip.dgst"
    unzip -qo "$WORK_DIR/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    rm -f "$WORK_DIR/xray.zip"

    # 再次校验二进制可执行
    if ! "$XRAY_BIN" version &>/dev/null; then
        _log_error "Xray 二进制下载后无法执行，可能架构不匹配"
        exit 1
    fi
    _log_success "Xray 下载完成: $version"
}

# ==========================================
# 下载 Hysteria2
# ==========================================
download_hy2() {
    [[ -f "$HY2_BIN" ]] && "$HY2_BIN" version &>/dev/null && return 0
    rm -f "$HY2_BIN"

    local arch; arch=$(detect_arch)
    local bin_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    download_file "$bin_url" "$HY2_BIN" "Hysteria2"

    local expected
    expected=$(curl -fsSL --connect-timeout 10 "${bin_url}.sha256" 2>/dev/null | cut -d' ' -f1 || echo "")
    [[ -n "$expected" ]] && verify_sha256 "$HY2_BIN" "$expected"
    chmod +x "$HY2_BIN"
    _log_success "Hysteria2 下载完成"
}

# ==========================================
# 下载 Cloudflared
# ==========================================
download_argo() {
    [[ -f "$ARGO_BIN" ]] && "$ARGO_BIN" version &>/dev/null && return 0
    rm -f "$ARGO_BIN"

    local arch; arch=$(detect_arch)
    local bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    download_file "$bin_url" "$ARGO_BIN" "Cloudflared"

    local expected
    expected=$(curl -fsSL --connect-timeout 10 "${bin_url}.sha256" 2>/dev/null | cut -d' ' -f1 || echo "")
    [[ -n "$expected" ]] && verify_sha256 "$ARGO_BIN" "$expected"
    chmod +x "$ARGO_BIN"
    _log_success "Cloudflared 下载完成"
}

# ==========================================
# 生成密钥（增强错误处理）
# ==========================================
generate_keys() {
    local output priv pub
    _log_info "正在生成 X25519 密钥..."

    # 确保 Xray 二进制可用
    if [[ ! -x "$XRAY_BIN" ]]; then
        _log_error "Xray 二进制不存在或不可执行: $XRAY_BIN"
        exit 1
    fi

    output=$("$XRAY_BIN" x25519 2>&1) || {
        _log_error "Xray x25519 命令执行失败，输出: $output"
        exit 1
    }

    # 解析密钥（兼容新旧格式）
    # Xray >= 25.x: "PrivateKey:" / "Password (PublicKey):"
    # Xray 旧版:     "Private key:" / "Public key:"
    priv=$(echo "$output" | grep -oP 'Private\s*[Kk]ey:\s*\K[^\s]+' || true)
    pub=$(echo "$output" | grep -oP '(?:Public\s*[Kk]ey|Password\s*\(PublicKey\)):\s*\K[^\s]+' || true)

    # fallback: 找所有 base64url 串（X25519 密钥含 _ - 字符）
    if [[ -z "$priv" || -z "$pub" ]]; then
        local keys
        keys=$(echo "$output" | grep -oE '[A-Za-z0-9_\-+/]{43,}' | head -2)
        priv=$(echo "$keys" | head -1)
        pub=$(echo "$keys" | head -2 | tail -1)
    fi

    if [[ -z "$priv" || -z "$pub" ]]; then
        _log_error "无法解析密钥，Xray 输出:\n$output"
        exit 1
    fi

    echo "${priv}:${pub}"
}

# ==========================================
# 生成 UUID
# ==========================================
gen_uuid() {
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen
    else
        local h
        h=$(od -An -N16 -x /dev/urandom 2>/dev/null | tr -d '[:space:]')
        [[ ${#h} -ge 32 ]] || h=$(openssl rand -hex 16 2>/dev/null)
        echo "${h:0:8}-${h:8:4}-4${h:13:3}-${h:17:4}-${h:21:12}"
    fi
}

# ==========================================
# 生成随机 hex
# ==========================================
gen_hex() {
    local len="${1:-16}"
    openssl rand -hex "$len" 2>/dev/null || od -An -N"$len" -x /dev/urandom 2>/dev/null | tr -d '[:space:]'
}

# ==========================================
# 节点信息管理
# ==========================================
_init_nodes_file() { [[ ! -f "$NODES_FILE" ]] && echo "# jiaoben 节点信息" > "$NODES_FILE"; }

append_node() {
    local name="$1" link="$2"
    _init_nodes_file
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
        _log_warn "未发现节点信息"
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
# 防火墙规则
# ==========================================
add_firewall_rule() {
    local colon_range="$1"
    # UFW
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow proto udp from any to any port "$colon_range" 2>/dev/null || true
        _log_info "UFW 规则已添加: ${colon_range}/udp"
    # firewalld
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port="${colon_range}/udp" --permanent 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        _log_info "firewalld 规则已添加: ${colon_range}/udp"
    # iptables
    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p udp --dport "$colon_range" -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p udp --dport "$colon_range" -j ACCEPT 2>/dev/null || true
        _log_info "iptables 规则已添加: ${colon_range}/udp（重启后需保存）"
    fi
}

# ==========================================
# 部署 Hysteria2
# ==========================================
deploy_hy2() {
    download_hy2
    _log_info "正在配置 Hysteria2..."

    # --- 端口配置 ---
    local port=""
    while true; do
        read -p "监听端口（回车随机 10000-59999）: " port
        if [[ -z "$port" ]]; then
            port=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]')
            port=$(( port % 50000 + 10000 ))
            _log_info "随机端口: $port"
            break
        fi
        [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || { _log_warn "无效端口"; continue; }
        if ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            _log_warn "端口 $port 已被占用（UDP）"
            continue
        fi
        _log_info "使用端口: $port"
        break
    done

    # --- 端口跳跃 ---
    local port_hop_enabled="no" port_hop_range="" port_hop_interval="25s"
    local listen_addr=":${port}" firewall_port_range="$port"

    read -p "是否开启端口跳跃 [y/N]: " hop_choice
    [[ "${hop_choice,,}" =~ ^y(es)?$ ]] && port_hop_enabled="yes"

    if [[ "$port_hop_enabled" == "yes" ]]; then
        local default_port_end=$((port + 75)) port_end
        [[ $default_port_end -gt 65535 ]] && default_port_end=65535
        while true; do
            read -p "跳跃结束端口（起始 $port，默认 $default_port_end）: " port_end
            port_end="${port_end:-$default_port_end}"
            [[ "$port_end" =~ ^[0-9]+$ && $port_end -gt $port && $port_end -le 65535 ]] && break
            _log_warn "结束端口须大于 $port 且不超过 65535"
        done
        read -p "跳跃间隔（默认 25s）: " hop_interval
        port_hop_interval="${hop_interval:-25s}"
        port_hop_range="${port}-${port_end}"
        listen_addr=":${port_hop_range}"
        firewall_port_range="${port}-${port_end}"
        _log_info "端口跳跃: ${port_hop_range} 间隔: ${port_hop_interval}"
    fi

    # --- TLS 证书 ---
    local cert_method="" cert_file="" key_file="" sni="" insecure=""
    local acme_domain="" acme_email=""

    echo ""
    echo "TLS 证书方式:"
    echo " 1) 自签证书（SNI 伪装 www.bing.com，客户端需跳过验证）"
    echo " 2) ACME 自动申请（域名需已解析到本机，不支持 CDN）"
    echo " 3) 自定义证书文件"
    echo ""

    while true; do
        read -p "请选择 [1-3]（默认 1）: " cert_choice
        cert_choice="${cert_choice:-1}"
        case "$cert_choice" in
            1)
                cert_method="self"; sni="www.bing.com"; insecure="1"
                if [[ ! -f "${WORK_DIR}/hy2.crt" || ! -f "${WORK_DIR}/hy2.key" ]]; then
                    _log_info "生成自签证书 (CN: $sni)..."
                    openssl req -newkey rsa:2048 -nodes -keyout "${WORK_DIR}/hy2.key" \
                        -x509 -days 3650 -out "${WORK_DIR}/hy2.crt" \
                        -subj "/CN=${sni}" 2>/dev/null || { _log_error "证书生成失败"; exit 1; }
                    chmod 600 "${WORK_DIR}/hy2.key"
                    chmod 644 "${WORK_DIR}/hy2.crt"
                else
                    _log_info "复用已有自签证书"
                fi
                cert_file="${WORK_DIR}/hy2.crt"; key_file="${WORK_DIR}/hy2.key"
                break ;;
            2)
                cert_method="acme"
                _log_warn "⚠ CDN 代理会导致 ACME 验证失败！"
                while true; do
                    read -p "域名（需已解析到本机）: " acme_domain
                    [[ "$acme_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]+)?(\.[a-zA-Z]{2,})$ ]] || { _log_warn "格式不正确"; continue; }
                    local resolved
                    resolved=$(dig +short "$acme_domain" 2>/dev/null | tail -1 || \
                                nslookup "$acme_domain" 2>/dev/null | grep -oP 'Address:\s*\K[0-9.]+' | tail -1 || echo "")
                    if [[ -z "$resolved" ]]; then
                        _log_warn "域名 $acme_domain 无法解析，ACME 可能失败"
                        read -p "继续？[y/N]: " cont
                        [[ "${cont,,}" =~ ^y(es)?$ ]] || continue 2
                    else
                        _log_info "解析: $resolved"
                    fi
                    break
                done
                while true; do
                    read -p "邮箱: " acme_email
                    [[ "$acme_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
                    _log_warn "邮箱格式不正确"
                done
                sni="$acme_domain"; insecure=""
                break ;;
            3)
                cert_method="custom"
                while true; do
                    read -p "证书文件路径 (.crt/.pem): " cert_file
                    [[ -n "$cert_file" && -f "$cert_file" ]] && break
                    _log_warn "文件不存在"
                done
                while true; do
                    read -p "私钥文件路径 (.key): " key_file
                    [[ -n "$key_file" && -f "$key_file" ]] && break
                    _log_warn "文件不存在"
                done
                sni=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN\s*=\s*//' | head -n1) || sni=""
                [[ -n "$sni" ]] && _log_info "证书 CN: $sni"
                insecure=""
                break ;;
            *) _log_warn "请输入 1、2 或 3" ;;
        esac
    done

    # --- 带宽 ---
    local limit_speed="no" speed_up="" speed_down=""
    echo ""
    echo "带宽限速:"
    echo " 1) 限速 100 Mbps"
    echo " 2) 不限速"
    while true; do
        read -p "请选择 [1-2]（默认 2）: " speed_choice
        speed_choice="${speed_choice:-2}"
        case "$speed_choice" in
            1) limit_speed="yes"; speed_up="100"; speed_down="100"; _log_info "限速 100 Mbps"; break ;;
            2) limit_speed="no"; _log_info "不限速"; break ;;
            *) _log_warn "请输入 1 或 2" ;;
        esac
    done

    # --- 密码 ---
    local pass; pass=$(gen_hex 16)
    _log_info "认证密码: ${pass}"

    # --- 构建 YAML ---
    local tls_block=""
    case "$cert_method" in
        self|custom) tls_block="  cert: ${cert_file}\n  key: ${key_file}" ;;
        acme) tls_block="  acme:\n    domains:\n      - ${acme_domain}\n    email: ${acme_email}" ;;
    esac

    local bw_block=""
    [[ "$limit_speed" == "yes" ]] && bw_block="bandwidth:\n  up: ${speed_up} mbps\n  down: ${speed_down} mbps"

    cat > "$HY2_CONFIG" <<EOF
listen: ${listen_addr}

tls:
$(echo -e "$tls_block")

auth: ${pass}

$(echo -e "$bw_block")

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
    _log_info "配置写入: $HY2_CONFIG"

    # 防火墙
    local colon_range; colon_range=$(echo "$firewall_port_range" | tr '-' ':')
    add_firewall_rule "$colon_range"

    # systemd 服务
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

    # 节点链接
    local link_sni="${sni:-www.bing.com}"
    local hy2_link="hysteria2://${pass}@${link_sni}:${port}?insecure=${insecure:-0}&sni=${link_sni}#Hysteria2"
    [[ "$port_hop_enabled" == "yes" ]] && hy2_link="${hy2_link}&mport=${port_hop_range}"

    append_node "Hysteria2" "$hy2_link"
    _log_success "Hysteria2 部署完成！"
}

# ==========================================
# Argo 域名获取
# ==========================================
get_argo_domain() {
    local i domain
    for i in $(seq 1 20); do
        domain=$(grep -oP 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "${WORK_DIR}/argo.log" 2>/dev/null | head -1 | sed 's|https://||')
        [[ -n "$domain" ]] && { echo "$domain"; return 0; }
        sleep 1
    done
    return 1
}

# ==========================================
# 备份配置
# ==========================================
backup_config() {
    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
}

# ==========================================
# 服务存在检查
# ==========================================
service_exists() {
    [[ -f "/etc/systemd/system/jiaoben-$1.service" ]]
}

# ==========================================
# 获取公网 IP
# ==========================================
get_public_ip() {
    curl -s4 ifconfig.me 2>/dev/null || curl -s6 ifconfig.me 2>/dev/null || \
    curl -s ip.sb 2>/dev/null || echo "YOUR_IP"
}

# ==========================================
# 核心部署
# ==========================================
deploy_core() {
    local mode="$1"
    install_deps

    # mode 4 不清空节点文件
    [[ "$mode" -eq 4 ]] || : > "$NODES_FILE"

    # ==================== REALITY ====================
    if [[ "$mode" -eq 1 || "$mode" -eq 4 ]]; then
        download_xray
        check_port 443 tcp || _log_warn "端口 443 可能被占用，REALITY 启动可能失败"

        _log_info "正在配置 REALITY..."
        local uuid priv pub sid domain keys
        uuid=$(gen_uuid)
        keys=$(generate_keys)
        priv=$(echo "$keys" | cut -d: -f1)
        pub=$(echo "$keys" | cut -d: -f2)
        sid=$(gen_hex 8)
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

        local pub_ip; pub_ip=$(get_public_ip)
        local reality_link="vless://${uuid}@${pub_ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#REALITY"
        append_node "REALITY (VLESS)" "$reality_link"
        _log_success "REALITY 部署完成！"
    fi

    # ==================== Argo ====================
    if [[ "$mode" -eq 2 || "$mode" -eq 4 ]]; then
        download_xray
        download_argo

        local argo_port=""
        while true; do
            read -p "Argo 本地端口（回车随机 20000-59999）: " argo_port
            if [[ -z "$argo_port" ]]; then
                argo_port=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]')
                argo_port=$(( argo_port % 40000 + 20000 ))
                _log_info "随机端口: $argo_port"
                break
            fi
            [[ "$argo_port" =~ ^[0-9]+$ && $argo_port -ge 1 && $argo_port -le 65535 ]] || { _log_warn "无效端口"; continue; }
            check_port "$argo_port" tcp && break
        done

        local uuid path
        uuid=$(gen_uuid)
        path="/$(gen_hex 8)"

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

        _log_info "等待 Argo 隧道建立（最多 20 秒）..."
        local argo_domain=""
        if argo_domain=$(get_argo_domain); then
            _log_success "Argo 域名: $argo_domain"
        else
            argo_domain="yg1.ygkkk.dpdns.org"
            _log_warn "获取超时，使用备用域名: $argo_domain"
        fi

        local encoded_path; encoded_path=$(printf '%s' "$path" | sed 's|/|%2F|g')
        local argo_link="vless://${uuid}@${argo_domain}:443?encryption=none&type=ws&path=${encoded_path}&security=tls&sni=${argo_domain}&fp=chrome#Argo"
        append_node "Argo 隧道 (VLESS)" "$argo_link"
        _log_success "Argo 部署完成！"
    fi

    # ==================== Hysteria2 ====================
    if [[ "$mode" -eq 3 || "$mode" -eq 4 ]]; then
        deploy_hy2
    fi

    clear
    print_nodes
    _log_success "部署任务完成！"
}

# ==========================================
# 服务管理
# ==========================================
restart_services() {
    local found=0 svc
    for svc in xray hy2 argo; do
        service_exists "$svc" || continue
        systemctl restart "jiaoben-$svc"
        _log_success "已重启 jiaoben-$svc"
        found=1
    done
    [[ $found -eq 0 ]] && _log_warn "未发现任何 jiaoben 服务"
}

stop_services() {
    local found=0 svc
    for svc in xray hy2 argo; do
        service_exists "$svc" || continue
        systemctl stop "jiaoben-$svc"
        _log_success "已停止 jiaoben-$svc"
        found=1
    done
    [[ $found -eq 0 ]] && _log_warn "未发现任何 jiaoben 服务"
}

# ==========================================
# 卸载
# ==========================================
uninstall_all() {
    echo ""
    _log_warn "⚠️  即将删除所有 jiaoben 组件和配置！"
    echo ""
    echo "以下将被删除："
    echo "  • 所有 systemd 服务"
    echo "  • 工作目录: $WORK_DIR"
    echo "  • 配置文件和密钥"
    echo ""
    read -p "确认卸载？输入 yes 确认: " confirm
    [[ "$confirm" != "yes" ]] && { _log_info "已取消"; return; }

    _log_info "正在卸载..."

    local svc
    for svc in xray hy2 argo; do
        if service_exists "$svc"; then
            systemctl disable --now "jiaoben-$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/jiaoben-${svc}.service"
            _log_info "已移除 jiaoben-$svc"
        fi
    done

    # 终止残留进程（修复 pkill 拼写）
    local proc
    for proc in cloudflared xray hysteria; do
        if pgrep -f "$proc" &>/dev/null; then
            _log_info "终止残留进程: $proc"
            if command -v pkill &>/dev/null; then
                pkill -9 -f "$proc" 2>/dev/null || true
            elif command -v killall &>/dev/null; then
                killall -9 "$proc" 2>/dev/null || true
            else
                pgrep -f "$proc" | xargs -r kill -9 2>/dev/null || true
            fi
        fi
    done

    rm -rf "$WORK_DIR"
    systemctl daemon-reload
    _log_success "已彻底卸载"
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
                *) _log_warn "无效选择" ;;
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