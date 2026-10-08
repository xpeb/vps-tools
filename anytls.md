# AnyTLS 管理脚本

基于 [anytls/anytls-go](https://github.com/anytls/anytls-go) 官方 Release，使用与 `shadowsocks.sh` 一致的极简交互界面。

## 使用

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/anytls.sh)
```

脚本只提供交互菜单，不接受子命令或参数：

```text
AnyTLS
状态  运行中  v0.0.13

[1] 安装  [2] 配置  [3] 更新
[4] 启动  [5] 停止  [6] 重启
[7] 信息  [8] 日志  [9] 卸载
选择 [q退出]:
```

安装或配置时询问端口、SNI 和密码：

```text
端口 [8443]:
SNI [可选，回车关闭]:
密码 [回车保持/生成]:
```

## 功能

- 安装、配置、更新、启动、停止、重启、信息、日志、卸载。
- 自动获取官方最新 Release。
- 使用 GitHub Release API 提供的 SHA256 摘要校验安装包。
- 支持 `amd64` 和 `arm64` Linux VPS。
- 自动识别 systemd、OpenRC；没有服务管理器时使用直接进程模式。
- 信息页同时显示 IPv4、IPv6、SNI 和对应的 `anytls://` 连接链接。
- 操作前自动清屏，不需要额外的“回车返回”。

默认配置：

| 配置 | 默认值 |
| --- | --- |
| 端口 | `8443` |
| 监听地址 | `:端口`（IPv4/IPv6 通配地址） |
| 协议 | AnyTLS |

AnyTLS 不使用 Shadowsocks 的加密方式或传输模式选项；客户端和服务端使用相同密码即可。SNI 是客户端 TLS 连接参数，脚本会将其写入生成的 `anytls://` 链接；留空则关闭 SNI，已配置时输入 `-` 可清除。首次安装会自动生成安全密码，也可以在配置页面手动输入 8-128 位字母、数字或 `. _ ~ -`。

配置了 SNI 时，生成的链接格式如下：

```text
anytls://密码@服务器地址:8443/?sni=www.example.com
```

## 防火墙

AnyTLS 使用 TCP。请放行服务器防火墙和云厂商安全组中的 TCP 端口，例如：

```bash
ufw allow 8443/tcp
```

## 文件

```text
/etc/anytls/anytls-server   服务端程序
/etc/anytls/config          端口、SNI 和密码，权限 600
/etc/anytls/version         当前版本
/var/log/anytls.log         direct/OpenRC 日志
```
