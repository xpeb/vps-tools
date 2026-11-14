# VPS Tools

轻量、极简、无冗余依赖的 Linux VPS 综合运维与代理管理工具箱。

---

## 🛠️ 工具列表

### 1. xray.sh — Xray 现代化轻量管理面板

> **快捷指令**：`xraym`

专为现代 Linux VPS 打造的极简 Xray 控制面板。单文件绿色运行，深度重构交互体验与配置安全引擎。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh)
```

#### ✨ 核心亮点

- **直觉式极简交互**：
  - **添加节点只需 2 步**：选协议、敲回车确认推荐端口，全套密钥/UUID/ShortID 瞬时自动生成并就绪，绝无繁琐连环追问；
  - **直观属性修改**：修改节点时以当前值为默认提示，直接敲回车保持不变，输入新值即刻热迁移更新；
  - **单线流程设计**：摒弃多层嵌套菜单，每个操作均可独立完成并一键回车返回。
- **现代化顶格排版 & 终端宽度自适应**：
  - 全界面统一顶格左对齐，去除生硬留白；
  - 动态感知终端尺寸（`draw_line`），虚线与表格随窗口宽度自适应铺满整屏，手机 SSH 客户端也绝不折行错位；
  - 规范统一的状态标识系统：`[成功]`、`[失败]`、`[警告]`、`[提示]`。
- **生产级配置事务引擎 (`mutate_config`)**：
  - **多层防护机制**：配置生成先写入独立临时目录，严格执行同协议端口冲突断言与 Xray 内核原生 `-test` 预检；
  - **原子更新与秒级回滚**：仅在预检完全通过后原子覆写目标配置并重启服务；若检测到底层异常或启动瞬崩，自动秒级回滚至上一次正常运行的历史备份；
  - **磁盘 0 残留**：基于隔离临时目录栈与 `trap` 垃圾回收机制，中断退出时全自动清理全部中间文件。
- **主流前沿协议矩阵**：
  - **VLESS-REALITY** (TCP + xtls-rprx-vision 流控，配置若缺失公钥自动调用底层反向推导)
  - **Hysteria 2** (UDP / QUIC / H3 极速抗封锁协议)
  - **Trojan-TLS** (OpenSSL 原生签发高强度 ECC Prime256v1 证书)
  - **Shadowsocks 2022** (`2022-blake3-aes-128-gcm` 工业标准现代对称加密)
  - **VMess-WS** (标准 WebSocket 伪装与路径回落)
- **多栈网络与一键聚合订阅**：
  - 自动嗅探服务器原生公网 IPv4 与 IPv6；
  - 输入 `sub` 一键导出全节点 Base64 聚合订阅源（IPv4 / IPv6 分开生成），主流客户端一键黏贴导入。
- **智能快捷命令与免 API 限流更新**：
  - 支持直接通过 `bash <(curl -fsSL ...)` 管道单行运行，自动容灾安装 `/usr/local/bin/xraym` 快捷指令；
  - 核心版本检查优先解析 Releases 302 重定向，彻底免除 GitHub API 60次/小时未鉴权限流困扰；
  - 严格以普通用户 `xray:xray` 降权守护运行，利用 `CAP_NET_BIND_SERVICE` 绑定低位端口，兼顾系统安全。

---

### 2. vps.sh — VPS 综合运维管理

> **快捷指令**：`vps`

涵盖 SSH 密钥与密码登录管理、端口修改、Fail2Ban 防爆破、BBR 拥塞控制、zRAM 动态内存压缩、Docker 运行环境管理与系统深度清理。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/vps.sh)
```

---

### 3. cliproxyapi.sh — CLIProxy API 管理器

> **快捷指令**：`cpapi`

CLIProxy API 服务全生命周期管理，本地安全回环绑定（`127.0.0.1:8317`），支持版本平滑升级回滚、配置备份与反代指引。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/cliproxyapi.sh)
```

---

## 📄 运行环境要求

- **操作系统**：Debian 11+ / Ubuntu 20.04+ / Alpine Linux 等常见发行版
- **系统架构**：x86_64 (amd64) / aarch64 (arm64) / armv7l
- **核心依赖**：`curl`、`jq`、`unzip`、`openssl`（脚本启动时会自动检查并无感补齐）
