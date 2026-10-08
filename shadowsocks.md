# shadowsocks.sh

一个面向 Linux 服务器的 **Shadowsocks-Rust 极简管理脚本**。

重构后的版本只保留一条清晰路径：下载并校验 `ssserver` → 写入一个配置文件 → 交给一个服务后端运行。菜单和底层实现都尽量减少状态、重复逻辑和隐式副作用。

## 设计重点

- **极简 UI**：一行状态、两行菜单，不使用大型 ASCII 边框和冗长提示。
- **极简架构**：安装与更新共用下载/校验流程；启动、停止、重启共用服务抽象。
- **安全默认值**：默认 `aes-128-gcm`、TCP/UDP 双栈，配置文件权限为 `600`。
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

[1] 安装/配置  [2] 更新  [3] 启动  [4] 停止
[5] 重启       [6] 配置  [7] 日志  [8] 卸载
[0] 退出
```

安装时只询问端口和密码，默认值如下：

| 配置 | 默认值 |
| --- | --- |
| 端口 | `56789` |
| 加密 | `aes-128-gcm` |
| 模式 | `tcp_and_udp` |
| 监听地址 | `::` |

再次进入“安装 / 配置”只会修改配置并重启服务，不会重复下载程序。

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

下载时会从 Shadowsocks-Rust 最新 Release 中选择匹配架构的静态包，先用官方 `.sha256` 文件完成 SHA256 校验，再执行 `ssserver --help` 确认支持 `aes-128-gcm`。

## 网络与防火墙

脚本监听 IPv4/IPv6 通配地址，但不会擅自修改 iptables、UFW 或 firewalld。请按实际环境放行：

```text
<端口>/tcp
<端口>/udp
```

同时检查云厂商安全组和系统防火墙。配置和 SS 链接可在菜单中选择“配置”查看。

## 开源协议

MIT License。
