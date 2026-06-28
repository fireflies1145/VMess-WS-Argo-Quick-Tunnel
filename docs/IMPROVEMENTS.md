# jiaoben 项目改进日志

## 版本 5.1 - Bug 修复版本

**发布日期**: 2026-06-28  
**优化范围**: 关键 Bug 修复、兼容性改进

### 🎯 v5.1 主要改进

#### 1. UUID 生成修复
- ✅ 修正 `gen_uuid()` / `generate_uuid()` 子串偏移错误
- ✅ 正确设置 UUID v4 variant 位 (8/9/a/b)
- ✅ 生成的 UUID 现在符合 RFC 4122 标准

#### 2. bash 兼容性
- ✅ `${var,,}` 替换为 `tr '[:upper:]' '[:lower:]'`，兼容 bash 3.x+
- ✅ `wget 2>&1` 修正为 `2>/dev/null`

#### 3. 安全性增强
- ✅ `openssl dgst` 输出解析使用 `awk` 替代 `cut`，适配多版本
- ✅ `generate_password()` fallback 添加缺失的 `-x` 参数
- ✅ `add_firewall_rule()` 自动持久化 iptables 规则
- ✅ `add_firewall_rule()` 支持 TCP 协议参数

#### 4. 代码质量
- ✅ YAML 生成使用 `printf '%b'` 替代 `echo -e`，避免命令替换换行丢失
- ✅ `set_error_trap` 统一添加 `set -E`
- ✅ uninstall.sh 颜色变量转义修正

### 📁 文件变更

| 文件 | 变更说明 |
|------|---------|
| `run.sh` | wget修正、UUID修复、bash兼容、防火墙增强、YAML改进、版本号 v5.1 |
| `common.sh` | UUID修复、generate_password改进、set_error_trap统一 |
| `uninstall.sh` | 颜色变量转义修正 |
| `docs/CHANGELOG.md` | 版本号修正，移除不存在的功能描述 |
| `docs/IMPROVEMENTS.md` | 本文件更新 |
| `README.md` | 更新版本号至 v5.1 |

### 🔒 安全建议（仍然适用）

1. 定期更新组件版本
2. 监控服务日志
3. 定期检查防火墙规则
4. 备份重要配置文件

---

## 版本 2.0.0 - DeepSeek 深度优化版本

**发布日期**: 2026-05-23  
**优化工具**: DeepSeek V4 Pro (最大思考程度)

### 主要改进
- ✅ 新增 `common.sh` 公共配置文件
- ✅ 实现模块间的显式依赖管理
- ✅ 改进节点信息存储格式（JSON）
- ✅ 添加文件权限严格控制
- ✅ 实现 sudo 权限检查
- ✅ 添加安全的随机数生成函数
- ✅ 添加下载文件完整性校验（SHA256）
- ✅ 改进错误处理机制
- ✅ 新增 `jb_improved.sh` 管理脚本
- ✅ 添加参数验证和命令自动补全
