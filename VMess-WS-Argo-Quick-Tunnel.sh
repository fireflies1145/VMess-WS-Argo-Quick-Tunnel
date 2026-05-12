#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${HOME}/vmess-argo-temp"
ARCH="$(uname -m)"
CF_PROTOCOL="${CF_PROTOCOL:-}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[1/8] 检查环境与架构..."

case "$ARCH" in
    x86_64|amd64)
        XRAY_PACKAGE="Xray-linux-64.zip"
        CLOUDFLARED_BIN="cloudflared-linux-amd64"
        ;;
    aarch64|arm64)
        XRAY_PACKAGE="Xray-linux-arm64-v8a.zip"
        CLOUDFLARED_BIN="cloudflared-linux-arm64"
        ;;
    *)
        echo "不支持的架构: $ARCH"
        exit 1
        ;;
esac

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "错误: 缺少依赖 '$1'"
        echo "Debian/Ubuntu:"
        echo "apt-get update && apt-get install -y curl unzip openssl coreutils grep sed procps"
        exit 1
    }
}

need_cmd curl
need_cmd unzip
need_cmd openssl
need_cmd grep
need_cmd sed
need_cmd base64
need_cmd head
need_cmd tr
need_cmd ps

echo "[2/8] 分配本地端口..."

PORT=""

for i in {1..100}; do
    CANDIDATE_PORT=$(( (RANDOM << 15 | RANDOM) % 50000 + 10000 ))

    if ! (echo >/dev/tcp/127.0.0.1/"$CANDIDATE_PORT") >/dev/null 2>&1; then
        PORT="$CANDIDATE_PORT"
        break
    fi
done

if [ -z "$PORT" ]; then
    echo "无法分配空闲端口"
    exit 1
fi

echo "本地端口: $PORT"

echo "[3/8] 获取并检查 Xray..."

if [ ! -x "./xray" ] || \
   [ ! -f "./geoip.dat" ] || \
   [ ! -f "./geosite.dat" ] || \
   ! ./xray version >/dev/null 2>&1; then

    rm -f xray xray.zip geoip.dat geosite.dat

    curl -fsSL \
    "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_PACKAGE}" \
    -o xray.zip

    unzip -qo xray.zip xray geoip.dat geosite.dat

    chmod +x xray

    rm -f xray.zip
fi

echo "[4/8] 获取并检查 Cloudflared..."

if [ ! -x "./cloudflared" ] || \
   ! ./cloudflared --version >/dev/null 2>&1; then

    rm -f cloudflared

    curl -fsSL \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/${CLOUDFLARED_BIN}" \
    -o cloudflared

    chmod +x cloudflared
fi

echo "[5/8] 生成节点配置..."

UUID="$(./xray uuid)"
WSPATH="/$(openssl rand -hex 8)"

cat > config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0,
            "security": "auto"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WSPATH}"
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
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

fail_exit() {
    local msg="$1"
    local xray_pid=""
    local cf_pid=""

    echo
    echo "错误: $msg"
    echo

    if [ -f "${WORKDIR}/xray.pid" ]; then
        xray_pid="$(cat "${WORKDIR}/xray.pid" 2>/dev/null || true)"

        if [ -n "$xray_pid" ] && kill -0 "$xray_pid" 2>/dev/null; then
            kill "$xray_pid" 2>/dev/null || true
        fi

        rm -f "${WORKDIR}/xray.pid"
    fi

    if [ -f "${WORKDIR}/cloudflared.pid" ]; then
        cf_pid="$(cat "${WORKDIR}/cloudflared.pid" 2>/dev/null || true)"

        if [ -n "$cf_pid" ] && kill -0 "$cf_pid" 2>/dev/null; then
            kill "$cf_pid" 2>/dev/null || true
        fi

        rm -f "${WORKDIR}/cloudflared.pid"
    fi

    exit 1
}

cleanup_pid() {
    local pid_file="$1"
    local expected="$2"

    [ -f "$pid_file" ] || return 0

    local old_pid
    old_pid="$(cat "$pid_file" 2>/dev/null || true)"

    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        if ps -p "$old_pid" -o args= 2>/dev/null | grep -q "$expected"; then
            kill "$old_pid" 2>/dev/null || true
            sleep 1
        fi
    fi

    rm -f "$pid_file"
}

echo "[6/8] 启动服务..."

cleanup_pid "${WORKDIR}/xray.pid" "${WORKDIR}/xray"
cleanup_pid "${WORKDIR}/cloudflared.pid" "${WORKDIR}/cloudflared"

: > "${WORKDIR}/xray.log"
: > "${WORKDIR}/cloudflared.log"

nohup "${WORKDIR}/xray" run \
-config "${WORKDIR}/config.json" \
> "${WORKDIR}/xray.log" 2>&1 &

echo $! > "${WORKDIR}/xray.pid"

XRAY_PID="$(cat "${WORKDIR}/xray.pid")"

for i in {1..20}; do

    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        cat "${WORKDIR}/xray.log"
        fail_exit "Xray 启动失败"
    fi

    if (echo >/dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1; then
        break
    fi

    if [ "$i" -eq 20 ]; then
        cat "${WORKDIR}/xray.log"
        fail_exit "Xray 端口等待超时"
    fi

    sleep 0.5
done

if [ -n "$CF_PROTOCOL" ]; then
    nohup "${WORKDIR}/cloudflared" tunnel \
    --protocol "${CF_PROTOCOL}" \
    --url "http://127.0.0.1:${PORT}" \
    > "${WORKDIR}/cloudflared.log" 2>&1 &
else
    nohup "${WORKDIR}/cloudflared" tunnel \
    --url "http://127.0.0.1:${PORT}" \
    > "${WORKDIR}/cloudflared.log" 2>&1 &
fi

echo $! > "${WORKDIR}/cloudflared.pid"

echo "[7/8] 等待 Cloudflare 分配域名..."

ARGO_URL=""

for i in {1..60}; do

    ARGO_URL="$(
        grep -oE \
        'https://[-a-zA-Z0-9.]+\.trycloudflare\.com' \
        "${WORKDIR}/cloudflared.log" \
        | head -n 1 || true
    )"

    if [ -n "$ARGO_URL" ]; then
        break
    fi

    CF_PID="$(cat "${WORKDIR}/cloudflared.pid" 2>/dev/null || true)"

    if [ -z "$CF_PID" ] || ! kill -0 "$CF_PID" 2>/dev/null; then
        cat "${WORKDIR}/cloudflared.log"
        fail_exit "Cloudflared 已退出"
    fi

    sleep 1
done

if [ -z "$ARGO_URL" ]; then
    cat "${WORKDIR}/cloudflared.log"
    fail_exit "获取 Argo 域名失败"
fi

DOMAIN="$(echo "$ARGO_URL" | sed 's#https://##')"

echo "[8/8] 生成 VMess 链接..."

VMESS_JSON="$(cat <<EOF
{
  "v":"2",
  "ps":"Argo-${DOMAIN:0:8}",
  "add":"${DOMAIN}",
  "port":"443",
  "id":"${UUID}",
  "aid":"0",
  "scy":"auto",
  "net":"ws",
  "type":"none",
  "host":"${DOMAIN}",
  "path":"${WSPATH}",
  "tls":"tls",
  "sni":"${DOMAIN}"
}
EOF
)"

VMESS_LINK="vmess://$(printf '%s' "$VMESS_JSON" | base64 | tr -d '\r\n')"

cat > stop.sh <<EOF
#!/usr/bin/env bash

WORKDIR="${WORKDIR}"

stop_one() {
    local pid_file="\$1"
    local expected="\$2"

    [ -f "\$pid_file" ] || return 0

    local pid
    pid="\$(cat "\$pid_file" 2>/dev/null || true)"

    if [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then
        if ps -p "\$pid" -o args= 2>/dev/null | grep -q "\$expected"; then
            kill "\$pid" 2>/dev/null || true
            sleep 1
        fi
    fi

    rm -f "\$pid_file"
}

stop_one "\${WORKDIR}/xray.pid" "\${WORKDIR}/xray"
stop_one "\${WORKDIR}/cloudflared.pid" "\${WORKDIR}/cloudflared"

echo "节点已停止"
EOF

chmod +x stop.sh

cat > uninstall.sh <<EOF
#!/usr/bin/env bash

"${WORKDIR}/stop.sh" 2>/dev/null || true

rm -rf "${WORKDIR}"

echo "节点已停止，工作目录已删除"
EOF

chmod +x uninstall.sh

CF_PROTOCOL_DISPLAY="${CF_PROTOCOL:-auto}"

cat > info.txt <<EOF
Protocol: VMess
Address: ${DOMAIN}
Port: 443
UUID: ${UUID}
AlterId: 0
Security: auto
Network: ws
Type: none
Host: ${DOMAIN}
SNI: ${DOMAIN}
Path: ${WSPATH}
TLS: tls
Local Port: ${PORT}
Cloudflared Protocol: ${CF_PROTOCOL_DISPLAY}

${VMESS_LINK}
EOF

echo
echo "=========================================="
echo "部署完成"
echo "=========================================="

cat info.txt

echo "=========================================="
echo "工作目录: ${WORKDIR}"
echo "停止节点: ${WORKDIR}/stop.sh"
echo "卸载节点: ${WORKDIR}/uninstall.sh"
echo "Xray 日志: ${WORKDIR}/xray.log"
echo "Cloudflared 日志: ${WORKDIR}/cloudflared.log"
echo "=========================================="
