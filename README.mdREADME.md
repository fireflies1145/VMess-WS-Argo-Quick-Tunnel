# VMess-WS-Argo-Quick-Tunnel
ChatGTP5.5think Gemini3.1pro Claudesonnet4.6共同完成的
README.md是GTP写的
VMess + WS + Argo Quick Tunnel

基于 Xray-core 与 Cloudflare Quick Tunnel 的临时 VMess + WebSocket + TLS 节点一键脚本。

特点：

- 不需要域名
- 不开放服务器公网端口
- 不依赖 Nginx/Caddy
- 不写 systemd
- 默认仅监听 "127.0.0.1"
- 自动生成 UUID / WS Path
- 自动生成 VMess 链接
- 支持 amd64 / arm64
- 支持 HTTP2 / QUIC

---

架构

Client
   ↓
trycloudflare.com
   ↓
Cloudflare Edge
   ↓
cloudflared
   ↓
127.0.0.1:PORT
   ↓
Xray VMess + WS

TLS 由 Cloudflare 提供。

---

系统要求

推荐系统：

- Debian 11+
- Ubuntu 20.04+

支持架构：

- amd64 / x86_64
- arm64 / aarch64

依赖：

apt-get update && apt-get install -y curl unzip openssl coreutils grep sed procps

---

一键运行

bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/VMess-WS-Argo-Quick-Tunnel/main/VMess-WS-Argo-Quick-Tunnel.sh)

---

使用方法

下载脚本

curl -O https://raw.githubusercontent.com/fireflies1145/VMess-WS-Argo-Quick-Tunnel/main/VMess-WS-Argo-Quick-Tunnel.sh

或者：

wget https://raw.githubusercontent.com/fireflies1145/VMess-WS-Argo-Quick-Tunnel/main/VMess-WS-Argo-Quick-Tunnel.sh

---

添加执行权限

chmod +x VMess-WS-Argo-Quick-Tunnel.sh

---

运行

./VMess-WS-Argo-Quick-Tunnel.sh

部署完成后会输出：

- VMess 链接
- UUID
- WS Path
- TLS/SNI
- trycloudflare 域名

---

指定 Cloudflared 协议

默认自动选择协议。

HTTP2

CF_PROTOCOL=http2 ./VMess-WS-Argo-Quick-Tunnel.sh

QUIC

CF_PROTOCOL=quic ./VMess-WS-Argo-Quick-Tunnel.sh

---

停止节点

~/vmess-argo-temp/stop.sh

---

卸载

~/vmess-argo-temp/uninstall.sh

---

查看日志

Xray

cat ~/vmess-argo-temp/xray.log

Cloudflared

cat ~/vmess-argo-temp/cloudflared.log

---

工作目录

~/vmess-argo-temp

包含：

xray
cloudflared
config.json
info.txt
xray.log
cloudflared.log
stop.sh
uninstall.sh

---

安全说明

本脚本：

- 不开放公网端口
- 不修改 iptables
- 不修改 nginx
- 不修改 ssh
- 不写 systemd
- 默认仅本地监听

但请注意：

- Quick Tunnel 为临时域名
- 重启后域名会变化
- Cloudflare 可能随时限制 trycloudflare.com
- 不建议用于长期生产环境

建议：

- 仅用于临时节点
- 使用干净 VPS
- 不在生产服务器运行

---

注意事项

Quick Tunnel 不稳定

Cloudflare Quick Tunnel：

- 域名随机
- 可能限速
- 可能断连
- 不保证长期可用

长期使用建议：

- 自有域名
- Named Tunnel
- Cloudflare Zero Trust

---

GitHub Raw 可能无法访问

可替换为 jsDelivr：

bash <(curl -fsSL https://cdn.jsdelivr.net/gh/fireflies1145/VMess-WS-Argo-Quick-Tunnel@main/VMess-WS-Argo-Quick-Tunnel.sh)

---

License

MIT
