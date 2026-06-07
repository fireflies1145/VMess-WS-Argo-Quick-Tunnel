# 🚀 jiaoben - 代理节点一键部署系统

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/shell_script-%23121011.svg?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

> 一个功能强大、轻量的 Shell 脚本，用于快速部署和管理多种代理协议节点。支持 REALITY (VLESS)、Hysteria 2、Argo 隧道，所有服务通过 Systemd 统一管理。

## ✨ 特性

- **一键部署** - 一个脚本搞定 REALITY、Hysteria2、Argo 隧道
- **Systemd 集成** - 所有服务（含 Argo）通过 Systemd 管理，支持开机自启和故障自动恢复
- **SHA256 校验** - 下载组件自动验证完整性
- **端口检测** - 部署前自动检查端口占用
- **下载重试** - 网络不稳定时自动重试
- **多架构支持** - x86_64 (amd64)、ARM64 (aarch64)
- **多发行版** - Ubuntu / Debian / CentOS / RHEL
- **健康检查** - 部署后自动验证服务状态
- **防火墙持久化** - iptables 规则自动持久化
- **日志轮转** - Argo 日志自动轮转，防止磁盘占满
- **多源 IP 检测** - 5 个 IP 源自动 fallback
- **JSON 配置安全构建** - jq 验证，防止配置损坏

## 🚀 快速开始

### 一键部署

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/jiaoben-simplified.sh)
```

### 本地部署

```bash
git clone https://github.com/fireflies1145/jiaoben.git
cd jiaoben
sudo bash jiaoben-simplified.sh
```

### 菜单选项

```
1. 部署 REALITY (VLESS)     # 端口 443，高性能
2. 部署 Argo 隧道 (VLESS)   # 无需暴露真实 IP
3. 部署 Hysteria2           # 基于 QUIC，低延迟
4. 一键部署全部
5. 查看节点信息
6. 重启服务
7. 更新组件
8. 彻底卸载（有确认提示）
```

### 参数支持

```bash
sudo bash jiaoben-simplified.sh --version   # 显示版本号
```

## 📋 项目结构

```
jiaoben/
├── jiaoben-simplified.sh    # ⭐ 精简版一键脚本（推荐）
├── jb_improved.sh           # 运维管理工具
├── common.sh                # 公共函数库（供扩展脚本使用）
├── uninstall.sh             # 卸载脚本
└── docs/
    ├── CHANGELOG.md
    ├── IMPROVEMENTS.md
    └── SECURITY.md
```

## 🔧 服务管理

精简版脚本部署的服务名：

| 服务名 | 协议 | systemd 服务 |
|--------|------|-------------|
| REALITY | VLESS + XTLS | `jiaoben-xray` |
| Hysteria2 | QUIC | `jiaoben-hy2` |
| Argo 隧道 | VLESS + WebSocket | `jiaoben-argo` |

```bash
# 手动管理服务
systemctl status jiaoben-xray
systemctl restart jiaoben-hy2
systemctl status jiaoben-argo
journalctl -u jiaoben-xray -n 50
```

## 📁 配置文件位置

```
~/.jiaoben/
├── all_nodes_info.txt        # 节点链接信息
├── config.json              # Xray 配置
├── config.json.bak.*        # 配置备份（自动）
├── hy2_config.yaml          # Hysteria2 配置
├── hy2.key / hy2.crt        # TLS 证书
├── argo.log                 # Argo 隧道日志
├── xray/
│   ├── xray                 # Xray 二进制
│   └── geo*.dat             # 地理数据
├── hysteria                 # Hysteria2 二进制
└── cloudflared              # Cloudflared 二进制
```

## 🔒 安全特性

- 文件权限 `600` 保护敏感文件（nodes.txt 等）
- 下载组件 SHA256 完整性校验
- 配置覆盖前自动备份
- 部署前端口占用检测
- 安全的随机密钥生成（openssl rand）
- JSON 配置有效性验证（jq 校验）
- iptables 防火墙规则自动持久化

## 🗑️ 卸载

**方式一：脚本菜单（推荐）**
```bash
sudo bash jiaoben-simplified.sh
# 选择 8 → 确认 y
```

**方式二：独立卸载脚本**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/uninstall.sh)
```

卸载会自动：停止所有服务 → 删除 systemd 文件 → 清理进程 → 删除工作目录 → 清理防火墙

## 🐛 故障排除

```bash
# 查看服务状态
systemctl status jiaoben-xray

# 查看日志
journalctl -u jiaoben-xray -n 50

# 调试模式运行脚本
sudo bash -x jiaoben-simplified.sh

# 检查网络连接
curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq .tag_name
```

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE)

## 🙏 致谢

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Hysteria](https://github.com/apernet/hysteria)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)

---

**当前版本**: v6.0 (2026-06-07)
