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
[7] 信息  [8] 日志  [9] ACME  [10] 卸载
选择 [q退出]:
```

安装或配置时询问公网端口、域名、ACME 邮箱和密码：

```text
端口 [8443]:
域名（必须已解析到本机）:
ACME 邮箱（可选，回车跳过）:
密码 [回车保持/生成]:
```

## 功能

- 安装、配置、更新、启动、停止、重启、信息、日志、ACME、卸载。
- 使用官方 `anytls-go` Release，不修改官方服务端协议实现。
- 自动使用 Let’s Encrypt 通过 HTTP-01 申请证书并配置自动续期。
- 使用 HAProxy 终止公网 TLS，再加密转发到本机的官方 AnyTLS 服务端。
- 自动获取官方最新 Release。
- 使用 GitHub Release API 提供的 SHA256 摘要校验安装包。
- 支持 `amd64` 和 `arm64` Linux VPS。
- 自动识别 systemd、OpenRC；没有服务管理器时使用直接进程模式。
- 信息页显示 IPv4、IPv6、域名、证书有效期和 `anytls://` 连接链接。
- 操作前自动清屏，不需要额外的“回车返回”。

默认配置：

| 配置 | 默认值 |
| --- | --- |
| 端口 | `8443` |
| 监听地址 | `:端口`（IPv4/IPv6 通配地址） |
| 协议 | AnyTLS |

AnyTLS 不使用 Shadowsocks 的加密方式或传输模式选项；客户端和服务端使用相同密码即可。脚本继续使用官方 `anytls-server`，官方服务端本身不提供证书参数，因此脚本通过 HAProxy 使用 ACME 证书作为公网 TLS 前端，再将 TLS 流量重新加密转发到 `127.0.0.1` 的官方 AnyTLS 服务端。

首次安装会申请 Let’s Encrypt 证书，并通过 systemd timer 或 cron 自动续期。证书申请使用 HTTP-01 校验，因此域名必须已经解析到本机，TCP 80 必须可以从公网访问；申请期间不能有其他程序占用 80 端口。公网 AnyTLS 端口默认为 `8443`，也可以输入 `443`。

生成的链接格式如下：

```text
anytls://密码@example.com:8443
```

首次安装会自动生成安全密码，也可以在配置页面手动输入 8-128 位字母、数字或 `. _ ~ -`。使用官方示例客户端时仍会跳过证书校验；使用支持证书校验的第三方客户端时，应使用域名连接并按客户端要求开启正常 TLS 校验。

## 防火墙

AnyTLS 公网 TLS 前端使用 TCP。证书申请还需要临时使用 TCP 80。请放行服务器防火墙和云厂商安全组中的 TCP 端口，例如：

```bash
ufw allow 8443/tcp
ufw allow 80/tcp
```

证书申请完成后仍建议保留 80/tcp，以便 HTTP-01 自动续期。

## 文件

```text
/etc/anytls/anytls-server   官方 AnyTLS 服务端程序
/etc/anytls/config          端口、域名、ACME 和密码，权限 600
/etc/anytls/certs/          ACME 证书、私钥和 HAProxy PEM
/etc/anytls/haproxy.cfg     HAProxy TLS 转发配置
/etc/anytls/acme/           acme.sh 账户和证书数据
/etc/anytls/version         当前版本
/var/log/anytls.log         官方 AnyTLS 后端日志
/var/log/anytls-proxy.log   HAProxy 日志
```
