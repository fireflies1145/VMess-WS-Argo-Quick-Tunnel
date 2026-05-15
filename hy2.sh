#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Hysteria 2 一键部署脚本 (改进版)
# 功能: 交互式配置 + systemd 守护 + 防火墙 + NAT 支持 + IPv6
# ==========================================

WORKDIR="${WORKDIR:-${HOME}/hysteria2}"
ARCH="$(uname -m)"
READ_TIMEOUT="${READ_TIMEOUT:-30}"
DEFAULT_HOP_INTERVAL="25s"
SCRIPT_NAME="$(basename "$0")"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ----- 颜色 -----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()     { printf "${RED}[x]${NC} %s\n" "$*"; }
section() { printf "\n${CYAN}%s${NC}\n" "$*"; }

# ----- 检查 root -----
EUID_NOW="$(id -u)"
IS_ROOT=false
[ "$EUID_NOW" -eq 0 ] && IS_ROOT=true

if ! $IS_ROOT; then
    warn "当前非 root 用户运行。部分功能受限（防火墙、systemd 系统服务等）。"
    warn "强烈建议使用 root 运行本脚本以获得完整功能。"
    echo ""
fi

# ----- 依赖检查 -----
section "[0/10] 检查环境与架构..."

case "$ARCH" in
    x86_64|amd64)   HYSTERIA_BIN="hysteria-linux-amd64" ;;
    aarch64|arm64)  HYSTERIA_BIN="hysteria-linux-arm64" ;;
    armv7l|armv6l|armv*) HYSTERIA_BIN="hysteria-linux-arm" ;;
    i386|i686)      HYSTERIA_BIN="hysteria-linux-386" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "缺少依赖 \"$1\""; echo "请执行: apt update && apt install -y curl openssl grep sed coreutils"; exit 1; }; }
need_cmd curl; need_cmd openssl; need_cmd grep; need_cmd sed; need_cmd head; need_cmd tr

# ----- 公网 IP 获取 (双栈) -----
get_public_ip() {
    local ip=""
    # 先尝试 IPv4
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip" && return 0
        fi
    done
    # 再尝试 IPv6
    for url in "https://api64.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -6 -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
        if [ -n "$ip" ] && [[ "$ip" =~ : ]]; then
            echo "$ip" && return 0
        fi
    done
    # 从网卡获取
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1) || true
    [ -n "$ip" ] && echo "$ip" && return 0
    ip=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80' | head -n1) || true
    [ -n "$ip" ] && echo "$ip" && return 0
    echo "" && return 1
}

# ----- 端口检测 -----
check_port_in_use() {
    local port="$1"
    (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1 && return 0
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -q ":$port " && return 0
        ss -ulnp 2>/dev/null | grep -q ":$port " && return 0
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1 && return 0
    fi
    return 1
}

random_port() {
    local port
    for i in $(seq 1 200); do
        if [ -r /dev/urandom ]; then
            port=$(( (0x$(od -An -N2 -tu2 /dev/urandom) % 50000) + 10000 ))
        else
            port=$(( (RANDOM << 15 | RANDOM) % 50000 + 10000 ))
        fi
        check_port_in_use "$port" || { echo "$port"; return 0; }
    done
    return 1
}

# ----- 防火墙管理 -----
configure_firewall() {
    local port_range="$1"  # 如 "10000" 或 "10000:10075"
    local proto="${2:-udp}"
    local applied=false

    if ! $IS_ROOT; then
        warn "非 root 用户，跳过防火墙配置。请手动放行 UDP 端口: $port_range"
        return
    fi

    # UFW
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "检测到 UFW 防火墙，正在添加规则..."
        if [[ "$port_range" == *:* ]]; then
            ufw allow proto "$proto" from any to any port "${port_range#*:}" 2>/dev/null || true
        else
            ufw allow "$port_range/$proto" 2>/dev/null || true
        fi
        applied=true
    fi

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        info "检测到 firewalld，正在添加规则..."
        firewall-cmd --permanent --add-port="${port_range}/${proto}" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        applied=true
    fi

    # iptables (作为后备)
    if ! $applied && command -v iptables >/dev/null 2>&1; then
        info "尝试使用 iptables 添加规则..."
        if [[ "$port_range" == *:* ]]; then
            local start_port="${port_range%%:*}"
            local end_port="${port_range##*:}"
            iptables -C INPUT -p "$proto" --dport "${start_port}:${end_port}" -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p "$proto" --dport "${start_port}:${end_port}" -j ACCEPT 2>/dev/null || true
        else
            iptables -C INPUT -p "$proto" --dport "$port_range" -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p "$proto" --dport "$port_range" -j ACCEPT 2>/dev/null || true
        fi
        applied=true
    fi

    if $applied; then
        info "防火墙规则已添加 (${port_range}/${proto})"
    else
        warn "未检测到可配置的防火墙，请手动放行 UDP 端口: $port_range"
    fi
}

# ==========================================
# 第 1 步：端口选择
# ==========================================
section "[1/10] 配置监听端口..."

PORT=""
USER_PORT=""

while true; do
    if [ -t 0 ]; then
        printf '请输入监听端口 (10000-59999，%d秒无操作自动随机): ' "$READ_TIMEOUT"
        read -t "$READ_TIMEOUT" -r USER_PORT || true
        echo ""
    else
        echo "非交互环境，自动分配随机端口..."
    fi

    [ -z "$USER_PORT" ] && { PORT=$(random_port) || fail_exit "无法自动分配空闲端口"; info "已分配随机端口: $PORT"; break; }

    if ! [[ "$USER_PORT" =~ ^[0-9]+$ ]] || [ "$USER_PORT" -lt 1 ] || [ "$USER_PORT" -gt 65535 ]; then
        warn "输入无效，请输入 1-65535 之间的数字。"; USER_PORT=""; continue
    fi

    if check_port_in_use "$USER_PORT"; then
        warn "端口 $USER_PORT 已被占用，请更换。"; USER_PORT=""; continue
    fi

    PORT="$USER_PORT"
    info "使用指定端口: $PORT"
    break
done

# ==========================================
# 第 2 步：NAT 检测
# ==========================================
section "[2/10] NAT 环境检测..."

PUBLIC_IP=""
NAT_MODE="no"
NAT_PUBLIC_PORT="$PORT"  # 默认与本地端口相同

PUBLIC_IP=$(get_public_ip) || PUBLIC_IP=""

if [ -n "$PUBLIC_IP" ]; then
    info "检测到公网 IP: $PUBLIC_IP"
else
    warn "无法获取公网 IP，可能处于 NAT 环境或网络受限。"
fi

while true; do
    if [ -t 0 ]; then
        printf '服务器是否在 NAT 后面（公网端口与本地端口不同）？[y/N] (%d秒无操作默认 N): ' "$READ_TIMEOUT"
        read -t "$READ_TIMEOUT" -r IS_NAT || true
        echo ""
    else
        IS_NAT="n"
    fi
    [ -z "$IS_NAT" ] && IS_NAT="n"
    case "${IS_NAT,,}" in
        y|yes)
            NAT_MODE="yes"
            while true; do
                printf '请输入公网 IP 或域名: '
                read -t "$READ_TIMEOUT" -r PUBLIC_IP || true
                echo ""
                [ -n "$PUBLIC_IP" ] && break
                warn "不能为空。"
            done
            while true; do
                printf '请输入公网端口 (默认: %d): ' "$PORT"
                read -t "$READ_TIMEOUT" -r NAT_PUBLIC_PORT || true
                echo ""
                [ -z "$NAT_PUBLIC_PORT" ] && NAT_PUBLIC_PORT="$PORT"
                if [[ "$NAT_PUBLIC_PORT" =~ ^[0-9]+$ ]] && [ "$NAT_PUBLIC_PORT" -ge 1 ] && [ "$NAT_PUBLIC_PORT" -le 65535 ]; then
                    break
                fi
                warn "端口格式无效，请重新输入。"
            done
            info "NAT 模式: 公网 $PUBLIC_IP:$NAT_PUBLIC_PORT -> 本地 $PORT"
            break
            ;;
        n|no|"")
            NAT_MODE="no"
            if [ -z "$PUBLIC_IP" ]; then
                warn "无法获取公网 IP，分享链接将使用 127.0.0.1 占位。"
                PUBLIC_IP="127.0.0.1"
            fi
            break
            ;;
        *) warn "请输入 y 或 n" ;;
    esac
done

# ==========================================
# 第 3 步：端口跳跃
# ==========================================
section "[3/10] 配置端口跳跃..."

PORT_HOP_ENABLED="no"
PORT_HOP_RANGE=""
PORT_HOP_INTERVAL="$DEFAULT_HOP_INTERVAL"
PORT_END=""

while true; do
    if [ -t 0 ]; then
        printf '是否开启端口跳跃功能？[y/N] (%d秒无操作默认 N): ' "$READ_TIMEOUT"
        read -t "$READ_TIMEOUT" -r ENABLE_HOP || true
        echo ""
    else
        ENABLE_HOP="n"
    fi
    [ -z "$ENABLE_HOP" ] && ENABLE_HOP="n"
    case "${ENABLE_HOP,,}" in
        y|yes) PORT_HOP_ENABLED="yes"; break ;;
        n|no|"") PORT_HOP_ENABLED="no"; break ;;
        *) warn "请输入 y 或 n" ;;
    esac
done

if [ "$PORT_HOP_ENABLED" = "yes" ]; then
    if [ "$NAT_MODE" = "yes" ]; then
        warn "NAT 环境下端口跳跃可能不可用，请确认公网端口范围映射是否配置。"
    fi

    DEFAULT_PORT_OFFSET=75
    DEFAULT_PORT_END=$((PORT + DEFAULT_PORT_OFFSET))
    [ "$DEFAULT_PORT_END" -gt 65535 ] && DEFAULT_PORT_END=65535

    while true; do
        printf '请输入端口跳跃范围结束端口 (默认: %d，即 %d-%d): ' "$DEFAULT_PORT_END" "$PORT" "$DEFAULT_PORT_END"
        read -t "$READ_TIMEOUT" -r USER_PORT_END || true
        echo ""
        [ -z "$USER_PORT_END" ] && { PORT_END="$DEFAULT_PORT_END"; break; }
        if ! [[ "$USER_PORT_END" =~ ^[0-9]+$ ]] || [ "$USER_PORT_END" -le "$PORT" ] || [ "$USER_PORT_END" -gt 65535 ]; then
            warn "输入无效，结束端口必须大于 $PORT 且不超过 65535。"; continue
        fi
        PORT_END="$USER_PORT_END"
        break
    done

    PORT_HOP_RANGE="${PORT}-${PORT_END}"
    info "端口跳跃范围: $PORT_HOP_RANGE"

    # 抽查范围端口
    local conflict_count=0
    for check_p in $(seq "$PORT" "$PORT_END"); do
        if check_port_in_use "$check_p"; then
            warn "端口 $check_p 已被占用。"
            conflict_count=$((conflict_count + 1))
            [ "$conflict_count" -ge 3 ] && { warn "多个端口被占用，请检查端口范围。"; break; }
        fi
    done

    printf '请输入端口跳跃间隔 (默认: %s): ' "$DEFAULT_HOP_INTERVAL"
    read -t "$READ_TIMEOUT" -r USER_HOP_INTERVAL || true
    echo ""
    [ -n "$USER_HOP_INTERVAL" ] && PORT_HOP_INTERVAL="$USER_HOP_INTERVAL"
    info "端口跳跃间隔: $PORT_HOP_INTERVAL"

    LISTEN_ADDR=":${PORT_HOP_RANGE}"
    FIREWALL_PORT_RANGE="${PORT}:${PORT_END}"
else
    LISTEN_ADDR=":${PORT}"
    FIREWALL_PORT_RANGE="$PORT"
fi

# ==========================================
# 第 4 步：证书配置
# ==========================================
section "[4/10] 配置 TLS 证书..."

CERT_METHOD=""; CERT_FILE=""; KEY_FILE=""; SNI=""; INSECURE=""
ACME_DOMAIN=""; ACME_EMAIL=""; ACME_LISTEN=""  # ACME 验证监听地址

echo "请选择证书方案:"
echo "  1) 自签证书 (SNI 伪装为 www.bing.com，客户端需跳过验证)"
echo "  2) ACME 自动申请 (需域名已解析到本服务器，注意: 如使用 CDN 代理请先关闭)"
echo "  3) 自定义证书 (已有证书文件)"
echo ""

while true; do
    if [ -t 0 ]; then
        printf '请输入选项 [1-3] (%d秒无操作默认 1): ' "$READ_TIMEOUT"
        read -t "$READ_TIMEOUT" -r CERT_CHOICE || true
        echo ""
    else
        CERT_CHOICE="1"
    fi
    [ -z "$CERT_CHOICE" ] && CERT_CHOICE="1"

    case "$CERT_CHOICE" in
        1) # 自签
            CERT_METHOD="self"
            SNI="www.bing.com"; INSECURE="1"
            if [ ! -f "${WORKDIR}/server.crt" ] || [ ! -f "${WORKDIR}/server.key" ]; then
                info "正在生成自签证书 (CN: $SNI)..."
                openssl req -newkey rsa:2048 -nodes -keyout "${WORKDIR}/server.key" \
                    -x509 -days 3650 -out "${WORKDIR}/server.crt" \
                    -subj "/CN=${SNI}" 2>/dev/null || fail_exit "自签证书生成失败"
                chmod 600 "${WORKDIR}/server.key" "${WORKDIR}/server.crt"
                info "自签证书已生成。"
            else
                info "发现已有自签证书，跳过生成。"
            fi
            CERT_FILE="${WORKDIR}/server.crt"
            KEY_FILE="${WORKDIR}/server.key"
            break
            ;;
        2) # ACME
            CERT_METHOD="acme"
            info "选择: ACME 自动申请"
            warn "注意: 如果域名使用了 CDN 代理（如 Cloudflare 橙色云朵），"
            warn "       TLS-ALPN-01 / HTTP-01 验证将会失败，请先关闭 CDN 代理，"
            warn "       或使用方案 3（自定义证书）+ certbot/acme.sh 手动申请。"

            while true; do
                printf '请输入已解析到本服务器的域名: '
                read -t "$READ_TIMEOUT" -r ACME_DOMAIN || true; echo ""
                [ -z "$ACME_DOMAIN" ] && { warn "域名不能为空。"; continue; }
                [[ "$ACME_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] && break
                warn "域名格式不正确，请重新输入。"
            done

            # 验证 DNS 解析
            RESOLVED_IP=""
            if command -v dig >/dev/null 2>&1; then
                RESOLVED_IP=$(dig +short "$ACME_DOMAIN" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1) || true
            elif command -v nslookup >/dev/null 2>&1; then
                RESOLVED_IP=$(nslookup "$ACME_DOMAIN" 2>/dev/null | grep -oE 'Address: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | awk '{print $2}') || true
            fi
            if [ -n "$RESOLVED_IP" ] && [ -n "$PUBLIC_IP" ] && [ "$RESOLVED_IP" = "$PUBLIC_IP" ]; then
                info "DNS 解析验证通过: $ACME_DOMAIN -> $RESOLVED_IP"
            elif [ -n "$RESOLVED_IP" ]; then
                warn "域名解析到 $RESOLVED_IP，本机公网 IP 为 ${PUBLIC_IP:-未知}，可能不匹配。"
            else
                warn "无法验证 DNS 解析，请自行确认域名已正确解析。"
            fi

            while true; do
                printf '请输入邮箱地址 (Let'\''s Encrypt 通知): '
                read -t "$READ_TIMEOUT" -r ACME_EMAIL || true; echo ""
                [ -z "$ACME_EMAIL" ] && { warn "邮箱不能为空。"; continue; }
                [[ "$ACME_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
                warn "邮箱格式不正确，请重新输入。"
            done

            # ACME 验证端口：优先 443 (TLS-ALPN-01)，否则 80 (HTTP-01)
            if ! check_port_in_use 443; then
                ACME_LISTEN=":443"
                info "ACME 将使用 TLS-ALPN-01 验证 (端口 443)"
            elif ! check_port_in_use 80; then
                ACME_LISTEN=":80"
                info "ACME 将使用 HTTP-01 验证 (端口 80)"
            else
                warn "端口 443 和 80 均被占用，ACME 验证可能失败。"
                warn "建议停止占用端口的服务，或改用自定义证书。"
                ACME_LISTEN=":443"  # 尝试默认
            fi

            # 权限检查：如果 ACME 监听端口 < 1024 且非 root
            local acme_port="${ACME_LISTEN#:}"
            if [ "$acme_port" -lt 1024 ] && ! $IS_ROOT; then
                if command -v setcap >/dev/null 2>&1; then
                    warn "ACME 需要绑定低位端口 $acme_port，将尝试 setcap。"
                else
                    err "ACME 需要绑定低位端口 $acme_port，但当前非 root 且无 setcap。"
                    err "请使用 root 运行，或安装 libcap2-bin 包，或改用其他证书方案。"
                    fail_exit "权限不足，无法继续。"
                fi
            fi

            SNI="$ACME_DOMAIN"; INSECURE=""
            CERT_FILE=""; KEY_FILE=""
            break
            ;;
        3) # 自定义
            CERT_METHOD="custom"
            while true; do
                printf '请输入证书文件路径 (fullchain.pem/.crt): '
                read -t "$READ_TIMEOUT" -r CERT_FILE || true; echo ""
                [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ] && break
                warn "文件不存在或路径为空，请重新输入。"
            done
            while true; do
                printf '请输入密钥文件路径 (privkey.pem/.key): '
                read -t "$READ_TIMEOUT" -r KEY_FILE || true; echo ""
                [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] && break
                warn "文件不存在或路径为空，请重新输入。"
            done
            # 检测证书权限
            if [ "$(stat -c %a "$KEY_FILE" 2>/dev/null || echo 644)" != "600" ]; then
                warn "密钥文件权限过于开放，建议执行: chmod 600 $KEY_FILE"
            fi
            SNI=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*//p' | head -n1) || SNI=""
            INSECURE=""
            [ -n "$SNI" ] && info "检测到证书 CN: $SNI"
            break
            ;;
        *) warn "请输入 1、2 或 3。" ;;
    esac
done

# ==========================================
# 第 5 步：限速配置
# ==========================================
section "[5/10] 配置限速..."

LIMIT_SPEED="no"; SPEED_UP=""; SPEED_DOWN=""

while true; do
    echo "请选择限速方案:"
    echo "  1) 限速 100 Mbps (上下行)"
    echo "  2) 不限速"
    echo ""
    if [ -t 0 ]; then
        printf '请输入选项 [1-2] (%d秒无操作默认 2): ' "$READ_TIMEOUT"
        read -t "$READ_TIMEOUT" -r SPEED_CHOICE || true
        echo ""
    else
        SPEED_CHOICE="2"
    fi
    [ -z "$SPEED_CHOICE" ] && SPEED_CHOICE="2"
    case "$SPEED_CHOICE" in
        1) LIMIT_SPEED="yes"; SPEED_UP="100"; SPEED_DOWN="100"; info "已选择: 限速 100 Mbps"; break ;;
        2) LIMIT_SPEED="no"; info "已选择: 不限速"; break ;;
        *) warn "请输入 1 或 2。" ;;
    esac
done

# ==========================================
# 第 6 步：下载 Hysteria 2
# ==========================================
section "[6/10] 获取 Hysteria 2..."

download_file() {
    local url="$1" output="$2" desc="$3"
    curl --retry 3 --retry-delay 2 -fsSL --connect-timeout 15 "$url" -o "$output" || { err "下载失败: $desc"; return 1; }
    [ -s "$output" ] || { err "下载文件为空: $desc"; return 1; }
    return 0
}

if [ ! -x "./hysteria" ] || ! ./hysteria version >/dev/null 2>&1; then
    rm -f hysteria
    info "正在下载 Hysteria 2 (${HYSTERIA_BIN})..."
    download_file "https://github.com/apernet/hysteria/releases/latest/download/${HYSTERIA_BIN}" \
        hysteria "Hysteria 2" || fail_exit "Hysteria 2 下载失败"
    chmod +x hysteria
fi

HYSTERIA_VERSION=$(./hysteria version 2>/dev/null | head -n1 || echo "未知")
info "Hysteria 版本: $HYSTERIA_VERSION"

# ----- setcap 处理（非 root + 低位端口） -----
if [ "$PORT" -lt 1024 ] && ! $IS_ROOT; then
    info "检测到低位端口 ($PORT) 且非 root，尝试 setcap..."
    if command -v setcap >/dev/null 2>&1; then
        setcap cap_net_bind_service=+ep "${WORKDIR}/hysteria" 2>/dev/null || {
            warn "setcap 失败，请使用 root 运行或选择 1024+ 端口。"
        }
    else
        warn "setcap 不可用 (需 libcap2-bin)，请使用 root 或选择 1024+ 端口。"
    fi
fi

# ==========================================
# 第 7 步：生成配置
# ==========================================
section "[7/10] 生成配置文件..."

PASSWORD=$(openssl rand -hex 16)
info "认证密码: $PASSWORD"

# TLS 配置块
if [ "$CERT_METHOD" = "self" ]; then
    TLS_BLOCK=$(cat <<EOF
tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}
EOF
)
elif [ "$CERT_METHOD" = "acme" ]; then
    if [ "$ACME_LISTEN" != ":443" ]; then
        TLS_BLOCK=$(cat <<EOF
tls:
  acme:
    domains:
      - ${ACME_DOMAIN}
    email: ${ACME_EMAIL}
    listen: ${ACME_LISTEN}
    type: http-01
EOF
)
    else
        TLS_BLOCK=$(cat <<EOF
tls:
  acme:
    domains:
      - ${ACME_DOMAIN}
    email: ${ACME_EMAIL}
EOF
)
    fi
else
    TLS_BLOCK=$(cat <<EOF
tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}
EOF
)
fi

# 限速块
SPEED_BLOCK=""
[ "$LIMIT_SPEED" = "yes" ] && SPEED_BLOCK=$(cat <<EOF
speed:
  up: "${SPEED_UP} mbps"
  down: "${SPEED_DOWN} mbps"
EOF
)

cat > "${WORKDIR}/config.yaml" <<YAML_EOF
# Hysteria 2 配置 - 由 ${SCRIPT_NAME} 自动生成
listen: ${LISTEN_ADDR}

${TLS_BLOCK}

auth:
  type: password
  password: ${PASSWORD}

${SPEED_BLOCK}

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAliveInterval: 10s

log:
  level: warn
  file: ${WORKDIR}/hysteria.log
YAML_EOF

chmod 600 "${WORKDIR}/config.yaml"
[ "$CERT_METHOD" = "self" ] && { chmod 600 "${WORKDIR}/server.key" 2>/dev/null || true; chmod 600 "${WORKDIR}/server.crt" 2>/dev/null || true; }
info "配置文件已生成并设置权限 600。"

# ==========================================
# 第 8 步：防火墙配置
# ==========================================
section "[8/10] 配置防火墙..."

configure_firewall "$FIREWALL_PORT_RANGE" "udp"

# ==========================================
# 第 9 步：启动服务
# ==========================================
section "[9/10] 启动 Hysteria 2 服务..."

# 清理旧进程
if [ -f "${WORKDIR}/hysteria.pid" ]; then
    OLD_PID=$(cat "${WORKDIR}/hysteria.pid" 2>/dev/null || true)
    [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && kill "$OLD_PID" 2>/dev/null || true
    rm -f "${WORKDIR}/hysteria.pid"
fi

SYSTEMD_MODE=false
SYSTEMD_SERVICE="hysteria2"

# 尝试 systemd（需要 root）
if $IS_ROOT && command -v systemctl >/dev/null 2>&1; then
    SYSTEMD_MODE=true

    # 生成 systemd service
    cat > "/etc/systemd/system/${SYSTEMD_SERVICE}.service" <<SERVICE_EOF
[Unit]
Description=Hysteria 2 Proxy Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${WORKDIR}
ExecStart=${WORKDIR}/hysteria server -c ${WORKDIR}/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
# 允许非 root 绑定低位端口（如果设置了 setcap）
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable --now "${SYSTEMD_SERVICE}" 2>/dev/null || {
        warn "systemctl 启动失败，回退到 nohup 模式。"
        SYSTEMD_MODE=false
    }
fi

if ! $SYSTEMD_MODE; then
    # nohup 模式
    : > "${WORKDIR}/hysteria.log"
    nohup "${WORKDIR}/hysteria" server -c "${WORKDIR}/config.yaml" \
        > "${WORKDIR}/hysteria.log" 2>&1 &
    echo $! > "${WORKDIR}/hysteria.pid"
    HY_PID=$(cat "${WORKDIR}/hysteria.pid")

    # 等待就绪
    for i in $(seq 1 30); do
        if ! kill -0 "$HY_PID" 2>/dev/null; then
            err "Hysteria 启动失败，日志:"; cat "${WORKDIR}/hysteria.log"
            fail_exit "Hysteria 进程异常退出"
        fi
        if check_port_in_use "$PORT"; then
            info "Hysteria 已成功启动 (PID: $HY_PID)"
            break
        fi
        [ "$i" -eq 30 ] && { err "Hysteria 启动超时，日志:"; cat "${WORKDIR}/hysteria.log"; fail_exit "端口等待超时"; }
        sleep 0.5
    done
fi

# ACME 额外等待
if [ "$CERT_METHOD" = "acme" ]; then
    info "ACME 模式，等待证书申请 (最多 60 秒)..."
    for i in $(seq 1 60); do
        if grep -qi "certificate" "${WORKDIR}/hysteria.log" 2>/dev/null; then break; fi
        sleep 1
    done
fi

# ==========================================
# 第 10 步：生成分享链接
# ==========================================
section "[10/10] 生成分享链接..."

SHARE_HOST="$PUBLIC_IP"
SHARE_PORT="$NAT_PUBLIC_PORT"
[ "$CERT_METHOD" = "acme" ] && SHARE_HOST="$ACME_DOMAIN"

# IPv6 地址加方括号
if [[ "$SHARE_HOST" =~ : ]] && [[ ! "$SHARE_HOST" =~ \[ ]]; then
    SHARE_HOST="[${SHARE_HOST}]"
fi

SHARE_LINK="hysteria2://${PASSWORD}@${SHARE_HOST}:${SHARE_PORT}?"
PARAMS=""

[ -n "$SNI" ] && PARAMS="${PARAMS}&sni=${SNI}"
[ "$INSECURE" = "1" ] && PARAMS="${PARAMS}&insecure=1"
if [ "$PORT_HOP_ENABLED" = "yes" ]; then
    PARAMS="${PARAMS}&mport=${PORT_HOP_RANGE}&hop_interval=${PORT_HOP_INTERVAL}"
fi
[ "$LIMIT_SPEED" = "yes" ] && PARAMS="${PARAMS}&upmbps=${SPEED_UP}&downmbps=${SPEED_DOWN}"
PARAMS="${PARAMS#&}"
SHARE_LINK="${SHARE_LINK}${PARAMS}#HY2-${SHARE_HOST}"

# ----- 管理脚本 -----
cat > "${WORKDIR}/stop.sh" <<'SCRIPT_EOF'
#!/usr/bin/env bash
WORKDIR="${WORKDIR:-${HOME}/hysteria2}"
SYSTEMD_SERVICE="hysteria2"
if systemctl is-active --quiet "${SYSTEMD_SERVICE}" 2>/dev/null; then
    systemctl stop "${SYSTEMD_SERVICE}"
    echo "已通过 systemctl 停止 ${SYSTEMD_SERVICE}。"
elif [ -f "${WORKDIR}/hysteria.pid" ]; then
    pid=$(cat "${WORKDIR}/hysteria.pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    rm -f "${WORKDIR}/hysteria.pid"
    echo "Hysteria 2 (nohup) 已停止。"
else
    echo "未找到运行中的 Hysteria 2 进程。"
fi
SCRIPT_EOF
chmod +x "${WORKDIR}/stop.sh"

cat > "${WORKDIR}/uninstall.sh" <<'SCRIPT_EOF'
#!/usr/bin/env bash
WORKDIR="${WORKDIR:-${HOME}/hysteria2}"
SYSTEMD_SERVICE="hysteria2"
if systemctl is-active --quiet "${SYSTEMD_SERVICE}" 2>/dev/null; then
    systemctl stop "${SYSTEMD_SERVICE}" 2>/dev/null || true
    systemctl disable "${SYSTEMD_SERVICE}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SYSTEMD_SERVICE}.service"
    systemctl daemon-reload 2>/dev/null || true
elif [ -f "${WORKDIR}/hysteria.pid" ]; then
    pid=$(cat "${WORKDIR}/hysteria.pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
fi
rm -rf "${WORKDIR}"
echo "Hysteria 2 已完全卸载。"
SCRIPT_EOF
chmod +x "${WORKDIR}/uninstall.sh"

# ----- 信息汇总 -----
cat > "${WORKDIR}/info.txt" <<INFO_EOF
========================================
Hysteria 2 节点部署信息
========================================
协议: Hysteria 2
地址: ${SHARE_HOST}
端口: ${SHARE_PORT}
端口跳跃: ${PORT_HOP_ENABLED}
$([ "$PORT_HOP_ENABLED" = "yes" ] && echo "跳跃范围: ${PORT_HOP_RANGE}")
$([ "$PORT_HOP_ENABLED" = "yes" ] && echo "跳跃间隔: ${PORT_HOP_INTERVAL}")
认证密码: ${PASSWORD}
证书方式: ${CERT_METHOD}
$([ "$CERT_METHOD" = "self" ] && echo "SNI伪装: ${SNI}")
$([ "$CERT_METHOD" = "self" ] && echo "跳过证书验证: 是 (insecure=1)")
$([ "$CERT_METHOD" = "acme" ] && echo "域名: ${ACME_DOMAIN}")
$([ "$CERT_METHOD" = "custom" ] && echo "证书: ${CERT_FILE}")
$([ "$CERT_METHOD" = "custom" ] && echo "密钥: ${KEY_FILE}")
限速: $([ "$LIMIT_SPEED" = "yes" ] && echo "${SPEED_UP} Mbps" || echo "不限速")
服务模式: $($SYSTEMD_MODE && echo "systemd (开机自启)" || echo "nohup (手动管理)")
本地监听: ${LISTEN_ADDR}

---------- 分享链接 ----------
${SHARE_LINK}

========================================
工作目录: ${WORKDIR}
停止节点: ${WORKDIR}/stop.sh
卸载节点: ${WORKDIR}/uninstall.sh
日志文件: ${WORKDIR}/hysteria.log
$($SYSTEMD_MODE && echo "查看日志: journalctl -u ${SYSTEMD_SERVICE} -f")
配置文件: ${WORKDIR}/config.yaml
========================================
INFO_EOF

echo ""
echo "=========================================="
echo "  部署完成！Hysteria 2 节点信息"
echo "=========================================="
cat "${WORKDIR}/info.txt"
echo "=========================================="

trap - INT TERM
info "节点已在后台运行，享受低延迟的 Hysteria 2 吧！"