#!/usr/bin/env bash
set -u
umask 077

APP='anytls'
PROXY_APP='anytls-proxy'
SVC_USER='anytls'
REPO='anytls/anytls-go'
DEFAULT_PORT='8443'
BASE_DIR='/etc/anytls'
BIN="$BASE_DIR/anytls-server"
ENV_FILE="$BASE_DIR/config"
VERSION_FILE="$BASE_DIR/version"
CERT_DIR="$BASE_DIR/certs"
CERT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/domain.key"
HAPROXY_PEM="$CERT_DIR/haproxy.pem"
HAPROXY_CFG="$BASE_DIR/haproxy.cfg"
ACME_HOME="$BASE_DIR/acme"
ACME_BIN="$ACME_HOME/acme.sh"
ACME_VERSION='3.1.6'
ACME_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/$ACME_VERSION/acme.sh"
ACME_SHA256='c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7'
RELOAD_SCRIPT="$BASE_DIR/reload-cert"
PID_FILE='/run/anytls.pid'
PROXY_PID_FILE='/run/anytls-proxy.pid'
LOG_FILE='/var/log/anytls.log'
PROXY_LOG_FILE='/var/log/anytls-proxy.log'
SYSTEMD_UNIT="/etc/systemd/system/$APP.service"
PROXY_SYSTEMD_UNIT="/etc/systemd/system/$PROXY_APP.service"
ACME_SYSTEMD_UNIT="/etc/systemd/system/$APP-acme.service"
ACME_TIMER_UNIT="/etc/systemd/system/$APP-acme.timer"
OPENRC_UNIT="/etc/init.d/$APP"
PROXY_OPENRC_UNIT="/etc/init.d/$PROXY_APP"
ACME_CRON_FILE="/etc/cron.d/$APP-acme"
ACME_CRON_MARKER='# anytls-acme-renewal'
HAPROXY_BIN=''
SETPRIV=''
DROP_CMD=()
TMP_DIR=''
ROLLBACK_DIR=''
NEW_BIN=''
NEW_VERSION=''
RELEASE_TAG=''
RELEASE_URL=''
RELEASE_DIGEST=''
RB_ACTIVE=0
RB_HAD_CONFIG=0
RB_HAD_BIN=0
RB_WAS_RUNNING=0
UNIT_CHANGED=0

has() { command -v "$1" >/dev/null 2>&1; }
error() { printf '错误：%s\n' "$*" >&2; return 1; }

root() {
    [ "$(id -u)" -eq 0 ] || error '请使用 root 权限运行。'
}

clean_tmp() {
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
    TMP_DIR=''
    NEW_BIN=''
    if [ "${RB_ACTIVE:-0}" != 1 ] && [ -n "$ROLLBACK_DIR" ]; then
        rm -rf "$ROLLBACK_DIR"
        ROLLBACK_DIR=''
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
        tls_mode) sed -n 's/^ANYTLS_TLS_MODE=//p' "$ENV_FILE" ;;
        domain) sed -n 's/^ANYTLS_DOMAIN=//p' "$ENV_FILE" ;;
        email) sed -n 's/^ANYTLS_EMAIL=//p' "$ENV_FILE" ;;
        backend_port) sed -n 's/^ANYTLS_BACKEND_PORT=//p' "$ENV_FILE" ;;
        *) return 1 ;;
    esac
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

proc_uid() {
    awk '/^Uid:/ { print $2; exit }' "/proc/$1/status" 2>/dev/null
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

proxy_pid() {
    local pid cmd
    [ -s "$PROXY_PID_FILE" ] || return 1
    pid=$(cat "$PROXY_PID_FILE" 2>/dev/null) || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    case "$cmd" in *haproxy*"$HAPROXY_CFG"*) printf '%s' "$pid" ;; *) return 1 ;; esac
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
            error '无法创建用户组 anytls。'
            return 1
        fi
    fi
    if has useradd; then
        useradd --system --gid "$SVC_USER" --home-dir /nonexistent \
            --no-create-home --shell "$shell" "$SVC_USER" || return 1
    elif has adduser; then
        adduser -S -D -H -h /nonexistent -s "$shell" -G "$SVC_USER" "$SVC_USER" || return 1
    else
        error '无法创建系统用户 anytls。'
        return 1
    fi
}

service_group() {
    id -gn "$SVC_USER" 2>/dev/null || printf '%s' "$SVC_USER"
}

remove_service_account() {
    if id -u "$SVC_USER" >/dev/null 2>&1; then
        if has userdel; then
            userdel "$SVC_USER" >/dev/null 2>&1 || true
        elif has deluser; then
            deluser "$SVC_USER" >/dev/null 2>&1 || true
        fi
    fi
    if has groupdel; then
        groupdel "$SVC_USER" >/dev/null 2>&1 || true
    elif has delgroup; then
        delgroup "$SVC_USER" >/dev/null 2>&1 || true
    fi
}

own_file() {
    local path="$1" owner="$2" mode="$3"
    [ -e "$path" ] || return 0
    chown "$owner" "$path" || return 1
    chmod "$mode" "$path" || return 1
}

secure_tree() {
    local group
    ensure_service_account || return 1
    group=$(service_group)
    mkdir -p "$BASE_DIR" "$CERT_DIR" || return 1
    # 目录可进入但不可列出，配置和账户密钥仍只有 root 能读。
    chown "root:$group" "$BASE_DIR" "$CERT_DIR" || return 1
    chmod 751 "$BASE_DIR" "$CERT_DIR" || return 1
    [ -e "$BIN" ] && { chown root:root "$BIN" && chmod 755 "$BIN" || return 1; }
    [ -f "$ENV_FILE" ] && { chown root:root "$ENV_FILE" && chmod 600 "$ENV_FILE" || return 1; }
    [ -f "$VERSION_FILE" ] && { chown root:root "$VERSION_FILE" && chmod 600 "$VERSION_FILE" || return 1; }
    [ -f "$CERT_FILE" ] && { chown root:root "$CERT_FILE" && chmod 600 "$CERT_FILE" || return 1; }
    [ -f "$KEY_FILE" ] && { chown root:root "$KEY_FILE" && chmod 600 "$KEY_FILE" || return 1; }
    [ -f "$HAPROXY_CFG" ] && { chown "root:$group" "$HAPROXY_CFG" && chmod 640 "$HAPROXY_CFG" || return 1; }
    [ -f "$HAPROXY_PEM" ] && { chown "$SVC_USER:$group" "$HAPROXY_PEM" && chmod 600 "$HAPROXY_PEM" || return 1; }
    [ -f "$RELOAD_SCRIPT" ] && { chown root:root "$RELOAD_SCRIPT" && chmod 700 "$RELOAD_SCRIPT" || return 1; }
    if [ "$(backend)" != systemd ]; then
        mkdir -p "${LOG_FILE%/*}" || return 1
        [ -e "$LOG_FILE" ] || : > "$LOG_FILE" || return 1
        [ -e "$PROXY_LOG_FILE" ] || : > "$PROXY_LOG_FILE" || return 1
        own_file "$LOG_FILE" "$SVC_USER:$group" 600 || return 1
        own_file "$PROXY_LOG_FILE" "$SVC_USER:$group" 600 || return 1
    fi
}

resolve_setpriv() {
    local c
    SETPRIV=''
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
    mv -f "$tmp" "$dest"
}

write_if_changed() {
    local dest="$1" mode="$2" tmp
    mkdir -p "$(dirname "$dest")" || return 1
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
    fi
    chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    UNIT_CHANGED=1
}

save_config() {
    local temp
    mkdir -p "$BASE_DIR" || return 1
    temp=$(mktemp "$BASE_DIR/config.XXXXXX") || return 1
    if ! printf 'ANYTLS_PORT=%s\nANYTLS_TLS_MODE=%s\nANYTLS_DOMAIN=%s\nANYTLS_EMAIL=%s\nANYTLS_BACKEND_PORT=%s\nANYTLS_PASSWORD=%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" > "$temp"; then
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
    mkdir -p "$BASE_DIR" || return 1
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

valid_port() {
    local value="${1:-}"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$value >= 1 && 10#$value <= 65535 )) || return 1
    printf '%s' "$((10#$value))"
}

valid_domain() {
    local value="${1:-}" label
    local -a labels
    [ -n "$value" ] || return 1
    ((${#value} <= 253)) || return 1
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 1
    [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
    [[ "$value" != *:* && "$value" != */* && "$value" != *' '* ]] || return 1
    local IFS=.
    read -r -a labels <<< "$value"
    ((${#labels[@]} >= 2)) || return 1
    for label in "${labels[@]}"; do
        ((${#label} <= 63)) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

valid_email() {
    [ -z "${1:-}" ] || [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]]
}

backend_port_for() {
    local port="$1" next
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    next=$((port + 1))
    # 80 留给 ACME HTTP-01，65536 不是合法端口。
    if (( next > 65535 || next == 80 || port == 80 )); then
        return 1
    fi
    printf '%s' "$next"
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

# Upstream publishes no signature. These pins are the trust anchor; the GitHub
# API digest is only a cross-check. Add a line before accepting a new release.
pinned_digest() {
    case "$1:$2" in
        v0.0.13:amd64) printf '%s' '7e80fc099ea54a71110d256dd60648c47c63c70a3c499eb1f6d7aaa4edb7016f' ;;
        v0.0.13:arm64) printf '%s' '88cb762c3c8eb56b46a2d8d6feab9c0858655192143fc164874229499246a956' ;;
        *) return 1 ;;
    esac
}

allowed_release_url() {
    local url="$1" arch
    arch=$(asset_arch) || return 1
    [ "$url" = "https://github.com/${REPO}/releases/download/${RELEASE_TAG}/anytls_${RELEASE_TAG#v}_linux_${arch}.zip" ]
}

release_info() {
    local api arch asset digest
    arch=$(asset_arch) || return 1
    api=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: anytls.sh' \
        "https://api.github.com/repos/$REPO/releases/latest") || {
        error '无法获取 AnyTLS 最新 Release。'
        return 1
    }
    RELEASE_TAG=$(printf '%s' "$api" | jq -r '.tag_name // empty')
    valid_tag "$RELEASE_TAG" || { error 'Release 版本格式无效。'; return 1; }
    asset="anytls_${RELEASE_TAG#v}_linux_${arch}.zip"
    RELEASE_URL=$(printf '%s' "$api" | jq -r --arg name "$asset" \
        '.assets[]? | select(.name == $name) | .browser_download_url')
    digest=$(printf '%s' "$api" | jq -r --arg name "$asset" \
        '.assets[]? | select(.name == $name) | .digest')
    RELEASE_DIGEST=${digest#sha256:}
    RELEASE_DIGEST=${RELEASE_DIGEST,,}
    pin=$(pinned_digest "$RELEASE_TAG" "$arch") || {
        error "脚本没有 ${RELEASE_TAG}（${arch}）的固定摘要。上游没有签名，不能只信 GitHub API 的同站摘要。"
        return 1
    }
    allowed_release_url "$RELEASE_URL" || {
        error '官方下载地址不在允许的 GitHub Release 路径内。'
        return 1
    }
    if [ -n "$RELEASE_DIGEST" ] && [[ ! "$RELEASE_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
        error "官方摘要格式无效。"
        return 1
    fi
    if [ -n "$RELEASE_DIGEST" ] && [ "$RELEASE_DIGEST" != "$pin" ]; then
        error 'GitHub API 摘要与脚本内固定摘要不一致，已拒绝。'
        return 1
    fi
    RELEASE_DIGEST=$pin
}

fetch_release() {
    local archive actual help
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/anytls.XXXXXX") || return 1
    archive="$TMP_DIR/anytls.zip"
    printf '下载 %s（%s）...\n' "$RELEASE_TAG" "${RELEASE_URL##*/}"
    curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
        -H 'User-Agent: anytls.sh' -o "$archive" "$RELEASE_URL" || {
        error '下载失败。'
        return 1
    }
    actual=$(sha256sum "$archive") || return 1
    actual=${actual%% *}
    actual=${actual,,}
    [ "$actual" = "$RELEASE_DIGEST" ] || {
        error '安装包 SHA256 校验失败。'
        return 1
    }
    unzip -p "$archive" anytls-server > "$TMP_DIR/anytls-server" || {
        error '安装包解压失败。'
        return 1
    }
    if [ -L "$TMP_DIR/anytls-server" ] || [ ! -f "$TMP_DIR/anytls-server" ]; then
        error '安装包内容异常。'
        return 1
    fi
    chmod 755 "$TMP_DIR/anytls-server" || return 1
    if ! help=$("$TMP_DIR/anytls-server" -h 2>&1); then
        error '下载的程序无法执行。'
        return 1
    fi
    printf '%s\n' "$help" | grep -q -- '-p string' || {
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
    [ -r "$VERSION_FILE" ] && tr -d '[:space:]' < "$VERSION_FILE"
}

version_newer() {
    local latest="${1#v}" current="${2#v}" i av bv
    local -a a b
    [[ "$latest" =~ ^[0-9]+(\.[0-9]+){2}$ ]] || return 1
    [[ "$current" =~ ^[0-9]+(\.[0-9]+){2}$ ]] || return 0
    IFS=. read -r -a a <<< "$latest"
    IFS=. read -r -a b <<< "$current"
    for i in 0 1 2; do
        av=${a[$i]:-0}
        bv=${b[$i]:-0}
        if (( av > bv )); then return 0; fi
        if (( av < bv )); then return 1; fi
    done
    return 1
}

choose_config() {
    local old_port old_mode old_domain old_email old_password value
    local default_password default_mode normalized
    old_port=$(cfg port)
    old_mode=$(cfg tls_mode)
    old_domain=$(cfg domain)
    old_email=$(cfg email)
    old_password=$(cfg password)
    normalized=$(valid_port "${old_port:-}") && old_port=$normalized
    if [ -z "$old_mode" ]; then
        [ -n "$old_domain" ] && old_mode='acme' || old_mode='self_signed'
    fi
    [ "$old_mode" = acme ] && default_mode=2 || default_mode=1

    while :; do
        read -r -p "端口 [${old_port:-$DEFAULT_PORT}]: " value || return 1
        value=${value:-${old_port:-$DEFAULT_PORT}}
        if normalized=$(valid_port "$value"); then
            SET_PORT="$normalized"
            break
        fi
        printf '端口无效（1-65535）。\n'
    done

    while :; do
        printf '证书方式\n'
        printf '[1] 自签名（官方自动生成）\n'
        printf '[2] ACME（Let\x27s Encrypt）\n'
        read -r -p "选择 [1/2] [$default_mode]: " value || return 1
        value=${value:-$default_mode}
        case "$value" in
            1) SET_TLS_MODE='self_signed'; break ;;
            2) SET_TLS_MODE='acme'; break ;;
            *) printf '无效选项，请选择 1 或 2。\n' ;;
        esac
    done

    SET_DOMAIN=''
    SET_EMAIL=''
    SET_BACKEND_PORT=''
    if [ "$SET_TLS_MODE" = acme ]; then
        if ! SET_BACKEND_PORT=$(backend_port_for "$SET_PORT"); then
            error 'ACME 模式不能使用 79、80 或 65535。80 要留给证书验证，79 的后端会占用 80。'
            return 1
        fi
        while :; do
            if [ -n "$old_domain" ]; then
                read -r -p "域名 [$old_domain]（回车保持）: " value || return 1
                value=${value:-$old_domain}
            else
                read -r -p '域名（必须已解析到本机）: ' value || return 1
            fi
            if valid_domain "$value"; then
                SET_DOMAIN="$value"
                break
            fi
            printf '域名无效。请输入域名，不要填写 IP。\n'
        done

        while :; do
            if [ -n "$old_email" ]; then
                read -r -p "ACME 邮箱 [$old_email]（回车保持，- 清除）: " value || return 1
                if [ "$value" = '-' ]; then
                    value=''
                elif [ -z "$value" ]; then
                    value="$old_email"
                fi
            else
                read -r -p 'ACME 邮箱（可选，回车跳过）: ' value || return 1
            fi
            if valid_email "$value"; then
                SET_EMAIL="$value"
                break
            fi
            printf '邮箱格式无效。\n'
        done
    fi

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

ensure_haproxy() {
    HAPROXY_BIN=$(command -v haproxy || true)
    [ -x "$HAPROXY_BIN" ] || error '缺少 haproxy，无法使用 ACME 证书。'
}

build_haproxy_pem() {
    local temp group
    if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
        error 'ACME 证书文件不存在。'
        return 1
    fi
    ensure_service_account || return 1
    group=$(service_group)
    mkdir -p "$CERT_DIR" || return 1
    temp=$(mktemp "$CERT_DIR/haproxy.pem.XXXXXX") || return 1
    if ! cat "$CERT_FILE" "$KEY_FILE" > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    chown "$SVC_USER:$group" "$temp" || { rm -f "$temp"; return 1; }
    chmod 600 "$temp" || { rm -f "$temp"; return 1; }
    mv -f "$temp" "$HAPROXY_PEM"
}

write_proxy_config() {
    local port backend temp limit group
    ensure_haproxy || return 1
    ensure_service_account || return 1
    group=$(service_group)
    port=$(cfg port)
    backend=$(cfg backend_port)
    port=$(valid_port "$port") || { error 'AnyTLS 端口配置不完整。'; return 1; }
    [[ "$backend" =~ ^[0-9]+$ ]] || { error 'AnyTLS 端口配置不完整。'; return 1; }
    limit=$(nofile_limit)
    temp=$(mktemp "$BASE_DIR/haproxy.cfg.XXXXXX") || return 1
    if ! cat > "$temp" <<EOF
global
    maxconn $limit

defaults
    mode tcp
    timeout connect 10s
    timeout client 1h
    timeout server 1h

frontend anytls_front
    bind :::${port} v4v6 ssl crt $HAPROXY_PEM
    default_backend anytls_backend

backend anytls_backend
    mode tcp
    server anytls 127.0.0.1:$backend ssl verify none
EOF
    then
        rm -f "$temp"
        return 1
    fi
    chown "root:$group" "$temp" || { rm -f "$temp"; return 1; }
    chmod 640 "$temp" || { rm -f "$temp"; return 1; }
    if ! mv -f "$temp" "$HAPROXY_CFG"; then
        rm -f "$temp"
        return 1
    fi
    "$HAPROXY_BIN" -c -q -f "$HAPROXY_CFG" || {
        error 'HAProxy 配置校验失败。'
        return 1
    }
}

write_reload_script() {
    local temp group port
    ensure_haproxy || return 1
    ensure_service_account || return 1
    group=$(service_group)
    port=$(cfg port)
    port=$(valid_port "$port") || { error 'AnyTLS 端口配置不完整。'; return 1; }
    temp=$(mktemp "$BASE_DIR/reload-cert.XXXXXX") || return 1
    if ! cat > "$temp" <<EOF
#!/usr/bin/env bash
set -u
cert='$CERT_FILE'
key='$KEY_FILE'
pem='$HAPROXY_PEM'
cfg='$HAPROXY_CFG'
proxy_bin='$HAPROXY_BIN'
proxy_app='$PROXY_APP'
proxy_pid_file='$PROXY_PID_FILE'
proxy_log='$PROXY_LOG_FILE'
svc_user='$SVC_USER'
svc_group='$group'
public_port='$port'
runtime_backend='$(backend)'

[ -s "\$cert" ] && [ -s "\$key" ] || exit 1
next=\$(mktemp "\${pem}.XXXXXX") || exit 1
if ! cat "\$cert" "\$key" > "\$next"; then
    rm -f "\$next"
    exit 1
fi
chown "\$svc_user:\$svc_group" "\$next" || { rm -f "\$next"; exit 1; }
chmod 600 "\$next" || { rm -f "\$next"; exit 1; }
mv -f "\$next" "\$pem" || { rm -f "\$next"; exit 1; }

if [ "\$runtime_backend" = systemd ]; then
    systemctl is-active --quiet "\$proxy_app" 2>/dev/null || exit 0
    systemctl restart "\$proxy_app"
    exit \$?
fi
if [ "\$runtime_backend" = openrc ]; then
    rc-service "\$proxy_app" status >/dev/null 2>&1 || exit 0
    rc-service "\$proxy_app" restart
    exit \$?
fi

old_pid=''
was_running=0
if [ -s "\$proxy_pid_file" ]; then
    old_pid=\$(cat "\$proxy_pid_file" 2>/dev/null || true)
    case "\$old_pid" in ''|*[!0-9]*) old_pid='' ;; esac
fi
if [ -n "\$old_pid" ] && kill -0 "\$old_pid" 2>/dev/null; then
    was_running=1
    kill "\$old_pid" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        kill -0 "\$old_pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "\$old_pid" 2>/dev/null; then
        kill -KILL "\$old_pid" >/dev/null 2>&1 || true
        sleep 1
    fi
    if kill -0 "\$old_pid" 2>/dev/null; then
        exit 1
    fi
fi
[ "\$was_running" = 1 ] || exit 0

setter=''
for c in /usr/bin/setpriv /usr/sbin/setpriv /bin/setpriv; do
    [ -x "\$c" ] || continue
    "\$c" --help 2>&1 | grep -q -- '--reuid' || continue
    setter=\$c
    break
done
[ -n "\$setter" ] || exit 1
if [ "\$public_port" -lt 1024 ]; then
    nohup "\$setter" --reuid="\$svc_user" --regid="\$svc_group" --init-groups \\
        --inh-caps=-all,+net_bind_service --ambient-caps=-all,+net_bind_service \\
        -- "\$proxy_bin" -db -f "\$cfg" >>"\$proxy_log" 2>&1 &
else
    nohup "\$setter" --reuid="\$svc_user" --regid="\$svc_group" --init-groups \\
        --inh-caps=-all --ambient-caps=-all \\
        -- "\$proxy_bin" -db -f "\$cfg" >>"\$proxy_log" 2>&1 &
fi
disown "\$!" 2>/dev/null || true
printf '%s\\n' "\$!" > "\$proxy_pid_file"
sleep 1
kill -0 "\$!" 2>/dev/null
EOF
    then
        rm -f "$temp"
        return 1
    fi
    chmod 700 "$temp" || { rm -f "$temp"; return 1; }
    mv -f "$temp" "$RELOAD_SCRIPT"
}

install_acme_schedule() {
    local temp
    case "$(backend)" in
        systemd)
            UNIT_CHANGED=0
            write_if_changed "$ACME_SYSTEMD_UNIT" 644 <<EOF
[Unit]
Description=AnyTLS ACME renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ACME_BIN --cron --home $ACME_HOME
EOF
            write_if_changed "$ACME_TIMER_UNIT" 644 <<EOF
[Unit]
Description=Run AnyTLS ACME renewal daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
EOF
            systemctl daemon-reload || return 1
            systemctl enable --now "$(basename "$ACME_TIMER_UNIT")" >/dev/null 2>&1 || {
                error 'ACME systemd 定时器启动失败。'
                return 1
            }
            ;;
        openrc|direct)
            if [ -x "$ACME_BIN" ] && (has crontab || has fcrontab); then
                "$ACME_BIN" --home "$ACME_HOME" --uninstall-cronjob >/dev/null 2>&1 || true
            fi
            if [ -d /etc/cron.d ]; then
                if ! has cron && ! has crond; then
                    error '未找到 cron/crond，无法配置 ACME 自动续期。'
                    return 1
                fi
                temp=$(mktemp /etc/cron.d/anytls-acme.XXXXXX) || return 1
                if ! printf '%s\n17 3 * * * root %s --cron --home %s >/dev/null 2>&1\n' \
                    "$ACME_CRON_MARKER" "$ACME_BIN" "$ACME_HOME" > "$temp"; then
                    rm -f "$temp"
                    return 1
                fi
                if ! chmod 644 "$temp" || ! mv "$temp" "$ACME_CRON_FILE"; then
                    rm -f "$temp"
                    return 1
                fi
            elif has crontab || has fcrontab; then
                "$ACME_BIN" --home "$ACME_HOME" --install-cronjob >/dev/null 2>&1 || {
                    error 'ACME crontab 安装失败。'
                    return 1
                }
            else
                error '未找到 cron/crontab，无法配置 ACME 自动续期。'
                return 1
            fi
            ;;
    esac
}

remove_acme_schedule() {
    case "$(backend)" in
        systemd)
            systemctl disable --now "$(basename "$ACME_TIMER_UNIT")" >/dev/null 2>&1 || true
            rm -f "$ACME_SYSTEMD_UNIT" "$ACME_TIMER_UNIT"
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        openrc|direct)
            rm -f "$ACME_CRON_FILE"
            if [ -x "$ACME_BIN" ] && (has crontab || has fcrontab); then
                "$ACME_BIN" --home "$ACME_HOME" --uninstall-cronjob >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

install_acme_client() {
    local temp actual
    mkdir -p "$ACME_HOME" || return 1
    chmod 700 "$ACME_HOME" || return 1
    actual=''
    if [ -x "$ACME_BIN" ]; then
        actual=$(sha256sum "$ACME_BIN" 2>/dev/null) || actual=''
        actual=${actual%% *}
    fi
    if [ "$actual" != "$ACME_SHA256" ]; then
        temp=$(mktemp "$ACME_HOME/acme.sh.XXXXXX") || return 1
        curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 90 \
            -H 'User-Agent: anytls.sh' \
            -o "$temp" "$ACME_URL" || {
            rm -f "$temp"
            error "下载 acme.sh $ACME_VERSION 失败。"
            return 1
        }
        actual=$(sha256sum "$temp" 2>/dev/null) || actual=''
        actual=${actual%% *}
        if [ "$actual" != "$ACME_SHA256" ]; then
            rm -f "$temp"
            error 'acme.sh SHA256 校验失败。'
            return 1
        fi
        if ! chmod 700 "$temp" || ! mv "$temp" "$ACME_BIN"; then
            rm -f "$temp"
            return 1
        fi
    fi
    "$ACME_BIN" --home "$ACME_HOME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || {
        error "设置 Let's Encrypt CA 失败。"
        return 1
    }
}

issue_certificate() {
    local domain="$1" email="$2"
    local -a register_args issue_args install_args
    ensure_haproxy || return 1
    ensure_service_account || return 1
    install_acme_client || return 1
    write_reload_script || return 1
    printf '申请 %s 的 Let\x27s Encrypt 证书...\n' "$domain"

    register_args=(--home "$ACME_HOME" --server letsencrypt --register-account)
    [ -z "$email" ] || register_args+=(-m "$email")
    "$ACME_BIN" "${register_args[@]}" || {
        error 'ACME 账户注册失败。'
        return 1
    }

    issue_args=(--home "$ACME_HOME" --server letsencrypt --issue --standalone --httpport 80 -d "$domain")
    "$ACME_BIN" "${issue_args[@]}" || {
        error '证书申请失败，请确认域名已解析到本机且 TCP 80 端口可访问。'
        return 1
    }

    install_args=(--home "$ACME_HOME" --install-cert -d "$domain" \
        --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" \
        --reloadcmd "$RELOAD_SCRIPT")
    "$ACME_BIN" "${install_args[@]}" || {
        error '证书安装失败。'
        return 1
    }
    build_haproxy_pem || return 1
}

tls_mode() {
    local mode
    mode=$(cfg tls_mode)
    case "$mode" in
        acme) printf 'acme' ;;
        self_signed) printf 'self_signed' ;;
        *)
            [ -n "$(cfg domain)" ] && printf 'acme' || printf 'self_signed'
            ;;
    esac
}

service_uses_proxy() {
    [ "$(tls_mode)" = acme ]
}

listen_port() {
    local port
    if service_uses_proxy; then
        port=$(cfg backend_port)
    else
        port=$(cfg port)
    fi
    valid_port "$port"
}

priv_unit_lines() {
    local port="$1"
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
}

stop_direct_pid() {
    local pid_file="$1" checker="$2" pid _
    if ! pid=$($checker); then
        rm -f "$pid_file"
        return 0
    fi
    kill "$pid" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        "$checker" >/dev/null || break
        sleep 1
    done
    if "$checker" >/dev/null; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
        sleep 1
    fi
    if "$checker" >/dev/null; then
        return 1
    fi
    rm -f "$pid_file"
}

stop_if_active() {
    local kind="$1" name="$2"
    case "$kind" in
        systemd)
            systemctl stop "$name" >/dev/null 2>&1 || true
            if systemctl is-active --quiet "$name" 2>/dev/null; then
                return 1
            fi
            ;;
        openrc)
            rc-service "$name" stop >/dev/null 2>&1 || true
            if rc-service "$name" status >/dev/null 2>&1; then
                return 1
            fi
            ;;
    esac
}

running_as_root() {
    local pid uid
    pid=$($1) || return 1
    uid=$(proc_uid "$pid")
    [ "$uid" = 0 ]
}

start_direct_one() {
    local kind="$1" port listen password pid
    secure_tree || return 1
    case "$kind" in
        server)
            if server_pid >/dev/null && ! running_as_root server_pid; then
                return 0
            fi
            running_as_root server_pid && { stop_direct_pid "$PID_FILE" server_pid || return 1; }
            port=$(listen_port) || return 1
            password=$(cfg password)
            [ -n "$password" ] || return 1
            if service_uses_proxy; then
                listen="127.0.0.1:$port"
            else
                listen=":$port"
            fi
            build_priv_cmd "$port" "$BIN" -l "$listen" -p "$password" || return 1
            rm -f "$PID_FILE"
            mkdir -p "${PID_FILE%/*}" || return 1
            nohup "${DROP_CMD[@]}" >>"$LOG_FILE" 2>&1 &
            pid=$!
            disown "$pid" 2>/dev/null || true
            printf '%s\n' "$pid" > "$PID_FILE"
            sleep 1
            server_pid >/dev/null || return 1
            conceal_server "$pid" || {
                stop_direct_pid "$PID_FILE" server_pid || true
                return 1
            }
            ;;
        proxy)
            service_uses_proxy || return 0
            if proxy_pid >/dev/null && ! running_as_root proxy_pid; then
                return 0
            fi
            running_as_root proxy_pid && { stop_direct_pid "$PROXY_PID_FILE" proxy_pid || return 1; }
            ensure_haproxy || return 1
            port=$(cfg port)
            port=$(valid_port "$port") || return 1
            build_priv_cmd "$port" "$HAPROXY_BIN" -db -f "$HAPROXY_CFG" || return 1
            rm -f "$PROXY_PID_FILE"
            mkdir -p "${PROXY_PID_FILE%/*}" || return 1
            nohup "${DROP_CMD[@]}" >>"$PROXY_LOG_FILE" 2>&1 &
            pid=$!
            disown "$pid" 2>/dev/null || true
            printf '%s\n' "$pid" > "$PROXY_PID_FILE"
            sleep 1
            proxy_pid >/dev/null
            ;;
    esac
}

service_pid() {
    local pid=''
    case "$(backend)" in
        systemd)
            pid=$(systemctl show -p MainPID --value "$APP" 2>/dev/null || true)
            ;;
        *)
            pid=$(server_pid 2>/dev/null || true)
            ;;
    esac
    case "$pid" in
        ''|*[!0-9]*|0) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s' "$pid"
}

install_scrub_script() {
    local tmp
    mkdir -p "$BASE_DIR" || return 1
    tmp=$(mktemp "$BASE_DIR/scrub-argv.XXXXXX") || return 1
    cat > "$tmp" << 'SCRUB_EOF'
#!/usr/bin/env bash
# Clear the AnyTLS password from another process's argv after it has started.
# The official binary only accepts -p. Other local users can read /proc/pid/cmdline,
# but not another user's process memory. Overwriting the argv bytes hides the secret
# from ps. The server hashes the password before it listens, so this runs only after that.
set -u
pid=${1:-}
config=${ANYTLS_SCRUB_CONFIG:-/etc/anytls/config}
[ -n "$pid" ] && [ -d "/proc/$pid" ] || exit 1
password=$(sed -n 's/^ANYTLS_PASSWORD=//p' "$config" | head -n 1)
[ -n "$password" ] || exit 1

password_visible() {
    local arg=''
    while IFS= read -r -d '' arg || [ -n "$arg" ]; do
        [ "$arg" = "$password" ] && return 0
    done < "/proc/$pid/cmdline"
    return 1
}

if ! password_visible; then
    exit 0
fi

if [ "${ANYTLS_SCRUB_NO_WAIT:-0}" != 1 ]; then
    mode=$(sed -n 's/^ANYTLS_TLS_MODE=//p' "$config" | head -n 1)
    if [ "$mode" = acme ]; then
        port=$(sed -n 's/^ANYTLS_BACKEND_PORT=//p' "$config" | head -n 1)
    else
        port=$(sed -n 's/^ANYTLS_PORT=//p' "$config" | head -n 1)
    fi
    hex=''
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        hex=$(printf '%04X' "$port")
    fi
    _i=0
    while [ "$_i" -lt 20 ]; do
        [ -d "/proc/$pid" ] || exit 1
        if tr '\0' '\n' < "/proc/$pid/cmdline" | grep -q 'anytls-server'; then
            if [ -n "$hex" ] && grep -qi ":${hex} " /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
                break
            fi
        fi
        _i=$((_i + 1))
        sleep 0.25
    done
    [ -d "/proc/$pid" ] || exit 1
fi

if ! password_visible; then
    exit 0
fi

arg_offset() {
    local arg='' offset=0
    while IFS= read -r -d '' arg || [ -n "$arg" ]; do
        if [ "$arg" = "$password" ]; then
            printf '%s' "$offset"
            return 0
        fi
        offset=$((offset + ${#arg} + 1))
    done < "/proc/$pid/cmdline"
    return 1
}

write_at() {
    local addr=$1 xs
    xs=$(printf '%*s' "${#password}" '' | tr ' ' 'x')
    printf '%s' "$xs" | dd of="/proc/$pid/mem" bs=1 seek="$addr" conv=notrunc status=none 2>/dev/null
}

cleared() {
    write_at "$1" || return 1
    ! password_visible
}

offset=$(arg_offset) || exit 1
rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null || true)
arg_start=$(printf '%s\n' "$rest" | awk 'NF >= 46 { print $46; exit }')
if [[ "${arg_start:-}" =~ ^[0-9]+$ ]]; then
    cleared $((arg_start + offset)) && exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    exit 1
fi
ANYTLS_SCRUB_PID=$pid ANYTLS_SCRUB_PASSWORD=$password python3 - << 'PY'
import os, sys
pid = os.environ["ANYTLS_SCRUB_PID"]
secret = os.environ["ANYTLS_SCRUB_PASSWORD"].encode()
blob = open(f"/proc/{pid}/cmdline", "rb").read()
idx = blob.find(b"\0" + secret + b"\0")
if idx < 0:
    sys.exit(0 if secret not in blob else 1)
idx += 1
fd = os.open(f"/proc/{pid}/mem", os.O_RDWR)
try:
    for line in open(f"/proc/{pid}/maps"):
        if "[stack]" not in line:
            continue
        start_s, end_s = line.split()[0].split("-")
        start, end = int(start_s, 16), int(end_s, 16)
        os.lseek(fd, start, os.SEEK_SET)
        data = os.read(fd, end - start)
        at = data.find(blob)
        if at < 0:
            at = data.find(b"\0" + secret + b"\0")
            if at < 0:
                sys.exit(1)
            at += 1
        else:
            at += idx
        os.lseek(fd, start + at, os.SEEK_SET)
        os.write(fd, b"x" * len(secret))
        sys.exit(0)
    sys.exit(1)
finally:
    os.close(fd)
PY
password_visible && exit 1
exit 0
SCRUB_EOF
    chmod 700 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$SCRUB_SCRIPT" || { rm -f "$tmp"; return 1; }
}

conceal_server() {
    local pid="${1:-}"
    if [ -z "$pid" ]; then
        pid=$(service_pid) || return 0
    fi
    install_scrub_script || return 1
    if ! "$SCRUB_SCRIPT" "$pid"; then
        error '无法从进程参数中清除密码。'
        return 1
    fi
}

unit_needs_drop() {
    case "$(backend)" in
        systemd)
            [ -f "$SYSTEMD_UNIT" ] || return 0
            grep -q "^User=$SVC_USER$" "$SYSTEMD_UNIT" || return 0
            if service_uses_proxy; then
                [ -f "$PROXY_SYSTEMD_UNIT" ] || return 0
                grep -q "^User=$SVC_USER$" "$PROXY_SYSTEMD_UNIT" || return 0
            fi
            return 1
            ;;
        openrc)
            [ -f "$OPENRC_UNIT" ] || return 0
            grep -q "command_user=\"$SVC_USER:" "$OPENRC_UNIT" || return 0
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

migrate_privileges() {
    local pid='' uid=''
    NOTICE=''
    [ -x "$BIN" ] && [ -r "$ENV_FILE" ] || return 0
    if service_pid >/dev/null && { unit_needs_drop || [ "$(proc_uid "$(service_pid)")" = 0 ]; }; then
        if restart_app; then
            NOTICE="已将正在运行的服务切换到 ${SVC_USER} 用户。"
        else
            NOTICE='自动降权失败。请选择“重启”。'
            return 1
        fi
    elif unit_needs_drop; then
        if svc install; then
            NOTICE="已更新服务配置，下次启动会使用 ${SVC_USER} 用户。"
        else
            NOTICE='服务配置更新失败。'
            return 1
        fi
    fi
    if pid=$(service_pid); then
        conceal_server "$pid" || NOTICE='无法从进程参数中清除密码。'
    fi
}

svc() {
    local action="$1" b port backend_port limit group app_priv proxy_priv pid=''
    b=$(backend) || return 1
    if [ "$action" = install ]; then
        install_scrub_script || return 1
    fi
    case "$action/$b" in
        status/systemd)
            if service_uses_proxy; then
                systemctl is-active --quiet "$APP" && systemctl is-active --quiet "$PROXY_APP"
            else
                systemctl is-active --quiet "$APP"
            fi
            ;;
        status/openrc)
            if service_uses_proxy; then
                rc-service "$APP" status >/dev/null 2>&1 && rc-service "$PROXY_APP" status >/dev/null 2>&1
            else
                rc-service "$APP" status >/dev/null 2>&1
            fi
            ;;
        status/direct)
            if service_uses_proxy; then
                server_pid >/dev/null && proxy_pid >/dev/null
            else
                server_pid >/dev/null
            fi
            ;;

        install/systemd)
            secure_tree || return 1
            port=$(listen_port) || return 1
            limit=$(nofile_limit)
            group=$(service_group)
            app_priv=$(priv_unit_lines "$port")
            if service_uses_proxy; then
                backend_port=$(cfg port)
                backend_port=$(valid_port "$backend_port") || return 1
                proxy_priv=$(priv_unit_lines "$backend_port")
            fi
            UNIT_CHANGED=0
            write_if_changed "$SYSTEMD_UNIT" 644 <<EOF
[Unit]
Description=AnyTLS Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
# Managed by anytls.sh. Local overrides: /etc/systemd/system/${APP}.service.d/

[Service]
Type=simple
User=$SVC_USER
Group=$group
EnvironmentFile=$ENV_FILE
ExecStart=$BIN -l $(service_uses_proxy && printf '127.0.0.1:${ANYTLS_BACKEND_PORT}' || printf ':${ANYTLS_PORT}') -p \${ANYTLS_PASSWORD}
ExecStartPost=+/bin/sh -c '$SCRUB_SCRIPT "\$MAINPID" || true'
Restart=on-failure
RestartSec=3
LimitNOFILE=$limit
UMask=0077
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
$app_priv

[Install]
WantedBy=multi-user.target
EOF
            if service_uses_proxy; then
                write_if_changed "$PROXY_SYSTEMD_UNIT" 644 <<EOF
[Unit]
Description=AnyTLS TLS Frontend
Requires=$APP.service
After=$APP.service
StartLimitIntervalSec=60
StartLimitBurst=5
# Managed by anytls.sh. Local overrides: /etc/systemd/system/${PROXY_APP}.service.d/

[Service]
Type=simple
User=$SVC_USER
Group=$group
ExecStart=$HAPROXY_BIN -db -f $HAPROXY_CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=$limit
UMask=0077
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
$proxy_priv

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload || return 1
                systemctl enable "$APP" "$PROXY_APP" >/dev/null 2>&1 || return 1
            else
                systemctl disable --now "$PROXY_APP" >/dev/null 2>&1 || true
                rm -f "$PROXY_SYSTEMD_UNIT"
                systemctl daemon-reload || return 1
                systemctl enable "$APP" >/dev/null 2>&1 || return 1
            fi
            ;;
        install/openrc)
            secure_tree || return 1
            port=$(listen_port) || return 1
            group=$(service_group)
            if (( port < 1024 )); then
                app_priv=$'capabilities="net_bind_service"'
            else
                app_priv='no_new_privs=true'
            fi
            UNIT_CHANGED=1
            cat > "$OPENRC_UNIT" <<EOF
#!/sbin/openrc-run
# Managed by anytls.sh.
. "$ENV_FILE"
name="AnyTLS"
command="$BIN"
command_args="-l $(service_uses_proxy && printf '127.0.0.1:${ANYTLS_BACKEND_PORT}' || printf ':${ANYTLS_PORT}') -p \${ANYTLS_PASSWORD}"
command_user="$SVC_USER:$group"
supervisor="supervise-daemon"
supervise_daemon_args="--stdout $LOG_FILE --stderr $LOG_FILE"
pidfile="$PID_FILE"
$app_priv

start_post() {
    if [ -s "\$pidfile" ]; then
        $SCRUB_SCRIPT "\$(cat "\$pidfile")" || true
    fi
}

depend() {
    need net
}
EOF
            chmod 755 "$OPENRC_UNIT" || return 1
            rc-update add "$APP" default >/dev/null 2>&1 || return 1
            if service_uses_proxy; then
                backend_port=$(cfg port)
                backend_port=$(valid_port "$backend_port") || return 1
                if (( backend_port < 1024 )); then
                    proxy_priv=$'capabilities="net_bind_service"'
                else
                    proxy_priv='no_new_privs=true'
                fi
                cat > "$PROXY_OPENRC_UNIT" <<EOF
#!/sbin/openrc-run
# Managed by anytls.sh.
name="AnyTLS TLS Frontend"
command="$HAPROXY_BIN"
command_args="-db -f $HAPROXY_CFG"
command_user="$SVC_USER:$group"
supervisor="supervise-daemon"
supervise_daemon_args="--stdout $PROXY_LOG_FILE --stderr $PROXY_LOG_FILE"
pidfile="$PROXY_PID_FILE"
$proxy_priv

depend() {
    need net
    need $APP
}
EOF
                chmod 755 "$PROXY_OPENRC_UNIT" || return 1
                rc-update add "$PROXY_APP" default >/dev/null 2>&1 || return 1
            else
                rc-service "$PROXY_APP" stop >/dev/null 2>&1 || true
                rc-update del "$PROXY_APP" default >/dev/null 2>&1 || true
                rm -f "$PROXY_OPENRC_UNIT"
            fi
            ;;
        install/direct)
            secure_tree || return 1
            if service_uses_proxy; then
                ensure_haproxy || return 1
            fi
            ;;

        start/systemd)
            systemctl reset-failed "$APP" "$PROXY_APP" >/dev/null 2>&1 || true
            if [ "${UNIT_CHANGED:-0}" = 1 ]; then
                stop_if_active systemd "$PROXY_APP" || return 1
                stop_if_active systemd "$APP" || return 1
            fi
            systemctl start "$APP" || return 1
            pid=$(systemctl show -p MainPID --value "$APP" 2>/dev/null || true)
            conceal_server "$pid" || {
                systemctl stop "$APP" >/dev/null 2>&1 || true
                return 1
            }
            if service_uses_proxy; then
                systemctl start "$PROXY_APP" || return 1
            else
                systemctl stop "$PROXY_APP" >/dev/null 2>&1 || true
            fi
            svc status
            ;;
        start/openrc)
            if [ "${UNIT_CHANGED:-0}" = 1 ]; then
                stop_if_active openrc "$PROXY_APP" || return 1
                stop_if_active openrc "$APP" || return 1
            fi
            rc-service "$APP" start || return 1
            conceal_server || {
                rc-service "$APP" stop >/dev/null 2>&1 || true
                return 1
            }
            if service_uses_proxy; then
                rc-service "$PROXY_APP" start || return 1
            else
                rc-service "$PROXY_APP" stop >/dev/null 2>&1 || true
            fi
            svc status
            ;;
        start/direct)
            start_direct_one server || return 1
            if service_uses_proxy; then
                start_direct_one proxy || return 1
            else
                stop_direct_pid "$PROXY_PID_FILE" proxy_pid || return 1
            fi
            svc status
            ;;

        stop/systemd)
            stop_if_active systemd "$PROXY_APP" || return 1
            stop_if_active systemd "$APP" || return 1
            ;;
        stop/openrc)
            stop_if_active openrc "$PROXY_APP" || return 1
            stop_if_active openrc "$APP" || return 1
            ;;
        stop/direct)
            stop_direct_pid "$PROXY_PID_FILE" proxy_pid || return 1
            stop_direct_pid "$PID_FILE" server_pid || return 1
            ;;

        remove/systemd)
            svc stop || return 1
            systemctl disable "$PROXY_APP" "$APP" >/dev/null 2>&1 || true
            rm -f "$PROXY_SYSTEMD_UNIT" "$SYSTEMD_UNIT"
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            ;;
        remove/openrc)
            svc stop || return 1
            rc-update del "$PROXY_APP" default >/dev/null 2>&1 || true
            rc-update del "$APP" default >/dev/null 2>&1 || true
            rm -f "$PROXY_OPENRC_UNIT" "$OPENRC_UNIT"
            ;;
        remove/direct) svc stop ;;
    esac
}

copy_if_exists() {
    local src="$1" dest="$2"
    if [ -e "$src" ]; then
        cp -a "$src" "$dest" || return 1
    fi
}

begin_rollback() {
    local dir
    RB_HAD_CONFIG=0
    RB_HAD_BIN=0
    RB_WAS_RUNNING=0
    RB_ACTIVE=0
    mkdir -p "$BASE_DIR" || return 1
    dir=$(mktemp -d "$BASE_DIR/rollback.XXXXXX") || return 1
    chmod 700 "$dir" || { rm -rf "$dir"; return 1; }
    if [ -f "$ENV_FILE" ]; then
        cp -a "$ENV_FILE" "$dir/config" || { rm -rf "$dir"; return 1; }
        RB_HAD_CONFIG=1
    fi
    if [ -e "$BIN" ]; then
        cp -a "$BIN" "$dir/anytls-server" || { rm -rf "$dir"; return 1; }
        RB_HAD_BIN=1
    fi
    copy_if_exists "$VERSION_FILE" "$dir/version" || { rm -rf "$dir"; return 1; }
    copy_if_exists "$CERT_DIR" "$dir/certs" || { rm -rf "$dir"; return 1; }
    copy_if_exists "$HAPROXY_CFG" "$dir/haproxy.cfg" || { rm -rf "$dir"; return 1; }
    copy_if_exists "$RELOAD_SCRIPT" "$dir/reload-cert" || { rm -rf "$dir"; return 1; }
    copy_if_exists "$SYSTEMD_UNIT" "$dir/app.service" || { rm -rf "$dir"; return 1; }
    copy_if_exists "$PROXY_SYSTEMD_UNIT" "$dir/proxy.service" || { rm -rf "$dir"; return 1; }
    copy_if_exists "$OPENRC_UNIT" "$dir/app.init" || { rm -rf "$dir"; return 1; }
    copy_if_exists "$PROXY_OPENRC_UNIT" "$dir/proxy.init" || { rm -rf "$dir"; return 1; }
    if [ "$RB_HAD_CONFIG" = 1 ] && svc status; then
        RB_WAS_RUNNING=1
    fi
    ROLLBACK_DIR=$dir
    RB_ACTIVE=1
}

abort_rollback() {
    RB_ACTIVE=0
    [ -z "$ROLLBACK_DIR" ] || rm -rf "$ROLLBACK_DIR"
    ROLLBACK_DIR=''
}

commit_rollback() {
    abort_rollback
}

restore_units() {
    if [ -e "$ROLLBACK_DIR/app.service" ]; then
        cp -a "$ROLLBACK_DIR/app.service" "$SYSTEMD_UNIT" || return 1
    else
        rm -f "$SYSTEMD_UNIT"
    fi
    if [ -e "$ROLLBACK_DIR/proxy.service" ]; then
        cp -a "$ROLLBACK_DIR/proxy.service" "$PROXY_SYSTEMD_UNIT" || return 1
    else
        rm -f "$PROXY_SYSTEMD_UNIT"
    fi
    if [ -e "$ROLLBACK_DIR/app.init" ]; then
        cp -a "$ROLLBACK_DIR/app.init" "$OPENRC_UNIT" || return 1
        chmod 755 "$OPENRC_UNIT" || return 1
    else
        rm -f "$OPENRC_UNIT"
    fi
    if [ -e "$ROLLBACK_DIR/proxy.init" ]; then
        cp -a "$ROLLBACK_DIR/proxy.init" "$PROXY_OPENRC_UNIT" || return 1
        chmod 755 "$PROXY_OPENRC_UNIT" || return 1
    else
        rm -f "$PROXY_OPENRC_UNIT"
    fi
    if [ "$(backend)" = systemd ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

restore_runtime() {
    [ "${RB_ACTIVE:-0}" = 1 ] || return 0
    svc stop >/dev/null 2>&1 || true
    if [ "$RB_HAD_BIN" = 1 ]; then
        install_file "$ROLLBACK_DIR/anytls-server" "$BIN" 755 || return 1
    else
        rm -f "$BIN"
    fi
    if [ "$RB_HAD_CONFIG" = 1 ]; then
        cp -a "$ROLLBACK_DIR/config" "$ENV_FILE" || return 1
        chmod 600 "$ENV_FILE" || return 1
    else
        rm -f "$ENV_FILE"
    fi
    if [ -e "$ROLLBACK_DIR/version" ]; then
        cp -a "$ROLLBACK_DIR/version" "$VERSION_FILE" || return 1
    else
        rm -f "$VERSION_FILE"
    fi
    if [ -e "$ROLLBACK_DIR/certs" ]; then
        rm -rf "$CERT_DIR"
        cp -a "$ROLLBACK_DIR/certs" "$CERT_DIR" || return 1
    else
        rm -rf "$CERT_DIR"
    fi
    if [ -e "$ROLLBACK_DIR/haproxy.cfg" ]; then
        cp -a "$ROLLBACK_DIR/haproxy.cfg" "$HAPROXY_CFG" || return 1
    else
        rm -f "$HAPROXY_CFG"
    fi
    if [ -e "$ROLLBACK_DIR/reload-cert" ]; then
        cp -a "$ROLLBACK_DIR/reload-cert" "$RELOAD_SCRIPT" || return 1
        chmod 700 "$RELOAD_SCRIPT" || return 1
    else
        rm -f "$RELOAD_SCRIPT"
    fi
    restore_units || return 1
    if [ "$RB_HAD_BIN" = 1 ] && [ "$RB_HAD_CONFIG" = 1 ]; then
        if [ "$(tls_mode)" = acme ]; then
            install_acme_schedule >/dev/null 2>&1 || true
        else
            remove_acme_schedule
        fi
        if [ "$RB_WAS_RUNNING" = 1 ]; then
            svc start >/dev/null 2>&1 || true
        fi
    elif [ "$RB_HAD_BIN" = 0 ]; then
        remove_acme_schedule
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
        error "$msg 自动恢复失败，备份仍在 $ROLLBACK_DIR"
        RB_ACTIVE=1
        clean_tmp
    fi
    return 1
}

apply_config() {
    local new_bin="${1:-}" message="${2:-配置完成。}"
    begin_rollback || { clean_tmp; error '无法备份当前文件。'; return 1; }
    if ! svc stop; then
        abort_rollback
        clean_tmp
        error '无法停止当前服务。'
        return 1
    fi
    if [ -n "$new_bin" ]; then
        install_file "$new_bin" "$BIN" 755 || { fail_apply '程序文件写入失败。'; return 1; }
        save_version "$NEW_VERSION" || { fail_apply '版本文件写入失败。'; return 1; }
    fi
    save_config "$SET_PORT" "$SET_TLS_MODE" "$SET_DOMAIN" "$SET_EMAIL" "$SET_BACKEND_PORT" "$SET_PASSWORD" || {
        fail_apply '配置文件写入失败。'
        return 1
    }
    if [ "$SET_TLS_MODE" = acme ]; then
        if ! acme_packages || ! issue_certificate "$SET_DOMAIN" "$SET_EMAIL" \
            || ! write_proxy_config || ! install_acme_schedule; then
            fail_apply 'ACME 配置失败，已恢复。'
            return 1
        fi
    else
        remove_acme_schedule
        rm -f "$HAPROXY_CFG" "$RELOAD_SCRIPT" "$HAPROXY_PEM"
    fi
    secure_tree || { fail_apply '权限设置失败，已恢复。'; return 1; }
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
    choose_config || { clean_tmp; return 1; }
    apply_config "$new_bin" '安装完成。'
}

configure_app() {
    packages || return 1
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
    if [ "$(tls_mode)" = acme ]; then
        acme_packages || return 1
        if [ -z "$(cfg domain)" ] || [ -z "$(cfg backend_port)" ]; then
            error '当前 ACME 配置不完整，请先选择“配置”。'
            return 1
        fi
    fi
    release_info || return 1
    latest="$RELEASE_TAG"
    current=$(version)
    if [ -n "$current" ] && ! version_newer "$latest" "$current"; then
        printf '当前已是最新版本：%s\n' "$current"
        return 0
    fi
    fetch_release || { clean_tmp; return 1; }
    begin_rollback || { clean_tmp; error '无法备份当前文件。'; return 1; }
    if ! svc stop; then
        abort_rollback
        clean_tmp
        error '无法停止当前服务。'
        return 1
    fi
    install_file "$NEW_BIN" "$BIN" 755 || { fail_apply '程序文件写入失败。'; return 1; }
    save_version "$NEW_VERSION" || { fail_apply '版本文件写入失败。'; return 1; }
    if [ "$(tls_mode)" = acme ]; then
        ensure_haproxy || { fail_apply '缺少 haproxy，已恢复。'; return 1; }
        build_haproxy_pem || { fail_apply '证书文件准备失败，已恢复。'; return 1; }
        write_proxy_config || { fail_apply 'HAProxy 配置写入失败，已恢复。'; return 1; }
        write_reload_script || { fail_apply '续期脚本写入失败，已恢复。'; return 1; }
    fi
    secure_tree || { fail_apply '权限设置失败，已恢复。'; return 1; }
    svc install || { fail_apply '服务配置更新失败，已恢复。'; return 1; }
    if svc start; then
        commit_rollback
        clean_tmp
        printf '已更新至 %s\n' "$latest"
        show_info || true
    else
        fail_apply '服务启动失败，已恢复。'
        return 1
    fi
}

prepare_acme_runtime() {
    acme_packages || return 1
    if [ -z "$(cfg domain)" ] || [ -z "$(cfg backend_port)" ]; then
        error 'ACME 配置不完整，请先选择“配置”。'
        return 1
    fi
    ensure_haproxy || return 1
    if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
        error 'ACME 证书不存在，请先选择“配置”。'
        return 1
    fi
    build_haproxy_pem || return 1
    write_proxy_config || return 1
    write_reload_script || return 1
}

start_app() {
    packages || return 1
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未完成安装，请先选择“安装”或“配置”。'
        return 1
    fi
    if [ "$(tls_mode)" = acme ]; then
        prepare_acme_runtime || return 1
    fi
    secure_tree || { error '权限设置失败。'; return 1; }
    svc install || { error '服务配置写入失败。'; return 1; }
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
    packages || return 1
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未完成安装，请先选择“安装”或“配置”。'
        return 1
    fi
    if [ "$(tls_mode)" = acme ]; then
        prepare_acme_runtime || return 1
    fi
    secure_tree || { error '权限设置失败。'; return 1; }
    svc stop || { error '服务停止失败。'; return 1; }
    svc install || { error '服务配置写入失败。'; return 1; }
    if svc start; then
        printf '服务已重启。\n'
    else
        error '服务重启失败。'
        return 1
    fi
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

show_info() {
    local port mode domain password ip4 ip6 local4 local6 cert_expiry host ext
    [ -r "$ENV_FILE" ] || { error '配置文件不存在。'; return 1; }
    port=$(cfg port)
    mode=$(tls_mode)
    domain=$(cfg domain)
    password=$(cfg password)
    ip4=''
    ip6=''
    local4=$(route_src -4 1.1.1.1 || true)
    local6=$(route_src -6 2606:4700:4700::1111 || true)
    is_global_ipv4 "$local4" && ip4=$local4
    is_global_ipv6 "$local6" && ip6=$local6
    if [ -z "$ip4" ] && has curl; then
        ext=$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
        is_global_ipv4 "$ext" && ip4=$ext
    fi
    if [ -z "$ip6" ] && has curl; then
        ext=$(curl -6fsS --max-time 3 https://api64.ipify.org 2>/dev/null || true)
        is_global_ipv6 "$ext" && ip6=$ext
    fi
    if [ "$mode" = acme ]; then
        cert_expiry='未安装'
        if [ -s "$CERT_FILE" ] && has openssl; then
            cert_expiry=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null || printf '无效')
            cert_expiry=${cert_expiry#notAfter=}
        fi
    else
        cert_expiry='官方自动生成的自签名证书'
    fi

    printf '\n状态  %s  %s\n' \
        "$(svc status && printf '运行中' || printf '已停止')" "$(version)"
    [ -n "$ip4" ] && printf 'IPv4  %s\n' "$ip4"
    [ -n "$ip6" ] && printf 'IPv6  %s\n' "$ip6"
    if [ -z "$ip4" ] && [ -z "$ip6" ]; then
        printf '地址  无公网地址\n'
        [ -n "$local4" ] && ! is_global_ipv4 "$local4" && printf '内网  %s\n' "$local4"
        [ -n "$local6" ] && ! is_global_ipv6 "$local6" && printf '内网  %s\n' "$local6"
    fi
    if [ "$mode" = acme ]; then
        printf '模式  ACME\n域名  %s\n端口  %s\n证书  %s\n协议  AnyTLS\n密码  %s\n' \
            "$domain" "$port" "$cert_expiry" "$password"
        printf '链接  anytls://%s@%s:%s\n' "$password" "$domain" "$port"
        printf '提示  请确认 DNS 已指向本机，并放行 %s/tcp、80/tcp。\n' "$port"
    else
        printf '模式  自签名\n端口  %s\n证书  %s\n协议  AnyTLS\n密码  %s\n' \
            "$port" "$cert_expiry" "$password"
        if [ -n "$ip4" ]; then
            printf 'IPv4链接  anytls://%s@%s:%s/?insecure=1\n' "$password" "$ip4" "$port"
        fi
        if [ -n "$ip6" ]; then
            host="[$ip6]"
            printf 'IPv6链接  anytls://%s@%s:%s/?insecure=1\n' "$password" "$host" "$port"
        fi
        [ -n "$ip4" ] || [ -n "$ip6" ] || printf '链接  无公网地址，请手动替换服务器 IP。\n'
        printf '提示  请确认云防火墙已放行 %s/tcp。客户端需跳过证书校验。\n' "$port"
    fi
    printf '提示  链接和密码会留在终端回滚缓冲。启动后会从进程参数中清除密码。\n'
}

show_logs() {
    case "$(backend)" in
        systemd) journalctl -u "$APP" -u "$PROXY_APP" -n 100 --no-pager 2>/dev/null || true ;;
        openrc|direct)
            [ -f "$LOG_FILE" ] && tail -n 60 "$LOG_FILE" || printf '暂无 AnyTLS 日志。\n'
            [ -f "$PROXY_LOG_FILE" ] && tail -n 60 "$PROXY_LOG_FILE" || printf '暂无 HAProxy 日志。\n'
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
    remove_acme_schedule
    svc remove || { error '服务移除失败，已停止卸载。'; return 1; }
    rm -f "$BIN" "$ENV_FILE" "$VERSION_FILE" \
        "$HAPROXY_CFG" "$RELOAD_SCRIPT" "$PID_FILE" "$PROXY_PID_FILE" \
        "$LOG_FILE" "$PROXY_LOG_FILE" "$ACME_CRON_FILE"
    rm -rf "$CERT_DIR" "$ACME_HOME" "$BASE_DIR"/rollback.* "$BASE_DIR"/config.*
    rmdir "$BASE_DIR" 2>/dev/null || true
    remove_service_account
    printf '已卸载。\n'
}

install_packages() {
    if has apk; then
        apk add --no-cache "$@"
    elif has apt-get; then
        env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            && env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif has dnf; then
        dnf install -y "$@"
    elif has yum; then
        yum install -y "$@"
    elif has pacman; then
        pacman -Sy --noconfirm "$@"
    else
        return 1
    fi
}

packages() {
    local missing='' c pkgs
    for c in curl jq unzip sha256sum; do
        has "$c" || missing="$missing $c"
    done
    pkgs='curl jq unzip coreutils ca-certificates'
    if has apk; then
        pkgs="$pkgs setpriv util-linux"
    else
        pkgs="$pkgs util-linux"
    fi
    if [ -z "$missing" ] && has flock && { [ "$(backend)" != direct ] || resolve_setpriv; }; then
        return 0
    fi
    install_packages $pkgs || {
        error "缺少依赖:$missing，且安装失败。"
        return 1
    }
    for c in curl jq unzip sha256sum; do
        has "$c" || { error "安装后仍缺少 $c。"; return 1; }
    done
}

acme_packages() {
    local missing='' c
    for c in haproxy openssl socat; do
        has "$c" || missing="$missing $c"
    done
    [ -z "$missing" ] && return 0
    install_packages haproxy openssl socat || {
        error "缺少依赖:$missing，且安装失败。"
        return 1
    }
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
        if [ -n "${NOTICE:-}" ]; then
            printf '%s\n' "$NOTICE"
            NOTICE=''
        fi
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
    exec 9>"$dir/anytls.sh.lock" || { error '无法创建运行锁。'; return 1; }
    flock -n 9 || { error '已有另一个实例正在运行。'; return 1; }
}

if [ "${ANYTLS_LIBRARY_ONLY:-0}" != 1 ]; then
    root || exit 1
    acquire_lock || exit 1
    migrate_privileges || true
    menu
fi
