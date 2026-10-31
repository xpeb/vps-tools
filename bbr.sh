#!/usr/bin/env bash
# bbr.sh — Debian / Alpine 网络/内核调优（drop-in 写入）
# 动态项按内存计算，只增不减；当前值已超上限时保留当前值。
# 运行方式：bash bbr.sh（需 root）
# 回滚：bash /var/lib/bbr/rollback.sh

# POSIX sh (如 Alpine ash / Debian dash) 启动自举
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if [ -f /etc/alpine-release ] || { [ -f /etc/os-release ] && grep -qi alpine /etc/os-release 2>/dev/null; }; then
            echo "[INFO] 检测到 Alpine Linux 且未安装 bash，正在自动安装必要依赖..." >&2
            if command -v apk >/dev/null 2>&1; then
                apk update >/dev/null 2>&1 && apk add --no-cache bash >/dev/null 2>&1 || {
                    echo "[ERROR] 安装 bash 失败，请先执行: apk add bash" >&2
                    exit 1
                }
            fi
        else
            echo "[ERROR] 请用 bash 运行: bash $0" >&2
            exit 1
        fi
    fi
    if command -v bash >/dev/null 2>&1; then
        [ -r "$0" ] && exec bash "$0" "$@" || exec bash -s -- "$@"
    else
        echo "[ERROR] 请用 bash 运行: bash $0" >&2
        exit 1
    fi
fi
set -euo pipefail

SYSCTL_FILE=/etc/sysctl.d/99-tuning.conf
LIMITS_FILE=/etc/security/limits.d/99-tuning.conf
MODULES_FILE=/etc/modules-load.d/99-tuning.conf
MODPROBE_FILE=/etc/modprobe.d/99-tuning.conf
JOURNAL_FILE=/etc/systemd/journald.conf.d/99-tuning.conf
SYSTEMD_NOFILE_FILE=/etc/systemd/system.conf.d/99-tuning.conf
PROFILE_FILE=/etc/profile.d/99-tuning.sh
STATE_DIR=/var/lib/bbr
ORIG_DIR=/var/lib/bbr/original
PREV_FILE=/var/lib/bbr/previous.conf
QDISC_FILE=/var/lib/bbr/qdisc.previous
ROLLBACK_SH=/var/lib/bbr/rollback.sh
RC_BEGIN="# --- bbr.sh begin ---"
RC_END="# --- bbr.sh end ---"
OS_KIND=""

fs_file_max=0 conntrack_max=0 rmem_max=0 wmem_max=0 backlog=0 somaxconn=0 tw_buckets=0
nofile=0 rmem_def=0 wmem_def=0 ct_buckets=0
memory_mb=0 mem_show="" cc=cubic qdisc="" CT_NOTE="" CT_SYSCTL_WRITABLE=0
BBR_MISSING=0 DRY_RUN=0 ASSUME_YES=0
LOADED_MODULES=()

die() { echo "[ERROR] $*" >&2; exit 1; }
sysctl_get() { sysctl -n "$1" 2>/dev/null || echo 0; }
normalize_ws() { local IFS=$' \t\n'; set -f; echo $*; }

usage() {
    cat <<'USAGE'
用法: bash bbr.sh [选项]

  无参数        计算并显示将要做的变更，确认后执行
  --dry-run, -n 只显示"当前值 -> 计划值"，不做任何修改
  --yes, -y     跳过确认，直接执行（用于无人值守）
  --help, -h    显示本帮助
  rollback      回滚到首次运行前的配置与 qdisc

回滚: bash /var/lib/bbr/rollback.sh
说明: 动态项只增不减，脚本不会把已调高的值调低。
USAGE
}

round_pow2_up() {
    local v=${1:-1} p=1
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo 1; return 0; }
    while [ "$p" -lt "$v" ]; do p=$((p * 2)); done
    echo "$p"
}

check_deps() {
    local c missing=0 apk_pkgs=()
    if [ "$OS_KIND" = alpine ] && command -v apk >/dev/null 2>&1; then
        command -v modinfo >/dev/null 2>&1 || apk_pkgs+=("kmod")
        command -v tc >/dev/null 2>&1 || apk_pkgs+=("iproute2-tc")
        if [ "${#apk_pkgs[@]}" -gt 0 ]; then
            echo "[INFO] Alpine 补充必要工具包: ${apk_pkgs[*]}" >&2
            apk add --no-cache "${apk_pkgs[@]}" >/dev/null 2>&1 || true
        fi
    fi

    for c in sysctl awk; do
        if ! command -v "$c" >/dev/null 2>&1; then
            echo "[ERROR] 缺少必要命令: $c" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "请先安装依赖后重试"
    command -v tc >/dev/null 2>&1 || echo "[WARN] 无 tc，现有网卡 qdisc 不会被改动（仅新网卡生效）" >&2
}

bbr_available() {
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
    modinfo tcp_bbr >/dev/null 2>&1 || [ -d /sys/module/tcp_bbr ] || \
        find "/lib/modules/$(uname -r 2>/dev/null)" -name "*tcp_bbr.ko*" 2>/dev/null | grep -q .
}

fq_available() {
    grep -qw fq /proc/sys/net/core/default_qdisc 2>/dev/null && return 0
    modinfo sch_fq >/dev/null 2>&1 || [ -d /sys/module/sch_fq ] || \
        find "/lib/modules/$(uname -r 2>/dev/null)" -name "*sch_fq.ko*" 2>/dev/null | grep -q .
}

tune() {
    local cur=${1:-0} calc=$2 min=$3 max=$4 v
    if [ "$cur" -ge "$max" ]; then echo "$cur"; return; fi
    v=$calc
    [ "$cur" -gt "$v" ] && v=$cur
    [ "$v" -lt "$min" ] && v=$min
    [ "$v" -gt "$max" ] && v=$max
    echo "$v"
}

compute_tuning() {
    local mem=$1
    fs_file_max=$(tune "$2" $((mem * 512)) 524288 4194304)
    conntrack_max=$(tune "$3" $((mem * 128)) 65536 2097152)
    rmem_max=$(tune "$4" $((mem * 8192)) 4194304 134217728)
    wmem_max=$(tune "$5" $((mem * 8192)) 4194304 134217728)
    backlog=$(tune "$6" $((mem * 256)) 32768 524288)
    somaxconn=$(tune "$7" $((mem * 32)) 1024 65535)
    tw_buckets=$(tune "$8" $((mem * 32)) 16384 1048576)
    (( nofile = fs_file_max > 1048576 ? 1048576 : fs_file_max ))

    # TCP 自动调优的默认值保持保守：接收 128K~512K，发送 16K~64K，防止高并发 OOM
    (( rmem_def = rmem_max / 32 ))
    (( rmem_def = rmem_def < 131072 ? 131072 : (rmem_def > 524288 ? 524288 : rmem_def) ))
    (( wmem_def = wmem_max / 64 ))
    (( wmem_def = wmem_def < 16384 ? 16384 : (wmem_def > 65536 ? 65536 : wmem_def) ))
    (( ct_buckets = conntrack_max / 4 ))
}

sysctl_line_set() {
    local line=$1 key val
    key=${line%%=*}; val=${line#*=}
    printf '%s=%s\n' "${key// /}" "${val# }"
}

sysctl_keys() {
    local dev
    printf '%s\n' \
        vm.swappiness fs.file-max net.core.rmem_max net.core.wmem_max \
        net.core.netdev_max_backlog net.core.somaxconn net.core.default_qdisc \
        net.ipv4.ip_forward net.ipv4.ip_local_port_range net.ipv4.tcp_syncookies \
        net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time \
        net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
        net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_notsent_lowat \
        net.ipv4.tcp_no_metrics_save net.ipv4.tcp_congestion_control \
        net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_buckets \
        net.netfilter.nf_conntrack_tcp_timeout_established \
        net.netfilter.nf_conntrack_tcp_timeout_time_wait \
        net.netfilter.nf_conntrack_udp_timeout \
        net.netfilter.nf_conntrack_udp_timeout_stream \
        net.ipv6.conf.all.forwarding net.ipv6.conf.default.forwarding \
        net.ipv6.conf.all.accept_ra net.ipv6.conf.default.accept_ra
    for dev in /sys/class/net/*; do
        dev=$(basename "$dev")
        [ "$dev" = lo ] || [ ! -e "/sys/class/net/$dev/device" ] && continue
        printf 'net.ipv6.conf.%s.accept_ra\n' "$dev"
    done
}

snapshot_sysctl() {
    mkdir -p "$STATE_DIR"
    [ -f "$PREV_FILE" ] || : > "$PREV_FILE"
    local -A existing
    local key val
    while IFS='=' read -r key _; do
        key=${key// /}
        [ -n "$key" ] && existing["$key"]=1
    done < "$PREV_FILE"

    while IFS= read -r key; do
        [ -n "$key" ] && [ -z "${existing[$key]:-}" ] || continue
        val=$(sysctl -n "$key" 2>/dev/null) || continue
        val=$(normalize_ws "$val")
        [ -n "$val" ] || continue
        printf '%s = %s\n' "$key" "$val" >> "$PREV_FILE"
        existing["$key"]=1
    done < <(sysctl_keys)
}

snapshot_files() {
    [ -f "$STATE_DIR/files.manifest" ] && return 0
    mkdir -p "$STATE_DIR" "$ORIG_DIR"
    : > "$STATE_DIR/files.manifest"
    local f dst
    for f in "$SYSCTL_FILE" "$LIMITS_FILE" "$MODULES_FILE" "$MODPROBE_FILE" \
             "$JOURNAL_FILE" "$SYSTEMD_NOFILE_FILE" "$PROFILE_FILE" /etc/rc.conf /etc/modules; do
        if [ -e "$f" ]; then
            printf 'present\t%s\n' "$f" >> "$STATE_DIR/files.manifest"
            dst="$ORIG_DIR$f"
            mkdir -p "$(dirname "$dst")"
            cp -a "$f" "$dst"
        else
            printf 'absent\t%s\n' "$f" >> "$STATE_DIR/files.manifest"
        fi
    done
}

render_sysctl() {
    local dev
    cat <<EOF
# 由 bbr.sh 生成（请勿手工编辑，回滚见 /var/lib/bbr/rollback.sh）
vm.swappiness = 1
fs.file-max = $fs_file_max

net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.netdev_max_backlog = $backlog
net.core.somaxconn = $somaxconn
EOF
    [ -n "${qdisc:-}" ] && printf '%s\n' "$qdisc"
    cat <<EOF
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_syn_backlog = $somaxconn
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = $tw_buckets
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rmem = 4096 $rmem_def $rmem_max
net.ipv4.tcp_wmem = 4096 $wmem_def $wmem_max
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_congestion_control = $cc

net.netfilter.nf_conntrack_max = $conntrack_max
EOF
    [ "${CT_SYSCTL_WRITABLE:-0}" -eq 1 ] && printf 'net.netfilter.nf_conntrack_buckets = %s\n' "$ct_buckets"
    cat <<EOF
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 10
net.netfilter.nf_conntrack_udp_timeout_stream = 60

net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# forwarding=1 会停收 RA，SLAAC 机器需 accept_ra=2 才不丢 IPv6
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
EOF
    for dev in /sys/class/net/*; do
        dev=$(basename "$dev")
        [ "$dev" = lo ] || [ ! -e "/sys/class/net/$dev/device" ] && continue
        printf 'net.ipv6.conf.%s.accept_ra = 2\n' "$dev"
    done
}

mem_mb() {
    local kb
    kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    (( memory_mb = ${kb:-0} / 1024 ))
    (( memory_mb >= 1 )) || die "无法读取内存"
    (( memory_mb >= 1024 )) && mem_show="$((memory_mb / 1024))G" || mem_show="${memory_mb}M"
}

apply_sysctl_file() {
    local line set
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        set=$(sysctl_line_set "$line")
        sysctl -w "$set" >/dev/null 2>&1 || echo "[WARN] 跳过: $line" >&2
    done < "$SYSCTL_FILE"
}

detect_os() {
    [ -f /etc/os-release ] && . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) OS_KIND=debian ;;
        alpine) OS_KIND=alpine ;;
        *)
            if [ -f /etc/alpine-release ]; then
                OS_KIND=alpine
            elif [ -f /etc/debian_version ]; then
                OS_KIND=debian
            else
                die "仅支持 Debian/Ubuntu 和 Alpine，当前为: ${ID:-unknown}"
            fi
            ;;
    esac
}

load_tuning_modules() {
    LOADED_MODULES=()
    local m
    for m in tcp_bbr sch_fq; do
        modprobe "$m" 2>/dev/null && LOADED_MODULES+=("$m")
    done
}

# 文本标记块通用维护函数（用于 /etc/rc.conf 及 /etc/modules）
replace_block() {
    local file=$1 tmp
    shift
    [ -f "$file" ] || touch "$file" 2>/dev/null || return 0
    tmp=$(mktemp) || return 1
    awk -v b="$RC_BEGIN" -v e="$RC_END" '
        function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
        trim($0) == b { skip=1; next }
        trim($0) == e { skip=0; next }
        !skip { print }
    ' "$file" > "$tmp"
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$RC_BEGIN" >> "$tmp"
        printf '%s\n' "$@" >> "$tmp"
        printf '%s\n' "$RC_END" >> "$tmp"
    fi
    chmod 644 "$tmp"
    mv "$tmp" "$file"
}

persist_modules() {
    local lines=("${LOADED_MODULES[@]}")
    [ -d /sys/module/nf_conntrack ] && lines+=("nf_conntrack")

    if [ "${#lines[@]}" -eq 0 ]; then
        rm -f "$MODULES_FILE"
        [ "$OS_KIND" = alpine ] && replace_block /etc/modules
        return 0
    fi
    mkdir -p /etc/modules-load.d
    printf '%s\n' "${lines[@]}" > "$MODULES_FILE"
    [ "$OS_KIND" = alpine ] && replace_block /etc/modules "${lines[@]}"
}

apply_conntrack_buckets() {
    local target=$1 current
    modprobe nf_conntrack 2>/dev/null || true

    if [ -w /proc/sys/net/netfilter/nf_conntrack_buckets ]; then
        CT_SYSCTL_WRITABLE=1
        sysctl -w "net.netfilter.nf_conntrack_buckets=$target" >/dev/null 2>&1 || true
        current=$(sysctl_get net.netfilter.nf_conntrack_buckets)
        rm -f "$MODPROBE_FILE"
        CT_NOTE="buckets=$current（sysctl 生效）"
        [ "$current" = "$target" ] || echo "[WARN] nf_conntrack_buckets 设置未达目标 $target（当前 $current）" >&2
        return 0
    fi

    CT_SYSCTL_WRITABLE=0
    mkdir -p /etc/modprobe.d
    printf 'options nf_conntrack hashsize=%s\n' "$target" > "$MODPROBE_FILE"
    current=$(sysctl_get net.netfilter.nf_conntrack_buckets)
    CT_NOTE="buckets=$current（已写入模块参数 hashsize=$target，重启生效）"
}

qdisc_info() {
    tc qdisc show dev "$1" 2>/dev/null | awk '$1=="qdisc" && $4=="root" { print $2, $3; exit }' || true
}

apply_fq_now() {
    command -v tc >/dev/null 2>&1 || {
        echo "[WARN] 无 tc，未改现有网卡 qdisc" >&2
        return 0
    }
    mkdir -p "$STATE_DIR"
    local dev kind handle info
    for dev in /sys/class/net/*; do
        dev=$(basename "$dev")
        [ "$dev" = lo ] || [ ! -e "/sys/class/net/$dev/device" ] && continue
        info=$(qdisc_info "$dev")
        [ -n "$info" ] || continue
        read -r kind handle <<< "$info"
        if [ ! -f "$QDISC_FILE" ] || ! grep -q "^${dev} " "$QDISC_FILE" 2>/dev/null; then
            printf '%s %s %s\n' "$dev" "$kind" "$handle" >> "$QDISC_FILE"
        fi
        [ "$kind" = fq ] || [ "$kind" = mq ] && continue
        tc qdisc replace dev "$dev" root fq >/dev/null 2>&1 || echo "[WARN] 跳过网卡 $dev 的 qdisc" >&2
    done
}

write_if_changed() {
    local path=$1 content=$2
    if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
        return 1
    fi
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
}

write_limits() {
    mkdir -p /etc/security/limits.d
    printf '%s\n' \
        "* soft nofile $nofile" "* hard nofile $nofile" \
        "root soft nofile $nofile" "root hard nofile $nofile" \
        > "$LIMITS_FILE"
    [ "$OS_KIND" = alpine ] && write_if_changed "$PROFILE_FILE" $'# 由 bbr.sh 生成，登录 shell 提高 nofile\nulimit -n '$nofile$' 2>/dev/null || true' || true
}

write_rc_ulimit() {
    [ "$OS_KIND" = alpine ] || return 0
    replace_block /etc/rc.conf "rc_ulimit=\"\${rc_ulimit:-\${RC_ULIMIT:-}} -n $nofile\""
}

write_journald() {
    [ "$OS_KIND" = debian ] || return 0
    local want=$'[Journal]\nSystemMaxUse=384M\nSystemMaxFileSize=128M'
    if write_if_changed "$JOURNAL_FILE" "$want"; then
        systemctl try-restart systemd-journald >/dev/null 2>&1 || true
    fi
}

write_systemd_nofile() {
    [ "$OS_KIND" = debian ] || return 0
    write_if_changed "$SYSTEMD_NOFILE_FILE" "[Manager]"$'\n'"DefaultLimitNOFILE=65535:$nofile" || true
}

write_rollback_script() {
    mkdir -p "$STATE_DIR"
    cat > "$ROLLBACK_SH" <<'SH'
#!/bin/sh
[ "$(id -u)" -eq 0 ] || { echo "[ERROR] 请以 root 运行" >&2; exit 1; }
sysctl -p /var/lib/bbr/previous.conf >/dev/null 2>&1 || true
if [ -f /var/lib/bbr/qdisc.previous ] && command -v tc >/dev/null 2>&1; then
    while read -r dev kind handle _; do
        [ -n "$dev" ] && [ -e "/sys/class/net/$dev" ] || continue
        tc qdisc del dev "$dev" root >/dev/null 2>&1 || true
        if [ "$handle" = "0:" ]; then
            current=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$1=="qdisc" && $4=="root" { print $2; exit }')
            if [ "$current" != "$kind" ]; then
                tc qdisc replace dev "$dev" root "$kind" >/dev/null 2>&1 || echo "[WARN] 无法恢复 $dev qdisc" >&2
            fi
        else
            tc qdisc add dev "$dev" root handle "$handle" "$kind" >/dev/null 2>&1 \
                || tc qdisc replace dev "$dev" root "$kind" >/dev/null 2>&1 \
                || echo "[WARN] 无法恢复 $dev qdisc" >&2
        fi
    done < /var/lib/bbr/qdisc.previous
fi
if [ -f /var/lib/bbr/files.manifest ]; then
    while IFS="$(printf '\t')" read -r state path; do
        [ -n "$path" ] || continue
        case "$state" in
            present)
                src="/var/lib/bbr/original$path"
                mkdir -p "$(dirname "$path")"
                cp -a "$src" "$path"
                ;;
            absent) rm -f "$path" ;;
        esac
    done < /var/lib/bbr/files.manifest
fi
command -v systemctl >/dev/null 2>&1 && { systemctl daemon-reload >/dev/null 2>&1 || true; systemctl try-restart systemd-journald >/dev/null 2>&1 || true; }
command -v rc-service >/dev/null 2>&1 && rc-service sysctl restart >/dev/null 2>&1 || true
rm -rf /var/lib/bbr
echo "[INFO] 已回滚配置和 qdisc；已加载模块及 conntrack buckets 可能需重启后完全恢复"
SH
    chmod 755 "$ROLLBACK_SH"
}

do_rollback() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 运行"
    [ -f "$ROLLBACK_SH" ] || die "没有可回滚的记录"
    sh "$ROLLBACK_SH"
}

main() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 运行"
    detect_os
    check_deps
    mem_mb
    compute_tuning "$memory_mb" \
        "$(sysctl_get fs.file-max)" \
        "$(sysctl_get net.netfilter.nf_conntrack_max)" \
        "$(sysctl_get net.core.rmem_max)" \
        "$(sysctl_get net.core.wmem_max)" \
        "$(sysctl_get net.core.netdev_max_backlog)" \
        "$(sysctl_get net.core.somaxconn)" \
        "$(sysctl_get net.ipv4.tcp_max_tw_buckets)"

    ct_buckets=$(round_pow2_up $((conntrack_max / 4)))
    current_buckets=$(sysctl_get net.netfilter.nf_conntrack_buckets)
    if [[ "$current_buckets" =~ ^[0-9]+$ ]] && [ "$current_buckets" -gt "$ct_buckets" ]; then
        ct_buckets=$current_buckets
    fi

    CT_SYSCTL_WRITABLE=0
    if [ -w /proc/sys/net/netfilter/nf_conntrack_buckets ] || [ ! -d /sys/module/nf_conntrack ]; then
        CT_SYSCTL_WRITABLE=1
    fi

    cc=cubic qdisc="" BBR_MISSING=0 CT_NOTE="未检查（dry-run）"
    if bbr_available; then
        cc=bbr
        fq_available && qdisc="net.core.default_qdisc = fq"
    else
        BBR_MISSING=1
    fi

    show_plan
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] 以上仅为预览，未修改任何文件或内核参数"
        return 0
    fi
    confirm_or_exit

    local ct_was_loaded=0
    [ -d /sys/module/nf_conntrack ] && ct_was_loaded=1
    snapshot_sysctl
    snapshot_files
    write_rollback_script
    load_tuning_modules
    apply_conntrack_buckets "$ct_buckets"
    persist_modules
    snapshot_sysctl
    if [ "$ct_was_loaded" -eq 0 ] && [ -f "$PREV_FILE" ]; then
        sed -i '/^net\.netfilter\.nf_conntrack_buckets = /d' "$PREV_FILE" 2>/dev/null || true
    fi

    if [ "$cc" = bbr ]; then
        if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
            echo "[WARN] 设置 BBR 失败，回退为 cubic" >&2
            cc=cubic; qdisc=""
        elif [ -n "$qdisc" ]; then
            sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || qdisc=""
        fi
    fi
    [ -n "$qdisc" ] && apply_fq_now

    render_sysctl > "$SYSCTL_FILE"
    apply_sysctl_file
    write_limits
    write_rc_ulimit
    write_journald
    write_systemd_nofile

    if [ "$OS_KIND" = alpine ] && command -v rc-update >/dev/null 2>&1; then
        rc-update add sysctl boot >/dev/null 2>&1 || true
        rc-update add modules boot >/dev/null 2>&1 || true
    fi

    echo "[INFO] 完成 ✔ 内存: $mem_show | BBR: $cc | conntrack: $conntrack_max | $CT_NOTE"
    [ "$BBR_MISSING" -eq 1 ] && echo "[INFO] 内核未提供 tcp_bbr，拥塞控制保持 cubic"
    [ "$OS_KIND" = alpine ] && echo "[INFO] OpenRC 服务需重启后使用新 nofile"
    [ "$OS_KIND" = debian ] && echo "[INFO] systemd 服务的 nofile 在重启后生效；已在跑的服务需各自重启"
    echo "[INFO] 回滚: sh $ROLLBACK_SH"
}

show_plan() {
    local tmp; tmp=$(mktemp) || return 0
    render_sysctl > "$tmp"
    echo "[PLAN] 系统: $OS_KIND | 内存: $mem_show | 拥塞控制: $cc$( [ -n "$qdisc" ] && echo ' + fq')"
    echo "[PLAN] nofile: $nofile | conntrack_max: $conntrack_max | buckets 目标: $ct_buckets"
    echo "[POLICY] 将打开 IPv4/IPv6 转发，并把 accept_ra 设为 2"
    echo "[POLICY] conntrack：TCP established 超时 600 秒，UDP stream 超时 60 秒"
    echo "[POLICY] swappiness 将设为 1"
    if [ "$BBR_MISSING" -eq 1 ]; then
        echo "[POLICY] 内核未提供 tcp_bbr，拥塞控制将保持 cubic"
    elif [ -z "$qdisc" ]; then
        echo "[POLICY] 有 BBR，但没有 sch_fq，不做 fq pacing"
    elif command -v tc >/dev/null 2>&1; then
        echo "[POLICY] 物理网卡的 root qdisc 将替换为 fq"
    else
        echo "[POLICY] 将设置 default_qdisc=fq；无 tc，现有网卡 qdisc 不会被改动"
    fi
    [ "$memory_mb" -lt 1024 ] && echo "[WARN] 内存低于 1G，动态项会落在下限，且 swappiness=1，连接数上来时更容易 OOM"
    echo "[PLAN] nf_conntrack 若能加载，将写入开机模块列表，供重启后 sysctl 套用"
    echo "[PLAN] 以下 sysctl 将发生变化:"
    local line key val cur changed=0
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        key=${line%%=*}; key=${key// /}
        val=${line#*=}; val=${val# }
        cur=$(normalize_ws "$(sysctl_get "$key")")
        val=$(normalize_ws "$val")
        if [ "$cur" != "$val" ]; then
            printf '  %-56s %s -> %s\n' "$key" "$cur" "$val"
            changed=$((changed + 1))
        fi
    done < "$tmp"
    [ "$changed" -eq 0 ] && echo "  （无变化）"
    rm -f "$tmp"
    echo "[PLAN] 将写入: $SYSCTL_FILE, $LIMITS_FILE, $MODULES_FILE"
    if [ "${CT_SYSCTL_WRITABLE:-0}" -eq 0 ]; then
        echo "[PLAN] 将写入: $MODPROBE_FILE"
    elif [ -f "$MODPROBE_FILE" ]; then
        echo "[PLAN] 将删除: $MODPROBE_FILE（buckets 改由 sysctl 持久化）"
    fi
    if [ "$OS_KIND" = debian ]; then
        echo "[PLAN] 将写入: $JOURNAL_FILE, $SYSTEMD_NOFILE_FILE"
    else
        echo "[PLAN] 将写入: $PROFILE_FILE, /etc/rc.conf（rc_ulimit）"
        [ -f /etc/modules ] && echo "[PLAN] 将写入: /etc/modules"
    fi
}

confirm_or_exit() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    local a
    printf '确认应用以上调优? [y/N] ' >&2
    if [ -t 0 ]; then
        IFS= read -r a
    elif [ -r /dev/tty ]; then
        IFS= read -r a < /dev/tty
    else
        a=n
    fi
    case "$a" in
        [yY]*) return 0 ;;
        *) echo "[INFO] 已取消，未做任何修改" >&2; exit 0 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]}" ]; then
    DRY_RUN=0 ASSUME_YES=0
    while [ $# -gt 0 ]; do
        case "$1" in
            rollback) do_rollback; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -y|--yes) ASSUME_YES=1 ;;
            *) echo "[ERROR] 未知参数: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
    main
fi
