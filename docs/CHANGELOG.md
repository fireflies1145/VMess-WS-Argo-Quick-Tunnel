# jiaoben 项目更新日志

## v5.2 - 2026-08-12 (Bug 修复)

### 🐛 Bug 修复

1. **Hysteria2 端口跳跃修复** — 服务端不再写非法的 `listen: :20000-20075` 和不存在的 `portHopping` 字段；改为固定监听单端口，并用 iptables NAT 将 UDP 端口区间 DNAT 重定向到监听端口
2. **masquerade.insecure 类型修复** — YAML 中输出 `true/false` bool 值（原来写 `1` 或空值会导致 hysteria 解析失败）
3. **REALITY 防火墙放行** — 部署 REALITY 时新增放行 TCP 443（原来仅 Hysteria2 调用防火墙函数）
4. **IPv6 节点链接修复** — 公网 IP 为 IPv6 时自动加方括号 `[...]`，避免链接格式错误
5. **Argo 域名回退修复** — 获取隧道域名超时时改为报错退出，不再回退到第三方域名 `yg1.ygkkk.dpdns.org`
6. **jb 管理工具安装** — check_env 时将 jb_improved.sh 安装为 /usr/local/bin/jb（README 与 uninstall.sh 均引用该命令，原来从未安装）
7. **SHA256 校验提示** — Hysteria2/Cloudflared 无逐文件校验和时明确提示「跳过校验」，不再静默略过

---

## v5.1 - 2026-06-28 (Bug 修复)

### 🐛 Bug 修复

1. **`wget` 重定向修复** — `2>&1` 修正为 `2>/dev/null`
2. **UUID v4 格式修复** — 修正子串偏移错误，添加 variant 位设置，生成符合标准的 UUID
3. **bash 兼容性** — `${var,,}` 替换为 `tr '[:upper:]' '[:lower:]'`，兼容 bash 3.x
4. **openssl 输出解析** — 使用 `awk '{print $NF}'` 替代 `cut -d' ' -f2`，适配不同版本
5. **YAML 生成改进** — 使用 `printf '%b'` 替代 `echo -e`，避免命令替换中换行丢失
6. **防火墙规则持久化** — 添加 `iptables-save` / `netfilter-persistent save` 自动持久化
7. **防火墙支持 TCP** — `add_firewall_rule()` 新增 proto 参数，支持 TCP/UDP
8. **颜色变量修复** — uninstall.sh 中 `\033` 转义修正
9. **generate_password fallback** — 添加缺失的 `-x` 参数
10. **set_error_trap 改进** — 统一添加 `set -E` 确保 ERR trap 在函数内传播

### 📝 文档更新

- CHANGELOG.md 修正版本号与文件引用
- IMPROVEMENTS.md 移除不存在的功能描述
- README.md 版本号更新至 v5.1

---

## v5.0 - 2026-06-08

### 主要变更
- xray 二进制有效性校验
- 错误陷阱连锁修复
- set -u 兼容
- 版本统一、路径动态化
- GitHub API 兼容
- dnf 支持
- IPv6 支持
- 函数拆分

---

## v2.0.0 - 2026-05-23

### 主要变更
- 新增 `common.sh` 公共配置文件
- 实现模块间的显式依赖管理
- 改进节点信息存储格式（JSON）
- 添加文件权限严格控制
- 实现 sudo 权限检查
- 添加安全的随机数生成函数
- 添加下载文件完整性校验（SHA256）
- 改进错误处理机制
- 新增 `jb_improved.sh` 管理脚本
- 添加参数验证和命令自动补全
