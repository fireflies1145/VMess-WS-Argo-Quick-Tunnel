# jiaoben 项目更新日志

## v6.0 - 2026-06-07 (全面修复与安全加固)

### 🐛 Bug 修复

1. **`set -Eeuo pipefail` 替代 `set -uo pipefail`** — 添加 `errtrace` 使 trap ERR 在函数内生效
2. **全局错误陷阱** — 新增 `trap ERR` 在脚本级别捕获所有错误
3. **JSON 配置安全构建** — `deploy_argo()` 追加配置前先用 `validate_json()` 验证文件有效性
4. **`download_sha256()` 安全校验** — 独立函数验证 SHA256 格式（必须为 64 位十六进制）
5. **`update_component()` 函数调用修复** — 使用 `"${download_fn}"` 安全调用函数引用
6. **Argo 域名获取超时处理** — 超时后给出明确提示而非静默使用硬编码域名
7. **IP 获取失败检测** — `validate_ip()` 函数验证 IP 格式，失败时阻止生成无效节点链接
8. **防火墙规则持久化** — `add_firewall_rule()` 自动调用 `iptables-save` 持久化规则
9. **端口跳跃和自定义端口统一处理** — `add_firewall_rule()` 同时支持两种场景
10. **变量引用统一** — 所有变量使用 `${var}` 格式，防止歧义

### 💡 优化

1. **多源 IP 检测** — `get_public_ip()` 使用 5 个服务源自动 fallback（ifconfig.me, ipinfo.io, icanhazip.com, api.ipify.org, checkip.amazonaws.com）
2. **JSON 配置验证** — `validate_json()` 函数用 `jq empty` 验证配置文件有效性
3. **服务健康检查** — `health_check()` 函数在部署后验证服务是否正常运行
4. **日志轮转** — `rotate_argo_log()` 自动轮转超过 10MB 的 Argo 日志
5. **SHA256 下载优化** — `download_sha256()` 独立函数，格式验证，错误处理
6. **防火墙管理统一** — `add_firewall_rule()` 支持 UFW 和 iptables，自动持久化
7. **错误处理增强** — 所有函数添加明确的错误处理和返回值检查
8. **代码结构优化** — 函数职责更清晰，减少重复代码
9. **变量引用安全** — 所有字符串使用双引号包裹，防止 word splitting
10. **日志格式统一** — 所有日志使用统一的时间戳格式

### 📝 文档更新

- README.md 更新至 v6.0
- CHANGELOG.md 新增 v6.0 更新记录
- IMPROVEMENTS.md 新增 v6.0 改进说明
- SECURITY.md 保持不变（安全实践仍然适用）

---

## v5.0 - 2026-06-06

### 主要变更
- 版本统一、路径动态化
- GitHub API 兼容
- dnf 支持
- IPv6 支持
- 函数拆分
- 更新机制

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
