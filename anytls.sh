#!/usr/bin/env bash
set -u

APP='anytls'
REPO='anytls/anytls-go'
DEFAULT_PORT='8443'
BASE_DIR='/etc/anytls'
BIN="$BASE_DIR/anytls-server"
ENV_FILE="$BASE_DIR/config"
VERSION_FILE="$BASE_DIR/version"
PID_FILE='/run/anytls.pid'
LOG_FILE='/var/log/anytls.log'
SYSTEMD_UNIT="/etc/systemd/system/$APP.service"
OPENRC_UNIT="/etc/init.d/$APP"
TMP_DIR=''
NEW_BIN=''
NEW_VERSION=''
RELEASE_TAG=''
RELEASE_URL=''
RELEASE_DIGEST=''

has() { command -v "$1" >/dev/null 2>&1; }
error() { printf '错误：%s\n' "$*" >&2; }

root() {
    [ "$(id -u)" -eq 0 ] || { error '请使用 root 权限运行。'; return 1; }
}

clean_tmp() {
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
    TMP_DIR=''
    NEW_BIN=''
}
trap clean_tmp EXIT

backend() {
    if has systemctl && [ -d /run/systemd/system ]; then
        printf 'systemd'
    elif has rc-service && has rc-update; then
        printf 'openrc'
    else
        printf 'direct'
    fi
}

cfg() {
    [ -r "$ENV_FILE" ] || return 0
    case "$1" in
        port) sed -n 's/^ANYTLS_PORT=//p' "$ENV_FILE" ;;
        password) sed -n 's/^ANYTLS_PASSWORD=//p' "$ENV_FILE" ;;
        sni) sed -n 's/^ANYTLS_SNI=//p' "$ENV_FILE" ;;
    esac
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

save_config() {
    local temp
    mkdir -p "$BASE_DIR" || return 1
    temp=$(mktemp "$BASE_DIR/config.XXXXXX") || return 1
    if ! printf 'ANYTLS_PORT=%s\nANYTLS_SNI=%s\nANYTLS_PASSWORD=%s\n' \
        "$1" "$2" "$3" > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    if ! chmod 600 "$temp" || ! mv "$temp" "$ENV_FILE"; then
        rm -f "$temp"
        return 1
    fi
}

save_version() {
    local temp
    temp=$(mktemp "$BASE_DIR/version.XXXXXX") || return 1
    if ! printf '%s\n' "$1" > "$temp" || ! chmod 600 "$temp" || ! mv "$temp" "$VERSION_FILE"; then
        rm -f "$temp"
        return 1
    fi
}

valid_tag() {
    [[ "${1:-}" =~ ^v[0-9]+(\.[0-9]+){2}$ ]]
}

valid_password() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._~-]{8,128}$ ]]
}

valid_sni() {
    local value="${1:-}" label
    local -a labels
    [ -z "$value" ] && return 0
    ((${#value} <= 253)) || return 1
    [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
    local IFS=.
    read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
        ((${#label} <= 63)) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

random_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

asset_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) error "不支持当前架构：$(uname -m)，官方 Release 仅提供 amd64 和 arm64。"; return 1 ;;
    esac
}

release_info() {
    local api arch asset digest
    arch=$(asset_arch) || return 1
    api=$(curl -fsSL --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: anytls.sh' \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || {
        error '无法获取 AnyTLS 最新 Release。'
        return 1
    }
    RELEASE_TAG=$(printf '%s' "$api" | jq -r '.tag_name // empty' 2>/dev/null)
    valid_tag "$RELEASE_TAG" || { error 'Release 版本格式无效。'; return 1; }
    asset="anytls_${RELEASE_TAG#v}_linux_${arch}.zip"
    RELEASE_URL=$(printf '%s' "$api" | jq -r --arg name "$asset" \
        '.assets[]? | select(.name == $name) | .browser_download_url' 2>/dev/null)
    digest=$(printf '%s' "$api" | jq -r --arg name "$asset" \
        '.assets[]? | select(.name == $name) | .digest' 2>/dev/null)
    RELEASE_DIGEST=${digest#sha256:}
    if [[ -z "$RELEASE_URL" || ! "$RELEASE_DIGEST" =~ ^[0-9a-fA-F]{64}$ ]]; then
        error "找不到 $asset 或官方 SHA256 摘要。"
        return 1
    fi
}

fetch_release() {
    local archive actual
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/anytls.XXXXXX") || return 1
    archive="$TMP_DIR/anytls.zip"
    printf '下载 %s（%s）...\n' "$RELEASE_TAG" "${RELEASE_URL##*/}"
    curl -fLsS --connect-timeout 10 --max-time 90 \
        -H 'User-Agent: anytls.sh' -o "$archive" "$RELEASE_URL" 2>/dev/null || {
        error '下载失败。'
        return 1
    }
    actual=$(sha256sum "$archive") || return 1
    actual=${actual%% *}
    [ "$actual" = "$RELEASE_DIGEST" ] || {
        error '安装包 SHA256 校验失败。'
        return 1
    }
    unzip -p "$archive" anytls-server > "$TMP_DIR/anytls-server" 2>/dev/null || {
        error '安装包解压失败。'
        return 1
    }
    chmod 755 "$TMP_DIR/anytls-server"
    "$TMP_DIR/anytls-server" -h 2>&1 | grep -q -- '-p string' || {
        error '安装包不是可用的 AnyTLS 服务端。'
        return 1
    }
    NEW_BIN="$TMP_DIR/anytls-server"
    NEW_VERSION="$RELEASE_TAG"
}

fetch() {
    release_info && fetch_release
}

version() {
    [ -r "$VERSION_FILE" ] && cat "$VERSION_FILE"
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

choose_config() {
    local old_port old_sni old_password value default_password
    old_port=$(cfg port)
    old_sni=$(cfg sni)
    old_password=$(cfg password)

    while :; do
        read -r -p "端口 [${old_port:-$DEFAULT_PORT}]: " value || return 1
        value=${value:-${old_port:-$DEFAULT_PORT}}
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
            SET_PORT="$value"
            break
        fi
        printf '端口无效（1-65535）。\n'
    done

    while :; do
        if [ -n "$old_sni" ]; then
            read -r -p "SNI [$old_sni]（回车保持，- 清除）: " value || return 1
            if [ "$value" = '-' ]; then
                value=''
            elif [ -z "$value" ]; then
                value="$old_sni"
            fi
        else
            read -r -p 'SNI [可选，回车关闭]: ' value || return 1
        fi
        if valid_sni "$value"; then
            SET_SNI="$value"
            break
        fi
        printf 'SNI 无效，请输入合法域名（例如 www.example.com）。\n'
    done

    default_password=${old_password:-$(random_password)}
    while :; do
        read -r -s -p '密码 [回车保持/生成]: ' value || return 1
        printf '\n'
        SET_PASSWORD=${value:-$default_password}
        if valid_password "$SET_PASSWORD"; then
            break
        fi
        printf '密码无效，请使用 8-128 位字母、数字或 . _ ~ -。\n'
    done
}

svc() {
    local action="$1" b port password
    b=$(backend)
    case "$action/$b" in
        status/systemd) systemctl is-active --quiet "$APP" ;;
        status/openrc) rc-service "$APP" status >/dev/null 2>&1 ;;
        status/direct) server_pid >/dev/null ;;

        install/systemd)
            cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=AnyTLS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$BIN -l :\${ANYTLS_PORT} -p \${ANYTLS_PASSWORD}
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
. "$ENV_FILE"
name="AnyTLS"
command="$BIN"
command_args="-l :\${ANYTLS_PORT} -p \${ANYTLS_PASSWORD}"
supervisor="supervise-daemon"
supervise_daemon_args="--stdout $LOG_FILE --stderr $LOG_FILE"
pidfile="$PID_FILE"

depend() {
    need net
}
EOF
            chmod 755 "$OPENRC_UNIT" || return 1
            rc-update add "$APP" default >/dev/null 2>&1 || return 1
            ;;
        install/direct) ;;

        start/systemd)
            systemctl start "$APP" && systemctl is-active --quiet "$APP"
            ;;
        start/openrc)
            rc-service "$APP" start && rc-service "$APP" status >/dev/null 2>&1
            ;;
        start/direct)
            svc status && return 0
            port=$(cfg port); password=$(cfg password)
            [ -n "$port" ] && [ -n "$password" ] || return 1
            rm -f "$PID_FILE"
            mkdir -p "${LOG_FILE%/*}" "${PID_FILE%/*}"
            nohup "$BIN" -l ":$port" -p "$password" \
                >>"$LOG_FILE" 2>&1 &
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
    esac
}

apply_config() {
    local new_bin="${1:-}" message="${2:-配置完成。}"
    svc stop || { clean_tmp; error '无法停止当前服务。'; return 1; }
    if [ -n "$new_bin" ]; then
        mkdir -p "${BIN%/*}"
        if ! cp "$new_bin" "$BIN" || ! chmod 755 "$BIN"; then
            clean_tmp
            error '程序文件写入失败。'
            return 1
        fi
    fi
    save_config "$SET_PORT" "$SET_SNI" "$SET_PASSWORD" || {
        clean_tmp
        error '配置文件写入失败。'
        return 1
    }
    if [ -n "$new_bin" ]; then
        save_version "$NEW_VERSION" || {
            clean_tmp
            error '版本文件写入失败。'
            return 1
        }
    fi
    clean_tmp
    svc install || { error '服务配置写入失败。'; return 1; }
    if svc start; then
        printf '%s\n' "$message"
        show_info
    else
        error "$message，但服务启动失败。"
        return 1
    fi
}

install_app() {
    local new_bin
    packages || return 1
    [ ! -x "$BIN" ] || { error '已经安装，请选择“配置”。'; return 1; }
    fetch || { clean_tmp; return 1; }
    new_bin="$NEW_BIN"
    choose_config || { clean_tmp; return 1; }
    apply_config "$new_bin" '安装完成。'
}

configure_app() {
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未安装，请先选择“安装”。'
        return 1
    fi
    choose_config || return 1
    apply_config '' '配置完成。'
}

update_app() {
    local latest current
    packages || return 1
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未安装，请先选择“安装”。'
        return 1
    fi
    release_info || return 1
    latest="$RELEASE_TAG"
    current=$(version)
    if [ -n "$current" ] && ! version_newer "$latest" "$current"; then
        printf '当前已是最新版本：%s\n' "$current"
        return 0
    fi
    fetch_release || { clean_tmp; return 1; }
    svc stop || { clean_tmp; error '无法停止当前服务。'; return 1; }
    if ! cp "$NEW_BIN" "$BIN" || ! chmod 755 "$BIN"; then
        clean_tmp
        error '程序文件写入失败。'
        return 1
    fi
    if ! save_version "$NEW_VERSION"; then
        clean_tmp
        error '版本文件写入失败。'
        return 1
    fi
    clean_tmp
    svc install || { error '服务配置更新失败。'; return 1; }
    if svc start; then
        printf '更新至 %s\n' "$NEW_VERSION"
    else
        error '更新完成，但服务启动失败。'
        return 1
    fi
}

start_app() {
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未安装，请先选择“安装”。'
        return 1
    fi
    if svc start; then
        printf '服务已启动。\n'
    else
        error '服务启动失败。'
        return 1
    fi
}

stop_app() {
    svc stop || { error '服务停止失败。'; return 1; }
    printf '服务已停止。\n'
}

restart_app() {
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未安装，请先选择“安装”。'
        return 1
    fi
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
    local port sni password ip4 ip6 host query
    [ -r "$ENV_FILE" ] || { error '配置文件不存在。'; return 1; }
    port=$(cfg port)
    sni=$(cfg sni)
    password=$(cfg password)
    ip4=''; ip6=''; query=''
    if [ -n "$sni" ]; then
        query="/?sni=$sni"
    fi
    if has curl; then
        ip4=$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
        ip6=$(curl -6fsS --max-time 3 https://api64.ipify.org 2>/dev/null || true)
    fi

    printf '\n状态  %s  %s\n' \
        "$(svc status && printf '运行中' || printf '已停止')" "$(version)"
    [ -n "$ip4" ] && printf 'IPv4  %s\n' "$ip4"
    [ -n "$ip6" ] && printf 'IPv6  %s\n' "$ip6"
    [ -n "$ip4" ] || [ -n "$ip6" ] || printf '地址  未知\n'
    printf '端口  %s\nSNI   %s\n协议  AnyTLS\n密码  %s\n' \
        "$port" "${sni:-未设置}" "$password"
    if [ -n "$ip4" ]; then
        printf 'IPv4链接  anytls://%s@%s:%s%s\n' "$password" "$ip4" "$port" "$query"
    fi
    if [ -n "$ip6" ]; then
        host="[$ip6]"
        printf 'IPv6链接  anytls://%s@%s:%s%s\n' "$password" "$host" "$port" "$query"
    fi
    [ -n "$ip4" ] || [ -n "$ip6" ] || printf '链接  无公网地址，请手动替换服务器 IP。\n'
    printf '提示  请确认云防火墙已放行 %s/tcp。\n' "$port"
}

show_logs() {
    case "$(backend)" in
        systemd) journalctl -u "$APP" -n 80 --no-pager 2>/dev/null || true ;;
        openrc|direct)
            [ -f "$LOG_FILE" ] && tail -n 80 "$LOG_FILE" || printf '暂无日志。\n'
            ;;
    esac
}

uninstall_app() {
    local value
    [ -x "$BIN" ] || { error '尚未安装。'; return 1; }
    read -r -p '确认卸载？[y/N] ' value || return 1
    case "$value" in
        y|Y|yes|YES) ;;
        *) printf '已取消。\n'; return ;;
    esac
    svc remove || { error '服务移除失败，已停止卸载。'; return 1; }
    rm -f "$BIN" "$ENV_FILE" "$BASE_DIR"/config.* "$VERSION_FILE" \
        "$PID_FILE" "$LOG_FILE"
    rmdir "$BASE_DIR" 2>/dev/null || true
    printf '已卸载。\n'
}

packages() {
    local missing='' c
    for c in curl jq unzip sha256sum; do
        has "$c" || missing="$missing $c"
    done
    [ -z "$missing" ] && return 0

    if has apk; then
        apk add --no-cache curl jq unzip coreutils
    elif has apt-get; then
        apt-get update -qq && apt-get install -y curl jq unzip coreutils
    elif has dnf; then
        dnf install -y curl jq unzip coreutils
    elif has yum; then
        yum install -y curl jq unzip coreutils
    elif has pacman; then
        pacman -Sy --noconfirm curl jq unzip coreutils
    else
        error "缺少依赖:$missing，且未找到包管理器。"
        return 1
    fi
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
        printf '\nAnyTLS\n'
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

root || exit 1
menu
