# 🚀 科学上网一键脚本库 (Jiaoben)

本项目提供了一系列由 AI 辅助编写的科学上网一键部署脚本，旨在为用户提供最简便、高效的节点搭建体验。所有脚本均经过优化，支持多种架构，并具备自动环境检查与依赖安装功能。

---

## 🛠️ 脚本列表

### 1. VMess + WebSocket + TLS + Argo 隧道
此脚本通过 Cloudflare Argo 隧道转发流量，能够有效解决 IP 被封锁或网络连接不畅的问题。

**功能特点：**
- 自动下载并配置 Xray-core。
- 自动获取 Cloudflared 二进制文件。
- 自动分配随机端口或支持自定义端口。
- 自动生成并显示 VMess 节点链接。
- 提供一键停止与卸载脚本。

**执行命令：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/VMess-WS-Argo-Quick-Tunnel.sh)
```

---

### 2. Hysteria 2 一键部署脚本
Hysteria 2 是一款基于 QUIC 协议的高性能代理工具，特别适合在高丢包网络环境下使用。

**功能特点：**
- 支持 **端口跳跃 (Port Hopping)**，有效对抗协议检测。
- 提供多种 TLS 证书获取方式：自签证书、ACME 自动申请、自定义证书。
- 支持带宽限速配置。
- 自动配置系统防火墙（UFW / Firewall-cmd / Iptables）。
- 支持以 Systemd 服务运行，实现开机自启。

**执行命令：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/hy2.sh)
```

---

## 📋 使用说明

1. **环境要求**：建议在 Debian / Ubuntu 等主流 Linux 发行版上运行。
2. **权限要求**：部分功能（如防火墙配置、Systemd 服务安装）需要 **root** 权限。
3. **安全提示**：本项目脚本由 AI 编写，建议在部署前自行检查脚本内容。

## 📂 项目结构

- `VMess-WS-Argo-Quick-Tunnel.sh`: VMess + Argo 隧道一键脚本。
- `hy2.sh`: Hysteria 2 一键部署脚本。
- `README.md`: 项目说明文档。

---

## 🤝 贡献与反馈

如果你在使用过程中遇到任何问题，欢迎提交 Issue 或通过 GitHub 提交 Pull Request。

**免责声明**：本工具仅供学习和研究网络技术使用，请在遵守当地法律法规的前提下使用。
