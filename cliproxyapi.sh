#!/usr/bin/env sh
# shellcheck shell=bash
# =========================================================
#  CLIProxyAPI 运维管理脚本 (仅支持 Debian / Ubuntu / Alpine)
#  官方文档: https://help.router-for.me
#  官方仓库: router-for-me/CLIProxyAPI
# =========================================================

# 兼容 sh 调用（Alpine 最小化环境自动补齐 bash）
if [ -z "${BASH_VERSION:-}" ]; then
    if [ -f /etc/alpine-release ] && ! command -v bash >/dev/null 2>&1; then
        [ "$(id -u)" -eq 0 ] && apk add --no-cache bash >/dev/null 2>&1
    fi
    command -v bash >/dev/null 2>&1 && exec bash "$0" "$@"
    echo "[错误] 请先安装 bash 后再运行此脚本！" >&2
    exit 1
fi

set -o pipefail

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; GRAY="\033[90m"; PLAIN="\033[0m"
SEP="=============================================="
LINE="----------------------------------------------"

WORK_DIR="/root/cliproxyapi"
AUTH_DIR="${WORK_DIR}/auth"
BIN_PATH="${WORK_DIR}/cli-proxy-api"
CONFIG_PATH="${WORK_DIR}/config.yaml"
BACKUP_DIR="${WORK_DIR}/backup"
LOG_FILE="/var/log/cliproxy.log"
OFFICIAL_REPO="router-for-me/CLIProxyAPI"

info()   { echo -e "${BLUE}[信息]${PLAIN} $*"; }
ok()     { echo -e "${GREEN}[成功]${PLAIN} $*"; }
warn()   { echo -e "${YELLOW}[提示]${PLAIN} $*"; }
err()    { echo -e "${RED}[错误]${PLAIN} $*" >&2; }
header() { echo -e "\n${GREEN}${SEP}\n  $1\n${SEP}${PLAIN}"; }

# 0. 权限与发行版校验 (仅限 Debian / Ubuntu / Alpine)
[[ "$EUID" -ne 0 ]] && { err "请使用 root 用户运行此脚本！"; exit 1; }

check_os() {
    [[ -f /etc/os-release ]] || { err "无法识别操作系统，本脚本仅支持 Debian / Ubuntu / Alpine 发行版！"; exit 1; }
    local ID="" PRETTY_NAME=""
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID,,}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
    case "$OS_ID" in
        debian|ubuntu) SERVICE_PATH="/etc/systemd/system/cliproxy.service" ;;
        alpine)        SERVICE_PATH="/etc/init.d/cliproxy" ;;
        *) err "当前系统 (${OS_NAME}) 不受支持！本脚本仅支持 Debian / Ubuntu / Alpine 发行版。"; exit 1 ;;
    esac
}
check_os

# 1. 系统与服务辅助函数 (统一封装 systemd 与 OpenRC)
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) return 1 ;;
    esac
}

ensure_deps() {
    local missing=() cmd
    for cmd in curl tar; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    info "正在安装基础依赖: ${missing[*]} ..."
    if [[ "$OS_ID" == "alpine" ]]; then
        apk add --no-cache "${missing[@]}"
    else
        apt-get update -y && apt-get install -y "${missing[@]}"
    fi
}

get_port() {
    local p=""
    [[ -f "$CONFIG_PATH" ]] && p=$(awk '/^[[:space:]]*port:[[:space:]]*[0-9]+/ {print $2; exit}' "$CONFIG_PATH" 2>/dev/null)
    echo "${p:-8317}"
}

get_server_ip() {
    local ip
    ip=$(curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null \
        || curl -fsS4 --max-time 3 https://ifconfig.me 2>/dev/null \
        || ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    echo "${ip:-127.0.0.1}"
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

is_installed() {
    [[ -f "$SERVICE_PATH" || -x "$BIN_PATH" ]]
}

fmt_status() {
    local short="${1:-}"
    if svc_ctl status; then
        [[ "$short" == "-s" ]] && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${GREEN}运行中 (active)${PLAIN}"
    elif is_installed; then
        [[ "$short" == "-s" ]] && echo -e "${RED}已停止${PLAIN}" || echo -e "${RED}已停止 (inactive)${PLAIN}"
    else
        echo -e "${YELLOW}未安装${PLAIN}"
    fi
}

restart_cliproxy() {
    [[ -f "$SERVICE_PATH" ]] && svc_ctl restart && sleep 1 && svc_ctl status
}

manage_service() {
    [[ -f "$SERVICE_PATH" ]] || { warn "服务尚未安装，请先执行 [1. 安装部署]。"; return 1; }
    case "$1" in
        start)
            svc_ctl status && { info "服务当前已在运行中，无需重复启动。"; return 0; }
            svc_ctl start && sleep 1 && svc_ctl status && ok "服务启动成功！" \
                || { err "服务启动失败，请通过菜单 [5. 实时日志] 查看详细报错。"; return 1; }
            ;;
        stop)
            svc_ctl status || { info "服务当前已处于停止状态。"; return 0; }
            svc_ctl stop && ok "服务已停止运行。"
            ;;
        restart)
            restart_cliproxy && ok "服务重启成功！" \
                || { err "服务重启失败，请通过菜单 [5. 实时日志] 查看详细报错。"; return 1; }
            ;;
    esac
}

# 2. 版本解析与官方发布源获取
parse_binary_version() {
    local target="${1:-$BIN_PATH}"
    [[ -x "$target" ]] || return 1
    "$target" --help 2>&1 | awk -F'CLIProxyAPI Version: ' '/CLIProxyAPI Version:/ {
        sub(/,.*/, "", $2); gsub(/[v \r\n]/, "", $2); print $2; exit
    }'
}

get_local_version() {
    [[ -f "$BIN_PATH" ]] || { echo "未安装"; return; }
    local ver
    ver=$(parse_binary_version "$BIN_PATH" 2>/dev/null || true)
    echo "${ver:-未知}"
}

fmt_ver() {
    [[ "$1" =~ ^(未安装|未知)$ ]] && echo -e "${YELLOW}$1${PLAIN}" || echo -e "${CYAN}v$1${PLAIN}"
}

fetch_release_info() {
    local arch variant=""
    arch=$(detect_arch) || { err "当前系统架构暂不支持: $(uname -m)"; return 1; }
    [[ "$OS_ID" == "alpine" ]] && variant="_no-plugin"

    # 优先通过 302 Location 头获取最新 Tag（轻量快速且不受 GitHub API 速率限制）
    LATEST_TAG=$(curl -sI --max-time 10 "https://github.com/${OFFICIAL_REPO}/releases/latest" 2>/dev/null \
        | awk -F'/tag/' 'tolower($0) ~ /^location:.*\/tag\// {gsub(/[\r\n ]/, "", $2); print $2; exit}')

    if [[ -z "$LATEST_TAG" ]]; then
        LATEST_TAG=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${OFFICIAL_REPO}/releases/latest" 2>/dev/null \
            | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4)
    fi
    [[ -n "$LATEST_TAG" ]] || { err "无法获取官方最新版本信息，请检查网络连通性！"; return 1; }

    LATEST_VER="${LATEST_TAG#v}"
    DOWNLOAD_URL="https://github.com/${OFFICIAL_REPO}/releases/download/${LATEST_TAG}/CLIProxyAPI_${LATEST_VER}_linux_${arch}${variant}.tar.gz"
}

# 3. 核心二进制下载、校验与原子安装
install_release_binary() {
    local tmp_dir found test_out example_cfg
    tmp_dir=$(mktemp -d)
    trap "rm -rf -- '$tmp_dir'; trap - RETURN" RETURN
    mkdir -p "$WORK_DIR"

    info "正在下载官方程序包: ${DOWNLOAD_URL}"
    curl -fsSL -o "${tmp_dir}/pkg.tar.gz" "$DOWNLOAD_URL" || { err "程序包下载失败！"; return 1; }
    tar -zxf "${tmp_dir}/pkg.tar.gz" -C "$tmp_dir" 2>/dev/null || { err "程序包解压失败！"; return 1; }
    rm -f "${tmp_dir}/pkg.tar.gz"

    found=$(find "$tmp_dir" -type f \( -iname "cli-proxy-api" -o -iname "cliproxyapi" \) | head -n 1)
    [[ -n "$found" ]] || { err "解压包内未找到可执行主程序！"; return 1; }
    chmod +x "$found"

    if ! test_out=$("$found" --help 2>&1); then
        err "程序兼容性预检未通过，无法在当前系统运行！"
        echo -e "${YELLOW}${test_out}${PLAIN}"
        return 1
    fi

    install -m 755 "$found" "$BIN_PATH"
    example_cfg=$(find "$tmp_dir" -type f -name "config.example.yaml" | head -n 1)
    [[ -n "$example_cfg" ]] && cp -f "$example_cfg" "${WORK_DIR}/config.example.yaml" 2>/dev/null || true

    ok "主程序安装完成 (v${LATEST_VER})"
}

# 4. 备份与轮转管理
create_backup() {
    local mode="${1:-auto}" ts cur_v v_tag
    mkdir -p "$BACKUP_DIR"
    ts=$(date +"%Y%m%d_%H%M%S")
    cur_v=$(get_local_version)
    [[ "$cur_v" =~ ^(未安装|未知)$ ]] && cur_v=""
    v_tag="${cur_v:+_v${cur_v}}"

    LAST_BIN_BACKUP=""
    [[ -f "$CONFIG_PATH" ]] && cp -a "$CONFIG_PATH" "${BACKUP_DIR}/config_${mode}${v_tag}_${ts}.yaml"
    if [[ -f "$BIN_PATH" ]]; then
        LAST_BIN_BACKUP="${BACKUP_DIR}/cli-proxy-api_${mode}${v_tag}_${ts}"
        cp -a "$BIN_PATH" "$LAST_BIN_BACKUP"
    fi
    if [[ "$mode" == "manual" && -d "$AUTH_DIR" ]] && [[ -n "$(ls -A "$AUTH_DIR" 2>/dev/null)" ]]; then
        tar -czf "${BACKUP_DIR}/auth_manual_${ts}.tar.gz" -C "$WORK_DIR" auth 2>/dev/null || true
    fi

    # 自动备份仅保留最新 3 份，手动备份永久保留
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "config_auto_*" 2>/dev/null | sort -r | tail -n +4 | xargs -r rm -f
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "cli-proxy-api_auto_*" 2>/dev/null | sort -r | tail -n +4 | xargs -r rm -f
}

# 5. 安装部署向导
deploy() {
    clear
    ensure_deps || return 1
    header "CLIProxyAPI 安装与配置向导"

    if [[ -f "$BIN_PATH" && -f "$CONFIG_PATH" ]]; then
        warn "检测到系统已安装 CLIProxyAPI ($(fmt_ver "$(get_local_version)"))"
        echo -e "  ${GREEN}1.${PLAIN} 平滑升级      ${GRAY}保留现有配置与授权凭据 (推荐)${PLAIN}"
        echo -e "  ${YELLOW}2.${PLAIN} 重新配置      ${GRAY}自动备份原文件并重新生成配置${PLAIN}"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo -e "${LINE}"
        local dep_opt
        read -rp "请选择操作 [0-2, 默认: 1]: " dep_opt
        case "${dep_opt:-1}" in
            1) upgrade_lossless; return ;;
            2) create_backup "auto" ;;
            *) return ;;
        esac
    fi

    local old_port="" old_key="" PORT SECRET_KEY default_key
    if [[ -f "$CONFIG_PATH" ]]; then
        old_port=$(get_port)
        old_key=$(awk '/^[[:space:]]*secret-key:/ {gsub(/["'\'' ]/, "", $2); print $2; exit}' "$CONFIG_PATH" 2>/dev/null || true)
        [[ "$old_key" == \$2[abxy]\$* ]] && old_key=""
    fi

    read -rp "请输入监听端口 [1-65535, 默认: ${old_port:-8317}]: " PORT
    PORT=${PORT:-${old_port:-8317}}
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        err "无效的端口号 (${PORT})，请输入 1-65535 之间的整数！"
        return 1
    fi

    default_key=${old_key:-$(head -c 256 /dev/urandom 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24)}
    read -rp "请输入管理密钥 Secret Key [默认: ${default_key}]: " SECRET_KEY
    SECRET_KEY=${SECRET_KEY:-$default_key}

    mkdir -p "$AUTH_DIR"
    svc_ctl stop || true

    local update_bin="y"
    [[ -x "$BIN_PATH" ]] && read -rp "检测到本地已有主程序，是否更新至官方最新版？[Y/n]: " update_bin
    if [[ ! "$update_bin" =~ ^[nN]$ ]]; then
        info "正在查询 GitHub 最新发行版本..."
        fetch_release_info && install_release_binary || return 1
    fi

    info "正在写入配置文件 ${CONFIG_PATH} ..."
    cat << YAML > "$CONFIG_PATH"
config-version: 8

server:
  host: ""
  port: ${PORT}

management:
  allow-remote: true
  secret-key: "${SECRET_KEY}"

oauth:
  auth-dir: "auth"
YAML

    if [[ "$OS_ID" == "alpine" ]]; then
        info "正在配置 OpenRC 系统服务..."
        cat << INIT > "$SERVICE_PATH"
#!/sbin/openrc-run

name="CLIProxyAPI"
description="CLIProxyAPI Service (${OFFICIAL_REPO})"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
directory="${WORK_DIR}"
command="${BIN_PATH}"
command_args="--config ${CONFIG_PATH}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
rc_ulimit="-n 65535"

depend() {
    need net
    after firewall
}
INIT
        chmod +x "$SERVICE_PATH"
        rc-update add cliproxy default >/dev/null 2>&1 || true
        svc_ctl restart || svc_ctl start
    else
        info "正在配置 systemd 系统服务..."
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
        systemctl daemon-reload
        systemctl enable --now cliproxy
    fi

    if ! sleep 1 || ! svc_ctl status; then
        err "服务启动失败，请通过菜单 [5. 实时日志] 排查具体原因！"
        return 1
    fi

    local srv_ip
    srv_ip=$(get_server_ip)
    header "CLIProxyAPI 部署成功"
    echo -e "  系统环境   : ${OS_NAME}"
    echo -e "  当前版本   : $(fmt_ver "$(get_local_version)")"
    echo -e "  运行状态   : $(fmt_status)"
    echo -e "  本地地址   : ${YELLOW}http://127.0.0.1:${PORT}${PLAIN} ${GRAY}(反代上游地址)${PLAIN}"
    echo -e "  管理面板   : ${BLUE}http://${srv_ip}:${PORT}/management.html${PLAIN}"
    echo -e "  管理密钥   : ${GREEN}${SECRET_KEY}${PLAIN}"
    echo -e "  配置文件   : ${CONFIG_PATH}"
    echo -e "  凭据目录   : ${AUTH_DIR}"
    echo -e "${LINE}"
    echo -e "  常用接口端点:"
    echo -e "  - OpenAI   : ${BLUE}http://${srv_ip}:${PORT}/v1/chat/completions${PLAIN}"
    echo -e "  - Claude   : ${BLUE}http://${srv_ip}:${PORT}/v1/messages${PLAIN}"
    echo -e "  - 模型列表 : ${BLUE}http://${srv_ip}:${PORT}/v1/models${PLAIN}"
    echo -e "${GREEN}${SEP}${PLAIN}"
}

# 6. 无损平滑升级
upgrade_lossless() {
    clear
    header "CLIProxyAPI 无损平滑升级"
    ensure_deps || return 1

    if [[ ! -f "$BIN_PATH" ]]; then
        warn "尚未检测到已安装的 CLIProxyAPI 主程序。"
        read -rp "是否立即进入安装部署向导？[Y/n]: " do_install
        [[ ! "$do_install" =~ ^[nN]$ ]] && deploy
        return
    fi

    local local_ver
    local_ver=$(get_local_version)
    info "本地当前版本: $(fmt_ver "$local_ver")"
    info "正在查询 GitHub 最新发行版本..."
    fetch_release_info || return 1
    info "官方最新版本: ${GREEN}v${LATEST_VER}${PLAIN}"

    if [[ "$local_ver" == "$LATEST_VER" ]]; then
        ok "当前已是最新版本 (v${local_ver})，无需升级。"
        read -rp "是否仍要强制重新下载并覆盖安装？[y/N]: " force_up
        [[ ! "$force_up" =~ ^[yY]$ ]] && { info "已取消升级操作。"; return 0; }
    else
        read -rp "确认升级至 v${LATEST_VER}（完整保留现有配置与凭据）？[Y/n]: " confirm_up
        [[ "$confirm_up" =~ ^[nN]$ ]] && { info "已取消升级操作。"; return 0; }
    fi

    info "正在自动备份当前版本与配置文件..."
    create_backup "auto"

    install_release_binary || { err "升级已中止，现有运行服务未受影响。"; return 1; }

    info "正在平滑重启服务..."
    if ! restart_cliproxy; then
        err "新版本启动异常，正在触发自动回滚..."
        if [[ -n "$LAST_BIN_BACKUP" && -f "$LAST_BIN_BACKUP" ]]; then
            install -m 755 "$LAST_BIN_BACKUP" "$BIN_PATH"
            if restart_cliproxy; then
                ok "已自动回滚至稳定版本 ($(fmt_ver "$(get_local_version)"))。"
                return 1
            fi
        fi
        err "回滚后服务仍未能启动，请通过菜单 [5. 实时日志] 排查原因！"
        return 1
    fi

    header "CLIProxyAPI 平滑升级完成"
    echo -e "  版本变更   : ${YELLOW}v${local_ver}${PLAIN} -> ${GREEN}v$(get_local_version)${PLAIN}"
    echo -e "  运行状态   : $(fmt_status)"
    echo -e "  配置文件   : ${CONFIG_PATH} ${GREEN}(已完整保留)${PLAIN}"
    echo -e "  凭据目录   : ${AUTH_DIR} ${GREEN}(已完整保留)${PLAIN}"
    echo -e "  参考模板   : ${WORK_DIR}/config.example.yaml"
    echo -e "${GREEN}${SEP}${PLAIN}"
}

# 7. 历史版本回滚
rollback() {
    clear
    header "CLIProxyAPI 历史版本回滚"

    local backup_list=() f idx=1 bver choice target_bin
    [[ -d "$BACKUP_DIR" ]] && mapfile -t backup_list < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "cli-proxy-api_*" 2>/dev/null | sort -r)
    [[ ${#backup_list[@]} -gt 0 ]] || { warn "未找到可用的历史主程序备份！"; return 1; }

    echo -e "  当前运行版本: $(fmt_ver "$(get_local_version)")\n"
    echo -e "  可恢复的历史版本列表："
    for f in "${backup_list[@]}"; do
        bver=$(parse_binary_version "$f" 2>/dev/null || echo "未知")
        printf "  ${GREEN}%2d.${PLAIN} %-42s %b\n" "$idx" "$(basename "$f")" "$(fmt_ver "$bver")"
        ((idx++))
    done
    echo -e "${LINE}\n   ${GREEN}0.${PLAIN} 返回主菜单\n${LINE}"

    read -rp "请选择要恢复的备份编号 [0-${#backup_list[@]}]: " choice
    [[ -z "$choice" || "$choice" == "0" ]] && { info "已取消版本回滚。"; return 0; }
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backup_list[@]} )); then
        err "输入的编号无效！"
        return 1
    fi

    target_bin="${backup_list[$((choice-1))]}"
    info "正在恢复版本备份: $(basename "$target_bin") ..."
    install -m 755 "$target_bin" "$BIN_PATH"

    if restart_cliproxy; then
        ok "已成功回滚至 $(fmt_ver "$(get_local_version)")，服务运行正常！"
    else
        err "回滚后服务启动失败，请通过菜单 [5. 实时日志] 排查原因！"
        return 1
    fi
}

# 8. 查看状态与实时日志
view_status() {
    local cur_port cur_ver auth_count=0 net_cmd="netstat"
    cur_port=$(get_port)
    cur_ver=$(get_local_version)
    [[ -d "$AUTH_DIR" ]] && auth_count=$(find "$AUTH_DIR" -type f 2>/dev/null | wc -l)

    header "CLIProxyAPI 服务运行状态"
    echo -e "  系统环境   : ${OS_NAME}"
    echo -e "  当前版本   : $(fmt_ver "$cur_ver")"
    echo -e "  运行状态   : $(fmt_status)"
    if [[ -f "$CONFIG_PATH" ]] || is_installed; then
        echo -e "  监听端口   : ${YELLOW}${cur_port}${PLAIN}"
    else
        echo -e "  监听端口   : ${GRAY}-${PLAIN}"
    fi
    echo -e "  凭据数量   : ${GREEN}${auth_count}${PLAIN} 个 ${GRAY}(${AUTH_DIR})${PLAIN}"
    echo -e "  配置文件   : ${CONFIG_PATH}"
    echo -e "  程序路径   : ${BIN_PATH}"
    echo -e "${LINE}\n  端口监听详情:"
    command -v ss &>/dev/null && net_cmd="ss"
    "$net_cmd" -tulpn 2>/dev/null | grep -iE ":${cur_port}([[:space:]]|$)|cli-proxy" | sed 's/^/  /' \
        || echo -e "  ${GRAY}(当前未检测到端口监听进程)${PLAIN}"
    echo -e "${GREEN}${SEP}${PLAIN}"
}

view_logs() {
    [[ -f "$SERVICE_PATH" ]] || { warn "服务尚未安装，暂无运行日志可查看。"; return 1; }
    info "正在输出最近 50 行日志并持续跟踪 ${YELLOW}(按 Ctrl+C 返回主菜单)${PLAIN}..."
    echo -e "${LINE}"
    trap 'echo ""' INT
    if [[ "$OS_ID" == "alpine" ]]; then
        [[ -f "$LOG_FILE" ]] || : > "$LOG_FILE"
        tail -n 50 -f "$LOG_FILE"
    else
        journalctl -u cliproxy -n 50 -f
    fi
    trap - INT
}

# 9. 备份与还原管理
backup_manage() {
    clear
    while true; do
        header "CLIProxyAPI 备份与还原管理"
        echo -e "  ${GREEN}1.${PLAIN} 创建完整备份    ${GRAY}归档配置、授权凭据与当前主程序${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 还原配置文件    ${GRAY}从历史归档恢复 config.yaml${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} 查看备份列表    ${GRAY}查看备份目录文件与磁盘占用${PLAIN}"
        echo -e "  ${RED}4.${PLAIN} 清空历史备份    ${GRAY}删除 backup 目录下全部备份归档${PLAIN}"
        echo -e "${LINE}\n  ${GREEN}0.${PLAIN} 返回主菜单\n${GREEN}${SEP}${PLAIN}"

        local bopt
        read -rp "请输入选项 [0-4]: " bopt
        case "$bopt" in
            1)
                create_backup "manual"
                ok "完整备份已保存至: ${BACKUP_DIR}"
                ;;
            2)
                local cfg_baks=() f i=1 pick
                [[ -d "$BACKUP_DIR" ]] && mapfile -t cfg_baks < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "config_*.yaml" 2>/dev/null | sort -r)
                [[ ${#cfg_baks[@]} -gt 0 ]] || { warn "暂无可恢复的配置文件备份！"; continue; }

                echo -e "\n  可恢复的配置文件列表："
                for f in "${cfg_baks[@]}"; do
                    printf "  ${GREEN}%2d.${PLAIN} %s\n" "$i" "$(basename "$f")"
                    ((i++))
                done
                echo -e "   ${GREEN}0.${PLAIN} 取消还原"
                read -rp "请选择备份编号 [0-${#cfg_baks[@]}]: " pick
                [[ -z "$pick" || "$pick" == "0" ]] && { info "已取消还原。"; continue; }
                if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#cfg_baks[@]} )); then
                    cp -f "${cfg_baks[$((pick-1))]}" "$CONFIG_PATH"
                    ok "已恢复配置文件: $(basename "${cfg_baks[$((pick-1))]}")"
                    svc_ctl status && restart_cliproxy && ok "已自动重启服务使配置生效。"
                else
                    err "输入的编号无效！"
                fi
                ;;
            3)
                echo -e "\n  备份目录路径: ${BACKUP_DIR}\n${LINE}"
                if [[ -d "$BACKUP_DIR" ]] && [[ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
                    ls -lh "$BACKUP_DIR" | tail -n +2 | sed 's/^/  /'
                else
                    echo -e "  ${GRAY}(当前暂无任何备份文件)${PLAIN}"
                fi
                echo -e "${LINE}"
                ;;
            4)
                local cfm
                read -rp "确认清空 ${BACKUP_DIR} 下的所有备份归档？此操作不可恢复 [y/N]: " cfm
                if [[ "$cfm" =~ ^[yY]$ ]]; then
                    rm -rf "${BACKUP_DIR:?}"/* 2>/dev/null || true
                    ok "全部历史备份已清理完毕。"
                else
                    info "已取消清理操作。"
                fi
                ;;
            0) return ;;
            *) err "请输入有效选项 [0-4]！" ;;
        esac
    done
}

# 10. 卸载与清理
uninstall_cliproxy() {
    header "CLIProxyAPI 卸载与清理"
    echo -e "  即将移除: 系统服务、主程序、配置文件及历史备份"
    echo -e "  默认保留: ${AUTH_DIR} 授权凭据目录\n"

    local confirm del_auth
    read -rp "确认卸载 CLIProxyAPI？[y/N]: " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { info "已取消卸载。"; return 0; }

    svc_ctl stop || true
    if [[ "$OS_ID" == "alpine" ]]; then
        rc-update del cliproxy default >/dev/null 2>&1 || true
        rm -f "$SERVICE_PATH" "$LOG_FILE"
    else
        systemctl disable cliproxy 2>/dev/null || true
        rm -f "$SERVICE_PATH"
        systemctl daemon-reload
    fi
    rm -f "$BIN_PATH" "$CONFIG_PATH" "${WORK_DIR}/config.example.yaml"
    rm -rf "$BACKUP_DIR"

    if [[ -d "$AUTH_DIR" ]] && [[ -n "$(ls -A "$AUTH_DIR" 2>/dev/null)" ]]; then
        read -rp "是否一并删除 ${AUTH_DIR} 下的所有授权凭据？[y/N]: " del_auth
        if [[ "$del_auth" =~ ^[yY]$ ]]; then
            rm -rf "$WORK_DIR"
            ok "CLIProxyAPI 及全部凭据数据已彻底清理完毕。"
        else
            ok "程序已卸载，授权凭据仍保留于: ${AUTH_DIR}"
        fi
    else
        rm -rf "$WORK_DIR" 2>/dev/null || true
        ok "CLIProxyAPI 已彻底卸载清理完毕。"
    fi
}

# 11. 交互式运维主菜单
while true; do
    is_installed && port_display="${YELLOW}$(get_port)${PLAIN}" || port_display="${GRAY}-${PLAIN}"

    echo -e "
${GREEN}${SEP}
            CLIProxyAPI 运维管理面板${PLAIN}
  版本: $(fmt_ver "$(get_local_version)")  |  状态: $(fmt_status -s)  |  端口: ${port_display}
${GREEN}${SEP}${PLAIN}
  ${CYAN}[部署与版本]${PLAIN}
   ${GREEN}1.${PLAIN} 安装部署      ${GRAY}初始化安装或重新配置服务${PLAIN}
   ${GREEN}2.${PLAIN} 平滑升级      ${GRAY}无损更新版本，保留配置与凭据${PLAIN}
   ${GREEN}3.${PLAIN} 版本回滚      ${GRAY}回退至历史备份版本${PLAIN}
${GRAY}${LINE}${PLAIN}
  ${CYAN}[监控与控制]${PLAIN}
   ${GREEN}4.${PLAIN} 查看状态      ${GRAY}查看运行详情与端口监听状态${PLAIN}
   ${GREEN}5.${PLAIN} 实时日志      ${GRAY}跟踪运行日志 (Ctrl+C 返回)${PLAIN}
   ${GREEN}6.${PLAIN} 启动服务      ${GRAY}启动后台守护进程${PLAIN}
   ${GREEN}7.${PLAIN} 停止服务      ${GRAY}停止后台守护进程${PLAIN}
   ${GREEN}8.${PLAIN} 重启服务      ${GRAY}重载配置并重启进程${PLAIN}
${GRAY}${LINE}${PLAIN}
  ${CYAN}[数据与维护]${PLAIN}
   ${GREEN}9.${PLAIN} 备份管理      ${GRAY}备份、还原配置或清理归档${PLAIN}
  ${RED}10.${PLAIN} 卸载清理      ${GRAY}移除服务、主程序及相关文件${PLAIN}
${GRAY}${LINE}${PLAIN}
   ${GREEN}0.${PLAIN} 退出脚本
${GREEN}${SEP}${PLAIN}"
    read -rp "请输入操作编号 [0-10]: " opt
    case "$opt" in
        1)  deploy ;;
        2)  upgrade_lossless ;;
        3)  rollback ;;
        4)  view_status ;;
        5)  view_logs ;;
        6)  manage_service start ;;
        7)  manage_service stop ;;
        8)  manage_service restart ;;
        9)  backup_manage ;;
        10) uninstall_cliproxy ;;
        0)  exit 0 ;;
        *)  err "请输入有效的操作编号 [0-10]！" ;;
    esac
done
