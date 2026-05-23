# 🚀 jiaoben - 企业级代理节点一键部署系统

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/shell_script-%23121011.svg?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Maintained](https://img.shields.io/badge/maintained%3F-yes-green.svg)](https://github.com/fireflies1145/jiaoben)

> 一个功能强大、生产就绪的 Shell 脚本项目，用于快速部署和管理多种代理协议节点。支持 Hysteria 2、VLESS、VMess 等多种协议，提供完整的生命周期管理（部署、管理、监控）。

## ✨ 核心特性

### 🎯 完整的生命周期管理
- **一键部署** - `all-in-one.sh` 自动化部署所有依赖和服务
- **统一管理** - `jb.sh` 提供强大的运维控制台
- **Systemd 集成** - 所有服务通过 Systemd 统一管理，支持开机自启和故障自动恢复
- **实时监控** - 查看服务状态、日志和性能指标

### 🔌 多协议支持
- ✅ **Hysteria 2** - 高性能代理协议
- ✅ **VLESS** - 灵活的代理协议
- ✅ **VMess** - 安全的代理协议
- ✅ **Argo Tunnel** - 快速隧道支持

### 🛡️ 企业级安全
- 文件权限管理（600 权限保护敏感文件）
- 完整性校验（SHA256 验证下载文件）
- Sudo 权限检查和管理
- 安全的随机数生成

### 📊 系统兼容性
- ✅ Ubuntu / Debian
- ✅ CentOS / RHEL
- ✅ 多架构支持（x86_64、ARM64、ARM32）

## 📋 项目结构

```
jiaoben/
├── README.md                          # 项目文档
├── CHANGELOG.md                       # 版本变更记录
├── IMPROVEMENTS.md                    # 改进日志
├── SECURITY.md                        # 安全最佳实践
│
├── 核心脚本
├── all-in-one.sh                      # 一键部署脚本（主控制器）
├── jb.sh                              # 运维管理脚本（原始版本）
├── jb_improved.sh                     # 运维管理脚本（改进版本）
├── common.sh                          # 公共配置和函数库
│
├── 协议脚本
├── hy2.sh                             # Hysteria 2 部署脚本
├── VLESS-WS-Argo-Quick-Tunnel.sh      # VLESS 快速隧道脚本
└── VMess-WS-Argo-Quick-Tunnel.sh      # VMess 快速隧道脚本
```

## 🚀 快速开始

### 前置要求
- Linux 系统（Ubuntu/Debian/CentOS）
- Bash 4.0+
- 网络连接
- Sudo 权限（推荐配置 NOPASSWD）

### 一键部署

**最简单的方式 - 直接执行：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/all-in-one.sh)
```

**或者使用 wget：**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/fireflies1145/jiaoben/main/all-in-one.sh)
```

**本地部署方式：**

```bash
# 克隆项目
git clone https://github.com/fireflies1145/jiaoben.git
cd jiaoben

# 赋予执行权限
chmod +x all-in-one.sh

# 执行部署
bash all-in-one.sh
```

### 部署完成后

部署完成后，系统会自动安装 `jb` 快捷管理工具。你可以直接在终端使用：

```bash
# 查看所有节点信息
jb status

# 查看特定协议节点
jb show vless
jb show hysteria2

# 管理服务
jb start          # 启动所有服务
jb stop           # 停止所有服务
jb restart        # 重启所有服务

# 查看日志
jb logs xray      # 查看 Xray 日志
jb logs hy2       # 查看 Hysteria2 日志

# 查看帮助
jb help           # 显示所有可用命令
```

## 📖 使用指南

### 部署流程

1. **系统检测** - 自动识别操作系统和架构
2. **依赖安装** - 安装必要的系统工具（curl、unzip、jq 等）
3. **二进制下载** - 下载最新的代理软件（带完整性校验）
4. **配置生成** - 生成协议配置文件
5. **服务创建** - 通过 Systemd 创建服务
6. **启动验证** - 验证所有服务正常运行

### 管理命令

#### jb.sh 命令参考

```bash
# 服务管理
jb start [service]      # 启动服务
jb stop [service]       # 停止服务
jb restart [service]    # 重启服务
jb status [service]     # 查看服务状态

# 信息查看
jb show [protocol]      # 显示协议节点信息
jb logs [service]       # 查看服务日志
jb info                 # 显示完整系统信息

# 改进版本 (jb_improved.sh)
jb help                 # 显示帮助信息
jb version              # 显示版本信息
```

### 配置文件位置

```
~/.jiaoben/
├── all_nodes_info.txt          # 节点信息（JSON 格式）
├── xray/
│   ├── config.json             # Xray 配置
│   └── xray                    # Xray 二进制
├── hysteria2/
│   ├── config.yaml             # Hysteria2 配置
│   └── hysteria                # Hysteria2 二进制
└── cloudflared/
    └── cloudflared             # Cloudflare 隧道
```

## 🔒 安全建议

### 文件权限
```bash
# 确保敏感文件只有所有者可读
chmod 600 ~/.jiaoben/all_nodes_info.txt
chmod 600 ~/.jiaoben/xray/config.json
```

### Sudo 配置
为了实现无密码部署，建议配置 sudo：

```bash
# 编辑 sudoers 文件
sudo visudo

# 添加以下行（用你的用户名替换 username）
username ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/apt, /usr/bin/yum
```

### 下载校验
所有脚本都会自动验证下载的二进制文件的完整性。确保网络连接稳定。

## 📊 架构设计

### 分层架构

```
┌─────────────────────────────────────┐
│      运维控制层 (jb.sh)              │
│  - 服务管理                          │
│  - 日志查看                          │
│  - 状态监控                          │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│      部署控制层 (all-in-one.sh)      │
│  - 系统检测                          │
│  - 依赖安装                          │
│  - 配置生成                          │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│      协议模块层                      │
│  - hy2.sh (Hysteria2)               │
│  - VLESS-WS-Argo-Quick-Tunnel.sh    │
│  - VMess-WS-Argo-Quick-Tunnel.sh    │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│      Systemd 服务层                  │
│  - xray-reality.service             │
│  - hysteria2.service                │
│  - argo-tunnel.service              │
└─────────────────────────────────────┘
```

### 模块化设计

- **控制器-模块模式** - 主脚本编排，子脚本独立部署
- **状态与配置分离** - 节点信息与系统配置分开管理
- **公共库** - `common.sh` 提供统一的工具函数和配置

## 🔄 最近改进 (DeepSeek V4 Pro 深度分析)

### P0 级改进（关键）
- ✅ 添加文件完整性校验 (SHA256)
- ✅ 设置敏感文件权限为 600
- ✅ 改进错误处理机制

### P1 级改进（高优先级）
- ✅ 创建公共库 `common.sh`
- ✅ 统一 Sudo 权限管理
- ✅ 完善架构兼容性检查

### P2 级改进（中优先级）
- ✅ 动态服务发现
- ✅ 合并依赖包安装
- ✅ 增加代码注释

详见 [IMPROVEMENTS.md](IMPROVEMENTS.md) 和 [SECURITY.md](SECURITY.md)

## 📝 文档

- [CHANGELOG.md](CHANGELOG.md) - 版本变更记录
- [IMPROVEMENTS.md](IMPROVEMENTS.md) - 改进日志和使用指南
- [SECURITY.md](SECURITY.md) - 安全最佳实践

## 🐛 故障排除

### 部署失败

**问题**: 脚本执行失败  
**解决方案**:
```bash
# 检查 Bash 版本
bash --version

# 检查网络连接
ping github.com

# 查看详细错误信息
bash -x all-in-one.sh
```

### 服务无法启动

**问题**: Systemd 服务启动失败  
**解决方案**:
```bash
# 查看服务状态
systemctl status xray-reality

# 查看详细日志
journalctl -u xray-reality -n 50

# 手动启动调试
/root/.jiaoben/xray/xray -c /root/.jiaoben/xray/config.json
```

### 节点链接错误

**问题**: 节点链接显示乱码或错误  
**解决方案**:
```bash
# 检查节点信息文件
cat ~/.jiaoben/all_nodes_info.txt

# 重新生成节点信息
jb show all
```

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 📄 许可证

本项目采用 MIT 许可证。详见 [LICENSE](LICENSE) 文件。

## 👨‍💻 作者

**fireflies1145** - GitHub: [@fireflies1145](https://github.com/fireflies1145)

## 🙏 致谢

感谢以下项目的支持：
- [Hysteria](https://github.com/apernet/hysteria)
- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)

## 📞 联系方式

- GitHub Issues: [Report a bug](https://github.com/fireflies1145/jiaoben/issues)
- 讨论区: [Discussions](https://github.com/fireflies1145/jiaoben/discussions)

---

**最后更新**: 2026-05-23  
**版本**: 2.0.0 (Pro Edition with DeepSeek V4 Optimization)
