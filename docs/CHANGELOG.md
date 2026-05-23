# jiaoben 项目更新日志 (2026-05-22)

本项目已由 **Manus AI (基于 GPT-4.1)** 进行全面升级，旨在提升脚本的健壮性、安全性、运维便利性和部署效率。

## 主要变更内容：

### `all-in-one.sh` (部署脚本)

1.  **Systemd 服务化**：
    - 彻底移除 `nohup` 方式，所有部署的服务（Xray, Hysteria, Cloudflared）现在都通过 **Systemd** 进行管理。
    - 自动创建并启用 `.service` 文件，支持开机自启、自动故障恢复和统一日志管理。
2.  **系统兼容性增强**：
    - 增加 `install_dependencies` 函数，自动检测 Linux 发行版（Ubuntu/Debian, CentOS/RHEL）并使用对应的包管理器安装缺失依赖（`curl`, `unzip`, `openssl`, `grep`, `sed`, `base64`, `coreutils`, `procps`, `jq`）。
3.  **部署效率优化**：
    - 优化了 Xray 和 Cloudflared 的下载逻辑，避免重复下载。
    - Cloudflared 隧道启动后，在获取 Argo 域名成功后，会将其转换为 Systemd 服务进行管理，提高稳定性。
4.  **端口检测优化**：
    - `get_random_port` 函数现在使用 `ss -tln` 进行更准确的端口占用检测。
5.  **代码结构优化**：
    - 引入 `create_service` 函数，封装 Systemd 服务创建逻辑，提高代码可读性和复用性。

### `jb.sh` (管理脚本)

1.  **Systemd 服务管理**：
    - 菜单选项更新，现在可以对所有节点服务进行 **状态检查**、**重启**、**停止** 和 **卸载**，所有操作均通过 `systemctl` 完成。
    - `SERVICES` 数组明确列出所有由 `all-in-one.sh` 创建的 Systemd 服务名称。
2.  **实时日志查看**：
    - 新增“查看实时服务日志”功能，用户可以选择特定服务，通过 `journalctl -f` 实时查看其日志输出，方便故障排查。
3.  **卸载逻辑增强**：
    - 卸载时会先停止并禁用所有 Systemd 服务，然后删除对应的 `.service` 文件和工作目录，清理更加彻底。
4.  **交互优化**：
    - 菜单选项更加清晰，操作提示更友好。

## 如何使用：

1.  **部署**：运行 `./all-in-one.sh` (确保已赋予执行权限)。
2.  **管理**：部署完成后，输入 `jb` 即可进入管理菜单。

---
