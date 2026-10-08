#!/usr/bin/env bash
set -u
umask 077

APP='anytls'
PROXY_APP='anytls-proxy'
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
HAPROXY_BIN=''
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
        tls_mode) sed -n 's/^ANYTLS_TLS_MODE=//p' "$ENV_FILE" ;;
        domain) sed -n 's/^ANYTLS_DOMAIN=//p' "$ENV_FILE" ;;
        email) sed -n 's/^ANYTLS_EMAIL=//p' "$ENV_FILE" ;;
        backend_port) sed -n 's/^ANYTLS_BACKEND_PORT=//p' "$ENV_FILE" ;;
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

valid_domain() {
    local value="${1:-}" label
    local -a labels
    [ -n "$value" ] || return 1
    ((${#value} <= 253)) || return 1
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
    [ -z "${1:-}" ] || [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@.]+(\.[^[:space:]@.]+)+$ ]]
}

backend_port_for() {
    local port="$1"
    if (( port < 65535 )); then
        printf '%s' "$((port + 1))"
    else
        printf '65534'
    fi
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
    local old_port old_mode old_domain old_email old_password value default_password default_mode
    old_port=$(cfg port)
    old_mode=$(cfg tls_mode)
    old_domain=$(cfg domain)
    old_email=$(cfg email)
    old_password=$(cfg password)
    if [ -z "$old_mode" ]; then
        [ -n "$old_domain" ] && old_mode='acme' || old_mode='self_signed'
    fi
    [ "$old_mode" = acme ] && default_mode=2 || default_mode=1

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
            printf '域名无效，请输入已解析到本机的合法域名。\n'
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
        SET_BACKEND_PORT=$(backend_port_for "$SET_PORT")
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
    [ -x "$HAPROXY_BIN" ] || {
        error '缺少 haproxy，无法使用 ACME 证书。'
        return 1
    }
}

build_haproxy_pem() {
    local temp
    if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
        error 'ACME 证书文件不存在。'
        return 1
    fi
    mkdir -p "$CERT_DIR" || return 1
    temp=$(mktemp "$CERT_DIR/haproxy.pem.XXXXXX") || return 1
    if ! cat "$CERT_FILE" "$KEY_FILE" > "$temp" || ! chmod 600 "$temp" || ! mv "$temp" "$HAPROXY_PEM"; then
        rm -f "$temp"
        return 1
    fi
}

write_proxy_config() {
    local port backend temp
    ensure_haproxy || return 1
    port=$(cfg port)
    backend=$(cfg backend_port)
    if [ -z "$port" ] || [ -z "$backend" ]; then
        error 'AnyTLS 端口配置不完整。'
        return 1
    fi
    temp=$(mktemp "$BASE_DIR/haproxy.cfg.XXXXXX") || return 1
    if ! cat > "$temp" <<EOF
global
    maxconn 512000

defaults
    mode tcp
    timeout connect 10s
    timeout client 1h
    timeout server 1h

frontend anytls_front
    bind :$port ssl crt $HAPROXY_PEM
    default_backend anytls_backend

backend anytls_backend
    mode tcp
    server anytls 127.0.0.1:$backend ssl verify none
EOF
    then
        rm -f "$temp"
        return 1
    fi
    if ! chmod 600 "$temp" || ! mv "$temp" "$HAPROXY_CFG"; then
        rm -f "$temp"
        return 1
    fi
    "$HAPROXY_BIN" -c -q -f "$HAPROXY_CFG" || {
        error 'HAProxy 配置校验失败。'
        return 1
    }
}

write_reload_script() {
    local temp
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

next="\${pem}.tmp.\$\$"
if ! cat "\$cert" "\$key" > "\$next" || ! chmod 600 "\$next" || ! mv "\$next" "\$pem"; then
    rm -f "\$next"
    exit 1
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && systemctl is-active --quiet "\$proxy_app" 2>/dev/null; then
    systemctl restart "\$proxy_app"
elif command -v rc-service >/dev/null 2>&1 && rc-service "\$proxy_app" status >/dev/null 2>&1; then
    rc-service "\$proxy_app" restart
elif [ -s "\$proxy_pid_file" ]; then
    old_pid=\$(cat "\$proxy_pid_file" 2>/dev/null || true)
    case "\$old_pid" in ''|*[!0-9]*) old_pid='' ;; esac
    [ -z "\$old_pid" ] || kill "\$old_pid" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        kill -0 "\$old_pid" 2>/dev/null || break
        sleep 1
    done
    nohup "\$proxy_bin" -db -f "\$cfg" >>"\$proxy_log" 2>&1 &
    printf '%s\\n' "\$!" > "\$proxy_pid_file"
fi
EOF
    then
        rm -f "$temp"
        return 1
    fi
    if ! chmod 700 "$temp" || ! mv "$temp" "$RELOAD_SCRIPT"; then
        rm -f "$temp"
        return 1
    fi
}

install_acme_schedule() {
    local temp
    case "$(backend)" in
        systemd)
            cat > "$ACME_SYSTEMD_UNIT" <<EOF
[Unit]
Description=AnyTLS ACME renewal

[Service]
Type=oneshot
ExecStart=$ACME_BIN --cron --home $ACME_HOME
EOF
            cat > "$ACME_TIMER_UNIT" <<EOF
[Unit]
Description=Run AnyTLS ACME renewal daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
            systemctl daemon-reload || return 1
            systemctl enable --now "$(basename "$ACME_TIMER_UNIT")" >/dev/null 2>&1 || return 1
            ;;
        openrc|direct)
            if has crontab; then
                "$ACME_BIN" --home "$ACME_HOME" --install-cronjob >/dev/null 2>&1 || true
            fi
            if [ -d /etc/cron.d ]; then
                temp=$(mktemp /etc/cron.d/anytls-acme.XXXXXX) || return 1
                printf '17 3 * * * root %s --cron --home %s >/dev/null 2>&1\\n' \
                    "$ACME_BIN" "$ACME_HOME" > "$temp" || {
                    rm -f "$temp"
                    return 1
                }
                if ! chmod 644 "$temp" || ! mv "$temp" "$ACME_CRON_FILE"; then
                    rm -f "$temp"
                    return 1
                fi
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
        openrc|direct) rm -f "$ACME_CRON_FILE" ;;
    esac
}

install_acme_client() {
    local temp
    mkdir -p "$ACME_HOME" || return 1
    if [ ! -x "$ACME_BIN" ]; then
        temp=$(mktemp "$ACME_HOME/acme.sh.XXXXXX") || return 1
        curl -fLsS --connect-timeout 10 --max-time 90 \
            -H 'User-Agent: anytls.sh' \
            -o "$temp" https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh 2>/dev/null || {
            rm -f "$temp"
            error '下载 acme.sh 失败。'
            return 1
        }
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
    install_acme_client || return 1
    write_reload_script || return 1
    printf "申请 %s 的 Let's Encrypt 证书...\\n" "$domain"

    register_args=(--home "$ACME_HOME" --server letsencrypt --register-account)
    [ -z "$email" ] || register_args+=(-m "$email")
    "$ACME_BIN" "${register_args[@]}" || {
        error 'ACME 账户注册失败。'
        return 1
    }

    issue_args=(--home "$ACME_HOME" --server letsencrypt --issue --standalone --httpport 80 -d "$domain")
    "${ACME_BIN}" "${issue_args[@]}" || {
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
    install_acme_schedule || {
        error 'ACME 自动续期任务配置失败。'
        return 1
    }
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

stop_direct_pid() {
    local pid_file="$1" checker="$2" pid
    if pid=$($checker); then
        kill "$pid" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
            "$checker" >/dev/null || break
            sleep 1
        done
        if "$checker" >/dev/null; then
            kill -KILL "$pid" >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$pid_file"
}

svc() {
    local action="$1" b port backend password listen
    b=$(backend)
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
            if service_uses_proxy; then
                ensure_haproxy || return 1
                listen="127.0.0.1:\${ANYTLS_BACKEND_PORT}"
            else
                listen=":\${ANYTLS_PORT}"
            fi
            cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=AnyTLS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$BIN -l $listen -p \${ANYTLS_PASSWORD}
Restart=on-failure
RestartSec=3
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF
            if service_uses_proxy; then
                cat > "$PROXY_SYSTEMD_UNIT" <<EOF
[Unit]
Description=AnyTLS TLS Frontend
Requires=$APP.service
After=$APP.service

[Service]
Type=simple
ExecStart=$HAPROXY_BIN -db -f $HAPROXY_CFG
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF
            else
                systemctl disable --now "$PROXY_APP" >/dev/null 2>&1 || true
                rm -f "$PROXY_SYSTEMD_UNIT"
            fi
            systemctl daemon-reload || return 1
            if service_uses_proxy; then
                systemctl enable "$APP" "$PROXY_APP" >/dev/null 2>&1 || return 1
            else
                systemctl enable "$APP" >/dev/null 2>&1 || return 1
            fi
            ;;
        install/openrc)
            if service_uses_proxy; then
                ensure_haproxy || return 1
                listen="127.0.0.1:\${ANYTLS_BACKEND_PORT}"
            else
                listen=":\${ANYTLS_PORT}"
            fi
            cat > "$OPENRC_UNIT" <<EOF
#!/sbin/openrc-run
. "$ENV_FILE"
name="AnyTLS"
command="$BIN"
command_args="-l $listen -p \${ANYTLS_PASSWORD}"
supervisor="supervise-daemon"
supervise_daemon_args="--stdout $LOG_FILE --stderr $LOG_FILE"
pidfile="$PID_FILE"

depend() {
    need net
}
EOF
            chmod 755 "$OPENRC_UNIT" || return 1
            rc-update add "$APP" default >/dev/null 2>&1 || return 1
            if service_uses_proxy; then
                cat > "$PROXY_OPENRC_UNIT" <<EOF
#!/sbin/openrc-run
name="AnyTLS TLS Frontend"
command="$HAPROXY_BIN"
command_args="-db -f $HAPROXY_CFG"
supervisor="supervise-daemon"
supervise_daemon_args="--stdout $PROXY_LOG_FILE --stderr $PROXY_LOG_FILE"
pidfile="$PROXY_PID_FILE"

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
            if service_uses_proxy; then
                ensure_haproxy
            else
                stop_direct_pid "$PROXY_PID_FILE" proxy_pid
            fi
            ;;

        start/systemd)
            systemctl start "$APP" || return 1
            if service_uses_proxy; then
                systemctl start "$PROXY_APP" || return 1
            else
                systemctl stop "$PROXY_APP" >/dev/null 2>&1 || true
            fi
            svc status
            ;;
        start/openrc)
            rc-service "$APP" start || return 1
            if service_uses_proxy; then
                rc-service "$PROXY_APP" start || return 1
            else
                rc-service "$PROXY_APP" stop >/dev/null 2>&1 || true
            fi
            svc status
            ;;
        start/direct)
            if service_uses_proxy; then
                ensure_haproxy || return 1
            else
                stop_direct_pid "$PROXY_PID_FILE" proxy_pid
            fi
            svc status && return 0
            port=$(cfg port)
            password=$(cfg password)
            [ -n "$port" ] && [ -n "$password" ] || return 1
            if service_uses_proxy; then
                backend=$(cfg backend_port)
                [ -n "$backend" ] || return 1
                listen="127.0.0.1:$backend"
            else
                listen=":$port"
            fi
            if ! server_pid >/dev/null; then
                rm -f "$PID_FILE"
                mkdir -p "${LOG_FILE%/*}" "${PID_FILE%/*}"
                nohup "$BIN" -l "$listen" -p "$password" \
                    >>"$LOG_FILE" 2>&1 &
                printf '%s\n' "$!" > "$PID_FILE"
                sleep 1
            fi
            server_pid >/dev/null || return 1
            if service_uses_proxy && ! proxy_pid >/dev/null; then
                rm -f "$PROXY_PID_FILE"
                mkdir -p "${PROXY_LOG_FILE%/*}" "${PROXY_PID_FILE%/*}"
                nohup "$HAPROXY_BIN" -db -f "$HAPROXY_CFG" \
                    >>"$PROXY_LOG_FILE" 2>&1 &
                printf '%s\n' "$!" > "$PROXY_PID_FILE"
                sleep 1
            fi
            svc status
            ;;

        stop/systemd)
            systemctl stop "$PROXY_APP" >/dev/null 2>&1 || true
            systemctl stop "$APP" >/dev/null 2>&1 || true
            ;;
        stop/openrc)
            rc-service "$PROXY_APP" stop >/dev/null 2>&1 || true
            rc-service "$APP" stop >/dev/null 2>&1 || true
            ;;
        stop/direct)
            stop_direct_pid "$PROXY_PID_FILE" proxy_pid
            stop_direct_pid "$PID_FILE" server_pid
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
    save_config "$SET_PORT" "$SET_TLS_MODE" "$SET_DOMAIN" "$SET_EMAIL" "$SET_BACKEND_PORT" "$SET_PASSWORD" || {
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
    if [ "$SET_TLS_MODE" = acme ]; then
        acme_packages || { clean_tmp; return 1; }
        issue_certificate "$SET_DOMAIN" "$SET_EMAIL" || { clean_tmp; return 1; }
        write_proxy_config || { clean_tmp; return 1; }
    else
        remove_acme_schedule
        rm -f "$HAPROXY_CFG"
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
    packages || return 1
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未安装，请先选择“安装”。'
        return 1
    fi
    choose_config || return 1
    apply_config '' '配置完成。'
}

update_app() {
    local latest current mode
    packages || return 1
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未安装，请先选择“安装”。'
        return 1
    fi
    mode=$(tls_mode)
    if [ "$mode" = acme ]; then
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
    local mode
    packages || return 1
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未完成安装，请先选择“安装”或“配置”。'
        return 1
    fi
    mode=$(tls_mode)
    if [ "$mode" = acme ]; then
        acme_packages || return 1
        if [ -z "$(cfg domain)" ]; then
            error 'ACME 域名未配置，请先选择“配置”。'
            return 1
        fi
        ensure_haproxy || return 1
        if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
            error 'ACME 证书不存在，请先选择“配置”。'
            return 1
        fi
        build_haproxy_pem || return 1
        write_proxy_config || return 1
    fi
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
    local mode
    packages || return 1
    if [ ! -x "$BIN" ] || [ ! -r "$ENV_FILE" ]; then
        error '尚未完成安装，请先选择“安装”或“配置”。'
        return 1
    fi
    mode=$(tls_mode)
    if [ "$mode" = acme ]; then
        acme_packages || return 1
        ensure_haproxy || return 1
        build_haproxy_pem || return 1
        write_proxy_config || return 1
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
    local port mode domain password ip4 ip6 cert_expiry host
    [ -r "$ENV_FILE" ] || { error '配置文件不存在。'; return 1; }
    port=$(cfg port)
    mode=$(tls_mode)
    domain=$(cfg domain)
    password=$(cfg password)
    ip4=''; ip6=''
    if [ "$mode" = acme ]; then
        cert_expiry='未安装'
        if [ -s "$CERT_FILE" ] && has openssl; then
            cert_expiry=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null || printf '无效')
            cert_expiry=${cert_expiry#notAfter=}
        fi
    else
        cert_expiry='官方自动生成的自签名证书'
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
    if [ "$mode" = acme ]; then
        printf '模式  ACME\n域名  %s\n端口  %s\n证书  %s\n协议  AnyTLS\n密码  %s\n' \
            "$domain" "$port" "$cert_expiry" "$password"
        printf '链接  anytls://%s@%s:%s\n' "$password" "$domain" "$port"
        printf '提示  请确认 DNS 已指向本机，并放行 %s/tcp、80/tcp。\n' "$port"
    else
        printf '模式  自签名\n端口  %s\n证书  %s\n协议  AnyTLS\n密码  %s\n' \
            "$port" "$cert_expiry" "$password"
        if [ -n "$ip4" ]; then
            printf 'IPv4链接  anytls://%s@%s:%s\n' "$password" "$ip4" "$port"
        fi
        if [ -n "$ip6" ]; then
            host="[$ip6]"
            printf 'IPv6链接  anytls://%s@%s:%s\n' "$password" "$host" "$port"
        fi
        [ -n "$ip4" ] || [ -n "$ip6" ] || printf '链接  无公网地址，请手动替换服务器 IP。\n'
        printf '提示  请确认云防火墙已放行 %s/tcp。\n' "$port"
    fi
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
    rm -f "$BIN" "$ENV_FILE" "$BASE_DIR"/config.* "$VERSION_FILE" \
        "$HAPROXY_CFG" "$RELOAD_SCRIPT" "$PID_FILE" "$PROXY_PID_FILE" \
        "$LOG_FILE" "$PROXY_LOG_FILE" "$ACME_CRON_FILE"
    rm -rf "$CERT_DIR" "$ACME_HOME"
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

acme_packages() {
    local missing='' c
    for c in haproxy openssl; do
        has "$c" || missing="$missing $c"
    done
    [ -z "$missing" ] && return 0

    if has apk; then
        apk add --no-cache haproxy openssl
    elif has apt-get; then
        apt-get update -qq && apt-get install -y haproxy openssl
    elif has dnf; then
        dnf install -y haproxy openssl
    elif has yum; then
        yum install -y haproxy openssl
    elif has pacman; then
        pacman -Sy --noconfirm haproxy openssl
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
