#!/usr/bin/env bash
# ==============================================================================
#  xray.sh - Minimalist Xray Core Management Script
#  Supported OS: Debian / Ubuntu / Alpine Linux
#  Protocols:    VLESS, VMess, Trojan, Shadowsocks, Hysteria (Hysteria 2)
#  Transports:   xhttp, grpc, websocket, raw/tcp
# ==============================================================================

if [ -z "$BASH_VERSION" ]; then
    case "$0" in
        *bash|*sh) ;;
        *)
            if ! command -v bash >/dev/null 2>&1; then
                if [ -f /etc/alpine-release ]; then
                    apk update >/dev/null 2>&1 && apk add bash >/dev/null 2>&1
                elif [ -f /etc/debian_version ]; then
                    apt-get update -y >/dev/null 2>&1 && apt-get install -y bash >/dev/null 2>&1
                fi
            fi
            exec bash "$0" "$@"
            ;;
    esac
fi

set -o pipefail

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

SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_LINK="/usr/local/bin/xray"

# Colors & Formatting
if [ -t 1 ]; then
    C_RESET="\033[0m" C_BOLD="\033[1m" C_DIM="\033[2m"
    C_CYAN="\033[36m" C_GREEN="\033[32m" C_YELLOW="\033[33m"
    C_RED="\033[31m" C_GRAY="\033[90m"
else
    C_RESET="" C_BOLD="" C_DIM="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_GRAY=""
fi

# ------------------------------------------------------------------------------
# UI Helpers
# ------------------------------------------------------------------------------
line() { echo -e "${C_GRAY}────────────────────────────────────────────────────────────────${C_RESET}"; }
log_info()    { echo -e "  ${C_CYAN}›${C_RESET} $1"; }
log_success() { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
log_warn()    { echo -e "  ${C_YELLOW}!${C_RESET} $1"; }
log_error()   { echo -e "  ${C_RED}✖${C_RESET} $1"; }
pause()       { echo ""; read -rp "  › 按回车键继续..." dummy; }

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

    local node_count=0
    [ -f "$XRAY_CONFIG" ] && node_count=$(jq '.inbounds | length' "$XRAY_CONFIG" 2>/dev/null || echo 0)
    local ip_str="${SERVER_IP:-获取中...}"

    local rem=$(( 16 - ${#node_count} ))
    [ "$rem" -lt 1 ] && rem=1

    printf "  ${C_BOLD}%-32s${C_RESET} ${C_GRAY}状态:${C_RESET} %b\n" "Xray Core Manager" "$status_str"
    printf "  ${C_GRAY}系统:${C_RESET} %-26s ${C_GRAY}地址:${C_RESET} %s\n" "$OS_NAME ($ARCH)" "$ip_str"
    printf "  ${C_GRAY}节点:${C_RESET} %d 个活跃入站%*s${C_GRAY}自启:${C_RESET} %b\n" "$node_count" "$rem" "" "$auto_str"
    line
}

prompt_input() {
    local prompt="$1" default_val="$2" var_name="$3" user_val=""
    if [ -n "$default_val" ]; then
        read -rp "  › ${prompt} [${C_CYAN}${default_val}${C_RESET}]: " user_val
        [ -z "$user_val" ] && user_val="$default_val"
    else
        read -rp "  › ${prompt}: " user_val
    fi
    eval "$var_name=\"\$user_val\""
}

prompt_choice() {
    local prompt="$1" default_idx="$2" var_name="$3"; shift 3
    local options=("$@")
    echo -e "  › ${C_BOLD}${prompt}:${C_RESET}"
    for i in "${!options[@]}"; do
        local idx=$((i + 1))
        if [ "$idx" -eq "$default_idx" ]; then
            echo -e "    ${C_CYAN}${idx}.${C_RESET} ${options[i]} ${C_GRAY}(默认)${C_RESET}"
        else
            echo -e "    ${C_GRAY}${idx}.${C_RESET} ${options[i]}"
        fi
    done
    while true; do
        read -rp "  › 请选择 [1-${#options[@]}, 默认: ${default_idx}]: " choice
        [ -z "$choice" ] && choice="$default_idx"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            eval "$var_name=\"\$choice\""
            break
        else
            log_warn "输入无效，请输入 1 到 ${#options[@]}"
        fi
    done
}

# ------------------------------------------------------------------------------
# System Detection & Dependencies
# ------------------------------------------------------------------------------
check_root() {
    [ "$(id -u)" -ne 0 ] && { log_error "请使用 root 权限运行此脚本"; exit 1; }
}

detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
        OS_NAME="Alpine $(cat /etc/alpine-release 2>/dev/null || echo "")"
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        local dver
        dver=$(cat /etc/debian_version 2>/dev/null || echo "")
        OS_NAME="Debian ${dver%%.*}"
    else
        OS_TYPE="unknown"
        OS_NAME="Linux"
    fi
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

get_public_ip() {
    [ -n "$SERVER_IP" ] && return
    SERVER_IP=$(curl -s4m 3 https://api.ipify.org || curl -s4m 3 https://ipv4.icanhazip.com || curl -s4m 3 https://ifconfig.me 2>/dev/null || echo "")
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s6m 3 https://api64.ipify.org 2>/dev/null || echo "127.0.0.1")
}

install_deps() {
    local missing=()
    for cmd in curl wget unzip tar openssl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "正在安装必要依赖: ${missing[*]}..."
        if [ "$OS_TYPE" = "alpine" ]; then
            apk update >/dev/null 2>&1 && apk add curl wget unzip tar openssl jq ca-certificates procps bash >/dev/null 2>&1
        elif [ "$OS_TYPE" = "debian" ]; then
            apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget unzip tar openssl jq ca-certificates procps bash >/dev/null 2>&1
        fi
        log_success "依赖安装完成"
    fi
}

setup_shortcut() {
    rm -f /usr/local/bin/xrsy 2>/dev/null || true
    if [ -f "$SCRIPT_LINK" ] && [ ! -L "$SCRIPT_LINK" ]; then
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
    if [ -f "$target_script" ] && [ "$(basename "$target_script")" != "bash" ] && [ "$(basename "$target_script")" != "sh" ]; then
        ln -sf "$target_script" "$SCRIPT_LINK" 2>/dev/null || true
        chmod +x "$SCRIPT_LINK" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Service Lifecycle
# ------------------------------------------------------------------------------
is_installed() {
    if [ ! -x "$XRAY_BIN" ] && [ -f "/usr/local/bin/xray" ] && [ ! -L "/usr/local/bin/xray" ]; then
        mkdir -p "$XRAY_SHARE_DIR"
        mv -f "/usr/local/bin/xray" "$XRAY_BIN" 2>/dev/null || true
    fi
    [ -x "$XRAY_BIN" ]
}

is_running() {
    [ -x "$XRAY_BIN" ] || return 1
    if [ "$INIT_TYPE" = "systemd" ]; then
        systemctl is-active --quiet xray 2>/dev/null
    elif [ "$INIT_TYPE" = "openrc" ]; then
        rc-service xray status 2>/dev/null | grep -q "status: started"
    else
        [ -f "$DAEMON_PID_FILE" ] && kill -0 "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null
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
                nohup "$XRAY_BIN" run -c "$XRAY_CONFIG" >> "$XRAY_ACCESS_LOG" 2>> "$XRAY_ERROR_LOG" &
                echo $! > "$DAEMON_PID_FILE"
                ;;
            stop)
                [ -f "$DAEMON_PID_FILE" ] && kill "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null || true
                rm -f "$DAEMON_PID_FILE"; pkill -x xray-core 2>/dev/null || true
                ;;
            restart)
                svc stop; sleep 1; svc start
                ;;
        esac
    fi
}

service_start() {
    is_running && { log_info "服务已在运行中"; return; }
    svc start; sleep 1
    is_running && log_success "服务启动成功" || log_error "服务启动失败，请检查配置或日志"
}

service_stop() {
    ! is_running && { log_info "服务未运行"; return; }
    svc stop; sleep 1
    ! is_running && log_success "服务已停止" || log_error "服务停止失败"
}

service_restart() {
    svc restart; sleep 1
    is_running && log_success "服务重启成功" || log_error "服务重启失败，请检查日志"
}

service_toggle_autostart() {
    if is_autostart_enabled; then
        [ "$INIT_TYPE" = "systemd" ] && systemctl disable xray >/dev/null 2>&1
        [ "$INIT_TYPE" = "openrc" ] && rc-update del xray default >/dev/null 2>&1
        log_success "已关闭开机自启"
    else
        [ "$INIT_TYPE" = "systemd" ] && systemctl enable xray >/dev/null 2>&1
        [ "$INIT_TYPE" = "openrc" ] && rc-update add xray default >/dev/null 2>&1
        log_success "已开启开机自启"
    fi
}

view_logs() {
    header
    echo -e "  ${C_CYAN}实时查看 Xray 日志 (按 Ctrl+C 返回菜单):${C_RESET}"
    line
    if [ -f "$XRAY_ERROR_LOG" ] || [ -f "$XRAY_ACCESS_LOG" ]; then
        trap ' ' INT
        tail -n 50 -f "$XRAY_ERROR_LOG" "$XRAY_ACCESS_LOG" 2>/dev/null
        trap - INT
    else
        log_warn "暂无日志文件 ($XRAY_LOG_DIR)"
        pause
    fi
}

# ------------------------------------------------------------------------------
# Install & Uninstall
# ------------------------------------------------------------------------------
get_latest_xray_version() {
    local tag
    tag=$(curl -sIL -o /dev/null -w '%{url_effective}' --max-time 5 https://github.com/XTLS/Xray-core/releases/latest | grep -o '[^/]*$' || echo "")
    [ -z "$tag" ] || [ "$tag" = "latest" ] && tag=$(curl -sL --max-time 5 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name // empty' 2>/dev/null || echo "")
    echo "${tag:-v26.10.29}"
}

init_config_if_needed() {
    mkdir -p "$XRAY_CONFIG_DIR" "$XRAY_CERTS_DIR" "$XRAY_LOG_DIR" "$XRAY_SHARE_DIR"
    touch "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
    chmod 755 "$XRAY_LOG_DIR" && chmod 644 "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
    if [ ! -s "$XRAY_CONFIG" ]; then
        cat << 'EOF' > "$XRAY_CONFIG"
{
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "blocked"}],
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
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -c $XRAY_CONFIG
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable xray >/dev/null 2>&1 || true
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
    log_info "正在获取 Xray 核心最新版本..."
    local ver
    ver=$(get_latest_xray_version)
    log_info "目标版本: ${C_CYAN}${ver}${C_RESET}"

    local url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${ARCH}.zip"
    local tmp_dir="/tmp/xray_install_$$"
    mkdir -p "$tmp_dir" "$XRAY_SHARE_DIR"

    log_info "正在下载: ${url}..."
    if ! curl -sL --fail "$url" -o "$tmp_dir/xray.zip"; then
        log_error "下载核心失败，请检查网络"
        rm -rf "$tmp_dir"
        pause && return 1
    fi

    unzip -q -o "$tmp_dir/xray.zip" -d "$tmp_dir"
    install -m 755 "$tmp_dir/xray" "$XRAY_BIN"
    [ -f "$tmp_dir/geoip.dat" ] && install -m 644 "$tmp_dir/geoip.dat" "$XRAY_SHARE_DIR/"
    [ -f "$tmp_dir/geosite.dat" ] && install -m 644 "$tmp_dir/geosite.dat" "$XRAY_SHARE_DIR/"
    rm -rf "$tmp_dir"

    init_config_if_needed
    setup_service_units
    setup_shortcut

    log_success "Xray 核心安装完成"
    service_restart
    pause
}

uninstall_xray() {
    header
    log_warn "确认彻底卸载 Xray？"
    read -rp "  › 请输入 'y' 确认: " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { log_info "已取消卸载"; pause; return; }

    service_stop
    if [ "$INIT_TYPE" = "systemd" ]; then
        systemctl disable xray >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE" && systemctl daemon-reload
    elif [ "$INIT_TYPE" = "openrc" ]; then
        rc-update del xray default >/dev/null 2>&1 || true
        rm -f "$OPENRC_SERVICE"
    fi
    rm -f "$XRAY_BIN" "$SCRIPT_LINK" /usr/local/bin/xrsy "$DAEMON_PID_FILE"
    rm -rf "$XRAY_SHARE_DIR"

    read -rp "  › 是否同时删除配置和证书 ($XRAY_CONFIG_DIR)？[y/N]: " del_cfg
    [[ "$del_cfg" =~ ^[yY]$ ]] && rm -rf "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"

    log_success "Xray 已成功卸载"
    pause
}

# ------------------------------------------------------------------------------
# Helpers: Math, Random, Certs
# ------------------------------------------------------------------------------
rand_port() {
    local p
    while true; do
        p=$(( RANDOM % 50000 + 10000 ))
        ! is_port_used "$p" && { echo "$p"; break; }
    done
}

rand_uuid() {
    [ -x "$XRAY_BIN" ] && "$XRAY_BIN" uuid 2>/dev/null && return
    [ -f /proc/sys/kernel/random/uuid ] && cat /proc/sys/kernel/random/uuid && return
    openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

rand_str() { openssl rand -base64 "${1:-16}" | tr -dc 'a-zA-Z0-9' | head -c "${1:-16}"; }
urlencode() { jq -rn --arg x "$1" '$x|@uri'; }
base64_encode() { echo -n "$1" | base64 | tr -d '\r\n'; }

is_port_used() {
    local port="$1"
    [ -f "$XRAY_CONFIG" ] && jq -e --argjson p "$port" '.inbounds[]? | select(.port == $p)' "$XRAY_CONFIG" >/dev/null 2>&1 && return 0
    command -v ss >/dev/null 2>&1 && ss -tunlp 2>/dev/null | grep -qw ":$port" && return 0
    command -v netstat >/dev/null 2>&1 && netstat -tunlp 2>/dev/null | grep -qw ":$port" && return 0
    return 1
}

generate_self_signed_cert() {
    local domain="${1:-www.cloudflare.com}"
    mkdir -p "$XRAY_CERTS_DIR"
    local crt="$XRAY_CERTS_DIR/self_signed.crt" key="$XRAY_CERTS_DIR/self_signed.key"
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -nodes -sha256 -days 3650 -keyout "$key" -out "$crt" -subj "/CN=$domain" >/dev/null 2>&1
    fi
}

validate_and_apply_config() {
    local new_config="$1" bak="$XRAY_CONFIG.bak"
    cp "$XRAY_CONFIG" "$bak"
    echo "$new_config" > "$XRAY_CONFIG"
    if "$XRAY_BIN" run -test -c "$XRAY_CONFIG" >/dev/null 2>&1; then
        rm -f "$bak"
        service_restart
        return 0
    else
        log_error "配置验证失败，已自动回退旧配置"
        mv -f "$bak" "$XRAY_CONFIG"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Inbound Node Creation Wizard
# ------------------------------------------------------------------------------
add_node_wizard() {
    header
    ! is_installed && { log_warn "未检测到 Xray 核心，请先安装"; pause; return; }
    init_config_if_needed

    echo -e "  ${C_BOLD}添加入站节点${C_RESET}"
    line

    prompt_choice "请选择代理协议" "1" p_sel \
        "VLESS        (轻量高效，推荐)" \
        "VMess        (经典兼容)" \
        "Trojan       (标准 HTTPS 伪装)" \
        "Shadowsocks  (SS-2022 及 AEAD)" \
        "Hysteria 2   (QUIC/UDP 弱网极速加速)"

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
        prompt_choice "请选择传输方式" "1" t_sel \
            "xhttp     (XHTTP 流式传输，推荐)" \
            "grpc      (gRPC 多路复用)" \
            "websocket (WebSocket 适合 CDN)" \
            "tcp       (原生 TCP + REALITY Vision)"
        case "$t_sel" in 1) transport="xhttp";; 2) transport="grpc";; 3) transport="ws";; 4) transport="tcp";; esac

        prompt_choice "请选择传输安全" "1" s_sel "REALITY (免证书防探测)" "TLS (标准证书)" "None (明文反代)"
        case "$s_sel" in 1) security="reality";; 2) security="tls";; 3) security="none";; esac

    elif [ "$protocol" = "vmess" ]; then
        prompt_choice "请选择传输方式" "1" t_sel "websocket (推荐 CDN)" "grpc" "xhttp" "tcp"
        case "$t_sel" in 1) transport="ws";; 2) transport="grpc";; 3) transport="xhttp";; 4) transport="tcp";; esac
        prompt_choice "请选择传输安全" "1" s_sel "None (用于 CDN 反代)" "TLS (标准证书)"
        case "$s_sel" in 1) security="none";; 2) security="tls";; esac

    elif [ "$protocol" = "trojan" ]; then
        prompt_choice "请选择传输方式" "1" t_sel "tcp (原生标准)" "websocket" "grpc" "xhttp"
        case "$t_sel" in 1) transport="tcp";; 2) transport="ws";; 3) transport="grpc";; 4) transport="xhttp";; esac
        prompt_choice "请选择传输安全" "1" s_sel "TLS (证书加密)" "REALITY (免证书伪装)"
        case "$s_sel" in 1) security="tls";; 2) security="reality";; esac

    elif [ "$protocol" = "shadowsocks" ]; then
        prompt_choice "请选择加密算法" "1" sm_sel \
            "2022-blake3-aes-128-gcm (SS-2022 128位)" \
            "2022-blake3-aes-256-gcm (SS-2022 256位)" \
            "aes-128-gcm" "aes-256-gcm" "chacha20-ietf-poly1305"
        case "$sm_sel" in
            1) ss_method="2022-blake3-aes-128-gcm" ;;
            2) ss_method="2022-blake3-aes-256-gcm" ;;
            3) ss_method="aes-128-gcm" ;;
            4) ss_method="aes-256-gcm" ;;
            5) ss_method="chacha20-ietf-poly1305" ;;
        esac
        prompt_choice "请选择传输方式" "1" t_sel "raw (原生 TCP/UDP)" "websocket" "grpc" "xhttp"
        case "$t_sel" in 1) transport="raw";; 2) transport="ws";; 3) transport="grpc";; 4) transport="xhttp";; esac
        security="none"

    elif [ "$protocol" = "hysteria" ]; then
        transport="hysteria" security="tls"
    fi

    # Port
    local def_port="443"
    [ "$security" = "none" ] && [ "$protocol" != "shadowsocks" ] && def_port="80"
    [ "$protocol" = "shadowsocks" ] && def_port=$(rand_port)
    [ "$protocol" = "hysteria" ] && def_port="8443"
    is_port_used "$def_port" && def_port=$(rand_port)

    local port
    while true; do
        prompt_input "请输入监听端口" "$def_port" port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if is_port_used "$port"; then
                log_warn "端口 $port 疑似已被占用"
                read -rp "  › 是否强制使用？[y/N]: " f_port
                [[ "$f_port" =~ ^[yY]$ ]] && break
            else
                break
            fi
        else
            log_warn "端口必须为 1-65535 的整数"
        fi
    done

    # Credentials
    if [ "$protocol" = "vless" ] || [ "$protocol" = "vmess" ]; then
        prompt_input "请输入用户 UUID" "$(rand_uuid)" client_id
    elif [ "$protocol" = "trojan" ] || [ "$protocol" = "hysteria" ]; then
        prompt_input "请输入认证密码" "$(rand_str 16)" client_id
    elif [ "$protocol" = "shadowsocks" ]; then
        if [ "$ss_method" = "2022-blake3-aes-128-gcm" ]; then
            ss_pass=$(openssl rand -base64 16)
        elif [ "$ss_method" = "2022-blake3-aes-256-gcm" ]; then
            ss_pass=$(openssl rand -base64 32)
        else
            ss_pass=$(rand_str 16)
        fi
        prompt_input "请输入密码/PSK" "$ss_pass" ss_pass
    fi

    # Transport Path / ServiceName
    [ "$transport" = "xhttp" ] && prompt_input "请输入 XHTTP 分流路径" "/$(rand_str 8)" path
    [ "$transport" = "ws" ] && prompt_input "请输入 WebSocket 分流路径" "/$(rand_str 8)" path
    [ "$transport" = "grpc" ] && prompt_input "请输入 gRPC serviceName" "grpc-$(rand_str 6)" service_name

    # Security (REALITY / TLS)
    if [ "$security" = "reality" ]; then
        prompt_input "请输入 REALITY 伪装域名 (SNI)" "www.apple.com" sni
        local x_out
        x_out=$("$XRAY_BIN" x25519 2>/dev/null || echo "")
        priv_key=$(echo "$x_out" | grep -i "PrivateKey:" | awk '{print $NF}')
        pbk=$(echo "$x_out" | grep -i "PublicKey):" | awk '{print $NF}')
        [ -z "$priv_key" ] && priv_key=$(openssl rand -base64 32)
        [ -z "$pbk" ] && pbk=$(openssl rand -base64 32)
        short_id=$(openssl rand -hex 8)
        [ "$protocol" = "vless" ] && [ "$transport" = "tcp" ] && flow="xtls-rprx-vision"

    elif [ "$security" = "tls" ]; then
        prompt_choice "请选择 TLS 证书" "1" c_sel "自动生成自签名 EC 证书 (零门槛)" "使用已有自定义证书文件"
        if [ "$c_sel" = "1" ]; then
            prompt_input "请输入伪装域名 (SNI)" "www.cloudflare.com" sni
            generate_self_signed_cert "$sni"
            cert_file="$XRAY_CERTS_DIR/self_signed.crt"
            key_file="$XRAY_CERTS_DIR/self_signed.key"
            insecure="1"
        else
            prompt_input "请输入域名 (SNI)" "example.com" sni
            prompt_input "请输入证书 .crt 绝对路径" "/root/cert.crt" cert_file
            prompt_input "请输入私钥 .key 绝对路径" "/root/private.key" key_file
            insecure="0"
        fi
        [ "$protocol" = "vless" ] && [ "$transport" = "tcp" ] && flow="xtls-rprx-vision"
    fi

    local remark
    prompt_input "请输入节点备注" "${protocol^^}-${transport^^}-${port}" remark

    # Construct JSON Objects
    local stream_settings
    stream_settings=$(jq -c -n \
        --arg net "$transport" --arg path "$path" --arg svc "$service_name" --arg sec "$security" \
        --arg dest "${sni}:443" --arg sni "$sni" --arg pk "$priv_key" --arg sid "$short_id" \
        --arg crt "$cert_file" --arg key "$key_file" \
        '{network: $net} +
        (if $net == "xhttp" then {xhttpSettings: {path: $path, mode: "auto"}}
         elif $net == "ws" then {wsSettings: {path: $path}}
         elif $net == "grpc" then {grpcSettings: {serviceName: $svc}}
         elif $net == "hysteria" then {hysteriaSettings: {version: 2}}
         else {} end) +
        (if $sec == "reality" then {security: "reality", realitySettings: {show: false, dest: $dest, xver: 0, serverNames: [$sni], privateKey: $pk, shortIds: [$sid]}}
         elif $sec == "tls" then {security: "tls", tlsSettings: ({certificates: [{certificateFile: $crt, keyFile: $key}]} + (if $net == "hysteria" then {alpn: ["h3"]} else {} end))}
         else {} end)')

    local settings
    if [ "$protocol" = "vless" ]; then
        settings=$(jq -c -n --arg id "$client_id" --arg flow "$flow" \
            '{clients: ([{id: $id} + (if $flow != "" then {flow: $flow} else {} end)]), decryption: "none"}')
    elif [ "$protocol" = "vmess" ]; then
        settings=$(jq -c -n --arg id "$client_id" '{clients: [{id: $id, alterId: 0}]}')
    elif [ "$protocol" = "trojan" ]; then
        settings=$(jq -c -n --arg pwd "$client_id" '{clients: [{password: $pwd}]}')
    elif [ "$protocol" = "shadowsocks" ]; then
        settings=$(jq -c -n --arg m "$ss_method" --arg p "$ss_pass" '{method: $m, password: $p, network: "tcp,udp"}')
    elif [ "$protocol" = "hysteria" ]; then
        settings=$(jq -c -n --arg auth "$client_id" '{version: 2, clients: [{auth: $auth}]}')
    fi

    local inbound_obj
    inbound_obj=$(jq -c -n \
        --arg tag "${protocol}-${port}" --argjson port "$port" --arg proto "$protocol" \
        --argjson set "$settings" --argjson ss "$stream_settings" \
        --arg trans "$transport" --arg sec "$security" --arg rmk "$remark" \
        --arg path "$path" --arg svc "$service_name" --arg sni "$sni" --arg pbk "$pbk" \
        --arg sid "$short_id" --arg insec "$insecure" --arg flow "$flow" \
        '{
            tag: $tag, port: $port, listen: "0.0.0.0", protocol: $proto, settings: $set, streamSettings: $ss,
            sniffing: (if $proto == "shadowsocks" or $proto == "hysteria" then null else {enabled: true, destOverride: ["http", "tls", "quic"]} end),
            _meta: {
                protocol: $proto, transport: $trans, security: $sec, remark: $rmk,
                path: $path, serviceName: $svc, sni: $sni, publicKey: $pbk,
                shortId: $sid, insecure: $insec, flow: $flow
            }
        } | del(.sniffing | nulls)')

    local new_config
    new_config=$(jq --argjson inb "$inbound_obj" '.inbounds += [$inb]' "$XRAY_CONFIG")

    log_info "正在验证并生效配置..."
    if validate_and_apply_config "$new_config"; then
        log_success "节点已添加并生效"
        view_node_detail "$(($(jq '.inbounds | length' "$XRAY_CONFIG") - 1))"
    else
        pause
    fi
}

# ------------------------------------------------------------------------------
# Node Listing & Details
# ------------------------------------------------------------------------------
get_node_share_link() {
    local idx="$1" node
    node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG" 2>/dev/null)
    [ -z "$node" ] && return

    local proto port meta_proto meta_trans meta_sec meta_rmk meta_path meta_svc meta_sni meta_pbk meta_sid meta_insec meta_flow id_or_pwd
    IFS='|' read -r proto port meta_proto meta_trans meta_sec meta_rmk meta_path meta_svc meta_sni meta_pbk meta_sid meta_insec meta_flow id_or_pwd < <(
        echo "$node" | jq -r '[
            .protocol, (.port | tostring), (._meta.protocol // .protocol),
            (._meta.transport // .streamSettings.network // "raw"), (._meta.security // .streamSettings.security // "none"),
            (._meta.remark // .tag // "Node"), (._meta.path // .streamSettings.xhttpSettings.path // .streamSettings.wsSettings.path // ""),
            (._meta.serviceName // .streamSettings.grpcSettings.serviceName // ""), (._meta.sni // .streamSettings.realitySettings.serverNames[0] // ""),
            (._meta.publicKey // ""), (._meta.shortId // .streamSettings.realitySettings.shortIds[0] // ""), (._meta.insecure // "0"),
            (._meta.flow // .settings.clients[0].flow // ""),
            (.settings.clients[0].id // .settings.clients[0].password // .settings.clients[0].auth // .settings.password // "")
        ] | join("|")'
    )

    local enc_rmk enc_path link=""
    enc_rmk=$(urlencode "$meta_rmk") enc_path=$(urlencode "$meta_path")

    case "$meta_proto" in
        vless)
            link="vless://${id_or_pwd}@${SERVER_IP}:${port}?type=${meta_trans}&security=${meta_sec}"
            [ "$meta_sec" = "reality" ] && link="${link}&pbk=${meta_pbk}&fp=chrome&sni=${meta_sni}&sid=${meta_sid}"
            [ "$meta_sec" = "tls" ] && link="${link}&fp=chrome&sni=${meta_sni}"
            [ "$meta_trans" = "xhttp" ] && link="${link}&path=${enc_path}&mode=auto"
            [ "$meta_trans" = "ws" ] && link="${link}&path=${enc_path}&host=${meta_sni}"
            [ "$meta_trans" = "grpc" ] && link="${link}&serviceName=${meta_svc}&mode=gun"
            [ "$meta_trans" = "tcp" ] && [ -n "$meta_flow" ] && link="${link}&flow=${meta_flow}"
            link="${link}#${enc_rmk}"
            ;;
        vmess)
            local tls_flag="" v_path="$meta_path"
            [ "$meta_sec" = "tls" ] && tls_flag="tls"
            [ "$meta_trans" = "grpc" ] && v_path="$meta_svc"
            local vjson
            vjson=$(jq -c -n \
                --arg ps "$meta_rmk" --arg add "$SERVER_IP" --argjson port "$port" \
                --arg id "$id_or_pwd" --arg net "$meta_trans" --arg host "$meta_sni" \
                --arg path "$v_path" --arg tls "$tls_flag" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:0, scy:"auto", net:$net, type:"none", host:$host, path:$path, tls:$tls}')
            link="vmess://$(base64_encode "$vjson")"
            ;;
        trojan)
            link="trojan://${id_or_pwd}@${SERVER_IP}:${port}?security=${meta_sec}&sni=${meta_sni}&type=${meta_trans}"
            [ "$meta_sec" = "reality" ] && link="${link}&pbk=${meta_pbk}&sid=${meta_sid}&fp=chrome"
            [ "$meta_trans" = "ws" ] && link="${link}&path=${enc_path}&host=${meta_sni}"
            [ "$meta_trans" = "grpc" ] && link="${link}&serviceName=${meta_svc}"
            [ "$meta_trans" = "xhttp" ] && link="${link}&path=${enc_path}"
            link="${link}#${enc_rmk}"
            ;;
        shadowsocks)
            local method
            method=$(echo "$node" | jq -r '.settings.method // ""')
            link="ss://$(base64_encode "${method}:${id_or_pwd}")@${SERVER_IP}:${port}#${enc_rmk}"
            ;;
        hysteria)
            link="hysteria2://${id_or_pwd}@${SERVER_IP}:${port}/?sni=${meta_sni}&insecure=${meta_insec}#${enc_rmk}"
            ;;
    esac
    echo "$link"
}

view_node_detail() {
    local idx="$1" node
    node=$(jq -c ".inbounds[$idx]" "$XRAY_CONFIG" 2>/dev/null)
    [ -z "$node" ] || [ "$node" = "null" ] && { log_error "节点不存在"; pause; return; }

    local proto port meta_proto meta_trans meta_sec meta_rmk meta_path meta_svc meta_sni meta_pbk meta_sid meta_insec meta_flow id_or_pwd
    IFS='|' read -r proto port meta_proto meta_trans meta_sec meta_rmk meta_path meta_svc meta_sni meta_pbk meta_sid meta_insec meta_flow id_or_pwd < <(
        echo "$node" | jq -r '[
            .protocol, (.port | tostring), (._meta.protocol // .protocol),
            (._meta.transport // .streamSettings.network // "raw"), (._meta.security // .streamSettings.security // "none"),
            (._meta.remark // .tag // "Node"), (._meta.path // .streamSettings.xhttpSettings.path // .streamSettings.wsSettings.path // ""),
            (._meta.serviceName // .streamSettings.grpcSettings.serviceName // ""), (._meta.sni // .streamSettings.realitySettings.serverNames[0] // ""),
            (._meta.publicKey // ""), (._meta.shortId // .streamSettings.realitySettings.shortIds[0] // ""), (._meta.insecure // "0"),
            (._meta.flow // .settings.clients[0].flow // ""),
            (.settings.clients[0].id // .settings.clients[0].password // .settings.clients[0].auth // .settings.password // "")
        ] | join("|")'
    )

    header
    echo -e "  ${C_BOLD}节点配置详情${C_RESET}"
    line
    printf "  ${C_GRAY}备注名称${C_RESET}  %s\n" "$meta_rmk"
    printf "  ${C_GRAY}协议类型${C_RESET}  %s\n" "${meta_proto^^}"
    printf "  ${C_GRAY}服务器IP${C_RESET}  %s\n" "$SERVER_IP"
    printf "  ${C_GRAY}监听端口${C_RESET}  %s\n" "$port"
    printf "  ${C_GRAY}传输方式${C_RESET}  %s\n" "$meta_trans"
    printf "  ${C_GRAY}安全加密${C_RESET}  %s\n" "${meta_sec^^}"

    if [ "$meta_proto" = "vless" ] || [ "$meta_proto" = "vmess" ]; then
        printf "  ${C_GRAY}用户UUID${C_RESET}  %s\n" "$id_or_pwd"
    elif [ "$meta_proto" = "trojan" ] || [ "$meta_proto" = "hysteria" ]; then
        printf "  ${C_GRAY}认证密码${C_RESET}  %s\n" "$id_or_pwd"
    elif [ "$meta_proto" = "shadowsocks" ]; then
        printf "  ${C_GRAY}加密算法${C_RESET}  %s\n" "$(echo "$node" | jq -r '.settings.method // ""')"
        printf "  ${C_GRAY}连接密码${C_RESET}  %s\n" "$id_or_pwd"
    fi

    [ -n "$meta_path" ] && printf "  ${C_GRAY}分流路径${C_RESET}  %s\n" "$meta_path"
    [ -n "$meta_svc" ] && printf "  ${C_GRAY}服务名称${C_RESET}  %s\n" "$meta_svc"
    [ -n "$meta_sni" ] && printf "  ${C_GRAY}伪装域名${C_RESET}  %s\n" "$meta_sni"
    [ -n "$meta_pbk" ] && printf "  ${C_GRAY}公钥 PBK${C_RESET}  %s\n" "$meta_pbk"
    [ -n "$meta_sid" ] && printf "  ${C_GRAY}Short ID${C_RESET}  %s\n" "$meta_sid"
    [ "$meta_sec" = "tls" ] && [ "$meta_insec" = "1" ] && printf "  ${C_GRAY}自签证书${C_RESET}  %s (insecure=1)\n" "允许"

    line
    local share_link
    share_link=$(get_node_share_link "$idx")
    echo -e "  ${C_BOLD}分享链接:${C_RESET}"
    echo -e "  ${C_CYAN}${share_link}${C_RESET}"
    [ "$meta_proto" = "hysteria" ] && echo -e "  ${C_GRAY}兼容链接 (hy2://):${C_RESET}\n  ${C_CYAN}${share_link/hysteria2:\/\//hy2:\/\/}${C_RESET}"

    line
    echo -e "  ${C_CYAN}1.${C_RESET} 导出客户端配置 JSON    ${C_GRAY}0. 返回列表 (回车)${C_RESET}"
    read -rp "  › 请选择操作 [0]: " opt
    if [ "$opt" = "1" ]; then
        line
        echo -e "  ${C_BOLD}Xray 客户端 Outbound 配置片段:${C_RESET}"
        echo "$node" | jq \
            --arg ip "$SERVER_IP" --arg pbk "$meta_pbk" --arg sid "$meta_sid" --arg sni "$meta_sni" \
            '{
                tag: ("proxy-" + .protocol), protocol: .protocol,
                settings: (if .protocol == "vless" then {vnext: [{address: $ip, port: .port, users: [{id: .settings.clients[0].id, encryption: "none"}]}]}
                           elif .protocol == "vmess" then {vnext: [{address: $ip, port: .port, users: [{id: .settings.clients[0].id, alterId: 0}]}]}
                           elif .protocol == "trojan" then {servers: [{address: $ip, port: .port, password: .settings.clients[0].password}]}
                           elif .protocol == "shadowsocks" then {servers: [{address: $ip, port: .port, method: .settings.method, password: .settings.password}]}
                           elif .protocol == "hysteria" then {version: 2, address: $ip, port: .port}
                           else .settings end),
                streamSettings: (.streamSettings |
                    if .security == "reality" then .realitySettings = {serverName: $sni, fingerprint: "chrome", show: false, publicKey: $pbk, shortId: $sid}
                    elif .security == "tls" then .tlsSettings = {serverName: $sni}
                    else . end)
            }'
        pause
    fi
}

list_nodes() {
    while true; do
        header
        ! is_installed && { log_warn "未安装 Xray 核心"; pause; return; }

        local count=0
        [ -f "$XRAY_CONFIG" ] && count=$(jq '.inbounds | length' "$XRAY_CONFIG" 2>/dev/null || echo 0)
        [ "$count" -eq 0 ] && { log_warn "暂无已配置的入站节点"; pause; return; }

        printf "  ${C_GRAY}%-4s  %-14s  %-9s  %-12s  %-11s  %s${C_RESET}\n" "#" "协议" "端口" "传输" "安全" "备注"
        line

        for ((i=0; i<count; i++)); do
            local node
            node=$(jq -c ".inbounds[$i]" "$XRAY_CONFIG" 2>/dev/null)
            local p_port p_proto p_trans p_sec p_rmk
            p_port=$(echo "$node" | jq -r '.port')
            p_proto=$(echo "$node" | jq -r '._meta.protocol // .protocol')
            p_trans=$(echo "$node" | jq -r '._meta.transport // .streamSettings.network // "raw"')
            p_sec=$(echo "$node" | jq -r '._meta.security // .streamSettings.security // "none"')
            p_rmk=$(echo "$node" | jq -r '._meta.remark // .tag // "Node"')

            printf "  %-4d  %-12s  %-7s  %-10s  %-9s  %s\n" \
                "$((i+1))" "${p_proto^^}" "$p_port" "$p_trans" "${p_sec^^}" "$p_rmk"
        done

        line
        read -rp "  › 请输入节点编号查看详情 [1-$count, 回车返回]: " node_choice
        [ -z "$node_choice" ] || [ "$node_choice" = "0" ] && break

        if [[ "$node_choice" =~ ^[0-9]+$ ]] && [ "$node_choice" -ge 1 ] && [ "$node_choice" -le "$count" ]; then
            view_node_detail "$((node_choice - 1))"
        else
            log_warn "输入无效" && sleep 1
        fi
    done
}

delete_node() {
    header
    ! is_installed && { log_warn "未安装 Xray 核心"; pause; return; }

    local count=0
    [ -f "$XRAY_CONFIG" ] && count=$(jq '.inbounds | length' "$XRAY_CONFIG" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && { log_warn "暂无可删除的节点"; pause; return; }

    echo -e "  ${C_BOLD}删除入站节点${C_RESET}"
    line
    for ((i=0; i<count; i++)); do
        local node
        node=$(jq -c ".inbounds[$i]" "$XRAY_CONFIG" 2>/dev/null)
        local p_port p_proto p_rmk
        p_port=$(echo "$node" | jq -r '.port')
        p_proto=$(echo "$node" | jq -r '._meta.protocol // .protocol')
        p_rmk=$(echo "$node" | jq -r '._meta.remark // .tag // "Node"')
        printf "  %2d. %-10s 端口: %-5s (%s)\n" "$((i+1))" "${p_proto^^}" "$p_port" "$p_rmk"
    done
    line

    read -rp "  › 请输入要删除的序号 [1-$count, 回车取消]: " del_idx
    [ -z "$del_idx" ] && return

    if [[ "$del_idx" =~ ^[0-9]+$ ]] && [ "$del_idx" -ge 1 ] && [ "$del_idx" -le "$count" ]; then
        local real_idx=$((del_idx - 1))
        read -rp "  › 确认删除该节点？[y/N]: " confirm_del
        if [[ "$confirm_del" =~ ^[yY]$ ]]; then
            local new_config
            new_config=$(jq --argjson idx "$real_idx" 'del(.inbounds[$idx])' "$XRAY_CONFIG")
            validate_and_apply_config "$new_config" && log_success "节点已删除并生效"
        else
            log_info "已取消删除"
        fi
    else
        log_warn "输入无效"
    fi
    pause
}

# ------------------------------------------------------------------------------
# System Optimization (BBR)
# ------------------------------------------------------------------------------
enable_bbr() {
    header
    echo -e "  ${C_BOLD}开启 BBR 拥塞控制${C_RESET}"
    line

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "")
    if [ "$current_cc" = "bbr" ]; then
        log_success "系统已处于 BBR 状态，无需重复配置"
        pause && return
    fi

    log_info "正在配置 BBR 内核参数..."
    modprobe tcp_bbr 2>/dev/null || true

    local sysctl_file="/etc/sysctl.d/99-bbr.conf"
    [ ! -d "/etc/sysctl.d" ] && sysctl_file="/etc/sysctl.conf"

    sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' "$sysctl_file" 2>/dev/null || true
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" >> "$sysctl_file"

    sysctl -p "$sysctl_file" >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true

    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "")
    [ "$new_cc" = "bbr" ] && log_success "BBR 开启成功" || log_warn "已写入参数，当前状态: $new_cc"
    pause
}

# ------------------------------------------------------------------------------
# Main Loop
# ------------------------------------------------------------------------------
main() {
    check_root
    detect_os
    detect_init
    detect_arch
    install_deps
    setup_shortcut
    get_public_ip

    while true; do
        header

        local auto_tag="${C_GRAY}关${C_RESET}"
        is_autostart_enabled && auto_tag="${C_GREEN}开${C_RESET}"

        echo -e "   ${C_CYAN}1.${C_RESET} 添加入站节点    ${C_CYAN}5.${C_RESET} 启动服务    ${C_CYAN} 9.${C_RESET} 自启开关 [${auto_tag}]"
        echo -e "   ${C_CYAN}2.${C_RESET} 查看节点列表    ${C_CYAN}6.${C_RESET} 停止服务    ${C_CYAN}10.${C_RESET} 开启 BBR"
        echo -e "   ${C_CYAN}3.${C_RESET} 删除入站节点    ${C_CYAN}7.${C_RESET} 重启服务    ${C_CYAN}11.${C_RESET} 卸载核心"
        echo -e "   ${C_CYAN}4.${C_RESET} 安装/更新核心   ${C_CYAN}8.${C_RESET} 实时日志    ${C_CYAN} 0.${C_RESET} 退出面板"
        line

        if ! read -rp "  › 请选择操作 [0-11]: " choice; then
            echo ""
            exit 0
        fi
        case "$choice" in
            1) add_node_wizard ;;
            2) list_nodes ;;
            3) delete_node ;;
            4) install_xray ;;
            5) service_start; pause ;;
            6) service_stop; pause ;;
            7) service_restart; pause ;;
            8) view_logs ;;
            9) service_toggle_autostart; pause ;;
            10) enable_bbr ;;
            11) uninstall_xray ;;
            0|q|exit)
                clear 2>/dev/null || true
                echo -e "\n  ${C_CYAN}感谢使用 Xray 管理脚本，再见！${C_RESET}\n"
                exit 0
                ;;
            *)
                log_warn "输入无效，请重新选择" && sleep 1
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
