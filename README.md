# 🚀 科学上网一键脚本库 (Jiaoben)

本项目提供了一系列由 AI 辅助编写的科学上网一键部署脚本，旨在为用户提供最简便、高效的节点搭建体验。所有脚本均经过优化，支持多种架构，并具备自动环境检查与依赖安装功能。

---

## 🛠️ 脚本列表

### 🌟 四合一全自动部署脚本 (All-in-One)
**真正的“一键”部署**：复制命令并执行后，脚本将全自动依次部署四个主流协议节点，无需任何手动干预。

**自动部署模块：**
1.  **VLESS + TCP + REALITY**：SNI 偷取 `www.apple.com`，极高隐蔽性。
2.  **Hysteria 2**：SNI 偷取 `www.bing.com`，适合高丢包环境。
3.  **VMess + WS + Argo 隧道**：通过 Cloudflare 隧道转发，免公网 IP。
4.  **VLESS + WS + Argo 隧道**：轻量化隧道方案。

**执行命令：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/all-in-one.sh)
```

---

### 1. VLESS + WebSocket + TLS + Argo 隧道
此脚本使用更轻量的 VLESS 协议，通过 Cloudflare Argo 隧道转发流量。

**执行命令：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/VLESS-WS-Argo-Quick-Tunnel.sh)
```

---

### 2. VMess + WebSocket + TLS + Argo 隧道
此脚本通过 Cloudflare Argo 隧道转发流量，提供稳定的连接体验。

**执行命令：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/VMess-WS-Argo-Quick-Tunnel.sh)
```

---

### 3. Hysteria 2 一键部署脚本
Hysteria 2 是一款基于 QUIC 协议的高性能代理工具，特别适合在高丢包网络环境下使用。

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

- `all-in-one.sh`: 四合一全自动部署脚本。
- `VLESS-WS-Argo-Quick-Tunnel.sh`: VLESS + Argo 隧道一键脚本。
- `VMess-WS-Argo-Quick-Tunnel.sh`: VMess + Argo 隧道一键脚本。
- `hy2.sh`: Hysteria 2 一键部署脚本。
- `README.md`: 项目说明文档。

---

## 🤝 贡献与反馈

如果你在使用过程中遇到任何问题，欢迎提交 Issue 或通过 GitHub 提交 Pull Request。

**免责声明**：本工具仅供学习和研究网络技术使用，请在遵守当地法律法规的前提下使用。
