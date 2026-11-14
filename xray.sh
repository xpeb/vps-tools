#!/usr/bin/env bash
# ==============================================================================
# Xray Management Script (xraym)
# Lightweight, Robust & Non-root Xray Server Manager for Linux VPS
# ==============================================================================
set -o pipefail
umask 077

[ "$(id -u)" -ne 0 ] && { echo -e "\033[31m[失败]\033[0m 请使用 root 权限运行此脚本" >&2; exit 1; }
# 非交互兜底：当脚本通过管道喂给 bash 且当前有控制终端时，重定向 stdin 接管键盘
if [ ! -t 0 ]; then
    if { exec < /dev/tty; } 2>/dev/null; then :; fi
fi

# 基础目录与服务常量
CONF_DIR="/usr/local/etc/xray"
CONF="$CONF_DIR/config.json"
CERTS_DIR="$CONF_DIR/certs"
BIN="/usr/local/bin/xray"
SVC_NAME="xray"
VER_CACHE="$CONF_DIR/.latest_ver"

PUB_IPV4=""
PUB_IPV6=""

# 架构判断
ARCH="64"
case "$(uname -m)" in
    aarch64|arm64)       ARCH="arm64-v8a" ;;
    armv7l|armv7*)       ARCH="arm32-v7a" ;;
    i386|i486|i586|i686) ARCH="32" ;;
    *)                   ARCH="64" ;;
esac

# 终端样式 (极简冷色调)
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_CYAN="\033[36m"; C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"

# 临时目录栈 (退出自动全量回收，磁盘 0 残留)
TMP_DIRS=()
cleanup_tmp() {
    local d
    for d in "${TMP_DIRS[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done
    TMP_DIRS=()
}
trap cleanup_tmp EXIT INT TERM

mk_tmp_cfg() {
    local __v="${1:-}" __d
    __d=$(mktemp -d "${TMPDIR:-/tmp}/xray.XXXXXX" 2>/dev/null) || return 1
    touch "${__d}/config.json" 2>/dev/null || { rm -rf "$__d"; return 1; }
    TMP_DIRS+=("$__d")
    if [ -n "$__v" ]; then printf -v "$__v" '%s' "${__d}/config.json"; else printf '%s' "${__d}/config.json"; fi
}

# ------------------------------------------------------------------------------
# 1. 统一状态标识与基础辅助
# ------------------------------------------------------------------------------
draw_line() {
    local char="${1:--}" color="${2:-}"
    local cols
    cols=$(tput cols 2>/dev/null || echo "")
    [ -z "$cols" ] || [ "$cols" -lt 30 ] 2>/dev/null && cols="${COLUMNS:-}"
    [ -z "$cols" ] || [ "$cols" -lt 30 ] 2>/dev/null && cols=75
    [ "$cols" -gt 120 ] 2>/dev/null && cols=120
    if [ -n "$color" ]; then
        echo -e "${color}$(printf '%*s' "$cols" '' | tr ' ' "$char")${C_RESET}"
    else
        printf '%*s\n' "$cols" '' | tr ' ' "$char"
    fi
}

ok()   { echo -e "${C_GREEN}[成功]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[失败]${C_RESET} $*" >&2; }
warn() { echo -e "${C_YELLOW}[警告]${C_RESET} $*"; }
info() { echo -e "${C_CYAN}[提示]${C_RESET} $*"; }

ask() {
    local p="$1" d="${2:-}" v=""
    if [ -n "$d" ]; then read -rp "$(echo -e "${C_CYAN}[提示]${C_RESET} ${p} [${d}]: ")" v
    else read -rp "$(echo -e "${C_CYAN}[提示]${C_RESET} ${p}: ")" v; fi
    echo "${v:-$d}"
}

pause_tip() { read -rp "$(echo -e "${C_CYAN}[提示]${C_RESET} 按回车键继续...")" _; }

cur_core_ver() {
    [ -x "$BIN" ] && "$BIN" version 2>/dev/null | head -n1 | awk '{print $2}' || echo ""
}

gen_uuid() {
    [ -x "$BIN" ] && "$BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16
}

setup_shortcut() {
    local target="/usr/local/bin/xraym"
    mkdir -p /usr/local/bin 2>/dev/null || true
    local src="${BASH_SOURCE[0]}" real_src=""
    [ -n "$src" ] && real_src=$(readlink -f "$src" 2>/dev/null || echo "$src")

    # 1. 若当前运行的正是实体快捷方式，确保权限后直接返回
    if [ "$real_src" = "$target" ] && [ -f "$target" ]; then
        chmod +x "$target" 2>/dev/null || true
        return 0
    fi

    # 2. 若是从本地实体文件运行 (如 /root/xray.sh)，直接原子拷贝
    if [ -n "$real_src" ] && [[ ! "$real_src" =~ ^/dev/fd/|^/proc/ ]] && [ -f "$real_src" ]; then
        cp -f "$real_src" "$target" 2>/dev/null || true
        chmod +x "$target" 2>/dev/null || true
        return 0
    fi

    # 3. 若通过管道/进程替换运行 (如 bash <(curl -fsSL https://xxxx.com/xray.sh))，且本地尚无快捷命令
    if [ ! -s "$target" ]; then
        # 探测原始来源 URL：优先显式变量，次选历史记录，兜底官方/镜像源
        local origin_url=""
        if [ -n "${XRAY_SOURCE_URL:-}" ]; then
            origin_url="$XRAY_SOURCE_URL"
        else
            local h
            for h in ~/.bash_history ~/.zsh_history; do
                if [ -r "$h" ]; then
                    origin_url=$(grep -E -a -o 'https?://[^ " '\''\)]+xray[^ " '\''\)]*' "$h" 2>/dev/null | tail -n 1 || true)
                    if [ -n "$origin_url" ]; then break; fi
                fi
            done
        fi

        local urls=()
        if [ -n "$origin_url" ]; then urls+=("$origin_url"); fi
        urls+=("https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh")
        urls+=("https://raw.gitmirror.com/xpeb/vps-tools/main/xray.sh")

        local u ok_inst=false
        for u in "${urls[@]}"; do
            if curl -fsSL -m 8 "$u" -o "${target}.tmp" 2>/dev/null && bash -n "${target}.tmp" 2>/dev/null; then
                mv -f "${target}.tmp" "$target" 2>/dev/null
                chmod +x "$target" 2>/dev/null || true
                ok_inst=true
                break
            else
                rm -f "${target}.tmp" 2>/dev/null
            fi
        done

        if [ "$ok_inst" = "true" ]; then
            ok "已自动配置快捷命令: ${C_BOLD}xraym${C_RESET} (以后可在任意终端直接输入 xraym 管理)"
        fi
    fi
}

latest_ver() {
    local tag
    tag=$(curl -fsSI -m 6 https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | sed -n 's|.*/tag/||p' | head -n1)
    [ -z "$tag" ] && tag=$(curl -fsSL -m 6 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
    [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]] && printf '%s' "$tag"
}

check_update_async() {
    [ -f "$BIN" ] || return 0
    (
        mkdir -p "$CONF_DIR" 2>/dev/null || true
        local tag; tag=$(latest_ver)
        if [ -n "$tag" ]; then
            printf '%s' "${tag#v}" > "$VER_CACHE" 2>/dev/null || true
        fi
    ) >/dev/null 2>&1 &
}

check_deps() {
    local missing="" cmd
    for cmd in curl unzip openssl jq; do command -v "$cmd" >/dev/null 2>&1 || missing+=" $cmd"; done
    if ! command -v setcap >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then missing+=" libcap2-bin"
        elif command -v apk >/dev/null 2>&1; then missing+=" libcap"; fi
    fi
    [ -z "$missing" ] && return 0
    info "安装必要系统依赖:${missing}..."
    if command -v apt-get >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ${missing} >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        apk update -q && apk add -q ${missing}
    else
        err "未找到包管理器，请手动安装:${missing}"; return 1
    fi
}

is_port_used() {
    local p="$1" proto="${2:-tcp}" hex
    hex=$(printf '%04X' "$p" 2>/dev/null)
    if command -v ss >/dev/null 2>&1; then
        case "$proto" in
            udp)  ss -uln 2>/dev/null | grep -Eq "[:.]${p}([^0-9]|$)" && return 0 ;;
            tcp)  ss -tln 2>/dev/null | grep -Eq "[:.]${p}([^0-9]|$)" && return 0 ;;
            both) ss -tlun 2>/dev/null | grep -Eq "[:.]${p}([^0-9]|$)" && return 0 ;;
        esac
    fi
    [ -n "$hex" ] || return 1
    local f
    if [ "$proto" != "udp" ]; then
        for f in /proc/net/tcp /proc/net/tcp6; do
            [ -r "$f" ] && awk -v h=":$hex" '$4=="0A" && index($2,h){f=1;exit} END{exit !f}' "$f" && return 0
        done
    fi
    if [ "$proto" != "tcp" ]; then
        for f in /proc/net/udp /proc/net/udp6; do
            [ -r "$f" ] && awk -v h=":$hex" '$4=="07" && index($2,h){f=1;exit} END{exit !f}' "$f" && return 0
        done
    fi
    return 1
}

ask_port() {
    local prompt="$1" def="$2" ignore_idx="${3:-}" proto="${4:-tcp}" p=""
    while true; do
        p=$(ask "$prompt" "$def")
        if [[ ! "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            err "端口无效，请输入 1-65535 纯数字"; continue
        fi
        if is_port_used "$p" "$proto"; then
            local own_port=""
            [ -n "$ignore_idx" ] && [ "$ignore_idx" -ge 0 ] 2>/dev/null && own_port=$(jq -r --argjson i "$ignore_idx" '.inbounds[$i].port // empty' "$CONF" 2>/dev/null)
            [ "$p" != "$own_port" ] && { err "端口 ${p} 已被系统外部占用，请更换"; continue; }
        fi
        echo "$p"; return 0
    done
}

rand_port() {
    local proto="${1:-tcp}" p
    while p=$((RANDOM % 55535 + 10000)); do is_port_used "$p" "$proto" || { echo "$p"; break; }; done
}

refresh_ips() {
    [ -n "$PUB_IPV4" ] || [ -n "$PUB_IPV6" ] && return 0
    # 极速本地路由查询 (0毫秒)
    if command -v ip >/dev/null 2>&1; then
        PUB_IPV4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Ev '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)' | head -n1 || true)
        PUB_IPV6=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Ev '^(fe80|fd00|::1)' | head -n1 || true)
    fi
    # 外部兜底探测 (仅当无本地公网 IP 时触发)
    if [ -z "$PUB_IPV4" ] && [ -z "$PUB_IPV6" ]; then
        PUB_IPV4=$(curl -fs4 -m 2 https://api.ipify.org 2>/dev/null || curl -fs4 -m 2 https://icanhazip.com 2>/dev/null || echo "")
        PUB_IPV6=$(curl -fs6 -m 2 https://api6.ipify.org 2>/dev/null || curl -fs6 -m 2 https://icanhazip.com 2>/dev/null || echo "")
    fi
}

enable_bbr() {
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw "bbr"; then
        echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
        sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
    fi
    local cur; cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "关闭")
    if [[ "$cur" == *"bbr"* ]]; then ok "BBR 拥塞控制: ${C_GREEN}开启${C_RESET}"; else warn "BBR: 未开启或内核未加载模块"; fi
}

# ------------------------------------------------------------------------------
# 2. 安全用户与服务生命周期
# ------------------------------------------------------------------------------
ensure_xray_user() {
    if ! id -u xray >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -M -d /nonexistent -U xray 2>/dev/null || adduser -S -D -H xray 2>/dev/null || true
    fi
    if [ -f "$BIN" ] && command -v setcap >/dev/null 2>&1; then
        setcap 'cap_net_bind_service=+ep' "$BIN" 2>/dev/null || true
    fi
    mkdir -p "$CONF_DIR" "$CERTS_DIR" /var/log/xray
    chown -R xray:xray "$CONF_DIR" /var/log/xray 2>/dev/null || true
    chmod 700 "$CONF_DIR" "$CERTS_DIR" 2>/dev/null || true
    if [ -f "$CONF" ]; then chmod 600 "$CONF" 2>/dev/null || true; fi
}

init_env() {
    ensure_xray_user
    if [ ! -s "$CONF" ]; then
        echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","fc00::/7","fe80::/10"],"outboundTag":"block"}]}}' > "$CONF"
        chown -R xray:xray "$CONF_DIR" 2>/dev/null || true; chmod 600 "$CONF" 2>/dev/null || true
    fi
}

is_running() {
    command -v pgrep >/dev/null 2>&1 && pgrep -x xray >/dev/null 2>&1 && return 0
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && systemctl is-active --quiet "$SVC_NAME" 2>/dev/null && return 0
    [ -f /run/xray.pid ] && kill -0 "$(cat /run/xray.pid 2>/dev/null)" 2>/dev/null && return 0
    killall -0 xray 2>/dev/null
}

svc() {
    local act="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl "$act" "$SVC_NAME" >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$SVC_NAME" "$act" >/dev/null 2>&1 || true
    else
        pkill -u xray -x xray >/dev/null 2>&1 || true
        if [ "$act" = "start" ] || [ "$act" = "restart" ]; then
            if id -u xray >/dev/null 2>&1; then
                su -s /bin/sh xray -c "nohup '$BIN' run -c '$CONF' >/dev/null 2>&1 &" >/dev/null 2>&1 || true
            else
                nohup "$BIN" run -c "$CONF" >/dev/null 2>&1 &
            fi
        fi
    fi
    local i=0
    case "$act" in
        start|restart) while [ "$i" -lt 15 ]; do is_running && return 0; sleep 0.2; i=$((i+1)); done; return 1 ;;
        stop)          while [ "$i" -lt 15 ]; do is_running || return 0; sleep 0.2; i=$((i+1)); done; return 1 ;;
    esac
    return 0
}

install_service() {
    ensure_xray_user
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Core Engine
After=network.target

[Service]
Type=simple
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=${BIN} run -c ${CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable xray >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        cat << 'EOF' > /etc/init.d/xray
#!/sbin/openrc-run
description="Xray Core Engine"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_user="xray:xray"
command_background=true
pidfile="/run/xray.pid"
export XRAY_LOCATION_ASSET="/usr/local/share/xray"
depend() { need net; }
EOF
        chmod +x /etc/init.d/xray; rc-update add xray default 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 3. 核心安装与证书生成
# ------------------------------------------------------------------------------
install_core() {
    info "查询 Xray 最新版本..."
    local ver cur_ver; ver=$(latest_ver); cur_ver=$(cur_core_ver)

    if [ -z "$ver" ]; then
        err "获取最新版本失败 (网络或 GitHub 限流)"
        [ -n "$cur_ver" ] && [[ "$(ask "是否重装当前版本 ${cur_ver}？[y/N]" "n")" =~ ^[Yy]$ ]] && ver="$cur_ver" || return 1
    elif [ -n "$cur_ver" ] && [ "${cur_ver#v}" = "${ver#v}" ]; then
        ok "当前已是最新版本 (${cur_ver})"
        [[ "$(ask "是否强制重新下载覆盖？[y/N]" "n")" =~ ^[Yy]$ ]] || return 0
    fi

    info "下载核心包: ${ver} (${ARCH})..."
    local tmp; tmp=$(mktemp -d) || { err "创建临时目录失败"; return 1; }
    if ! curl -fsSL --retry 2 -m 180 "https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${ARCH}.zip" -o "$tmp/x.zip"; then
        rm -rf "$tmp"; err "核心下载失败"; return 1
    fi
    unzip -qo "$tmp/x.zip" xray geoip.dat geosite.dat -d "$tmp/" 2>/dev/null || unzip -qo "$tmp/x.zip" xray -d "$tmp/"
    [ ! -x "$tmp/xray" ] && { rm -rf "$tmp"; err "核心包损坏或不可执行"; return 1; }

    local was_running=false; is_running && was_running=true
    svc stop >/dev/null 2>&1 || true

    mkdir -p /usr/local/share/xray
    install -m 755 "$tmp/xray" "$BIN"
    [ -f "$tmp/geoip.dat" ] && install -m 644 "$tmp/geoip.dat" /usr/local/share/xray/
    [ -f "$tmp/geosite.dat" ] && install -m 644 "$tmp/geosite.dat" /usr/local/share/xray/
    rm -rf "$tmp"

    init_env; install_service
    echo "${ver#v}" > "$VER_CACHE" 2>/dev/null || true
    [ "$was_running" = "true" ] && svc start
    ok "Xray 核心已成功就绪 (${ver})"
    sleep 1
}

ensure_self_cert() {
    local domain="${1:-www.apple.com}" crt="$CERTS_DIR/cert.crt" key="$CERTS_DIR/priv.key"
    mkdir -p "$CERTS_DIR" 2>/dev/null || true
    if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
            -keyout "$key" -out "$crt" -subj "/CN=${domain}" >/dev/null 2>&1
        chmod 600 "$key" "$crt" 2>/dev/null || true; chown -R xray:xray "$CERTS_DIR" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 4. 配置修改事务引擎 (自动校验、冲突断言与异常回滚)
# ------------------------------------------------------------------------------
apply_config() {
    local tmp_cfg="$1" err_msg="" bak_cfg="${CONF}.bak"
    [ ! -s "$tmp_cfg" ] || ! jq -e . "$tmp_cfg" >/dev/null 2>&1 && { rm -f "$tmp_cfg"; err "配置非法或为空"; return 1; }

    # 1. 端口冲突断言
    local dup_port
    dup_port=$(jq -r '
        def t: if .protocol == "hysteria" then "udp" elif .protocol == "shadowsocks" then "both" else "tcp" end;
        [.inbounds | to_entries[] | {idx: .key, port: .value.port, type: (.value | t)}] as $i |
        $i[] as $a | $i[] as $b | select($a.idx < $b.idx and $a.port == $b.port and ($a.type == "both" or $b.type == "both" or $a.type == $b.type)) | $a.port
    ' "$tmp_cfg" 2>/dev/null | head -n1)
    [ -n "$dup_port" ] && { rm -f "$tmp_cfg"; err "端口 ${dup_port} 在同协议族现有多个节点中重复绑定"; return 1; }

    # 2. Xray 原生语法校验
    if ! err_msg=$("$BIN" run -test -format=json -c "$tmp_cfg" 2>&1); then
        rm -f "$tmp_cfg"; err "内核配置校验未通过:"; echo -e "${C_DIM}${err_msg}${C_RESET}"; return 1
    fi

    # 3. 原子覆写并生效
    if [ -f "$CONF" ]; then cp -f "$CONF" "$bak_cfg" 2>/dev/null || true; fi
    if mv -f "$tmp_cfg" "$CONF" 2>/dev/null; then
        chown xray:xray "$CONF" 2>/dev/null || true
        chmod 600 "$CONF" 2>/dev/null || true
    else
        err "配置写入失败"; return 1
    fi

    if ! svc restart; then
        err "服务拉起失败，正在回滚原配置..."
        if [ -f "$bak_cfg" ]; then
            mv -f "$bak_cfg" "$CONF"
            svc restart
        fi
        if is_running; then ok "已恢复原配置"; else err "恢复后仍未运行，请检查日志"; fi
        return 1
    fi
    rm -f "$bak_cfg" 2>/dev/null || true
    ok "配置已校验并成功加载生效"
}

mutate_config() {
    local expr="$1"; shift; local tmp_cfg
    mk_tmp_cfg tmp_cfg || { err "无法分配临时缓冲"; return 1; }
    jq "$@" "$expr" "$CONF" > "$tmp_cfg" 2>/dev/null || { err "配置计算失败"; return 1; }
    apply_config "$tmp_cfg"
}

# ------------------------------------------------------------------------------
# 5. 链接构建与节点展示
# ------------------------------------------------------------------------------
build_link() {
    local target="$1" host="$2" proto pbk0=""
    proto=$(jq -r '.protocol // empty' <<< "$target" 2>/dev/null)
    if [ "$proto" = "vless" ]; then
        pbk0=$(jq -r '._meta.pbk // ""' <<< "$target" 2>/dev/null)
        if [ -z "$pbk0" ] && [ -x "$BIN" ]; then
            local priv; priv=$(jq -r '.streamSettings.realitySettings.privateKey // ""' <<< "$target" 2>/dev/null)
            [ -n "$priv" ] && pbk0=$("$BIN" x25519 -i "$priv" 2>/dev/null | awk -F': *' '/[Pp]ublic[ ]?[Kk]ey/{print $2}' | tr -d ' \r\n' | head -n1)
        fi
    fi

    jq -r --arg host "$host" --arg pbk0 "$pbk0" '
        .protocol as $p | .port as $port | (.tag // "node") as $tag | (._meta // {}) as $m | ($tag|@uri) as $tagq |
        if $p == "vless" then
            (.settings.clients[0].id // $m.uid // "") as $uid |
            (.streamSettings.realitySettings.shortIds[0] // $m.sid // "") as $sid |
            (.streamSettings.realitySettings.serverNames[0] // $m.sni // "www.apple.com") as $sni |
            (if ($m.pbk // "") != "" then $m.pbk else $pbk0 end) as $pbk |
            if (.streamSettings.network // $m.trans // "tcp") == "xhttp" then
                "vless://" + $uid + "@" + $host + ":" + ($port|tostring) + "?security=reality&encryption=none&pbk=" + $pbk + "&headerType=none&type=xhttp&path=" + ((.streamSettings.xhttpSettings.path // $m.path // "/xhttp")|@uri) + "&mode=auto&sni=" + $sni + "&sid=" + $sid + "#" + $tagq
            else
                "vless://" + $uid + "@" + $host + ":" + ($port|tostring) + "?security=reality&encryption=none&pbk=" + $pbk + "&headerType=none&type=tcp&flow=" + (.settings.clients[0].flow // $m.flow // "xtls-rprx-vision") + "&sni=" + $sni + "&sid=" + $sid + "#" + $tagq
            end
        elif $p == "trojan" then "trojan://" + ((.settings.clients[0].password // $m.pass // "")|@uri) + "@" + $host + ":" + ($port|tostring) + "?security=tls&allowInsecure=1&type=tcp&sni=" + (.streamSettings.tlsSettings.serverName // $m.sni // "www.apple.com") + "#" + $tagq
        elif $p == "hysteria" then "hysteria2://" + ((.settings.users[0].auth // $m.pass // "")|@uri) + "@" + $host + ":" + ($port|tostring) + "/?insecure=1&sni=" + ($m.sni // "www.apple.com") + "#" + $tagq
        elif $p == "shadowsocks" then "ss://" + (.settings.method // $m.method // "2022-blake3-aes-128-gcm") + ":" + ((.settings.password // $m.pass // "")|@uri) + "@" + $host + ":" + ($port|tostring) + "#" + $tagq
        elif $p == "vmess" then "vmess://" + ({v:"2",ps:$tag,add:$host,port:($port|tonumber),id:(.settings.clients[0].id // $m.uid // ""),aid:0,net:"ws",type:"none",host:(.streamSettings.wsSettings.host // ""),path:(.streamSettings.wsSettings.path // $m.path // "/ws"),tls:"none"}|tojson|@base64)
        else empty end
    ' <<< "$target"
}

render_node_table() {
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { echo -e "${C_DIM}(暂无任何配置的入站节点)${C_RESET}"; return 0; }

    echo -e "${C_DIM}序号  协议类型            端口     传输     别名 / 目标${C_RESET}"
    draw_line "-" "${C_DIM}"
    jq -c '.inbounds | to_entries[]' "$CONF" 2>/dev/null | while read -r item; do
        local idx port proto net tag target_desc proto_label
        idx=$(jq -r '.key' <<< "$item")
        port=$(jq -r '.value.port' <<< "$item")
        proto=$(jq -r '.value.protocol' <<< "$item")
        net=$(jq -r '.value.streamSettings.network // "tcp"' <<< "$item")
        tag=$(jq -r '.value.tag // "node"' <<< "$item")
        proto_label="$proto"
        case "$proto" in
            vless)       [ "$net" = "xhttp" ] && proto_label="VLESS (XHTTP)" || proto_label="VLESS (Vision)"; target_desc=$(jq -r '.value.streamSettings.realitySettings.serverNames[0] // "-"' <<< "$item") ;;
            hysteria)    proto_label="Hysteria 2"; net="udp/h3"; target_desc=$(jq -r '.value._meta.sni // "自签TLS"' <<< "$item") ;;
            trojan)      proto_label="Trojan"; target_desc=$(jq -r '.value.streamSettings.tlsSettings.serverName // "-"' <<< "$item") ;;
            shadowsocks) proto_label="Shadowsocks"; net="tcp,udp"; target_desc="2022-blake3" ;;
            vmess)       proto_label="VMess (WS)"; target_desc=$(jq -r '.value.streamSettings.wsSettings.path // "/ws"' <<< "$item") ;;
            *)           target_desc="-" ;;
        esac
        printf "%02d    %-18b  ${C_YELLOW}%-7s${C_RESET}  %-7s  %s ${C_DIM}(%s)${C_RESET}\n" "$idx" "$proto_label" "$port" "$net" "$tag" "$target_desc"
    done
    draw_line "-" "${C_DIM}"
}

print_node_card() {
    local target="$1" title="${2:-节点详细信息}"
    refresh_ips
    local tag proto port net
    tag=$(jq -r '.tag // "node"' <<< "$target")
    proto=$(jq -r '.protocol // "unknown"' <<< "$target")
    port=$(jq -r '.port // 0' <<< "$target")
    net=$(jq -r '.streamSettings.network // "tcp"' <<< "$target")

    local link4="" link6=""
    [ -n "$PUB_IPV4" ] && link4=$(build_link "$target" "$PUB_IPV4")
    [ -n "$PUB_IPV6" ] && link6=$(build_link "$target" "[${PUB_IPV6}]")

    echo ""
    draw_line "-" "${C_CYAN}"
    echo -e "${C_BOLD}[${title}] ${tag}${C_RESET}"
    echo -e "协议类型 : ${C_BOLD}${proto}${C_RESET} | 传输层: ${net} | 监听端口: ${port}"

    case "$proto" in
        vless)
            local sni uid pbk sid
            sni=$(jq -r '.streamSettings.realitySettings.serverNames[0] // "-"' <<< "$target")
            uid=$(jq -r '.settings.clients[0].id // "-"' <<< "$target")
            pbk=$(jq -r '._meta.pbk // "-"' <<< "$target")
            sid=$(jq -r '.streamSettings.realitySettings.shortIds[0] // "-"' <<< "$target")
            echo -e "伪装域名 : ${sni} (ShortID: ${sid})\n用户标识 : ${uid}"
            [ "$pbk" != "-" ] && echo -e "公钥密钥 : ${pbk}"
            ;;
        trojan|hysteria)
            local pass sni
            pass=$(jq -r '.settings.clients[0].password // .settings.users[0].auth // "-"' <<< "$target")
            sni=$(jq -r '.streamSettings.tlsSettings.serverName // ._meta.sni // "-"' <<< "$target")
            echo -e "伪装域名 : ${sni}\n认证密码 : ${pass}"
            ;;
        shadowsocks)
            local pass method
            pass=$(jq -r '.settings.password // "-"' <<< "$target")
            method=$(jq -r '.settings.method // "-"' <<< "$target")
            echo -e "加密方式 : ${method}\n预共享钥 : ${pass}"
            ;;
        vmess)
            local uid path
            uid=$(jq -r '.settings.clients[0].id // "-"' <<< "$target")
            path=$(jq -r '.streamSettings.wsSettings.path // "/ws"' <<< "$target")
            echo -e "用户标识 : ${uid}\nWS 路径  : ${path}"
            ;;
    esac

    if [ -n "$link4" ]; then
        echo -e "\n${C_BOLD}IPv4 分享链接:${C_RESET}\n${C_GREEN}${link4}${C_RESET}"
        command -v qrencode >/dev/null 2>&1 && { echo -e "\n${C_DIM}IPv4 二维码 (客户端扫码):${C_RESET}"; qrencode -t ANSIUTF8 "$link4" 2>/dev/null; }
    fi
    [ -n "$link6" ] && echo -e "\n${C_BOLD}IPv6 分享链接:${C_RESET}\n${C_GREEN}${link6}${C_RESET}"
    [ -z "$link4" ] && [ -z "$link6" ] && echo -e "\n${C_YELLOW}未检测到公网 IP，手动替换 127.0.0.1:${C_RESET}\n$(build_link "$target" "127.0.0.1")"
    draw_line "-" "${C_CYAN}"; echo ""
}

export_subscription() {
    [ ! -f "$CONF" ] && { err "配置文件不存在"; return 1; }
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { warn "暂无入站节点"; return 0; }

    refresh_ips; info "正在汇总节点链接..."
    local links4="" links6="" i item l4 l6
    for ((i=0; i<count; i++)); do
        item=$(jq -c --argjson i "$i" '.inbounds[$i]' "$CONF" 2>/dev/null)
        [ -z "$item" ] && continue
        [ -n "$PUB_IPV4" ] && l4=$(build_link "$item" "$PUB_IPV4") && [ -n "$l4" ] && links4+="${l4}"$'\n'
        [ -n "$PUB_IPV6" ] && l6=$(build_link "$item" "[${PUB_IPV6}]") && [ -n "$l6" ] && links6+="${l6}"$'\n'
    done

    echo ""
    draw_line "-" "${C_CYAN}"
    echo -e "${C_BOLD}[聚合订阅] 可直接复制导入客户端${C_RESET}"
    [ -n "$links4" ] && echo -e "\n${C_BOLD}IPv4 订阅 (Base64):${C_RESET}\n${C_GREEN}$(printf '%s' "$links4" | base64 | tr -d '\r\n')${C_RESET}"
    [ -n "$links6" ] && echo -e "\n${C_BOLD}IPv6 订阅 (Base64):${C_RESET}\n${C_GREEN}$(printf '%s' "$links6" | base64 | tr -d '\r\n')${C_RESET}"
    draw_line "-" "${C_CYAN}"; echo ""
}

# ------------------------------------------------------------------------------
# 6. 入站节点增删改 (极简直觉流)
# ------------------------------------------------------------------------------
add_node() {
    [ ! -f "$BIN" ] && { err "请先安装 Xray 核心 (菜单 7)"; sleep 1.2; return 1; }
    init_env

    echo -e "\n${C_BOLD}添加节点 - 选择协议${C_RESET}"
    draw_line "-"
    echo -e "${C_CYAN}1.${C_RESET} VLESS-REALITY (Vision)"
    echo -e "${C_CYAN}2.${C_RESET} Hysteria 2 (QUIC)"
    echo -e "${C_CYAN}3.${C_RESET} Trojan-TLS (自签证书)"
    echo -e "${C_CYAN}4.${C_RESET} Shadowsocks (2022-blake3)"
    echo -e "${C_CYAN}5.${C_RESET} VMess-WS (WebSocket)"
    echo -e "${C_DIM}0. 取消返回${C_RESET}"
    draw_line "-"

    local choice; choice=$(ask "选择协议 [1-5]" "1")
    [ "$choice" = "0" ] && return 0

    local def_ports=("" "443" "8443" "443" "8388" "80")
    local def_protos=("" "tcp" "udp" "tcp" "both" "tcp")
    local def_p="${def_ports[$choice]:-}" cur_proto_type="${def_protos[$choice]:-tcp}"
    [ -z "$def_p" ] && { err "无效选择"; sleep 1; return 1; }

    is_port_used "$def_p" "$cur_proto_type" && def_p=$(rand_port "$cur_proto_type")
    local port; port=$(ask_port "监听端口" "$def_p" "" "$cur_proto_type")
    local inb_data="" remark="" sni="www.apple.com"

    case "$choice" in
        1) # VLESS Reality Vision
            local keys; keys=$("$BIN" x25519)
            local priv; priv=$(awk -F': *' '/[Pp]rivate[ ]?[Kk]ey/{print $2}' <<< "$keys" | tr -d ' \r\n')
            local pub; pub=$(awk -F': *' '/[Pp]ublic[ ]?[Kk]ey/{print $2}' <<< "$keys" | tr -d ' \r\n')
            local sid; sid=$(openssl rand -hex 4)
            local uid; uid=$(gen_uuid)
            remark="VLESS-${port}"
            inb_data=$(jq -n --arg port "$port" --arg uid "$uid" --arg priv "$priv" --arg pbk "$pub" --arg sni "$sni" --arg sid "$sid" --arg rmk "$remark" \
                '{listen:"::",port:($port|tonumber),protocol:"vless",tag:$rmk,settings:{clients:[{id:$uid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$priv,shortIds:[$sid]}},sniffing:{enabled:true,destOverride:["http","tls","quic"]},_meta:{proto:"vless",trans:"tcp",sec:"reality",pbk:$pbk,sni:$sni,sid:$sid,uid:$uid,flow:"xtls-rprx-vision"}}')
            ;;
        2) # Hysteria 2
            local pass; pass=$(openssl rand -hex 8)
            ensure_self_cert "$sni"
            remark="Hy2-${port}"
            inb_data=$(jq -n --arg port "$port" --arg pass "$pass" --arg crt "$CERTS_DIR/cert.crt" --arg key "$CERTS_DIR/priv.key" --arg sni "$sni" --arg rmk "$remark" \
                '{listen:"::",port:($port|tonumber),protocol:"hysteria",tag:$rmk,settings:{version:2,users:[{auth:$pass}]},streamSettings:{network:"hysteria",security:"tls",tlsSettings:{certificates:[{certificateFile:$crt,keyFile:$key}],alpn:["h3"]}},_meta:{proto:"hysteria",pass:$pass,sni:$sni}}')
            ;;
        3) # Trojan-TLS
            local pass; pass=$(openssl rand -hex 8)
            ensure_self_cert "$sni"
            remark="Trojan-${port}"
            inb_data=$(jq -n --arg port "$port" --arg pass "$pass" --arg crt "$CERTS_DIR/cert.crt" --arg key "$CERTS_DIR/priv.key" --arg domain "$sni" --arg rmk "$remark" \
                '{listen:"::",port:($port|tonumber),protocol:"trojan",tag:$rmk,settings:{clients:[{password:$pass}]},streamSettings:{network:"tcp",security:"tls",tlsSettings:{certificates:[{certificateFile:$crt,keyFile:$key}],serverName:$domain}},sniffing:{enabled:true,destOverride:["http","tls"]},_meta:{proto:"trojan",pass:$pass,sni:$domain}}')
            ;;
        4) # Shadowsocks 2022
            local method="2022-blake3-aes-128-gcm" pass; pass=$(openssl rand -base64 16)
            remark="SS-${port}"
            inb_data=$(jq -n --arg port "$port" --arg pass "$pass" --arg method "$method" --arg rmk "$remark" \
                '{listen:"::",port:($port|tonumber),protocol:"shadowsocks",tag:$rmk,settings:{method:$method,password:$pass,network:"tcp,udp"},streamSettings:{network:"tcp"},_meta:{proto:"shadowsocks",method:$method,pass:$pass}}')
            ;;
        5) # VMess-WS
            local path uid
            path="/ws-$(openssl rand -hex 3)"
            uid=$(gen_uuid)
            remark="VMess-${port}"
            inb_data=$(jq -n --arg port "$port" --arg uid "$uid" --arg path "$path" --arg rmk "$remark" \
                '{listen:"::",port:($port|tonumber),protocol:"vmess",tag:$rmk,settings:{clients:[{id:$uid,alterId:0}]},streamSettings:{network:"ws",security:"none",wsSettings:{path:$path}},sniffing:{enabled:true,destOverride:["http","tls"]},_meta:{proto:"vmess",uid:$uid,path:$path}}')
            ;;
    esac

    [ -z "$inb_data" ] && return 1
    # shellcheck disable=SC2016
    mutate_config '.inbounds += [$inb]' --argjson inb "$inb_data" || return 1
    print_node_card "$inb_data" "节点添加成功"
    pause_tip
}

edit_node() {
    [ ! -f "$CONF" ] && { err "配置文件不存在"; sleep 1; return 1; }
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { info "当前暂无配置节点可修改"; sleep 1; return 0; }

    echo -e "\n${C_BOLD}修改节点${C_RESET}"
    render_node_table
    echo ""

    local sel; sel=$(ask "输入要修改的节点序号 (直接回车取消)" "")
    [ -z "$sel" ] && return 0
    [[ ! "$sel" =~ ^[0-9]+$ ]] && { err "序号须为纯数字"; sleep 1; return 1; }

    local target; target=$(jq -c --argjson i "$sel" '.inbounds[$i] // empty' "$CONF" 2>/dev/null)
    [ -z "$target" ] && { err "序号不存在"; sleep 1; return 1; }

    local cur_port cur_proto cur_tag meta
    read -r cur_port cur_proto _ cur_tag <<< "$(jq -r '[.port, .protocol, (.streamSettings.network // "tcp"), (.tag // "node")] | @tsv' <<< "$target")"
    meta=$(jq -r '._meta // {}' <<< "$target")

    local inb_proto="tcp"
    [ "$cur_proto" = "hysteria" ] && inb_proto="udp"
    [ "$cur_proto" = "shadowsocks" ] && inb_proto="both"

    echo ""
    info "修改节点 [${sel}] : ${cur_tag} (直接回车保持不变)"
    local new_port; new_port=$(ask_port "监听端口" "$cur_port" "$sel" "$inb_proto")
    local new_inb="$target"

    [ "$new_port" != "$cur_port" ] && new_inb=$(jq --arg port "$new_port" '.port = ($port|tonumber) | .tag = (.tag | sub("-[0-9]+$"; "-" + $port))' <<< "$new_inb")

    case "$cur_proto" in
        vless)
            local cur_sni; cur_sni=$(jq -r '.sni // "www.apple.com"' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名 (SNI)" "$cur_sni")
            [ "$new_sni" != "$cur_sni" ] && new_inb=$(jq --arg sni "$new_sni" '.streamSettings.realitySettings.serverNames = [$sni] | .streamSettings.realitySettings.dest = ($sni + ":443") | ._meta.sni = $sni' <<< "$new_inb")
            ;;
        trojan)
            local cur_sni; cur_sni=$(jq -r '.sni // "www.apple.com"' <<< "$meta")
            local cur_pass; cur_pass=$(jq -r '.pass // ""' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名" "$cur_sni")
            local new_pass; new_pass=$(ask "认证密码" "$cur_pass")
            [ "$new_sni" != "$cur_sni" ] && { ensure_self_cert "$new_sni"; new_inb=$(jq --arg sni "$new_sni" '.streamSettings.tlsSettings.serverName = $sni | ._meta.sni = $sni' <<< "$new_inb"); }
            [ "$new_pass" != "$cur_pass" ] && new_inb=$(jq --arg pass "$new_pass" '.settings.clients[0].password = $pass | ._meta.pass = $pass' <<< "$new_inb")
            ;;
        hysteria)
            local cur_sni; cur_sni=$(jq -r '.sni // "www.apple.com"' <<< "$meta")
            local cur_pass; cur_pass=$(jq -r '.pass // ""' <<< "$meta")
            local new_sni; new_sni=$(ask "伪装域名 (SNI)" "$cur_sni")
            local new_pass; new_pass=$(ask "认证密码" "$cur_pass")
            [ "$new_sni" != "$cur_sni" ] && { ensure_self_cert "$new_sni"; new_inb=$(jq --arg sni "$new_sni" '._meta.sni = $sni' <<< "$new_inb"); }
            [ "$new_pass" != "$cur_pass" ] && new_inb=$(jq --arg pass "$new_pass" '.settings.users[0].auth = $pass | ._meta.pass = $pass' <<< "$new_inb")
            ;;
        shadowsocks)
            local cur_pass; cur_pass=$(jq -r '.pass // ""' <<< "$meta")
            local new_pass; new_pass=$(ask "密钥密码" "$cur_pass")
            [ "$new_pass" != "$cur_pass" ] && new_inb=$(jq --arg pass "$new_pass" '.settings.password = $pass | ._meta.pass = $pass' <<< "$new_inb")
            ;;
        vmess)
            local cur_path; cur_path=$(jq -r '.path // "/ws"' <<< "$meta")
            local new_path; new_path=$(ask "WS 路由路径" "$cur_path")
            [ "$new_path" != "$cur_path" ] && new_inb=$(jq --arg path "$new_path" '.streamSettings.wsSettings.path = $path | ._meta.path = $path' <<< "$new_inb")
            ;;
    esac

    # shellcheck disable=SC2016
    if mutate_config '.inbounds[$i] = $inb' --argjson i "$sel" --argjson inb "$new_inb"; then
        ok "节点 [${sel}] 配置已更新生效"
        sleep 1
    fi
}

delete_node() {
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { info "当前暂无配置节点可删除"; sleep 1; return 0; }

    echo -e "\n${C_BOLD}删除节点${C_RESET}"
    render_node_table
    echo ""

    local sel; sel=$(ask "输入要删除的节点序号 (直接回车取消)" "")
    [ -z "$sel" ] && return 0
    [[ ! "$sel" =~ ^[0-9]+$ ]] && { err "序号须为纯数字"; sleep 1; return 1; }

    local tag; tag=$(jq -r --argjson i "$sel" '.inbounds[$i].tag // empty' "$CONF" 2>/dev/null)
    [ -z "$tag" ] && { err "序号不存在"; sleep 1; return 1; }

    [[ "$(ask "确认删除节点 [${sel}] (${tag})？[y/N]" "n")" =~ ^[Yy]$ ]] || { info "已取消删除"; sleep 0.8; return 0; }
    # shellcheck disable=SC2016
    if mutate_config 'del(.inbounds[$i])' --argjson i "$sel"; then
        ok "节点 [${sel}] (${tag}) 已删除"
        sleep 1
    fi
}

show_nodes() {
    [ ! -f "$CONF" ] && { err "配置文件不存在"; sleep 1; return 1; }
    local count; count=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { info "当前暂无配置节点"; sleep 1; return 0; }

    echo -e "\n${C_BOLD}[节点列表] 共 ${count} 个节点${C_RESET}"
    render_node_table

    echo ""
    local opt; opt=$(ask "输入序号查看链接 (sub 导出订阅, 回车返回)" "")
    [ -z "$opt" ] && return 0

    if [ "$opt" = "sub" ]; then
        export_subscription
        pause_tip
    elif [[ "$opt" =~ ^[0-9]+$ ]] && [ "$opt" -lt "$count" ]; then
        local target; target=$(jq -c --argjson i "$opt" '.inbounds[$i] // empty' "$CONF" 2>/dev/null)
        if [ -n "$target" ]; then
            print_node_card "$target" "节点详细信息"
            pause_tip
        fi
    else
        err "无效序号: ${opt}"
        sleep 1
    fi
}

# ------------------------------------------------------------------------------
# 7. 服务运行控制与彻底卸载
# ------------------------------------------------------------------------------
manage_service() {
    clear 2>/dev/null || true
    local st_desc="${C_RED}[已停止]${C_RESET}"; is_running && st_desc="${C_GREEN}[运行中]${C_RESET}"

    echo -e "${C_BOLD}服务管理${C_RESET} [当前: ${st_desc}]"
    draw_line "-"
    echo -e "${C_CYAN}1.${C_RESET} 重启服务"
    echo -e "${C_CYAN}2.${C_RESET} 停止服务"
    echo -e "${C_CYAN}3.${C_RESET} 启动服务"
    echo -e "${C_CYAN}4.${C_RESET} 实时日志"
    echo -e "${C_DIM}0. 返回菜单${C_RESET}"
    draw_line "-"

    case "$(ask "请选择操作" "0")" in
        1)
            if svc restart; then ok "服务已重启"; else err "重启失败，请检查日志"; fi
            sleep 0.8
            ;;
        2)
            if svc stop; then ok "服务已停止"; else err "停止失败"; fi
            sleep 0.8
            ;;
        3)
            if svc start; then ok "服务已启动"; else err "启动失败，请检查端口与日志"; fi
            sleep 0.8
            ;;
        4)
            if [ -f /var/log/xray/error.log ]; then
                info "Ctrl+C 退出日志监控"; tail -n 40 -f /var/log/xray/error.log
            elif command -v journalctl >/dev/null 2>&1; then
                info "Ctrl+C 退出日志监控"; journalctl -u xray -f -n 40
            else
                warn "未发现日志文件"; sleep 1
            fi
            ;;
        *) return 0 ;;
    esac
}

uninstall_xray() {
    echo ""
    [[ "$(ask "高危确认: 确定彻底卸载 Xray、删除证书及所有配置数据？[y/N]" "n")" =~ ^[Yy]$ ]] || { info "已取消卸载"; return 0; }

    info "停止服务并清理进程..."
    svc stop >/dev/null 2>&1 || true
    pkill -9 -u xray 2>/dev/null || true; pkill -9 -x xray 2>/dev/null || true

    info "注销系统服务守护..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable xray 2>/dev/null || true; rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload 2>/dev/null || true; systemctl reset-failed 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update del xray default 2>/dev/null || true; rm -f /etc/init.d/xray
    fi

    info "清理文件目录..."
    rm -rf "$BIN" "/usr/local/bin/xraym" "$CONF_DIR" "/usr/local/share/xray" "/var/log/xray" "/run/xray.pid"
    userdel -r xray 2>/dev/null || deluser xray 2>/dev/null || true

    ok "Xray 环境已彻底卸载清除"; exit 0
}

# ------------------------------------------------------------------------------
# 8. 极简看板主入口
# ------------------------------------------------------------------------------
main_menu() {
    check_deps || { err "环境依赖缺失，终止"; exit 1; }
    setup_shortcut; refresh_ips; check_update_async

    while true; do
        clear 2>/dev/null || true
        local st_badge="${C_RED}[已停止]${C_RESET}"; is_running && st_badge="${C_GREEN}[运行中]${C_RESET}"
        local ver; ver=$(cur_core_ver); [ -z "$ver" ] && ver="未安装"
        local update_hint=""
        if [ "$ver" != "未安装" ] && [ -f "$VER_CACHE" ]; then
            local latest_ver_val; latest_ver_val=$(tr -d ' \r\n' < "$VER_CACHE" 2>/dev/null || true)
            if [ -n "$latest_ver_val" ] && [ "${ver#v}" != "${latest_ver_val#v}" ]; then
                update_hint=" ${C_YELLOW}(可更新: v${latest_ver_val#v})${C_RESET}"
            fi
        fi

        local node_cnt; node_cnt=$(jq '.inbounds | length' "$CONF" 2>/dev/null || echo 0)
        local bbr_st; bbr_st=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "关闭")
        local bbr_badge="${C_DIM}${bbr_st}${C_RESET}"; [[ "$bbr_st" == *"bbr"* ]] && bbr_badge="${C_GREEN}开启${C_RESET}"

        local ip_summary=""
        if [ -n "$PUB_IPV4" ] && [ -n "$PUB_IPV6" ]; then
            ip_summary="IPv4: ${PUB_IPV4} | IPv6: ${PUB_IPV6}"
        elif [ -n "$PUB_IPV4" ]; then
            ip_summary="IPv4: ${PUB_IPV4}"
        elif [ -n "$PUB_IPV6" ]; then
            ip_summary="IPv6: ${PUB_IPV6}"
        else
            ip_summary="${C_DIM}离线/局域网${C_RESET}"
        fi

        printf "%b\n" "\
${C_BOLD}Xray Core${C_RESET} ${C_CYAN}${ver}${C_RESET}${update_hint} ${st_badge} | BBR: ${bbr_badge}
节点: ${node_cnt} 个 | 网络: ${ip_summary}"
        draw_line "-"
        printf "%b\n" "\
${C_CYAN}1.${C_RESET} 节点列表
${C_CYAN}2.${C_RESET} 添加节点
${C_CYAN}3.${C_RESET} 修改节点
${C_CYAN}4.${C_RESET} 删除节点
${C_CYAN}5.${C_RESET} 服务管理
${C_CYAN}6.${C_RESET} BBR 加速
${C_CYAN}7.${C_RESET} $([ "$ver" = "未安装" ] && echo "安装核心" || echo "核心更新")
${C_RED}8.${C_RESET} 卸载清除
${C_DIM}0. 退出面板${C_RESET}"
        draw_line "-"

        case "$(ask "请选择操作" "0")" in
            1) show_nodes ;;
            2) add_node ;;
            3) edit_node ;;
            4) delete_node ;;
            5) manage_service ;;
            6) enable_bbr; sleep 1 ;;
            7) install_core ;;
            8) uninstall_xray ;;
            0|q|quit)
                clear 2>/dev/null || true
                echo -e "\n${C_CYAN}[提示]${C_RESET} 已退出 Xray 管理面板\n"
                exit 0
                ;;
            *) err "请输入有效选项 [0-8]"; sleep 0.6 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu "$@"
fi
