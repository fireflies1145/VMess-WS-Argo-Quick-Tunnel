#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# VMess + WS + Argo Quick Tunnel
# ==========================================

WORKDIR="${WORKDIR:-${HOME}/vmess-argo-temp}"
ARCH="$(uname -m)"
CF_PROTOCOL="${CF_PROTOCOL:-}"
CF_PREFERRED_DOMAIN="${CF_PREFERRED_DOMAIN:-yg1.ygkkk.dpdns.org}"
# read 超时（秒），可通过环境变量覆盖
READ_TIMEOUT="${READ_TIMEOUT:-30}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ----- 基础清理函数 -----
stop_services() {
    local xray_pid=""
    local cf_pid=""

    if [ -f "${WORKDIR}/xray.pid" ]; then
        xray_pid=$(cat "${WORKDIR}/xray.pid" 2>/dev/null || true)
        if [ -n "$xray_pid" ] && kill -0 "$xray_pid" 2>/dev/null; then
            if ps -p "$xray_pid" -o args= 2>/dev/null | grep -qF "${WORKDIR}/xray"; then
                kill "$xray_pid" 2>/dev/null || true
            fi
        fi
        rm -f "${WORKDIR}/xray.pid"
    fi

    if [ -f "${WORKDIR}/cloudflared.pid" ]; then
        cf_pid=$(cat "${WORKDIR}/cloudflared.pid" 2>/dev/null || true)
        if [ -n "$cf_pid" ] && kill -0 "$cf_pid" 2>/dev/null; then
            if ps -p "$cf_pid" -o args= 2>/dev/null | grep -qF "${WORKDIR}/cloudflared"; then
                kill "$cf_pid" 2>/dev/null || true
            fi
        fi
        rm -f "${WORKDIR}/cloudflared.pid"
    fi
}

# ----- 信号与错误处理 -----
cleanup_on_interrupt() {
    printf '\n[!] 收到中断信号，正在清理残留进程并退出...\n'
    stop_services
    exit 1
}

fail_exit() {
    local msg="$1"
    printf '\n[x] 错误: %s\n' "$msg"
    printf '正在清理环境...\n'
    stop_services
    exit 1
}

trap cleanup_on_interrupt INT TERM

# ----- 依赖检查 -----
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
    armv7l|armv6l)
        XRAY_PACKAGE="Xray-linux-arm32-v7a.zip"
        CLOUDFLARED_BIN="cloudflared-linux-arm"
        ;;
    *)
        printf '不支持的架构: %s\n' "$ARCH"
        echo "支持的架构: x86_64, aarch64, armv7l, armv6l"
        exit 1
        ;;
esac

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '错误: 缺少依赖 "%s"\n' "$1"
        echo "请执行: apt-get update && apt-get install -y curl unzip openssl coreutils grep sed"
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

# ----- 端口检测工具 -----
# 优先使用 bash 内置 /dev/tcp，否则回退到 ss 命令
check_port_in_use() {
    local port="$1"
    # 尝试 bash 内置方式
    if (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
        return 0
    fi

    # 如果内置方式不被支持（比如 dash），尝试 ss
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -i :"$port" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# ----- 端口分配 -----
echo "[2/8] 分配本地端口..."

random_port() {
    local port
    for i in $(seq 1 200); do
        # 使用 /dev/urandom 生成更均匀的随机数（如果有）
        if [ -r /dev/urandom ]; then
            port=$(( ( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 50000) + 10000 ))
        else
            port=$(( (RANDOM << 15 | RANDOM) % 50000 + 10000 ))
        fi
        if ! check_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

PORT=""
USER_PORT=""

while true; do
    if [ -t 0 ]; then
        printf '请输入监听端口 (10000-59999，直接回车或%d秒无操作将自动随机): ' "$READ_TIMEOUT"
        read -t "$READ_TIMEOUT" -r USER_PORT || true
    else
        echo "非交互环境，自动分配随机端口..."
    fi

    if [ -z "$USER_PORT" ]; then
        echo "" # 补换行
        PORT=$(random_port) || fail_exit "无法自动分配空闲端口"
        printf '已分配随机端口: %s\n' "$PORT"
        break
    fi

    if ! [[ "$USER_PORT" =~ ^[0-9]+$ ]] || [ "$USER_PORT" -lt 10000 ] || [ "$USER_PORT" -gt 59999 ]; then
        echo "输入无效，请输入 10000-59999 之间的数字。"
        USER_PORT=""
        continue
    fi

    if check_port_in_use "$USER_PORT"; then
        printf '端口 %s 已被占用，请更换。\n' "$USER_PORT"
        USER_PORT=""
        continue
    fi

    PORT="$USER_PORT"
    printf '使用指定端口: %s\n' "$PORT"
    break
done

# ----- 下载 Xray -----
echo "[3/8] 获取 Xray..."

download_file() {
    local url="$1"
    local output="$2"
    local desc="$3"
    curl --retry 3 --retry-delay 2 -fsSL --connect-timeout 15 "$url" -o "$output" || {
        printf '下载失败: %s\n  URL: %s\n' "$desc" "$url"
        return 1
    }
    # 确保文件非空
    if [ ! -s "$output" ]; then
        printf '下载文件为空: %s\n' "$desc"
        return 1
    fi
    return 0
}

if [ ! -x "./xray" ] || [ ! -f "./geoip.dat" ] || [ ! -f "./geosite.dat" ] || ! ./xray version >/dev/null 2>&1; then
    rm -f xray xray.zip geoip.dat geosite.dat
    download_file \
        "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_PACKAGE}" \
        xray.zip \
        "Xray-core" || fail_exit "Xray 下载失败"

    unzip -qo xray.zip xray geoip.dat geosite.dat
    chmod +x xray
    rm -f xray.zip
fi

# ----- 下载 Cloudflared -----
echo "[4/8] 获取 Cloudflared..."

if [ ! -x "./cloudflared" ] || ! ./cloudflared --version >/dev/null 2>&1; then
    rm -f cloudflared
    download_file \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/${CLOUDFLARED_BIN}" \
        cloudflared \
        "cloudflared" || fail_exit "Cloudflared 下载失败"
    chmod +x cloudflared
fi

# ----- 生成配置 -----
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

# ----- 启动服务 -----
echo "[6/8] 启动服务..."

stop_services

: > "${WORKDIR}/xray.log"
: > "${WORKDIR}/cloudflared.log"

nohup "${WORKDIR}/xray" run -config "${WORKDIR}/config.json" \
    > "${WORKDIR}/xray.log" 2>&1 &
echo $! > "${WORKDIR}/xray.pid"

XRAY_PID=$(cat "${WORKDIR}/xray.pid")

# 等待 Xray 就绪（渐进式轮询）
for i in $(seq 1 30); do
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        cat "${WORKDIR}/xray.log"
        fail_exit "Xray 启动失败"
    fi
    if check_port_in_use "$PORT"; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        cat "${WORKDIR}/xray.log"
        fail_exit "Xray 端口等待超时"
    fi
    sleep 0.3
done

# 启动 Cloudflared
if [ -n "$CF_PROTOCOL" ]; then
    nohup "${WORKDIR}/cloudflared" tunnel --protocol "${CF_PROTOCOL}" \
        --url "http://127.0.0.1:${PORT}" \
        > "${WORKDIR}/cloudflared.log" 2>&1 &
else
    nohup "${WORKDIR}/cloudflared" tunnel \
        --url "http://127.0.0.1:${PORT}" \
        > "${WORKDIR}/cloudflared.log" 2>&1 &
fi
echo $! > "${WORKDIR}/cloudflared.pid"

# ----- 等待 Argo 域名 -----
echo "[7/8] 等待 Cloudflare 分配域名..."

ARGO_URL=""
for i in $(seq 1 90); do
    ARGO_URL=$(grep -oE 'https://[-a-zA-Z0-9.]+\.trycloudflare\.com' \
        "${WORKDIR}/cloudflared.log" 2>/dev/null | head -n 1 || true)

    if [ -n "$ARGO_URL" ]; then
        break
    fi

    CF_PID=$(cat "${WORKDIR}/cloudflared.pid" 2>/dev/null || true)
    if [ -z "$CF_PID" ] || ! kill -0 "$CF_PID" 2>/dev/null; then
        cat "${WORKDIR}/cloudflared.log"
        fail_exit "Cloudflared 进程异常退出"
    fi

    if [ "$i" -le 10 ]; then
        sleep 0.3
    elif [ "$i" -le 30 ]; then
        sleep 0.6
    else
        sleep 1
    fi
done

if [ -z "$ARGO_URL" ]; then
    cat "${WORKDIR}/cloudflared.log"
    fail_exit "获取 Argo 域名超时，可能 Cloudflare 临时分配接口受限"
fi

ARGO_DOMAIN="$(echo "$ARGO_URL" | sed 's#https://##')"

# ----- 生成 VMess 链接 -----
echo "[8/8] 生成 VMess 链接..."

VMESS_JSON=$(cat <<EOF
{"v":"2","ps":"Argo-${ARGO_DOMAIN:0:8}","add":"${CF_PREFERRED_DOMAIN}","port":"443","id":"${UUID}","aid":"0","scy":"auto","net":"ws","type":"none","host":"${ARGO_DOMAIN}","path":"${WSPATH}","tls":"tls","sni":"${ARGO_DOMAIN}"}
EOF
)

VMESS_LINK="vmess://$(printf '%s' "$VMESS_JSON" | base64 | tr -d '\r\n')"

# ----- 生成管理脚本 -----
cat > stop.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
WORKDIR="${WORKDIR}"

stop_one() {
    local pid_file="$1"
    local expected_path="$2"

    [ -f "$pid_file" ] || return 0

    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        if ps -p "$pid" -o args= 2>/dev/null | grep -qF "$expected_path"; then
            kill "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$pid_file"
}

stop_one "${WORKDIR}/xray.pid" "${WORKDIR}/xray"
stop_one "${WORKDIR}/cloudflared.pid" "${WORKDIR}/cloudflared"

echo "节点已安全停止"
SCRIPT_EOF
chmod +x stop.sh

cat > uninstall.sh <<SCRIPT_EOF
#!/usr/bin/env bash
"${WORKDIR}/stop.sh" 2>/dev/null || true
rm -rf "${WORKDIR}"
echo "节点服务已终止，相关工作目录已删除"
SCRIPT_EOF
chmod +x uninstall.sh

# ----- 输出信息 -----
CF_PROTOCOL_DISPLAY="${CF_PROTOCOL:-auto}"

cat > info.txt <<EOF
Protocol: VMess
Address (优选): ${CF_PREFERRED_DOMAIN}
Argo Tunnel: ${ARGO_DOMAIN}
Port: 443
UUID: ${UUID}
AlterId: 0
Security: auto
Network: ws
Type: none
Host: ${ARGO_DOMAIN}
SNI: ${ARGO_DOMAIN}
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
printf '工作目录: %s\n' "$WORKDIR"
printf '停止节点: %s/stop.sh\n' "$WORKDIR"
printf '卸载节点: %s/uninstall.sh\n' "$WORKDIR"
printf 'Xray 日志: %s/xray.log\n' "$WORKDIR"
printf 'Cloudflared 日志: %s/cloudflared.log\n' "$WORKDIR"
echo "=========================================="

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

# 正常退出，解绑 trap，保留后台服务
trap - INT TERM