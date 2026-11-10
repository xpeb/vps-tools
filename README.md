# VPS Tools

轻量、极简、无冗余依赖的 Linux VPS 综合运维工具集。

## 🛠️ 工具列表

### 1. vps.sh (VPS 综合管理)
快捷命令：`vps`

涵盖 SSH 密钥与密码登录管理、端口修改、Fail2Ban 防护、BBR 拥塞控制、zRAM 内存压缩、Docker 管理、系统深度清理等。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/vps.sh)
```

### 2. xray.sh (Xray 管理面板)
快捷命令：`xraym`

支持 VLESS (REALITY/RAW/XHTTP/Vision)、Hysteria 2、Trojan、Shadowsocks 2022、VMess、Socks5，非 root 安全降权运行，自签/ACME 证书自动化与节点配置备份迁移。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh)
```

### 3. cliproxyapi.sh (CLIProxy API 管理)
快捷命令：`cpapi`

CLIProxy API 服务生命周期管理、本地安全回环绑定（127.0.0.1:8317）、版本平滑升级回滚、配置备份与反代指引。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/cliproxyapi.sh)
```
