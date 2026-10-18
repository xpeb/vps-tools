#!/bin/sh
# Xray 管理面板（Debian systemd / Alpine OpenRC）
# 界面参照面板式双列菜单；协议与字段依据 https://xtls.github.io
# 直接运行即进入面板，无需命令行参数。

XRAY_BIN="/usr/local/bin/xray"
CONF_DIR="/usr/local/etc/xray"
CONF_FILE="${CONF_DIR}/config.json"
PANEL_DIR="${CONF_DIR}/panel"
CERT_DIR="${CONF_DIR}/certs"
ASSET_DIR="/usr/local/share/xray"
LOG_DIR="/var/log/xray"
RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/latest/download"

OS=""
INIT=""
MACHINE=""
RUN_USER="nobody"
RUN_GROUP=""
SERVER_IP=""
TMP_DIR=""
FG=""
BG=""
DIM=""
BOLD=""
OFF=""
RST=""
OSC_RESET=""
W=42
HR=""

cleanup() {
    if [ -n "${TMP_DIR:-}" ]; then
        rm -rf "$TMP_DIR"
        TMP_DIR=""
    fi
    printf '%s%s' "${OSC_RESET:-}" "${RST:-}"
}
trap 'cleanup; exit 130' INT TERM
trap 'cleanup' EXIT

init_color() {
    BOLD=$(printf '\033[1m')
    OFF=$(printf '\033[22m')
    RST=$(printf '\033[0m')
    HR=$(awk -v n="$W" 'BEGIN {for (i = 0; i < n; i++) printf "─"}')
    case "${TERM:-}" in
        linux | dumb | vt100 | vt220 | cons25)
            FG=$(printf '\033[32m')
            BG=
            DIM=$(printf '\033[2m')
            ;;
        *)
            FG=$(printf '\033[38;2;109;206;154m')
            BG=$(printf '\033[48;2;11;18;32m')
            DIM=$(printf '\033[38;2;61;120;98m')
            printf '\033]11;#0B1220\007\033]10;#6DCE9A\007'
            OSC_RESET=$(printf '\033]111\007\033]110\007')
            ;;
    esac
}

paint() {
    printf '%s%s' "$BG" "$FG"
}

cls() {
    paint
    printf '\033[H\033[2J'
}

dwidth() {
    printf '%s' "$1" | LC_ALL=C awk '
        BEGIN {
            w = 0
            for (i = 0; i < 256; i++) {
                byte[sprintf("%c", i)] = i
            }
        }
        {
            i = 1
            n = length($0)
            while (i <= n) {
                b = byte[substr($0, i, 1)]
                if (b < 128) {
                    w++
                    i++
                } else if (b >= 228 && b <= 233) {
                    w += 2
                    i += 3
                } else if (b >= 240) {
                    w += 2
                    i += 4
                } else if (b >= 224) {
                    w++
                    i += 3
                } else if (b >= 192) {
                    w++
                    i += 2
                } else {
                    i++
                }
            }
        }
        END { printf "%d", w }
    '
}

pad() {
    text=$1
    width=$2
    have=$(dwidth "$text")
    need=$((width - have))
    [ "$need" -lt 0 ] && need=0
    printf '%s%*s' "$text" "$need" ""
}

line3() {
    left=$1
    mid=$2
    right=$3
    gap=$((W - $(dwidth "$left") - $(dwidth "$mid") - $(dwidth "$right")))
    [ "$gap" -lt 2 ] && gap=2
    g1=$((gap / 2))
    g2=$((gap - g1))
    printf '%s%*s%s%*s%s\n' "$left" "$g1" "" "$mid" "$g2" "" "$right"
}

rule() {
    printf '%s%s%s\n' "$DIM" "$HR" "$FG"
}

title() {
    printf '%s' "$BOLD"
    if [ -n "$1" ]; then
        line3 "Xray 管理面板" "" "$1"
    else
        printf 'Xray 管理面板\n'
    fi
    printf '%s' "$OFF"
    rule
}

pair() {
    left=$(printf '%-3s%s' "$1" "$2")
    right=$(printf '%-3s%s' "$3" "$4")
    printf '%s%s\n' "$(pad "$left" 22)" "$right"
}

kv() {
    printf '%s%s\n' "$(pad "$1" 8)" "$2"
}

pause_back() {
    printf '\n请按回车返回...'
    read -r _ </dev/tty || true
}

notice() {
    cls
    title
    printf '\n'
    printf '%s\n' "$1"
    pause_back
}

read_choice() {
    hint=$1
    printf '\n请选择 [%s]: ' "$hint"
    read -r CHOICE </dev/tty || CHOICE=
    CHOICE=$(printf '%s' "$CHOICE" | tr -d ' \t')
}

ask() {
    prompt=$1
    def=${2:-}
    printf '%s' "$prompt" >/dev/tty
    if [ -n "$def" ]; then
        printf ' [%s]' "$def" >/dev/tty
    fi
    printf ': ' >/dev/tty
    read -r ans </dev/tty || ans=
    if [ -z "$ans" ]; then
        printf '%s' "$def"
    else
        printf '%s' "$ans"
    fi
}

json_escape() {
    printf '%s' "$1" | awk '
        BEGIN { ORS = "" }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
            if (NR > 1) printf "\\n"
            printf "%s", $0
        }
    '
}

b64url() {
    if printf '' | base64 -w 0 >/dev/null 2>&1; then
        printf '%s' "$1" | base64 -w 0
    else
        printf '%s' "$1" | base64 | tr -d '\n'
    fi | tr '+/' '-_' | tr -d '='
}

urlencode() {
    printf '%s' "$1" | awk '
        BEGIN {
            for (i = 0; i < 256; i++) {
                c = sprintf("%c", i)
                o[c] = sprintf("%%%02X", i)
            }
        }
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c
                else printf "%s", o[c]
            }
        }
    '
}

rand_b64() {
    openssl rand -base64 "$1" | tr -d '\n'
}

rand_hex() {
    openssl rand -hex "$1" | tr -d '\n'
}

is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
    esac
    return 0
}

valid_port() {
    is_number "$1" || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_loopback() {
    case "$1" in
        127.* | ::1 | localhost) return 0 ;;
    esac
    return 1
}

detect_os() {
    [ -r /etc/os-release ] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian | ubuntu | raspbian | linuxmint | kali | pop) OS=debian ;;
        alpine) OS=alpine ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*) OS=debian ;;
                *) return 1 ;;
            esac
            ;;
    esac
    if [ "$OS" = debian ]; then
        command -v systemctl >/dev/null 2>&1 || return 1
        INIT=systemd
    else
        command -v rc-service >/dev/null 2>&1 || return 1
        INIT=openrc
    fi
    return 0
}

detect_arch() {
    case "$(uname -m)" in
        i386 | i686) MACHINE=32 ;;
        amd64 | x86_64) MACHINE=64 ;;
        armv5tel) MACHINE=arm32-v5 ;;
        armv6l)
            MACHINE=arm32-v6
            grep -q ' vfp' /proc/cpuinfo 2>/dev/null || MACHINE=arm32-v5
            ;;
        armv7 | armv7l)
            MACHINE=arm32-v7a
            grep -q ' vfp' /proc/cpuinfo 2>/dev/null || MACHINE=arm32-v5
            ;;
        armv8 | aarch64) MACHINE=arm64-v8a ;;
        mips) MACHINE=mips32 ;;
        mipsle) MACHINE=mips32le ;;
        mips64)
            MACHINE=mips64
            if command -v lscpu >/dev/null 2>&1 && lscpu 2>/dev/null | grep -q 'Little Endian'; then
                MACHINE=mips64le
            fi
            ;;
        mips64le) MACHINE=mips64le ;;
        ppc64) MACHINE=ppc64 ;;
        ppc64le) MACHINE=ppc64le ;;
        riscv64) MACHINE=riscv64 ;;
        s390x) MACHINE=s390x ;;
        *) return 1 ;;
    esac
    return 0
}

private_ip() {
    case "$1" in
        10.* | 127.* | 192.168.* | 169.254.* | 0.*) return 0 ;;
        172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].*) return 0 ;;
        100.6[4-9].* | 100.[7-9][0-9].* | 100.1[0-1][0-9].* | 100.12[0-7].*) return 0 ;;
    esac
    return 1
}

detect_ip() {
    SERVER_IP=
    if command -v ip >/dev/null 2>&1; then
        SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    fi
    if [ -z "$SERVER_IP" ] || private_ip "$SERVER_IP"; then
        pub=$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
        case "$pub" in
            '' | *[!0-9.]*) ;;
            *) SERVER_IP=$pub ;;
        esac
    fi
    if { [ -z "$SERVER_IP" ] || private_ip "$SERVER_IP"; } && command -v hostname >/dev/null 2>&1; then
        SERVER_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
    fi
    case "$SERVER_IP" in
        '' | 127.*) SERVER_IP=YOUR_SERVER_IP ;;
    esac
}

prepare_user() {
    id nobody >/dev/null 2>&1 || return 1
    RUN_GROUP=$(id -gn nobody)
    return 0
}

svc() {
    op=$1
    if [ "$INIT" = systemd ]; then
        case "$op" in
            active) systemctl is-active --quiet xray ;;
            enabled) systemctl is-enabled --quiet xray ;;
            enable) systemctl enable xray >/dev/null 2>&1 ;;
            disable) systemctl disable xray >/dev/null 2>&1 ;;
            start) systemctl start xray ;;
            restart) systemctl restart xray ;;
            stop) systemctl stop xray ;;
            reload) systemctl daemon-reload ;;
        esac
        return $?
    fi
    case "$op" in
        active) rc-service xray status 2>/dev/null | grep -qi started ;;
        enabled) [ -e /etc/runlevels/default/xray ] ;;
        enable) rc-update add xray default >/dev/null 2>&1 ;;
        disable) rc-update del xray >/dev/null 2>&1 ;;
        start) rc-service xray start ;;
        restart) rc-service xray restart ;;
        stop) rc-service xray stop ;;
        reload) return 0 ;;
    esac
}

svc_active() {
    [ -x "$XRAY_BIN" ] || return 1
    svc active
}

status_word() {
    if [ ! -x "$XRAY_BIN" ]; then
        printf '未安装'
        return
    fi
    if svc_active; then
        printf '运行中'
    else
        printf '已停止'
    fi
}

version_word() {
    if [ -n "${VER_CACHE:-}" ]; then
        printf '%s' "$VER_CACHE"
        return
    fi
    if [ ! -x "$XRAY_BIN" ]; then
        VER_CACHE='-'
        printf '%s' "$VER_CACHE"
        return
    fi
    ver=$("$XRAY_BIN" version 2>/dev/null | awk 'NR == 1 {print $2; exit}')
    case "$ver" in
        '') VER_CACHE='-' ;;
        v*) VER_CACHE=$ver ;;
        *) VER_CACHE="v${ver}" ;;
    esac
    printf '%s' "$VER_CACHE"
}

inbound_count() {
    n=0
    for f in "$PANEL_DIR"/*.env; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    printf '%s' "$n"
}

draw_main() {
    cls
    title
    st=$(status_word)
    ver=$(version_word)
    n=$(inbound_count)
    case "$st" in
        运行中) mark='●' ;;
        *) mark='○' ;;
    esac
    line3 "${mark} ${st}" "$ver" "入站 ${n}"
    rule
    printf '\n'
    pair 1 安装内核 6 查看日志
    pair 2 升级内核 7 添加入站
    pair 3 启动内核 8 修改入站
    pair 4 停止内核 9 分享入站
    pair 5 卸载内核 10 删除入站
    read_choice "回车退出"
}

page_head() {
    cls
    title "$1"
    printf '\n'
}

need_kernel() {
    if [ -x "$XRAY_BIN" ]; then
        return 0
    fi
    notice "尚未安装内核
请先选择 1  安装内核"
    return 1
}

pkg_install() {
    if [ "$OS" = debian ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y "$@"
    else
        apk add --no-cache "$@"
    fi
}

install_packages() {
    if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 \
        && command -v openssl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
        return 0
    fi
    printf '正在安装依赖...\n'
    pkg_install curl unzip ca-certificates openssl
}

download() {
    curl -fL --retry 5 --retry-delay 2 -o "$2" "$1"
}

abort_dl() {
    rm -rf "$TMP_DIR"
    TMP_DIR=
    notice "$1"
}

install_binary() {
    force=$1
    if [ -x "$XRAY_BIN" ] && [ "$force" -eq 0 ]; then
        return 0
    fi
    detect_arch || {
        notice "不支持的架构: $(uname -m)"
        return 1
    }
    TMP_DIR=$(mktemp -d)
    zip="${TMP_DIR}/Xray-linux-${MACHINE}.zip"
    url="${RELEASE_BASE}/Xray-linux-${MACHINE}.zip"
    printf '正在下载内核...\n'
    if ! download "$url" "$zip"; then
        abort_dl "下载失败"
        return 1
    fi
    printf '正在校验...\n'
    if ! download "${url}.dgst" "${zip}.dgst"; then
        abort_dl "校验文件下载失败"
        return 1
    fi
    expect=$(awk -F '= ' '/256=/ {print $2; exit}' "${zip}.dgst" | tr -d ' \r' | tr 'A-F' 'a-f')
    got=$(sha256sum "$zip" | awk '{print $1}' | tr 'A-F' 'a-f')
    if [ -z "$expect" ] || [ "$expect" != "$got" ]; then
        abort_dl "SHA256 校验失败"
        return 1
    fi
    if ! unzip -qo "$zip" -d "$TMP_DIR/xray"; then
        abort_dl "解压失败"
        return 1
    fi
    install -m 755 "${TMP_DIR}/xray/xray" "$XRAY_BIN"
    install -d -m 755 "$ASSET_DIR"
    if [ -f "${TMP_DIR}/xray/geoip.dat" ] && [ -f "${TMP_DIR}/xray/geosite.dat" ]; then
        install -m 644 "${TMP_DIR}/xray/geoip.dat" "${ASSET_DIR}/geoip.dat"
        install -m 644 "${TMP_DIR}/xray/geosite.dat" "${ASSET_DIR}/geosite.dat"
    fi
    if id nobody >/dev/null 2>&1; then
        chown "nobody:$(id -gn nobody)" "$ASSET_DIR" "${ASSET_DIR}/geoip.dat" "${ASSET_DIR}/geosite.dat" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
    TMP_DIR=
    VER_CACHE=
    return 0
}

install_service() {
    prepare_user || {
        notice "系统没有 nobody 用户"
        return 1
    }
    install -d -m 755 "$CONF_DIR" "$PANEL_DIR" "$CERT_DIR" "$LOG_DIR"
    chown root:root "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    touch "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"
    chown "${RUN_USER}:${RUN_GROUP}" "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"
    chmod 600 "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"
    install_logrotate
    write_units
}

write_units() {
    prepare_user || return 1
    if [ "$INIT" = systemd ]; then
        cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=${RUN_USER}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=${ASSET_DIR}
Environment=XRAY_JSON_STRICT=true
ExecStart=${XRAY_BIN} run -config ${CONF_FILE}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 /etc/systemd/system/xray.service
        svc reload
    else
        cat >/etc/init.d/xray <<EOF
#!/sbin/openrc-run

name="Xray Daemon"
description="A unified platform for anti-censorship"
supervisor=supervise-daemon
respawn_delay=5
respawn_max=2
respawn_period=600
pidfile="/run/\${RC_SVCNAME}.pid"
rc_ulimit="-n 1024000 -u 1024000"
capabilities="^cap_net_bind_service,^cap_net_admin,^cap_net_raw"
extra_commands="checkconfig"
env="XRAY_LOCATION_ASSET=${ASSET_DIR}/"
command="${XRAY_BIN}"
command_user="${RUN_USER}:${RUN_GROUP}"
command_args="run -config ${CONF_FILE}"
required_files="${CONF_FILE}"

depend() {
    need net
    after firewall
}

checkconfig() {
    export \$env
    \$command run -test -config ${CONF_FILE}
    eend \$?
}
EOF
        chmod 755 /etc/init.d/xray
    fi
}

unit_ok() {
    if [ "$INIT" = systemd ]; then
        grep -q 'XRAY_JSON_STRICT=true' /etc/systemd/system/xray.service 2>/dev/null
    else
        [ -f /etc/init.d/xray ] && ! grep -q 'start_pre' /etc/init.d/xray
    fi
}

install_logrotate() {
    if ! command -v logrotate >/dev/null 2>&1; then
        printf '正在安装日志轮转...\n'
        pkg_install logrotate || {
            printf '日志轮转安装失败，不影响内核运行\n'
            return 0
        }
    fi
    install -d -m 755 /etc/logrotate.d
    # Xray 不会重新打开日志，必须 copytruncate，否则轮转后仍写入旧文件。
    cat >/etc/logrotate.d/xray <<EOF
${LOG_DIR}/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
    chmod 644 /etc/logrotate.d/xray
    if [ "$INIT" = systemd ]; then
        systemctl enable --now logrotate.timer >/dev/null 2>&1 || true
    elif [ -x /etc/init.d/crond ]; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    fi
}

svc_start() {
    svc enabled || svc enable || true
    svc start
}

install_core() {
    page_head "$1"
    install_packages || {
        notice "依赖安装失败"
        return 1
    }
    paint
    install_binary "$2" || return 1
    install_service
}

action_install() {
    if [ -x "$XRAY_BIN" ]; then
        notice "内核已安装
请使用 2  升级内核"
        return
    fi
    install_core "安装内核" 0 || return
    if [ ! -f "$CONF_FILE" ]; then
        rebuild_config || {
            notice "写入空配置失败"
            return
        }
    fi
    notice "内核已安装
版本  $(version_word)
请选择 7  添加入站，再选择 3  启动内核"
}

action_upgrade() {
    if ! need_kernel; then
        return
    fi
    was=0
    svc_active && was=1
    install_core "升级内核" 1 || return
    if [ "$was" -eq 1 ]; then
        svc enabled || svc enable || true
        if svc restart; then
            notice "内核已升级并重新启动
版本  $(version_word)"
        else
            notice "内核已升级，但启动失败
请查看 6  日志"
        fi
    else
        notice "内核已升级
版本  $(version_word)
当前未启动"
    fi
}

action_start() {
    if ! need_kernel; then
        return
    fi
    if [ ! -f "$CONF_FILE" ]; then
        rebuild_config || true
    fi
    if svc_active; then
        notice "内核已在运行"
        return
    fi
    unit_ok || write_units
    if svc_start; then
        notice "内核已启动"
    else
        notice "启动失败
请查看 6  日志"
    fi
}

action_stop() {
    if ! need_kernel; then
        return
    fi
    if ! svc_active; then
        notice "内核未在运行"
        return
    fi
    if svc stop; then
        notice "内核已停止"
    else
        notice "停止失败"
    fi
}

action_uninstall() {
    if [ ! -x "$XRAY_BIN" ] && [ ! -f /etc/systemd/system/xray.service ] && [ ! -f /etc/init.d/xray ]; then
        notice "内核未安装"
        return
    fi
    page_head "卸载内核"
    printf '1  卸载程序，保留配置\n'
    printf '2  卸载并删除配置与日志\n'
    read_choice "回车返回"
    case "$CHOICE" in
        1) purge=0 ;;
        2) purge=1 ;;
        *) return ;;
    esac
    svc_active && svc stop || true
    svc disable || true
    if [ "$INIT" = systemd ]; then
        rm -f /etc/systemd/system/xray.service
        svc reload >/dev/null 2>&1 || true
    else
        rm -f /etc/init.d/xray
    fi
    rm -f "$XRAY_BIN"
    if [ "$purge" -eq 1 ]; then
        rm -f /etc/logrotate.d/xray
        rm -rf "$CONF_DIR" "$LOG_DIR" "$ASSET_DIR"
        notice "内核、配置和日志已删除"
    else
        notice "内核已卸载
配置仍保留在 ${CONF_DIR}"
    fi
}

action_logs() {
    page_head "查看日志"
    printf '1  错误日志\n'
    printf '2  访问日志\n'
    read_choice "回车返回"
    case "$CHOICE" in
        1) file="${LOG_DIR}/error.log" ;;
        2) file="${LOG_DIR}/access.log" ;;
        *) return ;;
    esac
    page_head "查看日志"
    if [ ! -s "$file" ]; then
        printf '暂无日志\n'
    else
        tail -n 40 "$file"
    fi
    pause_back
}

FIELDS="IB_ID TAG PROTO LISTEN PORT SS_METHOD SS_PASSWORD SOCKS_USER SOCKS_PASS SOCKS_UDP TROJAN_PASSWORD VLESS_ID VLESS_FLOW HY_AUTH BRUTAL_UP BRUTAL_DOWN HY_MASQ SNI CERT KEY SELF_SIGNED ACME CERT_SHA"

reset_ib() {
    for key in $FIELDS; do
        eval "$key="
    done
    SOCKS_UDP=1
    SELF_SIGNED=0
    ACME=0
}

load_ib() {
    reset_ib
    # shellcheck disable=SC1090
    . "$1"
}

qv() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

save_ib() {
    file=$1
    [ "$PROTO" = vless ] && VLESS_FLOW=xtls-rprx-vision
    install -d -m 755 "$PANEL_DIR"
    old_umask=$(umask)
    umask 077
    : >"$file"
    for key in $FIELDS; do
        eval "val=\${$key}"
        printf "%s='%s'\n" "$key" "$(qv "$val")" >>"$file"
    done
    umask "$old_umask"
    chmod 600 "$file"
}

ib_rec() {
    (
        reset_ib
        # shellcheck disable=SC1090
        . "$1"
        printf '%s|%s|%s|%s' "$IB_ID" "$PORT" "$PROTO" "${SOCKS_UDP:-1}"
    )
}

proto_kind() {
    case "$1" in
        shadowsocks) printf both ;;
        socks)
            if [ "${2:-1}" = 1 ]; then
                printf both
            else
                printf tcp
            fi
            ;;
        trojan | vless) printf tcp ;;
        hysteria) printf udp ;;
        *) printf tcp ;;
    esac
}

port_busy() {
    want=$1
    kind=$2
    skip=${3:-}
    for f in "$PANEL_DIR"/*.env; do
        [ -f "$f" ] || continue
        rec=$(ib_rec "$f")
        id=${rec%%|*}
        rest=${rec#*|}
        p=${rest%%|*}
        rest=${rest#*|}
        other=${rest%%|*}
        udp=${rest#*|}
        [ -n "$skip" ] && [ "$id" = "$skip" ] && continue
        [ "$p" = "$want" ] || continue
        okind=$(proto_kind "$other" "$udp")
        case "$kind:$okind" in
            tcp:udp | udp:tcp) ;;
            *) return 0 ;;
        esac
    done
    return 1
}

suggest_port() {
    p=$1
    kind=$2
    skip=${3:-}
    while port_busy "$p" "$kind" "$skip" || os_port_busy "$p" "$kind"; do
        if [ "$p" -eq 443 ]; then
            p=8443
            continue
        fi
        p=$((p + 1))
        [ "$p" -le 65535 ] || return 1
    done
    printf '%s' "$p"
}

os_port_busy() {
    port=$1
    kind=$2
    hp=$(printf '%04X' "$port")
    case "$kind" in
        tcp) files="/proc/net/tcp /proc/net/tcp6" ;;
        udp) files="/proc/net/udp /proc/net/udp6" ;;
        *) files="/proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6" ;;
    esac
    inodes=$(
        for f in $files; do
            [ -r "$f" ] || continue
            awk -v hp="$hp" -v path="$f" 'NR > 1 {
                n = split($2, a, ":")
                if (a[n] != hp) next
                if (path ~ /udp/) {
                    m = split($3, b, ":")
                    if (b[m] != "0000") next
                } else if ($4 != "0A") {
                    next
                }
                print $10
            }' "$f"
        done
    )
    [ -n "$inodes" ] || return 1
    for ino in $inodes; do
        pid=
        for link in /proc/[0-9]*/fd/*; do
            [ -L "$link" ] || continue
            [ "$(readlink "$link" 2>/dev/null)" = "socket:[$ino]" ] || continue
            pid=${link#/proc/}
            pid=${pid%%/*}
            break
        done
        [ -n "$pid" ] || return 0
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
        case "$exe" in
            "$XRAY_BIN" | "$XRAY_BIN (deleted)") continue ;;
        esac
        return 0
    done
    return 1
}

ensure_port_free() {
    port=$1
    kind=$2
    skip=${3:-}
    if port_busy "$port" "$kind" "$skip"; then
        notice "端口 ${port} 已被其他入站占用"
        return 1
    fi
    if os_port_busy "$port" "$kind"; then
        notice "端口 ${port} 已被其他程序占用"
        return 1
    fi
    return 0
}

next_id() {
    max=0
    for f in "$PANEL_DIR"/*.env; do
        [ -f "$f" ] || continue
        rec=$(ib_rec "$f")
        id=${rec%%|*}
        is_number "$id" || continue
        [ "$id" -gt "$max" ] && max=$id
    done
    printf '%s' $((max + 1))
}

proto_label() {
    case "$1" in
        shadowsocks) printf Shadowsocks ;;
        socks) printf Socks ;;
        trojan) printf Trojan ;;
        vless) printf VLESS ;;
        hysteria) printf Hysteria ;;
        *) printf '%s' "$1" ;;
    esac
}

list_inbounds() {
    i=0
    found=0
    for f in "$PANEL_DIR"/*.env; do
        [ -f "$f" ] || continue
        found=1
        i=$((i + 1))
        rec=$(ib_rec "$f")
        rest=${rec#*|}
        port=${rest%%|*}
        rest=${rest#*|}
        proto=${rest%%|*}
        printf '%s%s\n' "$(pad "$(printf '%-3s%s' "$i" "$(proto_label "$proto")")" 22)" "$port"
    done
    [ "$found" -eq 1 ]
}

pick_inbound() {
    page_head "$1"
    if ! list_inbounds; then
        printf '暂无入站\n'
        pause_back
        PICK=
        return 1
    fi
    read_choice "回车返回"
    [ -n "$CHOICE" ] || return 1
    is_number "$CHOICE" || {
        notice "无效选项"
        return 1
    }
    i=0
    PICK=
    for f in "$PANEL_DIR"/*.env; do
        [ -f "$f" ] || continue
        i=$((i + 1))
        if [ "$i" -eq "$CHOICE" ]; then
            PICK=$f
            return 0
        fi
    done
    notice "无效选项"
    return 1
}

tls_block() {
    alpn=$1
    once=
    # 自签证书不续期，只加载一次。ACME 和外部证书保持官方热重载。
    if [ "$SELF_SIGNED" = 1 ]; then
        once='"oneTimeLoading": true,'
    fi
    cat <<EOF
    "security": "tls",
    "tlsSettings": {
      "serverName": "$(json_escape "$SNI")",
      "alpn": ${alpn},
      "certificates": [
        {
          ${once}
          "certificateFile": "$(json_escape "$CERT")",
          "keyFile": "$(json_escape "$KEY")"
        }
      ]
    }
EOF
}

SNIFF='  "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}'

emit_open() {
    cat <<EOF
{
  "tag": "$(json_escape "$TAG")",
  "listen": "$(json_escape "$LISTEN")",
  "port": ${PORT},
  "protocol": "$1",
EOF
}

emit_tail() {
    printf '%s\n}\n' "$SNIFF"
}

emit_inbound() {
    mail="$(json_escape "$TAG")@xray.local"
    case "$PROTO" in
        shadowsocks)
            emit_open shadowsocks
            cat <<EOF
  "settings": {
    "network": "tcp,udp",
    "method": "$(json_escape "$SS_METHOD")",
    "password": "$(json_escape "$SS_PASSWORD")",
    "level": 0,
    "email": "${mail}"
  },
EOF
            emit_tail
            ;;
        socks)
            udp_json=false
            [ "$SOCKS_UDP" = 1 ] && udp_json=true
            udp_ip=$LISTEN
            case "$LISTEN" in
                0.0.0.0 | '::' | '[::]')
                    detect_ip
                    udp_ip=$SERVER_IP
                    ;;
            esac
            emit_open socks
            cat <<EOF
  "settings": {
    "auth": "password",
    "udp": ${udp_json},
    "ip": "$(json_escape "$udp_ip")",
    "userLevel": 0,
    "users": [{"user": "$(json_escape "$SOCKS_USER")", "pass": "$(json_escape "$SOCKS_PASS")"}]
  },
EOF
            emit_tail
            ;;
        trojan)
            emit_open trojan
            cat <<EOF
  "settings": {
    "users": [{"password": "$(json_escape "$TROJAN_PASSWORD")", "email": "${mail}", "level": 0}]
  },
  "streamSettings": {
    "method": "raw",
$(tls_block '["h2", "http/1.1"]')
  },
EOF
            emit_tail
            ;;
        vless)
            emit_open vless
            cat <<EOF
  "settings": {
    "decryption": "none",
    "flow": "xtls-rprx-vision",
    "users": [{
      "id": "$(json_escape "$VLESS_ID")",
      "flow": "xtls-rprx-vision",
      "level": 0,
      "email": "${mail}"
    }]
  },
  "streamSettings": {
    "method": "raw",
$(tls_block '["http/1.1"]')
  },
EOF
            emit_tail
            ;;
        hysteria)
            masq=
            if [ -n "$HY_MASQ" ]; then
                masq=",
      \"masquerade\": {\"type\": \"string\", \"content\": \"$(json_escape "$HY_MASQ")\", \"statusCode\": 404}"
            fi
            brutal=
            if [ -n "$BRUTAL_UP" ] && [ -n "$BRUTAL_DOWN" ]; then
                brutal=",
    \"finalmask\": {\"quicParams\": {\"congestion\": \"brutal\", \"brutalUp\": \"$(json_escape "$BRUTAL_UP")\", \"brutalDown\": \"$(json_escape "$BRUTAL_DOWN")\"}}"
            fi
            emit_open hysteria
            cat <<EOF
  "settings": {
    "version": 2,
    "users": [{"auth": "$(json_escape "$HY_AUTH")", "level": 0, "email": "${mail}"}]
  },
  "streamSettings": {
    "method": "hysteria",
$(tls_block '["h3"]'),
    "hysteriaSettings": {
      "version": 2${masq}
    }${brutal}
  },
EOF
            emit_tail
            ;;
    esac
}

lock_config() {
    prepare_user || return 0
    chown "root:${RUN_GROUP}" "$CONF_FILE" 2>/dev/null || true
    chmod 640 "$CONF_FILE" 2>/dev/null || true
    if [ -d "$CERT_DIR" ]; then
        chown "root:${RUN_GROUP}" "$CERT_DIR"/* 2>/dev/null || true
        chmod 644 "$CERT_DIR"/*.crt 2>/dev/null || true
        chmod 640 "$CERT_DIR"/*.key 2>/dev/null || true
    fi
}

rebuild_config() {
    install -d -m 755 "$CONF_DIR" "$PANEL_DIR"
    tmp=$(mktemp)
    {
        printf '{\n'
        printf '  "log": {"access": "%s/access.log", "error": "%s/error.log", "loglevel": "warning"},\n' "$LOG_DIR" "$LOG_DIR"
        printf '  "inbounds": [\n'
        first=1
        for f in "$PANEL_DIR"/*.env; do
            [ -f "$f" ] || continue
            if [ "$first" -eq 0 ]; then
                printf ',\n'
            fi
            first=0
            # 子 shell 读取，避免覆盖当前正在编辑的入站变量。
            (
                load_ib "$f"
                emit_inbound
            ) | sed 's/^/    /'
        done
        cat <<'EOF'

  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
    ]
  }
}
EOF
    } >"$tmp"
    mv "$tmp" "$CONF_FILE"
    lock_config
}

test_config() {
    [ -x "$XRAY_BIN" ] || return 0
    XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$CONF_FILE" >/dev/null 2>"${CONF_DIR}/test.err"
}

apply_config() {
    if [ -f "$CONF_FILE" ]; then
        cp "$CONF_FILE" "${CONF_FILE}.bak"
    fi
    rebuild_config
    if ! test_config; then
        if [ -f "${CONF_FILE}.bak" ]; then
            mv "${CONF_FILE}.bak" "$CONF_FILE"
        fi
        err=$(tail -n 8 "${CONF_DIR}/test.err" 2>/dev/null || true)
        notice "配置校验失败
${err}"
        return 1
    fi
    rm -f "${CONF_DIR}/test.err"
    if svc_active; then
        svc restart || {
            notice "配置已写入，但重启失败"
            return 1
        }
    fi
    return 0
}

needs_tls() {
    case "$PROTO" in
        trojan | vless | hysteria) return 0 ;;
    esac
    return 1
}

setup_tls() {
    page_head "证书"
    printf '1  自签名\n'
    printf '2  ACME\n'
    printf '3  已有证书\n'
    read_choice "回车 自签"
    case "$CHOICE" in
        '' | 1) issue_self_signed || return 1 ;;
        2) issue_acme || return 1 ;;
        3) use_existing_cert || return 1 ;;
        *) return 1 ;;
    esac
    CERT_SHA=$(cert_fp "$CERT")
    return 0
}

issue_self_signed() {
    SELF_SIGNED=1
    ACME=0
    SNI=$(ask "域名" "xray.local")
    [ -n "$SNI" ] || SNI=xray.local
    install -d -m 755 "$CERT_DIR"
    prefix="${CERT_DIR}/${TAG}"
    # 默认只签 90 天，面板不续期，这里签 10 年。
    if ! "$XRAY_BIN" tls cert --domain "$SNI" --name "$SNI" --expire 87600h --file "$prefix" >/dev/null 2>&1; then
        notice "生成证书失败"
        return 1
    fi
    CERT="${prefix}.crt"
    KEY="${prefix}.key"
    lock_cert
}

use_existing_cert() {
    SELF_SIGNED=0
    ACME=0
    CERT=$(ask "证书路径" "")
    KEY=$(ask "私钥路径" "")
    if [ ! -r "$CERT" ] || [ ! -r "$KEY" ]; then
        notice "证书或私钥不可读"
        return 1
    fi
    SNI=$(ask "SNI / 域名" "")
    if [ -z "$SNI" ]; then
        SNI=$(openssl x509 -in "$CERT" -noout -subject -nameopt sep_multiline 2>/dev/null | awk -F= '/CN=/{gsub(/ /,"",$2); print $2; exit}')
    fi
    if [ -z "$SNI" ]; then
        notice "需要填写域名"
        return 1
    fi
}

acme_bin() {
    if [ -x "${HOME:-/root}/.acme.sh/acme.sh" ]; then
        printf '%s' "${HOME:-/root}/.acme.sh/acme.sh"
        return 0
    fi
    command -v acme.sh 2>/dev/null
}

ensure_acme() {
    bin=$(acme_bin) && [ -n "$bin" ] && return 0
    printf '正在安装 acme.sh...\n'
    pkg_install socat curl || {
        notice "安装 acme.sh 依赖失败"
        return 1
    }
    paint
    curl -fsSL https://get.acme.sh | sh || {
        notice "acme.sh 安装失败"
        return 1
    }
    bin=$(acme_bin) || {
        notice "找不到 acme.sh"
        return 1
    }
    "$bin" --upgrade --auto-upgrade >/dev/null 2>&1 || true
    "$bin" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

write_acme_reload() {
    prepare_user || true
    install -d -m 755 "$CONF_DIR"
    cat >"${CONF_DIR}/acme-reload.sh" <<EOF
#!/bin/sh
chown "root:${RUN_GROUP:-nobody}" ${CERT_DIR}/*.key 2>/dev/null || true
chmod 640 ${CERT_DIR}/*.key 2>/dev/null || true
chmod 644 ${CERT_DIR}/*.crt 2>/dev/null || true
if [ -d /run/systemd/system ]; then
    systemctl try-restart xray
else
    rc-service xray try-restart 2>/dev/null || rc-service xray restart
fi
exit 0
EOF
    chmod 755 "${CONF_DIR}/acme-reload.sh"
}

issue_acme() {
    SELF_SIGNED=0
    ACME=1
    page_head "ACME"
    printf '使用 acme.sh 向 Let'\''s Encrypt 申请 ECC 证书\n\n'
    SNI=$(ask "域名" "")
    case "$SNI" in
        '' | *[!A-Za-z0-9.-]* | .* | *. | *\**)
            notice "需要真实域名，不支持通配符"
            return 1
            ;;
        *.*) ;;
        *)
            notice "需要真实域名"
            return 1
            ;;
    esac
    printf '\n1  80 端口验证，会短暂停止内核\n'
    printf '2  网站目录验证\n'
    read_choice "回车 80 端口"
    webroot=
    case "$CHOICE" in
        '' | 1)
            if os_port_busy 80 tcp; then
                notice "80 端口被其他程序占用\n请改用网站目录验证"
                return 1
            fi
            ;;
        2)
            webroot=$(ask "网站目录" "")
            if [ ! -d "$webroot" ]; then
                notice "网站目录不存在"
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
    ensure_acme || return 1
    bin=$(acme_bin)
    held=0
    if [ -z "$webroot" ] && svc_active; then
        svc stop || true
        held=1
    fi
    log=$(mktemp)
    if [ -n "$webroot" ]; then
        "$bin" --issue -d "$SNI" -w "$webroot" --keylength ec-256 --server letsencrypt >"$log" 2>&1
    else
        "$bin" --issue -d "$SNI" --standalone --httpport 80 --keylength ec-256 --server letsencrypt >"$log" 2>&1
    fi
    st=$?
    if [ "$st" -ne 0 ] && [ "$st" -ne 2 ]; then
        err=$(tail -n 8 "$log" 2>/dev/null || true)
        rm -f "$log"
        acme_resume
        notice "证书申请失败\n${err}"
        return 1
    fi
    rm -f "$log"
    install -d -m 755 "$CERT_DIR"
    CERT="${CERT_DIR}/${SNI}.crt"
    KEY="${CERT_DIR}/${SNI}.key"
    write_acme_reload
    if ! "$bin" --install-cert -d "$SNI" --ecc \
        --fullchain-file "$CERT" \
        --key-file "$KEY" \
        --reloadcmd "${CONF_DIR}/acme-reload.sh" >/dev/null 2>&1; then
        acme_resume
        notice "证书安装失败"
        return 1
    fi
    lock_cert
    acme_resume
}

lock_cert() {
    chmod 644 "$CERT"
    chmod 640 "$KEY"
}

acme_resume() {
    [ "${held:-0}" -eq 1 ] || return 0
    svc_start || true
}

cert_still_used() {
    want=$1
    for f in "$PANEL_DIR"/*.env; do
        [ -f "$f" ] || continue
        got=$(. "$f"; printf '%s' "$CERT")
        [ "$got" = "$want" ] && return 0
    done
    return 1
}

cert_fp() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 | awk -F= '{print $2}' | tr -d ':' | tr 'A-F' 'a-f'
}

ss_key_bytes() {
    case "$1" in
        2022-blake3-aes-128-gcm) printf 16 ;;
        2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305) printf 32 ;;
        aes-128-gcm | aes-256-gcm | chacha20-poly1305 | xchacha20-poly1305) printf 0 ;;
        *) return 1 ;;
    esac
}

pick_ss_method() {
    page_head "Shadowsocks 加密"
    printf '1  2022-blake3-aes-256-gcm\n'
    printf '2  2022-blake3-aes-128-gcm\n'
    printf '3  2022-blake3-chacha20-poly1305\n'
    printf '4  aes-256-gcm\n'
    printf '5  aes-128-gcm\n'
    printf '6  chacha20-poly1305\n'
    printf '7  xchacha20-poly1305\n'
    read_choice "回车 推荐"
    case "$CHOICE" in
        '' | 1) SS_METHOD=2022-blake3-aes-256-gcm ;;
        2) SS_METHOD=2022-blake3-aes-128-gcm ;;
        3) SS_METHOD=2022-blake3-chacha20-poly1305 ;;
        4) SS_METHOD=aes-256-gcm ;;
        5) SS_METHOD=aes-128-gcm ;;
        6) SS_METHOD=chacha20-poly1305 ;;
        7) SS_METHOD=xchacha20-poly1305 ;;
        *) return 1 ;;
    esac
    return 0
}

gen_ss_password() {
    n=$(ss_key_bytes "$SS_METHOD") || return 1
    if [ "$n" = 0 ]; then
        SS_PASSWORD=$(rand_b64 24)
    else
        SS_PASSWORD=$(rand_b64 "$n")
    fi
}

fill_new_secrets() {
    case "$PROTO" in
        shadowsocks) gen_ss_password || return 1 ;;
        socks)
            SOCKS_USER="user$(rand_hex 2)"
            SOCKS_PASS=$(rand_b64 12)
            ;;
        trojan) TROJAN_PASSWORD=$(rand_hex 16) ;;
        vless) VLESS_ID=$("$XRAY_BIN" uuid) ;;
        hysteria) HY_AUTH=$(rand_hex 16) ;;
    esac
    return 0
}

share_host() {
    if [ -n "$SNI" ] && [ "$SNI" != "xray.local" ]; then
        printf '%s' "$SNI"
        return
    fi
    detect_ip
    printf '%s' "$SERVER_IP"
}

cert_pin() {
    if [ "$SELF_SIGNED" != 1 ]; then
        return 1
    fi
    if [ -z "$CERT_SHA" ] && [ -r "$CERT" ]; then
        CERT_SHA=$(cert_fp "$CERT")
    fi
    [ -n "$CERT_SHA" ] || return 1
    printf '%s' "$CERT_SHA" | tr 'a-f' 'A-F'
}

print_share() {
    host=$(share_host)
    pin=$(cert_pin || true)
    kv 协议 "$(proto_label "$PROTO")"
    kv 地址 "$host"
    kv 端口 "$PORT"
    case "$PROTO" in
        shadowsocks)
            kv 加密 "$SS_METHOD"
            kv 密码 "$SS_PASSWORD"
            printf '\n%s\n' "ss://$(b64url "${SS_METHOD}:${SS_PASSWORD}")@${host}:${PORT}#ss"
            ;;
        socks)
            kv 监听 "$LISTEN"
            kv 用户 "$SOCKS_USER"
            kv 密码 "$SOCKS_PASS"
            kv UDP "$SOCKS_UDP"
            printf '\nSocks 无传输加密，不要暴露到公网\n'
            ;;
        trojan)
            kv 密码 "$TROJAN_PASSWORD"
            kv SNI "$SNI"
            extra=
            [ -n "$pin" ] && extra="&pcs=$(urlencode "$pin")"
            printf '\n%s\n' "trojan://$(urlencode "$TROJAN_PASSWORD")@${host}:${PORT}?security=tls&type=raw&sni=$(urlencode "$SNI")${extra}#trojan"
            ;;
        vless)
            kv UUID "$VLESS_ID"
            kv 流控 xtls-rprx-vision
            kv SNI "$SNI"
            extra=
            [ -n "$pin" ] && extra="&pcs=$(urlencode "$pin")"
            printf '\n%s\n' "vless://${VLESS_ID}@${host}:${PORT}?encryption=none&security=tls&type=raw&flow=xtls-rprx-vision&alpn=http%2F1.1&sni=$(urlencode "$SNI")${extra}#vless"
            ;;
        hysteria)
            kv 认证 "$HY_AUTH"
            kv SNI "$SNI"
            if [ -n "$BRUTAL_UP" ] && [ -n "$BRUTAL_DOWN" ]; then
                printf 'Brutal  上行 %s，下行 %s\n' "$BRUTAL_UP" "$BRUTAL_DOWN"
                printf '客户端需自行填写对应速率\n'
            fi
            extra=
            if [ -n "$pin" ]; then
                extra="&insecure=1&pinSHA256=$(urlencode "$pin")&pcs=$(urlencode "$pin")"
            fi
            printf '\n%s\n' "hysteria2://$(urlencode "$HY_AUTH")@${host}:${PORT}/?sni=$(urlencode "$SNI")&alpn=h3${extra}#hy2"
            ;;
    esac
    if [ -n "$pin" ]; then
        printf '\n自签证书，指纹已写入链接\n'
        printf '%s\n' "$pin"
    elif [ "$ACME" = 1 ]; then
        printf '\nACME 证书会自动续期\n'
    fi
}

show_share_page() {
    page_head "分享入站"
    print_share
    if svc_active; then
        printf '\n内核运行中\n'
    else
        printf '\n内核未启动，选择 3  启动内核后生效\n'
    fi
    pause_back
}

pick_socks_udp() {
    page_head "$1"
    printf '1  开启 UDP\n'
    printf '2  仅 TCP\n'
    read_choice "$2"
    case "$CHOICE" in
        1) SOCKS_UDP=1 ;;
        2) SOCKS_UDP=0 ;;
        '') [ "$3" = on ] && SOCKS_UDP=1 || return 1 ;;
        *) return 1 ;;
    esac
    return 0
}

guard_socks_listen() {
    is_loopback "$LISTEN" && return 0
    page_head "$1"
    printf 'Socks 没有传输加密，不适合公网\n\n'
    printf '1  仍然使用 %s\n' "$LISTEN"
    printf '2  %s\n' "$2"
    read_choice "回车返回"
    case "$CHOICE" in
        1) return 0 ;;
        2)
            [ "$3" = cancel ] && return 1
            LISTEN=127.0.0.1
            return 0
            ;;
    esac
    return 1
}

read_brutal() {
    BRUTAL_UP=$(ask "$1" "$2")
    if [ -z "$BRUTAL_UP" ]; then
        BRUTAL_DOWN=
        return 0
    fi
    BRUTAL_DOWN=$(ask "Brutal 下行，如 100 mbps" "$3")
    if [ -z "$BRUTAL_DOWN" ]; then
        notice "需要同时填写下行速率"
        return 1
    fi
}

collect_common() {
    kind=$(proto_kind "$PROTO" "$SOCKS_UDP")
    case "$PROTO" in
        shadowsocks) def=8388 ;;
        socks) def=1080 ;;
        *) def=443 ;;
    esac
    def=$(suggest_port "$def" "$kind" "${IB_ID:-}") || def=$def
    page_head "添加入站"
    PORT=$(ask "端口" "$def")
    valid_port "$PORT" || {
        notice "端口无效"
        return 1
    }
    ensure_port_free "$PORT" "$kind" "${IB_ID:-}" || return 1
    if [ "$PROTO" = socks ]; then
        LISTEN=$(ask "监听地址" "127.0.0.1")
        guard_socks_listen "添加入站" "改为 127.0.0.1" keep || return 1
    else
        LISTEN=$(ask "监听地址" "0.0.0.0")
    fi
}

action_add() {
    if ! need_kernel; then
        return
    fi
    page_head "添加入站"
    printf '1  Shadowsocks\n'
    printf '2  Socks\n'
    printf '3  Trojan\n'
    printf '4  VLESS\n'
    printf '5  Hysteria\n'
    read_choice "回车返回"
    reset_ib
    case "$CHOICE" in
        1) PROTO=shadowsocks ;;
        2) PROTO=socks ;;
        3) PROTO=trojan ;;
        4) PROTO=vless ;;
        5) PROTO=hysteria ;;
        *) return ;;
    esac
    IB_ID=$(next_id)
    TAG="${PROTO}-${IB_ID}"
    case "$PROTO" in
        shadowsocks)
            pick_ss_method || return
            ;;
        socks) pick_socks_udp "Socks" "回车 开启" on || return ;;
        hysteria)
            page_head "Hysteria"
            read_brutal "Brutal 上行，如 100 mbps，回车跳过" "" "" || return
            HY_MASQ=$(ask "伪装页文字，回车跳过" "")
            ;;
    esac
    collect_common || return
    fill_new_secrets || {
        notice "生成认证信息失败"
        return
    }
    if needs_tls; then
        setup_tls || return
    fi
    page_head "确认添加"
    print_share
    printf '\n1  确认添加\n'
    read_choice "回车返回"
    [ "$CHOICE" = 1 ] || return
    file="${PANEL_DIR}/${IB_ID}.env"
    save_ib "$file"
    if ! apply_config; then
        rm -f "$file"
        rebuild_config || true
        return
    fi
    show_share_page
}

action_modify() {
    if ! need_kernel; then
        return
    fi
    pick_inbound "修改入站" || return
    file=$PICK
    load_ib "$file"
    page_head "修改入站"
    printf '当前  %s  %s\n\n' "$(proto_label "$PROTO")" "$PORT"
    printf '1  端口\n'
    printf '2  监听地址\n'
    printf '3  认证信息\n'
    if needs_tls; then
        printf '4  证书\n'
    fi
    if [ "$PROTO" = socks ]; then
        printf '5  UDP\n'
    fi
    if [ "$PROTO" = hysteria ]; then
        printf '5  Brutal\n'
        printf '6  伪装页\n'
    fi
    read_choice "回车返回"
    case "$CHOICE" in
        1)
            kind=$(proto_kind "$PROTO" "$SOCKS_UDP")
            newport=$(ask "端口" "$PORT")
            valid_port "$newport" || {
                notice "端口无效"
                return
            }
            ensure_port_free "$newport" "$kind" "$IB_ID" || return
            PORT=$newport
            ;;
        2)
            LISTEN=$(ask "监听地址" "$LISTEN")
            if [ "$PROTO" = socks ]; then
                guard_socks_listen "修改入站" "取消" cancel || return
            fi
            ;;
        3)
            page_head "认证信息"
            printf '1  重新生成\n'
            printf '2  手动输入\n'
            read_choice "回车返回"
            case "$CHOICE" in
                1) fill_new_secrets || return ;;
                2)
                    case "$PROTO" in
                        shadowsocks)
                            pick_ss_method || return
                            SS_PASSWORD=$(ask "密码" "")
                            [ -n "$SS_PASSWORD" ] || return
                            ;;
                        socks)
                            SOCKS_USER=$(ask "用户" "$SOCKS_USER")
                            SOCKS_PASS=$(ask "密码" "")
                            [ -n "$SOCKS_PASS" ] || return
                            ;;
                        trojan)
                            TROJAN_PASSWORD=$(ask "密码" "")
                            [ -n "$TROJAN_PASSWORD" ] || return
                            ;;
                        vless) VLESS_ID=$(ask "UUID" "$VLESS_ID") ;;
                        hysteria)
                            HY_AUTH=$(ask "认证" "")
                            [ -n "$HY_AUTH" ] || return
                            ;;
                    esac
                    ;;
                *) return ;;
            esac
            ;;
        4)
            needs_tls || {
                notice "无效选项"
                return
            }
            setup_tls || return
            ;;
        5)
            if [ "$PROTO" = socks ]; then
                old=$SOCKS_UDP
                pick_socks_udp "Socks UDP" "回车返回" || return
                kind=$(proto_kind socks "$SOCKS_UDP")
                ensure_port_free "$PORT" "$kind" "$IB_ID" || { SOCKS_UDP=$old; return; }
            elif [ "$PROTO" = hysteria ]; then
                page_head "Brutal"
                printf '当前  上行 %s  下行 %s\n\n' "${BRUTAL_UP:-未设置}" "${BRUTAL_DOWN:-未设置}"
                printf '1  设置速率\n'
                printf '2  关闭\n'
                read_choice "回车返回"
                case "$CHOICE" in
                    1) read_brutal "上行，如 100 mbps" "$BRUTAL_UP" "$BRUTAL_DOWN" || return ;;
                    2)
                        BRUTAL_UP=
                        BRUTAL_DOWN=
                        ;;
                    *) return ;;
                esac
            else
                notice "无效选项"
                return
            fi
            ;;
        6)
            if [ "$PROTO" != hysteria ]; then
                notice "无效选项"
                return
            fi
            page_head "伪装页"
            printf '当前  %s\n\n' "${HY_MASQ:-未设置}"
            printf '1  修改文字\n'
            printf '2  关闭\n'
            read_choice "回车返回"
            case "$CHOICE" in
                1)
                    HY_MASQ=$(ask "伪装页文字" "$HY_MASQ")
                    [ -n "$HY_MASQ" ] || return
                    ;;
                2) HY_MASQ= ;;
                *) return ;;
            esac
            ;;
        *) return ;;
    esac
    cp "$file" "${file}.bak"
    save_ib "$file"
    if ! apply_config; then
        mv "${file}.bak" "$file"
        rebuild_config || true
        return
    fi
    rm -f "${file}.bak"
    notice "入站已更新"
}

action_share() {
    pick_inbound "分享入站" || return
    load_ib "$PICK"
    show_share_page
}

action_delete() {
    pick_inbound "删除入站" || return
    file=$PICK
    load_ib "$file"
    page_head "删除入站"
    printf '确认删除  %s  %s ?\n\n' "$(proto_label "$PROTO")" "$PORT"
    printf '1  删除\n'
    read_choice "回车返回"
    [ "$CHOICE" = 1 ] || return
    rm -f "$file"
    if [ "$SELF_SIGNED" = 1 ] || [ "$ACME" = 1 ]; then
        cert_still_used "$CERT" || rm -f "$CERT" "$KEY"
    fi
    if ! apply_config; then
        notice "入站文件已删除，但配置刷新失败"
        return
    fi
    notice "入站已删除"
}

main() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf '请在终端中运行\n' >&2
        exit 1
    fi
    init_color
    paint
    if ! detect_os; then
        notice "仅支持 Debian 系与 Alpine"
        printf '%s' "$RST"
        exit 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        notice "请用 root 运行"
        printf '%s' "$RST"
        exit 1
    fi
    while true; do
        draw_main
        case "$CHOICE" in
            '') break ;;
            1) action_install ;;
            2) action_upgrade ;;
            3) action_start ;;
            4) action_stop ;;
            5) action_uninstall ;;
            6) action_logs ;;
            7) action_add ;;
            8) action_modify ;;
            9) action_share ;;
            10) action_delete ;;
            *) notice "无效选项" ;;
        esac
    done
    printf '%s%s\033[H\033[2J' "$OSC_RESET" "$RST"
}

main
