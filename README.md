# 🚀 jiaoben - 企业级代理节点一键部署系统

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/shell_script-%23121011.svg?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Maintained](https://img.shields.io/badge/maintained%3F-yes-green.svg)](https://github.com/fireflies1145/jiaoben)

> 一个功能强大、生产就绪的 Shell 脚本项目，用于快速部署和管理多种代理协议节点。支持 Hysteria 2、VLESS、VMess 等多种协议，提供完整的生命周期管理（部署、管理、监控）。

## ✨ 核心特性

### 🎯 完整的生命周期管理
- **一键部署** - 精简版脚本自动化部署所有依赖和服务
- **统一管理** - 提供强大的运维控制台
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
├── 精简版脚本（推荐）
├── jiaoben-simplified.sh              # ⭐ 一键部署脚本（精简版，推荐使用）
│
├── 原始版本脚本（兼容性维护）
├── all-in-one.sh                      # 一键部署脚本（主控制器）
├── jb.sh                              # 运维管理脚本（原始版本）
├── jb_improved.sh                     # 运维管理脚本（改进版本）
├── common.sh                          # 公共配置和函数库
├── hy2.sh                             # Hysteria 2 部署脚本
├── VLESS-WS-Argo-Quick-Tunnel.sh      # VLESS 快速隧道脚本
├── VMess-WS-Argo-Quick-Tunnel.sh      # VMess 快速隧道脚本
│
├── 卸载脚本
└── uninstall.sh                       # 卸载脚本
```

## 🚀 快速开始

### 前置要求
- Linux 系统（Ubuntu/Debian/CentOS）
- Bash 4.0+
- 网络连接
- Sudo 权限（推荐配置 NOPASSWD）

### 推荐：精简版脚本（新）

> **精简版优势**：代码精简 50%，仅需 1 个脚本，功能完整无损，经过完整测试

**一键部署精简版：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/jiaoben-simplified.sh)
```

**本地部署精简版：**

```bash
git clone https://github.com/fireflies1145/jiaoben.git
cd jiaoben
sudo bash jiaoben-simplified.sh
```

### 原始版本（兼容性维护）

**一键部署原始版本：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/all-in-one.sh)
```

**或者使用 wget：**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/fireflies1145/jiaoben/main/all-in-one.sh)
```

**本地部署原始版本：**

```bash
# 克隆项目
git clone https://github.com/fireflies1145/jiaoben.git
cd jiaoben

# 赋予执行权限
chmod +x all-in-one.sh

# 执行部署
bash all-in-one.sh
```

### 版本对比

| 特性 | 精简版 | 原始版 |
|------|--------|--------|
| 文件数量 | 1 个 | 6 个 |
| 代码行数 | ~380 行 | ~800 行 |
| 功能完整性 | 100% | 100% |
| 可维护性 | 高 ⭐⭐⭐⭐⭐ | 中 ⭐⭐⭐ |
| 部署速度 | 快 | 中 |
| 推荐指数 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |

## 📖 使用指南

### 部署流程

1. **系统检测** - 自动识别操作系统和架构
2. **依赖安装** - 安装必要的系统工具（curl、unzip、jq 等）
3. **二进制下载** - 下载最新的代理软件（带完整性校验）
4. **配置生成** - 生成协议配置文件
5. **服务创建** - 通过 Systemd 创建服务
6. **启动验证** - 验证所有服务正常运行

### 管理命令

#### 精简版管理菜单

精简版脚本提供交互式菜单：

```
=========================================
  jiaoben - 科学上网四合一精简版
=========================================
1. 部署 REALITY
2. 部署 Hysteria2
3. 部署 VMess + Argo
4. 部署 VLESS + Argo
5. 管理面板
6. 卸载全部
0. 退出
```

#### 管理面板功能

```
=== 管理面板 ===
1. 查看所有节点
2. 启动所有服务
3. 停止所有服务
4. 查看服务状态
5. 查看日志
6. 返回主菜单
```

### 配置文件位置

```
~/.jiaoben/
├── nodes.txt                  # 节点信息
├── xray/
│   ├── *.json                 # Xray 配置
│   └── xray                   # Xray 二进制
├── hysteria2/
│   ├── config.yaml            # Hysteria2 配置
│   └── hysteria               # Hysteria2 二进制
└── cloudflared/
    └── cloudflared            # Cloudflare 隧道
```

## 🔒 安全建议

### 文件权限
```bash
# 确保敏感文件只有所有者可读
chmod 600 ~/.jiaoben/nodes.txt
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

## 🎯 精简版本特性 (v2.1.0 - 2026-05-23)

### 核心改进
- ✅ **代码精简 50%** - 从 800 行减少到 380 行
- ✅ **单一脚本** - 删除了 5 个冗余脚本文件
- ✅ **功能完整** - 保留所有核心功能，无功能丢失
- ✅ **易于维护** - 逻辑清晰，便于扩展
- ✅ **完整测试** - 经过本地完整测试，无 Bug

### 精简方案
- 合并 VMess 和 VLESS Argo 脚本为一个函数
- 统一所有公共函数到主脚本中
- 删除重复的系统检测和依赖安装逻辑
- 简化配置文件生成流程
- 优化 Systemd 服务创建

## 🗑️ 卸载方法

### 快速卸载

**最简单的方式 - 使用卸载脚本：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fireflies1145/jiaoben/main/uninstall.sh)
```

**或者本地卸载：**

```bash
# 克隆项目
git clone https://github.com/fireflies1145/jiaoben.git
cd jiaoben

# 赋予执行权限
chmod +x uninstall.sh

# 执行卸载
bash uninstall.sh
```

### 卸载脚本功能

卸载脚本会自动执行以下操作：

1. ✅ **停止所有服务** - 停止 REALITY、Hysteria 2、VMess Argo、VLESS Argo 等所有服务
2. ✅ **删除服务文件** - 删除 Systemd 服务配置文件
3. ✅ **删除工作目录** - 删除 `~/.jiaoben` 目录及所有配置
4. ✅ **删除管理工具** - 删除 `/usr/local/bin/jb` 命令
5. ✅ **清理残留进程** - 杀死所有残留的 xray、hysteria、cloudflared 进程

### 验证卸载

卸载完成后，你可以验证：

```bash
# 检查服务是否已停止
sudo systemctl list-units --type=service | grep -E "xray|hy2|cf-"

# 检查工作目录是否已删除
ls -la ~/.jiaoben 2>/dev/null || echo "工作目录已删除"

# 检查进程是否已清理
ps aux | grep -E "xray|hysteria|cloudflared" | grep -v grep || echo "所有进程已清理"
```

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
bash -x jiaoben-simplified.sh
```

### 服务无法启动

**问题**: Systemd 服务启动失败  
**解决方案**:
```bash
# 查看服务状态
systemctl status xray-reality

# 查看详细日志
journalctl -u xray-reality -n 50
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
**版本**: 2.1.0 (Simplified Edition with DeepSeek V4 Pro Optimization)
