#!/usr/bin/env sh
# shellcheck shell=bash
# =========================================================
#  CLIProxyAPI 运维管理脚本 (Debian / Ubuntu / Alpine)
#  安全策略: 强制绑定 127.0.0.1:8317，禁止公网直连，支持域名反代
# =========================================================

if [ -z "${BASH_VERSION:-}" ]; then
    [ -f /etc/alpine-release ] && ! command -v bash >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && apk add --no-cache bash >/dev/null 2>&1
    if command -v bash >/dev/null 2>&1 && [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
    echo "[错误] 请先安装 bash 并使用 bash 运行此脚本！" >&2; exit 1
fi

set -o pipefail

SCRIPT_SELF=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
elif [[ -f "$0" ]]; then
    SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
fi
SCRIPT_LINK="/usr/local/bin/cpapi"

# --- 视觉主题与常量定义 ---
if [ -t 1 ]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_GRAY=$'\033[90m'
else
    C_RESET="" C_BOLD="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_GRAY=""
fi

WORK_DIR="/root/cliproxyapi"
AUTH_DIR="${WORK_DIR}/auth"
BIN_PATH="${WORK_DIR}/cli-proxy-api"
CONFIG_PATH="${WORK_DIR}/config.yaml"
DOMAIN_FILE="${WORK_DIR}/.domain"
BACKUP_DIR="${WORK_DIR}/backup"
LOG_FILE="/var/log/cliproxy.log"
OFFICIAL_REPO="router-for-me/CLIProxyAPI"

LOCKED_HOST="127.0.0.1"
LOCKED_PORT="8317"
LISTEN_ADDR="${LOCKED_HOST}:${LOCKED_PORT}"
TMP_EXTRACT_DIR=""

GH_PROXY="${GH_PROXY:-}"
[ -n "$GH_PROXY" ] && [[ "$GH_PROXY" != */ ]] && GH_PROXY="${GH_PROXY}/"

# --- 全局清理陷阱 ---
cleanup_tmp() {
    [[ -n "${TMP_EXTRACT_DIR:-}" && -d "$TMP_EXTRACT_DIR" ]] && rm -rf -- "$TMP_EXTRACT_DIR"
    TMP_EXTRACT_DIR=""
}
trap cleanup_tmp EXIT INT TERM HUP

# --- UI 输出与安全交互组件 ---
info()   { echo -e "  ${C_CYAN}›${C_RESET} $*"; }
ok()     { echo -e "  ${C_GREEN}✔${C_RESET} $*"; }
warn()   { echo -e "  ${C_YELLOW}!${C_RESET} $*"; }
err()    { echo -e "  ${C_RED}✖${C_RESET} $*" >&2; }
kv()     { printf "  ${C_GRAY}%-10s${C_RESET}  %b\n" "$1" "$2"; }

prompt_read() {
    local prompt_str="$1" var_name="$2"
    if [[ -t 0 ]]; then
        read -rp "$prompt_str" "${var_name?}"
    elif [[ -e /dev/tty ]]; then
        read -rp "$prompt_str" "${var_name?}" < /dev/tty
    else
        return 1
    fi
}

pause() {
    echo ""
    local _dummy
    prompt_read "  按回车键继续..." _dummy || true
}

header() {
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${C_BOLD}${1}${C_RESET}\n"
}

# --- 0. 权限与环境初始化 ---
check_root() { [[ "$EUID" -eq 0 ]] || { err "请使用 root 用户运行此脚本！"; exit 1; }; }
check_os() {
    [[ -f /etc/os-release ]] || { err "无法识别操作系统！"; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID,,}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"

    case "$OS_ID" in
        debian|ubuntu) SERVICE_PATH="/etc/systemd/system/cliproxy.service" ;;
        alpine)        SERVICE_PATH="/etc/init.d/cliproxy" ;;
        *) err "不支持当前系统 (${OS_NAME})，仅支持 Debian / Ubuntu / Alpine！"; exit 1 ;;
    esac
}

setup_shortcut() {
    [[ -n "$SCRIPT_SELF" && "$SCRIPT_SELF" == /* && -f "$SCRIPT_SELF" ]] || return 0
    case "$SCRIPT_SELF" in
        /bin/*|/usr/bin/*|/sbin/*|/usr/sbin/*) return 0 ;;
    esac
    mkdir -p /usr/local/bin
    if [ ! -f "$SCRIPT_LINK" ] || [ "$(readlink -f "$SCRIPT_LINK" 2>/dev/null)" != "$SCRIPT_SELF" ]; then
        ln -sf "$SCRIPT_SELF" "$SCRIPT_LINK" 2>/dev/null || true
        chmod +x "$SCRIPT_LINK" 2>/dev/null || true
    fi
}

# --- 1. 核心工具函数 ---
ensure_deps() {
    local missing=() pkgs=() cmd
    for cmd in curl tar awk; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
    if [[ ${#missing[@]} -gt 0 ]]; then
        pkgs+=("${missing[@]}")
    fi
    if [[ ! -d /etc/ssl/certs ]] || [[ -z "$(ls -A /etc/ssl/certs 2>/dev/null)" ]]; then
        pkgs+=("ca-certificates")
    fi
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    info "正在安装基础依赖: ${pkgs[*]} ..."
    if [[ "$OS_ID" == "alpine" ]]; then
        apk add --no-cache "${pkgs[@]}"
    else
        apt-get update -y && apt-get install -y "${pkgs[@]}"
    fi
}

parse_yaml_val() {
    [[ -f "$CONFIG_PATH" ]] || return 0
    awk -v k="$1" '$0 ~ "^[[:space:]]*" k ":[[:space:]]*" {
        sub("^[[:space:]]*" k ":[[:space:]]*", ""); sub(/[[:space:]]+#.*$/, "")
        gsub(/^["'\'']|["'\'']$/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit
    }' "$CONFIG_PATH" 2>/dev/null
}

get_domain() {
    if [[ -f "$DOMAIN_FILE" ]]; then
        head -n 1 "$DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]'
    else
        echo ""
    fi
}

sanitize_domain() {
    local d="${1#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d%%:*}"; d="$(echo "$d" | tr -d '[:space:]')"
    if [[ -z "$d" || "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        echo "$d"; return 0
    else
        return 1
    fi
}

# 兼容新旧两种 config.yaml 结构（顶层 host/port 或 server 块下 host/port）
enforce_local_binding() {
    [[ -f "$CONFIG_PATH" ]] || return 0
    local tmp="${CONFIG_PATH}.tmp"
    if awk -v h="$LOCKED_HOST" -v p="$LOCKED_PORT" '
        BEGIN { s=0; has_srv=0; top_h=0; top_p=0 }
        /^server:[[:space:]]*(#.*)?$/ {
            print "server:"
            print "  host: \"" h "\""
            print "  port: " p
            s=1; has_srv=1; next
        }
        /^[^[:space:]#]/ { s=0 }
        s && /^[[:space:]]+(host|port):[[:space:]]*/ { next }
        !s && /^host:[[:space:]]*/ { print "host: \"" h "\""; top_h=1; next }
        !s && /^port:[[:space:]]*/ { print "port: " p; top_p=1; next }
        { print }
        END {
            if (!has_srv && !top_h && !top_p) {
                print "\nserver:"
                print "  host: \"" h "\""
                print "  port: " p
            }
        }
    ' "$CONFIG_PATH" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CONFIG_PATH" && chmod 600 "$CONFIG_PATH"
    else
        rm -f "$tmp"
    fi
}

write_config() {
    local raw_key="$1"
    local safe_key="${raw_key//\\/\\\\}"
    safe_key="${safe_key//\"/\\\"}"
    safe_key="${safe_key//&/\\&}"
    safe_key="${safe_key//|/\\|}"
    (umask 077 && cat << 'YAML' | sed -e "s|__HOST__|${LOCKED_HOST}|g" -e "s|__PORT__|${LOCKED_PORT}|g" -e "s|__KEY__|${safe_key}|g" > "$CONFIG_PATH"
config-version: 8

server:
  host: "__HOST__"
  port: __PORT__

management:
  allow-remote: true
  secret-key: "__KEY__"

oauth:
  auth-dir: "auth"
YAML
    )
}

svc_ctl() {
    if [[ "$OS_ID" == "alpine" ]]; then
        rc-service cliproxy "$1" >/dev/null 2>&1
    else
        case "$1" in
            status)  systemctl is-active --quiet cliproxy 2>/dev/null ;;
            restart) systemctl daemon-reload && systemctl restart cliproxy ;;
            *)       systemctl "$1" cliproxy 2>/dev/null ;;
        esac
    fi
}

wait_for_service() {
    local retries=12
    while (( retries > 0 )); do
        if svc_ctl status; then
            if (echo >/dev/tcp/"$LOCKED_HOST"/"$LOCKED_PORT") 2>/dev/null || \
               curl -sS --max-time 1 "http://${LISTEN_ADDR}/" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 0.5
        ((retries--))
    done
    svc_ctl status
}

is_installed() { [[ -f "$SERVICE_PATH" || -x "$BIN_PATH" ]]; }

fmt_status() {
    if svc_ctl status; then
        echo -e "${C_GREEN}● 运行中${C_RESET}"
    elif is_installed; then
        echo -e "${C_RED}● 已停止${C_RESET}"
    else
        echo -e "${C_GRAY}○ 未安装${C_RESET}"
    fi
}

restart_cliproxy() { [[ -f "$SERVICE_PATH" ]] && enforce_local_binding && svc_ctl restart && wait_for_service; }

manage_service() {
    [[ -f "$SERVICE_PATH" ]] || { warn "服务尚未安装，请先执行 [5. 安装部署]。"; pause; return 1; }
    case "$1" in
        start)
            if svc_ctl status; then
                info "服务已在运行中。"
            else
                enforce_local_binding
                if svc_ctl start && wait_for_service; then
                    ok "服务已启动！"
                else
                    err "启动失败，请查看日志。"
                fi
            fi ;;
        stop)
            if svc_ctl status; then
                if svc_ctl stop; then
                    ok "服务已停止。"
                fi
            else
                info "服务当前已处于停止状态。"
            fi ;;
        restart)
            if restart_cliproxy; then
                ok "服务已重启！"
            else
                err "重启失败，请查看日志。"
            fi ;;
    esac
    pause
}

# --- 2. 版本与二进制管理 ---
parse_binary_version() {
    local target="${1:-$BIN_PATH}" out="" ver=""
    [[ -x "$target" ]] || return 0
    out=$("$target" --version 2>&1 || true)
    [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?) ]] && ver="${BASH_REMATCH[1]}"
    if [[ -z "$ver" ]]; then
        out=$("$target" --help 2>&1 || true)
        [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?) ]] && ver="${BASH_REMATCH[1]}"
    fi
    [[ -n "$ver" ]] && echo "$ver"
}

get_local_version() {
    [[ -x "$BIN_PATH" ]] || { echo "未安装"; return; }
    local v; v=$(parse_binary_version "$BIN_PATH" 2>/dev/null)
    echo "${v:-未知}"
}

fmt_ver() { [[ "$1" =~ ^(未安装|未知)$ ]] && echo -e "${C_GRAY}$1${C_RESET}" || echo -e "${C_CYAN}v$1${C_RESET}"; }

fetch_release_info() {
    local arch_primary arch_alt variant="" api_json=""
    case "$(uname -m)" in
        x86_64|amd64)  arch_primary="amd64"; arch_alt="x86_64" ;;
        aarch64|arm64) arch_primary="arm64"; arch_alt="aarch64" ;;
        *) err "不支持的架构: $(uname -m)"; return 1 ;;
    esac
    [[ "$OS_ID" == "alpine" ]] && variant="_no-plugin"

    local rel_url="https://github.com/${OFFICIAL_REPO}/releases/latest"
    local api_url="https://api.github.com/repos/${OFFICIAL_REPO}/releases/latest"
    [ -n "$GH_PROXY" ] && { rel_url="${GH_PROXY}${rel_url}"; api_url="${GH_PROXY}${api_url}"; }

    LATEST_TAG=""
    DOWNLOAD_URL=""

    # 1. 优先尝试从 GitHub API 获取精确的 tag_name 与 browser_download_url
    api_json=$(curl -fsSL --max-time 10 "$api_url" 2>/dev/null || true)
    if [[ -n "$api_json" ]]; then
        LATEST_TAG=$(echo "$api_json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4)
        local dl_urls
        dl_urls=$(echo "$api_json" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4)
        if [[ -n "$dl_urls" ]]; then
            if [[ -n "$variant" ]]; then
                DOWNLOAD_URL=$(echo "$dl_urls" | grep -i "linux" | grep -E "(${arch_primary}|${arch_alt})" | grep -F "$variant" | grep -E '\.(tar\.gz|tgz)$' | head -n 1)
            fi
            if [[ -z "$DOWNLOAD_URL" ]]; then
                DOWNLOAD_URL=$(echo "$dl_urls" | grep -i "linux" | grep -E "(${arch_primary}|${arch_alt})" | grep -v "no-plugin" | grep -E '\.(tar\.gz|tgz)$' | head -n 1)
            fi
            if [[ -z "$DOWNLOAD_URL" ]]; then
                DOWNLOAD_URL=$(echo "$dl_urls" | grep -i "linux" | grep -E "(${arch_primary}|${arch_alt})" | grep -E '\.(tar\.gz|tgz)$' | head -n 1)
            fi
            [[ -n "$DOWNLOAD_URL" && -n "$GH_PROXY" && "$DOWNLOAD_URL" != "${GH_PROXY}"* ]] && DOWNLOAD_URL="${GH_PROXY}${DOWNLOAD_URL}"
        fi
    fi

    # 2. 备选：通过 302 Location 或重定向 URL 提取 Tag（不使用 set -o pipefail 阻断）
    if [[ -z "$LATEST_TAG" ]]; then
        local hdr
        hdr=$(curl -sI --max-time 10 "$rel_url" 2>/dev/null || true)
        LATEST_TAG=$(echo "$hdr" | awk -F'/tag/' 'tolower($0) ~ /^location:.*\/tag\// {gsub(/[\r\n?[:space:]]/, "", $2); print $2; exit}')
    fi
    if [[ -z "$LATEST_TAG" ]]; then
        local eff_url
        eff_url=$(curl -sSL -o /dev/null -w '%{url_effective}' --max-time 10 "$rel_url" 2>/dev/null || true)
        LATEST_TAG=$(echo "$eff_url" | awk -F'/tag/' '/\/tag\// {gsub(/[\r\n?[:space:]].*/, "", $2); print $2; exit}')
    fi

    [[ -n "$LATEST_TAG" ]] || { err "无法获取最新版本信息，请检查网络或配置 GH_PROXY！"; return 1; }
    LATEST_VER="${LATEST_TAG#v}"

    # 3. 备选：构造候选下载链接列表（兼容 arm64 / aarch64 及 _no-plugin 回退）
    CANDIDATE_URLS=()
    if [[ -n "$DOWNLOAD_URL" ]]; then
        CANDIDATE_URLS+=("$DOWNLOAD_URL")
    fi
    local base_dl="https://github.com/${OFFICIAL_REPO}/releases/download/${LATEST_TAG}"
    [ -n "$GH_PROXY" ] && base_dl="${GH_PROXY}${base_dl}"

    local a
    for a in "$arch_primary" "$arch_alt"; do
        if [[ -n "$variant" ]]; then
            CANDIDATE_URLS+=("${base_dl}/CLIProxyAPI_${LATEST_VER}_linux_${a}${variant}.tar.gz")
        fi
        CANDIDATE_URLS+=("${base_dl}/CLIProxyAPI_${LATEST_VER}_linux_${a}.tar.gz")
    done
    DOWNLOAD_URL="${CANDIDATE_URLS[0]}"
}

install_release_binary() {
    local found="" test_out="" example_cfg="" url dl_ok=0
    cleanup_tmp
    TMP_EXTRACT_DIR=$(mktemp -d)
    mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"

    info "正在下载官方程序包 (v${LATEST_VER})..."
    for url in "${CANDIDATE_URLS[@]}"; do
        if curl -fsSL --connect-timeout 10 --max-time 180 -o "${TMP_EXTRACT_DIR}/pkg.tar.gz" "$url" 2>/dev/null; then
            if tar -zxf "${TMP_EXTRACT_DIR}/pkg.tar.gz" -C "$TMP_EXTRACT_DIR" 2>/dev/null; then
                dl_ok=1
                break
            fi
        fi
        rm -f "${TMP_EXTRACT_DIR}/pkg.tar.gz"
    done

    if [[ "$dl_ok" -ne 1 ]]; then
        err "程序包下载或解压失败，请检查网络连接！"
        cleanup_tmp
        return 1
    fi

    found=$(find "$TMP_EXTRACT_DIR" -type f \( -iname "cli-proxy-api*" -o -iname "cliproxyapi*" \) ! -name "*.yaml" ! -name "*.yml" ! -name "*.md" ! -name "*.txt" ! -name "*.tar.gz" ! -name "*.sh" | head -n 1)
    if [[ -n "$found" ]]; then
        chmod +x "$found"
    else
        err "压缩包内未找到可执行主程序！"; cleanup_tmp; return 1
    fi

    if ! test_out=$("$found" --help 2>&1) && ! test_out=$("$found" --version 2>&1); then
        err "二进制兼容性预检未通过：\n${test_out}"; cleanup_tmp; return 1
    fi

    # 极其关键：先写入 .new 临时文件再 mv 原子替换，避免进程运行中直接覆盖引发 Text file busy
    rm -f "${BIN_PATH}.new"
    if ! (install -m 755 "$found" "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"); then
        err "替换主程序文件失败！"; cleanup_tmp; return 1
    fi

    example_cfg=$(find "$TMP_EXTRACT_DIR" -type f -name "config.example.yaml" | head -n 1)
    if [[ -n "$example_cfg" ]]; then
        install -m 600 "$example_cfg" "${WORK_DIR}/config.example.yaml" 2>/dev/null || true
    fi
    cleanup_tmp
    ok "主程序安装完成 (v${LATEST_VER})"
}

# --- 3. 备份与轮转 ---
prune_old_backups() {
    local list=() i
    mapfile -t list < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$1" 2>/dev/null | sort -r)
    for (( i=3; i<${#list[@]}; i++ )); do rm -f -- "${list[$i]}"; done
}

create_backup() {
    local mode="${1:-auto}" skip_prune="${2:-0}" ts cur_v v_tag=""
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    ts=$(date +"%Y%m%d_%H%M%S")
    cur_v=$(get_local_version)
    [[ ! "$cur_v" =~ ^(未安装|未知)$ ]] && v_tag="_v${cur_v}"

    LAST_BIN_BACKUP=""
    [[ -f "$CONFIG_PATH" ]] && install -m 600 "$CONFIG_PATH" "${BACKUP_DIR}/config_${mode}${v_tag}_${ts}.yaml"
    if [[ -f "$BIN_PATH" ]]; then
        LAST_BIN_BACKUP="${BACKUP_DIR}/cli-proxy-api_${mode}${v_tag}_${ts}"
        cp -a "$BIN_PATH" "$LAST_BIN_BACKUP"
    fi
    if [[ "$mode" == "manual" && -d "$AUTH_DIR" ]] && [[ -n "$(ls -A "$AUTH_DIR" 2>/dev/null)" ]]; then
        (umask 077 && tar -czf "${BACKUP_DIR}/auth_manual_${ts}.tar.gz" -C "$WORK_DIR" auth 2>/dev/null) || true
    fi
    if [[ "$skip_prune" != "1" ]]; then
        prune_old_backups "config_auto_*"
        prune_old_backups "cli-proxy-api_auto_*"
    fi
}

# --- 4. 业务功能模块 ---
deploy() {
    ensure_deps || { pause; return 1; }
    header "安装与配置向导"

    if [[ -x "$BIN_PATH" && -f "$CONFIG_PATH" ]]; then
        warn "检测到已安装 CLIProxyAPI ($(fmt_ver "$(get_local_version)"))"
        echo -e "  ${C_CYAN}1.${C_RESET} 平滑升级 ${C_GRAY}(保留现有配置与凭据)${C_RESET}"
        echo -e "  ${C_CYAN}2.${C_RESET} 重新配置 ${C_GRAY}(备份并重写配置)${C_RESET}"
        echo -e "  ${C_GRAY}0.${C_RESET} 返回\n"
        local dep_opt; prompt_read "  › 请选择 [0-2, 默认 1]: " dep_opt || return
        case "${dep_opt:-1}" in
            1) upgrade_lossless; return ;;
            2) create_backup "auto" ;;
            *) return ;;
        esac
    fi

    local old_key old_domain SECRET_KEY default_key raw_domain PROXY_DOMAIN=""
    old_key=$(parse_yaml_val "secret-key")
    [[ "$old_key" == \$2[abxy]\$* ]] && old_key=""
    old_domain=$(get_domain)

    info "安全策略: 固定监听本地回环 ${C_YELLOW}http://${LISTEN_ADDR}${C_RESET} (禁止外部直连)"
    default_key=${old_key:-$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24 || true)}
    [[ -z "$default_key" ]] && default_key="cpa_$(date +%s)_secret"

    while true; do
        prompt_read "  › 管理密钥 Secret Key [默认: ${default_key}]: " SECRET_KEY || return 1
        SECRET_KEY=${SECRET_KEY:-$default_key}
        if [[ "$SECRET_KEY" =~ [[:cntrl:]] ]]; then
            err "密钥不能包含控制字符，请重新输入！"
        else
            break
        fi
    done

    while true; do
        prompt_read "  › 反代域名 (如 api.example.com，留空跳过) [${old_domain:+默认: $old_domain}]: " raw_domain || return 1
        raw_domain=${raw_domain:-$old_domain}
        if PROXY_DOMAIN=$(sanitize_domain "$raw_domain"); then
            break
        else
            err "域名格式无效，请重新输入！"
        fi
    done

    mkdir -p "$WORK_DIR" "$AUTH_DIR" && chmod 700 "$WORK_DIR" "$AUTH_DIR"
    if [[ -n "$PROXY_DOMAIN" ]]; then
        (umask 077 && echo "$PROXY_DOMAIN" > "$DOMAIN_FILE")
    else
        rm -f "$DOMAIN_FILE"
    fi
    svc_ctl stop || true

    local update_bin="y"
    [[ -x "$BIN_PATH" ]] && { prompt_read "  › 是否更新主程序至官方最新版？[Y/n]: " update_bin || return 1; }
    if [[ ! "$update_bin" =~ ^[nN]$ ]]; then
        if ! { fetch_release_info && install_release_binary; }; then
            pause; return 1
        fi
    fi

    write_config "$SECRET_KEY"

    if [[ "$OS_ID" == "alpine" ]]; then
        cat << INIT > "$SERVICE_PATH"
#!/sbin/openrc-run
name="CLIProxyAPI"
supervisor="supervise-daemon"
respawn_delay=3
directory="${WORK_DIR}"
command="${BIN_PATH}"
command_args="--config ${CONFIG_PATH}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
rc_ulimit="-n 65535"
depend() { need net; after firewall; }
INIT
        chmod +x "$SERVICE_PATH"
        if [[ -d /etc/logrotate.d ]]; then
            cat << LOGROTATE > /etc/logrotate.d/cliproxy
${LOG_FILE} {
    daily
    rotate 7
    size 20M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROTATE
        fi
        rc-update add cliproxy default >/dev/null 2>&1 || true
        svc_ctl restart || svc_ctl start
    else
        cat << UNIT > "$SERVICE_PATH"
[Unit]
Description=CLIProxyAPI Service (${OFFICIAL_REPO})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_PATH} --config ${CONFIG_PATH}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
        chmod 644 "$SERVICE_PATH"
        systemctl daemon-reload && systemctl enable --now cliproxy >/dev/null 2>&1
    fi

    if ! wait_for_service; then
        err "服务启动失败，请通过 [4. 实时日志] 排查原因！"
        pause; return 1
    fi

    local base_url="http://${LISTEN_ADDR}"
    [[ -n "$PROXY_DOMAIN" ]] && base_url="https://${PROXY_DOMAIN}"

    header "部署完成"
    kv "当前版本" "$(fmt_ver "$(get_local_version)") (${OS_NAME})"
    kv "运行状态" "$(fmt_status)"
    kv "本地监听" "${C_YELLOW}http://${LISTEN_ADDR}${C_RESET} ${C_GREEN}(公网已隔离)${C_RESET}"
    kv "反代域名" "${PROXY_DOMAIN:+${C_CYAN}https://${PROXY_DOMAIN}${C_RESET}}${PROXY_DOMAIN:-${C_GRAY}未设置 (可在菜单 10 配置)${C_RESET}}"
    kv "管理面板" "${C_CYAN}${base_url}/management.html${C_RESET}"
    kv "管理密钥" "${C_GREEN}${SECRET_KEY}${C_RESET}"
    echo ""
    kv "OpenAI"   "${C_CYAN}${base_url}/v1/chat/completions${C_RESET}"
    kv "Claude"   "${C_CYAN}${base_url}/v1/messages${C_RESET}"
    kv "Models"   "${C_CYAN}${base_url}/v1/models${C_RESET}"
    echo ""
    pause
}

upgrade_lossless() {
    ensure_deps || { pause; return 1; }
    header "CLIProxyAPI 无损平滑升级"

    if [[ ! -x "$BIN_PATH" ]]; then
        warn "尚未安装主程序，即将跳转至安装向导..."
        sleep 1; deploy; return
    fi

    local local_ver confirm_up="y"
    local_ver=$(get_local_version)
    kv "本地版本" "$(fmt_ver "$local_ver")"
    info "正在查询 GitHub 最新发行版..."
    fetch_release_info || { pause; return 1; }
    kv "官方最新" "${C_GREEN}v${LATEST_VER}${C_RESET}"
    echo ""

    if [[ "$local_ver" == "$LATEST_VER" ]]; then
        ok "当前已是最新版本。"
        prompt_read "  › 是否强制重新下载覆盖安装？[y/N]: " confirm_up || return 0
        [[ ! "$confirm_up" =~ ^[yY]$ ]] && return 0
    else
        prompt_read "  › 确认平滑升级至 v${LATEST_VER}？[Y/n]: " confirm_up || return 0
        [[ "$confirm_up" =~ ^[nN]$ ]] && return 0
    fi

    create_backup "auto" "1"
    install_release_binary || { pause; return 1; }

    info "正在重启服务..."
    if ! restart_cliproxy; then
        err "新版本启动异常，正在自动回滚..."
        if [[ -n "$LAST_BIN_BACKUP" && -f "$LAST_BIN_BACKUP" ]]; then
            install -m 755 "$LAST_BIN_BACKUP" "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"
        fi
        if restart_cliproxy; then
            ok "已回滚至旧版本 ($(fmt_ver "$(get_local_version)"))"
        else
            err "回滚启动失败，请检查日志！"
        fi
        pause; return 1
    fi

    prune_old_backups "config_auto_*"
    prune_old_backups "cli-proxy-api_auto_*"
    ok "平滑升级成功：${C_YELLOW}v${local_ver}${C_RESET} -> ${C_GREEN}v$(get_local_version)${C_RESET}"
    pause
}

rollback() {
    header "历史版本回滚"
    local list=() f idx=1 bver choice
    [[ -d "$BACKUP_DIR" ]] && mapfile -t list < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "cli-proxy-api_*" 2>/dev/null | sort -r)
    [[ ${#list[@]} -gt 0 ]] || { warn "暂无可用的主程序历史备份！"; pause; return 1; }

    kv "当前版本" "$(fmt_ver "$(get_local_version)")"
    echo ""
    for f in "${list[@]}"; do
        bver=$(parse_binary_version "$f" 2>/dev/null || echo "未知")
        printf "  ${C_CYAN}%2d.${C_RESET} %-40s %b\n" "$idx" "$(basename "$f")" "$(fmt_ver "$bver")"
        ((idx++))
    done
    echo -e "\n  ${C_GRAY} 0.${C_RESET} 取消并返回\n"
    prompt_read "  › 请选择备份编号 [0-${#list[@]}]: " choice || return 0
    [[ -z "$choice" || "$choice" == "0" ]] && return 0
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#list[@]} )); then
        err "编号无效！"; pause; return 1
    fi

    install -m 755 "${list[$((choice-1))]}" "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"
    if restart_cliproxy; then
        ok "已成功回滚至 $(fmt_ver "$(get_local_version)")！"
    else
        err "回滚后启动失败，请查看日志！"
    fi
    pause
}

view_status() {
    header "服务运行状态详情"
    local auth_count=0 net_cmd="" cur_domain
    cur_domain=$(get_domain)
    [[ -d "$AUTH_DIR" ]] && auth_count=$(find "$AUTH_DIR" -type f 2>/dev/null | wc -l)

    kv "系统环境" "${OS_NAME}"
    kv "当前版本" "$(fmt_ver "$(get_local_version)")"
    kv "运行状态" "$(fmt_status)"
    kv "监听地址" "${C_YELLOW}${LISTEN_ADDR}${C_RESET} ${C_GREEN}(仅限本机访问)${C_RESET}"
    kv "反代域名" "${cur_domain:+${C_CYAN}https://${cur_domain}${C_RESET}}${cur_domain:-${C_GRAY}未设置${C_RESET}}"
    kv "授权凭据" "${C_GREEN}${auth_count}${C_RESET} 个 ${C_GRAY}(${AUTH_DIR})${C_RESET}"
    kv "配置文件" "${CONFIG_PATH}"
    echo ""
    echo -e "  ${C_BOLD}本地端口监听套接字:${C_RESET}"
    if command -v ss &>/dev/null; then
        net_cmd="ss"
    elif command -v netstat &>/dev/null; then
        net_cmd="netstat"
    fi
    if [[ -n "$net_cmd" ]]; then
        "$net_cmd" -tulpn 2>/dev/null | grep -iE ":${LOCKED_PORT}([[:space:]]|$)|cli-proxy" | sed 's/^/  /' \
            || echo -e "  ${C_GRAY}(当前未检测到监听进程)${C_RESET}"
    elif (echo >/dev/tcp/"$LOCKED_HOST"/"$LOCKED_PORT") 2>/dev/null; then
        echo -e "  ${C_GREEN}tcp  LISTEN  ${LISTEN_ADDR}${C_RESET} ${C_GRAY}(通过 /dev/tcp 探测可达)${C_RESET}"
    else
        echo -e "  ${C_GRAY}(当前未检测到监听端口)${C_RESET}"
    fi
    echo ""
    pause
}

view_logs() {
    [[ -f "$SERVICE_PATH" ]] || { warn "服务尚未安装！"; pause; return 1; }
    header "实时运行日志 (按 Ctrl+C 返回菜单)"
    trap 'echo ""' INT
    if [[ "$OS_ID" == "alpine" ]]; then
        [[ -f "$LOG_FILE" ]] || : > "$LOG_FILE"
        tail -n 50 -f "$LOG_FILE"
    else
        journalctl -u cliproxy -n 50 -f
    fi
    trap cleanup_tmp EXIT INT TERM HUP
}

backup_manage() {
    while true; do
        header "备份与还原管理"
        echo -e "  ${C_CYAN}1.${C_RESET} 创建完整备份  ${C_GRAY}(归档配置、凭据与主程序)${C_RESET}"
        echo -e "  ${C_CYAN}2.${C_RESET} 还原配置文件  ${C_GRAY}(恢复历史 config.yaml 并锁定本地端口)${C_RESET}"
        echo -e "  ${C_CYAN}3.${C_RESET} 查看备份列表  ${C_GRAY}(查看 ${BACKUP_DIR})${C_RESET}"
        echo -e "  ${C_RED}4.${C_RESET} 清空历史备份  ${C_GRAY}(删除所有备份归档)${C_RESET}"
        echo ""
        echo -e "  ${C_GRAY}0.${C_RESET} 返回主菜单\n"

        local bopt; prompt_read "  › 请选择 [0-4]: " bopt || return
        case "$bopt" in
            1) create_backup "manual"; ok "完整备份已保存至: ${BACKUP_DIR}"; pause ;;
            2)
                local baks=() f i=1 pick
                [[ -d "$BACKUP_DIR" ]] && mapfile -t baks < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "config_*.yaml" 2>/dev/null | sort -r)
                [[ ${#baks[@]} -gt 0 ]] || { warn "暂无配置文件备份！"; pause; continue; }
                echo ""
                for f in "${baks[@]}"; do printf "  ${C_CYAN}%2d.${C_RESET} %s\n" "$i" "$(basename "$f")"; ((i++)); done
                echo ""
                prompt_read "  › 请选择要恢复的编号 [0 取消]: " pick || continue
                [[ -z "$pick" || "$pick" == "0" ]] && continue
                if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#baks[@]} )); then
                    cp -f "${baks[$((pick-1))]}" "$CONFIG_PATH" && enforce_local_binding
                    ok "配置已恢复并锁定 ${LISTEN_ADDR}"
                    if svc_ctl status; then
                        if restart_cliproxy; then
                            ok "服务已重启生效。"
                        fi
                    fi
                else
                    err "编号无效！"
                fi
                pause ;;
            3)
                echo ""
                local found_files=0
                if [[ -d "$BACKUP_DIR" ]]; then
                    for f in "$BACKUP_DIR"/*; do
                        [[ -e "$f" ]] || continue
                        found_files=1
                        printf "  %-42s  %s\n" "$(basename "$f")" "$(du -h "$f" 2>/dev/null | awk '{print $1}')"
                    done
                fi
                [[ "$found_files" -eq 0 ]] && info "当前暂无任何备份文件。"
                pause ;;
            4)
                local cfm; prompt_read "  确认清空所有备份归档？[y/N]: " cfm || continue
                if [[ "$cfm" =~ ^[yY]$ ]]; then
                    rm -rf "${BACKUP_DIR:?}"/* 2>/dev/null
                    ok "备份已清空。"
                else
                    info "已取消。"
                fi
                pause ;;
            0) return ;;
        esac
    done
}

uninstall_cliproxy() {
    header "卸载与清理"
    warn "即将移除系统服务、主程序、配置文件及备份归档。"
    local confirm del_auth
    prompt_read "  确认卸载 CLIProxyAPI？[y/N]: " confirm || return 0
    [[ "$confirm" =~ ^[yY]$ ]] || return 0

    svc_ctl stop || true
    if [[ "$OS_ID" == "alpine" ]]; then
        rc-update del cliproxy default >/dev/null 2>&1 || true
        rm -f "$SERVICE_PATH" "$LOG_FILE" /etc/logrotate.d/cliproxy
    else
        systemctl disable cliproxy >/dev/null 2>&1 || true
        rm -f "$SERVICE_PATH" && systemctl daemon-reload
    fi
    rm -f "$BIN_PATH" "${BIN_PATH}.new" "$CONFIG_PATH" "$DOMAIN_FILE" "${WORK_DIR}/config.example.yaml" "$SCRIPT_LINK"
    rm -rf "$BACKUP_DIR"

    if [[ -d "$AUTH_DIR" ]] && [[ -n "$(ls -A "$AUTH_DIR" 2>/dev/null)" ]]; then
        prompt_read "  是否同时删除 ${AUTH_DIR} 下的所有授权凭据？[y/N]: " del_auth || del_auth="n"
        if [[ "$del_auth" =~ ^[yY]$ ]]; then
            rm -rf "$WORK_DIR"
            ok "已彻底卸载并清理全部凭据。"
        else
            ok "已卸载程序，凭据保留于: ${AUTH_DIR}"
        fi
    else
        rm -rf "$WORK_DIR" 2>/dev/null || true
        ok "CLIProxyAPI 已彻底卸载。"
    fi
    pause
}

proxy_guide() {
    header "域名反向代理配置指引"
    local cur_domain raw_domain new_domain
    cur_domain=$(get_domain)
    kv "本地上游" "${C_YELLOW}http://${LISTEN_ADDR}${C_RESET} ${C_GREEN}(仅本机可访问)${C_RESET}"
    kv "当前域名" "${cur_domain:-未设置}"
    echo ""

    prompt_read "  › 输入/更新反代域名 (回车保持 [${cur_domain:-api.example.com}]): " raw_domain || true
    if [[ -n "$raw_domain" ]]; then
        if new_domain=$(sanitize_domain "$raw_domain") && [[ -n "$new_domain" ]]; then
            mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"
            (umask 077 && echo "$new_domain" > "$DOMAIN_FILE")
            cur_domain="$new_domain"
            ok "反代域名已更新: ${cur_domain}"
        else
            err "域名格式无效，保持原配置。"
        fi
    fi
    local d="${cur_domain:-api.example.com}"

    echo -e "\n  ${C_BOLD}▸ 方案 A：Caddy 配置 (/etc/caddy/Caddyfile)${C_RESET}\n"
    cat << CADDY
${d} {
    # 可选安全加固：限制管理后台仅指定 IP 可访问
    # @admin path /management*
    # handle @admin {
    #     @blocked not remote_ip 127.0.0.1
    #     respond @blocked 403
    # }

    reverse_proxy ${LISTEN_ADDR} {
        flush_interval -1
    }
}
CADDY

    echo -e "\n  ${C_BOLD}▸ 方案 B：Nginx 配置 (支持 SSE 流式输出与 WebSocket)${C_RESET}\n"
    cat << NGINX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      '';
}

server {
    listen 80;
    listen 443 ssl http2; # 若 Nginx >= 1.25.1，可改为 listen 443 ssl; 并在下方加 http2 on;
    server_name ${d};

    # ssl_certificate     /path/to/fullchain.pem;
    # ssl_certificate_key /path/to/privkey.pem;
    client_max_body_size 50m;

    # 可选安全加固：限制管理后台仅指定 IP 可访问
    # location ~ ^/management {
    #     allow 127.0.0.1;
    #     deny all;
    #     proxy_pass http://${LISTEN_ADDR};
    # }

    location / {
        proxy_pass http://${LISTEN_ADDR};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX
    echo ""
    pause
}

# --- 5. 主循环入口 ---
main() {
    check_root
    check_os
    setup_shortcut

    while true; do
        clear 2>/dev/null || true
        echo ""
        local cur_dom dom_badge auth_count=0
        cur_dom=$(get_domain)
        dom_badge="${cur_dom:+${C_CYAN}${cur_dom}${C_RESET}}"
        [ -z "$dom_badge" ] && dom_badge="${C_GRAY}未绑定${C_RESET}"
        [ -d "$AUTH_DIR" ] && auth_count=$(find "$AUTH_DIR" -type f 2>/dev/null | wc -l)

        echo -e "  ${C_BOLD}CLIPROXY API${C_RESET}  $(fmt_status) $(fmt_ver "$(get_local_version)")  ${C_GRAY}(快捷命令: ${C_CYAN}cpapi${C_GRAY})${C_RESET}"
        echo -e "  ${C_GRAY}${OS_NAME} · ${LISTEN_ADDR} · 域名: ${dom_badge}${C_GRAY} · 凭据: ${auth_count} 个${C_RESET}"
        echo ""

        echo -e "  ${C_GRAY}服务${C_RESET}    ${C_CYAN}1${C_RESET} 启动服务    ${C_CYAN}2${C_RESET} 停止服务    ${C_CYAN}3${C_RESET} 重启服务    ${C_CYAN}4${C_RESET} 实时日志"
        echo -e "  ${C_GRAY}核心${C_RESET}    ${C_CYAN}5${C_RESET} 安装部署    ${C_CYAN}6${C_RESET} 平滑升级    ${C_CYAN}7${C_RESET} 历史回滚    ${C_CYAN}8${C_RESET} 状态详情"
        echo -e "  ${C_GRAY}数据${C_RESET}    ${C_CYAN}9${C_RESET} 备份还原   ${C_CYAN}10${C_RESET} 反代指引"
        echo -e "  ${C_GRAY}其他${C_RESET}    ${C_GRAY}0${C_RESET} 退出面板   ${C_RED}11${C_RESET} 卸载清理"
        echo ""

        local opt; prompt_read "  › 请选择 [1-11, 回车退出]: " opt || exit 0
        if [[ -z "$opt" || "$opt" == "0" || "$opt" =~ ^[qQ]$ ]]; then
            clear 2>/dev/null || true
            echo -e "\n  ${C_CYAN}已退出 CLIProxyAPI 管理面板${C_RESET} ${C_GRAY}(输入 cpapi 可再次打开)${C_RESET}\n"
            exit 0
        fi

        case "$opt" in
            1)  manage_service start ;;
            2)  manage_service stop ;;
            3)  manage_service restart ;;
            4)  view_logs ;;
            5)  deploy ;;
            6)  upgrade_lossless ;;
            7)  rollback ;;
            8)  view_status ;;
            9)  backup_manage ;;
            10) proxy_guide ;;
            11) uninstall_cliproxy ;;
            *)  err "无效的操作编号，请输入 0-11 之间的数字！" && sleep 0.8 ;;
        esac
    done
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
