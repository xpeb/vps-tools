#!/usr/bin/env bash

# Shadowsocks-Rust 极简管理器：配置、下载、服务三层。
set -u
umask 077

APP="shadowsocks-rust"
REPO="shadowsocks/shadowsocks-rust"
BIN="/usr/local/bin/ssserver"
CONF_DIR="/etc/shadowsocks-rust"
CONF="$CONF_DIR/config.json"
SYSTEMD_UNIT="/etc/systemd/system/$APP.service"
OPENRC_UNIT="/etc/init.d/$APP"
PID_FILE="/run/$APP.pid"
LOG_FILE="/var/log/$APP.log"
DEFAULT_PORT="56789"
DEFAULT_METHOD="2022-blake3-aes-128-gcm"
DEFAULT_MODE="tcp_and_udp"

TMP_DIR=""
NEW_BIN=""
NEW_VERSION=""

has() { command -v "$1" >/dev/null 2>&1; }

error() {
    printf '错误：%s\n' "$*" >&2
    return 1
}

root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || error '请使用 root 权限运行。'
}

clean_tmp() {
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
    TMP_DIR=""
    NEW_BIN=""
    NEW_VERSION=""
}

trap clean_tmp EXIT
trap 'exit 130' INT TERM

# ---------- 服务层 ----------

backend() {
    if has systemctl && [ -d /run/systemd/system ]; then
        printf 'systemd'
    elif has rc-service && has rc-update; then
        printf 'openrc'
    else
        printf 'direct'
    fi
}

server_pid() {
    local pid cmd
    [ -s "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/$pid/cmdline" ]; then
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
        case "$cmd" in *"$BIN"*) printf '%s' "$pid"; return 0 ;; esac
        return 1
    fi
    printf '%s' "$pid"
}

svc() {
    local action="$1" b pid
    b=$(backend)
    case "$action/$b" in
        status/systemd) systemctl is-active --quiet "$APP" 2>/dev/null ;;
        status/openrc) rc-service "$APP" status >/dev/null 2>&1 ;;
        status/direct) server_pid >/dev/null ;;

        install/systemd)
            cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload || return 1
            systemctl enable "$APP" >/dev/null 2>&1 || return 1
            ;;
        install/openrc)
            cat > "$OPENRC_UNIT" <<EOF
#!/sbin/openrc-run
name="Shadowsocks-Rust"
command="$BIN"
command_args="-c $CONF"
supervisor="supervise-daemon"
supervise_daemon_args="--stdout $LOG_FILE --stderr $LOG_FILE"
pidfile="$PID_FILE"

depend() {
    need net
}
EOF
            chmod +x "$OPENRC_UNIT" || return 1
            rc-update add "$APP" default >/dev/null 2>&1 || return 1
            ;;
        install/direct) : ;;

        start/systemd) systemctl start "$APP" ;;
        start/openrc) rc-service "$APP" start ;;
        start/direct)
            svc status && return 0
            rm -f "$PID_FILE"
            mkdir -p "${LOG_FILE%/*}" "${PID_FILE%/*}"
            nohup "$BIN" -c "$CONF" >>"$LOG_FILE" 2>&1 &
            printf '%s\n' "$!" > "$PID_FILE"
            sleep 1
            svc status
            ;;

        stop/systemd)
            if systemctl is-active --quiet "$APP" 2>/dev/null; then
                systemctl stop "$APP"
            fi
            ;;
        stop/openrc)
            if rc-service "$APP" status >/dev/null 2>&1; then
                rc-service "$APP" stop
            fi
            ;;
        stop/direct)
            if pid=$(server_pid); then
                kill "$pid" >/dev/null 2>&1 || true
                for _ in 1 2 3 4 5; do
                    server_pid >/dev/null || break
                    sleep 1
                done
                if server_pid >/dev/null; then
                    kill -KILL "$pid" >/dev/null 2>&1 || true
                fi
            fi
            rm -f "$PID_FILE"
            ;;

        remove/systemd)
            svc stop || return 1
            systemctl disable "$APP" >/dev/null 2>&1 || true
            rm -f "$SYSTEMD_UNIT"
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            ;;
        remove/openrc)
            svc stop || return 1
            rc-update del "$APP" default >/dev/null 2>&1 || true
            rm -f "$OPENRC_UNIT"
            ;;
        remove/direct) svc stop ;;
        *) return 1 ;;
    esac
}

# ---------- 下载层 ----------

packages() {
    local missing="" c
    for c in curl tar xz jq sha256sum base64; do
        has "$c" || missing="$missing $c"
    done
    [ -z "$missing" ] && return 0

    if has apk; then
        apk add --no-cache curl tar xz jq coreutils
    elif has apt-get; then
        apt-get update -qq && apt-get install -y curl tar xz-utils jq coreutils
    elif has dnf; then
        dnf install -y curl tar xz jq coreutils
    elif has yum; then
        yum install -y curl tar xz jq coreutils
    elif has pacman; then
        pacman -Sy --noconfirm curl tar xz jq coreutils
    else
        error "缺少依赖:$missing，且未找到包管理器。"
        return 1
    fi
}

asset_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64-unknown-linux-musl' ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-musl' ;;
        armv7l|armhf) printf 'armv7-unknown-linux-musleabihf' ;;
        i386|i686) printf 'i686-unknown-linux-musl' ;;
        *) error "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
    esac
}

latest_tag() {
    local api tag url
    api=$(curl -fsSL --max-time 15 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: shadowsocks.sh' \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)
    tag=$(printf '%s' "$api" | jq -r '.tag_name // empty' 2>/dev/null || true)
    case "$tag" in
        v[0-9]*.[0-9]*) printf '%s' "$tag"; return 0 ;;
    esac

    url=$(curl -fsSIL --max-time 15 -o /dev/null -w '%{url_effective}' \
        -H 'User-Agent: shadowsocks.sh' \
        "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
    url=${url##*/tag/}
    case "$url" in
        v[0-9]*.[0-9]*) printf '%s' "$url" ;;
        *) error '无法获取最新 Release 版本。'; return 1 ;;
    esac
}

verify_archive() {
    local archive="$1" expected actual
    expected=$(curl -fLsS --max-time 20 "${2}.sha256" 2>/dev/null \
        | awk 'NR == 1 { print $1 }' || true)
    [ -n "$expected" ] || { error '无法获取官方 SHA256 校验值。'; return 1; }
    actual=$(sha256sum "$archive" | awk '{ print $1 }') || return 1
    [ "$expected" = "$actual" ] || {
        error '安装包 SHA256 校验失败。'
        return 1
    }
}

fetch() {
    local tag="${1:-}" arch url archive help method
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shadowsocks.XXXXXX") || return 1
    [ -n "$tag" ] || tag=$(latest_tag) || return 1
    arch=$(asset_arch) || return 1
    archive="$TMP_DIR/server.tar.xz"
    url="https://github.com/$REPO/releases/download/$tag/shadowsocks-$tag.$arch.tar.xz"

    printf '下载 %s（%s）...\n' "$tag" "$arch"
    curl -fLsS --connect-timeout 10 --max-time 90 \
        -H 'User-Agent: shadowsocks.sh' -o "$archive" "$url" 2>/dev/null || {
        error '下载失败，当前架构可能没有对应安装包。'
        return 1
    }
    verify_archive "$archive" "$url" || return 1
    tar -xf "$archive" -C "$TMP_DIR" ssserver 2>/dev/null || {
        error '安装包解压失败。'
        return 1
    }
    chmod +x "$TMP_DIR/ssserver"
    help=$("$TMP_DIR/ssserver" --help 2>&1 || true)
    for method in 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
        printf '%s' "$help" | grep -Fqi "$method" || {
            error "最新版本缺少 $method。"
            return 1
        }
    done
    NEW_BIN="$TMP_DIR/ssserver"
    NEW_VERSION="$tag"
}

# ---------- 配置层 ----------

cfg() {
    [ -f "$CONF" ] || return 0
    jq -r ".${1} // empty" "$CONF" 2>/dev/null || true
}

is_2022_method() {
    case "$1" in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) return 0 ;;
        *) return 1 ;;
    esac
}

key_bytes() {
    case "$1" in
        2022-blake3-aes-128-gcm) printf '16' ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf '32' ;;
        *) return 1 ;;
    esac
}

generate_key() {
    head -c "$(key_bytes "$1")" /dev/urandom | base64 | tr -d '\n'
}

valid_key() {
    local method="$1" key="$2" expected decoded encoded tmp
    expected=$(key_bytes "$method") || return 1
    [ -n "$key" ] || return 1
    tmp=$(mktemp "${TMPDIR:-/tmp}/ss-key.XXXXXX") || return 1
    if ! printf '%s' "$key" | base64 -d > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    decoded=$(wc -c < "$tmp")
    encoded=$(base64 < "$tmp" | tr -d '\n')
    rm -f "$tmp"
    [ "$decoded" -eq "$expected" ] && [ "$encoded" = "$key" ]
}

choose_method() {
    local current="${1:-$DEFAULT_METHOD}" choice
    is_2022_method "$current" || current="$DEFAULT_METHOD"
    printf '\n加密方式 [%s]\n' "$current"
    printf '[1] AES-128-GCM\n'
    printf '[2] AES-256-GCM\n'
    printf '[3] ChaCha20\n'
    while :; do
        read -r -p '选择 [回车不变]: ' choice || return 1
        case "$choice" in
            '') SET_METHOD="$current"; return 0 ;;
            1) SET_METHOD='2022-blake3-aes-128-gcm'; return 0 ;;
            2) SET_METHOD='2022-blake3-aes-256-gcm'; return 0 ;;
            3) SET_METHOD='2022-blake3-chacha20-poly1305'; return 0 ;;
            *) printf '无效选项。\n' ;;
        esac
    done
}

choose_mode() {
    local current="${1:-$DEFAULT_MODE}" choice
    printf '\n模式 [%s]\n' "$current"
    printf '[1] TCP\n'
    printf '[2] UDP\n'
    printf '[3] TCP+UDP\n'
    while :; do
        read -r -p '选择 [回车不变]: ' choice || return 1
        case "$choice" in
            '') SET_MODE="$current"; return 0 ;;
            1) SET_MODE='tcp_only'; return 0 ;;
            2) SET_MODE='udp_only'; return 0 ;;
            3) SET_MODE='tcp_and_udp'; return 0 ;;
            *) printf '无效选项。\n' ;;
        esac
    done
}

ask_config() {
    local old_port old_password old_method old_mode value default_key current_method key_hint
    old_port=$(cfg server_port)
    old_password=$(cfg password)
    old_method=$(cfg method)
    old_mode=$(cfg mode)

    while :; do
        read -r -p "端口 [${old_port:-$DEFAULT_PORT}]: " value || return 1
        value=${value:-${old_port:-$DEFAULT_PORT}}
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
            SET_PORT="$value"
            break
        fi
        printf '端口无效（1-65535）。\n'
    done

    is_2022_method "$old_method" && current_method="$old_method" || current_method="$DEFAULT_METHOD"
    choose_method "$current_method" || return 1
    choose_mode "${old_mode:-$DEFAULT_MODE}" || return 1
    if valid_key "$SET_METHOD" "$old_password"; then
        default_key="$old_password"
        key_hint='保持'
    else
        default_key=$(generate_key "$SET_METHOD") || return 1
        key_hint='生成'
    fi

    while :; do
        read -r -s -p "PSK [回车$key_hint]: " value || return 1
        printf '\n'
        value=${value:-$default_key}
        if valid_key "$SET_METHOD" "$value"; then
            SET_PASSWORD="$value"
            break
        fi
        printf 'PSK 无效，需要 %sB Base64。\n' "$(key_bytes "$SET_METHOD")"
    done
}

save_config() {
    local temp="$CONF.tmp.$$"
    mkdir -p "$CONF_DIR"
    if ! jq -n --arg port "$1" --arg password "$2" --arg method "$3" --arg mode "$4" \
        '{server:"::",server_port:($port|tonumber),password:$password,method:$method,mode:$mode,fast_open:false}' \
        > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    if ! mv "$temp" "$CONF"; then
        rm -f "$temp"
        return 1
    fi
    chmod 600 "$CONF"
}

version() {
    [ -x "$BIN" ] || return 0
    "$BIN" --version 2>/dev/null | awk 'NR == 1 { print $2 }'
}

version_newer() {
    local IFS=. i av bv
    local -a a b
    read -r -a a <<< "${1#v}"
    read -r -a b <<< "${2#v}"
    for i in 0 1 2; do
        av=${a[$i]:-0}; bv=${b[$i]:-0}
        if (( 10#$av > 10#$bv )); then return 0; fi
        if (( 10#$av < 10#$bv )); then return 1; fi
    done
    return 1
}

encode() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

# ---------- 操作层 ----------

apply_config() {
    local new_bin="${1:-}" done="${2:-配置完成。}"
    svc stop || { clean_tmp; error '无法停止当前服务。'; return 1; }
    if [ -n "$new_bin" ]; then
        mkdir -p "${BIN%/*}"
        if ! cp "$new_bin" "$BIN" || ! chmod 755 "$BIN"; then
            clean_tmp
            error '程序文件写入失败。'
            return 1
        fi
    fi
    save_config "$SET_PORT" "$SET_PASSWORD" "$SET_METHOD" "$SET_MODE" || {
        clean_tmp
        error '配置文件写入失败。'
        return 1
    }
    clean_tmp
    svc install || { error '服务配置写入失败。'; return 1; }
    if svc start; then
        printf '%s\n' "$done"
        show_info
    else
        error "$done，但服务启动失败。"
        return 1
    fi
}

install_app() {
    local new_bin
    packages || return 1
    [ ! -x "$BIN" ] || { error '已经安装，请选择“配置”。'; return 1; }
    fetch || { clean_tmp; return 1; }
    new_bin="$NEW_BIN"
    ask_config || { clean_tmp; return 1; }
    apply_config "$new_bin" '安装完成。'
}

configure_app() {
    packages || return 1
    [ -x "$BIN" ] || { error '尚未安装，请先选择“安装”。'; return 1; }
    ask_config || { clean_tmp; return 1; }
    apply_config '' '配置完成。'
}

update_app() {
    local latest current
    packages || return 1
    [ -x "$BIN" ] || { error '尚未安装，请先选择“安装”。'; return 1; }
    latest=$(latest_tag) || return 1
    current=$(version)
    if [ -n "$current" ] && ! version_newer "$latest" "$current"; then
        printf '当前已是最新版本：%s\n' "$current"
        return 0
    fi
    fetch "$latest" || { clean_tmp; return 1; }
    svc stop || { clean_tmp; error '无法停止当前服务。'; return 1; }
    if ! cp "$NEW_BIN" "$BIN" || ! chmod 755 "$BIN"; then
        clean_tmp
        error '程序文件写入失败。'
        return 1
    fi
    printf '更新至 %s\n' "$NEW_VERSION"
    clean_tmp
    svc install || { error '服务配置更新失败。'; return 1; }
    svc start || { error '更新完成，但服务启动失败。'; return 1; }
}

start_app() {
    [ -x "$BIN" ] || { error '尚未安装。'; return 1; }
    [ -f "$CONF" ] || { error '配置文件不存在。'; return 1; }
    svc install || { error '服务配置写入失败。'; return 1; }
    if svc start; then
        printf '服务已启动。\n'
    else
        error '服务启动失败。'
        return 1
    fi
}

stop_app() {
    [ -x "$BIN" ] || { error '尚未安装。'; return 1; }
    svc stop || { error '服务停止失败。'; return 1; }
    printf '服务已停止。\n'
}

restart_app() {
    [ -x "$BIN" ] || { error '尚未安装。'; return 1; }
    svc stop || { error '服务停止失败。'; return 1; }
    svc install || { error '服务配置写入失败。'; return 1; }
    if svc start; then
        printf '服务已重启。\n'
    else
        error '服务重启失败。'
        return 1
    fi
}

show_info() {
    local port password method mode ip4 ip6 host raw
    has jq || { error '缺少 jq，请先选择“安装”。'; return 1; }
    has base64 || { error '缺少 base64，请先选择“安装”。'; return 1; }
    [ -f "$CONF" ] || { error '配置文件不存在。'; return 1; }

    port=$(cfg server_port)
    password=$(cfg password)
    method=$(cfg method)
    mode=$(cfg mode)
    ip4=''; ip6=''
    if has curl; then
        ip4=$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
        ip6=$(curl -6fsS --max-time 3 https://api64.ipify.org 2>/dev/null || true)
    fi
    [ -n "$ip4" ] || ip4='-'

    printf '\n状态  %s  %s\n' \
        "$(svc status && printf '运行中' || printf '已停止')" "$(version)"
    printf '地址  %s\n端口  %s\n加密  %s\n模式  %s\n' "$ip4" "$port" "$method" "$mode"
    [ -n "$ip6" ] && printf 'IPv6  %s\n' "$ip6"

    if [ "$ip4" != '-' ]; then
        host="$ip4"
        raw="$method:$password@$host:$port"
        printf '链接  ss://%s#ss-rust\n' "$(encode "$raw")"
    fi
    if [ -n "$ip6" ]; then
        host="[$ip6]"
        raw="$method:$password@$host:$port"
        printf 'IPv6  ss://%s#ss-rust-ipv6\n' "$(encode "$raw")"
    fi
    [ "$ip4" != '-' ] || [ -n "$ip6" ] || printf '链接  无法获取公网地址，请手动替换服务器 IP。\n'
    printf '提示  请确认云防火墙已放行 %s/tcp、udp。\n' "$port"
}

show_logs() {
    case "$(backend)" in
        systemd) journalctl -u "$APP" -n 50 --no-pager 2>/dev/null || error '无法读取 systemd 日志。' ;;
        *) [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || printf '暂无日志。\n' ;;
    esac
}

uninstall_app() {
    [ -e "$BIN" ] || [ -e "$CONF_DIR" ] || { error '尚未安装。'; return 1; }
    read -r -p '确认卸载？[y/N] ' value || return 1
    case "$value" in
        y|Y|yes|YES) ;;
        *) printf '已取消。\n'; return ;;
    esac
    svc remove || { error '服务移除失败，已停止卸载。'; return 1; }
    rm -f "$BIN" "$CONF" "$CONF.tmp."* "$PID_FILE" "$LOG_FILE"
    rmdir "$CONF_DIR" 2>/dev/null || true
    printf '已卸载。\n'
}

status_line() {
    if [ ! -x "$BIN" ]; then
        printf '状态  未安装\n'
    elif svc status; then
        printf '状态  运行中  %s\n' "$(version)"
    else
        printf '状态  已停止  %s\n' "$(version)"
    fi
}

pause_menu() {
    printf '\n'
    read -r -p '回车返回: ' _ || true
}

menu() {
    local choice
    while :; do
        [ -t 1 ] && printf '\033[2J\033[H'
        printf '\nShadowsocks-Rust\n'
        status_line
        printf '\n[1] 安装  [2] 配置  [3] 更新\n'
        printf '[4] 启动  [5] 停止  [6] 重启\n'
        printf '[7] 信息  [8] 日志  [9] 卸载\n'
        printf '[0] 退出\n\n'
        read -r -p '选择 [0-9]: ' choice || break
        case "$choice" in
            1) install_app; pause_menu ;;
            2) configure_app; pause_menu ;;
            3) update_app; pause_menu ;;
            4) start_app; pause_menu ;;
            5) stop_app; pause_menu ;;
            6) restart_app; pause_menu ;;
            7) show_info; pause_menu ;;
            8) show_logs; pause_menu ;;
            9) uninstall_app; pause_menu ;;
            0) break ;;
            *) printf '无效选项。\n'; pause_menu ;;
        esac
    done
}

root || exit 1
menu
