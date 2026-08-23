# jiaoben 项目更新日志

## v5.4 - 2026-08-23 (Bug 修复)

### 🔴 严重修复

1. **Hysteria2 节点链接主机名错误** — 自签/自定义证书模式下，链接的 `@` 后写的是伪装域名（如 `www.bing.com`）而非服务器地址，导致客户端去连接微软的服务器，节点必然不通。现按证书模式区分：ACME 用已解析的域名，其余用公网 IP（IPv6 自动加方括号），伪装域名只保留在 `sni` 参数中
2. **端口跳跃 `mport` 参数落入 fragment** — 原代码在已含 `#Hysteria2` 的链接后追加 `&mport=...`，参数变成备注名的一部分，客户端收不到。现改为先拼完 query 再接 `#备注`

### 🟡 其它修复

3. **节点信息不再被误清空** — 原逻辑单独部署任一协议都会清空整个节点文件，导致先前部署的节点链接丢失（服务仍在运行却查不到链接）。改为 TSV 存储 + 按协议名去重覆盖，单独部署互不影响，同协议重复部署自动更新
4. **Argo inbound 无限累积** — 每次部署 Argo 都往 config.json 追加 ws inbound，旧的永不清理，配置膨胀且可能出现重复端口导致 Xray `address already in use` 启动失败。现在追加前先剔除旧的 ws inbound，并加 `argo-ws` tag
5. **Argo 旧日志导致读到过期域名** — 部署前清空 argo.log，避免 `get_argo_domain` 匹配到上一次的隧道域名
6. **jb 管理工具安装后不可用** — jb_improved.sh 强制要求同目录存在 common.sh，装到 /usr/local/bin 后必然报错退出。现将两者一并安装至 /usr/local/lib/jiaoben/，/usr/local/bin/jb 为包装脚本；jb 自身也会回退查找系统路径
7. **`bash <(curl ...)` 方式下 SCRIPT_DIR 失效** — 该方式（README 主推）下 BASH_SOURCE 为 /dev/fd/N，同目录文件不可用，jb 永远装不上。现检测到此情况时自动从仓库拉取所需文件
8. **卸载不清理防火墙规则** — 新增 `cleanup_firewall_rules`，卸载时移除本脚本添加的 TCP 443 ACCEPT、UDP 区间 ACCEPT 与端口跳跃 DNAT，并同步持久化；同时删除 jb 与 /usr/local/lib/jiaoben
9. **`pkill -9 -f xray` 误杀风险** — 原先按进程名模糊匹配，会连带杀掉用户自建的其它 xray/hysteria/cloudflared 实例。改为按本脚本安装的完整二进制路径锚定匹配
10. **包管理器支持补齐** — install_deps 新增 dnf / zypper / pacman / apk 分支（CHANGELOG 早在 v5.0 就声称支持 dnf，实际并无），并对硬依赖 jq 缺失时明确报错
11. **shellcheck 清零** — 补齐 15 处 `read -r`，移除未使用的 BLUE 变量，添加必要的 source 指令

### ✅ 新增

- `tests/run_tests.sh` — 32 项回归测试，覆盖上述所有已修复 bug（不需 root、不联网、不改动系统）

---

## v5.3 - 2026-08-12

### ✨ 变更

- **REALITY 伪装目标改为 `www.amd.com`**（原 `www.microsoft.com`）—— 已实测该站支持 TLS 1.3 / HTTP/2 / X25519，证书由 DigiCert GeoTrust 签发
- README 与菜单文案同步更新，并新增「REALITY 伪装目标」说明章节

---

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
