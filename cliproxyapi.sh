#!/usr/bin/env bash
# =========================================================
#  CLIProxyAPI + Caddy 运维管理脚本 (官方文档标准规范版)
#  官方文档: https://help.router-for-me
#  官方仓库: router-for-me/CLIProxyAPI
# =========================================================

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; PLAIN="\033[0m"
WORK_DIR="/root/cliproxyapi"
AUTH_DIR="${WORK_DIR}/auth"
BIN_PATH="${WORK_DIR}/cli-proxy-api"
CONFIG_PATH="${WORK_DIR}/config.yaml"
BACKUP_DIR="${WORK_DIR}/backup"
VERSION_FILE="${WORK_DIR}/version.txt"
SERVICE_PATH="/etc/systemd/system/cliproxy.service"
CADDYFILE="/etc/caddy/Caddyfile"
OFFICIAL_REPO="router-for-me/CLIProxyAPI"

# 0. 权限检查
[[ "$EUID" -ne 0 ]] && { echo -e "${RED}[错误] 必须使用 root 用户执行此脚本！${PLAIN}"; exit 1; }

# 1. 系统与服务状态辅助函数
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) echo "unsupported" ;;
    esac
}

is_musl() {
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi 'musl'; then
        return 0
    fi
    [[ -f /etc/alpine-release || -f /etc/openwrt_release ]] && return 0
    local m
    for m in /lib/ld-musl* /usr/lib/ld-musl*; do
        [[ -e "$m" ]] && return 0
    done
    return 1
}

get_service_status() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "active"
    elif [[ -f "/etc/systemd/system/${svc}.service" ]] || command -v "$svc" &>/dev/null; then
        echo "inactive"
    else
        echo "未安装"
    fi
}

restart_cliproxy() {
    [[ -f "$SERVICE_PATH" ]] || return 0
    systemctl daemon-reload
    systemctl restart cliproxy
    sleep 2
    systemctl is-active --quiet cliproxy
}

# 2. 版本获取与解析
parse_binary_version() {
    local target="${1:-$BIN_PATH}"
    [[ -x "$target" ]] || return 1
    "$target" --help 2>&1 | awk -F'CLIProxyAPI Version: ' '/CLIProxyAPI Version:/ {print $2}' | awk -F',' '{print $1}' | tr -d 'v \r\n'
}

get_local_version() {
    local ver
    ver=$(parse_binary_version "$BIN_PATH")
    [[ -z "$ver" && -f "$VERSION_FILE" ]] && ver=$(tr -d 'v \r\n' < "$VERSION_FILE" 2>/dev/null)
    if [[ -z "$ver" ]]; then
        [[ -f "$BIN_PATH" ]] && echo "未知" || echo "未安装"
    else
        echo "$ver"
    fi
}

fetch_release_info() {
    local arch
    arch=$(detect_arch)
    if [[ "$arch" == "unsupported" ]]; then
        echo -e "${RED}[错误] 暂不支持当前系统架构: $(uname -m)${PLAIN}"
        return 1
    fi

    local musl=false
    is_musl && musl=true

    local release_json=""
    release_json=$(curl -sL --max-time 10 "https://api.github.com/repos/${OFFICIAL_REPO}/releases/latest" 2>/dev/null || true)
    
    LATEST_TAG=""
    LATEST_VER=""
    DOWNLOAD_URL=""

    [[ -n "$release_json" ]] && LATEST_TAG=$(echo "$release_json" | jq -r '.tag_name // empty' 2>/dev/null || true)

    # API 速率受限或无返回时通过 Location 标头兜底
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        local loc_header
        loc_header=$(curl -sIL --max-time 10 "https://github.com/${OFFICIAL_REPO}/releases/latest" 2>/dev/null | grep -i '^location:' | head -n 1 || true)
        LATEST_TAG=$(echo "$loc_header" | awk -F'/tag/' '{print $2}' | tr -d '\r\n ')
    fi

    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        echo -e "${RED}[错误] 无法获取官方最新版本信息，请检查网络或 GitHub 连通性！${PLAIN}"
        return 1
    fi

    LATEST_VER="${LATEST_TAG#v}"

    if [[ -n "$release_json" ]]; then
        # shellcheck disable=SC2016
        local filter='test("linux"; "i") and test($a; "i") and (test("rpm|deb|apk"; "i") | not)'
        if [[ "$musl" == "true" ]]; then
            filter+=' and test("no-plugin"; "i")'
        else
            filter+=' and (test("no-plugin"; "i") | not)'
        fi
        DOWNLOAD_URL=$(echo "$release_json" | jq -r --arg a "$arch" ".assets[] | select($filter) | .browser_download_url" 2>/dev/null | head -n 1)
    fi

    if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
        local variant=""
        [[ "$musl" == "true" ]] && variant="_no-plugin"
        DOWNLOAD_URL="https://github.com/${OFFICIAL_REPO}/releases/download/${LATEST_TAG}/CLIProxyAPI_${LATEST_VER}_linux_${arch}${variant}.tar.gz"
    fi

    return 0
}

# 3. 基础运行环境检查与初始化
init_system() {
    local mem_total swap_total
    mem_total=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo 0)
    swap_total=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}' || echo 0)
    if [[ "$swap_total" -eq 0 && "$mem_total" -lt 2048 && "$mem_total" -gt 0 ]]; then
        echo -e "${YELLOW}[*] 检测到内存较小且无 Swap，配置 2GB Swap 虚拟内存...${PLAIN}"
        fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null || true
        chmod 600 /swapfile 2>/dev/null || true
        mkswap /swapfile 2>/dev/null || true
        swapon /swapfile 2>/dev/null || true
        grep -q "/swapfile" /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp 443/tcp >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port={80,443}/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    echo -e "${BLUE}[*] 检查安装基础运行环境与 Caddy...${PLAIN}"
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y curl wget tar unzip jq psmisc debian-keyring debian-archive-keyring apt-transport-https
        if ! command -v caddy &>/dev/null; then
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes 2>/dev/null || true
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null 2>&1 || true
            apt-get update -y && apt-get install -y caddy
        fi
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        yum install -y curl wget tar unzip jq psmisc
        if ! command -v caddy &>/dev/null; then
            yum install -y 'dnf-command(copr)' 2>/dev/null || true
            yum copr enable -y @caddy/caddy && yum install -y caddy
        fi
    fi
}

# 4. 数据快照与备份管理
backup_current_state() {
    mkdir -p "$BACKUP_DIR"
    local ts cur_v v_tag
    ts=$(date +"%Y%m%d_%H%M%S")
    cur_v=$(get_local_version)
    [[ "$cur_v" == "未安装" || "$cur_v" == "未知" ]] && cur_v=""
    v_tag="${cur_v:+_v${cur_v}}"

    [[ -f "$CONFIG_PATH" ]] && cp -a "$CONFIG_PATH" "${BACKUP_DIR}/config${v_tag}_${ts}.yaml" && cp -a "$CONFIG_PATH" "${WORK_DIR}/config.yaml.bak"
    [[ -f "$BIN_PATH" ]] && cp -a "$BIN_PATH" "${BACKUP_DIR}/cli-proxy-api${v_tag}_${ts}" && cp -a "$BIN_PATH" "${WORK_DIR}/cli-proxy-api.bak"

    # 自动轮转保留最新 5 个历史备份
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "config_*" 2>/dev/null | sort | head -n -5 | xargs -r rm -f 2>/dev/null || true
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "cli-proxy-api_*" 2>/dev/null | sort | head -n -5 | xargs -r rm -f 2>/dev/null || true
}

# 5. 下载解压与核心二进制安装通用管道
download_and_extract_pkg() {
    local tmp_dir="$1"
    echo -e "${BLUE}[*] 正在下载程序包: ${DOWNLOAD_URL}${PLAIN}"
    if ! curl -sL -f -o "${tmp_dir}/pkg" "$DOWNLOAD_URL"; then
        echo -e "${RED}[错误] 下载官方程序包失败！${PLAIN}"
        return 1
    fi

    if tar -ztf "${tmp_dir}/pkg" &>/dev/null; then
        tar -zxf "${tmp_dir}/pkg" -C "$tmp_dir"
    elif unzip -t "${tmp_dir}/pkg" &>/dev/null; then
        unzip -qo "${tmp_dir}/pkg" -d "$tmp_dir"
    else
        mv "${tmp_dir}/pkg" "${tmp_dir}/cli-proxy-api"
    fi

    local found
    found=$(find "$tmp_dir" -type f \( -iname "*cliproxyapi*" -o -iname "*cli-proxy-api*" \) | head -n 1)
    if [[ -z "$found" || ! -f "$found" ]]; then
        echo -e "${RED}[错误] 未在解压包中找到核心可执行程序！${PLAIN}"
        return 1
    fi
    chmod +x "$found"

    # 运行前兼容性预检
    local test_out
    if ! test_out=$("$found" --help 2>&1); then
        echo -e "${RED}[错误] 运行前预检失败，程序无法在当前系统中正常执行！${PLAIN}"
        echo -e "${YELLOW}错误输出: ${test_out}${PLAIN}"
        return 1
    fi

    # 原子替换安装
    install -m 755 "$found" "$BIN_PATH" || mv -f "$found" "$BIN_PATH"

    # 更新官方配置示例 (供用户参考，绝不影响 config.yaml)
    local example_cfg
    example_cfg=$(find "$tmp_dir" -type f -name "config.example.yaml" | head -n 1)
    if [[ -n "$example_cfg" && -f "$example_cfg" ]]; then
        cp -f "$example_cfg" "${WORK_DIR}/config.example.yaml" 2>/dev/null || true
    fi

    echo "$LATEST_VER" > "$VERSION_FILE"
    return 0
}

download_official_binary() {
    echo -e "${BLUE}[*] 正在向官方 GitHub 请求最新发布版本...${PLAIN}"
    fetch_release_info || return 1
    echo -e "${GREEN}[*] 官方最新版本号: ${LATEST_TAG}${PLAIN}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    mkdir -p "$WORK_DIR"
    if download_and_extract_pkg "$tmp_dir"; then
        rm -rf "$tmp_dir"
        echo -e "${GREEN}[成功] 官方程序文件就绪！(版本: ${LATEST_TAG})${PLAIN}"
        return 0
    else
        rm -rf "$tmp_dir"
        return 1
    fi
}

# 6. 无损平滑升级 (保留全部配置、授权数据与反代证书)
upgrade_lossless() {
    clear
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}       CLIProxyAPI 无损平滑升级 (Zero Downtime)     ${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"

    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${YELLOW}[提示] 未检测到已安装的 CLIProxyAPI 程序 (${BIN_PATH})${PLAIN}"
        read -rp "是否立即转为执行全新安装部署？[Y/n]: " do_install
        [[ ! "$do_install" =~ ^[nN]$ ]] && deploy
        return
    fi

    local local_ver
    local_ver=$(get_local_version)
    echo -e "${BLUE}[*] 当前本地版本: ${YELLOW}v${local_ver:-未知}${PLAIN}"
    echo -e "${BLUE}[*] 正在向官方 GitHub 查询最新发布版本...${PLAIN}"
    fetch_release_info || return 1
    echo -e "${BLUE}[*] 官方最新版本: ${GREEN}${LATEST_TAG}${PLAIN}"

    if [[ -n "$local_ver" && "$local_ver" != "未知" && "$local_ver" == "$LATEST_VER" ]]; then
        echo -e "\n${GREEN}[✓] 当前本地运行版本与官方最新版本一致 (v${local_ver})。${PLAIN}"
        read -rp "是否仍要重新下载并强制重新升级？[y/N]: " force_up
        [[ ! "$force_up" =~ ^[yY]$ ]] && { echo -e "${BLUE}[*] 升级流程已取消。${PLAIN}"; return 0; }
    fi

    echo -e "\n${YELLOW}[*] 即将执行无损升级（将完整保留 config.yaml 配置与 auth/ 授权凭证）${PLAIN}"
    read -rp "确认开始无损平滑升级？[Y/n]: " confirm_up
    [[ "$confirm_up" =~ ^[nN]$ ]] && { echo -e "${BLUE}[*] 用户已取消。${PLAIN}"; return 0; }

    echo -e "\n${BLUE}[*] 正在创建当前配置与运行快照备份...${PLAIN}"
    backup_current_state

    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! download_and_extract_pkg "$tmp_dir"; then
        rm -rf "$tmp_dir"
        echo -e "${RED}[错误] 升级失败！现有服务完全未受影响。${PLAIN}"
        return 1
    fi
    rm -rf "$tmp_dir"

    echo -e "${BLUE}[*] 正在平滑重启服务...${PLAIN}"
    if ! restart_cliproxy; then
        echo -e "\n${RED}[警告] 新版本启动异常，检测到 cliproxy 服务未能正常运行！${PLAIN}"
        echo -e "${YELLOW}[*] 触发自动回滚保护机制，正在还原上一稳定版本...${PLAIN}"
        if [[ -f "${WORK_DIR}/cli-proxy-api.bak" ]]; then
            install -m 755 "${WORK_DIR}/cli-proxy-api.bak" "$BIN_PATH"
            if restart_cliproxy; then
                echo -e "${GREEN}[✓] 自动回滚成功！上一稳定版本已恢复正常运行。${PLAIN}"
                local rb_ver
                rb_ver=$(get_local_version)
                echo "$rb_ver" > "$VERSION_FILE"
                return 1
            fi
        fi
        echo -e "${RED}[致命] 回滚后服务依然未启动成功，请检查日志: journalctl -u cliproxy -f${PLAIN}"
        return 1
    fi

    if command -v caddy &>/dev/null; then
        systemctl reload caddy >/dev/null 2>&1 || true
    fi

    # 升级成功，清理备份文件以释放空间
    echo -e "${BLUE}[*] 升级成功，正在清理备份文件以释放磁盘空间...${PLAIN}"
    rm -f "${WORK_DIR}/cli-proxy-api.bak" "${WORK_DIR}/config.yaml.bak" 2>/dev/null || true
    if [[ -d "$BACKUP_DIR" ]]; then
        rm -f "${BACKUP_DIR}"/config_* "${BACKUP_DIR}"/cli-proxy-api_* 2>/dev/null || true
        rmdir "$BACKUP_DIR" 2>/dev/null || true
    fi

    local final_ver
    final_ver=$(get_local_version)
    echo -e "\n${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}        🎉 CLIProxyAPI 无损平滑升级已成功完成！        ${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "升级前版本   : ${YELLOW}v${local_ver:-未知}${PLAIN}"
    echo -e "升级后版本   : ${GREEN}v${final_ver}${PLAIN}"
    echo -e "后端服务状态 : ${GREEN}$(get_service_status cliproxy)${PLAIN}"
    echo -e "用户配置文件 : ${BLUE}${CONFIG_PATH}${PLAIN} ${GREEN}(100% 完整保留)${PLAIN}"
    echo -e "认证凭据目录 : ${BLUE}${AUTH_DIR}${PLAIN} ${GREEN}(100% 完整保留)${PLAIN}"
    echo -e "参考配置示例 : ${YELLOW}${WORK_DIR}/config.example.yaml${PLAIN}"
    echo -e "备份文件清理 : ${GREEN}已自动清理备份文件 (释放磁盘空间)${PLAIN}"
    echo -e "====================================================${PLAIN}"
}

# 7. 版本回滚功能
rollback() {
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}         CLIProxyAPI 版本回滚           ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"

    local bak_bin="${WORK_DIR}/cli-proxy-api.bak"
    local backup_list=()
    if [[ -d "$BACKUP_DIR" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && backup_list+=("$f")
        done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "cli-proxy-api_*" 2>/dev/null | sort -r)
    fi

    if [[ ! -f "$bak_bin" && ${#backup_list[@]} -eq 0 ]]; then
        echo -e "${YELLOW}[提示] 未找到可回滚的历史二进制文件备份！${PLAIN}"
        return 1
    fi

    echo -e "可用的回滚选项："
    local idx=1
    if [[ -f "$bak_bin" ]]; then
        local bak_ver
        bak_ver=$(parse_binary_version "$bak_bin")
        echo -e "  [${idx}] 上一个版本 (.bak) [版本: v${bak_ver:-未知}]"
        idx=$((idx+1))
    fi

    for bf in "${backup_list[@]}"; do
        echo -e "  [${idx}] 历史备份: $(basename "$bf")"
        idx=$((idx+1))
    done
    echo -e "  [0] 取消回滚"

    local choice
    read -rp "请选择要恢复的版本 [0-$((idx-1))]: " choice
    [[ "$choice" == "0" || -z "$choice" ]] && { echo -e "${BLUE}[*] 已取消回滚。${PLAIN}"; return 0; }

    local target_bin=""
    if [[ -f "$bak_bin" && "$choice" -eq 1 ]]; then
        target_bin="$bak_bin"
    else
        local offset=$choice
        [[ -f "$bak_bin" ]] && offset=$((choice-1))
        local target_index=$((offset-1))
        if [[ $target_index -ge 0 && $target_index -lt ${#backup_list[@]} ]]; then
            target_bin="${backup_list[$target_index]}"
        fi
    fi

    if [[ -z "$target_bin" || ! -f "$target_bin" ]]; then
        echo -e "${RED}[错误] 选择无效！${PLAIN}"
        return 1
    fi

    echo -e "${BLUE}[*] 正在回滚至: $(basename "$target_bin")...${PLAIN}"
    cp -f "$BIN_PATH" "${WORK_DIR}/cli-proxy-api.before_rollback" 2>/dev/null || true
    install -m 755 "$target_bin" "$BIN_PATH" || mv -f "$target_bin" "$BIN_PATH"
    local rb_ver
    rb_ver=$(get_local_version)
    echo "$rb_ver" > "$VERSION_FILE"

    if restart_cliproxy; then
        echo -e "${GREEN}[成功] 已成功回滚至版本: v${rb_ver}，服务运行正常！${PLAIN}"
    else
        echo -e "${RED}[错误] 回滚后服务启动失败，请检查日志: journalctl -u cliproxy -n 20${PLAIN}"
    fi
}

# 8. 备份与还原管理
backup_manage() {
    clear
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}       CLIProxyAPI 备份与还原管理       ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "  1. 手动创建当前完整备份 (配置 + 授权凭据 + 二进制)"
    echo -e "  2. 还原历史配置文件 (config.yaml)"
    echo -e "  3. 查看现有备份列表与空间占用"
    echo -e "  4. 清理所有历史备份"
    echo -e "  0. 返回主菜单"
    echo -e "----------------------------------------"
    local bopt
    read -rp "请输入选项 [0-4]: " bopt
    case "$bopt" in
        1)
            mkdir -p "$BACKUP_DIR"
            local ts
            ts=$(date +"%Y%m%d_%H%M%S")
            echo -e "${BLUE}[*] 正在创建完整备份...${PLAIN}"
            [[ -f "$CONFIG_PATH" ]] && cp -a "$CONFIG_PATH" "${BACKUP_DIR}/config_manual_${ts}.yaml"
            [[ -f "$BIN_PATH" ]] && cp -a "$BIN_PATH" "${BACKUP_DIR}/cli-proxy-api_manual_${ts}"
            if [[ -d "$AUTH_DIR" && $(find "$AUTH_DIR" -type f 2>/dev/null | wc -l) -gt 0 ]]; then
                tar -czf "${BACKUP_DIR}/auth_manual_${ts}.tar.gz" -C "$WORK_DIR" auth 2>/dev/null || true
            fi
            echo -e "${GREEN}[成功] 完整备份已创建在: ${BACKUP_DIR}${PLAIN}"
            ;;
        2)
            local cfg_baks=()
            while IFS= read -r f; do
                [[ -n "$f" ]] && cfg_baks+=("$f")
            done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "config_*.yaml" 2>/dev/null | sort -r)

            if [[ ${#cfg_baks[@]} -eq 0 ]]; then
                echo -e "${YELLOW}[提示] 没有找到可恢复的配置文件备份！${PLAIN}"
                return
            fi
            echo -e "可恢复的配置文件列表："
            local i=1
            for cb in "${cfg_baks[@]}"; do
                echo -e "  [${i}] $(basename "$cb")"
                i=$((i+1))
            done
            local pick
            read -rp "请选择要恢复的配置编号 [1-${#cfg_baks[@]}]: " pick
            if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#cfg_baks[@]} )); then
                local sel="${cfg_baks[$((pick-1))]}"
                cp -f "$CONFIG_PATH" "${WORK_DIR}/config.yaml.before_restore" 2>/dev/null || true
                cp -f "$sel" "$CONFIG_PATH"
                echo -e "${GREEN}[成功] 已成功还原配置: $(basename "$sel")${PLAIN}"
                systemctl is-active --quiet cliproxy 2>/dev/null && restart_cliproxy && echo -e "${GREEN}[*] 已重启后端服务使配置生效。${PLAIN}"
            else
                echo -e "${RED}[错误] 无效的编号！${PLAIN}"
            fi
            ;;
        3)
            echo -e "\n当前备份目录 (${BACKUP_DIR}) 内容："
            [[ -d "$BACKUP_DIR" ]] && ls -lh "$BACKUP_DIR" || echo -e "备份目录为空。"
            ;;
        4)
            local cfm
            read -rp "确认清理 ${BACKUP_DIR} 下的所有历史备份文件？[y/N]: " cfm
            if [[ "$cfm" =~ ^[yY]$ ]]; then
                if [[ -d "$BACKUP_DIR" ]]; then
                    rm -rf "${BACKUP_DIR:?}"/* 2>/dev/null || true
                fi
                echo -e "${GREEN}[成功] 历史备份已清理。${PLAIN}"
            fi
            ;;
        0) return ;;
        *) echo -e "${RED}请输入有效选项！${PLAIN}" ;;
    esac
}

# 9. 官方标准安装与重新部署流程
deploy() {
    clear
    init_system
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}    CLIProxyAPI 官方标准一键部署流程    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"

    if [[ -f "$BIN_PATH" && -f "$CONFIG_PATH" ]]; then
        echo -e "${YELLOW}[提示] 检测到当前系统已存在 CLIProxyAPI 安装与配置！${PLAIN}"
        echo -e "  当前已安装版本: v$(get_local_version)"
        echo -e "----------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} 执行【无损平滑升级】 (推荐，保留全部现有配置与账号)"
        echo -e "  ${RED}2.${PLAIN} 重新部署 / 覆盖初始化配置 (原配置将自动备份)"
        echo -e "  ${PLAIN}0.${PLAIN} 返回主菜单"
        echo -e "----------------------------------------"
        local dep_opt
        read -rp "请选择操作 [默认: 1]: " dep_opt
        dep_opt=${dep_opt:-1}
        case "$dep_opt" in
            1) upgrade_lossless; return ;;
            2) backup_current_state ;;
            *) return ;;
        esac
    fi

    local old_domain="" old_key="" old_port=""
    if [[ -f "$CONFIG_PATH" ]]; then
        old_port=$(awk '/^port:/ {print $2}' "$CONFIG_PATH" 2>/dev/null || true)
        old_key=$(awk '/^secret-key:/ {gsub(/["'\'' ]/, "", $2); print $2}' "$CONFIG_PATH" 2>/dev/null || true)
        [[ -f "$CADDYFILE" ]] && old_domain=$(head -n 1 "$CADDYFILE" 2>/dev/null | awk '{print $1}')
    fi

    local DOMAIN SECRET_KEY PORT default_key
    read -rp "绑定公网域名 [默认: ${old_domain:-api.onc.cc}]: " DOMAIN
    DOMAIN=${DOMAIN:-${old_domain:-api.onc.cc}}

    default_key=${old_key:-$(tr -dc A-Za-z0-9 </dev/urandom 2>/dev/null | head -c 24)}
    read -rp "管理密钥 Secret Key [默认: ${default_key}]: " SECRET_KEY
    SECRET_KEY=${SECRET_KEY:-$default_key}

    read -rp "本地监听端口 [默认: ${old_port:-8317}]: " PORT
    PORT=${PORT:-${old_port:-8317}}

    mkdir -p "$AUTH_DIR"
    pkill -9 -f "cli-proxy-api" 2>/dev/null || true
    fuser -k -9 "${PORT}/tcp" 2>/dev/null || true

    if [[ -f "$BIN_PATH" ]]; then
        local update_bin
        read -rp "检测到本地已有二进制文件，是否从官方更新最新版本？[y/N]: " update_bin
        [[ "$update_bin" =~ ^[yY]$ ]] && download_official_binary
    else
        download_official_binary
    fi

    echo -e "${BLUE}[*] 生成官方标准 config.yaml...${PLAIN}"
    cat << YAML > "$CONFIG_PATH"
port: ${PORT}
secret-key: "${SECRET_KEY}"
remote-management:
  allow-remote: true
  secret-key: "${SECRET_KEY}"
auth-dir: "auth"
log-level: "info"
timeout: 120s
YAML

    echo -e "${BLUE}[*] 配置 systemd 服务守护...${PLAIN}"
    cat << UNIT > "$SERVICE_PATH"
[Unit]
Description=CLI Proxy API Service (router-for-me)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_PATH}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now cliproxy

    echo -e "${BLUE}[*] 配置 Caddy 反代与自动 SSL...${PLAIN}"
    mkdir -p /etc/caddy
    cat << CADDY > "$CADDYFILE"
${DOMAIN} {
    reverse_proxy 127.0.0.1:${PORT} {
        flush_interval -1
        transport http {
            keepalive 30s
            keepalive_idle_conns 10
        }
    }
    encode gzip zstd
}
CADDY

    caddy fmt -w "$CADDYFILE" >/dev/null 2>&1 || true
    systemctl enable --now caddy
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true

    echo -e "\n${GREEN}================ 部署完成 ================${PLAIN}"
    echo -e "管理控制台   : ${BLUE}https://${DOMAIN}/management.html${PLAIN}"
    echo -e "控制台配置   : 服务地址请填写 ${YELLOW}https://${DOMAIN}${PLAIN} ${RED}(绝不要加 /v1！)${PLAIN}"
    echo -e "管理密钥     : ${GREEN}${SECRET_KEY}${PLAIN}"
    echo -e "API 端点规范 : "
    echo -e "  - OpenAI   : ${BLUE}https://${DOMAIN}/v1/chat/completions${PLAIN}"
    echo -e "  - Claude   : ${BLUE}https://${DOMAIN}/v1/messages${PLAIN}"
    echo -e "  - 模型列表 : ${BLUE}https://${DOMAIN}/v1/models${PLAIN}"
    echo -e "认证数据目录 : ${YELLOW}${AUTH_DIR}${PLAIN} (OAuth 与登录 Session 持久化)"
    echo -e "==========================================${PLAIN}"
}

# 10. 查看服务状态与端口
view_status() {
    local cur_port cur_ver auth_count domain cpa_st caddy_st
    cur_port=$(awk '/^port:/ {print $2}' "$CONFIG_PATH" 2>/dev/null || echo 8317)
    cur_ver=$(get_local_version)
    auth_count=0
    [[ -d "$AUTH_DIR" ]] && auth_count=$(find "$AUTH_DIR" -type f 2>/dev/null | wc -l)
    cpa_st=$(get_service_status cliproxy)
    caddy_st=$(get_service_status caddy)
    domain=""
    [[ -f "$CADDYFILE" ]] && domain=$(head -n 1 "$CADDYFILE" 2>/dev/null | awk '{print $1}')

    echo -e "\n${GREEN}================== 服务运行状态 ==================${PLAIN}"
    [[ "$cur_ver" =~ ^(未安装|未知)$ ]] && echo -e "程序当前版本 : ${YELLOW}${cur_ver}${PLAIN}" || echo -e "程序当前版本 : ${BLUE}v${cur_ver#v}${PLAIN}"

    [[ "$cpa_st" == "active" ]] && echo -e "后端服务状态 : ${GREEN}运行中 (active)${PLAIN}" || echo -e "后端服务状态 : ${RED}${cpa_st}${PLAIN}"
    [[ "$caddy_st" == "active" ]] && echo -e "Caddy 反代状态: ${GREEN}运行中 (active)${PLAIN}" || echo -e "Caddy 反代状态: ${RED}${caddy_st}${PLAIN}"

    echo -e "本地监听端口 : ${YELLOW}${cur_port}${PLAIN}"
    [[ -n "$domain" ]] && echo -e "绑定公网域名 : ${BLUE}https://${domain}${PLAIN}"
    echo -e "授权凭据数量 : ${GREEN}${auth_count}${PLAIN} 个 (位于 ${AUTH_DIR})"
    echo -e "配置文件路径 : ${CONFIG_PATH}"
    echo -e "--------------------------------------------------"
    echo -e "端口与进程监听："
    ss -tulpn 2>/dev/null | grep -iE "${cur_port}|caddy|cli-proxy" || netstat -tulpn 2>/dev/null | grep -iE "${cur_port}|caddy|cli-proxy" || true
    echo -e "=================================================="
}

# 11. 交互式运维面板
while true; do
    cur_ver=$(get_local_version)
    cpa_st=$(get_service_status cliproxy)
    cpa_display="${RED}已停止${PLAIN}"
    [[ "$cpa_st" == "active" ]] && cpa_display="${GREEN}运行中${PLAIN}"
    [[ "$cpa_st" == "未安装" ]] && cpa_display="${YELLOW}未安装${PLAIN}"

    ver_display="${YELLOW}${cur_ver}${PLAIN}"
    [[ ! "$cur_ver" =~ ^(未安装|未知)$ ]] && ver_display="${BLUE}v${cur_ver#v}${PLAIN}"

    echo -e "
${GREEN}=== CLIProxyAPI 官方标准运维面板 ===${PLAIN}
  当前版本: ${ver_display}  |  后端状态: ${cpa_display}
---------------------------------
  ${GREEN}1.${PLAIN} 一键安装部署 CLIProxyAPI
  ${GREEN}2.${PLAIN} ${YELLOW}无损平滑升级 CLIProxyAPI (保留全部配置与授权)${PLAIN}
  ${GREEN}3.${PLAIN} 版本回滚 (恢复至上一版本二进制)
  ${GREEN}4.${PLAIN} 查看服务状态与端口
  ${GREEN}5.${PLAIN} 备份与还原管理 (配置/凭据)
  ${GREEN}6.${PLAIN} 重启所有服务
  ${GREEN}7.${PLAIN} 停止后端服务
  ${GREEN}8.${PLAIN} 启动后端服务
  ${GREEN}9.${PLAIN} 查看 CLIProxyAPI 实时日志
  ${GREEN}10.${PLAIN} 查看 Caddy 访问/SSL 日志
  ${GREEN}11.${PLAIN} 彻底卸载清理
  ${GREEN}0.${PLAIN} 退出脚本
---------------------------------"
    read -rp "请输入选项 [0-11]: " opt
    case "$opt" in
        1) deploy ;;
        2) upgrade_lossless ;;
        3) rollback ;;
        4) view_status ;;
        5) backup_manage ;;
        6) restart_cliproxy && (systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true) && echo -e "${GREEN}已完成重启${PLAIN}" ;;
        7) systemctl stop cliproxy && echo -e "${YELLOW}后端服务已停止${PLAIN}" ;;
        8) systemctl start cliproxy && echo -e "${GREEN}后端服务已启动${PLAIN}" ;;
        9) journalctl -u cliproxy -f ;;
        10) journalctl -u caddy -f ;;
        11)
            read -rp "确认彻底卸载 CLIProxyAPI？此操作不会删除已有的 auth 授权数据 [y/N]: " confirm
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                systemctl disable --now cliproxy 2>/dev/null || true
                rm -f "$SERVICE_PATH" "$BIN_PATH" "$CONFIG_PATH" "$VERSION_FILE"
                systemctl daemon-reload
                echo -e "${GREEN}程序已卸载。auth 授权数据保留在: ${AUTH_DIR}${PLAIN}"
            fi
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入有效选项！${PLAIN}" ;;
    esac
done
