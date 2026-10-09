#!/usr/bin/env bash

# Shadowsocks-Rust 极简管理器。
# 下载校验、配置、服务三层；服务以降权账号运行，更新失败会回滚。
set -u
umask 077

APP="shadowsocks-rust"
REPO="shadowsocks/shadowsocks-rust"
SVC_USER="shadowsocks"
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
ROLLBACK_DIR=""
RB_ACTIVE=0
RB_HAD_CONFIG=0
RB_HAD_BIN=0
RB_WAS_RUNNING=0
UNIT_CHANGED=0
KEY_TMP=""
SETPRIV=""

has() { command -v "$1" >/dev/null 2>&1; }

error() {
    printf '错误：%s\n' "$*" >&2
    return 1
}

root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || error '请使用 root 权限运行。'
}

clean_tmp() {
    [ -z "$KEY_TMP" ] || rm -f "$KEY_TMP"
    KEY_TMP=""
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
    TMP_DIR=""
    NEW_BIN=""
    NEW_VERSION=""
    if [ "${RB_ACTIVE:-0}" != 1 ] && [ -n "$ROLLBACK_DIR" ]; then
        rm -rf "$ROLLBACK_DIR"
        ROLLBACK_DIR=""
    fi
}

cleanup() {
    if [ "${RB_ACTIVE:-0}" = 1 ]; then
        restore_runtime || printf '错误：自动恢复失败，备份仍在 %s\n' "$ROLLBACK_DIR" >&2
    fi
    clean_tmp
}

trap cleanup EXIT
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

listen_port() {
    local port
    port=$(cfg server_port)
    if [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )); then
        printf '%s' "$((10#$port))"
    else
        printf '%s' "$DEFAULT_PORT"
    fi
}

nofile_limit() {
    local max=65535 nr=1048576
    if [ -r /proc/sys/fs/nr_open ]; then
        nr=$(tr -d '[:space:]' < /proc/sys/fs/nr_open)
    fi
    [[ "$nr" =~ ^[0-9]+$ ]] || nr=1048576
    if (( nr < max )); then
        max=$nr
    fi
    if (( max > 1024 )); then
        printf '%s' "$((max - 1))"
    else
        printf '1024'
    fi
}

server_pid() {
    local pid cmd
    [ -s "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    case "$cmd" in *"$BIN"*) printf '%s' "$pid" ;; *) return 1 ;; esac
}

ensure_service_account() {
    local shell="/usr/sbin/nologin"
    if id -u "$SVC_USER" >/dev/null 2>&1; then
        return 0
    fi
    [ -x "$shell" ] || shell="/sbin/nologin"
    [ -x "$shell" ] || shell="/bin/false"
    if ! grep -q "^${SVC_USER}:" /etc/group 2>/dev/null; then
        if has groupadd; then
            groupadd --system "$SVC_USER" || return 1
        elif has addgroup; then
            addgroup -S "$SVC_USER" || return 1
        else
            error '无法创建用户组 shadowsocks。'
            return 1
        fi
    fi
    if has useradd; then
        useradd --system --gid "$SVC_USER" --home-dir /nonexistent \
            --no-create-home --shell "$shell" "$SVC_USER" || return 1
    elif has adduser; then
        adduser -S -D -H -h /nonexistent -s "$shell" -G "$SVC_USER" "$SVC_USER" || return 1
    else
        error '无法创建系统用户 shadowsocks。'
        return 1
    fi
}

service_group() {
    id -gn "$SVC_USER" 2>/dev/null || printf '%s' "$SVC_USER"
}

own_service_file() {
    local path="$1" mode="$2" group
    [ -e "$path" ] || return 0
    group=$(service_group)
    chown "$SVC_USER:$group" "$path" || return 1
    chmod "$mode" "$path" || return 1
}

rotate_log() {
    local size
    [ -f "$LOG_FILE" ] || return 0
    size=$(wc -c < "$LOG_FILE")
    size=${size//[[:space:]]/}
    if [ "$size" -gt 1048576 ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" || return 1
        : > "$LOG_FILE" || return 1
        own_service_file "$LOG_FILE" 600 || return 1
        own_service_file "$LOG_FILE.1" 600 || return 1
    fi
}

secure_paths() {
    ensure_service_account || return 1
    mkdir -p "$CONF_DIR" || return 1
    own_service_file "$CONF_DIR" 750 || return 1
    if [ -f "$CONF" ]; then
        own_service_file "$CONF" 600 || return 1
    fi
    if [ "$(backend)" != systemd ]; then
        mkdir -p "${LOG_FILE%/*}" || return 1
        [ -e "$LOG_FILE" ] || : > "$LOG_FILE" || return 1
        own_service_file "$LOG_FILE" 600 || return 1
        rotate_log || return 1
    fi
}

resolve_setpriv() {
    local c
    SETPRIV=""
    for c in /usr/bin/setpriv /usr/sbin/setpriv /bin/setpriv "$(command -v setpriv 2>/dev/null || true)"; do
        [ -n "$c" ] && [ -x "$c" ] || continue
        "$c" --help 2>&1 | grep -q -- '--reuid' || continue
        SETPRIV=$c
        return 0
    done
    return 1
}

setpriv_supports() {
    [ -n "$SETPRIV" ] && "$SETPRIV" --help 2>&1 | grep -q -- "$1"
}

build_priv_cmd() {
    local port="$1"
    shift
    local group
    resolve_setpriv || {
        error '缺少支持 --reuid 的 setpriv，无法降权启动。'
        return 1
    }
    group=$(service_group)
    DROP_CMD=("$SETPRIV" --reuid="$SVC_USER" --regid="$group" --init-groups)
    if (( port < 1024 )); then
        DROP_CMD+=(--inh-caps=-all,+net_bind_service --ambient-caps=-all,+net_bind_service)
        setpriv_supports --bounding-set && DROP_CMD+=(--bounding-set=-all,+net_bind_service)
    else
        DROP_CMD+=(--inh-caps=-all --ambient-caps=-all)
        setpriv_supports --bounding-set && DROP_CMD+=(--bounding-set=-all)
        setpriv_supports --no-new-privs && DROP_CMD+=(--no-new-privs)
    fi
    DROP_CMD+=(-- "$@")
}

write_if_changed() {
    local dest="$1" mode="$2" tmp
    mkdir -p "$(dirname "$dest")" || return 1
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        UNIT_CHANGED=0
        return 0
    fi
    chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    UNIT_CHANGED=1
}

stop_direct() {
    local pid _
    if ! pid=$(server_pid); then
        rm -f "$PID_FILE"
        return 0
    fi
    kill "$pid" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        server_pid >/dev/null || break
        sleep 1
    done
    if server_pid >/dev/null; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
        sleep 1
    fi
    if server_pid >/dev/null; then
        return 1
    fi
    rm -f "$PID_FILE"
}

start_direct() {
    local pid
    secure_paths || return 1
    server_pid >/dev/null && return 0
    build_priv_cmd "$(listen_port)" "$BIN" -c "$CONF" || return 1
    rm -f "$PID_FILE"
    mkdir -p "${PID_FILE%/*}" || return 1
    # nohup 会替换成 ssserver，因此记录的就是服务进程；disown 避免退出菜单时被挂起。
    nohup "${DROP_CMD[@]}" >>"$LOG_FILE" 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null || true
    printf '%s\n' "$pid" > "$PID_FILE"
    sleep 1
    server_pid >/dev/null
}

svc() {
    local action="$1" b port limit group caps unit_tmp rc
    b=$(backend)
    case "$action/$b" in
        status/systemd) systemctl is-active --quiet "$APP" 2>/dev/null ;;
        status/openrc) rc-service "$APP" status >/dev/null 2>&1 ;;
        status/direct) server_pid >/dev/null ;;

        install/systemd)
            secure_paths || return 1
            port=$(listen_port)
            limit=$(nofile_limit)
            unit_tmp=$(mktemp "${TMPDIR:-/tmp}/ss-unit.XXXXXX") || return 1
            {
                printf '%s\n' '# Managed by shadowsocks.sh. Local overrides belong in' \
                    "# /etc/systemd/system/$APP.service.d/"
                cat <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=$SVC_USER
Group=$(service_group)
ExecStart=$BIN -c $CONF
Restart=on-failure
RestartSec=3
UMask=0077
LimitNOFILE=$limit
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
EOF
                if (( port < 1024 )); then
                    printf '%s\n' \
                        'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' \
                        'AmbientCapabilities=CAP_NET_BIND_SERVICE'
                else
                    printf '%s\n' \
                        'NoNewPrivileges=true' \
                        'CapabilityBoundingSet=' \
                        'AmbientCapabilities='
                fi
                printf '%s\n' '[Install]' 'WantedBy=multi-user.target'
            } > "$unit_tmp" || { rm -f "$unit_tmp"; return 1; }
            write_if_changed "$SYSTEMD_UNIT" 644 < "$unit_tmp"
            rc=$?
            rm -f "$unit_tmp"
            [ "$rc" -eq 0 ] || return 1
            if [ "$UNIT_CHANGED" = 1 ]; then
                systemctl daemon-reload || return 1
            fi
            systemctl enable "$APP" >/dev/null 2>&1 || return 1
            ;;
        install/openrc)
            secure_paths || return 1
            port=$(listen_port)
            limit=$(nofile_limit)
            group=$(service_group)
            caps=""
            if (( port < 1024 )); then
                caps='capabilities="net_bind_service"'
            else
                caps='no_new_privs=true'
            fi
            unit_tmp=$(mktemp "${TMPDIR:-/tmp}/ss-unit.XXXXXX") || return 1
            cat > "$unit_tmp" <<EOF
#!/sbin/openrc-run
# Managed by shadowsocks.sh.
name="Shadowsocks-Rust"
command="$BIN"
command_args="-c $CONF"
command_user="$SVC_USER:$group"
supervisor="supervise-daemon"
supervise_daemon_args="--stdout $LOG_FILE --stderr $LOG_FILE"
pidfile="$PID_FILE"
rc_ulimit="-n $limit"
$caps

depend() {
    need net
}
EOF
            write_if_changed "$OPENRC_UNIT" 755 < "$unit_tmp"
            rc=$?
            rm -f "$unit_tmp"
            [ "$rc" -eq 0 ] || return 1
            rc-update add "$APP" default >/dev/null 2>&1 || return 1
            ;;
        install/direct)
            secure_paths || return 1
            ;;

        start/systemd)
            systemctl reset-failed "$APP" >/dev/null 2>&1 || true
            if [ "${UNIT_CHANGED:-0}" = 1 ] && systemctl is-active --quiet "$APP" 2>/dev/null; then
                systemctl restart "$APP"
            else
                systemctl start "$APP"
            fi
            ;;
        start/openrc)
            if [ "${UNIT_CHANGED:-0}" = 1 ] && rc-service "$APP" status >/dev/null 2>&1; then
                rc-service "$APP" restart
            else
                rc-service "$APP" start
            fi
            ;;
        start/direct) start_direct ;;

        stop/systemd)
            if systemctl is-active --quiet "$APP" 2>/dev/null; then
                systemctl stop "$APP" || return 1
            fi
            systemctl is-active --quiet "$APP" 2>/dev/null && return 1
            return 0
            ;;
        stop/openrc)
            if rc-service "$APP" status >/dev/null 2>&1; then
                rc-service "$APP" stop || return 1
            fi
            rc-service "$APP" status >/dev/null 2>&1 && return 1
            return 0
            ;;
        stop/direct) stop_direct ;;

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

gnu_tool() {
    has "$1" && "$1" --version 2>&1 | grep -qi coreutils
}

packages() {
    local missing="" c
    for c in curl tar xz jq sha256sum base64; do
        has "$c" || missing="$missing $c"
    done
    gnu_tool base64 || missing="$missing coreutils"
    gnu_tool sha256sum || missing="$missing coreutils"
    has flock || missing="$missing flock"
    resolve_setpriv || missing="$missing setpriv"
    if [ ! -e /etc/ssl/certs/ca-certificates.crt ] && [ ! -d /etc/ssl/certs ]; then
        missing="$missing ca-certificates"
    fi
    [ -z "$missing" ] && return 0

    if has apk; then
        apk add --no-cache curl tar xz jq coreutils ca-certificates util-linux setpriv
    elif has apt-get; then
        env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            && env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                curl tar xz-utils jq coreutils ca-certificates util-linux
    elif has dnf; then
        dnf install -y curl tar xz jq coreutils ca-certificates util-linux
    elif has yum; then
        yum install -y curl tar xz jq coreutils ca-certificates util-linux
    elif has pacman; then
        pacman -S --needed --noconfirm curl tar xz jq coreutils ca-certificates util-linux
    else
        error "缺少依赖:$missing，且未找到包管理器。"
        return 1
    fi || return 1

    for c in curl tar xz jq sha256sum base64 flock; do
        has "$c" || { error "安装后仍缺少 $c。"; return 1; }
    done
    gnu_tool base64 && gnu_tool sha256sum || {
        error '需要 GNU coreutils 的 base64 和 sha256sum。'
        return 1
    }
    resolve_setpriv || {
        error '需要支持 --reuid 的 setpriv。'
        return 1
    }
}

asset_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64-unknown-linux-musl' ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-musl' ;;
        armv7l|armhf) printf 'armv7-unknown-linux-musleabihf' ;;
        i386|i686) printf 'i686-unknown-linux-musl' ;;
        riscv64|riscv64gc) printf 'riscv64gc-unknown-linux-musl' ;;
        loongarch64) printf 'loongarch64-unknown-linux-musl' ;;
        *) error "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
    esac
}

valid_tag() {
    [[ "${1:-}" =~ ^v[0-9]+(\.[0-9]+){2}$ ]]
}

curl_fetch() {
    curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
        -H 'User-Agent: shadowsocks.sh' "$@"
}

latest_tag() {
    local api tag url
    api=$(curl_fetch --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)
    tag=$(printf '%s' "$api" | jq -r '.tag_name // empty' 2>/dev/null || true)
    if valid_tag "$tag"; then
        printf '%s' "$tag"
        return 0
    fi

    url=$(curl_fetch --max-time 20 -I -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
    url=${url%%\?*}
    url=${url##*/tag/}
    if valid_tag "$url"; then
        printf '%s' "$url"
    else
        error '无法获取最新 Release 版本。'
        return 1
    fi
}

verify_archive() {
    local archive="$1" url="$2" line expected name actual base
    line=$(curl_fetch --max-time 20 "${url}.sha256" 2>/dev/null || true)
    line=${line%%$'\n'*}
    expected=${line%%[[:space:]]*}
    name=${line##*[[:space:]]}
    expected=${expected,,}
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
        error '无法获取官方 SHA256 校验值。'
        return 1
    }
    actual=$(sha256sum "$archive" | awk '{ print $1 }') || return 1
    actual=${actual,,}
    [ "$expected" = "$actual" ] || {
        error '安装包 SHA256 校验失败。'
        return 1
    }
    base=${url##*/}
    if [ -n "$name" ] && [ "$name" != "$expected" ] && [ "$name" != "$base" ]; then
        error '校验文件与安装包名称不符。'
        return 1
    fi
}

fetch() {
    local tag="${1:-}" arch url archive help method
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shadowsocks.XXXXXX") || return 1
    [ -n "$tag" ] || tag=$(latest_tag) || return 1
    valid_tag "$tag" || { error '版本号无效。'; return 1; }
    arch=$(asset_arch) || return 1
    archive="$TMP_DIR/server.tar.xz"
    url="https://github.com/$REPO/releases/download/$tag/shadowsocks-$tag.$arch.tar.xz"

    printf '下载 %s（%s）...\n' "$tag" "$arch"
    curl_fetch -o "$archive" "$url" 2>/dev/null || {
        error '下载失败，当前架构可能没有对应安装包。'
        return 1
    }
    verify_archive "$archive" "$url" || return 1
    tar -xf "$archive" -C "$TMP_DIR" ssserver 2>/dev/null || {
        error '安装包解压失败。'
        return 1
    }
    if [ -L "$TMP_DIR/ssserver" ] || [ ! -f "$TMP_DIR/ssserver" ]; then
        error '安装包内容异常。'
        return 1
    fi
    chmod 755 "$TMP_DIR/ssserver" || return 1
    if ! help=$("$TMP_DIR/ssserver" --help 2>&1); then
        error '下载的程序无法执行。'
        return 1
    fi
    for method in 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
        printf '%s' "$help" | grep -Fqi "$method" || {
            error "程序不支持 $method。"
            return 1
        }
    done
    NEW_BIN="$TMP_DIR/ssserver"
    NEW_VERSION="$tag"
}

# ---------- 配置层 ----------

cfg() {
    [ -f "$CONF" ] || return 0
    case "$1" in
        server_port|password|method|mode) ;;
        *) return 1 ;;
    esac
    jq -r --arg key "$1" '.[$key] // empty' "$CONF" 2>/dev/null || true
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

valid_port() {
    local value="${1:-}"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$value >= 1 && 10#$value <= 65535 )) || return 1
    printf '%s' "$((10#$value))"
}

generate_key() {
    head -c "$(key_bytes "$1")" /dev/urandom | base64 | tr -d '\n'
}

canonical_key() {
    local method="$1" key="$2" expected decoded encoded
    expected=$(key_bytes "$method") || return 1
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    key=$(printf '%s' "$key" | tr '_-' '/+')
    [ -n "$key" ] || return 1
    [[ "$key" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
    case $(( ${#key} % 4 )) in
        0) ;;
        2) key="${key}==" ;;
        3) key="${key}=" ;;
        *) return 1 ;;
    esac
    KEY_TMP=$(mktemp "${TMPDIR:-/tmp}/ss-key.XXXXXX") || return 1
    chmod 600 "$KEY_TMP" || { rm -f "$KEY_TMP"; KEY_TMP=""; return 1; }
    if ! printf '%s' "$key" | base64 -d > "$KEY_TMP" 2>/dev/null; then
        rm -f "$KEY_TMP"
        KEY_TMP=""
        return 1
    fi
    decoded=$(wc -c < "$KEY_TMP")
    decoded=${decoded//[[:space:]]/}
    encoded=$(base64 < "$KEY_TMP" | tr -d '\n')
    rm -f "$KEY_TMP"
    KEY_TMP=""
    [ "$decoded" -eq "$expected" ] && [ "$encoded" = "$key" ] || return 1
    printf '%s' "$encoded"
}

choose_method() {
    local current="${1:-$DEFAULT_METHOD}" choice
    is_2022_method "$current" || current="$DEFAULT_METHOD"
    printf '\n加密方式\n'
    printf '[1] 2022-blake3-aes-128-gcm\n'
    printf '[2] 2022-blake3-aes-256-gcm\n'
    printf '[3] 2022-blake3-chacha20-poly1305\n'
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
    case "$current" in
        tcp_only|udp_only|tcp_and_udp) ;;
        *) current="$DEFAULT_MODE" ;;
    esac
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
    local old_port old_password old_method old_mode value default_key current_method key_hint canon
    old_port=$(cfg server_port)
    old_password=$(cfg password)
    old_method=$(cfg method)
    old_mode=$(cfg mode)

    while :; do
        read -r -p "端口 [${old_port:-$DEFAULT_PORT}]: " value || return 1
        value=${value:-${old_port:-$DEFAULT_PORT}}
        if canon=$(valid_port "$value"); then
            SET_PORT="$canon"
            break
        fi
        printf '端口无效（1-65535）。\n'
    done

    is_2022_method "$old_method" && current_method="$old_method" || current_method="$DEFAULT_METHOD"
    choose_method "$current_method" || return 1
    choose_mode "${old_mode:-$DEFAULT_MODE}" || return 1
    if canon=$(canonical_key "$SET_METHOD" "$old_password"); then
        default_key="$canon"
        key_hint='保持'
    else
        default_key=$(generate_key "$SET_METHOD") || return 1
        key_hint='生成'
    fi

    while :; do
        read -r -s -p "PSK [回车$key_hint]: " value || return 1
        printf '\n'
        value=${value:-$default_key}
        if canon=$(canonical_key "$SET_METHOD" "$value"); then
            SET_PASSWORD="$canon"
            break
        fi
        printf 'PSK 无效，需要 %s 字节的 Base64（可省略填充，也可用 URL 安全字符）。\n' \
            "$(key_bytes "$SET_METHOD")"
    done
}

save_config() {
    local port="$1" password="$2" method="$3" mode="$4" temp group
    valid_port "$port" >/dev/null || return 1
    is_2022_method "$method" || return 1
    canonical_key "$method" "$password" >/dev/null || return 1
    case "$mode" in
        tcp_only|udp_only|tcp_and_udp) ;;
        *) return 1 ;;
    esac
    mkdir -p "$CONF_DIR" || return 1
    chmod 750 "$CONF_DIR" || return 1
    temp=$(mktemp "$CONF_DIR/config.json.XXXXXX") || return 1
    # 密钥走 stdin，避免出现在 jq 的进程参数里。
    if ! printf '%s' "$password" | jq -Rs \
        --arg port "$port" --arg method "$method" --arg mode "$mode" \
        '{server:"::",server_port:($port|tonumber),password:.,method:$method,mode:$mode,fast_open:false}' \
        > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    chmod 600 "$temp" || { rm -f "$temp"; return 1; }
    if id -u "$SVC_USER" >/dev/null 2>&1; then
        group=$(service_group)
        chown "$SVC_USER:$group" "$temp" || { rm -f "$temp"; return 1; }
    fi
    mv -f "$temp" "$CONF" || { rm -f "$temp"; return 1; }
}

install_file() {
    local src="$1" dest="$2" mode="$3" tmp
    mkdir -p "$(dirname "$dest")" || return 1
    tmp=$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX") || return 1
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
    chown root:root "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

version() {
    [ -x "$BIN" ] || return 0
    "$BIN" --version 2>/dev/null | awk 'NR == 1 { print $2 }'
}

version_newer() {
    local latest="${1#v}" current="${2#v}" IFS=. i av bv
    local -a a b
    [[ "$latest" =~ ^[0-9]+(\.[0-9]+){2}$ ]] || return 1
    [[ "$current" =~ ^[0-9]+(\.[0-9]+){2}$ ]] || return 0
    read -r -a a <<< "$latest"
    read -r -a b <<< "$current"
    for i in 0 1 2; do
        av=${a[$i]:-0}
        bv=${b[$i]:-0}
        if (( 10#$av > 10#$bv )); then return 0; fi
        if (( 10#$av < 10#$bv )); then return 1; fi
    done
    return 1
}

b64url() {
    printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'
}

share_uri() {
    local method="$1" password="$2" host="$3" port="$4" tag="$5" userinfo
    userinfo=$(b64url "${method}:${password}")
    printf 'ss://%s@%s:%s#%s' "$userinfo" "$host" "$port" "$tag"
}

is_global_ipv4() {
    local ip="${1:-}" a b c d
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a=${BASH_REMATCH[1]}
    b=${BASH_REMATCH[2]}
    c=${BASH_REMATCH[3]}
    d=${BASH_REMATCH[4]}
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    return 0
}

is_global_ipv6() {
    local ip="${1,,}"
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" == *.* || "$ip" == *%* ]] && return 1
    [[ "$ip" == :: || "$ip" == ::1 ]] && return 1
    [[ "$ip" == fe80:* || "$ip" == fc* || "$ip" == fd* || "$ip" == ff* ]] && return 1
    return 0
}

route_src() {
    local family="$1" target="$2"
    has ip || return 1
    ip "$family" route get "$target" 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }
    }'
}

# ---------- 操作层 ----------

begin_rollback() {
    local dir
    RB_HAD_CONFIG=0
    RB_HAD_BIN=0
    RB_WAS_RUNNING=0
    RB_ACTIVE=0
    mkdir -p "$CONF_DIR" || return 1
    dir=$(mktemp -d "$CONF_DIR/rollback.XXXXXX") || return 1
    chmod 700 "$dir" || { rm -rf "$dir"; return 1; }
    if [ -f "$CONF" ]; then
        cp -a "$CONF" "$dir/config.json" || { rm -rf "$dir"; return 1; }
        RB_HAD_CONFIG=1
    fi
    if [ -e "$BIN" ]; then
        cp -a "$BIN" "$dir/ssserver" || { rm -rf "$dir"; return 1; }
        RB_HAD_BIN=1
    fi
    if svc status; then
        RB_WAS_RUNNING=1
    fi
    ROLLBACK_DIR=$dir
    RB_ACTIVE=1
}

abort_rollback() {
    RB_ACTIVE=0
    [ -z "$ROLLBACK_DIR" ] || rm -rf "$ROLLBACK_DIR"
    ROLLBACK_DIR=""
}

commit_rollback() {
    abort_rollback
}

restore_runtime() {
    [ "${RB_ACTIVE:-0}" = 1 ] || return 0
    svc stop >/dev/null 2>&1 || true
    if [ "$RB_HAD_BIN" = 1 ]; then
        install_file "$ROLLBACK_DIR/ssserver" "$BIN" 755 || return 1
    else
        rm -f "$BIN"
    fi
    if [ "$RB_HAD_CONFIG" = 1 ]; then
        install_file "$ROLLBACK_DIR/config.json" "$CONF" 600 || return 1
        own_service_file "$CONF" 600 || return 1
    else
        rm -f "$CONF"
    fi
    if [ "$RB_HAD_BIN" = 1 ] && [ "$RB_HAD_CONFIG" = 1 ]; then
        svc install >/dev/null 2>&1 || true
        if [ "$RB_WAS_RUNNING" = 1 ]; then
            svc start >/dev/null 2>&1 || true
        fi
    elif [ "$RB_HAD_BIN" = 0 ]; then
        svc remove >/dev/null 2>&1 || true
    fi
    abort_rollback
}

fail_apply() {
    local msg="$1"
    if restore_runtime; then
        clean_tmp
        error "$msg"
    else
        error "$msg 自动恢复失败，备份在 $ROLLBACK_DIR"
        RB_ACTIVE=1
        clean_tmp
    fi
    return 1
}

activate() {
    local new_bin="${1:-}" message="$2" do_config="${3:-0}"
    begin_rollback || { clean_tmp; error '无法备份当前文件。'; return 1; }
    if ! svc stop; then
        abort_rollback
        clean_tmp
        error '无法停止当前服务。'
        return 1
    fi
    if [ -n "$new_bin" ]; then
        install_file "$new_bin" "$BIN" 755 || { fail_apply '程序文件写入失败，已恢复。'; return 1; }
    fi
    ensure_service_account || { fail_apply '无法创建运行账号，已恢复。'; return 1; }
    if [ "$do_config" = 1 ]; then
        save_config "$SET_PORT" "$SET_PASSWORD" "$SET_METHOD" "$SET_MODE" || {
            fail_apply '配置文件写入失败，已恢复。'
            return 1
        }
    fi
    secure_paths || { fail_apply '权限设置失败，已恢复。'; return 1; }
    svc install || { fail_apply '服务配置写入失败，已恢复。'; return 1; }
    if svc start; then
        commit_rollback
        clean_tmp
        printf '%s\n' "$message"
        show_info || true
    else
        fail_apply '服务启动失败，已恢复。'
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
    activate "$new_bin" '安装完成。' 1
}

configure_app() {
    packages || return 1
    [ -x "$BIN" ] || { error '尚未安装，请先选择“安装”。'; return 1; }
    ask_config || return 1
    activate '' '配置完成。' 1
}

update_app() {
    local latest current new_bin
    packages || return 1
    [ -x "$BIN" ] || { error '尚未安装，请先选择“安装”。'; return 1; }
    [ -f "$CONF" ] || { error '配置文件不存在，请先选择“配置”。'; return 1; }
    latest=$(latest_tag) || return 1
    current=$(version)
    if [ -n "$current" ] && ! version_newer "$latest" "$current"; then
        printf '当前已是最新版本：%s\n' "$current"
        return 0
    fi
    fetch "$latest" || { clean_tmp; return 1; }
    new_bin="$NEW_BIN"
    activate "$new_bin" "已更新至 $NEW_VERSION。" 0
}

start_app() {
    [ -x "$BIN" ] || { error '尚未安装。'; return 1; }
    [ -f "$CONF" ] || { error '配置文件不存在。'; return 1; }
    packages || return 1
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
    [ -f "$CONF" ] || { error '配置文件不存在。'; return 1; }
    packages || return 1
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
    local port password method mode ip4 ip6 local4 local6 ext host
    has jq || { error '缺少 jq，请先选择“安装”。'; return 1; }
    has base64 || { error '缺少 base64，请先选择“安装”。'; return 1; }
    [ -f "$CONF" ] || { error '配置文件不存在。'; return 1; }

    port=$(cfg server_port)
    password=$(cfg password)
    method=$(cfg method)
    mode=$(cfg mode)
    local4=$(route_src -4 1.1.1.1 || true)
    local6=$(route_src -6 2001:4860:4860::8888 || true)
    ip4=""; ip6=""
    is_global_ipv4 "$local4" && ip4="$local4"
    is_global_ipv6 "$local6" && ip6="$local6"
    if [ -z "$ip4" ] && has curl; then
        ext=$(curl -4fsS --connect-timeout 3 --max-time 3 https://api.ipify.org 2>/dev/null || true)
        is_global_ipv4 "$ext" && ip4="$ext"
    fi
    if [ -z "$ip6" ] && has curl; then
        ext=$(curl -6fsS --connect-timeout 3 --max-time 3 https://api64.ipify.org 2>/dev/null || true)
        is_global_ipv6 "$ext" && ip6="$ext"
    fi

    printf '\n状态  %s  %s\n' \
        "$(svc status && printf '运行中' || printf '已停止')" "$(version)"
    printf '账号  %s\n' "$SVC_USER"
    [ -n "$ip4" ] && printf 'IPv4  %s\n' "$ip4"
    [ -n "$ip6" ] && printf 'IPv6  %s\n' "$ip6"
    if [ -z "$ip4" ] && [ -n "$local4" ]; then
        printf '内网  %s\n' "$local4"
    fi
    if [ -z "$ip6" ] && [ -n "$local6" ]; then
        printf '内网  %s\n' "$local6"
    fi
    [ -n "$ip4" ] || [ -n "$ip6" ] || [ -n "$local4" ] || printf '地址  未知\n'
    printf '端口  %s\n加密  %s\nPSK   %s\n模式  %s\n' "$port" "$method" "$password" "$mode"

    if [ -n "$ip4" ]; then
        printf 'IPv4链接  %s\n' "$(share_uri "$method" "$password" "$ip4" "$port" ss-rust-ipv4)"
    fi
    if [ -n "$ip6" ]; then
        host="[$ip6]"
        printf 'IPv6链接  %s\n' "$(share_uri "$method" "$password" "$host" "$port" ss-rust-ipv6)"
    fi
    [ -n "$ip4" ] || [ -n "$ip6" ] || printf '链接  无公网地址，请手动替换服务器 IP。\n'
    printf '提示  链接为 SIP002。PSK 会留在终端回滚缓冲。\n'
    printf '提示  请确认云防火墙已放行 %s/tcp、udp。\n' "$port"
}

show_logs() {
    case "$(backend)" in
        systemd) journalctl -u "$APP" -n 50 --no-pager 2>/dev/null || error '无法读取 systemd 日志。' ;;
        *) [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || printf '暂无日志。\n' ;;
    esac
}

remove_service_account() {
    if has userdel; then
        userdel "$SVC_USER" >/dev/null 2>&1 || true
    elif has deluser; then
        deluser "$SVC_USER" >/dev/null 2>&1 || true
    fi
    if has groupdel; then
        groupdel "$SVC_USER" >/dev/null 2>&1 || true
    elif has delgroup; then
        delgroup "$SVC_USER" >/dev/null 2>&1 || true
    fi
}

uninstall_app() {
    local value
    [ -e "$BIN" ] || [ -e "$CONF_DIR" ] || { error '尚未安装。'; return 1; }
    read -r -p '确认卸载？[y/N] ' value || return 1
    case "$value" in
        y|Y|yes|YES) ;;
        *) printf '已取消。\n'; return ;;
    esac
    svc remove || { error '服务移除失败，已停止卸载。'; return 1; }
    rm -f "$BIN" "$PID_FILE" "$LOG_FILE" "$LOG_FILE.1"
    rm -rf "$CONF_DIR"
    remove_service_account
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

clear_screen() {
    printf '\033[2J\033[H'
}

menu() {
    local choice action refresh=1
    while :; do
        [ "$refresh" -eq 1 ] && clear_screen
        printf '\nShadowsocks-Rust\n'
        status_line
        printf '\n[1] 安装  [2] 配置  [3] 更新\n'
        printf '[4] 启动  [5] 停止  [6] 重启\n'
        printf '[7] 信息  [8] 日志  [9] 卸载\n'
        read -r -p '选择 [q退出]: ' choice || break
        case "$choice" in
            1) action=install_app ;;
            2) action=configure_app ;;
            3) action=update_app ;;
            4) action=start_app ;;
            5) action=stop_app ;;
            6) action=restart_app ;;
            7) action=show_info ;;
            8) action=show_logs ;;
            9) action=uninstall_app ;;
            q|Q) break ;;
            *) printf '无效选项。\n'; refresh=0; continue ;;
        esac
        clear_screen
        "$action"
        refresh=0
    done
}

acquire_lock() {
    local dir="/run/lock"
    if ! has flock; then
        packages || return 1
    fi
    [ -d /run/lock ] || dir="/run"
    [ -d "$dir" ] || dir="${TMPDIR:-/tmp}"
    mkdir -p "$dir" 2>/dev/null || true
    exec 9>"$dir/shadowsocks.sh.lock" || { error '无法创建运行锁。'; return 1; }
    flock -n 9 || { error '已有另一个实例正在运行。'; return 1; }
}

if [ "${SS_LIBRARY_ONLY:-0}" != 1 ]; then
    root || exit 1
    acquire_lock || exit 1
    menu
fi
