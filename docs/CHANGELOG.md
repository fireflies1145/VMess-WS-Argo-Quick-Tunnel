# jiaoben 项目更新日志

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
