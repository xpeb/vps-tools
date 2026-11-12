#!/usr/bin/env bash
set -o pipefail

CONF_DIR="/usr/local/etc/xray"
CONF="$CONF_DIR/config.json"
CERTS_DIR="$CONF_DIR/certs"
BIN="/usr/local/bin/xray"
SVC_NAME="xray"

# 终端样式 (极简冷色调)
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_CYAN="\033[36m"
C_GREEN="\033[32m"
C_RED="\033[31m"

# 全局缓存 IP
PUB_IPV4=""
PUB_IPV6=""

# 1. 基础辅助与环境检测 (全部统一左对齐)
ok()   { echo -e "${C_GREEN}✓${C_RESET} $*"; }
err()  { echo -e "${C_RED}✗${C_RESET} $*" >&2; }
info() { echo -e "${C_CYAN}›${C_RESET} $*"; }
die()  { err "$*"; exit 1; }

ARCH="64"
[[ "$(uname -m)" =~ arm64|aarch64 ]] && ARCH="arm64-v8a"

check_deps() {
    local missing=""
    for cmd in curl unzip openssl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=" $cmd"
    done
    if [ -n "$missing" ]; then
        info "安装必要依赖:${missing}..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk update -q && apk add -q $missing
        fi
    fi
}

ask() {
    local prompt="$1" def="$2" val=""
    read -rp "› ${prompt} [${def}]: " val
    echo "${val:-$def}"
}

rand_port() {
    while :; do
        local p=$((RANDOM % 55535 + 10000))
        if ! ss -tlun 2>/dev/null | grep -q ":${p}\b"; then
            echo "$p"
            break
        fi
    done
}

refresh_ips() {
    [ -n "$PUB_IPV4" ] || PUB_IPV4=$(curl -fs4 -m 2 https://api.ipify.org 2>/dev/null || curl -fs4 -m 2 https://icanhazip.com 2>/dev/null || echo "")
    [ -n "$PUB_IPV6" ] || PUB_IPV6=$(curl -fs6 -m 2 https://api6.ipify.org 2>/dev/null || curl -fs6 -m 2 https://icanhazip.com 2>/dev/null || echo "")
}

get_connect_host() {
    refresh_ips
    if [ -n "$PUB_IPV4" ]; then
        echo "$PUB_IPV4"
    elif [ -n "$PUB_IPV6" ]; then
        echo "[${PUB_IPV6}]"
    else
        echo "127.0.0.1"
    fi
}

tune_system() {
    local cur_rmem; cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    if [ "$cur_rmem" -lt 26214400 ]; then
        sysctl -w net.core.rmem_max=26214400 net.core.wmem_max=26214400 >/dev/null 2>&1 || true
    fi
}

enable_bbr() {
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw "bbr"; then
        echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
        sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
    fi
    local cur; cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "关闭")
    if [[ "$cur" == *"bbr"* ]]; then
        ok "BBR 状态: 开启"
    else
        err "BBR 状态: 关闭"
    fi
}

# 2. 服务管理与初始化
init_env() {
    mkdir -p "$CONF_DIR" "$CERTS_DIR"
    if [ ! -s "$CONF" ]; then
        echo '{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "fc00::/7", "fe80::/10"], "outboundTag": "block"}]}
}' > "$CONF"
    fi
}

svc() {
    local act="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl "$act" "$SVC_NAME" 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$SVC_NAME" "$act" 2>/dev/null || true
    else
        pkill -x xray 2>/dev/null || true
        [ "$act" = "start" ] || [ "$act" = "restart" ] && nohup "$BIN" run -c "$CONF" >/dev/null 2>&1 &
    fi
}

is_running() { pgrep -x xray >/dev/null 2>&1; }

install_service() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Core
After=network.target

[Service]
ExecStart=${BIN} run -c ${CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable xray 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        cat << EOF > /etc/init.d/xray
#!/sbin/openrc-run
description="Xray Core"
command="${BIN}"
command_args="run -c ${CONF}"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default 2>/dev/null || true
    fi
}

# 3. 核心安装与更新
install_core() {
    echo ""
    info "查询 Xray 最新版本..."
    local ver
    ver=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
    { [ -z "$ver" ] || [ "$ver" = "null" ]; } && ver="v25.1.30"
    info "下载目标版本: ${ver} (${ARCH})..."

    local url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${ARCH}.zip"
    local tmp; tmp=$(mktemp -d)
    if ! curl -fsSL "$url" -o "$tmp/xray.zip"; then
        rm -rf "$tmp"; err "核心下载失败，请检查网络"; return 1
    fi
    mkdir -p /usr/local/share/xray
    unzip -qo "$tmp/xray.zip" xray geoip.dat geosite.dat -d "$tmp/" 2>/dev/null || unzip -qo "$tmp/xray.zip" xray -d "$tmp/"
    install -m 755 "$tmp/xray" "$BIN"
    [ -f "$tmp/geoip.dat" ] && install -m 644 "$tmp/geoip.dat" /usr/local/share/xray/
    [ -f "$tmp/geosite.dat" ] && install -m 644 "$tmp/geosite.dat" /usr/local/share/xray/
    rm -rf "$tmp"

    init_env
    install_service
    tune_system
    ok "Xray 核心已就绪 (${ver})"
}

# 4. 证书自签 (针对 Trojan / TLS 等)
ensure_self_cert() {
    local domain="${1:-www.nvidia.com}"
    local crt="$CERTS_DIR/cert.crt" key="$CERTS_DIR/priv.key"
    if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
            -keyout "$key" -out "$crt" -subj "/CN=${domain}" >/dev/null 2>&1
        chmod 600 "$key" "$crt" 2>/dev/null || true
    fi
}

# 5. 配置检验与原子替换
apply_config_test() {
    local tmp_cfg="$1" err_msg=""
    if err_msg=$("$BIN" run -test -format=json -c "$tmp_cfg" 2>&1); then
        mv "$tmp_cfg" "$CONF"
        chmod 600 "$CONF"
        svc restart
        ok "配置已验证并加载"
        return 0
    else
        if grep -q '"protocol": *"hysteria"' "$tmp_cfg" 2>/dev/null && [[ "$err_msg" == *"unknown config id: hysteria"* || "$err_msg" == *"unknown transport protocol: hysteria"* ]]; then
            mv "$tmp_cfg" "$CONF"
            chmod 600 "$CONF"
            svc restart
            ok "配置已保存加载 (注: 当前核心提示非原生 hysteria 协议)"
            return 0
        fi
        rm -f "$tmp_cfg"
        err "配置校验失败，已放弃更改"
        [ -n "$err_msg" ] && echo -e "${C_DIM}${err_msg}${C_RESET}"
        return 1
    fi
}

apply_inbound() {
    local inbound_json="$1" tmp_cfg
    tmp_cfg="$(mktemp).json"
    jq --argjson inb "$inbound_json" '.inbounds += [$inb]' "$CONF" > "$tmp_cfg"
    apply_config_test "$tmp_cfg"
}

# 6. 预设节点生成器 (严格按照 Xray 官方文档规范)
add_node() {
    [ ! -f "$BIN" ] && { err "请先安装 Xray 核心 (选项 7)"; return 1; }
    init_env

    echo ""
    echo -e "${C_BOLD}入站协议${C_RESET}"
    echo -e "${C_CYAN}1)${C_RESET} VLESS"
    echo -e "${C_CYAN}2)${C_RESET} Hysteria"
    echo -e "${C_CYAN}3)${C_RESET} Trojan"
    echo -e "${C_CYAN}4)${C_RESET} Shadowsocks"
    echo -e "${C_CYAN}5)${C_RESET} VMess"
    echo ""

    local choice; choice=$(ask "选择协议 [1-5]" "1")
    local def_p; def_p=$(rand_port)
    local port; port=$(ask "监听端口" "$def_p")
    local host; host=$(get_connect_host)
    local inb_data="" link="" remark=""

    case "$choice" in
        1) # VLESS-Reality (Vision 或 XHTTP)
            local trans_mode; trans_mode=$(ask "传输方式 [1: Vision, 2: XHTTP]" "1")
            local sni; sni=$(ask "伪装域名 (SNI)" "www.nvidia.com")
            local keys; keys=$("$BIN" x25519)
            local priv; priv=$(awk -F': *' '/[Pp]rivate[ ]?[Kk]ey/{print $2}' <<< "$keys" | tr -d ' \r\n')
            local pub; pub=$(awk -F': *' '/[Pp]ublic[ ]?[Kk]ey/{print $2}' <<< "$keys" | tr -d ' \r\n')
            local sid; sid=$(openssl rand -hex 4)
            local uid; uid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

            if [ "$trans_mode" = "2" ]; then
                # XHTTP 模式 (严格官方规范，无 flow)
                local path; path=$(ask "XHTTP 路径" "/xhttp-$(openssl rand -hex 3)")
                remark="VLESS-XHTTP-${port}"
                inb_data=$(jq -n \
                    --arg port "$port" --arg uid "$uid" --arg priv "$priv" --arg pbk "$pub" --arg sni "$sni" --arg sid "$sid" --arg path "$path" --arg rmk "$remark" \
                    '{
                        listen: "::",
                        port: ($port|tonumber),
                        protocol: "vless",
                        tag: $rmk,
                        settings: {
                            clients: [{id: $uid}],
                            decryption: "none"
                        },
                        streamSettings: {
                            network: "xhttp",
                            security: "reality",
                            xhttpSettings: {
                                path: $path,
                                host: $sni,
                                mode: "auto"
                            },
                            realitySettings: {
                                show: false,
                                dest: ($sni + ":443"),
                                xver: 0,
                                serverNames: [$sni],
                                privateKey: $priv,
                                shortIds: [$sid]
                            }
                        },
                        sniffing: {
                            enabled: true,
                            destOverride: ["http", "tls", "quic"]
                        },
                        _meta: {proto: "vless", trans: "xhttp", sec: "reality", pbk: $pbk, sni: $sni, sid: $sid, uid: $uid, path: $path}
                    }')
                apply_inbound "$inb_data" || return 1
                local enc_path; enc_path=$(printf '%s' "$path" | jq -sRr @uri)
                link="vless://${uid}@${host}:${port}?security=reality&encryption=none&pbk=${pub}&headerType=none&type=xhttp&path=${enc_path}&mode=auto&sni=${sni}&sid=${sid}#${remark}"
            else
                # Vision 模式 (严格官方 RAW + Vision 规范)
                remark="VLESS-Reality-${port}"
                inb_data=$(jq -n \
                    --arg port "$port" --arg uid "$uid" --arg priv "$priv" --arg pbk "$pub" --arg sni "$sni" --arg sid "$sid" --arg rmk "$remark" \
                    '{
                        listen: "::",
                        port: ($port|tonumber),
                        protocol: "vless",
                        tag: $rmk,
                        settings: {
                            clients: [{id: $uid, flow: "xtls-rprx-vision"}],
                            decryption: "none"
                        },
                        streamSettings: {
                            network: "raw",
                            security: "reality",
                            realitySettings: {
                                show: false,
                                dest: ($sni + ":443"),
                                xver: 0,
                                serverNames: [$sni],
                                privateKey: $priv,
                                shortIds: [$sid]
                            }
                        },
                        sniffing: {
                            enabled: true,
                            destOverride: ["http", "tls", "quic"]
                        },
                        _meta: {proto: "vless", trans: "raw", sec: "reality", pbk: $pbk, sni: $sni, sid: $sid, uid: $uid, flow: "xtls-rprx-vision"}
                    }')
                apply_inbound "$inb_data" || return 1
                link="vless://${uid}@${host}:${port}?security=reality&encryption=none&pbk=${pub}&headerType=none&type=raw&flow=xtls-rprx-vision&sni=${sni}&sid=${sid}#${remark}"
            fi
            ;;

        2) # Hysteria 2
            local sni; sni=$(ask "伪装域名 (SNI)" "www.nvidia.com")
            ensure_self_cert "$sni"
            tune_system
            local pass; pass=$(openssl rand -hex 8)
            pass=$(ask "认证密码" "$pass")
            remark="Hy2-${port}"

            inb_data=$(jq -n \
                --arg port "$port" --arg pass "$pass" --arg crt "$CERTS_DIR/cert.crt" --arg key "$CERTS_DIR/priv.key" --arg sni "$sni" --arg rmk "$remark" \
                '{
                    listen: "::",
                    port: ($port|tonumber),
                    protocol: "hysteria",
                    tag: $rmk,
                    settings: {
                        version: 2,
                        users: [{auth: $pass}]
                    },
                    streamSettings: {
                        network: "hysteria",
                        hysteriaSettings: {version: 2},
                        security: "tls",
                        tlsSettings: {
                            certificates: [{certificateFile: $crt, keyFile: $key}],
                            alpn: ["h3"]
                        }
                    },
                    _meta: {proto: "hysteria", pass: $pass, sni: $sni}
                }')
            apply_inbound "$inb_data" || return 1
            link="hysteria2://${pass}@${host}:${port}/?insecure=1&sni=${sni}#${remark}"
            ;;

        3) # Trojan-TLS (严格官方 Trojan TLS 规范)
            local domain; domain=$(ask "伪装域名 (自签)" "www.nvidia.com")
            ensure_self_cert "$domain"
            local pass; pass=$(openssl rand -hex 8)
            remark="Trojan-${port}"

            inb_data=$(jq -n \
                --arg port "$port" --arg pass "$pass" --arg crt "$CERTS_DIR/cert.crt" --arg key "$CERTS_DIR/priv.key" --arg domain "$domain" --arg rmk "$remark" \
                '{
                    listen: "::",
                    port: ($port|tonumber),
                    protocol: "trojan",
                    tag: $rmk,
                    settings: {
                        clients: [{password: $pass}]
                    },
                    streamSettings: {
                        network: "raw",
                        security: "tls",
                        tlsSettings: {
                            certificates: [{certificateFile: $crt, keyFile: $key}],
                            serverName: $domain
                        }
                    },
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls"]
                    },
                    _meta: {proto: "trojan", pass: $pass, sni: $domain}
                }')
            apply_inbound "$inb_data" || return 1
            link="trojan://${pass}@${host}:${port}?security=tls&allowInsecure=1&sni=${domain}#${remark}"
            ;;

        4) # Shadowsocks 2022 (严格官方 Shadowsocks 2022 规范)
            local method="2022-blake3-aes-128-gcm"
            local pass; pass=$(openssl rand -base64 16)
            remark="SS-${port}"

            inb_data=$(jq -n \
                --arg port "$port" --arg pass "$pass" --arg method "$method" --arg rmk "$remark" \
                '{
                    listen: "::",
                    port: ($port|tonumber),
                    protocol: "shadowsocks",
                    tag: $rmk,
                    settings: {
                        method: $method,
                        password: $pass,
                        network: "tcp,udp"
                    },
                    streamSettings: {
                        network: "raw"
                    },
                    _meta: {proto: "shadowsocks", method: $method, pass: $pass}
                }')
            apply_inbound "$inb_data" || return 1
            local b64_auth; b64_auth=$(printf '%s:%s' "$method" "$pass" | base64 | tr -d '\n')
            link="ss://${b64_auth}@${host}:${port}#${remark}"
            ;;

        5) # VMess-WS (严格官方 VMess + WebSocket 规范)
            local path; path=$(ask "WebSocket 路径" "/ws-$(openssl rand -hex 3)")
            local uid; uid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
            remark="VMess-WS-${port}"

            inb_data=$(jq -n \
                --arg port "$port" --arg uid "$uid" --arg path "$path" --arg rmk "$remark" \
                '{
                    listen: "::",
                    port: ($port|tonumber),
                    protocol: "vmess",
                    tag: $rmk,
                    settings: {
                        clients: [{id: $uid, alterId: 0}]
                    },
                    streamSettings: {
                        network: "ws",
                        security: "none",
                        wsSettings: {path: $path}
                    },
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls"]
                    },
                    _meta: {proto: "vmess", uid: $uid, path: $path}
                }')
            apply_inbound "$inb_data" || return 1
            local vmess_json; vmess_json=$(jq -cn \
                --arg ps "$remark" --arg add "$host" --arg port "$port" --arg id "$uid" --arg path "$path" \
                '{v: "2", ps: $ps, add: $add, port: ($port|tonumber), id: $id, aid: 0, net: "ws", type: "none", host: "", path: $path, tls: ""}')
            local b64_vmess; b64_vmess=$(printf '%s' "$vmess_json" | base64 | tr -d '\n')
            link="vmess://${b64_vmess}"
            ;;

        *) err "无效选项"; return 1 ;;
    esac

    echo ""
    ok "节点添加成功:"
    echo -e "${C_CYAN}${link}${C_RESET}\n"
    read -rp "按回车键继续..." _
}

# 7. 修改节点功能
edit_node() {
    [ ! -f "$CONF" ] && { err "配置文件不存在"; return 1; }
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { info "暂无节点可修改"; read -rp "按回车键返回..." _; return 0; }

    echo ""
    echo -e "${C_BOLD}修改入站节点${C_RESET}"
    jq -c '.inbounds | to_entries[]' "$CONF" | while read -r item; do
        local idx; idx=$(jq -r '.key' <<< "$item")
        local p; p=$(jq -r '.value.port' <<< "$item")
        local tag; tag=$(jq -r '.value.tag // .value._meta.proto // "node"' <<< "$item")
        local trans; trans=$(jq -r '.value.streamSettings.network // "raw"' <<< "$item")
        echo -e "[${C_CYAN}${idx}${C_RESET}] ${tag} ${C_DIM}(端口: ${p} | 传输: ${trans})${C_RESET}"
    done
    echo ""

    local sel; sel=$(ask "输入要修改的节点编号 (回车返回)" "")
    [ -z "$sel" ] && return 0

    local target; target=$(jq -c --argjson i "$sel" '.inbounds[$i] // empty' "$CONF" 2>/dev/null)
    [ -z "$target" ] && { err "无效编号"; read -rp "按回车键返回..." _; return 1; }

    local cur_port; cur_port=$(jq -r '.port' <<< "$target")
    local cur_proto; cur_proto=$(jq -r '.protocol' <<< "$target")
    local cur_trans; cur_trans=$(jq -r '.streamSettings.network // "raw"' <<< "$target")
    local meta; meta=$(jq -r '._meta // {}' <<< "$target")

    echo ""
    info "正在修改节点 [${sel}] (${cur_proto}/${cur_trans}):"
    local new_port; new_port=$(ask "监听端口" "$cur_port")

    local tmp_cfg; tmp_cfg="$(mktemp).json"
    jq --argjson i "$sel" --arg port "$new_port" \
        '.inbounds[$i].port = ($port|tonumber) | .inbounds[$i].tag = (.inbounds[$i].tag | sub("-[0-9]+$"; "-" + $port))' "$CONF" > "$tmp_cfg"

    case "$cur_proto" in
        vless)
            local cur_sni; cur_sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名 (SNI)" "$cur_sni")
            local jq_filter='.inbounds[$i].streamSettings.realitySettings.serverNames = [$sni] | .inbounds[$i].streamSettings.realitySettings.dest = ($sni + ":443") | .inbounds[$i]._meta.sni = $sni'

            if [ "$cur_trans" = "xhttp" ]; then
                local cur_path; cur_path=$(jq -r '.path // "/xhttp"' <<< "$meta")
                local new_path; new_path=$(ask "XHTTP 路径" "$cur_path")
                jq_filter+=' | .inbounds[$i].streamSettings.xhttpSettings.path = $path | .inbounds[$i].streamSettings.xhttpSettings.host = $sni | .inbounds[$i]._meta.path = $path'
                jq --argjson i "$sel" --arg sni "$new_sni" --arg path "$new_path" "$jq_filter" "$tmp_cfg" > "${tmp_cfg}.2" && mv "${tmp_cfg}.2" "$tmp_cfg"
            else
                jq --argjson i "$sel" --arg sni "$new_sni" "$jq_filter" "$tmp_cfg" > "${tmp_cfg}.2" && mv "${tmp_cfg}.2" "$tmp_cfg"
            fi
            ;;
        trojan)
            local cur_sni; cur_sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名" "$cur_sni")
            ensure_self_cert "$new_sni"
            jq --argjson i "$sel" --arg sni "$new_sni" \
                '.inbounds[$i].streamSettings.tlsSettings.serverName = $sni | .inbounds[$i]._meta.sni = $sni' "$tmp_cfg" > "${tmp_cfg}.2" && mv "${tmp_cfg}.2" "$tmp_cfg"
            ;;
        hysteria)
            local cur_pass; cur_pass=$(jq -r '.pass // ""' <<< "$meta")
            local new_pass; new_pass=$(ask "认证密码" "$cur_pass")
            local cur_sni; cur_sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名 (SNI)" "$cur_sni")
            ensure_self_cert "$new_sni"
            jq --argjson i "$sel" --arg pass "$new_pass" --arg sni "$new_sni" \
                '.inbounds[$i].settings.users[0].auth = $pass | .inbounds[$i]._meta.pass = $pass | .inbounds[$i]._meta.sni = $sni' "$tmp_cfg" > "${tmp_cfg}.2" && mv "${tmp_cfg}.2" "$tmp_cfg"
            ;;
        shadowsocks)
            local cur_pass; cur_pass=$(jq -r '.pass // ""' <<< "$meta")
            local new_pass; new_pass=$(ask "密码" "$cur_pass")
            jq --argjson i "$sel" --arg pass "$new_pass" \
                '.inbounds[$i].settings.password = $pass | .inbounds[$i]._meta.pass = $pass' "$tmp_cfg" > "${tmp_cfg}.2" && mv "${tmp_cfg}.2" "$tmp_cfg"
            ;;
        vmess)
            local cur_path; cur_path=$(jq -r '.path // "/ws"' <<< "$meta")
            local new_path; new_path=$(ask "WebSocket 路径" "$cur_path")
            jq --argjson i "$sel" --arg path "$new_path" \
                '.inbounds[$i].streamSettings.wsSettings.path = $path | .inbounds[$i]._meta.path = $path' "$tmp_cfg" > "${tmp_cfg}.2" && mv "${tmp_cfg}.2" "$tmp_cfg"
            ;;
    esac

    if apply_config_test "$tmp_cfg"; then
        ok "节点 [${sel}] 已成功修改并重启生效"
    fi
    read -rp "按回车键继续..." _
}

# 8. 节点查看与链接输出
show_nodes() {
    [ ! -f "$CONF" ] && { err "配置文件不存在"; return 1; }
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        info "暂无配置任何节点"
        read -rp "按回车键返回..." _
        return 0
    fi

    echo ""
    echo -e "${C_BOLD}当前节点列表 [${count}]${C_RESET}"
    local host; host=$(get_connect_host)

    jq -c '.inbounds | to_entries[]' "$CONF" | while read -r item; do
        local idx; idx=$(jq -r '.key' <<< "$item")
        local p; p=$(jq -r '.value.port' <<< "$item")
        local proto; proto=$(jq -r '.value.protocol' <<< "$item")
        local tag; tag=$(jq -r '.value.tag // .value._meta.proto // "node"' <<< "$item")
        local net; net=$(jq -r '.value.streamSettings.network // "raw"' <<< "$item")
        local sec; sec=$(jq -r '.value.streamSettings.security // "none"' <<< "$item")
        echo -e "[${C_CYAN}${idx}${C_RESET}] ${tag} ${C_DIM}(端口: ${p} | 传输: ${net} | 安全: ${sec})${C_RESET}"
    done
    echo ""

    local sel; sel=$(ask "输入编号查看分享链接 (回车返回)" "")
    [ -z "$sel" ] && return 0

    local target; target=$(jq -c --argjson i "$sel" '.inbounds[$i] // empty' "$CONF" 2>/dev/null)
    [ -z "$target" ] && { err "无效编号"; read -rp "按回车键返回..." _; return 1; }

    local proto; proto=$(jq -r '.protocol' <<< "$target")
    local port; port=$(jq -r '.port' <<< "$target")
    local tag; tag=$(jq -r '.tag // "node"' <<< "$target")
    local meta; meta=$(jq -r '._meta // {}' <<< "$target")
    local link=""

    case "$proto" in
        vless)
            local uid; uid=$(jq -r '.uid // empty' <<< "$meta")
            local pbk; pbk=$(jq -r '.pbk // empty' <<< "$meta")
            local sni; sni=$(jq -r '.sni // empty' <<< "$meta")
            local sid; sid=$(jq -r '.sid // empty' <<< "$meta")
            local trans; trans=$(jq -r '.trans // "raw"' <<< "$meta")
            if [ "$trans" = "xhttp" ]; then
                local path; path=$(jq -r '.path // "/xhttp"' <<< "$meta")
                local enc_path; enc_path=$(printf '%s' "$path" | jq -sRr @uri)
                link="vless://${uid}@${host}:${port}?security=reality&encryption=none&pbk=${pbk}&headerType=none&type=xhttp&path=${enc_path}&mode=auto&sni=${sni}&sid=${sid}#${tag}"
            else
                link="vless://${uid}@${host}:${port}?security=reality&encryption=none&pbk=${pbk}&headerType=none&type=raw&flow=xtls-rprx-vision&sni=${sni}&sid=${sid}#${tag}"
            fi
            ;;
        trojan)
            local pass; pass=$(jq -r '.pass // empty' <<< "$meta")
            local sni; sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            link="trojan://${pass}@${host}:${port}?security=tls&allowInsecure=1&sni=${sni}#${tag}"
            ;;
        hysteria)
            local pass; pass=$(jq -r '.pass // empty' <<< "$meta")
            local sni; sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            link="hysteria2://${pass}@${host}:${port}/?insecure=1&sni=${sni}#${tag}"
            ;;
        shadowsocks)
            local method; method=$(jq -r '.method // "2022-blake3-aes-128-gcm"' <<< "$meta")
            local pass; pass=$(jq -r '.pass // empty' <<< "$meta")
            local b64; b64=$(printf '%s:%s' "$method" "$pass" | base64 | tr -d '\n')
            link="ss://${b64}@${host}:${port}#${tag}"
            ;;
        vmess)
            local uid; uid=$(jq -r '.uid // empty' <<< "$meta")
            local path; path=$(jq -r '.path // "/ws"' <<< "$meta")
            local vmess_json; vmess_json=$(jq -cn \
                --arg ps "$tag" --arg add "$host" --arg port "$port" --arg id "$uid" --arg path "$path" \
                '{v: "2", ps: $ps, add: $add, port: ($port|tonumber), id: $id, aid: 0, net: "ws", type: "none", host: "", path: $path, tls: ""}')
            local b64_vmess; b64_vmess=$(printf '%s' "$vmess_json" | base64 | tr -d '\n')
            link="vmess://${b64_vmess}"
            ;;
    esac

    echo ""
    info "节点链接 (${tag}):"
    echo -e "${C_CYAN}${link}${C_RESET}\n"
    read -rp "按回车键继续..." _
}

# 9. 删除节点
delete_node() {
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { info "暂无节点可删"; read -rp "按回车键返回..." _; return 0; }

    echo ""
    echo -e "${C_BOLD}删除节点${C_RESET}"
    jq -c '.inbounds | to_entries[]' "$CONF" | while read -r item; do
        local idx; idx=$(jq -r '.key' <<< "$item")
        local p; p=$(jq -r '.value.port' <<< "$item")
        local tag; tag=$(jq -r '.value.tag // .value._meta.proto // "node"' <<< "$item")
        echo -e "[${C_RED}${idx}${C_RESET}] ${tag} (端口: ${p})"
    done
    echo ""

    local sel; sel=$(ask "输入要删除的节点编号 (回车取消)" "")
    [ -z "$sel" ] && return 0

    local tmp_cfg; tmp_cfg="$(mktemp).json"
    if jq --argjson i "$sel" 'del(.inbounds[$i])' "$CONF" > "$tmp_cfg" 2>/dev/null; then
        apply_config_test "$tmp_cfg" && ok "节点 [${sel}] 已删除"
    else
        rm -f "$tmp_cfg"
        err "编号无效，删除失败"
    fi
    read -rp "按回车键继续..." _
}

# 10. 服务管理菜单
manage_service() {
    echo ""
    echo -e "${C_BOLD}服务操作${C_RESET}"
    echo -e "${C_CYAN}1)${C_RESET} 重启服务"
    echo -e "${C_CYAN}2)${C_RESET} 停止服务"
    echo -e "${C_CYAN}3)${C_RESET} 启动服务"
    echo -e "${C_CYAN}4)${C_RESET} 实时日志"
    echo -e "${C_DIM}0) 返回${C_RESET}"
    echo ""
    local opt; opt=$(ask "请选择" "1")
    case "$opt" in
        1) svc restart && ok "服务已重启" ;;
        2) svc stop && ok "服务已停止" ;;
        3) svc start && ok "服务已启动" ;;
        4)
            if [ -f /var/log/xray/error.log ]; then
                tail -n 30 -f /var/log/xray/error.log
            elif command -v journalctl >/dev/null 2>&1; then
                journalctl -u xray -f -n 30
            else
                info "未找到独立日志文件，请确认服务已启动"
                sleep 1.5
            fi
            ;;
        *) return 0 ;;
    esac
    read -rp "按回车键继续..." _
}

# 11. 极简主界面看板 (严格按照用户要求的排列顺序与BBR状态中文)
main_menu() {
    check_deps
    refresh_ips
    while true; do
        clear 2>/dev/null || true
        local st_color="${C_RED}●${C_RESET}" st_text="停止"
        is_running && st_color="${C_GREEN}●${C_RESET}" && st_text="运行中"

        local ver="未安装"
        [ -f "$BIN" ] && ver=$("$BIN" version 2>/dev/null | head -n1 | awk '{print $2}')

        local node_cnt; node_cnt=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)

        local bbr_st; bbr_st=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "off")

        # 格式化 IPv4 / IPv6 显示
        local ip_str=""
        if [ -n "$PUB_IPV4" ] && [ -n "$PUB_IPV6" ]; then
            ip_str="IPv4: ${PUB_IPV4} | IPv6: ${PUB_IPV6}"
        elif [ -n "$PUB_IPV4" ]; then
            ip_str="IPv4: ${PUB_IPV4}"
        elif [ -n "$PUB_IPV6" ]; then
            ip_str="IPv6: ${PUB_IPV6}"
        else
            ip_str="IP: 未检测到"
        fi

        echo -e "${C_BOLD}Xray-Core${C_RESET} ${ver} [${st_color} ${st_text}] ${C_DIM}BBR: ${bbr_st}${C_RESET}"
        echo -e "节点: ${node_cnt} 个 | ${ip_str}"
        echo ""
        echo -e "${C_CYAN}1.${C_RESET} 节点列表"
        echo -e "${C_CYAN}2.${C_RESET} 添加节点"
        echo -e "${C_CYAN}3.${C_RESET} 修改节点"
        echo -e "${C_CYAN}4.${C_RESET} 删除节点"
        echo -e "${C_CYAN}5.${C_RESET} 服务管理"
        echo -e "${C_CYAN}6.${C_RESET} 开启 BBR"
        echo -e "${C_CYAN}7.${C_RESET} 核心管理"
        echo -e "${C_DIM}0. 退出面板${C_RESET}"
        echo ""

        local act; act=$(ask "请选择" "0")
        case "$act" in
            1) show_nodes ;;
            2) add_node ;;
            3) edit_node ;;
            4) delete_node ;;
            5) manage_service ;;
            6) enable_bbr; read -rp "按回车键继续..." _ ;;
            7) install_core; read -rp "按回车键继续..." _ ;;
            0|q|quit)
                echo -e "\n${C_CYAN}已退出管理面板${C_RESET}\n"
                exit 0
                ;;
            *) echo "无效输入" && sleep 0.5 ;;
        esac
    done
}

main_menu
