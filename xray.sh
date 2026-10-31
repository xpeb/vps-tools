#!/usr/bin/env bash
# ==============================================================================
#  xray.sh - Minimalist Xray Core Management Script
#  Supported OS: Debian / Ubuntu / Alpine Linux
#  Protocols:    VLESS, VMess, Trojan, Shadowsocks, Hysteria 2
#  Transports:   xhttp, grpc, websocket, raw/tcp
# ==============================================================================

if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if [ -f /etc/alpine-release ]; then
            apk update >/dev/null 2>&1 && apk add bash >/dev/null 2>&1
        elif [ -f /etc/debian_version ] || [ -f /etc/os-release ]; then
            apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y bash >/dev/null 2>&1
        fi
    fi
    if [ -f "$0" ] && [ "$0" != "sh" ] && [ "$0" != "bash" ]; then
        exec bash "$0" "$@"
    else
        exec bash -s -- "$@"
    fi
fi

set -o pipefail
if [ ! -t 0 ]; then
    { exec < /dev/tty; } 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# Constants & Paths
# ------------------------------------------------------------------------------
XRAY_SHARE_DIR="/usr/local/share/xray"
XRAY_BIN="$XRAY_SHARE_DIR/xray-core"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_CONFIG_DIR/config.json"
XRAY_CERTS_DIR="$XRAY_CONFIG_DIR/certs"
XRAY_LOG_DIR="/var/log/xray"
XRAY_ACCESS_LOG="$XRAY_LOG_DIR/access.log"
XRAY_ERROR_LOG="$XRAY_LOG_DIR/error.log"

SYSTEMD_SERVICE="/etc/systemd/system/xray.service"
OPENRC_SERVICE="/etc/init.d/xray"
DAEMON_PID_FILE="/run/xray.pid"

SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
SCRIPT_LINK="/usr/local/bin/xray"
SCRIPT_URL="https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh"

SERVER_IP=""
SERVER_IPV4=""
SERVER_IPV6=""
IP_FETCHED=0

# Colors & Formatting
if [ -t 1 ]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m'
    C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m' C_GRAY=$'\033[90m'
else
    C_RESET="" C_BOLD="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_GRAY=""
fi

# ------------------------------------------------------------------------------
# UI Helpers
# ------------------------------------------------------------------------------
line()        { echo -e "${C_GRAY}────────────────────────────────────────────────────────────────${C_RESET}"; }
log_info()    { echo -e "  ${C_CYAN}›${C_RESET} $1"; }
log_success() { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
log_warn()    { echo -e "  ${C_YELLOW}!${C_RESET} $1"; }
log_error()   { echo -e "  ${C_RED}✖${C_RESET} $1"; }
pause()       { echo ""; read -r -p "  › 按回车继续..." || true; }

get_node_count() {
    local c=0
    [ -f "$XRAY_CONFIG" ] && c=$(jq '.inbounds | length // 0' "$XRAY_CONFIG" 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo 0
}

header() {
    clear 2>/dev/null || true
    line
    local core_ver="未安装" status_str="${C_GRAY}○ 未安装${C_RESET}"
    if is_installed; then
        core_ver="$("$XRAY_BIN" version 2>/dev/null | head -n 1 | awk '{print $2}')"
        [ -z "$core_ver" ] && core_ver="已安装"
        if is_running; then
            status_str="${C_GREEN}● 运行中${C_RESET} ${C_GRAY}(v${core_ver#v})${C_RESET}"
        else
            status_str="${C_RED}○ 已停止${C_RESET} ${C_GRAY}(v${core_ver#v})${C_RESET}"
        fi
    fi

    local auto_str="${C_GRAY}已关闭${C_RESET}"
    is_autostart_enabled && auto_str="${C_GREEN}已开启${C_RESET}"

    local node_count
    node_count=$(get_node_count)

    [ -z "$SERVER_IP" ] && get_public_ip

    printf "  ${C_BOLD}%s${C_RESET}\n" "Xray Core Manager"
    printf "  ${C_GRAY}系统:${C_RESET} %s\n" "${OS_NAME:-Linux}"
    printf "  ${C_GRAY}状态:${C_RESET} %b\n" "$status_str"
    printf "  ${C_GRAY}自启:${C_RESET} %b\n" "$auto_str"
    printf "  ${C_GRAY}节点:${C_RESET} %d 个活跃入站\n" "$node_count"
    if [ -n "$SERVER_IPV4" ] && [ -n "$SERVER_IPV6" ]; then
        printf "  ${C_GRAY}IPv4:${C_RESET} %s\n" "$SERVER_IPV4"
        printf "  ${C_GRAY}IPv6:${C_RESET} %s\n" "$SERVER_IPV6"
    elif [ -n "$SERVER_IPV4" ]; then
        printf "  ${C_GRAY}IPv4:${C_RESET} %s\n" "$SERVER_IPV4"
    elif [ -n "$SERVER_IPV6" ]; then
        printf "  ${C_GRAY}IPv6:${C_RESET} %s\n" "$SERVER_IPV6"
    else
        printf "  ${C_GRAY}地址:${C_RESET} %s\n" "${SERVER_IP:-获取中...}"
    fi
    line
}

prompt_input() {
    local prompt="$1" default_val="$2" var_name="$3" user_val=""
    if [ -n "$default_val" ]; then
        echo -ne "  › ${prompt} [${C_CYAN}${default_val}${C_RESET}]: "
        read -r user_val
        [ -z "$user_val" ] && user_val="$default_val"
    else
        echo -ne "  › ${prompt}: "
        read -r user_val
    fi
    printf -v "$var_name" '%s' "$user_val"
}

prompt_choice() {
    local prompt="$1" default_idx="$2" var_name="$3"; shift 3
    echo -e "  › ${C_BOLD}${prompt}:${C_RESET}"
    local idx=1
    for opt in "$@"; do
        if [ "$idx" -eq "$default_idx" ]; then
            echo -e "    ${C_CYAN}${idx}.${C_RESET} ${opt} ${C_GRAY}(默认)${C_RESET}"
        else
            echo -e "    ${C_GRAY}${idx}.${C_RESET} ${opt}"
        fi
        idx=$((idx + 1))
    done
    local total=$#
    while true; do
        read -rp "  › 请选择 [1-${total}, 默认: ${default_idx}]: " choice
        [ -z "$choice" ] && choice="$default_idx"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
            printf -v "$var_name" '%s' "$choice"
            break
        else
            log_warn "输入无效，请输入 1 到 ${total}"
        fi
    done
}

# ------------------------------------------------------------------------------
# System Detection & Dependencies
# ------------------------------------------------------------------------------
check_root() {
    [ "$(id -u)" -ne 0 ] && { log_error "需 root 权限运行"; exit 1; }
}

detect_os() {
    local id_val="" ver_id="" name_val=""
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id_val="$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')"
        ver_id="${VERSION_ID:-}"
        name_val="${NAME:-}"
    fi

    case "$id_val" in
        debian*)
            OS_TYPE="debian"
            local dver="${ver_id%%.*}"
            [ -z "$dver" ] && [ -f /etc/debian_version ] && dver=$(cut -d. -f1 /etc/debian_version 2>/dev/null)
            OS_NAME="Debian ${dver}"
            ;;
        ubuntu*)
            OS_TYPE="debian"
            OS_NAME="Ubuntu ${ver_id}"
            ;;
        alpine*)
            OS_TYPE="alpine"
            local aver="${ver_id}"
            [ -z "$aver" ] && [ -f /etc/alpine-release ] && aver=$(cat /etc/alpine-release 2>/dev/null)
            aver=$(echo "$aver" | cut -d. -f1,2)
            OS_NAME="Alpine ${aver}"
            ;;
        centos*)
            OS_TYPE="rhel"
            OS_NAME="CentOS ${ver_id%%.*}"
            ;;
        rocky*)
            OS_TYPE="rhel"
            OS_NAME="Rocky ${ver_id%%.*}"
            ;;
        alma*)
            OS_TYPE="rhel"
            OS_NAME="Alma ${ver_id%%.*}"
            ;;
        fedora*)
            OS_TYPE="fedora"
            OS_NAME="Fedora ${ver_id%%.*}"
            ;;
        arch*)
            OS_TYPE="arch"
            OS_NAME="Arch Linux"
            ;;
        *)
            if [ -f /etc/alpine-release ]; then
                OS_TYPE="alpine"
                OS_NAME="Alpine $(cut -d. -f1,2 /etc/alpine-release 2>/dev/null)"
            elif [ -f /etc/debian_version ]; then
                OS_TYPE="debian"
                OS_NAME="Debian $(cut -d. -f1 /etc/debian_version 2>/dev/null)"
            else
                OS_TYPE="unknown"
                local first_word="${name_val%% *}"
                OS_NAME="${first_word:-Linux}${ver_id:+ ${ver_id%%.*}}"
            fi
            ;;
    esac
    OS_NAME="${OS_NAME% }"
}

detect_init() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_TYPE="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_TYPE="openrc"
    else
        INIT_TYPE="daemon"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="64" ;;
        aarch64|arm64)  ARCH="arm64-v8a" ;;
        armv7*|armv8l)  ARCH="arm32-v7a" ;;
        i386|i686)      ARCH="32" ;;
        s390x)          ARCH="s390x" ;;
        riscv64)        ARCH="riscv64" ;;
        *)              ARCH="64" ;;
    esac
}

format_url_host() {
    [[ "$1" == *:* && "$1" != \[*\] ]] && echo "[$1]" || echo "$1"
}

get_public_ip() {
    [ -n "$SERVER_IPV4" ] || [ -n "$SERVER_IPV6" ] && return
    [ "${IP_FETCHED:-0}" -eq 1 ] && return
    IP_FETCHED=1

    local has_v4=0 has_v6=0
    if command -v ip >/dev/null 2>&1; then
        ip -4 route show default 2>/dev/null | grep -q default && has_v4=1
        ip -6 route show default 2>/dev/null | grep -q default && has_v6=1
    fi
    [ "$has_v4" -eq 0 ] && [ "$has_v6" -eq 0 ] && { has_v4=1; has_v6=1; }

    local tmp_dir
    tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'xray_ip.XXXXXX')
    [ "$has_v4" -eq 1 ] && ( curl -s4m 3 https://api.ipify.org || curl -s4m 3 https://ipv4.icanhazip.com || curl -s4m 3 https://ifconfig.me ) > "$tmp_dir/v4" 2>/dev/null &
    [ "$has_v6" -eq 1 ] && ( curl -s6m 3 https://api6.ipify.org || curl -s6m 3 https://ipv6.icanhazip.com || curl -s6m 3 https://api64.ipify.org ) > "$tmp_dir/v6" 2>/dev/null &
    wait 2>/dev/null

    [ -s "$tmp_dir/v4" ] && SERVER_IPV4=$(tr -d '[:space:]' < "$tmp_dir/v4")
    [ -s "$tmp_dir/v6" ] && SERVER_IPV6=$(tr -d '[:space:]' < "$tmp_dir/v6")
    rm -rf "$tmp_dir" 2>/dev/null

    [[ "$SERVER_IPV4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || SERVER_IPV4=""
    [[ "$SERVER_IPV6" == *:* && "$SERVER_IPV6" =~ ^[0-9a-fA-F:]+$ ]] || SERVER_IPV6=""

    SERVER_IP="${SERVER_IPV4:-$SERVER_IPV6}"
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="127.0.0.1"
        IP_FETCHED=0
    fi
}

check_ipv6_only() {
    if ! ip -4 route show default 2>/dev/null | grep -q default && ip -6 route show default 2>/dev/null | grep -q default; then
        if ! curl -sIm 3 https://github.com >/dev/null 2>&1 && ! wget -q -T 3 -O /dev/null https://github.com 2>/dev/null; then
            log_info "检测到纯 IPv6 环境，正在接入 DNS64 加速通道..."
            if ! grep -q "2001:67c:2b0::4" /etc/resolv.conf 2>/dev/null; then
                sed -i '1i nameserver 2001:67c:2b0::4\nnameserver 2a01:4f8:c2c:123f::1' /etc/resolv.conf 2>/dev/null || \
                echo -e "nameserver 2001:67c:2b0::4\nnameserver 2a01:4f8:c2c:123f::1" >> /etc/resolv.conf 2>/dev/null || true
            fi
        fi
    fi
}

install_deps() {
    local missing=""
    for cmd in curl wget unzip tar openssl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
        log_info "安装系统依赖:${missing}..."
        if [ "$OS_TYPE" = "alpine" ]; then
            if ! wget -q -T 3 -O /dev/null "https://dl-cdn.alpinelinux.org/alpine/" 2>/dev/null; then
                for m in "http://mirror.yandex.ru/mirrors/alpine" "http://mirrors.edge.kernel.org/alpine" "http://mirror.leaseweb.com/alpine"; do
                    if wget -q -T 3 -O /dev/null "$m/" 2>/dev/null; then
                        sed -i "s|https\?://dl-cdn.alpinelinux.org/alpine|$m|g" /etc/apk/repositories 2>/dev/null || true
                        break
                    fi
                done
            fi
            apk update >/dev/null 2>&1 && apk add curl wget unzip tar openssl jq ca-certificates procps bash >/dev/null 2>&1
        elif [ "$OS_TYPE" = "debian" ]; then
            apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget unzip tar openssl jq ca-certificates procps bash >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl wget unzip tar openssl jq ca-certificates procps-ng bash >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl wget unzip tar openssl jq ca-certificates procps-ng bash >/dev/null 2>&1
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm curl wget unzip tar openssl jq ca-certificates procps-ng bash >/dev/null 2>&1
        fi
        log_success "依赖已就绪"
    fi
}

setup_shortcut() {
    rm -f /usr/local/bin/xrsy 2>/dev/null || true
    if [ -f "$SCRIPT_LINK" ] && head -c 4 "$SCRIPT_LINK" 2>/dev/null | grep -q "ELF"; then
        mkdir -p "$XRAY_SHARE_DIR"
        mv -f "$SCRIPT_LINK" "$XRAY_BIN" 2>/dev/null || true
    fi
    if [ -f "$SYSTEMD_SERVICE" ] && grep -q "/usr/local/bin/xray " "$SYSTEMD_SERVICE"; then
        sed -i "s|/usr/local/bin/xray |$XRAY_BIN |g" "$SYSTEMD_SERVICE"
        systemctl daemon-reload 2>/dev/null || true
    fi
    if [ -f "$OPENRC_SERVICE" ] && grep -q 'command="/usr/local/bin/xray"' "$OPENRC_SERVICE"; then
        sed -i "s|command=\"/usr/local/bin/xray\"|command=\"$XRAY_BIN\"|g" "$OPENRC_SERVICE"
    fi

    local target_script="$SCRIPT_SELF"
    if [ "$target_script" = "$SCRIPT_LINK" ]; then
        chmod +x "$SCRIPT_LINK" 2>/dev/null || true
        return
    fi

    mkdir -p /usr/local/bin
    if [ -f "$target_script" ] && [[ "$target_script" != /proc/* ]] && [[ "$target_script" != /dev/fd/* ]]; then
        cp -f "$target_script" "$SCRIPT_LINK" 2>/dev/null || true
    else
        local tmp_sh="/tmp/xray_sh_$$"
        if curl -fsSL "$SCRIPT_URL" -o "$tmp_sh" 2>/dev/null || wget -qO "$tmp_sh" "$SCRIPT_URL" 2>/dev/null; then
            if [ -s "$tmp_sh" ]; then
                mv -f "$tmp_sh" "$SCRIPT_LINK" 2>/dev/null || true
            fi
            rm -f "$tmp_sh" 2>/dev/null || true
        fi
    fi
    chmod +x "$SCRIPT_LINK" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Service Lifecycle
# ------------------------------------------------------------------------------
is_installed() {
    [ -x "$XRAY_BIN" ] && head -c 4 "$XRAY_BIN" 2>/dev/null | grep -q "ELF"
}

is_running() {
    [ -x "$XRAY_BIN" ] || return 1
    if [ "$INIT_TYPE" = "systemd" ]; then
        systemctl is-active --quiet xray 2>/dev/null
    elif [ "$INIT_TYPE" = "openrc" ]; then
        rc-service xray status 2>/dev/null | grep -q "status: started"
    else
        if [ -f "$DAEMON_PID_FILE" ] && kill -0 "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null; then
            return 0
        fi
        pgrep -x xray-core >/dev/null 2>&1
    fi
}

is_autostart_enabled() {
    if [ "$INIT_TYPE" = "systemd" ]; then
        systemctl is-enabled --quiet xray 2>/dev/null
    elif [ "$INIT_TYPE" = "openrc" ]; then
        rc-status default 2>/dev/null | grep -q "\bxray\b"
    fi
}

svc() {
    local action="$1"
    if [ "$INIT_TYPE" = "systemd" ]; then
        systemctl "$action" xray
    elif [ "$INIT_TYPE" = "openrc" ]; then
        rc-service xray "$action"
    else
        case "$action" in
            start)
                mkdir -p "$XRAY_LOG_DIR"
                nohup "$XRAY_BIN" run -c "$XRAY_CONFIG" >> "$XRAY_ACCESS_LOG" 2>> "$XRAY_ERROR_LOG" </dev/null &
                echo $! > "$DAEMON_PID_FILE"
                ;;
            stop)
                if [ -f "$DAEMON_PID_FILE" ]; then
                    kill "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null || true
                    rm -f "$DAEMON_PID_FILE"
                fi
                pkill -x xray-core 2>/dev/null || true
                ;;
            restart)
                svc stop; sleep 1; svc start
                ;;
        esac
    fi
}

service_ctrl() {
    case "$1" in
        start)
            if is_running; then log_info "服务运行中"; return; fi
            svc start; sleep 1
            if is_running; then log_success "服务已启动"; else log_error "启动失败，请检查日志"; fi
            ;;
        stop)
            if ! is_running; then log_info "服务未运行"; return; fi
            svc stop; sleep 1
            if ! is_running; then log_success "服务已停止"; else log_error "停止失败"; fi
            ;;
        restart)
            svc restart; sleep 1
            if is_running; then log_success "服务已重启"; else log_error "重启失败，请检查日志"; fi
            ;;
    esac
}
service_stop()    { service_ctrl stop; }
service_restart() { service_ctrl restart; }

service_toggle_autostart() {
    if is_autostart_enabled; then
        [ "$INIT_TYPE" = "systemd" ] && systemctl disable xray >/dev/null 2>&1
        [ "$INIT_TYPE" = "openrc" ] && rc-update del xray default >/dev/null 2>&1
        log_success "自启已关闭"
    else
        [ "$INIT_TYPE" = "systemd" ] && systemctl enable xray >/dev/null 2>&1
        [ "$INIT_TYPE" = "openrc" ] && rc-update add xray default >/dev/null 2>&1
        log_success "自启已开启"
    fi
}

view_logs() {
    header
    echo -e "  ${C_CYAN}实时日志 (Ctrl+C 返回):${C_RESET}"
    line
    mkdir -p "$XRAY_LOG_DIR"
    touch "$XRAY_ERROR_LOG" "$XRAY_ACCESS_LOG"
    if [ ! -s "$XRAY_ERROR_LOG" ] && [ ! -s "$XRAY_ACCESS_LOG" ] && [ "$INIT_TYPE" = "systemd" ]; then
        journalctl -u xray -n 30 --no-pager 2>/dev/null
    fi
    trap ' ' INT
    tail -n 50 -f "$XRAY_ERROR_LOG" "$XRAY_ACCESS_LOG" 2>/dev/null
    trap - INT
}

# ------------------------------------------------------------------------------
# Install & Uninstall
# ------------------------------------------------------------------------------
get_latest_xray_version() {
    local tag
    tag=$(curl -sIL -o /dev/null -w '%{url_effective}' --max-time 5 https://github.com/XTLS/Xray-core/releases/latest | grep -o '[^/]*$' || echo "")
    [ -z "$tag" ] || [ "$tag" = "latest" ] && tag=$(curl -sL --max-time 5 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name // empty' 2>/dev/null || echo "")
    echo "${tag:-v26.10.31}"
}

init_config_if_needed() {
    mkdir -p "$XRAY_CONFIG_DIR" "$XRAY_CERTS_DIR" "$XRAY_LOG_DIR" "$XRAY_SHARE_DIR"
    touch "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
    chown -R root:root "$XRAY_LOG_DIR" "$XRAY_CONFIG_DIR" "$XRAY_SHARE_DIR" 2>/dev/null || true
    chmod 755 "$XRAY_LOG_DIR" 2>/dev/null || true
    chmod 644 "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG" 2>/dev/null || true
    if [ ! -s "$XRAY_CONFIG" ]; then
        local freedom_settings="{}"
        if ! ip -4 route show default 2>/dev/null | grep -q default && ip -6 route show default 2>/dev/null | grep -q default; then
            freedom_settings='{"domainStrategy": "UseIPv6"}'
        fi
        cat << EOF > "$XRAY_CONFIG"
{
  "log": {"loglevel": "warning", "access": "$XRAY_ACCESS_LOG", "error": "$XRAY_ERROR_LOG"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct", "settings": $freedom_settings}, {"protocol": "blackhole", "tag": "blocked"}],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}]}
}
EOF
    fi
}

setup_service_units() {
    if [ "$INIT_TYPE" = "systemd" ]; then
        cat << EOF > "$SYSTEMD_SERVICE"
[Unit]
Description=Xray Core Service
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment="XRAY_LOCATION_ASSET=$XRAY_SHARE_DIR"
ExecStart=$XRAY_BIN run -c $XRAY_CONFIG
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1 || true
    elif [ "$INIT_TYPE" = "openrc" ]; then
        cat << EOF > "$OPENRC_SERVICE"
#!/sbin/openrc-run
name="xray"
description="Xray Core Service"
command="$XRAY_BIN"
command_args="run -c $XRAY_CONFIG"
command_background="yes"
pidfile="$DAEMON_PID_FILE"
output_log="$XRAY_ACCESS_LOG"
error_log="$XRAY_ERROR_LOG"
export XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o root:root "$XRAY_LOG_DIR" "$XRAY_CONFIG_DIR"
    checkpath -f -m 0644 -o root:root "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
}
EOF
        chmod +x "$OPENRC_SERVICE"
        rc-update add xray default >/dev/null 2>&1 || true
    fi
}

install_xray() {
    header
    log_info "获取最新核心版本..."
    local ver
    ver=$(get_latest_xray_version)
    log_info "版本: ${C_CYAN}${ver}${C_RESET}"

    local url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${ARCH}.zip"
    local tmp_dir="/tmp/xray_install_$$"
    mkdir -p "$tmp_dir" "$XRAY_SHARE_DIR"

    log_info "下载核心组件..."
    if ! curl -sL --fail "$url" -o "$tmp_dir/xray.zip"; then
        log_error "下载失败，请检查网络"
        rm -rf "$tmp_dir"
        pause && return 1
    fi

    if ! unzip -q -o "$tmp_dir/xray.zip" -d "$tmp_dir" || [ ! -f "$tmp_dir/xray" ]; then
        log_error "解压核心失败"
        rm -rf "$tmp_dir"
        pause && return 1
    fi

    install -m 755 "$tmp_dir/xray" "$XRAY_BIN"
    [ -f "$tmp_dir/geoip.dat" ] && install -m 644 "$tmp_dir/geoip.dat" "$XRAY_SHARE_DIR/"
    [ -f "$tmp_dir/geosite.dat" ] && install -m 644 "$tmp_dir/geosite.dat" "$XRAY_SHARE_DIR/"
    rm -rf "$tmp_dir"

    is_running && svc stop
    init_config_if_needed
    setup_service_units
    setup_shortcut

    log_success "核心安装完成"
    service_restart
    pause
}

uninstall_xray() {
    header
    echo -e "  ${C_BOLD}卸载 Xray${C_RESET}"
    line
    log_warn "将彻底清除核心、配置、证书、日志及快捷指令"
    read -rp "  › 确认卸载？[y/N]: " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { log_info "已取消"; pause; return; }

    log_info "停止服务..."
    service_stop
    pkill -9 -x xray-core 2>/dev/null || true
    pkill -9 -x xray 2>/dev/null || true

    log_info "注销系统服务..."
    if [ "$INIT_TYPE" = "systemd" ]; then
        systemctl disable xray >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE" /etc/systemd/system/xray@.service
        rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true
    elif [ "$INIT_TYPE" = "openrc" ]; then
        rc-update del xray default >/dev/null 2>&1 || true
        rc-update del xray >/dev/null 2>&1 || true
        rm -f "$OPENRC_SERVICE"
    fi

    log_info "清理核心与配置文件..."
    rm -rf "$XRAY_SHARE_DIR" "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR" /etc/xray
    rm -f /usr/local/bin/xray-core /usr/local/bin/geoip.dat /usr/local/bin/geosite.dat "$DAEMON_PID_FILE" /run/xray.pid /var/run/xray.pid

    log_info "清理快捷指令..."
    rm -f "$SCRIPT_LINK" /usr/local/bin/xrsy /usr/bin/xray /usr/bin/xrsy

    log_success "Xray 已彻底卸载"
    echo ""
    exit 0
}

# ------------------------------------------------------------------------------
# Helpers: Math, Random, Certs, Config Validation
# ------------------------------------------------------------------------------
rand_port() {
    local p
    while true; do
        p=$(shuf -i 10000-60000 -n 1 2>/dev/null || awk 'BEGIN{srand(); print int(rand()*50000)+10000}')
        ! is_port_used "$p" && { echo "$p"; break; }
    done
}

rand_uuid() {
    [ -x "$XRAY_BIN" ] && "$XRAY_BIN" uuid 2>/dev/null && return
    [ -f /proc/sys/kernel/random/uuid ] && cat /proc/sys/kernel/random/uuid && return
    openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

rand_str()      { openssl rand -base64 "$(( ${1:-16} * 2 ))" | tr -dc 'a-zA-Z0-9' | head -c "${1:-16}"; }
urlencode()     { jq -rn --arg x "$1" '$x|@uri'; }
base64_encode() { printf '%s' "$1" | base64 | tr -d '\r\n'; }

is_port_used() {
    local port="$1"
    [ -f "$XRAY_CONFIG" ] && jq -e --argjson p "$port" '.inbounds[]? | select(.port == $p)' "$XRAY_CONFIG" >/dev/null 2>&1 && return 0
    command -v ss >/dev/null 2>&1 && ss -tunl 2>/dev/null | grep -E -q "[:]$port([[:space:]]|$)" && return 0
    command -v netstat >/dev/null 2>&1 && netstat -tunl 2>/dev/null | grep -E -q "[:]$port([[:space:]]|$)" && return 0
    return 1
}

generate_self_signed_cert() {
    local domain="${1:-www.cloudflare.com}"
    mkdir -p "$XRAY_CERTS_DIR"
    local crt="$XRAY_CERTS_DIR/self_signed.crt" key="$XRAY_CERTS_DIR/self_signed.key"
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -nodes -sha256 -days 3650 -keyout "$key" -out "$crt" -subj "/CN=$domain" \
            -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1 || \
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -nodes -sha256 -days 3650 -keyout "$key" -out "$crt" -subj "/CN=$domain" >/dev/null 2>&1
    fi
}

validate_and_apply_config() {
    local new_config="$1" bak="$XRAY_CONFIG.bak" err_msg
    [ -z "$new_config" ] && { log_error "配置数据为空，已拒绝应用"; return 1; }
    [ -f "$XRAY_CONFIG" ] && cp -f "$XRAY_CONFIG" "$bak"
    printf '%s\n' "$new_config" > "$XRAY_CONFIG"
    if err_msg=$("$XRAY_BIN" run -test -c "$XRAY_CONFIG" 2>&1); then
        rm -f "$bak"
        service_restart
        return 0
    else
        log_error "配置验证失败，已回退"
        [ -n "$err_msg" ] && echo -e "${C_GRAY}${err_msg}${C_RESET}"
        [ -f "$bak" ] && mv -f "$bak" "$XRAY_CONFIG"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Inbound Node Creation Wizard
# ------------------------------------------------------------------------------
add_node_wizard() {
    header
    ! is_installed && { log_warn "核心未安装，请先安装"; pause; return; }
    init_config_if_needed

    echo -e "  ${C_BOLD}添加入站节点${C_RESET}"
    line

    local p_sel="" t_sel="" s_sel="" sm_sel="" c_sel=""
    prompt_choice "代理协议" "1" p_sel \
        "VLESS        (主流首选: 速度最快/抗封锁强)" \
        "VMess        (经典协议: 兼容老旧客户端)" \
        "Trojan       (伪装协议: 模拟标准网页访问)" \
        "Shadowsocks  (经典协议: 游戏/路由器友好)" \
        "Hysteria 2   (极速协议: 拯救恶劣丢包弱网)"

    local protocol transport="raw" security="none" path="" service_name="" sni="" pbk="" priv_key="" short_id=""
    local cert_file="" key_file="" insecure="0" ss_method="" ss_pass="" client_id="" flow=""

    case "$p_sel" in
        1) protocol="vless" ;;
        2) protocol="vmess" ;;
        3) protocol="trojan" ;;
        4) protocol="shadowsocks" ;;
        5) protocol="hysteria" ;;
    esac

    # Transport & Security
    if [ "$protocol" = "vless" ]; then
        prompt_choice "传输方式" "1" t_sel \
            "xhttp     (推荐: 最新流式传输，过墙更稳)" \
            "grpc      (多路复用)" \
            "websocket (适合配合 CDN 反代)" \
            "tcp       (原生 TCP)"
        case "$t_sel" in 1) transport="xhttp";; 2) transport="grpc";; 3) transport="ws";; 4) transport="tcp";; esac

        prompt_choice "安全协议" "1" s_sel \
            "REALITY (推荐: 免买域名，借大厂伪装防封)" \
            "TLS     (标准证书加密，需自行准备域名)" \
            "None    (明文传输，适合配合 CDN 反代)"
        case "$s_sel" in 1) security="reality";; 2) security="tls";; 3) security="none";; esac

    elif [ "$protocol" = "vmess" ]; then
        prompt_choice "传输方式" "1" t_sel "websocket (推荐 CDN)" "grpc" "xhttp" "tcp"
        case "$t_sel" in 1) transport="ws";; 2) transport="grpc";; 3) transport="xhttp";; 4) transport="tcp";; esac
        prompt_choice "安全协议" "1" s_sel "None (用于 CDN)" "TLS (标准证书)"
        case "$s_sel" in 1) security="none";; 2) security="tls";; esac

    elif [ "$protocol" = "trojan" ]; then
        prompt_choice "传输方式" "1" t_sel "tcp (原生标准)" "websocket" "grpc" "xhttp"
        case "$t_sel" in 1) transport="tcp";; 2) transport="ws";; 3) transport="grpc";; 4) transport="xhttp";; esac
        prompt_choice "安全协议" "1" s_sel "TLS (标准证书)" "REALITY (免证书伪装)"
        case "$s_sel" in 1) security="tls";; 2) security="reality";; esac

    elif [ "$protocol" = "shadowsocks" ]; then
        prompt_choice "加密算法" "1" sm_sel \
            "2022-blake3-aes-128-gcm (推荐)" \
            "2022-blake3-aes-256-gcm" \
            "aes-128-gcm" "aes-256-gcm" "chacha20-ietf-poly1305"
        case "$sm_sel" in
            1) ss_method="2022-blake3-aes-128-gcm" ;;
            2) ss_method="2022-blake3-aes-256-gcm" ;;
            3) ss_method="aes-128-gcm" ;;
            4) ss_method="aes-256-gcm" ;;
            5) ss_method="chacha20-ietf-poly1305" ;;
        esac
        prompt_choice "传输方式" "1" t_sel "raw (原生 TCP/UDP)" "websocket" "grpc" "xhttp"
        case "$t_sel" in 1) transport="raw";; 2) transport="ws";; 3) transport="grpc";; 4) transport="xhttp";; esac
        security="none"

    elif [ "$protocol" = "hysteria" ]; then
        transport="hysteria" security="tls"
    fi

    # Port selection
    local def_port="443"
    [ "$security" = "none" ] && [ "$protocol" != "shadowsocks" ] && def_port="80"
    [ "$protocol" = "shadowsocks" ] && def_port=$(rand_port)
    [ "$protocol" = "hysteria" ] && def_port="8443"
    is_port_used "$def_port" && def_port=$(rand_port)

    local port
    while true; do
        prompt_input "监听端口" "$def_port" port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if is_port_used "$port"; then
                log_warn "端口 $port 已被占用"
                read -rp "  › 强制使用？[y/N]: " f_port
                [[ "$f_port" =~ ^[yY]$ ]] && break
            else
                break
            fi
        else
            log_warn "无效端口 (1-65535)"
        fi
    done

    # Credentials
    case "$protocol" in
        vless|vmess)
            prompt_input "用户 UUID" "$(rand_uuid)" client_id
            ;;
        trojan|hysteria)
            prompt_input "认证密码" "$(rand_str 16)" client_id
            ;;
        shadowsocks)
            case "$ss_method" in
                2022-blake3-aes-128-gcm) ss_pass=$(openssl rand -base64 16); prompt_input "密码/PSK (16字节Base64)" "$ss_pass" ss_pass ;;
                2022-blake3-aes-256-gcm) ss_pass=$(openssl rand -base64 32); prompt_input "密码/PSK (32字节Base64)" "$ss_pass" ss_pass ;;
                *)                       ss_pass=$(rand_str 16); prompt_input "连接密码" "$ss_pass" ss_pass ;;
            esac
            ;;
    esac

    # Transport Path / ServiceName
    if [ "$transport" = "xhttp" ] || [ "$transport" = "ws" ]; then
        prompt_input "分流路径" "/$(rand_str 8)" path
        [[ "$path" != /* ]] && path="/$path"
    fi
    [ "$security" = "none" ] && { [ "$transport" = "ws" ] || [ "$transport" = "xhttp" ]; } && prompt_input "CDN 伪装域名/Host (可选)" "" sni
    [ "$transport" = "grpc" ] && prompt_input "gRPC serviceName" "grpc-$(rand_str 6)" service_name

    # Security (REALITY / TLS)
    if [ "$security" = "reality" ]; then
        prompt_input "REALITY 伪装域名 (SNI)" "www.apple.com" sni
        local x_out
        x_out=$("$XRAY_BIN" x25519 2>/dev/null || echo "")
        priv_key=$(printf '%s\n' "$x_out" | awk 'tolower($0) ~ /private/{print $NF; exit}')
        pbk=$(printf '%s\n' "$x_out" | awk 'tolower($0) ~ /public|password/{print $NF; exit}')
        if [ -z "$priv_key" ] || [ -z "$pbk" ]; then
            log_error "生成 x25519 密钥对失败，请检查核心状态"
            pause && return 1
        fi
        short_id=$(openssl rand -hex 8)
        [ "$protocol" = "vless" ] && [ "$transport" = "tcp" ] && flow="xtls-rprx-vision"

    elif [ "$security" = "tls" ]; then
        prompt_choice "TLS 证书类型" "1" c_sel "自动生成自签名 EC 证书" "指定已有证书文件路径"
        if [ "$c_sel" = "1" ]; then
            prompt_input "伪装域名 (SNI)" "www.cloudflare.com" sni
            generate_self_signed_cert "$sni"
            cert_file="$XRAY_CERTS_DIR/self_signed.crt"
            key_file="$XRAY_CERTS_DIR/self_signed.key"
            insecure="1"
        else
            prompt_input "域名 (SNI)" "example.com" sni
            prompt_input "证书 .crt/.pem 绝对路径" "/root/cert.crt" cert_file
            prompt_input "私钥 .key 绝对路径" "/root/private.key" key_file
            [ ! -f "$cert_file" ] && log_warn "提示: 证书文件当前不存在，请稍后补全"
            [ ! -f "$key_file" ] && log_warn "提示: 私钥文件当前不存在，请稍后补全"
            insecure="0"
        fi
        [ "$protocol" = "vless" ] && [ "$transport" = "tcp" ] && flow="xtls-rprx-vision"
    fi

    local remark
    prompt_input "节点备注" "${protocol^^}-${transport^^}-${port}" remark

    # Construct JSON Objects
    local stream_settings
    stream_settings=$(jq -c -n \
        --arg net "$transport" --arg path "$path" --arg svc "$service_name" --arg sec "$security" \
        --arg dest "${sni}:443" --arg sni "$sni" --arg pk "$priv_key" --arg sid "$short_id" \
        --arg crt "$cert_file" --arg key "$key_file" \
        '{network: $net} +
        (if $net == "xhttp" then {xhttpSettings: {path: $path}}
         elif $net == "ws" then {wsSettings: ({path: $path} + (if $sni != "" then {host: $sni} else {} end))}
         elif $net == "grpc" then {grpcSettings: {serviceName: $svc}}
         elif $net == "hysteria" then {hysteriaSettings: {version: 2}}
         else {} end) +
        (if $sec == "reality" then {security: "reality", realitySettings: {show: false, dest: $dest, xver: 0, serverNames: [$sni], privateKey: $pk, minClientVer: "1.0.0", shortIds: [$sid]}}
         elif $sec == "tls" then {security: "tls", tlsSettings: ({certificates: [{certificateFile: $crt, keyFile: $key}]} + (if $net == "hysteria" then {alpn: ["h3"]} else {} end))}
         else {} end)')

    local settings
    case "$protocol" in
        vless)       settings=$(jq -c -n --arg id "$client_id" --arg flow "$flow" '{users: ([{id: $id} + (if $flow != "" then {flow: $flow} else {} end)]), decryption: "none"}') ;;
        vmess)       settings=$(jq -c -n --arg id "$client_id" '{users: [{id: $id}]}') ;;
        trojan)      settings=$(jq -c -n --arg pwd "$client_id" '{users: [{password: $pwd}]}') ;;
        shadowsocks) settings=$(jq -c -n --arg m "$ss_method" --arg p "$ss_pass" '{network: "tcp,udp", method: $m, password: $p}') ;;
        hysteria)    settings=$(jq -c -n --arg auth "$client_id" '{version: 2, users: [{auth: $auth}]}') ;;
    esac

    local inbound_obj
    inbound_obj=$(jq -c -n \
        --arg tag "${protocol}-${port}" --argjson port "$port" --arg proto "$protocol" \
        --argjson set "$settings" --argjson ss "$stream_settings" \
        --arg trans "$transport" --arg sec "$security" --arg rmk "$remark" \
        --arg path "$path" --arg svc "$service_name" --arg sni "$sni" --arg pbk "$pbk" \
        --arg sid "$short_id" --arg insec "$insecure" --arg flow "$flow" \
        '{
            tag: $tag, port: $port, listen: "::", protocol: $proto, settings: $set, streamSettings: $ss,
            sniffing: (if $proto == "shadowsocks" or $proto == "hysteria" then null else {enabled: true, destOverride: ["http", "tls", "quic"]} end),
            _meta: {
                protocol: $proto, transport: $trans, security: $sec, remark: $rmk,
                path: $path, serviceName: $svc, sni: $sni, publicKey: $pbk,
                shortId: $sid, insecure: $insec, flow: $flow
            }
        } | del(.sniffing | nulls)')

    local new_config
    new_config=$(jq --argjson inb "$inbound_obj" '.inbounds += [$inb]' "$XRAY_CONFIG")

    log_info "验证并应用配置..."
    if validate_and_apply_config "$new_config"; then
        log_success "节点已添加并生效"
        local inb_len
        inb_len=$(jq '.inbounds | length // 0' "$XRAY_CONFIG" 2>/dev/null)
        view_node_detail "$((inb_len - 1))"
    else
        pause
    fi
}

# ------------------------------------------------------------------------------
# Node Listing & Details
# ------------------------------------------------------------------------------
parse_node_meta() {
    local node="$1"
    {
        read -r port
        read -r meta_proto
        read -r meta_trans
        read -r meta_sec
        read -r meta_rmk
        read -r meta_path
        read -r meta_svc
        read -r meta_sni
        read -r meta_pbk
        read -r meta_sid
        read -r meta_insec
        read -r meta_flow
        read -r id_or_pwd
        read -r meta_address
    } < <(
        echo "$node" | jq -r '
            (.port | tostring),
            (._meta.protocol // .protocol),
            (._meta.transport // .streamSettings.network // "raw"),
            (._meta.security // .streamSettings.security // "none"),
            (._meta.remark // .tag // "Node"),
            (._meta.path // .streamSettings.xhttpSettings.path // .streamSettings.wsSettings.path // ""),
            (._meta.serviceName // .streamSettings.grpcSettings.serviceName // ""),
            (._meta.sni // .streamSettings.realitySettings.serverNames[0] // .streamSettings.tlsSettings.serverName // ""),
            (._meta.publicKey // ""),
            (._meta.shortId // .streamSettings.realitySettings.shortIds[0] // ""),
            (._meta.insecure // "0"),
            (._meta.flow // .settings.users[0].flow // .settings.clients[0].flow // ""),
            (.settings.users[0].id // .settings.clients[0].id // .settings.users[0].password // .settings.clients[0].password // .settings.users[0].auth // .settings.clients[0].auth // .settings.password // ""),
            (._meta.address // "")
        '
    )
}

get_connect_host() {
    if [ -n "$meta_address" ]; then
        format_url_host "$meta_address"
        return
    fi
    # 套 CDN 或配置了域名证书的 TLS 节点，优先使用域名作为连接地址
    if [ "$meta_sec" = "tls" ] && [ -n "$meta_sni" ] && [ "$meta_insec" != "1" ]; then
        echo "$meta_sni"
        return
    fi
    # 明文传输 (None) 但配置了 CDN 域名/Host 的节点
    if [ "$meta_sec" = "none" ] && [ -n "$meta_sni" ]; then
        echo "$meta_sni"
        return
    fi
    [ -z "$SERVER_IP" ] && get_public_ip
    format_url_host "${SERVER_IP:-127.0.0.1}"
}

build_share_link() {
    local target_host="$1"
    local enc_rmk enc_path link="" connect_host
    enc_rmk=$(urlencode "$meta_rmk") enc_path=$(urlencode "$meta_path")
    if [ -n "$target_host" ]; then
        connect_host=$(format_url_host "$target_host")
    else
        connect_host=$(get_connect_host)
    fi

    case "$meta_proto" in
        vless)
            link="vless://${id_or_pwd}@${connect_host}:${port}?type=${meta_trans}&security=${meta_sec}"
            [ "$meta_sec" = "reality" ] && link="${link}&pbk=${meta_pbk}&fp=chrome&sni=${meta_sni}&sid=${meta_sid}"
            [ "$meta_sec" = "tls" ] && link="${link}&fp=chrome&sni=${meta_sni}"
            [ "$meta_sec" = "tls" ] && [ "$meta_insec" = "1" ] && link="${link}&allowInsecure=1"
            [ "$meta_trans" = "xhttp" ] && link="${link}&path=${enc_path}&mode=auto"
            [ "$meta_trans" = "ws" ] && { link="${link}&path=${enc_path}"; [ -n "$meta_sni" ] && link="${link}&host=${meta_sni}"; }
            [ "$meta_trans" = "grpc" ] && link="${link}&serviceName=${meta_svc}&mode=gun"
            [ "$meta_trans" = "tcp" ] && [ -n "$meta_flow" ] && link="${link}&flow=${meta_flow}"
            link="${link}#${enc_rmk}"
            ;;
        vmess)
            local tls_flag="" v_path="$meta_path"
            [ "$meta_sec" = "tls" ] && tls_flag="tls"
            [ "$meta_trans" = "grpc" ] && v_path="$meta_svc"
            local v_host="${connect_host//[\[\]]/}"
            local vjson
            vjson=$(jq -c -n \
                --arg ps "$meta_rmk" --arg add "$v_host" --argjson port "$port" \
                --arg id "$id_or_pwd" --arg net "$meta_trans" --arg host "$meta_sni" \
                --arg path "$v_path" --arg tls "$tls_flag" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:0, scy:"auto", net:$net, type:"none", host:$host, path:$path, tls:$tls}')
            link="vmess://$(base64_encode "$vjson")"
            ;;
        trojan)
            link="trojan://${id_or_pwd}@${connect_host}:${port}?security=${meta_sec}&sni=${meta_sni}&type=${meta_trans}"
            [ "$meta_sec" = "reality" ] && link="${link}&pbk=${meta_pbk}&sid=${meta_sid}&fp=chrome"
            [ "$meta_sec" = "tls" ] && [ "$meta_insec" = "1" ] && link="${link}&allowInsecure=1"
            [ "$meta_trans" = "ws" ] && { link="${link}&path=${enc_path}"; [ -n "$meta_sni" ] && link="${link}&host=${meta_sni}"; }
            [ "$meta_trans" = "grpc" ] && link="${link}&serviceName=${meta_svc}"
            [ "$meta_trans" = "xhttp" ] && link="${link}&path=${enc_path}&mode=auto"
            link="${link}#${enc_rmk}"
            ;;
        shadowsocks)
            local method
            method=$(echo "$node" | jq -r '.settings.method // ""')
            link="ss://$(base64_encode "${method}:${id_or_pwd}")@${connect_host}:${port}#${enc_rmk}"
            ;;
        hysteria)
            link="hysteria2://${id_or_pwd}@${connect_host}:${port}/?sni=${meta_sni}&insecure=${meta_insec}#${enc_rmk}"
            ;;
    esac
    echo "$link"
}

print_share_link() {
    local label="$1" host="$2" link
    link=$(build_share_link "$host")
    echo -e "  ${C_BOLD}${label}:${C_RESET}\n  ${C_CYAN}${link}${C_RESET}"
    [ "$meta_proto" = "hysteria" ] && echo -e "  ${C_GRAY}兼容链接 (hy2://):${C_RESET}\n  ${C_CYAN}${link/hysteria2:\/\//hy2:\/\/}${C_RESET}"
}

view_node_detail() {
    local idx="$1" node
    node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG" 2>/dev/null)
    [ -z "$node" ] || [ "$node" = "null" ] && { log_error "节点不存在"; pause; return; }

    parse_node_meta "$node"
    local connect_host
    connect_host=$(get_connect_host)

    header
    echo -e "  ${C_BOLD}节点配置详情${C_RESET}"
    line
    printf "  ${C_GRAY}备注名称${C_RESET}  %s\n" "$meta_rmk"
    printf "  ${C_GRAY}协议类型${C_RESET}  %s\n" "${meta_proto^^}"
    if [ "$connect_host" != "$SERVER_IP" ] && [ "$connect_host" != "[$SERVER_IP]" ]; then
        printf "  ${C_GRAY}连接地址${C_RESET}  %s (域名/CDN)\n" "$connect_host"
    fi
    if [ -n "$SERVER_IPV4" ] && [ -n "$SERVER_IPV6" ]; then
        printf "  ${C_GRAY}IPv4地址${C_RESET}  %s\n" "$SERVER_IPV4"
        printf "  ${C_GRAY}IPv6地址${C_RESET}  %s\n" "$SERVER_IPV6"
    elif [ -n "$SERVER_IPV4" ]; then
        printf "  ${C_GRAY}IPv4地址${C_RESET}  %s\n" "$SERVER_IPV4"
    elif [ -n "$SERVER_IPV6" ]; then
        printf "  ${C_GRAY}IPv6地址${C_RESET}  %s\n" "$SERVER_IPV6"
    else
        printf "  ${C_GRAY}服务器IP${C_RESET}  %s\n" "${SERVER_IP:-获取中...}"
    fi
    printf "  ${C_GRAY}监听端口${C_RESET}  %s\n" "$port"
    printf "  ${C_GRAY}传输方式${C_RESET}  %s\n" "$meta_trans"
    printf "  ${C_GRAY}安全加密${C_RESET}  %s\n" "${meta_sec^^}"

    case "$meta_proto" in
        vless|vmess)        printf "  ${C_GRAY}用户UUID${C_RESET}  %s\n" "$id_or_pwd" ;;
        trojan|hysteria)    printf "  ${C_GRAY}认证密码${C_RESET}  %s\n" "$id_or_pwd" ;;
        shadowsocks)
            printf "  ${C_GRAY}加密算法${C_RESET}  %s\n" "$(echo "$node" | jq -r '.settings.method // ""')"
            printf "  ${C_GRAY}连接密码${C_RESET}  %s\n" "$id_or_pwd"
            ;;
    esac

    [ -n "$meta_path" ] && printf "  ${C_GRAY}分流路径${C_RESET}  %s\n" "$meta_path"
    [ -n "$meta_svc" ] && printf "  ${C_GRAY}服务名称${C_RESET}  %s\n" "$meta_svc"
    if [ -n "$meta_sni" ]; then
        if [ "$meta_sec" = "reality" ]; then
            printf "  ${C_GRAY}伪装域名${C_RESET}  %s (REALITY)\n" "$meta_sni"
        else
            printf "  ${C_GRAY}域名(SNI)${C_RESET} %s\n" "$meta_sni"
        fi
    fi
    [ -n "$meta_pbk" ] && printf "  ${C_GRAY}公钥 PBK${C_RESET}  %s\n" "$meta_pbk"
    [ -n "$meta_sid" ] && printf "  ${C_GRAY}Short ID${C_RESET}  %s\n" "$meta_sid"
    [ "$meta_sec" = "tls" ] && [ "$meta_insec" = "1" ] && printf "  ${C_GRAY}自签证书${C_RESET}  %s (insecure=1)\n" "允许"

    line
    if [ "$connect_host" != "$SERVER_IP" ] && [ "$connect_host" != "[$SERVER_IP]" ]; then
        print_share_link "分享链接"
    elif [ -n "$SERVER_IPV4" ] && [ -n "$SERVER_IPV6" ]; then
        print_share_link "分享链接 (IPv4)" "$SERVER_IPV4"
        echo ""
        print_share_link "分享链接 (IPv6)" "$SERVER_IPV6"
    else
        print_share_link "分享链接"
    fi

    line
    echo -e "  ${C_CYAN}1.${C_RESET} 查看客户端 JSON 配置    ${C_GRAY}0. 返回列表 (回车)${C_RESET}"
    read -rp "  › 请选择操作 [0]: " opt
    if [ "$opt" = "1" ]; then
        line
        echo -e "  ${C_BOLD}客户端 Outbound 配置:${C_RESET}"
        local json_host="${connect_host//[\[\]]/}"
        echo "$node" | jq \
            --arg ip "$json_host" --arg pbk "$meta_pbk" --arg sid "$meta_sid" --arg sni "$meta_sni" --arg auth "$id_or_pwd" \
            '{
                tag: ("proxy-" + .protocol), protocol: .protocol,
                settings: (if .protocol == "vless" then {vnext: [{address: $ip, port: .port, users: [{id: (.settings.users[0].id // .settings.clients[0].id), encryption: "none"} + (if (._meta.flow // "") != "" then {flow: ._meta.flow} else {} end)]}]}
                           elif .protocol == "vmess" then {vnext: [{address: $ip, port: .port, users: [{id: (.settings.users[0].id // .settings.clients[0].id), alterId: 0}]}]}
                           elif .protocol == "trojan" then {servers: [{address: $ip, port: .port, password: (.settings.users[0].password // .settings.clients[0].password)}]}
                           elif .protocol == "shadowsocks" then {servers: [{address: $ip, port: .port, method: .settings.method, password: .settings.password}]}
                           elif .protocol == "hysteria" then {version: 2, address: $ip, port: .port}
                           else .settings end),
                streamSettings: (.streamSettings |
                    if .security == "reality" then .realitySettings = {serverName: $sni, fingerprint: "chrome", show: false, publicKey: $pbk, shortId: $sid}
                    elif .security == "tls" then .tlsSettings = ({serverName: $sni} + (if .network == "hysteria" then {alpn: ["h3"]} else {} end))
                    else . end |
                    if .network == "hysteria" then .hysteriaSettings = {version: 2, auth: $auth}
                    elif .network == "xhttp" then .xhttpSettings += {mode: "auto", xmux: {maxConcurrency: 16}}
                    else . end
                )
            }'
        pause
    fi
}

print_node_list() {
    local i=1
    while IFS='|' read -r p_port p_proto p_rmk; do
        [ -z "$p_port" ] && continue
        printf "  %2d. %-10s 端口: %-5s (%s)\n" "$i" "${p_proto^^}" "$p_port" "$p_rmk"
        i=$((i + 1))
    done < <(jq -r '.inbounds[]? | "\(.port)|\(._meta.protocol // .protocol)|\(._meta.remark // .tag // "Node")"' "$XRAY_CONFIG" 2>/dev/null)
}

list_nodes() {
    while true; do
        header
        ! is_installed && { log_warn "核心未安装"; pause; return; }

        local count
        count=$(get_node_count)
        [ "$count" -eq 0 ] && { log_warn "暂无节点"; pause; return; }

        printf "  ${C_GRAY}%-4s  %-14s  %-9s  %-12s  %-11s  %s${C_RESET}\n" "#" "协议" "端口" "传输" "安全" "备注"
        line

        local i=1
        while IFS='|' read -r p_port p_proto p_trans p_sec p_rmk; do
            [ -z "$p_port" ] && continue
            printf "  %-4d  %-12s  %-7s  %-10s  %-9s  %s\n" \
                "$i" "${p_proto^^}" "$p_port" "$p_trans" "${p_sec^^}" "$p_rmk"
            i=$((i + 1))
        done < <(jq -r '.inbounds[]? | "\(.port)|\(._meta.protocol // .protocol)|\(._meta.transport // .streamSettings.network // "raw")|\(._meta.security // .streamSettings.security // "none")|\(._meta.remark // .tag // "Node")"' "$XRAY_CONFIG" 2>/dev/null)

        line
        read -rp "  › 请输入节点编号 [1-$count, 回车返回]: " node_choice
        [ -z "$node_choice" ] || [ "$node_choice" = "0" ] && break

        if [[ "$node_choice" =~ ^[0-9]+$ ]] && [ "$node_choice" -ge 1 ] && [ "$node_choice" -le "$count" ]; then
            view_node_detail "$((node_choice - 1))"
        else
            log_warn "输入无效" && sleep 1
        fi
    done
}

edit_single_node() {
    local idx="$1" node=""
    node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG" 2>/dev/null)
    [ -z "$node" ] || [ "$node" = "null" ] && { log_error "节点不存在"; pause; return; }
    parse_node_meta "$node"

    while true; do
        local connect_host
        connect_host=$(get_connect_host)

        header
        echo -e "  ${C_BOLD}修改节点: ${C_CYAN}${meta_rmk}${C_RESET} (${meta_proto^^} · ${port})"
        line
        echo -e "  ${C_CYAN}1.${C_RESET} 监听端口        [当前: ${port}]"

        local cred_label="认证密码"
        [ "$meta_proto" = "vless" ] || [ "$meta_proto" = "vmess" ] && cred_label="用户 UUID"
        [ "$meta_proto" = "shadowsocks" ] && cred_label="连接密码"
        echo -e "  ${C_CYAN}2.${C_RESET} ${cred_label}    [当前: ${id_or_pwd:0:8}...]"

        local trans_show=""
        { [ "$meta_trans" = "xhttp" ] || [ "$meta_trans" = "ws" ]; } && trans_show="分流路径"
        [ "$meta_trans" = "grpc" ] && trans_show="serviceName"
        [ -n "$trans_show" ] && echo -e "  ${C_CYAN}3.${C_RESET} ${trans_show}        [当前: ${meta_path:-$meta_svc}]"

        if [ "$meta_sec" = "reality" ] || [ "$meta_sec" = "tls" ] || { [ "$meta_sec" = "none" ] && [ -n "$meta_sni" ]; }; then
            echo -e "  ${C_CYAN}4.${C_RESET} 域名/SNI/Host   [当前: ${meta_sni}]"
        fi
        [ "$meta_sec" = "reality" ] && echo -e "  ${C_CYAN}5.${C_RESET} 重置 REALITY 密钥对与 ShortId"
        echo -e "  ${C_CYAN}6.${C_RESET} 节点备注名称    [当前: ${meta_rmk}]"
        echo -e "  ${C_CYAN}7.${C_RESET} 连接地址/CDN域名 [当前: ${meta_address:-自动($connect_host)}]"
        echo -e "  ${C_CYAN}8.${C_RESET} 完整重新配置该节点"
        line
        read -rp "  › 请选择修改项 [回车返回]: " mod_opt
        [ -z "$mod_opt" ] || [ "$mod_opt" = "0" ] && break

        local up_inb="" msg=""
        case "$mod_opt" in
            1)
                local new_port
                while true; do
                    prompt_input "新监听端口" "$port" new_port
                    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                        if [ "$new_port" != "$port" ] && is_port_used "$new_port"; then
                            log_warn "端口 $new_port 已被占用"
                            read -rp "  › 强制使用？[y/N]: " f_port
                            [[ "$f_port" =~ ^[yY]$ ]] && break
                        else
                            break
                        fi
                    else
                        log_warn "无效端口 (1-65535)"
                    fi
                done
                if [ "$new_port" != "$port" ]; then
                    up_inb=$(echo "$node" | jq --argjson p "$new_port" '.port = $p | ._meta.port = $p | .tag = ((._meta.protocol // "node") + "-" + ($p|tostring))')
                    msg="端口已更新为 $new_port"
                fi
                ;;
            2)
                local new_cred=""
                if [ "$meta_proto" = "vless" ] || [ "$meta_proto" = "vmess" ]; then
                    prompt_input "用户 UUID (输入 r 随机生成)" "$id_or_pwd" new_cred
                    [ "$new_cred" = "r" ] && new_cred=$(rand_uuid)
                    up_inb=$(echo "$node" | jq --arg id "$new_cred" 'if .settings.clients then .settings.clients[0].id = $id else .settings.users[0].id = $id end | ._meta.uuid = $id')
                elif [ "$meta_proto" = "trojan" ]; then
                    prompt_input "连接密码 (输入 r 随机生成)" "$id_or_pwd" new_cred
                    [ "$new_cred" = "r" ] && new_cred=$(rand_str 16)
                    up_inb=$(echo "$node" | jq --arg pwd "$new_cred" 'if .settings.clients then .settings.clients[0].password = $pwd else .settings.users[0].password = $pwd end | ._meta.password = $pwd')
                elif [ "$meta_proto" = "hysteria" ]; then
                    prompt_input "认证密码 (输入 r 随机生成)" "$id_or_pwd" new_cred
                    [ "$new_cred" = "r" ] && new_cred=$(rand_str 16)
                    up_inb=$(echo "$node" | jq --arg pwd "$new_cred" 'if .settings.clients then .settings.clients[0].auth = $pwd else .settings.users[0].auth = $pwd end | ._meta.auth = $pwd')
                elif [ "$meta_proto" = "shadowsocks" ]; then
                    prompt_input "密码/PSK" "$id_or_pwd" new_cred
                    up_inb=$(echo "$node" | jq --arg pwd "$new_cred" '.settings.password = $pwd | ._meta.password = $pwd')
                fi
                [ -n "$new_cred" ] && [ "$new_cred" != "$id_or_pwd" ] && msg="${cred_label}已更新" || up_inb=""
                ;;
            3)
                if [ "$meta_trans" = "grpc" ]; then
                    local new_svc; prompt_input "gRPC serviceName" "$meta_svc" new_svc
                    up_inb=$(echo "$node" | jq --arg s "$new_svc" '.streamSettings.grpcSettings.serviceName = $s | ._meta.serviceName = $s')
                else
                    local new_path; prompt_input "分流路径" "$meta_path" new_path
                    [[ "$new_path" != /* ]] && new_path="/$new_path"
                    local field="wsSettings"
                    [ "$meta_trans" = "xhttp" ] && field="xhttpSettings"
                    up_inb=$(echo "$node" | jq --arg p "$new_path" --arg f "$field" '.streamSettings[$f].path = $p | ._meta.path = $p')
                fi
                msg="路径/服务名已更新"
                ;;
            4)
                local new_sni; prompt_input "域名/SNI/Host" "$meta_sni" new_sni
                if [ "$meta_sec" = "reality" ]; then
                    up_inb=$(echo "$node" | jq --arg s "$new_sni" --arg dest "${new_sni}:443" \
                        '.streamSettings.realitySettings.serverNames = [$s] | .streamSettings.realitySettings.dest = $dest | ._meta.sni = $s')
                else
                    up_inb=$(echo "$node" | jq --arg s "$new_sni" \
                        '._meta.sni = $s | (if .streamSettings.wsSettings then .streamSettings.wsSettings.host = $s else . end)')
                fi
                msg="域名/SNI 已更新"
                ;;
            5)
                if [ "$meta_sec" = "reality" ]; then
                    local x_out priv_k pub_k sid
                    x_out=$("$XRAY_BIN" x25519 2>/dev/null || echo "")
                    priv_k=$(printf '%s\n' "$x_out" | awk 'tolower($0) ~ /private/{print $NF; exit}')
                    pub_k=$(printf '%s\n' "$x_out" | awk 'tolower($0) ~ /public|password/{print $NF; exit}')
                    sid=$(openssl rand -hex 8)
                    if [ -n "$priv_k" ] && [ -n "$pub_k" ]; then
                        up_inb=$(echo "$node" | jq --arg pk "$priv_k" --arg sid "$sid" --arg pbk "$pub_k" \
                            '.streamSettings.realitySettings.privateKey = $pk | .streamSettings.realitySettings.shortIds = [$sid] | .streamSettings.realitySettings.minClientVer = "1.0.0" | ._meta.publicKey = $pbk | ._meta.shortId = $sid')
                        msg="REALITY 密钥对已重置"
                    fi
                fi
                ;;
            6)
                local new_rmk; prompt_input "节点备注" "$meta_rmk" new_rmk
                up_inb=$(echo "$node" | jq --arg r "$new_rmk" '._meta.remark = $r')
                msg="备注已更新为 $new_rmk"
                ;;
            7)
                local new_addr
                prompt_input "连接地址/域名/优选IP (留空则恢复自动检测)" "${meta_address}" new_addr
                up_inb=$(echo "$node" | jq --arg a "$new_addr" '._meta.address = $a')
                msg="连接地址已更新"
                ;;
            8)
                log_info "进入完整重配向导..."
                local new_cfg
                new_cfg=$(jq --argjson idx "$idx" 'del(.inbounds[$idx])' "$XRAY_CONFIG")
                validate_and_apply_config "$new_cfg"
                add_node_wizard
                return
                ;;
        esac

        if [ -n "$up_inb" ]; then
            local new_cfg
            new_cfg=$(jq --argjson idx "$idx" --argjson inb "$up_inb" '.inbounds[$idx] = $inb' "$XRAY_CONFIG")
            if validate_and_apply_config "$new_cfg"; then
                log_success "$msg"
                node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG")
                parse_node_meta "$node" && sleep 1
            fi
        fi
    done
}

modify_node() {
    while true; do
        header
        ! is_installed && { log_warn "核心未安装"; pause; return; }

        local count
        count=$(get_node_count)
        [ "$count" -eq 0 ] && { log_warn "暂无节点"; pause; return; }

        echo -e "  ${C_BOLD}修改入站节点${C_RESET}"
        line
        print_node_list
        line

        read -rp "  › 请输入要修改的编号 [1-$count, 回车返回]: " mod_idx
        [ -z "$mod_idx" ] || [ "$mod_idx" = "0" ] && break

        if [[ "$mod_idx" =~ ^[0-9]+$ ]] && [ "$mod_idx" -ge 1 ] && [ "$mod_idx" -le "$count" ]; then
            edit_single_node "$((mod_idx - 1))"
        else
            log_warn "输入无效 (1-$count)" && sleep 1
        fi
    done
}

delete_node() {
    while true; do
        header
        ! is_installed && { log_warn "核心未安装"; pause; return; }

        local count
        count=$(get_node_count)
        [ "$count" -eq 0 ] && { log_warn "暂无节点"; pause; return; }

        echo -e "  ${C_BOLD}删除入站节点${C_RESET}"
        line
        print_node_list
        line

        read -rp "  › 请输入要删除的编号 [1-$count, 回车返回]: " del_idx
        [ -z "$del_idx" ] || [ "$del_idx" = "0" ] && break

        if [[ "$del_idx" =~ ^[0-9]+$ ]] && [ "$del_idx" -ge 1 ] && [ "$del_idx" -le "$count" ]; then
            local real_idx=$((del_idx - 1))
            read -rp "  › 确认删除？[y/N]: " confirm_del
            if [[ "$confirm_del" =~ ^[yY]$ ]]; then
                local new_config
                new_config=$(jq --argjson idx "$real_idx" 'del(.inbounds[$idx])' "$XRAY_CONFIG")
                if validate_and_apply_config "$new_config"; then
                    log_success "节点已删除"
                    sleep 1
                fi
            else
                log_info "已取消"
                sleep 1
            fi
        else
            log_warn "输入无效 (1-$count)"
            sleep 1
        fi
    done
}

# ------------------------------------------------------------------------------
# System Optimization (BBR)
# ------------------------------------------------------------------------------
enable_bbr() {
    header
    echo -e "  ${C_BOLD}BBR 拥塞控制${C_RESET}"
    line

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "")
    if [ "$current_cc" = "bbr" ]; then
        log_success "BBR 处于开启状态"
        pause && return
    fi

    log_info "配置 BBR 内核参数..."
    modprobe tcp_bbr 2>/dev/null || true

    local sysctl_file="/etc/sysctl.d/99-bbr.conf"
    [ ! -d "/etc/sysctl.d" ] && sysctl_file="/etc/sysctl.conf"

    sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' "$sysctl_file" 2>/dev/null || true
    if [ "$sysctl_file" != "/etc/sysctl.conf" ]; then
        sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    fi
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" >> "$sysctl_file"

    sysctl -p "$sysctl_file" >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true

    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "")
    if [ "$new_cc" = "bbr" ]; then
        log_success "BBR 开启成功"
    else
        log_warn "已应用，当前算法: $new_cc"
    fi
    pause
}

# ------------------------------------------------------------------------------
# Main Loop
# ------------------------------------------------------------------------------
detect_os
detect_init
detect_arch

main() {
    check_root
    check_ipv6_only
    install_deps
    setup_shortcut
    get_public_ip

    while true; do
        header

        local auto_tag="${C_GRAY}关${C_RESET}"
        is_autostart_enabled && auto_tag="${C_GREEN}开${C_RESET}"

        echo -e "  ${C_CYAN}1.${C_RESET} 添加入站节点    ${C_CYAN}5.${C_RESET} 启动服务    ${C_CYAN} 9.${C_RESET} 安装/更新核心"
        echo -e "  ${C_CYAN}2.${C_RESET} 查看节点列表    ${C_CYAN}6.${C_RESET} 停止服务    ${C_CYAN}10.${C_RESET} 自启开关 [${auto_tag}]"
        echo -e "  ${C_CYAN}3.${C_RESET} 修改入站节点    ${C_CYAN}7.${C_RESET} 重启服务    ${C_CYAN}11.${C_RESET} 开启 BBR"
        echo -e "  ${C_CYAN}4.${C_RESET} 删除入站节点    ${C_CYAN}8.${C_RESET} 实时日志    ${C_CYAN}12.${C_RESET} 卸载核心"
        line

        read -rp "  › 请选择操作 [回车退出]: " choice || exit 0
        case "$choice" in
            ""|0|[qQ]|[eE][xX][iI][tT])
                clear 2>/dev/null || true
                echo -e "\n  ${C_CYAN}已退出 Xray 管理面板${C_RESET}\n"
                exit 0
                ;;
            1) add_node_wizard ;;
            2) list_nodes ;;
            3) modify_node ;;
            4) delete_node ;;
            5) service_ctrl start; pause ;;
            6) service_ctrl stop; pause ;;
            7) service_ctrl restart; pause ;;
            8) view_logs ;;
            9) install_xray ;;
            10) service_toggle_autostart; pause ;;
            11) enable_bbr ;;
            12) uninstall_xray ;;
            *)
                log_warn "输入无效" && sleep 1
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
