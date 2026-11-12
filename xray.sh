#!/usr/bin/env bash
set -o pipefail
umask 077

[ "$(id -u)" -ne 0 ] && { echo -e "\033[31m✗\033[0m 请使用 root 权限运行此脚本" >&2; exit 1; }

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
C_YELLOW="\033[33m"
VER_CACHE="$CONF_DIR/.latest_ver"

PUB_IPV4=""
PUB_IPV6=""
ARCH="64"
[[ "$(uname -m)" =~ arm64|aarch64 ]] && ARCH="arm64-v8a"

# 1. 基础辅助与环境检测
ok()   { echo -e "${C_GREEN}✓${C_RESET} $*"; }
err()  { echo -e "${C_RED}✗${C_RESET} $*" >&2; }
info() { echo -e "${C_CYAN}›${C_RESET} $*"; }
gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16; }

setup_shortcut() {
    local target="/usr/local/bin/xraym"
    local persist_script="$CONF_DIR/xray.sh"
    mkdir -p "$CONF_DIR" /usr/local/bin 2>/dev/null || true

    local cur_src="${BASH_SOURCE[0]}"
    local real_src=""
    [ -n "$cur_src" ] && real_src=$(readlink -f "$cur_src" 2>/dev/null || echo "$cur_src")

    # 如果通过 bash <(curl ...) 或匿名管道执行，当前路径为 /dev/fd/* 或不存在实体文件
    if [ -z "$real_src" ] || [[ "$real_src" =~ ^/dev/fd/|^/proc/ ]] || [ ! -f "$real_src" ]; then
        if ! curl -fsSL -m 5 https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh -o "$persist_script" 2>/dev/null || [ ! -s "$persist_script" ]; then
            # 备用回退: 若离线或受限，尝试从当前进程源码流 dump
            cat "$cur_src" > "$persist_script" 2>/dev/null || true
        fi
        if [ -s "$persist_script" ]; then
            chmod +x "$persist_script" 2>/dev/null || true
            ln -sf "$persist_script" "$target" 2>/dev/null || cp -f "$persist_script" "$target" 2>/dev/null || true
        fi
    else
        # 从本地实体磁盘文件运行
        if [ "$real_src" != "$persist_script" ] && [ "$real_src" != "$target" ]; then
            cp -f "$real_src" "$persist_script" 2>/dev/null || true
            chmod +x "$persist_script" 2>/dev/null || true
            ln -sf "$persist_script" "$target" 2>/dev/null || true
        else
            ln -sf "$real_src" "$target" 2>/dev/null || true
        fi
    fi
    chmod +x "$target" 2>/dev/null || true
}

check_update_async() {
    [ -f "$BIN" ] || return 0
    local now mtime=0
    if [ -f "$VER_CACHE" ]; then
        now=$(date +%s 2>/dev/null || echo 0)
        mtime=$(stat -c %Y "$VER_CACHE" 2>/dev/null || echo 0)
        [ $((now - mtime)) -le 3600 ] && return 0
    fi
    (
        mkdir -p "$CONF_DIR" 2>/dev/null || true
        local tag
        tag=$(curl -fsSL -m 3 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
        if [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            if echo "${tag#v}" > "${VER_CACHE}.tmp.$$" 2>/dev/null; then
                mv -f "${VER_CACHE}.tmp.$$" "$VER_CACHE" 2>/dev/null || rm -f "${VER_CACHE}.tmp.$$" 2>/dev/null
            fi
        fi
    ) >/dev/null 2>&1 &
}

check_deps() {
    local missing="" cmd
    for cmd in curl unzip openssl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=" $cmd"
    done
    command -v setcap >/dev/null 2>&1 || {
        if command -v apt-get >/dev/null 2>&1; then missing+=" libcap2-bin"
        elif command -v apk >/dev/null 2>&1; then missing+=" libcap"; fi
    }
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

ask_port() {
    local prompt="$1" def="$2" p=""
    while true; do
        p=$(ask "$prompt" "$def")
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
            echo "$p"
            return 0
        fi
        err "端口无效，请输入 1-65535 之间的纯数字"
    done
}

is_port_used() {
    local p="$1"
    ss -tlun 2>/dev/null | grep -qw ":${p}\b"
}

rand_port() {
    local p
    while p=$((RANDOM % 55535 + 10000)); do
        is_port_used "$p" || { echo "$p"; break; }
    done
}

refresh_ips() {
    [ -n "$PUB_IPV4" ] || PUB_IPV4=$(curl -fs4 -m 2 https://api.ipify.org 2>/dev/null || curl -fs4 -m 2 https://icanhazip.com 2>/dev/null || echo "")
    [ -n "$PUB_IPV6" ] || PUB_IPV6=$(curl -fs6 -m 2 https://api6.ipify.org 2>/dev/null || curl -fs6 -m 2 https://icanhazip.com 2>/dev/null || echo "")
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
    if [[ "$cur" == *"bbr"* ]]; then ok "BBR 状态: 开启"; else err "BBR 状态: 关闭"; fi
}

# 2. 安全用户与服务初始化
ensure_xray_user() {
    if ! id -u xray >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd -r -s /usr/sbin/nologin -M -d /nonexistent -U xray 2>/dev/null || useradd -r -s /bin/false -M xray 2>/dev/null || true
        elif command -v adduser >/dev/null 2>&1; then
            adduser -S -H -h /dev/null -s /sbin/nologin -D -u 19999 xray 2>/dev/null || adduser -S -D -H xray 2>/dev/null || true
        fi
    fi
    if [ -f "$BIN" ] && command -v setcap >/dev/null 2>&1; then
        setcap 'cap_net_bind_service=+ep' "$BIN" 2>/dev/null || true
    fi
    mkdir -p "$CONF_DIR" "$CERTS_DIR" /var/log/xray
    chown -R xray:xray "$CONF_DIR" /var/log/xray 2>/dev/null || true
    chmod 700 "$CONF_DIR" "$CERTS_DIR" 2>/dev/null || true
    if [ -f "$CONF" ]; then
        chmod 600 "$CONF" 2>/dev/null || true
    fi
    chmod 750 /var/log/xray 2>/dev/null || true
}

init_env() {
    ensure_xray_user
    if [ ! -s "$CONF" ]; then
        echo '{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "fc00::/7", "fe80::/10"], "outboundTag": "block"}]}
}' > "$CONF"
        chown -R xray:xray "$CONF_DIR" 2>/dev/null || true
        chmod 600 "$CONF" 2>/dev/null || true
    fi
}

svc() {
    local act="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl "$act" "$SVC_NAME" 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$SVC_NAME" "$act" 2>/dev/null || true
    else
        pkill -u xray -x xray 2>/dev/null || pkill -x xray 2>/dev/null || true
        if [ "$act" = "start" ] || [ "$act" = "restart" ]; then
            if id -u xray >/dev/null 2>&1; then
                su -s /bin/sh xray -c "nohup '$BIN' run -c '$CONF' >/dev/null 2>&1 &" 2>/dev/null || nohup "$BIN" run -c "$CONF" >/dev/null 2>&1 &
            else
                nohup "$BIN" run -c "$CONF" >/dev/null 2>&1 &
            fi
        fi
    fi
}

is_running() { pgrep -x xray >/dev/null 2>&1; }

install_service() {
    ensure_xray_user
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Core
After=network.target

[Service]
Type=simple
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
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
command_user="xray:xray"
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
    local ver cur_ver=""
    ver=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
    { [ -z "$ver" ] || [ "$ver" = "null" ]; } && ver="v26.11.9"

    if [ -f "$BIN" ]; then
        cur_ver=$("$BIN" version 2>/dev/null | head -n1 | awk '{print $2}')
        local cur_clean="${cur_ver#v}"
        local target_clean="${ver#v}"
        if [ "$cur_clean" = "$target_clean" ]; then
            ok "当前已是最新版本 (${cur_ver})"
            local re_inst; re_inst=$(ask "是否重新下载安装？[y/N]" "n")
            if [[ ! "$re_inst" =~ ^[Yy]$ ]]; then
                info "已取消安装"
                return 0
            fi
        else
            info "检测到更新: ${cur_ver} -> ${ver}"
        fi
    fi

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
    echo "${ver#v}" > "$VER_CACHE" 2>/dev/null || true
    ok "Xray 核心已就绪 (${ver})"
}

# 4. 证书自签 (针对 Trojan / Hysteria 等)
ensure_self_cert() {
    local domain="${1:-www.nvidia.com}"
    local crt="$CERTS_DIR/cert.crt" key="$CERTS_DIR/priv.key"
    if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650             -keyout "$key" -out "$crt" -subj "/CN=${domain}" >/dev/null 2>&1
        chmod 600 "$key" "$crt" 2>/dev/null || true
        chown xray:xray "$key" "$crt" 2>/dev/null || true
    fi
}

# 5. 配置检验与原子替换
apply_config_test() {
    local tmp_cfg="$1" err_msg=""
    if err_msg=$("$BIN" run -test -format=json -c "$tmp_cfg" 2>&1); then
        mv "$tmp_cfg" "$CONF"
        chown -R xray:xray "$CONF_DIR" 2>/dev/null || true
        chmod 600 "$CONF" 2>/dev/null || true
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

list_inbounds() {
    local simple="${1:-}"
    jq -c '.inbounds | to_entries[]' "$CONF" 2>/dev/null | while read -r item; do
        local idx p tag
        idx=$(jq -r '.key' <<< "$item")
        p=$(jq -r '.value.port' <<< "$item")
        tag=$(jq -r '.value.tag // .value._meta.proto // "node"' <<< "$item")
        if [ "$simple" = "1" ]; then
            echo -e "[${C_RED}${idx}${C_RESET}] ${tag} (端口: ${p})"
        else
            local net; net=$(jq -r '.value.streamSettings.network // "raw"' <<< "$item")
            echo -e "[${C_CYAN}${idx}${C_RESET}] ${tag} ${C_DIM}(端口: ${p} | 传输: ${net})${C_RESET}"
        fi
    done
}

# 6. 单一数据源：统一生成标准客户端分享链接
build_link() {
    local target="$1" host="$2"
    local proto port tag meta
    proto=$(jq -r '.protocol' <<< "$target")
    port=$(jq -r '.port' <<< "$target")
    tag=$(jq -r '.tag // "node"' <<< "$target")
    meta=$(jq -r '._meta // {}' <<< "$target")

    case "$proto" in
        vless)
            local uid pbk sni sid trans path enc_path
            uid=$(jq -r '.uid // empty' <<< "$meta")
            pbk=$(jq -r '.pbk // empty' <<< "$meta")
            sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            sid=$(jq -r '.sid // empty' <<< "$meta")
            trans=$(jq -r '.trans // "raw"' <<< "$meta")
            if [ "$trans" = "xhttp" ]; then
                path=$(jq -r '.path // "/xhttp"' <<< "$meta")
                enc_path=$(printf '%s' "$path" | jq -sRr @uri)
                echo "vless://${uid}@${host}:${port}?security=reality&encryption=none&pbk=${pbk}&headerType=none&type=xhttp&path=${enc_path}&mode=auto&sni=${sni}&sid=${sid}#${tag}"
            else
                echo "vless://${uid}@${host}:${port}?security=reality&encryption=none&pbk=${pbk}&headerType=none&type=raw&flow=xtls-rprx-vision&sni=${sni}&sid=${sid}#${tag}"
            fi
            ;;
        trojan)
            local pass sni
            pass=$(jq -r '.pass // empty' <<< "$meta")
            sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            echo "trojan://${pass}@${host}:${port}?security=tls&allowInsecure=1&sni=${sni}#${tag}"
            ;;
        hysteria)
            local pass sni
            pass=$(jq -r '.pass // empty' <<< "$meta")
            sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            echo "hysteria2://${pass}@${host}:${port}/?insecure=1&sni=${sni}#${tag}"
            ;;
        shadowsocks)
            local method pass b64
            method=$(jq -r '.method // "2022-blake3-aes-128-gcm"' <<< "$meta")
            pass=$(jq -r '.pass // empty' <<< "$meta")
            b64=$(printf '%s:%s' "$method" "$pass" | base64 | tr -d '\n')
            echo "ss://${b64}@${host}:${port}#${tag}"
            ;;
        vmess)
            local uid path vmess_json b64_vmess
            uid=$(jq -r '.uid // empty' <<< "$meta")
            path=$(jq -r '.path // "/ws"' <<< "$meta")
            vmess_json=$(jq -cn                 --arg ps "$tag" --arg add "$host" --arg port "$port" --arg id "$uid" --arg path "$path"                 '{v: "2", ps: $ps, add: $add, port: ($port|tonumber), id: $id, aid: 0, net: "ws", type: "none", host: "", path: $path, tls: ""}')
            b64_vmess=$(printf '%s' "$vmess_json" | base64 | tr -d '\n')
            echo "vmess://${b64_vmess}"
            ;;
    esac
}

print_node_links() {
    local target="$1" title="${2:-节点链接}"
    refresh_ips
    local tag; tag=$(jq -r '.tag // "node"' <<< "$target")
    echo ""
    info "${title} (${tag}):"

    if [ -n "$PUB_IPV4" ] && [ -n "$PUB_IPV6" ]; then
        echo -e "\n${C_BOLD}IPv4 链接:${C_RESET}\n${C_CYAN}$(build_link "$target" "$PUB_IPV4")${C_RESET}"
        echo -e "\n${C_BOLD}IPv6 链接:${C_RESET}\n${C_CYAN}$(build_link "$target" "[${PUB_IPV6}]")${C_RESET}\n"
    elif [ -n "$PUB_IPV4" ]; then
        echo -e "\n${C_CYAN}$(build_link "$target" "$PUB_IPV4")${C_RESET}\n"
    elif [ -n "$PUB_IPV6" ]; then
        echo -e "\n${C_CYAN}$(build_link "$target" "[${PUB_IPV6}]")${C_RESET}\n"
    else
        echo -e "\n${C_CYAN}$(build_link "$target" "127.0.0.1")${C_RESET}\n"
    fi
}

# 7. 入站节点生成器 (严格按照 Xray 官方文档规范)
add_node() {
    [ ! -f "$BIN" ] && { err "请先安装 Xray 核心 (选项 7)"; return 1; }
    init_env

    echo -e "\n${C_BOLD}入站协议${C_RESET}\n${C_CYAN}1)${C_RESET} VLESS\n${C_CYAN}2)${C_RESET} Hysteria\n${C_CYAN}3)${C_RESET} Trojan\n${C_CYAN}4)${C_RESET} Shadowsocks\n${C_CYAN}5)${C_RESET} VMess\n"

    local choice; choice=$(ask "选择协议 [1-5]" "1")
    local def_ports=("" "443" "8443" "443" "8388" "80")
    local def_p="${def_ports[$choice]:-}"
    [ -z "$def_p" ] && { err "无效选项"; return 1; }
    is_port_used "$def_p" && def_p=$(rand_port)
    local port; port=$(ask_port "监听端口" "$def_p")
    local inb_data="" remark=""

    case "$choice" in
        1) # VLESS-Reality
            local trans_mode; trans_mode=$(ask "传输方式 [1: Vision, 2: XHTTP]" "1")
            local sni; sni=$(ask "伪装域名 (SNI)" "www.nvidia.com")
            local keys; keys=$("$BIN" x25519)
            local priv; priv=$(awk -F': *' '/[Pp]rivate[ ]?[Kk]ey/{print $2}' <<< "$keys" | tr -d ' \r\n')
            local pub; pub=$(awk -F': *' '/[Pp]ublic[ ]?[Kk]ey/{print $2}' <<< "$keys" | tr -d ' \r\n')
            local sid; sid=$(openssl rand -hex 4)
            local uid; uid=$(gen_uuid)

            if [ "$trans_mode" = "2" ]; then
                local path; path=$(ask "XHTTP 路径" "/xhttp-$(openssl rand -hex 3)")
                remark="VLESS-XHTTP-${port}"
                inb_data=$(jq -n                     --arg port "$port" --arg uid "$uid" --arg priv "$priv" --arg pbk "$pub" --arg sni "$sni" --arg sid "$sid" --arg path "$path" --arg rmk "$remark"                     '{
                        listen: "::",
                        port: ($port|tonumber),
                        protocol: "vless",
                        tag: $rmk,
                        settings: {clients: [{id: $uid}], decryption: "none"},
                        streamSettings: {
                            network: "xhttp",
                            security: "reality",
                            xhttpSettings: {path: $path, host: $sni, mode: "auto"},
                            realitySettings: {show: false, dest: ($sni + ":443"), xver: 0, serverNames: [$sni], privateKey: $priv, shortIds: [$sid]}
                        },
                        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
                        _meta: {proto: "vless", trans: "xhttp", sec: "reality", pbk: $pbk, sni: $sni, sid: $sid, uid: $uid, path: $path}
                    }')
            else
                remark="VLESS-Reality-${port}"
                inb_data=$(jq -n                     --arg port "$port" --arg uid "$uid" --arg priv "$priv" --arg pbk "$pub" --arg sni "$sni" --arg sid "$sid" --arg rmk "$remark"                     '{
                        listen: "::",
                        port: ($port|tonumber),
                        protocol: "vless",
                        tag: $rmk,
                        settings: {clients: [{id: $uid, flow: "xtls-rprx-vision"}], decryption: "none"},
                        streamSettings: {
                            network: "raw",
                            security: "reality",
                            realitySettings: {show: false, dest: ($sni + ":443"), xver: 0, serverNames: [$sni], privateKey: $priv, shortIds: [$sid]}
                        },
                        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
                        _meta: {proto: "vless", trans: "raw", sec: "reality", pbk: $pbk, sni: $sni, sid: $sid, uid: $uid, flow: "xtls-rprx-vision"}
                    }')
            fi
            ;;

        2) # Hysteria 2
            local sni; sni=$(ask "伪装域名 (SNI)" "www.nvidia.com")
            ensure_self_cert "$sni"
            tune_system
            local pass; pass=$(ask "认证密码" "$(openssl rand -hex 8)")
            remark="Hy2-${port}"

            inb_data=$(jq -n                 --arg port "$port" --arg pass "$pass" --arg crt "$CERTS_DIR/cert.crt" --arg key "$CERTS_DIR/priv.key" --arg sni "$sni" --arg rmk "$remark"                 '{
                    listen: "::",
                    port: ($port|tonumber),
                    protocol: "hysteria",
                    tag: $rmk,
                    settings: {version: 2, users: [{auth: $pass}]},
                    streamSettings: {
                        network: "hysteria",
                        hysteriaSettings: {version: 2},
                        security: "tls",
                        tlsSettings: {certificates: [{certificateFile: $crt, keyFile: $key}], alpn: ["h3"]}
                    },
                    _meta: {proto: "hysteria", pass: $pass, sni: $sni}
                }')
            ;;

        3) # Trojan-TLS
            local domain; domain=$(ask "伪装域名 (自签)" "www.nvidia.com")
            ensure_self_cert "$domain"
            local pass; pass=$(openssl rand -hex 8)
            remark="Trojan-${port}"

            inb_data=$(jq -n                 --arg port "$port" --arg pass "$pass" --arg crt "$CERTS_DIR/cert.crt" --arg key "$CERTS_DIR/priv.key" --arg domain "$domain" --arg rmk "$remark"                 '{
                    listen: "::",
                    port: ($port|tonumber),
                    protocol: "trojan",
                    tag: $rmk,
                    settings: {clients: [{password: $pass}]},
                    streamSettings: {
                        network: "raw",
                        security: "tls",
                        tlsSettings: {certificates: [{certificateFile: $crt, keyFile: $key}], serverName: $domain}
                    },
                    sniffing: {enabled: true, destOverride: ["http", "tls"]},
                    _meta: {proto: "trojan", pass: $pass, sni: $domain}
                }')
            ;;

        4) # Shadowsocks 2022
            local method="2022-blake3-aes-128-gcm"
            local pass; pass=$(openssl rand -base64 16)
            remark="SS-${port}"

            inb_data=$(jq -n                 --arg port "$port" --arg pass "$pass" --arg method "$method" --arg rmk "$remark"                 '{
                    listen: "::",
                    port: ($port|tonumber),
                    protocol: "shadowsocks",
                    tag: $rmk,
                    settings: {method: $method, password: $pass, network: "tcp,udp"},
                    streamSettings: {network: "raw"},
                    _meta: {proto: "shadowsocks", method: $method, pass: $pass}
                }')
            ;;

        5) # VMess-WS
            local path; path=$(ask "WebSocket 路径" "/ws-$(openssl rand -hex 3)")
            local uid; uid=$(gen_uuid)
            remark="VMess-WS-${port}"

            inb_data=$(jq -n                 --arg port "$port" --arg uid "$uid" --arg path "$path" --arg rmk "$remark"                 '{
                    listen: "::",
                    port: ($port|tonumber),
                    protocol: "vmess",
                    tag: $rmk,
                    settings: {clients: [{id: $uid, alterId: 0}]},
                    streamSettings: {network: "ws", security: "none", wsSettings: {path: $path}},
                    sniffing: {enabled: true, destOverride: ["http", "tls"]},
                    _meta: {proto: "vmess", uid: $uid, path: $path}
                }')
            ;;

        *) err "无效选项"; return 1 ;;
    esac

    [ -z "$inb_data" ] && return 1
    apply_inbound "$inb_data" || return 1
    print_node_links "$inb_data" "节点添加成功"
    read -rp "按回车键返回主菜单..." _
}

# 8. 修改节点功能 (内存级单次计算原子更新)
edit_node() {
    [ ! -f "$CONF" ] && { err "配置文件不存在"; sleep 1; return 1; }
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { info "暂无节点可修改"; sleep 1; return 0; }

    echo -e "\n${C_BOLD}修改入站节点${C_RESET}"
    list_inbounds
    echo ""

    local sel; sel=$(ask "输入要修改的节点编号 (回车返回)" "")
    [ -z "$sel" ] && return 0
    [[ ! "$sel" =~ ^[0-9]+$ ]] && { err "编号必须是纯数字"; sleep 1; return 1; }

    local target; target=$(jq -c --argjson i "$sel" '.inbounds[$i] // empty' "$CONF" 2>/dev/null)
    [ -z "$target" ] && { err "无效编号"; sleep 1; return 1; }

    local cur_port cur_proto cur_trans meta new_port new_inb
    cur_port=$(jq -r '.port' <<< "$target")
    cur_proto=$(jq -r '.protocol' <<< "$target")
    cur_trans=$(jq -r '.streamSettings.network // "raw"' <<< "$target")
    meta=$(jq -r '._meta // {}' <<< "$target")

    echo ""
    info "正在修改节点 [${sel}] (${cur_proto}/${cur_trans}):"
    new_port=$(ask_port "监听端口" "$cur_port")
    new_inb=$(jq --arg port "$new_port" '.port = ($port|tonumber) | .tag = (.tag | sub("-[0-9]+$"; "-" + $port))' <<< "$target")

    case "$cur_proto" in
        vless)
            local cur_sni; cur_sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名 (SNI)" "$cur_sni")
            if [ "$cur_trans" = "xhttp" ]; then
                local cur_path; cur_path=$(jq -r '.path // "/xhttp"' <<< "$meta")
                local new_path; new_path=$(ask "XHTTP 路径" "$cur_path")
                new_inb=$(jq --arg sni "$new_sni" --arg path "$new_path"                     '.streamSettings.realitySettings.serverNames = [$sni] | .streamSettings.realitySettings.dest = ($sni + ":443") | .streamSettings.xhttpSettings.path = $path | .streamSettings.xhttpSettings.host = $sni | ._meta.sni = $sni | ._meta.path = $path' <<< "$new_inb")
            else
                new_inb=$(jq --arg sni "$new_sni"                     '.streamSettings.realitySettings.serverNames = [$sni] | .streamSettings.realitySettings.dest = ($sni + ":443") | ._meta.sni = $sni' <<< "$new_inb")
            fi
            ;;
        trojan)
            local cur_sni; cur_sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名" "$cur_sni")
            ensure_self_cert "$new_sni"
            new_inb=$(jq --arg sni "$new_sni"                 '.streamSettings.tlsSettings.serverName = $sni | ._meta.sni = $sni' <<< "$new_inb")
            ;;
        hysteria)
            local cur_pass; cur_pass=$(jq -r '.pass // ""' <<< "$meta")
            local new_pass; new_pass=$(ask "认证密码" "$cur_pass")
            local cur_sni; cur_sni=$(jq -r '.sni // "www.nvidia.com"' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名 (SNI)" "$cur_sni")
            ensure_self_cert "$new_sni"
            new_inb=$(jq --arg pass "$new_pass" --arg sni "$new_sni"                 '.settings.users[0].auth = $pass | ._meta.pass = $pass | ._meta.sni = $sni' <<< "$new_inb")
            ;;
        shadowsocks)
            local cur_pass; cur_pass=$(jq -r '.pass // ""' <<< "$meta")
            local new_pass; new_pass=$(ask "密码" "$cur_pass")
            new_inb=$(jq --arg pass "$new_pass" '.settings.password = $pass | ._meta.pass = $pass' <<< "$new_inb")
            ;;
        vmess)
            local cur_path; cur_path=$(jq -r '.path // "/ws"' <<< "$meta")
            local new_path; new_path=$(ask "WebSocket 路径" "$cur_path")
            new_inb=$(jq --arg path "$new_path" '.streamSettings.wsSettings.path = $path | ._meta.path = $path' <<< "$new_inb")
            ;;
    esac

    local tmp_cfg; tmp_cfg="$(mktemp).json"
    jq --argjson i "$sel" --argjson inb "$new_inb" '.inbounds[$i] = $inb' "$CONF" > "$tmp_cfg"
    if apply_config_test "$tmp_cfg"; then
        ok "节点 [${sel}] 已成功修改并重启生效"
        sleep 1
    fi
}

# 9. 节点查看与链接输出
show_nodes() {
    [ ! -f "$CONF" ] && { err "配置文件不存在"; sleep 1; return 1; }

    while true; do
        local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
        if [ "$count" -eq 0 ]; then
            info "暂无配置任何节点"
            sleep 1
            return 0
        fi

        echo -e "\n${C_BOLD}当前节点列表 [${count}]${C_RESET}"
        list_inbounds
        echo ""

        local sel; sel=$(ask "输入编号查看分享链接 (回车返回)" "")
        [ -z "$sel" ] && return 0
        if [[ ! "$sel" =~ ^[0-9]+$ ]]; then
            err "编号必须是纯数字"; sleep 1; continue
        fi

        local target; target=$(jq -c --argjson i "$sel" '.inbounds[$i] // empty' "$CONF" 2>/dev/null)
        if [ -z "$target" ]; then
            err "无效编号"; sleep 1; continue
        fi

        print_node_links "$target" "节点链接"
        read -rp "按回车键返回列表..." _
    done
}

# 10. 删除节点
delete_node() {
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { info "暂无节点可删"; sleep 1; return 0; }

    echo -e "\n${C_BOLD}删除节点${C_RESET}"
    list_inbounds 1
    echo ""

    local sel; sel=$(ask "输入要删除的节点编号 (回车取消)" "")
    [ -z "$sel" ] && return 0
    [[ ! "$sel" =~ ^[0-9]+$ ]] && { err "编号必须是纯数字"; sleep 1; return 1; }

    local tmp_cfg; tmp_cfg="$(mktemp).json"
    if jq --argjson i "$sel" 'del(.inbounds[$i])' "$CONF" > "$tmp_cfg" 2>/dev/null; then
        apply_config_test "$tmp_cfg" && ok "节点 [${sel}] 已删除"
        sleep 1
    else
        rm -f "$tmp_cfg"
        err "编号无效，删除失败"
        sleep 1
    fi
}

# 11. 服务管理菜单
manage_service() {
    echo -e "\n${C_BOLD}服务操作${C_RESET}\n${C_CYAN}1)${C_RESET} 重启服务\n${C_CYAN}2)${C_RESET} 停止服务\n${C_CYAN}3)${C_RESET} 启动服务\n${C_CYAN}4)${C_RESET} 实时日志\n${C_DIM}0) 返回${C_RESET}\n"
    case "$(ask "请选择" "1")" in
        1) svc restart && ok "服务已重启"; sleep 1 ;;
        2) svc stop && ok "服务已停止"; sleep 1 ;;
        3) svc start && ok "服务已启动"; sleep 1 ;;
        4)
            if [ -f /var/log/xray/error.log ]; then tail -n 30 -f /var/log/xray/error.log
            elif command -v journalctl >/dev/null 2>&1; then journalctl -u xray -f -n 30
            else info "未找到独立日志文件，请确认服务已启动"; sleep 1.5; fi
            ;;
        *) return 0 ;;
    esac
}

# 12. 彻底卸载 Xray 与数据
uninstall_xray() {
    echo ""
    local confirm; confirm=$(ask "确认彻底卸载 Xray 并清除全部数据？[y/N]" "n")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消卸载"
        sleep 1
        return 0
    fi

    info "停止服务并清理进程..."
    svc stop >/dev/null 2>&1 || true
    pkill -9 -u xray 2>/dev/null || true
    pkill -9 -x xray 2>/dev/null || true

    info "移除系统服务配置..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable xray 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update del xray default 2>/dev/null || true
        rm -f /etc/init.d/xray
    fi

    info "清除核心程序、配置、证书与全部数据..."
    rm -rf "$BIN" "/usr/local/bin/xraym"
    rm -rf "$CONF_DIR" "/usr/local/share/xray" "/var/log/xray" "/run/xray.pid" "/etc/logrotate.d/xray"
    userdel -r xray 2>/dev/null || deluser xray 2>/dev/null || true
    groupdel xray 2>/dev/null || true

    echo ""
    ok "Xray 及所有数据文件已彻底卸载清理完毕"
    exit 0
}

# 13. 极简主界面看板
main_menu() {
    setup_shortcut
    check_deps
    refresh_ips
    check_update_async
    while true; do
        clear 2>/dev/null || true
        local st_color="${C_RED}●${C_RESET}" st_text="停止"
        is_running && st_color="${C_GREEN}●${C_RESET}" && st_text="运行中"

        local ver="未安装" core_action="安装核心" update_tag=""
        if [ -f "$BIN" ]; then
            ver=$("$BIN" version 2>/dev/null | head -n1 | awk '{print $2}')
            core_action="更新核心"
            if [ -f "$VER_CACHE" ]; then
                local latest_ver; latest_ver=$(tr -d ' \r\n' < "$VER_CACHE" 2>/dev/null || true)
                if [ -n "$latest_ver" ]; then
                    local cur_clean="${ver#v}" target_clean="${latest_ver#v}"
                    if [ "$cur_clean" != "$target_clean" ] && [ "$(printf '%s\n%s\n' "$cur_clean" "$target_clean" | sort -V | head -n 1)" = "$cur_clean" ]; then
                        update_tag=" ${C_YELLOW}(可更新: ${target_clean})${C_RESET}"
                    fi
                fi
            fi
        fi

        local node_cnt; node_cnt=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
        local bbr_st; bbr_st=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "off")

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

        echo -e "${C_BOLD}Xray-Core${C_RESET} ${ver}${update_tag} [${st_color} ${st_text}] ${C_DIM}BBR: ${bbr_st}${C_RESET}"
        echo -e "节点: ${node_cnt} 个 | ${ip_str}"
        echo ""
        echo -e "${C_CYAN}1.${C_RESET} 节点列表"
        echo -e "${C_CYAN}2.${C_RESET} 添加节点"
        echo -e "${C_CYAN}3.${C_RESET} 修改节点"
        echo -e "${C_CYAN}4.${C_RESET} 删除节点"
        echo -e "${C_CYAN}5.${C_RESET} 服务管理"
        echo -e "${C_CYAN}6.${C_RESET} BBR 算法"
        echo -e "${C_CYAN}7.${C_RESET} ${core_action}"
        echo -e "${C_RED}8.${C_RESET} 卸载 Xray"
        echo -e "${C_DIM}0. 退出面板${C_RESET}"
        echo ""

        case "$(ask "请选择" "0")" in
            1) show_nodes ;;
            2) add_node ;;
            3) edit_node ;;
            4) delete_node ;;
            5) manage_service ;;
            6) enable_bbr; sleep 1.2 ;;
            7) install_core; sleep 1.2 ;;
            8) uninstall_xray ;;
            0|q|quit)
                clear 2>/dev/null || true
                echo -e "\n${C_CYAN}已退出管理面板${C_RESET}\n"
                exit 0
                ;;
            *) err "请输入 0-8 之间的选项"; sleep 0.8 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu "$@"
fi
