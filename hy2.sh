#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Hysteria 2 一键部署脚本 (已修复证书/防火墙Bug)
# ==========================================

WORKDIR="${WORKDIR:-${HOME}/hysteria2}"
ARCH="$(uname -m)"
READ_TIMEOUT="${READ_TIMEOUT:-30}"
DEFAULT_HOP_INTERVAL="25s"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ----- 颜色 -----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()     { printf "${RED}[x]${NC} %s\n" "$*"; }
section() { printf "\n${CYAN}══ %s ══${NC}\n" "$*"; }

# ----- 检查 root -----
IS_ROOT=false
[ "$(id -u)" -eq 0 ] && IS_ROOT=true
$IS_ROOT || warn "非 root 运行，防火墙/systemd 功能将受限。建议 root 运行。"

# ----- 架构检测 -----
section "检查环境"
case "$ARCH" in
    x86_64|amd64)        HYSTERIA_BIN="hysteria-linux-amd64" ;;
    aarch64|arm64)       HYSTERIA_BIN="hysteria-linux-arm64" ;;
    armv7l|armv6l|armv*) HYSTERIA_BIN="hysteria-linux-arm" ;;
    i386|i686)           HYSTERIA_BIN="hysteria-linux-386" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac

for cmd in curl openssl grep sed tr head; do
    command -v "$cmd" >/dev/null 2>&1 || { err "缺少依赖: $cmd"; exit 1; }
done
info "架构: $ARCH  二进制: $HYSTERIA_BIN"

# ----- 工具函数 -----
stop_services() {
    if [ -f "${WORKDIR}/hysteria.pid" ]; then
        local pid
        pid=$(cat "${WORKDIR}/hysteria.pid" 2>/dev/null || true)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
        rm -f "${WORKDIR}/hysteria.pid"
    fi
}

fail_exit() { err "$1"; stop_services; exit 1; }

trap 'printf "\n"; warn "已中断。"; stop_services; exit 1' INT TERM

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    done
    ip=$(curl -6 -s --connect-timeout 5 "https://api64.ipify.org" 2>/dev/null | tr -d '[:space:]') || true
    [[ "$ip" =~ : ]] && echo "$ip" && return 0
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1) || true
    [ -n "$ip" ] && echo "$ip" && return 0
    return 1
}

port_in_use() {
    local p="$1"
    (echo >/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1 && return 0
    command -v ss >/dev/null 2>&1 && { ss -ulnp 2>/dev/null | grep -q ":$p " && return 0; }
    return 1
}

random_port() {
    local port
    for _ in $(seq 1 200); do
        if [ -r /dev/urandom ]; then
            port=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]') % 50000 + 10000 ))
        else
            port=$(( (RANDOM << 15 | RANDOM) % 50000 + 10000 ))
        fi
        port=$(( port < 10000 ? port + 10000 : port ))
        port=$(( port > 59999 ? 59999 : port ))
        ! port_in_use "$port" && echo "$port" && return 0
    done
    return 1
}

ask() {
    local varname="$1" prompt="$2" default="${3:-}"
    if [ -t 0 ]; then
        [ -n "$default" ] && printf "%s（回车默认 %s）: " "$prompt" "$default" \
                          || printf "%s: " "$prompt"
        local val
        read -t "$READ_TIMEOUT" -r val || true
        echo ""
        [ -z "$val" ] && val="$default"
        printf -v "$varname" '%s' "$val"
    else
        printf -v "$varname" '%s' "$default"
    fi
}

configure_firewall() {
    local raw_range="$1" proto="${2:-udp}"
    $IS_ROOT || { warn "非 root，请手动放行 ${proto}/${raw_range}"; return; }
    
    # [修复Bug] 区分不同防火墙的端口段格式要求
    local ufw_fw_range="${raw_range//:/-}"
    local iptables_range="${raw_range//-/:}"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow proto "$proto" from any to any port "$ufw_fw_range" 2>/dev/null || true
        info "UFW 规则已添加: ${ufw_fw_range}/${proto}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${ufw_fw_range}/${proto}" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "firewalld 规则已添加: ${ufw_fw_range}/${proto}"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$proto" --dport "$iptables_range" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p "$proto" --dport "$iptables_range" -j ACCEPT 2>/dev/null || true
        info "iptables 规则已添加: ${iptables_range}/${proto}"
    else
        warn "未检测到防火墙，请手动放行 ${proto}/${ufw_fw_range}"
    fi
}

# ==========================================
# 1. 端口
# ==========================================
section "1/7 端口配置"

PORT=""
while true; do
    ask PORT "监听端口（回车随机分配 10000-59999）" ""
    if [ -z "$PORT" ]; then
        PORT=$(random_port) || fail_exit "无法分配空闲端口"
        info "随机端口: $PORT"; break
    fi
    [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || {
        warn "无效端口，请输入 1-65535"; PORT=""; continue; }
    port_in_use "$PORT" && { warn "端口 $PORT 已被占用"; PORT=""; continue; }
    info "使用端口: $PORT"; break
done

PUBLIC_IP=$(get_public_ip 2>/dev/null) || PUBLIC_IP=""
[ -n "$PUBLIC_IP" ] && info "公网 IP: $PUBLIC_IP" || warn "无法获取公网 IP，分享链接将用 127.0.0.1 占位"
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="127.0.0.1"

# ==========================================
# 2. 端口跳跃
# ==========================================
section "2/7 端口跳跃"

PORT_HOP_ENABLED="no"
ask _HOP "是否开启端口跳跃 [y/N]" "n"
[[ "${_HOP,,}" =~ ^y ]] && PORT_HOP_ENABLED="yes"

PORT_HOP_RANGE=""
PORT_HOP_INTERVAL="$DEFAULT_HOP_INTERVAL"
LISTEN_ADDR=":${PORT}"
FIREWALL_PORT_RANGE="$PORT"

if [ "$PORT_HOP_ENABLED" = "yes" ]; then
    DEFAULT_PORT_END=$((PORT + 75))
    [ "$DEFAULT_PORT_END" -gt 65535 ] && DEFAULT_PORT_END=65535

    PORT_END=""
    while true; do
        ask PORT_END "跳跃范围结束端口（起始 $PORT）" "$DEFAULT_PORT_END"
        [[ "$PORT_END" =~ ^[0-9]+$ ]] && [ "$PORT_END" -gt "$PORT" ] && [ "$PORT_END" -le 65535 ] && break
        warn "结束端口须大于 $PORT 且 ≤ 65535"
    done

    ask PORT_HOP_INTERVAL "端口跳跃间隔" "$DEFAULT_HOP_INTERVAL"
    PORT_HOP_RANGE="${PORT}-${PORT_END}"
    LISTEN_ADDR=":${PORT_HOP_RANGE}"
    FIREWALL_PORT_RANGE="${PORT}-${PORT_END}"
    info "端口跳跃: $PORT_HOP_RANGE  间隔: $PORT_HOP_INTERVAL"
fi

# ==========================================
# 3. 证书
# ==========================================
section "3/7 TLS 证书"
echo "  1) 自签证书（SNI 伪装为 www.bing.com，客户端需跳过验证）"
echo "  2) ACME 自动申请（域名需已解析到本机，不支持 CDN）"
echo "  3) 自定义证书文件"
echo ""

CERT_METHOD="" CERT_FILE="" KEY_FILE="" SNI="" INSECURE=""
ACME_DOMAIN="" ACME_EMAIL="" ACME_LISTEN=":443"

while true; do
    ask CERT_CHOICE "请选择 [1-3]" "1"
    case "$CERT_CHOICE" in
        1)
            CERT_METHOD="self"; SNI="www.bing.com"; INSECURE="1"
            if [ ! -f "${WORKDIR}/server.crt" ] || [ ! -f "${WORKDIR}/server.key" ]; then
                info "生成自签证书 (CN: $SNI)..."
                # [修复Bug] 增加 subjectAltName，规避 Go 原生证书校验报错
                openssl req -newkey rsa:2048 -nodes -keyout "${WORKDIR}/server.key" \
                    -x509 -days 3650 -out "${WORKDIR}/server.crt" \
                    -subj "/CN=${SNI}" -addext "subjectAltName = DNS:${SNI}" 2>/dev/null || fail_exit "自签证书生成失败"
                chmod 600 "${WORKDIR}/server.key" "${WORKDIR}/server.crt"
            else
                info "复用已有自签证书"
            fi
            CERT_FILE="${WORKDIR}/server.crt"; KEY_FILE="${WORKDIR}/server.key"
            break ;;
        2)
            CERT_METHOD="acme"
            warn "CDN 代理（橙色云朵）会导致 ACME 验证失败，使用前请确认已关闭。"
            while true; do
                ask ACME_DOMAIN "域名（需已解析到本机）" ""
                [[ "$ACME_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]+)?(\.[a-zA-Z]{2,})$ ]] && break
                warn "域名格式不正确"
            done
            while true; do
                ask ACME_EMAIL "邮箱（Let's Encrypt 通知用）" ""
                [[ "$ACME_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
                warn "邮箱格式不正确"
            done
            port_in_use 443 && ACME_LISTEN=":80" || ACME_LISTEN=":443"
            info "ACME 验证端口: ${ACME_LISTEN}"
            SNI="$ACME_DOMAIN"; INSECURE=""
            break ;;
        3)
            CERT_METHOD="custom"
            while true; do
                ask CERT_FILE "证书路径 (fullchain.pem)" ""
                [ -f "$CERT_FILE" ] && break; warn "文件不存在"
            done
            while true; do
                ask KEY_FILE "私钥路径 (privkey.pem)" ""
                [ -f "$KEY_FILE" ] && break; warn "文件不存在"
            done
            SNI=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null \
                  | sed 's/.*CN\s*=\s*//' | head -n1) || SNI=""
            INSECURE=""
            [ -n "$SNI" ] && info "证书 CN: $SNI"
            break ;;
        *) warn "请输入 1、2 或 3" ;;
    esac
done

# ==========================================
# 4. 限速
# ==========================================
section "4/7 带宽限速"
echo "  1) 限速 100 Mbps（上下行）"
echo "  2) 不限速"
echo ""

LIMIT_SPEED="no"; SPEED_UP=""; SPEED_DOWN=""
while true; do
    ask SPEED_CHOICE "请选择 [1-2]" "2"
    case "$SPEED_CHOICE" in
        1) LIMIT_SPEED="yes"; SPEED_UP="100"; SPEED_DOWN="100"; info "限速: 100 Mbps"; break ;;
        2) LIMIT_SPEED="no"; info "不限速"; break ;;
        *) warn "请输入 1 或 2" ;;
    esac
done

# ==========================================
# 5. 下载 Hysteria 2
# ==========================================
section "5/7 获取 Hysteria 2"

if [ ! -x "./hysteria" ] || ! ./hysteria version >/dev/null 2>&1; then
    rm -f hysteria
    info "下载 ${HYSTERIA_BIN}..."
    curl --retry 3 --retry-delay 2 -fsSL --connect-timeout 15 \
        "https://github.com/apernet/hysteria/releases/latest/download/${HYSTERIA_BIN}" \
        -o hysteria || fail_exit "下载失败，请检查网络"
    [ -s hysteria ] || fail_exit "下载文件为空"
    chmod +x hysteria
fi

HYSTERIA_VERSION=$(./hysteria version 2>&1 | head -n1 || echo "未知")
info "版本: $HYSTERIA_VERSION"

if [ "$PORT" -lt 1024 ] && ! $IS_ROOT; then
    command -v setcap >/dev/null 2>&1 \
        && setcap cap_net_bind_service=+ep "${WORKDIR}/hysteria" 2>/dev/null \
        || warn "低位端口需 root 或 setcap，若启动失败请换用 1024+ 端口"
fi

# ==========================================
# 6. 生成配置
# ==========================================
section "6/7 生成配置文件"

PASSWORD=$(openssl rand -hex 16)
info "认证密码: $PASSWORD"

# [修复Bug] ACME 应作为顶层配置块，且不再嵌套于 tls 内
case "$CERT_METHOD" in
    self|custom)
        TLS_BLOCK="tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}" ;;
    acme)
        if [ "$ACME_LISTEN" = ":80" ]; then
            TLS_BLOCK="acme:
  domains:
    - ${ACME_DOMAIN}
  email: ${ACME_EMAIL}
  listen: ${ACME_LISTEN}
  type: http-01"
        else
            TLS_BLOCK="acme:
  domains:
    - ${ACME_DOMAIN}
  email: ${ACME_EMAIL}"
        fi ;;
esac

SPEED_BLOCK=""
[ "$LIMIT_SPEED" = "yes" ] && SPEED_BLOCK="speed:
  up: \"${SPEED_UP} mbps\"
  down: \"${SPEED_DOWN} mbps\""

HOP_BLOCK=""
[ "$PORT_HOP_ENABLED" = "yes" ] && HOP_BLOCK="hopInterval: ${PORT_HOP_INTERVAL}"

cat > "${WORKDIR}/config.yaml" <<EOF
listen: ${LISTEN_ADDR}

${TLS_BLOCK}

auth:
  type: password
  password: ${PASSWORD}

${SPEED_BLOCK}

${HOP_BLOCK}

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
EOF

chmod 600 "${WORKDIR}/config.yaml"
info "配置已写入 ${WORKDIR}/config.yaml"

# ==========================================
# 防火墙
# ==========================================
configure_firewall "$FIREWALL_PORT_RANGE" "udp"

# ==========================================
# 7. 启动服务
# ==========================================
section "7/7 启动服务"

stop_services

SYSTEMD_SERVICE="hysteria2"

if $IS_ROOT && command -v systemctl >/dev/null 2>&1; then
    cat > "/etc/systemd/system/${SYSTEMD_SERVICE}.service" <<EOF
[Unit]
Description=Hysteria 2 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${WORKDIR}
ExecStart=${WORKDIR}/hysteria server --config ${WORKDIR}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$SYSTEMD_SERVICE" 2>/dev/null || fail_exit "systemd 服务启动失败"
    sleep 2
    if systemctl is-active --quiet "$SYSTEMD_SERVICE"; then
        info "systemd 服务运行中"
    else
        journalctl -u "$SYSTEMD_SERVICE" -n 20 --no-pager 2>/dev/null || true
        fail_exit "服务启动失败，请查看上方日志"
    fi
else
    nohup "${WORKDIR}/hysteria" server --config "${WORKDIR}/config.yaml" \
        > "${WORKDIR}/hysteria.log" 2>&1 &
    echo $! > "${WORKDIR}/hysteria.pid"
    sleep 2
    if kill -0 "$(cat "${WORKDIR}/hysteria.pid" 2>/dev/null)" 2>/dev/null; then
        info "Hysteria 2 已在后台启动 (PID: $(cat "${WORKDIR}/hysteria.pid"))"
    else
        tail -20 "${WORKDIR}/hysteria.log" 2>/dev/null || true
        fail_exit "启动失败，请查看日志: ${WORKDIR}/hysteria.log"
    fi
fi

SHARE_PORT="$PORT"

if [ "$CERT_METHOD" = "acme" ]; then
    SNI="$ACME_DOMAIN"
    INSECURE_PARAM=""
else
    INSECURE_PARAM=$([ "$INSECURE" = "1" ] && echo "&insecure=1" || echo "")
fi

MPORT_PARAM=""
[ "$PORT_HOP_ENABLED" = "yes" ] && MPORT_PARAM="&mport=${PORT_HOP_RANGE}"

ENC_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PASSWORD}'))" 2>/dev/null || echo "$PASSWORD")

SHARE_HOST="$PUBLIC_IP"
[[ "$PUBLIC_IP" =~ : ]] && SHARE_HOST="[${PUBLIC_IP}]"

SHARE_LINK="hysteria2://${ENC_PASS}@${SHARE_HOST}:${SHARE_PORT}?sni=${SNI}${MPORT_PARAM}${INSECURE_PARAM}#hy2"

printf "\n"
printf "${CYAN}══════════════════════════════════════════${NC}\n"
printf "${GREEN}        Hysteria 2 部署成功！${NC}\n"
printf "${CYAN}══════════════════════════════════════════${NC}\n"
printf "  服务器  : %s\n" "$PUBLIC_IP"
printf "  端口    : %s\n" "$SHARE_PORT"
[ "$PORT_HOP_ENABLED" = "yes" ] && printf "  跳跃范围: %s\n" "$PORT_HOP_RANGE"
printf "  密码    : %s\n" "$PASSWORD"
printf "  SNI     : %s\n" "$SNI"
printf "  跳过验证: %s\n" "$([ "$INSECURE" = "1" ] && echo '是' || echo '否')"
printf "${CYAN}──────────────────────────────────────────${NC}\n"
printf "  分享链接:\n"
printf "  %s\n" "$SHARE_LINK"
printf "${CYAN}══════════════════════════════════════════${NC}\n"
printf "\n"

if $IS_ROOT && command -v systemctl >/dev/null 2>&1; then
    printf "  管理命令:\n"
    printf "    查看状态: systemctl status %s\n" "$SYSTEMD_SERVICE"
    printf "    查看日志: journalctl -u %s -f\n" "$SYSTEMD_SERVICE"
    printf "    重启服务: systemctl restart %s\n" "$SYSTEMD_SERVICE"
    printf "    停止服务: systemctl stop %s\n" "$SYSTEMD_SERVICE"
else
    printf "  日志文件: %s/hysteria.log\n" "$WORKDIR"
    printf "  停止服务: kill \$(cat %s/hysteria.pid)\n" "$WORKDIR"
fi
printf "\n"
