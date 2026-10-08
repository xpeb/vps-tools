# shadowsocks.sh

一个面向 Linux 服务器的 **Shadowsocks-Rust 极简管理脚本**。

重构后的版本只保留一条清晰路径：下载并校验 `ssserver` → 写入一个配置文件 → 交给一个服务后端运行。菜单和底层实现都尽量减少状态、重复逻辑和隐式副作用。

## 设计重点

- **极简 UI**：一行状态、两行菜单，不使用大型 ASCII 边框和冗长提示。
- **极简架构**：安装、配置和更新分别处理；服务启动、停止、重启共用服务抽象。
- **安全默认值**：默认 `2022-blake3-aes-128-gcm`、TCP/UDP 双栈，使用固定长度 Base64 PSK。
- **兼容服务后端**：优先使用 systemd，其次 OpenRC，最后使用轻量的直接进程模式。
- **保守防火墙策略**：不再自动插入 iptables 规则，避免重复规则和误修改；请自行放行服务器端口。
- **单一交互入口**：只保留菜单操作，避免额外的参数分支。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/shadowsocks.sh | bash
```

也可以先下载后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/shadowsocks.sh -o shadowsocks.sh
chmod +x shadowsocks.sh
sudo ./shadowsocks.sh
```

需要 root 权限。脚本会按系统包管理器补齐 `curl`、`tar`、`xz`、`jq` 和 `coreutils`。

## 极简菜单

```text
Shadowsocks-Rust
状态  运行中  1.23.4

[1] 安装          [2] 配置
[3] 更新          [4] 启动
[5] 停止          [6] 重启
[7] 信息          [8] 日志
[9] 卸载
[0] 退出
```

安装或配置时会依次询问端口、加密方式、传输模式和预共享密钥（PSK）；选择使用编号，回车保持当前值或自动生成合法密钥。

仅使用 Shadowsocks 2022 的三种加密方式：

- `2022-blake3-aes-128-gcm`：16 字节 PSK
- `2022-blake3-aes-256-gcm`：32 字节 PSK
- `2022-blake3-chacha20-poly1305`：32 字节 PSK

PSK 必须是对应长度的标准 Base64 密钥，不再使用普通密码。客户端也必须支持 SIP022 / Shadowsocks 2022，并使用同一种加密方式。

支持的传输模式：

- `tcp_only`
- `udp_only`
- `tcp_and_udp`（默认）

| 配置 | 默认值 |
| --- | --- |
| 端口 | `56789` |
| 加密 | `2022-blake3-aes-128-gcm` |
| 模式 | `tcp_and_udp` |
| 监听地址 | `::` |

首次使用选择“安装”，已安装后选择“配置”修改端口、加密方式、传输模式或 PSK；“信息”只显示当前配置和连接信息。

## 交互入口

脚本只提供交互菜单，不接受子命令或参数。直接运行后，所有安装、配置、更新、服务控制、日志和卸载操作都从菜单完成：

```bash
sudo ./shadowsocks.sh
```

## 底层结构

```text
入口
 ├─ 配置层：端口、密码、config.json
 ├─ 下载层：最新 Release、架构匹配、二进制校验
 └─ 服务层：svc(action) → systemd / OpenRC / direct
```

脚本只维护一个核心配置文件：

```text
/etc/shadowsocks-rust/config.json
```

程序和服务文件：

```text
/usr/local/bin/ssserver
/etc/systemd/system/shadowsocks-rust.service
/etc/init.d/shadowsocks-rust
```

实际使用哪一个服务文件由运行环境自动决定。没有 systemd 或 OpenRC 时，会使用 PID 文件和日志文件运行直接进程：

```text
/run/shadowsocks-rust.pid
/var/log/shadowsocks-rust.log
```

## 支持架构

- `x86_64` / `amd64`
- `aarch64` / `arm64`
- `armv7l` / `armhf`
- `i386` / `i686`

下载时会从 Shadowsocks-Rust 最新 Release 中选择匹配架构的静态包，先用官方 `.sha256` 文件完成 SHA256 校验，再确认支持全部三种 Shadowsocks 2022 加密方式。

## 网络与防火墙

脚本监听 IPv4/IPv6 通配地址，但不会擅自修改 iptables、UFW 或 firewalld。请按实际环境放行：

```text
<端口>/tcp
<端口>/udp
```

同时检查云厂商安全组和系统防火墙。配置和 SS 链接可在菜单中选择“信息”查看。

## 开源协议

MIT License。
