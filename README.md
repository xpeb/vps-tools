# vps.sh

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/vps.sh)
```

# bbr.sh

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/bbr.sh)
```

# sing-box.sh

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/sing-box.sh)
```

支持 Debian/Ubuntu（运行中的 systemd）与 Alpine（运行中的 OpenRC），需要 root 和 Bash ≥ 4.3；Alpine 请先执行 `apk add bash`。脚本自动补齐 curl、jq、OpenSSL、iproute2、flock 等依赖，管理 sing-box ≥ 1.14.0。

菜单和七种协议保持原有用法；Snell 支持 v5（可选 HTTP 混淆）和 v6。入站变更成功后自动启动或重启；删除最后一个入站时停止；仅改备注不会重启。升级保持原来的运行状态。安装仅启用开机自启，添加入站后启动。

自签名 TLS 的 SNI 默认使用 `www.gnu.org`，可在向导中替换；该域名当前解析直达 Free Software Foundation 的服务器，未发现 CDN 接入迹象。生成的仍为自签名证书。域名证书需填写自己控制且解析到 VPS 的域名。Hysteria2/TUIC 的公网连通性还需要 VPS 与客户端之间的路径允许双向 UDP。

下载与候选内核暂存在 `/var/tmp`，结束后自动清理，避免小容量 `/run` tmpfs 导致安装失败；进程锁仍放在 `/run`。内核版本信息缓存在私有锁目录中，二进制变化后自动失效，减少重复启动面板时的内核加载；卸载时清除缓存。

可设置 `GH_PROXY` 作为 GitHub 下载地址的前缀；官方 SHA-256 摘要始终从 `api.github.com` 获取。无法获取官方摘要时，可通过 `SINGBOX_SHA256` 指定下载压缩包的 64 位十六进制摘要。

配置仍位于 `/etc/sing-box`，现有 `inbounds/*.json` 无需迁移。每次变更先暂存、校验并备份，服务验证成功后才提交。失败或可捕获的中断会恢复原文件和原服务状态；强制结束后，下次运行会检测并恢复遗留事务。服务状态检查只确认进程持续运行，不代表外部网络和 ACME 签发一定成功。

自动恢复失败时会停用修改功能，保留并显示 `/etc/sing-box/.transactions/txn.*` 的路径。可用 `jq . /etc/sing-box/.transactions/txn.XXXXXXXX/manifest.json` 查看阶段、原服务状态和目标文件；`backups/<序号>` 对应 `paths` 数组中同一序号的原文件。修复磁盘、权限或服务问题后重新运行脚本重试恢复。恢复完成前请保留整个事务目录。旧版 `.bak`、`.certbak` 和 `.old` 不参与自动恢复。软件依赖和专用系统用户属于准备步骤，失败时允许保留；完整卸载时可一并清理专用用户与配置。

`source sing-box.sh` 只加载函数，不检查 root、不安装依赖、不修改文件或 shell 设置。静态检查：

```bash
bash -n sing-box.sh
shellcheck sing-box.sh
```
