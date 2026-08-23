# 🚀 jiaoben - 代理节点一键部署系统

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/shell_script-%23121011.svg?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

> 一个轻量的 Shell 脚本，快速部署和管理多种代理协议节点。支持 REALITY (VLESS)、Hysteria 2、Argo 隧道，所有服务通过 Systemd 统一管理。

## 🚀 一键部署

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/run.sh)
```

## ✨ 功能

- **REALITY (VLESS)** — 端口 443，高性能抗封锁，默认借用 `www.amd.com` 证书（SNI 伪装目标）
- **Argo 隧道** — 无需暴露真实 IP，通过 Cloudflare 隧道
- **Hysteria2** — 基于 QUIC，低延迟，支持端口跳跃
- **Systemd 管理** — 所有服务开机自启、故障自动恢复
- **SHA256 校验** — 下载组件自动验证完整性
- **多架构** — x86_64 / ARM64

## 🎭 REALITY 伪装目标

默认借用 `www.amd.com`（已验证支持 TLS 1.3、HTTP/2、X25519，证书由 DigiCert/GeoTrust 签发）。

如需更换，编辑 `run.sh` 中 REALITY 部署段的 `domain` 变量：

```bash
domain="www.amd.com"   # 改为其他支持 TLS1.3 + H2 的境外站点
```

更换后需同时重新部署，客户端链接中的 `sni` 会自动跟随该域名。

## 📋 菜单

```
1. 部署 REALITY (VLESS)       — 端口 443，高性能（伪装 www.amd.com）
2. 部署 Argo 隧道 (VLESS)     — 无需暴露真实 IP
3. 部署 Hysteria2             — 基于 QUIC，低延迟
4. 一键部署全部
5. 查看节点信息
6. 停止/重启服务
7. 彻底卸载
0. 退出
```

## 🔧 服务管理

部署后会自动安装 `jb` 管理工具：

```bash
jb status          # 查看所有服务状态
jb list            # 列出已安装服务
jb nodes           # 显示所有节点链接
jb restart hy2     # 重启 Hysteria2
jb logs xray       # 实时查看 Xray 日志
```

也可以直接用 systemd 管理：

```bash
systemctl status jiaoben-xray    # REALITY
systemctl status jiaoben-hy2     # Hysteria2
systemctl status jiaoben-argo    # Argo 隧道
journalctl -u jiaoben-xray -n 50 # 查看日志
```

## 📁 配置文件

```
~/.jiaoben/
├── all_nodes_info.txt    # 节点链接（可读渲染）
├── nodes.tsv             # 节点记录（按协议去重）
├── config.json           # Xray 配置
├── hy2_config.yaml       # Hysteria2 配置
├── xray/xray             # Xray 二进制
├── hysteria              # Hysteria2 二进制
└── cloudflared           # Cloudflared 二进制
```

## 🧪 测试

```bash
bash tests/run_tests.sh
```

回归测试覆盖节点链接生成、配置合并、UUID 合规性等 32 项检查，不需要 root、不联网、不修改系统。

## 🗑️ 卸载

```bash
sudo bash run.sh
# 选择 7 → 输入 yes 确认
```

## 📁 项目结构

```
jiaoben/
├── run.sh           # ⭐ 一键部署脚本
├── common.sh        # 公共函数库
├── uninstall.sh     # 独立卸载脚本
├── jb_improved.sh   # 运维管理工具（安装为 jb）
├── tests/           # 回归测试
└── docs/
```

## 📄 许可证

MIT License

---

**当前版本**: v5.4 (2026-08-23)
