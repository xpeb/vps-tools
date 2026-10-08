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

安装或配置时先选择证书方式：

```text
端口 [8443]:
证书方式
[1] 自签名（官方自动生成）
[2] ACME（Let's Encrypt）
选择 [1/2] [1]:
```

选择 ACME 后继续询问：

```text
域名（必须已解析到本机）:
ACME 邮箱（可选，回车跳过）:
```

最后输入密码：

```text
密码 [回车保持/生成]:
```

## 功能

- 安装、配置、更新、启动、停止、重启、信息、日志、卸载。
- 安装和配置的交互流程中可选择自签名或 ACME，不单独增加证书菜单项。
- 自签名模式直接使用官方服务端自动生成的自签名证书。
- ACME 模式自动申请并配置 Let’s Encrypt 证书。
- 使用官方 `anytls-go` Release，不修改官方服务端协议实现。
- ACME 模式使用 HAProxy 终止公网 TLS，再加密转发到本机的官方 AnyTLS 服务端。
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
| 证书方式 | 自签名 |

AnyTLS 不使用 Shadowsocks 的加密方式或传输模式选项；客户端和服务端使用相同密码即可。脚本继续使用官方 `anytls-server`，证书方式在安装或配置时选择：

- **自签名**：官方服务端直接监听公网端口，启动时自动生成短期自签名证书。不需要域名、HAProxy 或 TCP 80。
- **ACME**：通过 HTTP-01 申请 Let’s Encrypt 证书，由 HAProxy 使用证书接收公网 TLS，再加密转发到本机的官方 AnyTLS 服务端。

ACME 模式通过 systemd timer 或 cron 自动续期。证书申请期间，域名必须已经解析到本机，TCP 80 必须可以从公网访问，且不能有其他程序占用 80 端口。公网 AnyTLS 端口默认为 `8443`，也可以输入 `443`。

自签名模式生成的链接示例：

```text
anytls://密码@服务器IP:8443
```

ACME 模式生成的链接示例：

```text
anytls://密码@example.com:8443
```

首次安装会自动生成安全密码，也可以在配置页面手动输入 8-128 位字母、数字或 `. _ ~ -`。使用自签名模式时，客户端需要允许不校验证书；ACME 模式应使用域名连接并按客户端要求开启正常 TLS 校验。

## 防火墙

两种模式都使用 TCP。ACME 模式申请和续期证书还需要 TCP 80。自签名模式只需放行公网 AnyTLS 端口；ACME 模式还需放行 TCP 80。例如：

```bash
ufw allow 8443/tcp
ufw allow 80/tcp  # 仅 ACME 模式需要
```

## 文件

```text
/etc/anytls/anytls-server   官方 AnyTLS 服务端程序
/etc/anytls/config          端口、证书模式、域名和密码，权限 600
/etc/anytls/certs/          ACME 证书、私钥和 HAProxy PEM（ACME 模式）
/etc/anytls/haproxy.cfg     HAProxy TLS 转发配置（ACME 模式）
/etc/anytls/acme/           acme.sh 账户和证书数据（ACME 模式）
/etc/anytls/version         当前版本
/var/log/anytls.log         官方 AnyTLS 日志
/var/log/anytls-proxy.log   HAProxy 日志（ACME 模式）
```
