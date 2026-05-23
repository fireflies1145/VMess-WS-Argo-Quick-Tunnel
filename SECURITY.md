# jiaoben 项目安全性最佳实践

## 概述

本文档提供了 jiaoben 项目的安全性最佳实践和建议。

## 1. 文件权限管理

### 敏感文件权限设置

```bash
# 节点信息文件 - 仅所有者可读写
chmod 600 ~/all_nodes_info.txt

# 配置目录 - 仅所有者可访问
chmod 700 ~/proxy_nodes/config

# 日志目录 - 仅所有者可访问
chmod 700 ~/proxy_nodes/logs
```

### 自动化权限设置

使用 `common.sh` 中的 `secure_file()` 函数：

```bash
source common.sh
secure_file ~/all_nodes_info.txt
```

## 2. 下载文件完整性校验

### 实现 SHA256 校验

```bash
# 下载文件和校验文件
wget "https://github.com/hysteria-net/hysteria/releases/download/v2.x.x/hysteria-linux-amd64"
wget "https://github.com/hysteria-net/hysteria/releases/download/v2.x.x/hysteria-linux-amd64.sha256"

# 验证完整性
sha256sum -c hysteria-linux-amd64.sha256 || exit 1
```

## 3. Sudo 权限管理

### 配置 NOPASSWD

编辑 `/etc/sudoers`（使用 `sudo visudo`）：

```sudoers
# 允许特定用户无密码执行特定命令
ubuntu ALL=(ALL) NOPASSWD: /usr/bin/systemctl
ubuntu ALL=(ALL) NOPASSWD: /usr/bin/apt-get
```

### 权限检查

```bash
# 在脚本中检查 sudo 权限
if ! sudo -n true 2>/dev/null; then
    echo "需要 sudo 权限且未配置 NOPASSWD"
    exit 1
fi
```

## 4. 密钥和密码管理

### 使用安全的随机数生成

```bash
# 使用 /dev/urandom 生成安全的密钥
generate_uuid() {
    cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1
}

# 生成强密码
generate_password() {
    openssl rand -base64 32
}
```

### 密钥存储

- 不要在脚本中硬编码密钥
- 使用环境变量或配置文件存储密钥
- 确保配置文件权限为 600

## 5. 日志和审计

### 启用审计日志

```bash
# 记录所有关键操作
log_audit() {
    local action="$1"
    local user="${SUDO_USER:-$(whoami)}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$user] $action" >> /var/log/jiaoben-audit.log
}
```

### 日志轮转

```bash
# 配置 logrotate
cat > /etc/logrotate.d/jiaoben << 'LOGROTATE'
/var/log/jiaoben-audit.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
}
LOGROTATE
```

## 6. 网络安全

### 防火墙配置

```bash
# 仅允许必要的端口
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw enable
```

### 使用 HTTPS

- 始终使用 HTTPS 下载文件
- 验证 SSL 证书

## 7. 定期安全检查

### 脚本安全审计

```bash
# 检查硬编码的密钥
grep -r "password\|secret\|key" *.sh

# 检查不安全的权限
find . -type f -perm /077 -ls

# 检查 sudo 使用情况
grep -r "sudo" *.sh
```

## 8. 应急响应

### 如果发现安全漏洞

1. 立即停止受影响的服务
2. 更改所有密钥和密码
3. 检查日志以确定影响范围
4. 更新脚本并重新部署
5. 通知所有相关人员

---

**最后更新**: 2026-05-23
