#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Hysteria 2 一键部署脚本 (Final)
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

# ----- 权限检查 -----
IS_ROOT=false
[ "$(id -u)" -eq 0 ] && IS_ROOT=true
$IS_ROOT || warn "非 root 运行，防火墙 / systemd 功能将受限。建议 root 运行。"

# ----- 依赖检查 -----
section "检查环境"

case "$ARCH" in
    x86_64|amd64)        HYSTERIA_BIN="hysteria-linux-amd64" ;;
    aarch64|arm64)       HYSTERIA_BIN="hysteria-linux-arm64" ;;
    armv7l|armv6l|armv*) HYSTERIA_BIN="hysteria-linux-arm" ;;
    i386|i686)           HYSTERIA_BIN="hysteria-linux-386" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac

for cmd in curl openssl grep sed tr head; do
    command -v "$cmd" >/dev/null 2>&1 || { err "缺少依赖: $cmd"; echo "请运行: apt update && apt install -y curl openssl grep sed coreutils"; exit 1; }
done
info "架构: $ARCH  二进制: $HYSTERIA_BIN"

# ----- 基础函数 -----
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

# ----- 公网 IP（双栈）-----
get_public_ip() {
    local ip=""
    # IPv4
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    done
    # IPv6
    ip=$(curl -6 -s --connect-timeout 5 "https://api64.ipify.org" 2>/dev/null | tr -d '[:space:]') || true
    [[ "$ip" =~ : ]] && echo "$ip" && return 0
    # 本地网卡
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1) || true
    [ -n "$ip" ] && echo "$ip" && return 0
    ip=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80' | head -n1) || true
    [ -n "$ip" ] && echo "$ip" && return 0
    return 1
}

# ----- 端口检测（仅 UDP，因为 Hysteria 2 只用 UDP）-----
port_in_use() {
    local p="$1"
    # 用 ss 检测 UDP
    if command -v ss >/dev/null 2>&1; then
        ss -ulnp 2>/dev/null | grep -qE "[[:space:]]${p}[[:space:]]" && return 0
    fi
    # lsof 回退
    if command -v lsof >/dev/null 2>&1; then
        lsof -iUDP:"$p" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# ----- 随机端口 -----
random_port() {
    local port
    for _ in $(seq 1 200); do
        if [ -r /dev/urandom ]; then
            port=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]') % 50000 + 10000 ))
        else
            port=$(( (RANDOM << 15 | RANDOM) % 50000 + 10000 ))
        fi
        port=$(( port > 59999 ? 59999 : port ))
        ! port_in_use "$port" && echo "$port" && return 0
    done
    return 1
}

# ----- 统一交互函数 -----
ask() {
    local varname="$1" prompt="$2" default="${3:-}"
    local val=""
    if [ -t 0 ]; then
        [ -n "$default" ] && printf "%s（回车默认 %s）: " "$prompt" "$default" \
                          || printf "%s: " "$prompt"
        read -t "$READ_TIMEOUT" -r val || true
        echo ""
        [ -z "$val" ] && val="$default"
    else
        val="$default"
    fi
    printf -v "$varname" '%s' "$val"
}

# ----- 防火墙（修复：统一端口范围格式）-----
configure_firewall() {
    local raw_range="$1" proto="${2:-udp}"

    if ! $IS_ROOT; then
        warn "非 root，请手动放行 UDP 端口: ${raw_range}"
        return
    fi

    # UFW 和 iptables 用冒号（10000:10075），firewalld 用短横线（10000-10075）
    local colon_range="${raw_range//-/:}"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow proto "$proto" from any to any port "$colon_range" 2>/dev/null || true
        info "UFW 规则已添加: ${colon_range}/${proto}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${raw_range}/${proto}" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "firewalld 规则已添加: ${raw_range}/${proto}"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$proto" --dport "$colon_range" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p "$proto" --dport "$colon_range" -j ACCEPT 2>/dev/null || true
        info "iptables 规则已添加: ${colon_range}/${proto}"
    else
        warn "未检测到防火墙，请手动放行 UDP 端口: ${raw_range}"
    fi
}

# ==========================================
# 1/7 端口配置
# ==========================================
section "1/7 端口配置"

PORT=""
while true; do
    ask PORT "监听端口（回车随机分配 10000-59999）" ""
    if [ -z "$PORT" ]; then
        PORT=$(random_port) || fail_exit "无法分配空闲端口"
        info "随机端口: $PORT"
        break
    fi
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        warn "无效端口，请输入 1-65535 之间的数字"
        continue
    fi
    if port_in_use "$PORT"; then
        warn "端口 $PORT 已被占用（UDP），请更换"
        continue
    fi
    info "使用端口: $PORT"
    break
done

# ----- 获取公网 IP -----
PUBLIC_IP=$(get_public_ip 2>/dev/null) || PUBLIC_IP=""
if [ -n "$PUBLIC_IP" ]; then
    info "公网 IP: $PUBLIC_IP"
else
    warn "无法获取公网 IP，分享链接将用 127.0.0.1 占位，请部署后手动修改"
    PUBLIC_IP="127.0.0.1"
fi

# ==========================================
# 2/7 端口跳跃（默认关闭）
# ==========================================
section "2/7 端口跳跃"

PORT_HOP_ENABLED="no"
ask HOP_CHOICE "是否开启端口跳跃 [y/N]" "n"
[[ "${HOP_CHOICE,,}" =~ ^y(es)?$ ]] && PORT_HOP_ENABLED="yes"

PORT_HOP_RANGE=""
PORT_HOP_INTERVAL="$DEFAULT_HOP_INTERVAL"
LISTEN_ADDR=":${PORT}"
FIREWALL_PORT_RANGE="$PORT"

if [ "$PORT_HOP_ENABLED" = "yes" ]; then
    DEFAULT_PORT_END=$((PORT + 75))
    [ "$DEFAULT_PORT_END" -gt 65535 ] && DEFAULT_PORT_END=65535

    PORT_END=""
    while true; do
        ask PORT_END "跳跃范围结束端口（起始 ${PORT}）" "$DEFAULT_PORT_END"
        if [[ "$PORT_END" =~ ^[0-9]+$ ]] && [ "$PORT_END" -gt "$PORT" ] && [ "$PORT_END" -le 65535 ]; then
            break
        fi
        warn "结束端口须大于 ${PORT} 且不超过 65535"
    done

    ask PORT_HOP_INTERVAL "端口跳跃间隔" "$DEFAULT_HOP_INTERVAL"
    PORT_HOP_RANGE="${PORT}-${PORT_END}"
    LISTEN_ADDR=":${PORT_HOP_RANGE}"
    FIREWALL_PORT_RANGE="${PORT}-${PORT_END}"
    info "端口跳跃: ${PORT_HOP_RANGE}  间隔: ${PORT_HOP_INTERVAL}"
fi

# ==========================================
# 3/7 TLS 证书
# ==========================================
section "3/7 TLS 证书"

echo "  1) 自签证书（SNI 伪装为 www.bing.com，客户端需跳过验证）"
echo "  2) ACME 自动申请（域名需已解析到本机，不支持 CDN 代理）"
echo "  3) 自定义证书文件"
echo ""

CERT_METHOD="" CERT_FILE="" KEY_FILE="" SNI="" INSECURE=""
ACME_DOMAIN="" ACME_EMAIL="" ACME_LISTEN=":443"

while true; do
    ask CERT_CHOICE "请选择 [1-3]" "1"
    case "$CERT_CHOICE" in
        1)
            CERT_METHOD="self"
            SNI="www.bing.com"
            INSECURE="1"
            if [ ! -f "${WORKDIR}/server.crt" ] || [ ! -f "${WORKDIR}/server.key" ]; then
                info "正在生成自签证书 (CN: ${SNI})..."
                openssl req -newkey rsa:2048 -nodes -keyout "${WORKDIR}/server.key" \
                    -x509 -days 3650 -out "${WORKDIR}/server.crt" \
                    -subj "/CN=${SNI}" -addext "subjectAltName = DNS:${SNI}" \
                    2>/dev/null || fail_exit "自签证书生成失败"
                chmod 600 "${WORKDIR}/server.key" "${WORKDIR}/server.crt"
                info "自签证书已生成"
            else
                info "复用已有自签证书"
            fi
            CERT_FILE="${WORKDIR}/server.crt"
            KEY_FILE="${WORKDIR}/server.key"
            break
            ;;
        2)
            CERT_METHOD="acme"
            warn "⚠ 注意：CDN 代理（如 Cloudflare 橙色云朵）会导致 ACME 验证失败！"
            warn "   使用前请确认域名已关闭 CDN 代理，且已解析到本服务器。"

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

            # ACME 验证端口：优先 443，否则 80
            if port_in_use 443; then
                ACME_LISTEN=":80"
            else
                ACME_LISTEN=":443"
            fi
            info "ACME 验证端口: ${ACME_LISTEN}"
            info "证书申请可能需要 1-2 分钟，启动后请耐心等待。"

            SNI="$ACME_DOMAIN"
            INSECURE=""
            break
            ;;
        3)
            CERT_METHOD="custom"
            while true; do
                ask CERT_FILE "证书文件路径（fullchain.pem / .crt）" ""
                [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ] && break
                warn "文件不存在，请重新输入"
            done
            while true; do
                ask KEY_FILE "私钥文件路径（privkey.pem / .key）" ""
                [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] && break
                warn "文件不存在，请重新输入"
            done
            # 提取 CN
            SNI=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null \
                  | sed 's/.*CN\s*=\s*//' | head -n1) || SNI=""
            [ -n "$SNI" ] && info "证书 CN: $SNI"
            INSECURE=""
            break
            ;;
        *)
            warn "请输入 1、2 或 3"
            ;;
    esac
done

# ==========================================
# 4/7 带宽限速
# ==========================================
section "4/7 带宽限速"

echo "  1) 限速 100 Mbps（上下行）"
echo "  2) 不限速"
echo ""

LIMIT_SPEED="no"
SPEED_UP=""
SPEED_DOWN=""

while true; do
    ask SPEED_CHOICE "请选择 [1-2]" "2"
    case "$SPEED_CHOICE" in
        1) LIMIT_SPEED="yes"; SPEED_UP="100"; SPEED_DOWN="100"; info "限速: 100 Mbps"; break ;;
        2) LIMIT_SPEED="no"; info "不限速"; break ;;
        *) warn "请输入 1 或 2" ;;
    esac
done

# ==========================================
# 5/7 下载 Hysteria 2
# ==========================================
section "5/7 获取 Hysteria 2"

if [ ! -x "./hysteria" ] || ! ./hysteria version >/dev/null 2>&1; then
    rm -f hysteria
    info "正在下载 ${HYSTERIA_BIN}..."
    curl --retry 3 --retry-delay 2 -fsSL --connect-timeout 15 \
        "https://github.com/apernet/hysteria/releases/latest/download/${HYSTERIA_BIN}" \
        -o hysteria || fail_exit "下载失败，请检查网络连接"
    [ -s hysteria ] || fail_exit "下载文件为空"
    chmod +x hysteria
fi

HYSTERIA_VERSION=$(./hysteria version 2>&1 | head -n1 || echo "未知")
info "Hysteria 版本: ${HYSTERIA_VERSION}"

# 低位端口 setcap
if [ "$PORT" -lt 1024 ] && ! $IS_ROOT; then
    if command -v setcap >/dev/null 2>&1; then
        setcap cap_net_bind_service=+ep "${WORKDIR}/hysteria" 2>/dev/null \
            || warn "setcap 失败，低位端口可能无法绑定"
    else
        warn "非 root + 低位端口需要 setcap（apt install libcap2-bin），或改用 1024+ 端口"
    fi
fi

# ==========================================
# 6/7 生成配置
# ==========================================
section "6/7 生成配置文件"

PASSWORD=$(openssl rand -hex 16)
info "认证密码: ${PASSWORD}"

# 构建 TLS 块
case "$CERT_METHOD" in
    self|custom)
        TLS_BLOCK=$(cat <<EOF
tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}
EOF
) ;;
    acme)
        if [ "$ACME_LISTEN" = ":80" ]; then
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
        ;;
esac

# 构建带宽块（修复：bandwidth 而非 speed）
BANDWIDTH_BLOCK=""
if [ "$LIMIT_SPEED" = "yes" ]; then
    BANDWIDTH_BLOCK=$(cat <<EOF
bandwidth:
  up: ${SPEED_UP} mbps
  down: ${SPEED_DOWN} mbps
EOF
)
fi

cat > "${WORKDIR}/config.yaml" <<YAML_EOF
# Hysteria 2 配置文件

listen: ${LISTEN_ADDR}

${TLS_BLOCK}

auth:
  type: password
  password: ${PASSWORD}

${BANDWIDTH_BLOCK}

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
info "配置文件已写入: ${WORKDIR}/config.yaml"

# ----- 防火墙 -----
configure_firewall "$FIREWALL_PORT_RANGE" "udp"

# ==========================================
# 7/7 启动服务
# ==========================================
section "7/7 启动服务"

stop_services

SYSTEMD_SERVICE="hysteria2"
SYSTEMD_MODE=false

if $IS_ROOT && command -v systemctl >/dev/null 2>&1; then
    cat > "/etc/systemd/system/${SYSTEMD_SERVICE}.service" <<SERVICE_EOF
[Unit]
Description=Hysteria 2 Proxy Service
After=network.target network-online.target
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
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable --now "$SYSTEMD_SERVICE" 2>/dev/null || fail_exit "systemd 服务启动失败"
    sleep 2

    if systemctl is-active --quiet "$SYSTEMD_SERVICE"; then
        SYSTEMD_MODE=true
        info "systemd 服务运行中"
    else
        journalctl -u "$SYSTEMD_SERVICE" -n 20 --no-pager 2>/dev/null || true
        fail_exit "服务启动失败，请查看上方日志"
    fi
else
    # nohup 模式
    : > "${WORKDIR}/hysteria.log"
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

# ACME 模式额外提示
if [ "$CERT_METHOD" = "acme" ]; then
    warn "ACME 证书正在申请中，如果客户端连不上，请等待 1-2 分钟后重试。"
    warn "可通过日志查看进度: $($SYSTEMD_MODE && echo "journalctl -u ${SYSTEMD_SERVICE} -f" || echo "tail -f ${WORKDIR}/hysteria.log")"
fi

# ==========================================
# 生成分享链接
# ==========================================
SHARE_PORT="$PORT"

# SNI
if [ "$CERT_METHOD" = "acme" ]; then
    SHARE_SNI="$ACME_DOMAIN"
else
    SHARE_SNI="$SNI"
fi

# insecure 参数
INSECURE_PARAM=""
[ "$INSECURE" = "1" ] && INSECURE_PARAM="&insecure=1"

# 端口跳跃参数（修复：hop_interval 而非 mportHopInt）
MPORT_PARAM=""
if [ "$PORT_HOP_ENABLED" = "yes" ]; then
    # 去掉间隔中的 "s"（如 "25s" → "25"）
    HOP_INT_NUM="${PORT_HOP_INTERVAL//s/}"
    MPORT_PARAM="&mport=${PORT_HOP_RANGE}&hop_interval=${HOP_INT_NUM}"
fi

# 密码不需要 URL 编码（纯 hex，无特殊字符）
SHARE_HOST="$PUBLIC_IP"
[[ "$PUBLIC_IP" =~ : ]] && [[ ! "$PUBLIC_IP" =~ \[ ]] && SHARE_HOST="[${PUBLIC_IP}]"

SHARE_LINK="hysteria2://${PASSWORD}@${SHARE_HOST}:${SHARE_PORT}?sni=${SHARE_SNI}${MPORT_PARAM}${INSECURE_PARAM}#hy2"

# ==========================================
# 生成管理脚本
# ==========================================
cat > "${WORKDIR}/stop.sh" <<SCRIPT_EOF
#!/usr/bin/env bash
WORKDIR="\${WORKDIR:-${WORKDIR}}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE}"

if systemctl is-active --quiet "\${SYSTEMD_SERVICE}" 2>/dev/null; then
    systemctl stop "\${SYSTEMD_SERVICE}" 2>/dev/null || true
    echo "已通过 systemctl 停止 \${SYSTEMD_SERVICE}"
elif [ -f "\${WORKDIR}/hysteria.pid" ]; then
    pid=\$(cat "\${WORKDIR}/hysteria.pid" 2>/dev/null || true)
    [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null && kill "\$pid" 2>/dev/null
    rm -f "\${WORKDIR}/hysteria.pid"
    echo "Hysteria 2 (nohup) 已停止"
else
    echo "未找到运行中的进程"
fi
SCRIPT_EOF
chmod +x "${WORKDIR}/stop.sh"

cat > "${WORKDIR}/uninstall.sh" <<SCRIPT_EOF
#!/usr/bin/env bash
WORKDIR="\${WORKDIR:-${WORKDIR}}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE}"

# 停止服务
if [ -f "\${WORKDIR}/stop.sh" ]; then
    bash "\${WORKDIR}/stop.sh" 2>/dev/null || true
fi

# 删除 systemd 服务
if systemctl list-unit-files "\${SYSTEMD_SERVICE}.service" >/dev/null 2>&1; then
    systemctl disable "\${SYSTEMD_SERVICE}" 2>/dev/null || true
    rm -f "/etc/systemd/system/\${SYSTEMD_SERVICE}.service"
    systemctl daemon-reload 2>/dev/null || true
fi

# 删除工作目录
rm -rf "\${WORKDIR}"
echo "Hysteria 2 已完全卸载"
SCRIPT_EOF
chmod +x "${WORKDIR}/uninstall.sh"

# ==========================================
# 输出信息
# ==========================================
cat > "${WORKDIR}/info.txt" <<INFO_EOF
========================================
Hysteria 2 节点信息
========================================
地址: ${SHARE_HOST}
端口: ${SHARE_PORT}
端口跳跃: ${PORT_HOP_ENABLED}
$([ "$PORT_HOP_ENABLED" = "yes" ] && echo "跳跃范围: ${PORT_HOP_RANGE}")
$([ "$PORT_HOP_ENABLED" = "yes" ] && echo "跳跃间隔: ${PORT_HOP_INTERVAL}")
密码: ${PASSWORD}
SNI: ${SHARE_SNI}
跳过证书验证: $([ "$INSECURE" = "1" ] && echo "是" || echo "否")
证书方式: ${CERT_METHOD}
$([ "$CERT_METHOD" = "acme" ] && echo "ACME 域名: ${ACME_DOMAIN}")
$([ "$CERT_METHOD" = "custom" ] && echo "证书: ${CERT_FILE}")
$([ "$CERT_METHOD" = "custom" ] && echo "密钥: ${KEY_FILE}")
限速: $([ "$LIMIT_SPEED" = "yes" ] && echo "${SPEED_UP} Mbps" || echo "不限速")
服务模式: $($SYSTEMD_MODE && echo "systemd (开机自启)" || echo "nohup (手动管理)")

---------- 分享链接 ----------
${SHARE_LINK}

========================================
管理命令:
  查看状态: $($SYSTEMD_MODE && echo "systemctl status ${SYSTEMD_SERVICE}" || echo "ps aux | grep hysteria")
  查看日志: $($SYSTEMD_MODE && echo "journalctl -u ${SYSTEMD_SERVICE} -f" || echo "tail -f ${WORKDIR}/hysteria.log")
  停止节点: ${WORKDIR}/stop.sh
  卸载节点: ${WORKDIR}/uninstall.sh
  配置文件: ${WORKDIR}/config.yaml
========================================
INFO_EOF

echo ""
printf "${CYAN}══════════════════════════════════════════${NC}\n"
printf "${GREEN}        Hysteria 2 部署成功！${NC}\n"
printf "${CYAN}══════════════════════════════════════════${NC}\n"
printf "  地址    : %s\n" "$SHARE_HOST"
printf "  端口    : %s\n" "$SHARE_PORT"
[ "$PORT_HOP_ENABLED" = "yes" ] && printf "  跳跃范围: %s\n" "$PORT_HOP_RANGE"
printf "  密码    : %s\n" "$PASSWORD"
printf "  SNI     : %s\n" "$SHARE_SNI"
printf "  跳过验证: %s\n" "$([ "$INSECURE" = "1" ] && echo '是' || echo '否')"
printf "${CYAN}──────────────────────────────────────────${NC}\n"
printf "  分享链接:\n"
printf "  %s\n" "$SHARE_LINK"
printf "${CYAN}──────────────────────────────────────────${NC}\n"

if $SYSTEMD_MODE; then
    printf "  状态: systemctl status %s\n" "$SYSTEMD_SERVICE"
    printf "  日志: journalctl -u %s -f\n" "$SYSTEMD_SERVICE"
    printf "  停止: %s/stop.sh\n" "$WORKDIR"
else
    printf "  日志: tail -f %s/hysteria.log\n" "$WORKDIR"
    printf "  停止: %s/stop.sh\n" "$WORKDIR"
fi
printf "  卸载: %s/uninstall.sh\n" "$WORKDIR"
printf "${CYAN}══════════════════════════════════════════${NC}\n"

if [ "$CERT_METHOD" = "acme" ]; then
    echo ""
    warn "ACME 证书正在申请中（最多 2 分钟），请稍等再连接。"
    warn "如果长时间无法连接，请检查域名是否已关闭 CDN 代理。"
fi

echo ""
info "信息已保存至: ${WORKDIR}/info.txt"
# 将信息追加到全局记录文件
{
    echo "--- Hysteria 2 (独立部署) ---"
    cat "${WORKDIR}/info.txt"
    echo ""
} >> "${HOME}/all_nodes_info.txt"

# 安装快捷管理工具
printf "\033[0;32m[+] 正在安装快捷管理工具...\033[0m\n"
curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/jb.sh -o ${HOME}/jb.sh
chmod +x ${HOME}/jb.sh
if [ -w "/usr/local/bin" ]; then
    sudo ln -sf ${HOME}/jb.sh /usr/local/bin/jb
    printf "\033[0;32m[+] 快捷命令 'jb' 安装成功！输入 'jb' 即可管理节点。\033[0m\n"
else
    echo "alias jb='bash ${HOME}/jb.sh'" >> ${HOME}/.bashrc
    printf "\033[0;32m[+] 快捷命令已添加至别名，请执行 'source ~/.bashrc' 后输入 'jb' 管理节点。\033[0m\n"
fi
echo "=========================================="
