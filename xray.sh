#!/usr/bin/env bash
# xray.sh — Minimalist Xray Core Management Script (Debian / Ubuntu / Alpine)

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh}"
SCRIPT_MARKER="Minimalist Xray Core Management Script"

if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if [ -f /etc/alpine-release ]; then
            apk update >/dev/null 2>&1 && apk add --no-cache bash >/dev/null 2>&1
        elif [ -f /etc/debian_version ] || [ -f /etc/os-release ]; then
            apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y bash >/dev/null 2>&1
        fi
    fi
    [ -f "$0" ] && grep -q "$SCRIPT_MARKER" "$0" 2>/dev/null && exec bash "$0" "$@"
    _xray_src="$(curl -fsSL "$SCRIPT_URL" 2>/dev/null || wget -qO- "$SCRIPT_URL" 2>/dev/null)"
    [ -z "$_xray_src" ] && { echo "无法下载脚本: $SCRIPT_URL" >&2; exit 1; }
    exec bash -c "$_xray_src" xray.sh "$@"
fi

set -o pipefail
shopt -s checkwinsize 2>/dev/null || true
[ -e /dev/fd ] || ln -sf /proc/self/fd /dev/fd 2>/dev/null || true

GH_PROXY="${GH_PROXY:-}"
[ -n "$GH_PROXY" ] && [[ "$GH_PROXY" != */ ]] && GH_PROXY="${GH_PROXY}/"

XRAY_SHARE_DIR="/usr/local/share/xray"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_CONFIG_DIR/config.json"
XRAY_CERTS_DIR="$XRAY_CONFIG_DIR/certs"
XRAY_LOG_DIR="/var/log/xray"
XRAY_ERROR_LOG="$XRAY_LOG_DIR/error.log"
LOGROTATE_CONF="/etc/logrotate.d/xray"

SYSTEMD_SERVICE="/etc/systemd/system/xray.service"
OPENRC_SERVICE="/etc/init.d/xray"
DAEMON_PID_FILE="/run/xray.pid"
SERVICE_DESC="Xray Core Service"

SCRIPT_SELF=""
[ -n "${BASH_SOURCE[0]:-}" ] && SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_LINK="/usr/local/bin/xraym"
LEGACY_SCRIPT_LINK="/usr/local/bin/xray"

DNS64_SERVERS="2001:67c:2b0::4 2a01:4f8:c2c:123f::1"
RESOLVED_DNS64_CONF="/etc/systemd/resolved.conf.d/99-xray-dns64.conf"

SERVER_IP="" SERVER_IPV4="" SERVER_IPV6="" IP_FETCHED=0 XRAY_VER=""

export XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR"
export GODEBUG="multipathtcp=0"

if [ -t 1 ]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_GRAY=$'\033[90m'
else
    C_RESET="" C_BOLD="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_GRAY=""
fi


log_info()    { echo -e "  ${C_CYAN}›${C_RESET} $1"; }
log_success() { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
log_warn()    { echo -e "  ${C_YELLOW}!${C_RESET} $1"; }
log_error()   { echo -e "  ${C_RED}✖${C_RESET} $1"; }
pause()       { echo ""; read -r -p "  ${C_GRAY}按回车继续...${C_RESET}" || true; }
input_eof()   { echo ""; log_error "输入流已关闭，退出"; exit 1; }
is_cancel()   { [[ "${1:-}" =~ ^([0qQ]|[eE][xX][iI][tT])$ ]]; }

confirm() {
    local prompt="$1" def="${2:-n}" hint="[y/N]" ans=""
    [ "$def" = "y" ] && hint="[Y/n]"
    read -rp "  › ${prompt} ${hint}: " ans || input_eof
    [ -z "$ans" ] && ans="$def"
    [[ "$ans" =~ ^[yY]$ ]]
}

prompt_input() {
    local prompt="$1" default_val="$2" var_name="$3" user_val="" hint=""
    [ -n "$default_val" ] && hint=" ${C_GRAY}[${C_RESET}${C_CYAN}${default_val}${C_RESET}${C_GRAY}]${C_RESET}"
    echo -ne "  › ${prompt}${hint}: "
    read -r user_val || input_eof
    printf -v "$var_name" '%s' "${user_val:-$default_val}"
}

prompt_choice() {
    local prompt="$1" default_idx="$2" var_name="$3"; shift 3
    local idx=1 total=$# choice=""
    echo -e "  ${C_BOLD}${prompt}${C_RESET}"
    for opt in "$@"; do
        if [ "$idx" -eq "$default_idx" ]; then
            echo -e "    ${C_CYAN}${idx}.${C_RESET} ${opt} ${C_GRAY}(默认)${C_RESET}"
        else
            echo -e "    ${C_GRAY}${idx}.${C_RESET} ${opt}"
        fi
        idx=$((idx + 1))
    done
    while true; do
        read -rp "  › 请选择 [1-${total}, 默认 ${default_idx}, q 返回]: " choice || input_eof
        [ -z "$choice" ] && choice="$default_idx"
        is_cancel "$choice" && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
            printf -v "$var_name" '%s' "$choice"
            return 0
        fi
        log_warn "请输入 1-${total}，或输入 q 返回"
    done
}

get_sysctl() {
    local p="/proc/sys/${1//.//}" v=""
    if [ -r "$p" ]; then
        IFS= read -r v < "$p" 2>/dev/null || true
        printf '%s' "$v"
    else
        sysctl -n "$1" 2>/dev/null || true
    fi
}

is_bbr_enabled() { [ "$(get_sysctl net.ipv4.tcp_congestion_control)" = "bbr" ]; }

get_node_count() {
    local c=0
    [ -f "$XRAY_CONFIG" ] && c=$(jq '.inbounds | length // 0' "$XRAY_CONFIG" 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo 0
}

get_core_version() {
    is_installed || { XRAY_VER=""; return 1; }
    [ -z "$XRAY_VER" ] && XRAY_VER="$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')"
    [ -n "$XRAY_VER" ] && printf 'v%s' "${XRAY_VER#v}"
}

header() {
    clear 2>/dev/null || true
    echo ""
    local ver status_str="${C_GRAY}○ 未安装${C_RESET}"
    if is_installed; then
        ver=$(get_core_version || true)
        if is_running; then
            status_str="${C_GREEN}● 运行中${C_RESET}${ver:+ ${C_GRAY}${ver}${C_RESET}}"
        else
            status_str="${C_RED}○ 已停止${C_RESET}${ver:+ ${C_GRAY}${ver}${C_RESET}}"
        fi
    fi

    local auto_str="${C_GRAY}自启 关${C_RESET}" bbr_str="${C_GRAY}BBR 关${C_RESET}" sep="${C_GRAY}·${C_RESET}"
    is_autostart_enabled && auto_str="${C_GREEN}自启 开${C_RESET}"
    is_bbr_enabled && bbr_str="${C_GREEN}BBR 开${C_RESET}"
    [ -z "$SERVER_IP" ] && get_public_ip

    local ip_info=""
    if [ -n "$SERVER_IPV4" ]; then
        ip_info="$SERVER_IPV4"
        [ -n "$SERVER_IPV6" ] && ip_info="${ip_info} (IPv6 就绪)"
    elif [ -n "$SERVER_IPV6" ]; then
        ip_info="$SERVER_IPV6"
    else
        ip_info="未获取到 IP"
    fi

    echo -e "  ${C_BOLD}XRAY CORE${C_RESET}  ${status_str}  ${C_GRAY}(快捷命令: ${C_CYAN}xraym${C_GRAY})${C_RESET}"
    echo -e "  ${C_GRAY}${OS_NAME:-Linux} ${sep} ${ip_info} ${sep} ${bbr_str} ${sep} ${auto_str} ${sep} $(get_node_count) 个节点${C_RESET}"
    echo ""
}

check_root() { [ "$(id -u)" -eq 0 ] || { log_error "请使用 root 权限运行"; exit 1; }; }

detect_os() {
    local id="" id_like="" ver="" name="" ID="" ID_LIKE="" VERSION_ID="" NAME=""
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID,,}" id_like="${ID_LIKE,,}" ver="${VERSION_ID}" name="${NAME}"
    fi
    case "$id" in
        debian*)
            [ -z "$ver" ] && [ -f /etc/debian_version ] && ver=$(cut -d. -f1 /etc/debian_version 2>/dev/null)
            OS_TYPE="debian"; OS_NAME="Debian ${ver%%.*}" ;;
        ubuntu*)
            OS_TYPE="debian"; OS_NAME="Ubuntu ${ver}" ;;
        alpine*)
            [ -z "$ver" ] && [ -f /etc/alpine-release ] && ver=$(cat /etc/alpine-release 2>/dev/null)
            OS_TYPE="alpine"; OS_NAME="Alpine $(printf '%s' "$ver" | cut -d. -f1,2)" ;;
        *)
            if [ -f /etc/alpine-release ]; then
                OS_TYPE="alpine"; OS_NAME="Alpine $(cut -d. -f1,2 /etc/alpine-release 2>/dev/null)"
            elif [[ "$id_like" == *debian* ]] || [ -f /etc/debian_version ]; then
                OS_TYPE="debian"; OS_NAME="${name%% *}"; OS_NAME="${OS_NAME:-Debian}${ver:+ ${ver%%.*}}"
            else
                OS_TYPE="unsupported"; OS_NAME="${name:-Linux}"
            fi ;;
    esac
    OS_NAME="${OS_NAME% }"
    if [ "$OS_TYPE" != "debian" ] && [ "$OS_TYPE" != "alpine" ]; then
        log_error "仅支持 Debian / Ubuntu / Alpine Linux 系统 (当前: ${OS_NAME:-未知})"
        exit 1
    fi
}

detect_init() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT_TYPE="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_TYPE="openrc"
    else INIT_TYPE="daemon"; fi
}

detect_arch() {
    ARCH=""
    case "$(uname -m)" in
        x86_64|amd64)        ARCH="64" ;;
        aarch64|arm64)       ARCH="arm64-v8a" ;;
        armv7*|armv8l)       ARCH="arm32-v7a" ;;
        armv6*)              ARCH="arm32-v6" ;;
        armv5*)              ARCH="arm32-v5" ;;
        i386|i686)           ARCH="32" ;;
        s390x)               ARCH="s390x" ;;
        riscv64)             ARCH="riscv64" ;;
        loongarch64|loong64) ARCH="loong64" ;;
        ppc64le)             ARCH="ppc64le" ;;
        ppc64)               ARCH="ppc64" ;;
        mips64el)            ARCH="mips64le" ;;
        mips64)              ARCH="mips64" ;;
        mipsel)              ARCH="mips32le" ;;
        mips)                ARCH="mips32" ;;
    esac
}

is_ipv6_only() {
    ! ip -4 route show default 2>/dev/null | grep -q default &&
      ip -6 route show default 2>/dev/null | grep -q default
}

format_url_host() { [[ "$1" == *:* && "$1" != \[*\] ]] && echo "[$1]" || echo "$1"; }

get_public_ip() {
    [ "${1:-}" = "force" ] && { SERVER_IPV4=""; SERVER_IPV6=""; SERVER_IP=""; }
    [[ -n "$SERVER_IPV4" || -n "$SERVER_IPV6" ]] && return
    [ "${IP_FETCHED:-0}" -eq 1 ] && [ "${1:-}" != "force" ] && return
    IP_FETCHED=1

    local has_v4=0 has_v6=0 tmp_dir
    if command -v ip >/dev/null 2>&1; then
        ip -4 route show default 2>/dev/null | grep -q default && has_v4=1
        ip -6 route show default 2>/dev/null | grep -q default && has_v6=1
    fi
    [ "$has_v4" -eq 0 ] && [ "$has_v6" -eq 0 ] && { has_v4=1; has_v6=1; }

    tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'xray_ip.XXXXXX') || return
    [ "$has_v4" -eq 1 ] && ( curl -fs4m 3 https://api.ipify.org || curl -fs4m 3 https://ipv4.icanhazip.com || curl -fs4m 3 https://ifconfig.me ) > "$tmp_dir/v4" 2>/dev/null &
    [ "$has_v6" -eq 1 ] && ( curl -fs6m 3 https://api6.ipify.org || curl -fs6m 3 https://ipv6.icanhazip.com || curl -fs6m 3 https://api64.ipify.org ) > "$tmp_dir/v6" 2>/dev/null &
    wait 2>/dev/null

    [ -s "$tmp_dir/v4" ] && SERVER_IPV4=$(tr -d '[:space:]' < "$tmp_dir/v4")
    [ -s "$tmp_dir/v6" ] && SERVER_IPV6=$(tr -d '[:space:]' < "$tmp_dir/v6")
    rm -rf "$tmp_dir" 2>/dev/null

    [[ "$SERVER_IPV4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || SERVER_IPV4=""
    [[ "$SERVER_IPV6" == *:* && "$SERVER_IPV6" =~ ^[0-9a-fA-F:]+$ ]] || SERVER_IPV6=""
    SERVER_IP="${SERVER_IPV4:-$SERVER_IPV6}"
}

apply_sysctl_dropin() {
    local sed_pat="$2" content="$3" conf="/etc/sysctl.d/${1}"
    [ ! -d /etc/sysctl.d ] && conf="/etc/sysctl.conf"
    sed -i "$sed_pat" "$conf" 2>/dev/null || true
    [ "$conf" != "/etc/sysctl.conf" ] && { sed -i "$sed_pat" /etc/sysctl.conf 2>/dev/null || true; }
    printf '%b' "$content" >> "$conf"
    sysctl -p "$conf" >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
}

check_mptcp_security() {
    [ "$(get_sysctl net.mptcp.enabled)" = "1" ] || return 0
    sysctl -w net.mptcp.enabled=0 >/dev/null 2>&1 || true
    apply_sysctl_dropin "99-mptcp.conf" '/net.mptcp.enabled/d' 'net.mptcp.enabled=0\n'
}

check_ipv6_only() {
    is_ipv6_only || return 0
    curl -sIm 3 https://github.com >/dev/null 2>&1 && return 0
    wget -q -T 3 -O /dev/null https://github.com 2>/dev/null && return 0

    log_warn "纯 IPv6 环境无法直连 GitHub，可配置公共 DNS64 (${DNS64_SERVERS// /, })"
    confirm "是否写入系统 DNS 配置？" "n" || { log_info "已跳过 DNS64 配置"; return 0; }

    local rconf
    rconf=$(readlink -f /etc/resolv.conf 2>/dev/null || echo "/etc/resolv.conf")
    if [[ "$rconf" == /run/systemd/resolve/* ]] && command -v resolvectl >/dev/null 2>&1; then
        mkdir -p "${RESOLVED_DNS64_CONF%/*}"
        printf '[Resolve]\nDNS=%s\n' "$DNS64_SERVERS" > "$RESOLVED_DNS64_CONF"
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
        log_success "已写入 ${RESOLVED_DNS64_CONF}"
        return 0
    fi
    [ -L /etc/resolv.conf ] && log_warn "/etc/resolv.conf 为符号链接 (-> ${rconf})，可能被网络服务覆盖"
    grep -q "${DNS64_SERVERS%% *}" "$rconf" 2>/dev/null && return 0
    [ -f "${rconf}.xray-bak" ] || cp -f "$rconf" "${rconf}.xray-bak" 2>/dev/null || true

    local lines="" s
    for s in $DNS64_SERVERS; do lines="${lines}nameserver ${s}\n"; done
    if [ -s "$rconf" ]; then
        sed -i "1i ${lines%\\n}" "$rconf" 2>/dev/null || true
    else
        printf '%b' "$lines" > "$rconf" 2>/dev/null || true
    fi
    log_success "已配置 DNS64 (原文件备份于 ${rconf}.xray-bak)"
}

remove_dns64() {
    if [ -f "$RESOLVED_DNS64_CONF" ]; then
        rm -f "$RESOLVED_DNS64_CONF" 2>/dev/null || true
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
    fi
    local rconf s
    rconf=$(readlink -f /etc/resolv.conf 2>/dev/null || echo "/etc/resolv.conf")
    for s in $DNS64_SERVERS; do
        sed -i "/^nameserver ${s//:/\\:}\$/d" "$rconf" 2>/dev/null || true
    done
    rm -f "${rconf}.xray-bak" 2>/dev/null || true
}

install_deps() {
    local required="curl unzip openssl jq" missing="" cmd
    for cmd in $required; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] && return 0

    log_info "安装系统依赖:${missing}..."
    local pkgs=(curl unzip openssl jq ca-certificates procps iproute2 bash)
    if [ "$OS_TYPE" = "alpine" ]; then
        if ! wget -q -T 3 -O /dev/null "https://dl-cdn.alpinelinux.org/alpine/" 2>/dev/null; then
            local m
            for m in "http://mirrors.edge.kernel.org/alpine" "http://mirror.leaseweb.com/alpine" "http://mirror.yandex.ru/mirrors/alpine"; do
                if wget -q -T 3 -O /dev/null "$m/" 2>/dev/null; then
                    sed -i "s|https\?://dl-cdn.alpinelinux.org/alpine|$m|g" /etc/apk/repositories 2>/dev/null || true
                    break
                fi
            done
        fi
        apk update >/dev/null 2>&1 && apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1
    else
        apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1
    fi

    missing=""
    for cmd in $required; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -n "$missing" ] && { log_error "依赖安装失败:${missing}，请手动安装后重试"; exit 1; }
    log_success "依赖已就绪"
}

ensure_xray_user() {
    if ! id -u xray >/dev/null 2>&1; then
        if [ "$OS_TYPE" = "alpine" ]; then
            addgroup -S xray 2>/dev/null || true
            adduser -S -D -H -s /sbin/nologin -G xray -g "Xray Daemon" xray 2>/dev/null || true
        else
            useradd -r -s /usr/sbin/nologin -d /var/empty -M -U xray 2>/dev/null ||
            useradd -r -s /bin/false -M -U xray 2>/dev/null ||
            useradd -r -s /bin/false -M xray 2>/dev/null || true
        fi
    fi
    mkdir -p "$XRAY_CONFIG_DIR" "$XRAY_CERTS_DIR" "$XRAY_LOG_DIR"
    chown -R xray:xray "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR" 2>/dev/null || true
    chmod 700 "$XRAY_CONFIG_DIR" "$XRAY_CERTS_DIR" 2>/dev/null || true
    chmod 750 "$XRAY_LOG_DIR" 2>/dev/null || true
    [ -f "$XRAY_CONFIG" ] && chmod 600 "$XRAY_CONFIG" 2>/dev/null
    [ -f "$XRAY_ERROR_LOG" ] && chmod 640 "$XRAY_ERROR_LOG" 2>/dev/null
    if command -v setcap >/dev/null 2>&1 && [ -f "$XRAY_BIN" ]; then
        setcap 'cap_net_bind_service=+ep' "$XRAY_BIN" 2>/dev/null || true
    fi
}

is_our_script()  { [ -f "$1" ] && head -c 4096 "$1" 2>/dev/null | grep -q "$SCRIPT_MARKER"; }
is_our_service() { [ -f "$1" ] && grep -qE "^(Description=|description=\")${SERVICE_DESC}" "$1" 2>/dev/null; }

setup_shortcut() {
    if is_our_script "$LEGACY_SCRIPT_LINK" && [ "$SCRIPT_SELF" != "$LEGACY_SCRIPT_LINK" ]; then
        rm -f "$LEGACY_SCRIPT_LINK"
        log_info "面板命令已更新为 ${C_CYAN}xraym${C_RESET}，内核命令保留为 ${C_CYAN}xray${C_RESET}"
    fi
    if [ ! -f "$XRAY_BIN" ] && [ -x "$XRAY_SHARE_DIR/xray-core" ]; then
        install -m 755 "$XRAY_SHARE_DIR/xray-core" "$XRAY_BIN" 2>/dev/null || true
    fi
    [ "$SCRIPT_SELF" = "$SCRIPT_LINK" ] && { chmod +x "$SCRIPT_LINK" 2>/dev/null || true; return 0; }

    mkdir -p /usr/local/bin
    local tmp_sh
    tmp_sh=$(mktemp /usr/local/bin/.xraym.XXXXXX 2>/dev/null) || return 0
    if [ -n "$SCRIPT_SELF" ] && is_our_script "$SCRIPT_SELF"; then
        cp -f "$SCRIPT_SELF" "$tmp_sh" 2>/dev/null
    else
        curl -fsSL "$SCRIPT_URL" -o "$tmp_sh" 2>/dev/null || wget -qO "$tmp_sh" "$SCRIPT_URL" 2>/dev/null
    fi
    if is_our_script "$tmp_sh" && bash -n "$tmp_sh" 2>/dev/null; then
        chmod 755 "$tmp_sh" && mv -f "$tmp_sh" "$SCRIPT_LINK"
    fi
    rm -f "$tmp_sh" 2>/dev/null || true
}

is_installed() {
    [ -x "$XRAY_BIN" ] && head -c 4 "$XRAY_BIN" 2>/dev/null | grep -q "ELF" && return 0
    if [ -x "$XRAY_SHARE_DIR/xray-core" ] && head -c 4 "$XRAY_SHARE_DIR/xray-core" 2>/dev/null | grep -q "ELF"; then
        install -m 755 "$XRAY_SHARE_DIR/xray-core" "$XRAY_BIN" 2>/dev/null || true
        [ -x "$XRAY_BIN" ] && return 0
    fi
    return 1
}

is_running() {
    [ -x "$XRAY_BIN" ] || [ -x "$XRAY_SHARE_DIR/xray-core" ] || return 1
    case "$INIT_TYPE" in
        systemd) systemctl is-active --quiet xray 2>/dev/null ;;
        openrc)  rc-service xray status 2>/dev/null | grep -q "status: started" ;;
        *)       { [ -f "$DAEMON_PID_FILE" ] && kill -0 "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null; } ||
                 pgrep -x xray >/dev/null 2>&1 || pgrep -x xray-core >/dev/null 2>&1 ;;
    esac
}

is_autostart_enabled() {
    case "$INIT_TYPE" in
        systemd) systemctl is-enabled --quiet xray 2>/dev/null ;;
        openrc)  rc-update show default 2>/dev/null | awk '{print $1}' | grep -qx "xray" ;;
        *)       return 1 ;;
    esac
}

svc() {
    local action="$1"
    case "$INIT_TYPE" in
        systemd)
            [ "$action" = "restart" ] && { systemctl reset-failed xray 2>/dev/null || true; }
            systemctl "$action" xray 2>/dev/null
            ;;
        openrc)
            rc-service xray "$action" >/dev/null 2>&1
            ;;
        *)
            case "$action" in
                start)
                    mkdir -p "$XRAY_LOG_DIR"
                    nohup env GODEBUG="multipathtcp=0" XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" \
                        "$XRAY_BIN" run -c "$XRAY_CONFIG" >/dev/null 2>> "$XRAY_ERROR_LOG" </dev/null &
                    echo $! > "$DAEMON_PID_FILE" ;;
                stop)
                    [ -f "$DAEMON_PID_FILE" ] && { kill "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null || true; rm -f "$DAEMON_PID_FILE"; }
                    pkill -x xray 2>/dev/null || pkill -x xray-core 2>/dev/null || true ;;
                restart) svc stop; sleep 1; svc start ;;
            esac ;;
    esac
}

service_ctrl() {
    ! is_installed && { log_warn "请先安装 Xray 核心 (菜单 9)"; return 1; }
    case "$1" in
        start)
            is_running && { log_info "服务已在运行中"; return 0; }
            svc start; sleep 1
            if is_running; then log_success "服务已启动"; else log_error "启动失败，请查看实时日志排查"; return 1; fi ;;
        stop)
            ! is_running && { log_info "服务当前未运行"; return 0; }
            svc stop; sleep 1
            if ! is_running; then log_success "服务已停止"; else log_error "停止失败"; return 1; fi ;;
        restart)
            svc restart; sleep 1
            if is_running; then log_success "服务已重启"; else log_error "重启失败，请查看实时日志排查"; return 1; fi ;;
    esac
}

service_toggle_autostart() {
    if [ "$INIT_TYPE" != "systemd" ] && [ "$INIT_TYPE" != "openrc" ]; then
        log_warn "当前环境 (${INIT_TYPE}) 不支持开机自启管理"
        return 1
    fi
    if is_autostart_enabled; then
        [ "$INIT_TYPE" = "systemd" ] && systemctl disable xray >/dev/null 2>&1
        [ "$INIT_TYPE" = "openrc" ] && rc-update del xray default >/dev/null 2>&1
        log_success "开机自启已关闭"
    else
        [ "$INIT_TYPE" = "systemd" ] && systemctl enable xray >/dev/null 2>&1
        [ "$INIT_TYPE" = "openrc" ] && rc-update add xray default >/dev/null 2>&1
        log_success "开机自启已开启"
    fi
}

view_logs() {
    header
    echo -e "  ${C_BOLD}实时日志${C_RESET} ${C_GRAY}(按 Ctrl+C 返回菜单)${C_RESET}\n"
    mkdir -p "$XRAY_LOG_DIR"
    touch "$XRAY_ERROR_LOG"
    if [ ! -s "$XRAY_ERROR_LOG" ] && [ "$INIT_TYPE" = "systemd" ]; then
        journalctl -u xray -n 30 --no-pager 2>/dev/null
    fi
    trap ' ' INT
    tail -n 50 -f "$XRAY_ERROR_LOG" 2>/dev/null
    trap - INT
}

get_latest_xray_version() {
    local tag="" url_rel="https://github.com/XTLS/Xray-core/releases/latest"
    local url_api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    [ -n "$GH_PROXY" ] && { url_rel="${GH_PROXY}${url_rel}"; url_api="${GH_PROXY}${url_api}"; }
    tag=$(curl -fsIL -o /dev/null -w '%{url_effective}' --max-time 8 "$url_rel" 2>/dev/null | awk -F'/' '{print $NF}')
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        tag=$(curl -fsSL --max-time 8 "$url_api" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
    fi
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] && echo "$tag"
}

setup_logrotate() {
    [ -d /etc/logrotate.d ] || return 0
    printf '%s/*.log {\n    weekly\n    rotate 4\n    maxsize 10M\n    missingok\n    notifempty\n    compress\n    delaycompress\n    copytruncate\n}\n' "$XRAY_LOG_DIR" > "$LOGROTATE_CONF"
    chmod 644 "$LOGROTATE_CONF" 2>/dev/null || true
}

init_config_if_needed() {
    mkdir -p "$XRAY_CONFIG_DIR" "$XRAY_CERTS_DIR" "$XRAY_LOG_DIR" "$XRAY_SHARE_DIR"
    ( umask 077; touch "$XRAY_ERROR_LOG" )
    chmod 700 "$XRAY_CONFIG_DIR" "$XRAY_CERTS_DIR" 2>/dev/null || true
    chmod 750 "$XRAY_LOG_DIR" 2>/dev/null || true
    chmod 640 "$XRAY_ERROR_LOG" 2>/dev/null || true
    setup_logrotate
    if [ ! -s "$XRAY_CONFIG" ]; then
        local freedom_settings="{}"
        is_ipv6_only && freedom_settings='{"domainStrategy": "UseIPv6"}'
        (
            umask 077
            cat << EOF > "$XRAY_CONFIG"
{
  "log": {"loglevel": "warning", "access": "none", "error": "$XRAY_ERROR_LOG"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct", "settings": $freedom_settings}, {"protocol": "blackhole", "tag": "blocked"}],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}]}
}
EOF
        )
    fi
    chmod 600 "$XRAY_CONFIG" 2>/dev/null || true
}

setup_service_units() {
    ensure_xray_user
    local first_install=0
    if [ "$INIT_TYPE" = "systemd" ]; then
        [ ! -f "$SYSTEMD_SERVICE" ] && first_install=1
        cat << EOF > "$SYSTEMD_SERVICE"
[Unit]
Description=${SERVICE_DESC}
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=xray
Group=xray
UMask=0077
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment="XRAY_LOCATION_ASSET=$XRAY_SHARE_DIR" "GODEBUG=multipathtcp=0"
ExecStart=$XRAY_BIN run -c $XRAY_CONFIG
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        [ "$first_install" -eq 1 ] && { systemctl enable xray >/dev/null 2>&1 || true; }
    elif [ "$INIT_TYPE" = "openrc" ]; then
        [ ! -f "$OPENRC_SERVICE" ] && first_install=1
        cat << EOF > "$OPENRC_SERVICE"
#!/sbin/openrc-run
name="xray"
description="${SERVICE_DESC}"
command="$XRAY_BIN"
command_args="run -c $XRAY_CONFIG"
command_user="xray:xray"
command_background="yes"
pidfile="$DAEMON_PID_FILE"
output_log="/dev/null"
error_log="$XRAY_ERROR_LOG"
export XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR"
export GODEBUG="multipathtcp=0"

depend() { need net; after firewall; }
start_pre() {
    checkpath -d -m 0750 -o xray:xray "$XRAY_LOG_DIR"
    checkpath -d -m 0700 -o xray:xray "$XRAY_CONFIG_DIR"
    checkpath -f -m 0640 -o xray:xray "$XRAY_ERROR_LOG"
}
EOF
        chmod +x "$OPENRC_SERVICE"
        [ "$first_install" -eq 1 ] && { rc-update add xray default >/dev/null 2>&1 || true; }
    fi
}

verify_zip_dgst() {
    local zip_file="$1" dgst_file="$2" expected actual
    expected=$(awk -F'= *' '/^SHA2-256=/{gsub(/[[:space:]]/, "", $2); print tolower($2); exit}' "$dgst_file" 2>/dev/null)
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$zip_file" 2>/dev/null | awk '{print tolower($1)}')
    else
        actual=$(openssl dgst -sha256 "$zip_file" 2>/dev/null | awk '{print tolower($NF)}')
    fi
    [ "$actual" = "$expected" ]
}

install_xray() {
    header
    echo -e "  ${C_BOLD}安装 / 更新 Xray 核心${C_RESET}\n"
    [ -z "$ARCH" ] && { log_error "不支持当前 CPU 架构: $(uname -m)"; pause; return 1; }

    log_info "查询官方最新版本..."
    local ver cur_ver
    ver=$(get_latest_xray_version)
    [ -z "$ver" ] && { log_error "获取最新版本失败，请检查 GitHub 网络连通性"; pause; return 1; }
    cur_ver=$(get_core_version || true)
    if [ -n "$cur_ver" ] && [ "$cur_ver" = "$ver" ]; then
        log_info "当前已是最新版本 (${C_CYAN}${ver}${C_RESET})"
        confirm "是否重新安装？" "n" || return 0
    else
        log_info "目标版本: ${C_CYAN}${ver}${C_RESET}${cur_ver:+ (当前: ${cur_ver})}"
    fi

    local base_url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${ARCH}.zip" tmp_dir
    [ -n "$GH_PROXY" ] && base_url="${GH_PROXY}${base_url}"
    tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'xray_inst.XXXXXX') || { log_error "创建临时目录失败"; pause; return 1; }
    mkdir -p "$XRAY_SHARE_DIR"

    log_info "下载核心包与 SHA-256 校验文件..."
    if ! curl -fsSL "$base_url" -o "$tmp_dir/xray.zip" || ! curl -fsSL "${base_url}.dgst" -o "$tmp_dir/xray.zip.dgst"; then
        log_error "下载失败，请检查网络或确认该版本提供 ${ARCH} 架构包"
        rm -rf "$tmp_dir"; pause; return 1
    fi

    log_info "校验安装包完整性..."
    if ! verify_zip_dgst "$tmp_dir/xray.zip" "$tmp_dir/xray.zip.dgst"; then
        log_error "SHA-256 校验未通过，已中止安装"
        rm -rf "$tmp_dir"; pause; return 1
    fi

    if ! unzip -q -o "$tmp_dir/xray.zip" -d "$tmp_dir" || [ ! -f "$tmp_dir/xray" ]; then
        log_error "解压核心组件失败"
        rm -rf "$tmp_dir"; pause; return 1
    fi

    local was_installed=0 was_running=0
    is_installed && was_installed=1
    is_running && { was_running=1; svc stop; }

    mkdir -p /usr/local/bin "$XRAY_SHARE_DIR"
    install -m 755 "$tmp_dir/xray" "$XRAY_BIN"
    ln -sf "$XRAY_BIN" "$XRAY_SHARE_DIR/xray-core" 2>/dev/null || true
    [ -f "$tmp_dir/geoip.dat" ] && install -m 644 "$tmp_dir/geoip.dat" "$XRAY_SHARE_DIR/"
    [ -f "$tmp_dir/geosite.dat" ] && install -m 644 "$tmp_dir/geosite.dat" "$XRAY_SHARE_DIR/"
    rm -rf "$tmp_dir"
    XRAY_VER=""

    check_mptcp_security
    init_config_if_needed
    setup_service_units
    setup_shortcut
    get_public_ip force

    log_success "核心安装完成 (${ver})"
    if [ "$was_installed" -eq 0 ] || [ "$was_running" -eq 1 ]; then
        service_ctrl restart || true
    else
        log_info "保持原有停止状态，未自动启动服务"
    fi
    pause
}

uninstall_xray() {
    header
    echo -e "  ${C_BOLD}卸载 Xray${C_RESET}\n"
    log_warn "将彻底删除 Xray 核心、全部节点配置、自签证书、日志及快捷命令 (xraym)"
    confirm "确认继续卸载？" "n" || { log_info "已取消"; sleep 0.6; return 0; }

    is_running && svc stop
    pkill -9 -x xray 2>/dev/null || pkill -9 -x xray-core 2>/dev/null || true

    if [ "$INIT_TYPE" = "systemd" ] && is_our_service "$SYSTEMD_SERVICE"; then
        systemctl disable xray >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE"
        rm -rf /etc/systemd/system/xray.service.d
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true
    elif [ "$INIT_TYPE" = "openrc" ] && is_our_service "$OPENRC_SERVICE"; then
        rc-update del xray default >/dev/null 2>&1 || true
        rc-update del xray >/dev/null 2>&1 || true
        rm -f "$OPENRC_SERVICE"
    fi

    rm -f "$XRAY_BIN"
    rm -rf "$XRAY_SHARE_DIR" "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"
    rm -f "$LOGROTATE_CONF" "$DAEMON_PID_FILE" "$SCRIPT_LINK"
    is_our_script "$LEGACY_SCRIPT_LINK" && rm -f "$LEGACY_SCRIPT_LINK"
    id -u xray >/dev/null 2>&1 && { userdel -r xray 2>/dev/null || deluser xray 2>/dev/null || true; }
    remove_dns64

    log_success "Xray 已彻底卸载"
    echo ""
    exit 0
}

rand_str()         { openssl rand -base64 "$(( ${1:-16} * 2 ))" | tr -dc 'a-zA-Z0-9' | head -c "${1:-16}"; }
base64_encode()    { printf '%s' "$1" | base64 | tr -d '\r\n'; }
base64url_encode() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\r\n'; }

rand_uuid() {
    [ -x "$XRAY_BIN" ] && "$XRAY_BIN" uuid 2>/dev/null && return
    [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
    openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

gen_default_cred() {
    case "$1" in
        vless|vmess) rand_uuid ;;
        shadowsocks)
            case "${2:-}" in
                2022-*-128-*) openssl rand -base64 16 ;;
                2022-*-256-*) openssl rand -base64 32 ;;
                *)            rand_str 16 ;;
            esac ;;
        socks) echo "user_$(rand_str 4):$(rand_str 10)" ;;
        *) rand_str 16 ;;
    esac
}

cred_label_of() {
    case "$1" in
        vless|vmess) echo "用户UUID" ;;
        shadowsocks)
            case "${2:-}" in
                2022-*-128-*) echo "密钥 PSK (16B Base64)" ;;
                2022-*-256-*) echo "密钥 PSK (32B Base64)" ;;
                *)            echo "连接密码" ;;
            esac ;;
        socks) echo "Socks 账密 (user:pass)" ;;
        *) echo "认证密码" ;;
    esac
}

gen_reality_keys() {
    local x_out
    x_out=$("$XRAY_BIN" x25519 2>/dev/null || true)
    REALITY_PRIV=$(printf '%s\n' "$x_out" | awk 'tolower($0) ~ /private/{print $NF; exit}')
    REALITY_PUB=$(printf '%s\n' "$x_out" | awk 'tolower($0) ~ /public|password/{print $NF; exit}')
    REALITY_SID=$(openssl rand -hex 8)
    [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ]
}

is_port_used() {
    local port="$1"
    [ -f "$XRAY_CONFIG" ] && jq -e --argjson p "$port" '.inbounds[]? | select(.port == $p)' "$XRAY_CONFIG" >/dev/null 2>&1 && return 0
    command -v ss >/dev/null 2>&1 && ss -tunl 2>/dev/null | grep -Eq "[:]$port([[:space:]]|$)" && return 0
    command -v netstat >/dev/null 2>&1 && netstat -tunl 2>/dev/null | grep -Eq "[:]$port([[:space:]]|$)" && return 0
    return 1
}

rand_port() {
    local p
    while true; do
        p=$(shuf -i 10000-60000 -n 1 2>/dev/null || awk 'BEGIN{srand(); print int(rand()*50000)+10000}')
        ! is_port_used "$p" && { echo "$p"; return; }
    done
}

ask_port() {
    local prompt="${1:-监听端口}" default_port="$2" current_port="$3" var_name="$4" p
    while true; do
        prompt_input "${prompt} (q 返回)" "$default_port" p
        is_cancel "$p" && return 1
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$((10#$p))" -ge 1 ] && [ "$((10#$p))" -le 65535 ]; then
            p="$((10#$p))"
            if [ "$p" != "$current_port" ] && is_port_used "$p"; then
                log_warn "端口 $p 已被占用"
                confirm "仍然强制使用该端口？" "n" && break
            else
                break
            fi
        else
            log_warn "端口范围需在 1-65535 之间"
        fi
    done
    printf -v "$var_name" '%s' "$p"
}

get_cert_sha256() {
    local crt="$1" fp
    [ -f "$crt" ] || return 1
    fp=$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print tolower($2)}' | tr -d ':[:space:]')
    [[ "$fp" =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$fp"
}

generate_self_signed_cert() {
    local domain="${1:-www.cloudflare.com}" safe_sni
    safe_sni=$(printf '%s' "$domain" | tr -c 'a-zA-Z0-9._-' '_')
    [ -z "$safe_sni" ] && safe_sni="default"
    mkdir -p "$XRAY_CERTS_DIR"
    chmod 700 "$XRAY_CERTS_DIR" 2>/dev/null || true

    CERT_CRT="$XRAY_CERTS_DIR/self_${safe_sni}.crt"
    CERT_KEY="$XRAY_CERTS_DIR/self_${safe_sni}.key"
    if [ ! -s "$CERT_CRT" ] || [ ! -s "$CERT_KEY" ]; then
        local args=(-x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 -keyout "$CERT_KEY" -out "$CERT_CRT" -subj "/CN=$domain")
        (
            umask 077
            openssl req "${args[@]}" -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1 ||
            openssl req "${args[@]}" >/dev/null 2>&1
        )
        chmod 600 "$CERT_KEY" 2>/dev/null || true
        chmod 644 "$CERT_CRT" 2>/dev/null || true
        chown xray:xray "$CERT_KEY" "$CERT_CRT" 2>/dev/null || true
    fi
    CERT_SHA256=$(get_cert_sha256 "$CERT_CRT" || true)
    [ -n "$CERT_SHA256" ]
}

request_acme_cert() {
    local domain="$1" safe_sni acme_bin="/root/.acme.sh/acme.sh"
    [ -z "$domain" ] && return 1
    safe_sni=$(printf '%s' "$domain" | tr -c 'a-zA-Z0-9._-' '_')
    [ -z "$safe_sni" ] && safe_sni="default"

    mkdir -p "$XRAY_CERTS_DIR"
    chmod 700 "$XRAY_CERTS_DIR" 2>/dev/null || true
    CERT_CRT="$XRAY_CERTS_DIR/acme_${safe_sni}.crt"
    CERT_KEY="$XRAY_CERTS_DIR/acme_${safe_sni}.key"

    if [ ! -x "$acme_bin" ]; then
        log_info "正在安装 ACME.sh 证书申请工具..."
        local acme_src="https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
        [ -n "$GH_PROXY" ] && acme_src="${GH_PROXY}${acme_src}"
        local tmp_acme
        tmp_acme=$(mktemp) || return 1
        if curl -fsSL --max-time 15 "$acme_src" -o "$tmp_acme" 2>/dev/null || wget -qO "$tmp_acme" "$acme_src" 2>/dev/null; then
            bash "$tmp_acme" --install --home /root/.acme.sh >/dev/null 2>&1 || true
        fi
        rm -f "$tmp_acme"
        [ -x "$acme_bin" ] || { log_error "ACME.sh 安装失败，请检查网络连接"; return 1; }
        "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    fi

    local port80_was_running=0
    if is_port_used 80; then
        if is_running; then
            log_info "临时停止 Xray 服务以释放 80 端口验证证书..."
            svc stop
            port80_was_running=1
        else
            log_warn "端口 80 已被其他程序占用，如验证失败请先停用占用 80 端口的服务"
        fi
    fi

    log_info "向 Let's Encrypt 申请 EC 证书 (${domain})..."
    local err_code=0 issue_out
    issue_out=$("$acme_bin" --issue -d "$domain" --standalone --keylength ec-256 --force 2>&1) || err_code=$?
    if [ $err_code -ne 0 ]; then
        log_error "证书申请失败"
        [ -n "$issue_out" ] && echo -e "${C_GRAY}${issue_out}${C_RESET}"
        if [ "$port80_was_running" -eq 1 ]; then svc start 2>/dev/null || true; fi
        return 1
    fi

    local reload_cmd="systemctl restart xray 2>/dev/null || rc-service xray restart 2>/dev/null || true"
    "$acme_bin" --install-cert -d "$domain" --ecc \
        --fullchain-file "$CERT_CRT" \
        --key-file "$CERT_KEY" \
        --reloadcmd "$reload_cmd" >/dev/null 2>&1

    if [ "$port80_was_running" -eq 1 ]; then svc start 2>/dev/null || true; fi

    if [ -s "$CERT_CRT" ] && [ -s "$CERT_KEY" ]; then
        chown xray:xray "$CERT_CRT" "$CERT_KEY" 2>/dev/null || true
        chmod 644 "$CERT_CRT" 2>/dev/null || true
        chmod 600 "$CERT_KEY" 2>/dev/null || true
        CERT_SHA256=$(get_cert_sha256 "$CERT_CRT" || true)
        log_success "证书申请与安装成功 (已配置自动续期)"
        return 0
    fi
    log_error "证书文件未生成"
    return 1
}

validate_and_apply_config() {
    local new_config="$1" tmp_dir tmp_cfg err_msg
    [ -z "$new_config" ] && { log_error "配置为空，已拒绝写入"; return 1; }
    mkdir -p "$XRAY_CONFIG_DIR"
    chmod 700 "$XRAY_CONFIG_DIR" 2>/dev/null || true

    tmp_dir=$(umask 077 && mktemp -d "$XRAY_CONFIG_DIR/.tmp.XXXXXX" 2>/dev/null) || {
        log_error "无法创建临时配置目录"
        return 1
    }
    tmp_cfg="$tmp_dir/config.json"
    printf '%s\n' "$new_config" > "$tmp_cfg"
    chmod 600 "$tmp_cfg" 2>/dev/null || true

    if err_msg=$("$XRAY_BIN" run -test -c "$tmp_cfg" 2>&1); then
        mv -f "$tmp_cfg" "$XRAY_CONFIG"
        rmdir "$tmp_dir" 2>/dev/null || rm -rf "$tmp_dir"
        chown -R xray:xray "$XRAY_CONFIG_DIR" 2>/dev/null || true
        chmod 600 "$XRAY_CONFIG" 2>/dev/null || true
        if is_running; then
            service_ctrl restart || return 1
        else
            log_info "配置已保存 (服务未运行，未自动拉起)"
        fi
        return 0
    fi
    rm -rf "$tmp_dir"
    log_error "Xray 配置校验未通过，原配置未改动"
    [ -n "$err_msg" ] && echo -e "${C_GRAY}${err_msg}${C_RESET}"
    return 1
}

add_node_wizard() {
    local replace_idx="${1:-}" cur_port=""
    header
    ! is_installed && { log_warn "请先安装 Xray 核心 (菜单 9)"; pause; return 1; }
    init_config_if_needed

    if [ -n "$replace_idx" ]; then
        cur_port=$(jq -r ".inbounds[$replace_idx].port // empty" "$XRAY_CONFIG" 2>/dev/null)
        echo -e "  ${C_BOLD}重新配置节点${C_RESET} ${C_GRAY}(输入 q 可随时取消返回，原节点不受影响)${C_RESET}\n"
    else
        echo -e "  ${C_BOLD}添加入站节点${C_RESET} ${C_GRAY}(输入 q 可随时取消返回)${C_RESET}\n"
    fi

    local p_sel="" t_sel="" s_sel="" sm_sel="" c_sel=""
    prompt_choice "选择代理协议" "1" p_sel \
        "VLESS        REALITY / Vision / xhttp (推荐)" \
        "Hysteria 2   QUIC 高速抗丢包 (弱网首选)" \
        "Trojan       TLS 伪装 (自备域名)" \
        "Shadowsocks  2022 / AEAD (原生 TCP+UDP)" \
        "VMess        经典协议 (CDN 反代)" \
        "Socks        标准 Socks5 (链式代理/内网)" || return 1

    local protos=("" vless hysteria trojan shadowsocks vmess socks)
    local protocol="${protos[$p_sel]}" transport="raw" security="none"
    local path="" service_name="" sni="" pbk="" priv_key="" short_id=""
    local cert_file="" key_file="" insecure="0" cert_sha256="" ss_method="" cred="" flow=""

    case "$protocol" in
        vless)
            local v_trans=("" xhttp raw grpc ws)
            prompt_choice "选择传输方式" "1" t_sel \
                "XHTTP      流式分片 (兼顾直连与反代，首选)" \
                "RAW        原生直连 (原 TCP 架构，搭配 Vision 极速)" \
                "gRPC       gRPC (HTTP/2 多路复用)" \
                "WebSocket  WS 协议 (CDN 反代兼容)" || return 1
            transport="${v_trans[$t_sel]}"
            if [ "$transport" = "ws" ]; then
                local ws_sec=("" none tls)
                prompt_choice "选择安全加密" "1" s_sel \
                    "None  明文传输 (CDN 节点卸载 TLS)" \
                    "TLS   标准证书加密" || return 1
                security="${ws_sec[$s_sel]}"
            else
                local v_sec=("" reality tls none)
                prompt_choice "选择安全加密" "1" s_sel \
                    "REALITY  免证书 TLS 伪装 (推荐)" \
                    "TLS      标准证书加密" \
                    "None     明文传输 (前置反代)" || return 1
                security="${v_sec[$s_sel]}"
            fi ;;
        hysteria)
            transport="hysteria"; security="tls" ;;
        trojan)
            local tr_trans=("" raw ws grpc xhttp)
            prompt_choice "选择传输方式" "1" t_sel \
                "RAW        原生直连 (原 TCP 标准模式)" \
                "WebSocket  WS 协议 (适合 CDN 反代)" \
                "gRPC       gRPC (HTTP/2 多路复用)" \
                "XHTTP      流式分片传输" || return 1
            transport="${tr_trans[$t_sel]}"; security="tls" ;;
        shadowsocks)
            local ss_methods=("" 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm aes-128-gcm aes-256-gcm chacha20-ietf-poly1305)
            prompt_choice "选择加密算法" "1" sm_sel \
                "2022-blake3-aes-128-gcm  SS2022 128 位 (推荐)" \
                "2022-blake3-aes-256-gcm  SS2022 256 位" \
                "aes-128-gcm              传统 AEAD 128" \
                "aes-256-gcm              传统 AEAD 256" \
                "chacha20-ietf-poly1305   ChaCha20 (移动端友好)" || return 1
            ss_method="${ss_methods[$sm_sel]}" ;;
        vmess)
            local m_trans=("" ws grpc xhttp raw) m_sec=("" none tls)
            prompt_choice "选择传输方式" "1" t_sel \
                "WebSocket  WS 协议 (CDN 反代首选)" \
                "gRPC       gRPC (HTTP/2 多路复用)" \
                "XHTTP      流式分片传输" \
                "RAW        原生直连 (原 TCP)" || return 1
            transport="${m_trans[$t_sel]}"
            prompt_choice "选择安全加密" "1" s_sel \
                "None  明文传输 (CDN 反代)" \
                "TLS   标准证书加密" || return 1
            security="${m_sec[$s_sel]}" ;;
        socks)
            local auth_sel=""
            prompt_choice "选择认证方式" "1" auth_sel \
                "密码认证  需用户名和密码 (推荐)" \
                "免密模式  无需认证直接连接" || return 1
            if [ "$auth_sel" = "1" ]; then
                local s_user s_pass
                prompt_input "Socks 用户名" "user_$(rand_str 4)" s_user
                prompt_input "Socks 密码" "$(rand_str 12)" s_pass
                cred="${s_user}:${s_pass}"
            else
                cred=""
            fi
            transport="raw"; security="none" ;;
    esac

    local def_port="443" port=""
    if [ -n "$cur_port" ]; then
        def_port="$cur_port"
    else
        case "$protocol" in
            shadowsocks) def_port=$(rand_port) ;;
            socks)       def_port="1080" ;;
            hysteria)    def_port="8443" ;;
            *)           [ "$security" = "none" ] && def_port="80" ;;
        esac
        is_port_used "$def_port" && def_port=$(rand_port)
    fi
    ask_port "监听端口" "$def_port" "$cur_port" port || return 1

    [ "$protocol" != "socks" ] && prompt_input "$(cred_label_of "$protocol" "$ss_method")" "$(gen_default_cred "$protocol" "$ss_method")" cred

    if [ "$transport" = "xhttp" ] || [ "$transport" = "ws" ]; then
        prompt_input "分流路径" "/$(rand_str 8)" path
        [[ "$path" != /* ]] && path="/$path"
        [ "$security" = "none" ] && prompt_input "伪装域名 / Host (留空跳过)" "" sni
    elif [ "$transport" = "grpc" ]; then
        prompt_input "gRPC serviceName" "grpc-$(rand_str 6)" service_name
    fi

    if [ "$security" = "reality" ]; then
        prompt_input "REALITY 目标域名 (SNI)" "addons.mozilla.org" sni
        gen_reality_keys || { log_error "生成 x25519 密钥对失败"; pause; return 1; }
        priv_key="$REALITY_PRIV" pbk="$REALITY_PUB" short_id="$REALITY_SID"
    elif [ "$security" = "tls" ]; then
        prompt_choice "选择 TLS 证书方式" "1" c_sel \
            "自签 EC 证书  按 SNI 自动签发并固定 SHA-256 指纹 (免域名)" \
            "ACME 自动申请 自动申请 Let's Encrypt 证书 (需域名已解析)" \
            "自备正式证书  指定本地 .crt/.pem 与 .key 文件路径" || return 1
        if [ "$c_sel" = "1" ]; then
            prompt_input "证书域名 (SNI)" "www.cloudflare.com" sni
            generate_self_signed_cert "$sni" || { log_error "签发自签名证书失败"; pause; return 1; }
            cert_file="$CERT_CRT" key_file="$CERT_KEY" cert_sha256="$CERT_SHA256" insecure="1"
        elif [ "$c_sel" = "2" ]; then
            prompt_input "解析到本机的域名 (SNI)" "example.com" sni
            request_acme_cert "$sni" || { pause; return 1; }
            cert_file="$CERT_CRT" key_file="$CERT_KEY" cert_sha256="" insecure="0"
        else
            prompt_input "证书域名 (SNI)" "example.com" sni
            while true; do
                prompt_input "证书文件路径 (.crt/.pem)" "/root/cert.crt" cert_file
                prompt_input "私钥文件路径 (.key)" "/root/private.key" key_file
                [ -f "$cert_file" ] && [ -f "$key_file" ] && break
                log_warn "证书或私钥文件不存在"
                confirm "重新输入文件路径？" "y" || return 1
            done
        fi
    fi
    [ "$protocol" = "vless" ] && [ "$transport" = "raw" ] && [ "$security" != "none" ] && flow="xtls-rprx-vision"

    local remark listen_addr="::" inbound_obj new_config detail_idx reality_target="$sni"
    prompt_input "节点备注" "${protocol^^}-${transport^^}-${port}" remark
    [ ! -f /proc/net/if_inet6 ] && listen_addr="0.0.0.0"
    [ -n "$reality_target" ] && [[ "$reality_target" != *:* ]] && reality_target="${reality_target}:443"

    inbound_obj=$(jq -c -n \
        --arg tag "${protocol}-${port}" --argjson port "$port" --arg listen "$listen_addr" --arg proto "$protocol" \
        --arg cred "$cred" --arg method "$ss_method" --arg flow "$flow" \
        --arg net "$transport" --arg path "$path" --arg svc "$service_name" --arg sec "$security" \
        --arg target "$reality_target" --arg sni "$sni" --arg pk "$priv_key" --arg pbk "$pbk" --arg sid "$short_id" \
        --arg crt "$cert_file" --arg key "$key_file" --arg insec "$insecure" --arg pcs "$cert_sha256" --arg rmk "$remark" \
        '{
            tag: $tag, port: $port, listen: $listen, protocol: $proto,
            settings: (
                if $proto == "vless" then {users: ([{id: $cred} + (if $flow != "" then {flow: $flow} else {} end)]), decryption: "none"}
                elif $proto == "vmess" then {users: [{id: $cred}]}
                elif $proto == "trojan" then {users: [{password: $cred}]}
                elif $proto == "shadowsocks" then {network: "tcp,udp", method: $method, password: $cred}
                elif $proto == "socks" then (if $cred != "" then {auth: "password", accounts: [{user: ($cred|split(":")[0]), pass: ($cred|split(":")[1] // "")}], udp: true} else {auth: "noauth", udp: true} end)
                else {version: 2, users: [{auth: $cred}]} end
            ),
            streamSettings: (
                {network: $net}
                + (if $net == "xhttp" then {xhttpSettings: ({path: $path} + (if $sni != "" then {host: $sni} else {} end))}
                   elif $net == "ws" then {wsSettings: ({path: $path} + (if $sni != "" then {host: $sni} else {} end))}
                   elif $net == "grpc" then {grpcSettings: {serviceName: $svc}}
                   elif $net == "hysteria" then {hysteriaSettings: {version: 2}}
                   else {} end)
                + (if $sec == "reality" then {security: "reality", realitySettings: {show: false, target: $target, xver: 0, serverNames: [$sni], privateKey: $pk, shortIds: [$sid]}}
                   elif $sec == "tls" then {
                       security: "tls",
                       tlsSettings: ({certificates: [{certificateFile: $crt, keyFile: $key}]}
                           + (if $net == "hysteria" then {alpn: ["h3"]}
                              elif $net == "grpc" then {alpn: ["h2"]}
                              elif $net == "ws" then {alpn: ["http/1.1"]}
                              else {alpn: ["h2", "http/1.1"]} end))
                   }
                   else {} end)
            ),
            sniffing: (if $proto == "shadowsocks" or $proto == "hysteria" or $proto == "socks" then null else {enabled: true, destOverride: ["http", "tls", "quic"]} end),
            _meta: ({remark: $rmk, sni: $sni, publicKey: $pbk, insecure: $insec, certSha256: $pcs} | with_entries(select(.value != "" and .value != "0")))
        } | del(.sniffing | nulls)')

    if [ -n "$replace_idx" ]; then
        new_config=$(jq --argjson idx "$replace_idx" --argjson inb "$inbound_obj" '.inbounds[$idx] = $inb' "$XRAY_CONFIG")
        detail_idx="$replace_idx"
    else
        new_config=$(jq --argjson inb "$inbound_obj" '.inbounds += [$inb]' "$XRAY_CONFIG")
    fi

    log_info "正在校验并应用配置..."
    if validate_and_apply_config "$new_config"; then
        log_success "节点已保存生效"
        [ -z "$replace_idx" ] && detail_idx="$(( $(get_node_count) - 1 ))"
        view_node_detail "$detail_idx"
        return 0
    fi
    pause
    return 1
}

parse_node_meta() {
    local _m=()
    mapfile -t _m < <(printf '%s\n' "$1" | jq -r '
        ((.settings.accounts // .settings.users // .settings.clients // [{}])[0]) as $u | [
            (.port | tostring),
            .protocol,
            (.streamSettings.network // .streamSettings.method // "raw"),
            (.streamSettings.security // "none"),
            (._meta.remark // .tag // "Node"),
            (.streamSettings.xhttpSettings.path // .streamSettings.wsSettings.path // ._meta.path // ""),
            (.streamSettings.grpcSettings.serviceName // ._meta.serviceName // ""),
            (._meta.sni // .streamSettings.realitySettings.serverNames[0] // .streamSettings.tlsSettings.serverName // .streamSettings.xhttpSettings.host // .streamSettings.wsSettings.host // ""),
            (._meta.publicKey // ""),
            (.streamSettings.realitySettings.shortIds[0] // ._meta.shortId // ""),
            (._meta.insecure // "0"),
            (._meta.certSha256 // ""),
            ($u.flow // ._meta.flow // ""),
            ($u.id // $u.password // $u.auth // (if $u.user then ($u.user + ":" + ($u.pass // "")) else null end) // .settings.password // ""),
            (._meta.address // ""),
            (.settings.method // ._meta.method // ""),
            (.streamSettings.tlsSettings.certificates[0].certificateFile // "")
        ] | map(tostring | gsub("[\r\n]"; "")) | .[]')

    NODE_PORT="${_m[0]:-}"   NODE_PROTO="${_m[1]:-}"  NODE_TRANS="${_m[2]:-}"  NODE_SEC="${_m[3]:-}"
    NODE_RMK="${_m[4]:-}"    NODE_PATH="${_m[5]:-}"   NODE_SVC="${_m[6]:-}"    NODE_SNI="${_m[7]:-}"
    NODE_PBK="${_m[8]:-}"    NODE_SID="${_m[9]:-}"    NODE_INSEC="${_m[10]:-}" NODE_PCS="${_m[11]:-}"
    NODE_FLOW="${_m[12]:-}"  NODE_CRED="${_m[13]:-}"  NODE_ADDR="${_m[14]:-}"  NODE_METHOD="${_m[15]:-}"

    if [ "$NODE_SEC" = "tls" ] && [ "$NODE_INSEC" = "1" ] && [ -z "$NODE_PCS" ] && [ -n "${_m[16]:-}" ]; then
        NODE_PCS=$(get_cert_sha256 "${_m[16]}" || true)
    fi
}

get_connect_host() {
    [ -n "$NODE_ADDR" ] && { format_url_host "$NODE_ADDR"; return; }
    [ "$NODE_SEC" = "tls" ] && [ -n "$NODE_SNI" ] && [ "$NODE_INSEC" != "1" ] && { echo "$NODE_SNI"; return; }
    [ "$NODE_SEC" = "none" ] && [ -n "$NODE_SNI" ] && { echo "$NODE_SNI"; return; }
    [ -z "$SERVER_IP" ] && get_public_ip
    format_url_host "${SERVER_IP:-127.0.0.1}"
}

build_share_link() {
    local target_host="${1:-}" connect_host link="" trans_q="" _e=()
    if [ -n "$target_host" ]; then connect_host=$(format_url_host "$target_host")
    else connect_host=$(get_connect_host); fi

    mapfile -t _e < <(jq -rn \
        --arg rmk "$NODE_RMK" --arg path "$NODE_PATH" --arg cred "$NODE_CRED" \
        --arg sni "$NODE_SNI" --arg svc "$NODE_SVC" --arg pbk "$NODE_PBK" \
        --arg sid "$NODE_SID" --arg pcs "$NODE_PCS" --arg flow "$NODE_FLOW" \
        '[($rmk|@uri), (($path|@uri)|gsub("%2F";"/")), ($cred|@uri), ($sni|@uri), ($svc|@uri), ($pbk|@uri), ($sid|@uri), ($pcs|@uri), ($flow|@uri)] | .[]')

    local enc_rmk="${_e[0]}" enc_path="${_e[1]}" enc_cred="${_e[2]}" enc_sni="${_e[3]}" enc_svc="${_e[4]}"
    local enc_pbk="${_e[5]}" enc_sid="${_e[6]}" enc_pcs="${_e[7]}" enc_flow="${_e[8]}"
    local link_trans="$NODE_TRANS"
    [ "$link_trans" = "raw" ] && link_trans="tcp"

    case "$NODE_TRANS" in
        xhttp)   trans_q="&path=${enc_path}&mode=auto${NODE_SNI:+&host=${enc_sni}}" ;;
        ws)      trans_q="&path=${enc_path}${NODE_SNI:+&host=${enc_sni}}" ;;
        grpc)    trans_q="&serviceName=${enc_svc}&mode=gun" ;;
        raw)     [ -n "$NODE_FLOW" ] && trans_q="&flow=${enc_flow}" ;;
    esac

    case "$NODE_PROTO" in
        vless)
            link="vless://${enc_cred}@${connect_host}:${NODE_PORT}?type=${link_trans}&encryption=none&security=${NODE_SEC}"
            [ "$NODE_SEC" = "reality" ] && link="${link}&pbk=${enc_pbk}&fp=chrome&sni=${enc_sni}&sid=${enc_sid}"
            [ "$NODE_SEC" = "tls" ] && link="${link}&fp=chrome&sni=${enc_sni}${NODE_PCS:+&pcs=${enc_pcs}}"
            link="${link}${trans_q}#${enc_rmk}" ;;
        trojan)
            link="trojan://${enc_cred}@${connect_host}:${NODE_PORT}?security=${NODE_SEC}&sni=${enc_sni}&type=${link_trans}${NODE_PCS:+&pcs=${enc_pcs}}${trans_q/&mode=gun/}#${enc_rmk}" ;;
        vmess)
            local tls_flag="" v_path="$NODE_PATH" vjson
            [ "$NODE_SEC" = "tls" ] && tls_flag="tls"
            [ "$NODE_TRANS" = "grpc" ] && v_path="$NODE_SVC"
            vjson=$(jq -c -n \
                --arg ps "$NODE_RMK" --arg add "${connect_host//[\[\]]/}" --argjson port "$NODE_PORT" \
                --arg id "$NODE_CRED" --arg net "$link_trans" --arg host "$NODE_SNI" \
                --arg path "$v_path" --arg tls "$tls_flag" --arg pcs "$NODE_PCS" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:0, scy:"auto", net:$net, type:"none", host:$host, path:$path, tls:$tls, sni:(if $tls == "tls" then $host else "" end), fp:(if $tls == "tls" then "chrome" else "" end)} + (if $pcs != "" then {pcs:$pcs} else {} end)')
            link="vmess://$(base64_encode "$vjson")" ;;
        shadowsocks)
            link="ss://$(base64url_encode "${NODE_METHOD}:${NODE_CRED}")@${connect_host}:${NODE_PORT}#${enc_rmk}" ;;
        hysteria)
            local hy_extra=""
            [ "$NODE_INSEC" = "1" ] && hy_extra="&insecure=1"
            [ -n "$NODE_PCS" ] && hy_extra="${hy_extra}&pinSHA256=${enc_pcs}&pcs=${enc_pcs}"
            link="hysteria2://${enc_cred}@${connect_host}:${NODE_PORT}/?sni=${enc_sni}${hy_extra}#${enc_rmk}" ;;
        socks)
            if [ -n "$NODE_CRED" ]; then
                local s_user="${NODE_CRED%%:*}" s_pass="${NODE_CRED#*:}" s_auth
                s_auth=$(jq -rn --arg u "$s_user" --arg p "$s_pass" '($u|@uri) + ":" + ($p|@uri)')
                link="socks5://${s_auth}@${connect_host}:${NODE_PORT}#${enc_rmk}"
            else
                link="socks5://${connect_host}:${NODE_PORT}#${enc_rmk}"
            fi ;;
    esac
    echo "$link"
}

print_share_link() {
    local label="$1" host="${2:-}" link
    link=$(build_share_link "$host")
    echo -e "  ${C_BOLD}${label}${C_RESET}\n  ${C_CYAN}${link}${C_RESET}"
    [ "$NODE_PROTO" = "hysteria" ] && echo -e "  ${C_GRAY}兼容格式 (hy2://)${C_RESET}\n  ${C_CYAN}${link/hysteria2:\/\//hy2:\/\/}${C_RESET}"
    if [ "$NODE_PROTO" = "socks" ]; then
        local tg_host="${host:-}" tg_user="" tg_pass=""
        [ -z "$tg_host" ] && tg_host=$(get_connect_host)
        tg_host="${tg_host//[\[\]]/}"
        if [ -n "$NODE_CRED" ]; then
            tg_user="${NODE_CRED%%:*}" tg_pass="${NODE_CRED#*:}"
            echo -e "  ${C_GRAY}Telegram 直连格式 (tg://socks)${C_RESET}\n  ${C_CYAN}tg://socks?server=${tg_host}&port=${NODE_PORT}&user=${tg_user}&pass=${tg_pass}${C_RESET}"
        else
            echo -e "  ${C_GRAY}Telegram 直连格式 (tg://socks)${C_RESET}\n  ${C_CYAN}tg://socks?server=${tg_host}&port=${NODE_PORT}${C_RESET}"
        fi
    fi
}

print_outbound_json() {
    printf '%s\n' "$1" | jq \
        --arg ip "${2//[\[\]]/}" --arg cred "$NODE_CRED" --arg flow "$NODE_FLOW" \
        --arg method "$NODE_METHOD" --arg pbk "$NODE_PBK" --arg sid "$NODE_SID" \
        --arg sni "$NODE_SNI" --arg pcs "$NODE_PCS" \
        '{
            tag: ("proxy-" + .protocol), protocol: .protocol,
            settings: (
                if .protocol == "vless" then {vnext: [{address: $ip, port: .port, users: ([{id: $cred, encryption: "none"} + (if $flow != "" then {flow: $flow} else {} end)])}]}
                elif .protocol == "vmess" then {vnext: [{address: $ip, port: .port, users: [{id: $cred, alterId: 0, security: "auto"}]}]}
                elif .protocol == "trojan" then {servers: [{address: $ip, port: .port, password: $cred}]}
                elif .protocol == "shadowsocks" then {servers: [{address: $ip, port: .port, method: $method, password: $cred}]}
                elif .protocol == "hysteria" then {version: 2, address: $ip, port: .port}
                elif .protocol == "socks" then {servers: [{address: $ip, port: .port} + (if $cred != "" then {users: [{user: ($cred|split(":")[0]), pass: ($cred|split(":")[1] // "")}]} else {} end)]}
                else .settings end
            ),
            streamSettings: (.streamSettings |
                if .security == "reality" then .realitySettings = {serverName: $sni, fingerprint: "chrome", show: false, publicKey: $pbk, shortId: $sid}
                elif .security == "tls" then .tlsSettings = (
                    {serverName: $sni}
                    + (if .network == "hysteria" then {alpn: ["h3"]}
                       elif .network == "grpc" then {alpn: ["h2"], fingerprint: "chrome"}
                       elif .network == "ws" then {alpn: ["http/1.1"], fingerprint: "chrome"}
                       else {alpn: ["h2", "http/1.1"], fingerprint: "chrome"} end)
                    + (if $pcs != "" then {pinnedPeerCertSha256: $pcs} else {} end)
                )
                else . end |
                if .network == "hysteria" then .hysteriaSettings = {version: 2, auth: $cred}
                elif .network == "xhttp" then .xhttpSettings += {mode: "auto", xmux: {maxConcurrency: 16}}
                else . end
            )
        }'
}

delete_node_by_idx() {
    local idx="$1" node new_cfg
    node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG" 2>/dev/null)
    [ -z "$node" ] || [ "$node" = "null" ] && return 1
    parse_node_meta "$node"
    confirm "确认删除节点 [${NODE_RMK}] (端口 ${NODE_PORT})？" "n" || { log_info "已取消"; sleep 0.6; return 1; }
    new_cfg=$(jq --argjson idx "$idx" 'del(.inbounds[$idx])' "$XRAY_CONFIG")
    if validate_and_apply_config "$new_cfg"; then
        log_success "节点已删除"
        sleep 0.8
        return 0
    fi
    pause
    return 1
}

view_node_detail() {
    local idx="$1" node connect_host opt
    while true; do
        node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG" 2>/dev/null)
        [ -z "$node" ] || [ "$node" = "null" ] && { log_warn "节点不存在或已删除"; sleep 0.8; return; }

        parse_node_meta "$node"
        connect_host=$(get_connect_host)

        header
        echo -e "  ${C_BOLD}节点详情${C_RESET}  ${C_CYAN}${NODE_RMK}${C_RESET}\n"
        printf "  ${C_GRAY}协议组合${C_RESET}  %s · %s · %s%s\n" \
            "${NODE_PROTO^^}" "${NODE_TRANS^^}" "${NODE_SEC^^}" "${NODE_FLOW:+ (${NODE_FLOW})}"
        printf "  ${C_GRAY}连接地址${C_RESET}  %s:%s\n" "$connect_host" "$NODE_PORT"
        [ "$NODE_PROTO" = "shadowsocks" ] && printf "  ${C_GRAY}加密算法${C_RESET}  %s\n" "$NODE_METHOD"
        printf "  ${C_GRAY}%s${C_RESET}  %s\n" "$(cred_label_of "$NODE_PROTO")" "$NODE_CRED"

        [ -n "$NODE_PATH" ] && printf "  ${C_GRAY}分流路径${C_RESET}  %s\n" "$NODE_PATH"
        [ -n "$NODE_SVC" ]  && printf "  ${C_GRAY}服务名称${C_RESET}  %s\n" "$NODE_SVC"
        [ -n "$NODE_SNI" ]  && printf "  ${C_GRAY}域名 SNI${C_RESET}  %s\n" "$NODE_SNI"
        [ -n "$NODE_PBK" ]  && printf "  ${C_GRAY}公钥 PBK${C_RESET}  %s\n" "$NODE_PBK"
        [ -n "$NODE_SID" ]  && printf "  ${C_GRAY}Short ID${C_RESET}  %s\n" "$NODE_SID"
        [ -n "$NODE_PCS" ]  && printf "  ${C_GRAY}证书指纹${C_RESET}  %s\n" "$NODE_PCS"

        echo ""
        if [ "$connect_host" != "$SERVER_IP" ] && [ "$connect_host" != "[$SERVER_IP]" ]; then
            print_share_link "分享链接"
        elif [ -n "$SERVER_IPV4" ] && [ -n "$SERVER_IPV6" ]; then
            print_share_link "分享链接 (IPv4)" "$SERVER_IPV4"
            echo ""
            print_share_link "分享链接 (IPv6)" "$SERVER_IPV6"
        else
            print_share_link "分享链接"
        fi

        echo ""
        echo -e "  ${C_CYAN}1.${C_RESET} 客户端 JSON    ${C_CYAN}2.${C_RESET} 修改节点    ${C_CYAN}3.${C_RESET} 删除节点    ${C_GRAY}0. 返回 (回车)${C_RESET}"
        read -rp "  › 请选择 [回车返回]: " opt || return 0
        [ -z "$opt" ] || is_cancel "$opt" && return 0
        case "$opt" in
            1) echo ""; echo -e "  ${C_BOLD}客户端 Outbound 配置${C_RESET}"; print_outbound_json "$node" "$connect_host"; pause ;;
            2) edit_single_node "$idx" ;;
            3) delete_node_by_idx "$idx" && return 0 ;;
            *) log_warn "请输入 1-3，或按回车返回"; sleep 0.8 ;;
        esac
    done
}

render_node_table() {
    echo ""
    printf "  ${C_GRAY}%-4s %-14s %-8s %-12s %-12s %s${C_RESET}\n\n" "#" "协议" "端口" "传输" "安全" "备注"
    local i=1 p_port p_proto p_trans p_sec p_rmk has_node=0
    while IFS='|' read -r p_port p_proto p_trans p_sec p_rmk; do
        [ -z "$p_port" ] && continue
        has_node=1
        local d_proto="${p_proto^^}" d_trans="${p_trans^^}" d_sec="${p_sec^^}" s_color="$C_GRAY"
        [ "$d_proto" = "HYSTERIA" ] && d_proto="HYSTERIA 2"
        [ "$d_trans" = "WS" ] && d_trans="WEBSOCKET"

        if [ "$d_sec" = "REALITY" ] || [ "$d_sec" = "TLS" ]; then
            s_color="$C_GREEN"
        elif [[ "$d_sec" == *128* ]]; then
            d_sec="2022-128"
            s_color="$C_CYAN"
        elif [[ "$d_sec" == *256* ]]; then
            d_sec="2022-256"
            s_color="$C_CYAN"
        elif [[ "$d_sec" == *CHACHA* ]]; then
            d_sec="CHACHA20"
            s_color="$C_CYAN"
        elif [ "$d_sec" = "NONE" ] || [ -z "$d_sec" ]; then
            d_sec="NONE"
            s_color="$C_GRAY"
        else
            d_sec="${d_sec:0:10}"
        fi

        printf "  ${C_CYAN}%-4s${C_RESET} ${C_BOLD}%-12s${C_RESET} %-6s %-10s ${s_color}%-10s${C_RESET} %s\n" \
            "$i" "$d_proto" "$p_port" "$d_trans" "$d_sec" "$p_rmk"
        i=$((i + 1))
    done < <(jq -r '.inbounds[]? | "\(.port)|\(.protocol)|\(.streamSettings.network // .streamSettings.method // "raw")|\(.settings.method // .streamSettings.security // "none")|\(._meta.remark // .tag // "Node")"' "$XRAY_CONFIG" 2>/dev/null)
    [ "$has_node" -eq 0 ] && echo -e "  ${C_GRAY}(当前暂无入站节点)${C_RESET}"
    echo ""
}

node_menu_loop() {
    local title="$1" prompt_hint="$2" handler="$3" count sel
    while true; do
        header
        ! is_installed && { log_warn "请先安装 Xray 核心 (菜单 9)"; pause; return; }
        count=$(get_node_count)
        [ "$count" -eq 0 ] && { log_warn "当前暂无入站节点"; pause; return; }

        echo -e "  ${C_BOLD}${title}${C_RESET} ${C_GRAY}(共 ${count} 个节点)${C_RESET}"
        render_node_table
        read -rp "  › ${prompt_hint} [1-${count}, 回车返回]: " sel || return
        [ -z "$sel" ] || is_cancel "$sel" && return

        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$count" ]; then
            "$handler" "$((sel - 1))"
        else
            log_warn "请输入 1-${count} 之间的编号" && sleep 0.8
        fi
    done
}

edit_single_node() {
    local idx="$1" node=""
    node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG" 2>/dev/null)
    [ -z "$node" ] || [ "$node" = "null" ] && { log_error "节点不存在"; pause; return; }
    parse_node_meta "$node"

    while true; do
        local connect_host cred_label short_cred="认证密码" mod_opt i
        connect_host=$(get_connect_host)
        cred_label=$(cred_label_of "$NODE_PROTO" "$NODE_METHOD")
        case "$NODE_PROTO" in
            vless|vmess) short_cred="用户UUID" ;;
            shadowsocks) [[ "$NODE_METHOD" == 2022-* ]] && short_cred="密钥 PSK" || short_cred="连接密码" ;;
            socks)       short_cred="Socks账密" ;;
        esac

        local actions=("port" "cred") labels=(
            "监听端口      ${C_GRAY}${NODE_PORT}${C_RESET}"
            "${short_cred}      ${C_GRAY}${NODE_CRED:0:16}...${C_RESET}"
        )
        if [ "$NODE_TRANS" = "xhttp" ] || [ "$NODE_TRANS" = "ws" ]; then
            actions+=("path"); labels+=("分流路径      ${C_GRAY}${NODE_PATH}${C_RESET}")
        elif [ "$NODE_TRANS" = "grpc" ]; then
            actions+=("svc");  labels+=("服务名称      ${C_GRAY}${NODE_SVC}${C_RESET}")
        fi
        if [ "$NODE_SEC" = "reality" ] || [ "$NODE_SEC" = "tls" ] || [ "$NODE_TRANS" = "ws" ] || [ "$NODE_TRANS" = "xhttp" ]; then
            actions+=("sni");  labels+=("域名 SNI      ${C_GRAY}${NODE_SNI:-未设置}${C_RESET}")
        fi
        [ "$NODE_SEC" = "reality" ] && { actions+=("keys"); labels+=("重置密钥      ${C_GRAY}重新生成 REALITY 密钥与 ShortId${C_RESET}"); }
        actions+=("rmk" "addr" "reconf")
        labels+=(
            "节点备注      ${C_GRAY}${NODE_RMK}${C_RESET}"
            "连接地址      ${C_GRAY}${NODE_ADDR:-自动 (${connect_host})}${C_RESET}"
            "重新配置      ${C_GRAY}向导完成后原子替换${C_RESET}"
        )

        local total="${#actions[@]}"
        header
        echo -e "  ${C_BOLD}修改节点${C_RESET}  ${C_CYAN}${NODE_RMK}${C_RESET} ${C_GRAY}(${NODE_PROTO^^} · ${NODE_PORT})${C_RESET}\n"
        for (( i = 0; i < total; i++ )); do
            echo -e "  ${C_CYAN}$((i + 1)).${C_RESET} ${labels[$i]}"
        done
        echo ""
        read -rp "  › 请选择修改项 [1-${total}, 回车返回]: " mod_opt || break
        [ -z "$mod_opt" ] || is_cancel "$mod_opt" && break
        if ! [[ "$mod_opt" =~ ^[0-9]+$ ]] || [ "$mod_opt" -lt 1 ] || [ "$mod_opt" -gt "$total" ]; then
            log_warn "请输入 1-${total}" && sleep 0.8 && continue
        fi

        local up_inb="" msg=""
        case "${actions[$((mod_opt - 1))]}" in
            port)
                local new_port=""
                ask_port "新监听端口" "$NODE_PORT" "$NODE_PORT" new_port || continue
                [ "$new_port" != "$NODE_PORT" ] && {
                    up_inb=$(printf '%s\n' "$node" | jq --argjson p "$new_port" '.port = $p | .tag = (.protocol + "-" + ($p|tostring))')
                    msg="监听端口已更新为 $new_port"
                } ;;
            cred)
                local new_cred=""
                prompt_input "${cred_label} (输入 r 随机重置)" "$NODE_CRED" new_cred
                [ "$new_cred" = "r" ] && new_cred=$(gen_default_cred "$NODE_PROTO" "$NODE_METHOD")
                [ -n "$new_cred" ] && [ "$new_cred" != "$NODE_CRED" ] && {
                    up_inb=$(printf '%s\n' "$node" | jq --arg v "$new_cred" '
                        if .protocol == "shadowsocks" then .settings.password = $v
                        elif .protocol == "socks" then (if $v != "" then .settings.auth = "password" | .settings.accounts = [{user: ($v|split(":")[0]), pass: ($v|split(":")[1] // "")}] else .settings.auth = "noauth" | del(.settings.accounts, .settings.users) end)
                        elif .settings.clients then .settings.clients[0] |= (if has("id") then .id = $v elif has("password") then .password = $v else .auth = $v end)
                        else .settings.users[0] |= (if has("id") then .id = $v elif has("password") then .password = $v else .auth = $v end) end')
                    msg="节点凭据已更新"
                } ;;
            path)
                local new_path="" field="wsSettings"
                prompt_input "分流路径" "$NODE_PATH" new_path
                [[ "$new_path" != /* ]] && new_path="/$new_path"
                [ "$NODE_TRANS" = "xhttp" ] && field="xhttpSettings"
                up_inb=$(printf '%s\n' "$node" | jq --arg p "$new_path" --arg f "$field" '.streamSettings[$f].path = $p | del(._meta.path)')
                msg="分流路径已更新" ;;
            svc)
                local new_svc=""
                prompt_input "gRPC serviceName" "$NODE_SVC" new_svc
                up_inb=$(printf '%s\n' "$node" | jq --arg s "$new_svc" '.streamSettings.grpcSettings.serviceName = $s | del(._meta.serviceName)')
                msg="serviceName 已更新" ;;
            sni)
                local new_sni=""
                prompt_input "域名 / SNI / Host" "$NODE_SNI" new_sni
                if [ "$NODE_SEC" = "reality" ]; then
                    [ -z "$new_sni" ] && { log_warn "REALITY 节点的 SNI 不能为空"; sleep 0.8; continue; }
                    local reality_target="$new_sni"
                    [[ "$reality_target" != *:* ]] && reality_target="${reality_target}:443"
                    up_inb=$(printf '%s\n' "$node" | jq --arg s "$new_sni" --arg target "$reality_target" \
                        '.streamSettings.realitySettings.serverNames = [$s] | .streamSettings.realitySettings.target = $target | del(.streamSettings.realitySettings.dest) | ._meta.sni = $s')
                elif [ "$NODE_SEC" = "tls" ] && [ "$NODE_INSEC" = "1" ]; then
                    [ -z "$new_sni" ] && { log_warn "TLS 节点的 SNI 不能为空"; sleep 0.8; continue; }
                    generate_self_signed_cert "$new_sni" || { log_error "签发新 SNI 自签证书失败"; pause; continue; }
                    up_inb=$(printf '%s\n' "$node" | jq --arg s "$new_sni" --arg crt "$CERT_CRT" --arg key "$CERT_KEY" --arg pcs "$CERT_SHA256" \
                        '._meta.sni = $s | ._meta.certSha256 = $pcs | .streamSettings.tlsSettings.certificates = [{certificateFile: $crt, keyFile: $key}]
                         | (if .streamSettings.wsSettings then .streamSettings.wsSettings.host = $s else . end)
                         | (if .streamSettings.xhttpSettings then .streamSettings.xhttpSettings.host = $s else . end)')
                else
                    up_inb=$(printf '%s\n' "$node" | jq --arg s "$new_sni" \
                        '._meta.sni = $s
                         | (if .streamSettings.wsSettings then (if $s != "" then .streamSettings.wsSettings.host = $s else del(.streamSettings.wsSettings.host) end) else . end)
                         | (if .streamSettings.xhttpSettings then (if $s != "" then .streamSettings.xhttpSettings.host = $s else del(.streamSettings.xhttpSettings.host) end) else . end)')
                fi
                msg="域名 / SNI 已更新" ;;
            keys)
                gen_reality_keys || { log_error "生成 x25519 密钥对失败"; pause; continue; }
                up_inb=$(printf '%s\n' "$node" | jq --arg pk "$REALITY_PRIV" --arg sid "$REALITY_SID" --arg pbk "$REALITY_PUB" \
                    '.streamSettings.realitySettings.privateKey = $pk | .streamSettings.realitySettings.shortIds = [$sid] | del(.streamSettings.realitySettings.minClientVer, ._meta.shortId) | ._meta.publicKey = $pbk')
                msg="REALITY 密钥对与 ShortId 已重置" ;;
            rmk)
                local new_rmk=""
                prompt_input "节点备注" "$NODE_RMK" new_rmk
                up_inb=$(printf '%s\n' "$node" | jq --arg r "$new_rmk" '._meta.remark = $r')
                msg="备注已更新" ;;
            addr)
                local new_addr=""
                prompt_input "连接地址 / CDN 域名 / 优选 IP (留空恢复自动)" "$NODE_ADDR" new_addr
                up_inb=$(printf '%s\n' "$node" | jq --arg a "$new_addr" 'if $a == "" then del(._meta.address) else ._meta.address = $a end')
                msg="连接地址已更新" ;;
            reconf)
                confirm "进入完整重配向导？(中途取消不影响原节点)" "n" || continue
                add_node_wizard "$idx" || true
                return ;;
        esac

        if [ -n "$up_inb" ]; then
            local new_cfg
            new_cfg=$(jq --argjson idx "$idx" --argjson inb "$up_inb" '.inbounds[$idx] = $inb' "$XRAY_CONFIG")
            if validate_and_apply_config "$new_cfg"; then
                log_success "$msg"
                node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG")
                parse_node_meta "$node"
                sleep 0.8
            else
                pause
            fi
        fi
    done
}

export_backup_archive() {
    [ ! -f "$XRAY_CONFIG" ] && { log_warn "当前暂无配置文件可备份"; pause; return 1; }
    local date_str out_file
    date_str=$(date +%Y%m%d_%H%M%S)
    out_file="/root/xray_backup_${date_str}.tar.gz"

    mkdir -p /root
    if tar -czf "$out_file" -C /usr/local/etc xray 2>/dev/null; then
        chmod 600 "$out_file" 2>/dev/null || true
        log_success "备份包已生成: ${C_CYAN}${out_file}${C_RESET}"
        echo -e "  ${C_GRAY}包含内容: config.json 及全部证书 (certs/)${C_RESET}"
        echo -e "  ${C_GRAY}跨机迁移: 将此文件复制到新服务器，在面板中选择 [导入恢复包] 即可${C_RESET}"
    else
        log_error "备份打包失败"
    fi
    pause
}

import_backup_archive() {
    local in_file=""
    prompt_input "请输入备份文件完整路径 (.tar.gz)" "/root/xray_backup.tar.gz" in_file
    [ ! -f "$in_file" ] && { log_error "指定的文件不存在: $in_file"; pause; return 1; }

    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1
    if ! tar -xzf "$in_file" -C "$tmp_dir" 2>/dev/null || [ ! -f "$tmp_dir/xray/config.json" ]; then
        rm -rf "$tmp_dir"
        log_error "无效的备份包，未在压缩包中找到 xray/config.json"
        pause; return 1
    fi

    if [ -x "$XRAY_BIN" ]; then
        local err_msg
        if ! err_msg=$("$XRAY_BIN" run -test -c "$tmp_dir/xray/config.json" 2>&1); then
            rm -rf "$tmp_dir"
            log_error "备份包中的配置文件未通过 Xray 语法校验"
            [ -n "$err_msg" ] && echo -e "${C_GRAY}${err_msg}${C_RESET}"
            pause; return 1
        fi
    fi

    confirm "确定恢复此备份包？(将覆盖现有配置与证书)" "n" || { rm -rf "$tmp_dir"; return 0; }

    mkdir -p "$XRAY_CONFIG_DIR"
    cp -rf "$tmp_dir/xray/"* "$XRAY_CONFIG_DIR/"
    rm -rf "$tmp_dir"

    ensure_xray_user
    get_public_ip force
    log_success "配置与证书已成功恢复！"
    if is_running; then
        service_ctrl restart || true
    fi
    pause
}

backup_and_restore_menu() {
    header
    echo -e "  ${C_BOLD}Xray 配置备份与跨机迁移${C_RESET}\n"
    echo -e "  ${C_CYAN}1.${C_RESET} 导出备份包 (打包当前 config.json 与证书目录)"
    echo -e "  ${C_CYAN}2.${C_RESET} 导入恢复包 (从 .tar.gz 恢复配置与证书)"
    echo ""
    local sel
    read -rp "  › 请选择 [1-2, 回车返回]: " sel || return 0
    case "$sel" in
        1) export_backup_archive ;;
        2) import_backup_archive ;;
        *) return 0 ;;
    esac
}

enable_bbr() {
    header
    echo -e "  ${C_BOLD}TCP BBR 拥塞控制${C_RESET}\n"

    if is_bbr_enabled; then
        log_success "BBR 已处于开启状态 (队列算法: $(get_sysctl net.core.default_qdisc))"
        pause && return 0
    fi

    modprobe tcp_bbr 2>/dev/null || true
    local avail_cc
    avail_cc=$(get_sysctl net.ipv4.tcp_available_congestion_control)
    if ! printf '%s\n' "$avail_cc" | tr ' ' '\n' | grep -qx "bbr"; then
        log_warn "当前内核不支持 BBR (可用: ${avail_cc:-未知}，常见于 OpenVZ/LXC 容器)"
        pause && return 1
    fi

    apply_sysctl_dropin "99-bbr.conf" \
        '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d;/net.mptcp.enabled/d' \
        'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.mptcp.enabled=0\n'

    if is_bbr_enabled; then
        log_success "BBR + FQ 已开启生效"
    else
        log_warn "参数已写入，当前拥塞算法: $(get_sysctl net.ipv4.tcp_congestion_control)"
    fi
    pause
}

detect_os
detect_init
detect_arch

run_quick() { if "$@"; then sleep 0.8; else pause; fi; }

main() {
    if [ ! -t 0 ]; then
        if ! { exec < /dev/tty; } 2>/dev/null; then
            log_error "当前非交互式终端且无法打开 /dev/tty"
            exit 1
        fi
    fi

    check_root
    check_ipv6_only
    check_mptcp_security
    install_deps
    ensure_xray_user
    setup_shortcut
    get_public_ip

    local choice
    while true; do
        header

        echo -e "  ${C_GRAY}节点${C_RESET}    ${C_CYAN}1${C_RESET} 节点列表    ${C_CYAN}2${C_RESET} 添加节点    ${C_CYAN}3${C_RESET} 修改节点    ${C_CYAN}4${C_RESET} 删除节点"
        echo -e "  ${C_GRAY}服务${C_RESET}    ${C_CYAN}5${C_RESET} 重启服务    ${C_CYAN}6${C_RESET} 启动服务    ${C_CYAN}7${C_RESET} 停止服务    ${C_CYAN}8${C_RESET} 实时日志"
        echo -e "  ${C_GRAY}系统${C_RESET}    ${C_CYAN}9${C_RESET} 核心升级   ${C_CYAN}10${C_RESET} 开机自启   ${C_CYAN}11${C_RESET} BBR 算法   ${C_CYAN}12${C_RESET} 备份迁移"
        echo -e "  ${C_GRAY}其他${C_RESET}    ${C_GRAY}0${C_RESET} 退出面板   ${C_RED}13${C_RESET} 卸载核心"
        echo ""

        read -rp "  › 请选择 [1-13, 回车退出]: " choice || exit 0
        if [ -z "$choice" ] || is_cancel "$choice"; then
            clear 2>/dev/null || true
            echo -e "\n  ${C_CYAN}已退出 Xray 管理面板${C_RESET} ${C_GRAY}(输入 xraym 可再次打开)${C_RESET}\n"
            exit 0
        fi
        case "$choice" in
            1)  node_menu_loop "入站节点列表" "查看节点编号" view_node_detail ;;
            2)  add_node_wizard ;;
            3)  node_menu_loop "修改入站节点" "选择修改编号" edit_single_node ;;
            4)  node_menu_loop "删除入站节点" "选择删除编号" delete_node_by_idx ;;
            5)  run_quick service_ctrl restart ;;
            6)  run_quick service_ctrl start ;;
            7)  run_quick service_ctrl stop ;;
            8)  view_logs ;;
            9)  install_xray ;;
            10) run_quick service_toggle_autostart ;;
            11) enable_bbr ;;
            12) backup_and_restore_menu ;;
            13) uninstall_xray ;;
            *)  log_warn "请输入 1-13 之间的选项" && sleep 0.8 ;;
        esac
    done
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
