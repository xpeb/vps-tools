#!/bin/sh
# xray 管理面板
# 文档: https://xtls.github.io/
# 系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
# 入站: Shadowsocks、VLESS REALITY、Hysteria2
# 内核以 xray 用户运行
#
# 用法: sudo ./xray.sh

set -eu

if ! command -v bash >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "需要 bash。请用 root 运行，或先安装 bash。" >&2
    exit 1
  fi
  if [ -f /etc/alpine-release ]; then
    apk add -q --no-cache bash >/dev/null 2>&1
  elif [ -f /etc/debian_version ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq -y >/dev/null 2>&1
    apt-get install -qq -y --no-install-recommends bash >/dev/null 2>&1
  else
    echo "仅支持 Debian 与 Alpine。" >&2
    exit 1
  fi
fi

# 输出走独立 fd，避免 heredoc 被 read 读走。
exec bash /dev/fd/3 "$@" 3<<'XRAY_PANEL_PAYLOAD'
set -uo pipefail
set +H
set +o history
umask 077
shopt -s nullglob

# 程序、配置、证书和日志都在 STATE_DIR。服务单元仍由 systemd / OpenRC 从 /etc 加载。
STATE_DIR=/var/lib/xray
BIN=$STATE_DIR/bin/xray
CMD_LINK=/usr/local/bin/xray
CONF_DIR=$STATE_DIR/etc
CONF=$CONF_DIR/config.json
LOG_DIR=$STATE_DIR/log
META_DIR=$STATE_DIR/meta
CERT_DIR=$STATE_DIR/certs
STDOUT_LOG=$LOG_DIR/stdout.log
STDERR_LOG=$LOG_DIR/stderr.log
LOCK_FILE=/run/lock/xray.lock
PID_FILE=/run/xray.pid
OPENRC_DIR=${RC_SVCDIR:-/run/openrc}
SERVICE_FILE=/etc/systemd/system/xray.service
ROTATE_FILE=/etc/logrotate.d/xray
REPO=XTLS/Xray-core

GRN=$'\033[38;2;126;217;167m'
RED=$'\033[38;2;255;107;107m'
YEL=$'\033[38;2;240;200;120m'
DIM=$'\033[38;2;145;155;170m'
ACC=$'\033[38;2;116;180;255m'
RST=$'\033[0m'
BOLD=$'\033[1m'

OS=""
TX=""
LOCKED=0
ACTION_LOCK=0
TX_WAS=0
CONFLICT_TAG=""
PICKED=""
TMP_PATHS=()
RULE=""

ui() { printf '%b' "$1" >&4; }
uin() { printf '%b\n' "$1" >&4; }
plainln() { printf '%s\n' "$1" >&4; }
err() { printf '  %b%s%b\n' "$RED" "$1" "$GRN" >&4; }
warn() { printf '  %b%s%b\n' "$YEL" "$1" "$GRN" >&4; }
note() { printf '  %b%s%b\n' "$DIM" "$1" "$GRN" >&4; }
kv() { printf '  %s%s\n' "$(pad "$1" 8)" "$2" >&4; }
share_addr() {
  printf '  %s%b%s%b\n' "$(pad "$1" 8)" "$ACC" "$(uri_host "$2")" "$RST" >&4
}
item() { printf '  %b%s%b%s\n' "$ACC" "$(pad "$1" "$MENU_NUM_W")" "$RST" "$2" >&4; }
blank() { uin ""; }

cleanup() {
  local rc=$? p
  trap - EXIT INT TERM HUP
  if [[ -n $TX ]]; then
    rollback_tx || { rc=1; err "恢复未完成，快照保留在 ${TX}，请勿删除。"; }
  fi
  ACTION_LOCK=0
  release_lock
  if ((${#TMP_PATHS[@]})); then
    for p in "${TMP_PATHS[@]}"; do
      if [[ -n $p && -e $p ]]; then
        rm -rf -- "$p"
      fi
    done
  fi
  printf '%b' "$RST" >&4 2>/dev/null || true
  return "$rc"
}

MENU_NUM_W=4
MENU_LABEL_W=18
PANEL_KERNEL=("1 安装内核 2 升级内核" "3 启动服务 4 停止服务")
PANEL_INBOUND=("6 添加入站 7 修改入站" "8 分享链接 9 删除入站")
PANEL_DIAG=("10 查看日志 q 退出面板")

menu_row_width() {
  dw "$(pad "$1" "$MENU_NUM_W")$(pad "$2" "$MENU_LABEL_W")  $(pad "$3" "$MENU_NUM_W")$4"
}

# 分隔线与主菜单最宽的一行对齐。
menu_rule() {
  local max=0 w spec n1 l1 n2 l2
  for spec in "$@"; do
    read -r n1 l1 n2 l2 <<<"$spec"
    w=$(menu_row_width "$n1" "$l1" "$n2" "$l2")
    ((w > max)) && max=$w
  done
  printf '%*s' "$max" '' | tr ' ' '-'
}

init_ui() {
  if [[ -n ${NO_COLOR:-} || ${TERM:-dumb} == dumb ]]; then
    GRN='' RED='' YEL='' DIM='' ACC='' RST='' BOLD=''
  fi
  RULE=$(menu_rule "${PANEL_KERNEL[@]}" "${PANEL_INBOUND[@]}" "${PANEL_DIAG[@]}")
}

dw() {
  local s=$1 i w=0 cp
  for ((i = 0; i < ${#s}; i++)); do
    printf -v cp '%d' "'${s:i:1}"
    if ((cp < 32 || (cp >= 0x7F && cp < 0xA0) || (cp >= 0x300 && cp <= 0x36F))); then
      continue
    elif (( (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0xA4CF) \
         || (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) \
         || (cp >= 0xFE10 && cp <= 0xFE6F) || (cp >= 0xFF00 && cp <= 0xFF60) \
         || (cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x1F300 && cp <= 0x1FAFF) \
         || (cp >= 0x20000 && cp <= 0x3FFFD) )); then
      w=$((w + 2))
    else
      w=$((w + 1))
    fi
  done
  printf '%s' "$w"
}

pad() {
  local s=$1 width=$2 w
  w=$(dw "$s")
  printf '%s' "$s"
  ((w >= width)) || printf '%*s' "$((width - w))" ''
}

cls() {
  [[ ${TERM:-dumb} == dumb ]] || ui $'\033[H\033[2J'
  ui "$RST"
}

header() {
  cls
  blank
  printf '  %bXRAY%b  /  %s\n' "$ACC$BOLD" "$RST" "$1" >&4
  uin "  ${DIM}${RULE}${RST}"
  blank
}

pause() {
  blank
  ui "  ${DIM}回车继续${RST}${GRN}"
  IFS= read -r _ </dev/tty || true
  ui $'\n'
}

# 一次拆开多行输出，避免反复调用 sed。
read_fields() {
  local data=$1 name i=0
  local -a values=()
  shift
  mapfile -t values <<<"$data"
  for name in "$@"; do
    printf -v "$name" '%s' "${values[i]:-}"
    i=$((i + 1))
  done
}

trim_line() {
  local s=$1
  s=${s//$'\r'/}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

tty_read() {
  local -n _out=$1
  local _prompt=$2 _ans
  if ! IFS= read -r -e -p "$_prompt" _ans </dev/tty 2>&4; then
    ui $'\n'
    return 2
  fi
  _out=$(trim_line "$_ans")
}

prompt() {
  local msg=$1 default=${2:-} hint=${3:-} ans p=""
  p=$(printf '\001%s\002  %s' "$GRN" "$msg")
  if [[ -n $default ]]; then
    p+=$(printf ' \001%s\002%s\001%s\002' "$DIM" "$default" "$GRN")
  fi
  if [[ -n $hint ]]; then
    p+=$(printf ' \001%s\002%s\001%s\002' "$DIM" "$hint" "$GRN")
  fi
  p+=$(printf ': ')
  tty_read ans "$p" || return 2
  if [[ -z $ans ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$ans"
  fi
}

confirm() {
  local ans p
  p=$(printf '\001%s\002  %s \001%s\002y/N\001%s\002: ' "$GRN" "$1" "$DIM" "$GRN")
  tty_read ans "$p" || return 1
  [[ $ans == y || $ans == Y || $ans == yes || $ans == YES ]]
}

cancelled() {
  [[ ${1:-} == q || ${1:-} == Q ]]
}

is_regen() {
  [[ ${1:-} == g || ${1:-} == G ]]
}

detect_os() {
  if [[ $(uname -s) != Linux ]]; then
    echo "仅支持 Linux。" >&2
    return 1
  fi
  if [[ -f /etc/alpine-release ]]; then
    OS=alpine
  elif [[ -f /etc/debian_version ]]; then
    OS=debian
  else
    echo "仅支持 Debian 与 Alpine。" >&2
    return 1
  fi
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
}

asset_arch() {
  local machine
  case $(uname -m) in
    i386 | i686) machine=32 ;;
    amd64 | x86_64) machine=64 ;;
    armv5tel) machine=arm32-v5 ;;
    armv6l)
      machine=arm32-v6
      grep -q ' vfp' /proc/cpuinfo 2>/dev/null || machine=arm32-v5
      ;;
    armv7 | armv7l)
      machine=arm32-v7a
      grep -q ' vfp' /proc/cpuinfo 2>/dev/null || machine=arm32-v5
      ;;
    armv8 | aarch64) machine=arm64-v8a ;;
    mips) machine=mips32 ;;
    mipsle) machine=mips32le ;;
    mips64)
      machine=mips64
      if lscpu 2>/dev/null | grep -q 'Little Endian'; then
        machine=mips64le
      fi
      ;;
    mips64le) machine=mips64le ;;
    ppc64) machine=ppc64 ;;
    ppc64le) machine=ppc64le ;;
    riscv64) machine=riscv64 ;;
    s390x) machine=s390x ;;
    loongarch64) machine=loong64 ;;
    *)
      err "不支持的架构: $(uname -m)"
      return 1
      ;;
  esac
  printf '%s' "$machine"
}

ensure_deps() {
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v unzip >/dev/null 2>&1 || pkgs+=(unzip)
  command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  command -v sha256sum >/dev/null 2>&1 || pkgs+=(coreutils)
  command -v logrotate >/dev/null 2>&1 || pkgs+=(logrotate)
  if ! command -v flock >/dev/null 2>&1; then
    if [[ $OS == alpine ]]; then pkgs+=(util-linux-misc); else pkgs+=(util-linux); fi
  fi
  if ! command -v su >/dev/null 2>&1; then
    if [[ $OS == alpine ]]; then pkgs+=(shadow); else pkgs+=(util-linux); fi
  fi
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || pkgs+=(ca-certificates)
  if ((${#pkgs[@]} == 0)); then
    return 0
  fi
  plainln "  安装依赖: ${pkgs[*]}"
  if [[ $OS == alpine ]]; then
    apk add -q --no-cache "${pkgs[@]}" ca-certificates >/dev/null 2>&1
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq -y >/dev/null 2>&1 || return 1
    apt-get install -qq -y --no-install-recommends "${pkgs[@]}" ca-certificates >/dev/null 2>&1
  fi
}

box_group_ok() {
  local primary listed
  if ! getent group xray >/dev/null 2>&1; then
    return 1
  fi
  primary=$(id -gn xray 2>/dev/null || true)
  if [[ $primary == xray ]]; then
    return 0
  fi
  listed=$(id -nG xray 2>/dev/null || true)
  [[ " ${listed} " == *" xray "* ]]
}

create_box_user() {
  install -d -m 755 -o root -g root /var/empty || return 1
  if id -u xray >/dev/null 2>&1; then
    if [[ $(id -u xray) -eq 0 || $(id -g xray) -eq 0 ]]; then
      err "已有的 xray 账户不能是 root。"
      return 1
    fi
    if ! box_group_ok; then
      err "已有的 xray 账户必须属于 xray 组。"
      return 1
    fi
    warn "已有 xray 用户，继续使用。"
    return 0
  fi
  plainln "  创建 xray 用户"
  # systemd-sysusers 的提示在 stderr；装了 systemd 的 Alpine 也走这里。
  if command -v systemd-sysusers >/dev/null 2>&1; then
    systemd-sysusers - >/dev/null 2>&1 <<'EOF' || true
u xray - "xray" /var/empty
EOF
  elif [[ $OS == alpine ]]; then
    if ! grep -q '^xray:' /etc/group 2>/dev/null; then
      addgroup -S xray >/dev/null 2>&1 || return 1
    fi
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G xray -g "xray" xray >/dev/null 2>&1 || true
  else
    if ! getent group xray >/dev/null 2>&1; then
      groupadd --system xray >/dev/null 2>&1 || return 1
    fi
    useradd --system --gid xray --home-dir /var/empty --shell /usr/sbin/nologin --comment "xray" xray >/dev/null 2>&1 || true
  fi
  if ! id -u xray >/dev/null 2>&1; then
    err "无法创建 xray 用户。"
    return 1
  fi
  if [[ $(id -u xray) -eq 0 || $(id -g xray) -eq 0 ]] || ! box_group_ok; then
    err "xray 账户身份或组不正确。"
    return 1
  fi
}

ensure_dirs() {
  local f
  for f in "$CONF_DIR" "$LOG_DIR" "$STATE_DIR" "$META_DIR" "$CERT_DIR" "$CONF"; do
    [[ ! -L $f ]] || { err "拒绝使用符号链接: $f"; return 1; }
  done
  install -d -m 750 -o root -g xray "$STATE_DIR" || return 1
  install -d -m 755 -o root -g root "${BIN%/*}" || return 1
  install -d -m 750 -o root -g xray "$CONF_DIR" "$LOG_DIR" "$CERT_DIR" || return 1
  install -d -m 700 -o root -g root "$META_DIR" || return 1
  for f in "$STDOUT_LOG" "$STDERR_LOG"; do
    [[ ! -L $f ]] || return 1
    if [[ ! -e $f ]]; then
      install -m 600 -o xray -g xray /dev/null "$f" || return 1
    fi
  done
  repair_conf_access
}

atomic_json() {
  local dest=$1 mode=$2 owner=$3 group=$4 dir tmp
  dir=$(dirname "$dest")
  [[ -d $dir ]] || return 1
  tmp=$(mktemp -p "$dir") || return 1
  if ! cat >"$tmp" || [[ ! -s $tmp ]] || ! jq -e . >/dev/null <"$tmp" \
    || ! chown "${owner}:${group}" "$tmp" || ! chmod "$mode" "$tmp" \
    || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

atomic_text() {
  local dest=$1 tmp
  tmp=$(mktemp "${dest}.XXXXXX") || return 1
  if ! cat >"$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

empty_config() {
  jq -n '{log:{loglevel:"warning"},inbounds:[],outbounds:[{protocol:"freedom",tag:"direct"}]}'
}

ensure_base_config() {
  if [[ -f $CONF ]]; then
    return 0
  fi
  empty_config | atomic_json "$CONF" 640 root xray
}

set_mode() {
  [[ -e $3 && ! -L $3 ]] || return 0
  chown "$1" "$3" && chmod "$2" "$3"
}

fix_tree_perms() {
  local f
  set_mode root:xray 640 "$CONF" || return 1
  set_mode root:xray 750 "$CONF_DIR" || return 1
  set_mode root:xray 750 "$STATE_DIR" || return 1
  set_mode root:root 755 "${BIN%/*}" || return 1
  set_mode root:xray 750 "$LOG_DIR" || return 1
  set_mode root:root 700 "$META_DIR" || return 1
  for f in "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    [[ ! -L $f ]] || return 1
    set_mode root:root 600 "$f" || return 1
  done
  set_mode root:xray 750 "$CERT_DIR" || return 1
  for f in "$CERT_DIR"/*; do
    [[ -f $f && ! -L $f ]] || continue
    set_mode root:xray 640 "$f" || return 1
  done
  repair_conf_access
}

# umask 077 时新建父目录会变成 0700。
open_parent_dirs() {
  local dir=${1%/*} i
  local -a parents=()
  while [[ -n $dir && $dir != / && $dir != . ]]; do
    parents=("$dir" "${parents[@]}")
    dir=${dir%/*}
  done
  # 从外向内修，避免外层放开后内层仍是 0700。
  for ((i = 0; i < ${#parents[@]}; i++)); do
    dir=${parents[i]}
    # 安装根目录靠组权限进入，再加 other 执行位会变成 751。
    [[ $dir == "$STATE_DIR" || $dir == "$STATE_DIR"/* ]] && continue
    if [[ -d $dir && ! -L $dir && $(stat -c '%u' "$dir") == 0 ]]; then
      chmod o+x "$dir" || return 1
    fi
  done
}

repair_conf_access() {
  [[ -d $CONF_DIR ]] || return 0
  open_parent_dirs "$CONF_DIR" && open_parent_dirs "$LOG_DIR" || return 1
  if ! id -u xray >/dev/null 2>&1 || ! command -v su >/dev/null 2>&1; then
    return 0
  fi
  if su -s /bin/bash -c "test -x $(printf '%q' "$CONF_DIR") && test -r $(printf '%q' "$CONF_DIR")" xray; then
    return 0
  fi
  chown root:xray "$CONF_DIR" && chmod 750 "$CONF_DIR" || return 1
  su -s /bin/bash -c "test -x $(printf '%q' "$CONF_DIR") && test -r $(printf '%q' "$CONF_DIR")" xray
}

gc_certs() {
  local f base
  for f in "$CERT_DIR"/hy2-*.crt "$CERT_DIR"/hy2-*.key; do
    [[ -f $f ]] || continue
    base=${f##*/}
    base=${base%.*}
    if [[ ! -f $META_DIR/${base}.json ]] \
      && ! jq -e --arg f "$f" '.. | objects | select(.certificateFile? == $f or .keyFile? == $f)' "$CONF" >/dev/null 2>&1; then
      rm -f -- "$f" || return 1
    fi
  done
}

restore_tree() {
  local live=$1 snap=$2 f rel
  [[ -d $snap ]] || return 0
  if [[ ! -d $live ]]; then
    mkdir -p -- "$live" || return 1
  fi
  while IFS= read -r -d '' f; do
    rel=${f#"$live"/}
    if [[ ! -e $snap/$rel && ! -L $snap/$rel ]]; then
      rm -rf -- "$f" || return 1
    fi
  done < <(find "$live" -mindepth 1 -depth -print0)
  cp -a "$snap"/. "$live"/
}

acquire_lock() {
  ((LOCKED)) && return 0
  command -v flock >/dev/null 2>&1 || { err "缺少 flock，无法安全修改。"; return 1; }
  [[ -d ${LOCK_FILE%/*} ]] || { err "锁目录不存在。"; return 1; }
  [[ ! -L $LOCK_FILE ]] || { err "锁文件不能是符号链接。"; return 1; }
  # 锁文件必须保留，避免并发进程锁住不同的 inode。
  exec 9>"$LOCK_FILE" || return 1
  if ! flock -n 9; then
    exec 9>&-
    err "另一个面板正在操作，请稍后重试。"
    return 1
  fi
  LOCKED=1
}

release_lock() {
  ((ACTION_LOCK == 0)) || return 0
  if ((LOCKED)); then
    flock -u 9 || true
    exec 9>&-
    LOCKED=0
  fi
}

# 快照只存在于本次操作的临时目录，提交或回滚后删除。
snapshot_path() {
  local live=$1 name=$2
  [[ ! -L $live ]] || { err "拒绝修改符号链接: $live"; return 1; }
  if [[ -e $live ]]; then
    cp -a -- "$live" "$TX/$name" || return 1
  else
    : >"$TX/$name.absent"
  fi
}

restore_path() {
  local live=$1 name=$2 tmp
  if [[ -f $TX/$name.absent ]]; then
    rm -rf -- "$live"
  elif [[ -d $TX/$name ]]; then
    [[ ! -L $live ]] || return 1
    restore_tree "$live" "$TX/$name"
  elif [[ -f $TX/$name ]]; then
    mkdir -p -- "$(dirname "$live")" || return 1
    tmp=$(mktemp "${live}.restore.XXXXXX") || return 1
    if ! cp -a -- "$TX/$name" "$tmp" || ! mv -f -- "$tmp" "$live"; then
      rm -f -- "$tmp"
      return 1
    fi
  else
    return 1
  fi
}

begin_tx() {
  local full=${1:-0}
  [[ -z $TX ]] || { err "存在未完成的事务，请先恢复。"; return 1; }
  acquire_lock || return 1
  TX=$(mktemp -d) || { release_lock; return 1; }
  TX_WAS=0
  is_running && TX_WAS=1
  local item ok=1
  for item in "conf:$CONF_DIR" "meta:$META_DIR" "certs:$CERT_DIR" "service:$SERVICE_FILE" "logrotate:$ROTATE_FILE"; do
    snapshot_path "${item#*:}" "${item%%:*}" || { ok=0; break; }
  done
  if ((ok == 0)) || { [[ $full == 1 ]] && ! snapshot_path "$BIN" binary; }; then
    rm -rf -- "$TX"
    TX=''
    release_lock
    return 1
  fi
  if service_enabled; then : >"$TX/enabled"; fi
  printf '%s\n' "$TX_WAS" >"$TX/was" || { end_tx; return 1; }
}

end_tx() {
  local saved=$TX
  TX='' TX_WAS=0
  if [[ -n $saved ]]; then
    rm -rf -- "$saved" || warn "事务已结束，但临时快照尚未删除。"
  fi
  release_lock
}

mark_service_change() { : >"$TX/service-changed"; }
mark_restart() { : >"$TX/restarted"; }

rollback_tx() {
  [[ -n $TX ]] || return 0
  if [[ ! -d $TX ]]; then
    end_tx
    return $?
  fi
  local failed=0
  # 先停掉本次启动的服务，再恢复文件。
  if [[ -f $TX/restarted ]]; then
    svc stop || { is_running && failed=1; }
  fi
  local item
  for item in "conf:$CONF_DIR" "meta:$META_DIR" "certs:$CERT_DIR"; do
    restore_path "${item#*:}" "${item%%:*}" || failed=1
  done
  if [[ -e $TX/binary || -e $TX/binary.absent ]]; then
    restore_path "$BIN" binary || failed=1
  fi
  if [[ -f $TX/command-created ]]; then
    unlink_command || failed=1
  fi
  if [[ -f $TX/service-changed ]]; then
    if [[ ! -f $TX/enabled ]] && service_enabled; then
      set_service_enabled 0 || failed=1
    fi
    restore_path "$SERVICE_FILE" service || failed=1
    restore_path "$ROTATE_FILE" logrotate || failed=1
    if [[ $OS == debian ]]; then systemctl daemon-reload || failed=1; fi
    if [[ -f $TX/enabled ]]; then set_service_enabled 1 || failed=1; fi
  fi
  if [[ -f $TX/restarted && $(<"$TX/was") == 1 ]]; then
    kernel_stays_up restart || failed=1
  fi
  if ((failed)); then
    err "回滚未完成，快照保留在 ${TX}。请勿继续修改。"
    return 1
  fi
  end_tx
}

box_as_user() {
  local bin=$1 log=$2 conf=$3 cmd
  if ! id -u xray >/dev/null 2>&1 || ! command -v su >/dev/null 2>&1; then
    printf '%s\n' '缺少 xray 用户或 su，拒绝以 root 代替校验。' >"$log"
    return 1
  fi
  cmd=$(printf '%q run -c %q -test' "$bin" "$conf")
  su -s /bin/bash -c "$cmd" xray >"$log" 2>&1
}

box_test() {
  local log
  log=$(mktemp) || return 1
  TMP_PATHS+=("$log")
  if [[ ! -x $BIN ]]; then
    err "未找到 xray，无法校验配置。"
    return 1
  fi
  if [[ ! -f $CONF ]]; then
    err "配置文件不存在。"
    return 1
  fi
  if box_as_user "$BIN" "$log" "$CONF"; then
    return 0
  fi
  err "配置校验失败:"
  cat "$log" >&4 || true
  ui "$GRN"
  return 1
}

running_pid() {
  local pid='' procs supervisor='' stat rest state ppid exe
  [[ -x $BIN ]] || return 1
  if [[ $OS == alpine ]]; then
    # pidfile 属于监督进程；OpenRC 单独记录实际子进程，内容可能没有换行。
    [[ -r $PID_FILE && -r $OPENRC_DIR/options/xray/child_pid ]] || return 1
    supervisor=$(<"$PID_FILE")
    pid=$(<"$OPENRC_DIR/options/xray/child_pid")
    [[ $supervisor =~ ^[0-9]+$ ]] && ((supervisor > 1)) || return 1
    kill -0 "$supervisor" 2>/dev/null || return 1
  else
    for procs in \
      /sys/fs/cgroup/system.slice/xray.service/cgroup.procs \
      /sys/fs/cgroup/systemd/system.slice/xray.service/cgroup.procs
    do
      [[ -f $procs ]] || continue
      IFS= read -r pid <"$procs" || return 1
      break
    done
    if [[ -z $pid ]]; then
      command -v systemctl >/dev/null 2>&1 || return 1
      pid=$(systemctl show --property=MainPID --value xray 2>/dev/null) || return 1
    fi
  fi
  [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1)) || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  IFS= read -r stat 2>/dev/null <"/proc/$pid/stat" || return 1
  rest=${stat##*) }
  read -r state ppid _ <<<"$rest"
  [[ $state != Z && $state != X ]] || return 1
  [[ -z $supervisor || $ppid == "$supervisor" ]] || return 1
  if [[ ! /proc/$pid/exe -ef $BIN ]]; then
    # 原子升级后，尚未重启的进程仍引用旧程序。
    exe=$(readlink -- "/proc/$pid/exe" 2>/dev/null) || return 1
    [[ $exe == "$BIN (deleted)" ]] || return 1
  fi
  printf '%s' "$pid"
}

is_running() { running_pid >/dev/null; }

service_installed() { [[ -f $SERVICE_FILE ]]; }

service_uses_panel_conf() {
  service_installed && grep -qF -- "run -c $CONF" "$SERVICE_FILE"
}

service_enabled() {
  if [[ $OS == alpine ]]; then
    [[ -L /etc/runlevels/default/xray ]]
  else
    systemctl is-enabled --quiet xray 2>/dev/null
  fi
}

set_service_enabled() {
  if [[ $OS == alpine ]]; then
    if [[ $1 == 1 ]]; then
      rc-update add xray default
    elif [[ -L /etc/runlevels/default/xray ]]; then
      rc-update del xray default
    else
      return 0
    fi
  else
    if [[ $1 == 1 ]]; then systemctl enable xray; else systemctl disable xray; fi
  fi >/dev/null 2>&1
}

drop_file_caps() {
  local bin=$1
  [[ -f $bin ]] || return 0
  if command -v setcap >/dev/null 2>&1; then
    setcap -r "$bin" 2>/dev/null || true
  fi
}

install_service() {
  [[ -z $TX ]] || mark_service_change || return 1
  local tmp
  tmp=$(mktemp "${SERVICE_FILE}.XXXXXX") || return 1
  TMP_PATHS+=("$tmp")
  if [[ $OS == alpine ]]; then
    if ! command -v rc-service >/dev/null 2>&1; then
      apk add -q --no-cache openrc >/dev/null 2>&1 || return 1
    fi
    cat >"$tmp" <<EOF || return 1
#!/sbin/openrc-run

description="xray Service"

supervisor=supervise-daemon
command="$BIN"
command_args="run -c $CONF"
command_user="xray:xray"
pidfile="/run/\${RC_SVCNAME}.pid"
capabilities="^cap_net_bind_service"
output_log="$STDOUT_LOG"
error_log="$STDERR_LOG"
respawn_delay=2
respawn_max=10
umask=0077

depend() {
	need net
	after firewall
}
EOF
    chmod 755 "$tmp" && mv -f -- "$tmp" "$SERVICE_FILE" || return 1
  else
    if ! command -v systemctl >/dev/null 2>&1; then
      err "Debian 需要 systemd。"
      return 1
    fi
    cat >"$tmp" <<EOF || return 1
[Unit]
Description=xray Service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
UMask=0077
ExecStart=$BIN run -c $CONF
StandardOutput=append:$STDOUT_LOG
StandardError=append:$STDERR_LOG
Restart=on-failure
RestartSec=2s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$tmp" && mv -f -- "$tmp" "$SERVICE_FILE" || return 1
    systemctl daemon-reload || return 1
  fi
  install_logrotate || return 1
  set_service_enabled 1 || return 1
  drop_file_caps "$BIN"
}

svc() {
  if [[ $OS == alpine ]]; then
    rc-service xray "$1" 9>&-
  else
    # 清掉上一轮限流，否则连续修改后无法再启动。
    if [[ $1 == start || $1 == restart ]]; then
      systemctl reset-failed xray >/dev/null 2>&1 || true
    fi
    systemctl "$1" xray 9>&-
  fi
}

kernel_stays_up() {
  local i pid previous='' stable=0
  svc "$1" || return 1
  # 最多等待 5 秒，要求同一个实际进程连续存活 1 秒。
  for ((i = 0; i < 50; i++)); do
    pid=$(running_pid) || pid=''
    if [[ -n $pid && $pid == "$previous" ]]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    previous=$pid
    ((stable >= 10)) && return 0
    sleep 0.1
  done
  return 1
}

show_service_log() {
  if [[ $OS == debian ]] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u xray -n 40 --no-pager >&4 || true
  fi
  if [[ -f $STDERR_LOG && -s $STDERR_LOG ]]; then
    plainln "  --- stderr ---"
    tail -n 40 "$STDERR_LOG" >&4 || true
  fi
  ui "$GRN"
}

commit_tx() {
  if ! fix_tree_perms || ! box_test; then
    rollback_tx
    err "校验失败，已尝试回滚本次修改。"
    return 1
  fi
  if ! service_uses_panel_conf; then
    plainln "  正在更新服务..."
    if ! install_service; then
      rollback_tx
      err "无法更新服务文件，已尝试回滚。"
      return 1
    fi
  fi
  if [[ $TX_WAS == 1 ]]; then
    mark_restart || { rollback_tx; return 1; }
    if ! kernel_stays_up restart; then
      rollback_tx
      err "重启失败，已尝试回滚。"
      show_service_log
      return 1
    fi
    plainln "  配置已生效，服务已重启。"
  else
    plainln "  配置已保存，服务未启动。主菜单选 3。"
  fi
  end_tx
}

current_version() {
  local raw
  if [[ -n ${VERSION_CACHE:-} ]]; then
    printf '%s' "$VERSION_CACHE"
    return
  fi
  if [[ ! -x $BIN ]]; then
    printf '%s' '-'
    return
  fi
  raw=$("$BIN" version 2>/dev/null | awk 'NR==1 {print $2}') || true
  raw=${raw#v}
  raw=${raw%%[^0-9.]*}
  if [[ -z $raw ]]; then
    printf '%s' '-'
    return
  fi
  VERSION_CACHE="v${raw}"
  printf '%s' "$VERSION_CACHE"
}

ver_cmp() {
  local a=${1#v} b=${2#v}
  local -a aa bb
  local IFS=. i n x y
  read -r -a aa <<<"$a"
  read -r -a bb <<<"$b"
  n=${#aa[@]}
  ((${#bb[@]} > n)) && n=${#bb[@]}
  for ((i = 0; i < n; i++)); do
    x=${aa[i]:-0}
    y=${bb[i]:-0}
    x=${x//[^0-9]/}
    y=${y//[^0-9]/}
    [[ -z $x ]] && x=0
    [[ -z $y ]] && y=0
    if ((10#$x > 10#$y)); then
      printf '1'
      return
    fi
    if ((10#$x < 10#$y)); then
      printf '%s' '-1'
      return
    fi
  done
  printf '0'
}

latest_version() {
  local url tag
  url=$(curl -fsSL --connect-timeout 10 --max-time 60 -o /dev/null -w '%{url_effective}' --retry 3 --retry-delay 2 \
    "https://github.com/${REPO}/releases/latest") || return 1
  tag=${url##*/}
  if [[ ! $tag =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]]; then
    return 1
  fi
  printf 'v%s' "${tag#v}"
}

count_inbounds() {
  local n=0 f
  for f in "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

kernel_state() {
  if [[ ! -x $BIN ]]; then
    printf '未安装'
  elif is_running; then
    printf '运行中'
  else
    printf '未运行'
  fi
}

status_text() {
  local color=$RED
  case $1 in
    运行中) color=$GRN ;;
    未运行) color=$YEL ;;
  esac
  printf '%b● %s%b  |  %s  |  面板入站 %s' "$color" "$1" "$RST" "$2" "$3"
}

menu_row() {
  local n1=$1 l1=$2 n2=$3 l2=$4
  printf '  %b%s%b%s  %b%s%b%s\n' \
    "$ACC" "$(pad "$n1" "$MENU_NUM_W")" "$RST" "$(pad "$l1" "$MENU_LABEL_W")" \
    "$ACC" "$(pad "$n2" "$MENU_NUM_W")" "$RST" "$l2" >&4
}

print_menu_rows() {
  local spec n1 l1 n2 l2
  for spec in "$@"; do
    read -r n1 l1 n2 l2 <<<"$spec"
    menu_row "$n1" "$l1" "$n2" "$l2"
  done
}

draw_panel() {
  local state ver count
  state=$(kernel_state)
  ver=$(current_version)
  count=$(count_inbounds)
  cls
  blank
  uin "  ${ACC}${BOLD}XRAY${RST}  ${DIM}服务与入站管理${RST}"
  uin "  ${DIM}${RULE}${RST}"
  uin "  $(status_text "$state" "$ver" "$count")"
  uin "  ${DIM}${RULE}${RST}"
  blank
  note "01 / 内核服务"
  print_menu_rows "${PANEL_KERNEL[@]}"
  item "5" "卸载内核"
  blank
  note "02 / 入站配置"
  print_menu_rows "${PANEL_INBOUND[@]}"
  blank
  note "03 / 诊断"
  print_menu_rows "${PANEL_DIAG[@]}"
  blank
}

require_kernel() {
  if [[ ! -x $BIN ]]; then
    err "请先安装内核。"
    pause
    return 1
  fi
  return 0
}

dgst_sha256() {
  local file=$1 sum
  sum=$(awk -F '= ' 'tolower($0) ~ /256=/ {print tolower($2); exit}' "$file") || return 1
  sum=${sum//$'\r'/}
  sum=${sum// /}
  if [[ ! $sum =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  printf '%s' "$sum"
}

download_release() {
  local version=$1 dest=$2 machine url name sum actual sha_pid
  machine=$(asset_arch) || return 1
  name="Xray-linux-${machine}.zip"
  url="https://github.com/${REPO}/releases/download/${version}/${name}"
  plainln "  下载 ${url}"
  # 校验文件与压缩包同时取，避免下载后再等一次 GitHub。
  curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
    -o "$dest/xray.zip.dgst" "${url}.dgst" &
  sha_pid=$!
  if ! curl -fsSL --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 -o "$dest/xray.zip" "$url"; then
    kill "$sha_pid" 2>/dev/null || true
    wait "$sha_pid" 2>/dev/null || true
    err "下载失败，请检查网络。"
    return 1
  fi
  plainln "  校验 SHA256"
  if ! wait "$sha_pid"; then
    err "无法下载校验文件。"
    return 1
  fi
  sum=$(dgst_sha256 "$dest/xray.zip.dgst") || {
    err "无法读取 SHA256。"
    return 1
  }
  actual=$(sha256sum "$dest/xray.zip" | awk '{print tolower($1)}')
  if [[ -z $sum || $sum != "$actual" ]]; then
    err "SHA256 校验失败。"
    return 1
  fi
  plainln "  解压"
  # 只提取压缩包根目录的程序，不信任包内路径。
  mkdir -p "$dest/pack" || return 1
  if ! unzip -qq -p "$dest/xray.zip" xray >"$dest/pack/xray" || [[ ! -s $dest/pack/xray ]]; then
    err "无法从压缩包提取 xray。"
    return 1
  fi
  chmod 755 "$dest/pack/xray" || return 1
  if ! "$dest/pack/xray" version >/dev/null 2>&1; then
    err "程序无法执行，请确认架构。"
    return 1
  fi
}

place_binary() {
  local src=$1 new
  install -d -m 755 "${BIN%/*}" || return 1
  new=$(mktemp "${BIN}.XXXXXX") || return 1
  cp -- "$src" "$new" || { rm -f -- "$new"; return 1; }
  chown root:root "$new" || { rm -f -- "$new"; return 1; }
  chmod 755 "$new" || { rm -f -- "$new"; return 1; }
  drop_file_caps "$new"
  mv -f -- "$new" "$BIN" || { rm -f -- "$new"; return 1; }
  VERSION_CACHE=""
  link_command
}

# 仅给 /var/lib 下的正式安装提供命令名，测试目录不写 /usr/local/bin。
link_command() {
  local link=$CMD_LINK target
  [[ $BIN == /var/lib/* && -d ${link%/*} && ! -L ${link%/*} ]] || return 0
  if [[ -L $link ]]; then
    target=$(readlink -- "$link") || return 1
    [[ $target == "$BIN" ]] && return 0
  fi
  if [[ -e $link || -L $link ]]; then
    err "${link} 已存在且不由本面板管理，拒绝覆盖。"
    return 1
  fi
  # 只记录本次新建的链接，原有链接始终不改动。
  [[ -z $TX ]] || : >"$TX/command-created" || return 1
  ln -sT -- "$BIN" "$link"
}

unlink_command() {
  local target
  [[ -L $CMD_LINK ]] || return 0
  target=$(readlink -- "$CMD_LINK") || return 1
  [[ $target == "$BIN" ]] || return 0
  rm -f -- "$CMD_LINK"
}

install_logrotate() {
  local dir=${ROTATE_FILE%/*} tmp
  [[ ! -L $dir && ! -L $ROTATE_FILE ]] || return 1
  if [[ ! -d $dir ]]; then
    install -d -m 755 "$dir" || return 1
  fi
  tmp=$(mktemp "${ROTATE_FILE}.XXXXXX") || return 1
  TMP_PATHS+=("$tmp")
  cat >"$tmp" <<EOF || return 1
$LOG_DIR/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
  chmod 644 "$tmp" && mv -f -- "$tmp" "$ROTATE_FILE"
}

deploy_pack() {
  local src=$1
  create_box_user || return 1
  ensure_dirs || return 1
  place_binary "$src/xray" || return 1
  ensure_base_config || return 1
  rebuild_config || return 1
  fix_tree_perms || return 1
  box_test || return 1
  install_service
}

deploy_or_rollback() {
  begin_tx 1 || return 1
  if ! deploy_pack "$1"; then
    rollback_tx
    err "$2"
    return 1
  fi
}

fetch_latest_pack() {
  plainln "  获取最新版本..."
  version=$(latest_version) || { err "无法获取版本，请检查到 GitHub 的网络。"; return 1; }
  plainln "  最新版本 ${version}"
  work=$(mktemp -d) || return 1
  TMP_PATHS+=("$work")
  download_release "$version" "$work"
}

install_kernel() {
  local work version
  header "安装内核"
  if [[ -x $BIN ]]; then
    plainln "  已安装 $(current_version)，更新请选「升级内核」。"
    pause
    return 0
  fi
  fetch_latest_pack || { pause; return 0; }
  deploy_or_rollback "$work/pack" "安装失败，已尝试恢复原有文件。" || { pause; return 0; }
  end_tx || { pause; return 0; }
  blank
  plainln "  安装完成。"
  kv "版本" "$(current_version)"
  kv "程序" "$BIN"
  kv "配置" "$CONF"
  kv "日志" "$LOG_DIR"
  kv "用户" "xray"
  blank
  note "回到主菜单选 3 启动。"
  pause
}

upgrade_kernel() {
  local work version current cmp
  header "升级内核"
  require_kernel || return 0
  current=$(current_version)
  plainln "  当前版本 ${current}"
  fetch_latest_pack || { pause; return 0; }
  cmp=$(ver_cmp "$version" "$current")
  if [[ $cmp -le 0 ]]; then
    if [[ $cmp -eq 0 ]]; then
      plainln "  已是最新版本。"
    else
      warn "当前版本高于最新正式版。"
    fi
    confirm "是否仍要重新安装此版本？" || return 0
  fi
  if [[ -f $CONF ]]; then
    plainln "  正在校验现有配置..."
    chmod 755 "$work" "$work/pack" "$work/pack/xray" || { pause; return 0; }
    if ! box_as_user "$work/pack/xray" "$work/test.err" "$CONF"; then
      err "新版本无法加载当前配置，已取消升级。"
      cat "$work/test.err" >&4 || true
      ui "$GRN"
      pause
      return 0
    fi
  fi
  deploy_or_rollback "$work/pack" "升级失败，已尝试恢复原有程序、配置与服务。" || { pause; return 0; }
  if [[ $TX_WAS == 1 ]]; then
    if ! mark_restart || ! kernel_stays_up restart; then
      err "新版本没有保持运行，正在恢复。"
      show_service_log
      rollback_tx || show_service_log
      pause
      return 0
    fi
    plainln "  已升级到 $(current_version)，服务已重启。"
  else
    plainln "  已升级到 $(current_version)，服务未启动。"
  fi
  end_tx
  pause
}

start_kernel() {
  header "启动服务"
  require_kernel || return 0
  if ! service_uses_panel_conf; then
    plainln "  正在更新服务..."
    begin_tx 1 || { pause; return 0; }
    if ! create_box_user || ! ensure_dirs || ! ensure_base_config || ! install_service; then
      rollback_tx
      pause
      return 0
    fi
  fi
  local own_tx=0 changed=0 action=start
  if [[ -z $TX ]]; then
    begin_tx || { pause; return 0; }
    own_tx=1
  fi
  if ! id -u xray >/dev/null 2>&1 && ! create_box_user; then
    rollback_tx
    pause
    return 0
  fi
  if ! ensure_dirs || ! rebuild_config; then
    rollback_tx
    err "无法按当前脚本重写配置。"
    pause
    return 0
  fi
  if [[ -f $TX/conf/config.json ]] && cmp -s "$TX/conf/config.json" "$CONF"; then
    changed=0
  else
    changed=1
  fi
  if ((own_tx && changed == 0)) && is_running; then
    end_tx
    plainln "  服务已在运行。"
    pause
    return 0
  fi
  if ! box_test; then
    rollback_tx
    pause
    return 0
  fi
  mark_restart || { rollback_tx; pause; return 0; }
  if [[ $TX_WAS == 1 ]]; then
    action=restart
  fi
  if ! kernel_stays_up "$action"; then
    err "启动失败。"
    show_service_log
    rollback_tx
    pause
    return 0
  fi
  end_tx
  if ((changed)) && [[ $action == restart ]]; then
    plainln "  配置已更新，服务已重启。"
  elif ((changed)); then
    plainln "  配置已更新，服务已启动。"
  elif [[ $action == restart ]]; then
    plainln "  服务已重启。"
  else
    plainln "  服务已启动。"
  fi
  pause
}

stop_kernel() {
  header "停止服务"
  if ! is_running; then
    plainln "  服务未在运行。"
    pause
    return 0
  fi
  if ! svc stop; then
    err "停止失败。"
    pause
    return 0
  fi
  plainln "  服务已停止。"
  pause
}

remove_box_user() {
  local uid="" gid=""
  if id -u xray >/dev/null 2>&1; then
    uid=$(id -u xray) || return 1
    gid=$(id -g xray) || return 1
    if [[ $uid == 0 || $gid == 0 ]]; then
      err "拒绝删除 root 账户。"
      return 1
    fi
    if [[ $OS == alpine ]]; then deluser xray; else userdel xray; fi || return 1
  fi
  # userdel 可能已经删除同名私有组。
  if getent group xray >/dev/null 2>&1; then
    if [[ $OS == alpine ]]; then delgroup xray; else groupdel xray; fi || return 1
  fi
}

uninstall_kernel() {
  local path
  header "卸载内核"
  if [[ ! -x $BIN && ! -e $CONF_DIR && ! -e $STATE_DIR && ! -e $LOG_DIR ]] && ! service_installed; then
    plainln "  内核未安装。"
    pause
    return 0
  fi
  note "将删除内核、配置、证书、日志和用户。"
  confirm "确认卸载？" || return 0
  begin_tx 1 || { pause; return 0; }
  if ! mark_service_change || ! mark_restart; then rollback_tx; pause; return 0; fi
  if service_installed || is_running; then
    if ! svc stop || ! set_service_enabled 0; then
      err "无法停止或禁用服务，已取消卸载。"
      rollback_tx
      pause
      return 0
    fi
  fi
  for path in "$CONF_DIR" "$STATE_DIR" "$META_DIR" "$CERT_DIR" "$LOG_DIR" "${BIN%/*}"; do
    if [[ -L $path ]]; then
      err "拒绝删除符号链接: ${path}"
      rollback_tx
      pause
      return 0
    fi
  done
  # 先留着程序目录，回滚才能把程序写回去；提交后再删安装根目录。
  if ! rm -f -- "$BIN" "$SERVICE_FILE" "$ROTATE_FILE" \
    || ! rm -rf -- "$CONF_DIR" "$META_DIR" "$CERT_DIR"; then
    rollback_tx
    pause
    return 0
  fi
  if [[ $OS == debian ]] && ! systemctl daemon-reload; then
    rollback_tx
    pause
    return 0
  fi
  # 锁文件保留，由 mutate 在目录和账户清理结束后释放锁。
  end_tx || { pause; return 0; }
  rm -rf -- "$LOG_DIR" || warn "日志未完全删除。"
  rm -rf -- "$STATE_DIR" "${BIN%/*}" || warn "安装目录未完全删除。"
  unlink_command || warn "命令链接未删除。"
  remove_box_user || warn "账户或组未完全删除。"
  plainln "  卸载完成。"
  pause
}

show_file() {
  local title=$1 file=$2
  header "$title"
  if [[ ! -f $file ]]; then
    plainln "  暂无日志。"
  elif [[ ! -s $file ]]; then
    plainln "  日志为空。"
  else
    tail -n 40 -- "$file" >&4 || true
    ui "$GRN"
  fi
  pause
}

follow_log() {
  local file=$1 pid old_int
  old_int=$(trap -p INT)
  header "实时日志"
  if [[ ! -f $file ]]; then
    plainln "  暂无日志。"
    pause
    return 0
  fi
  note "Ctrl+C 返回"
  blank
  tail -n 20 -F -- "$file" >&4 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' INT
  wait "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - INT
  [[ -z $old_int ]] || eval "$old_int"
  ui "$GRN"
  ui $'\n'
}

view_logs() {
  local choice
  while true; do
    choice=$(choose "日志" "返回" "错误日志" "实时跟踪错误日志" "服务日志") || return 0
    case $choice in
      1) show_file "错误日志" "$STDERR_LOG" ;;
      2) follow_log "$STDERR_LOG" ;;
      3)
        header "服务日志"
        show_service_log
        if ! is_running && [[ ! -s $STDERR_LOG ]]; then
          plainln "  暂无服务日志。"
        fi
        pause
        ;;
    esac
  done
}

uses_tcp() {
  local proto=$1 net=$2
  if [[ $proto == hysteria2 || $proto == hysteria ]]; then
    return 1
  fi
  if [[ $net == udp || $net == hysteria || $net == quic || $net == kcp || $net == mkcp ]]; then
    return 1
  fi
  if [[ $proto == shadowsocks && -n $net && $net != *tcp* ]]; then
    return 1
  fi
  return 0
}

uses_udp() {
  local proto=$1 net=$2
  if [[ $proto == hysteria2 || $proto == hysteria || $net == hysteria || $net == quic || $net == kcp || $net == mkcp ]]; then
    return 0
  fi
  if [[ ( $proto == shadowsocks && ( -z $net || $net == *udp* ) ) \
    || ( $proto == socks && $net == *udp* ) ]]; then
    return 0
  fi
  return 1
}

wildcard_listen() {
  local listen
  listen=$(unbracket "$1")
  [[ -z $listen || $listen == null || $listen == 0.0.0.0 ]] && return 0
  is_ipv6 "$listen" && [[ ${listen//[0:]/} == "" ]]
}

listen_clash() {
  local a=$1 b=$2
  [[ $a == "$b" ]] || wildcard_listen "$a" || wildcard_listen "$b"
}

endpoint_hits() {
  local port=$1 except=$2 listen=$3 nt=$4 nu=$5 etag=$6 eproto=$7 enet=$8 ep=$9 elisten=${10}
  local ct=0 cu=0
  [[ -n $ep && $ep != null ]] || return 1
  if [[ $ep =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    ((port >= 10#${BASH_REMATCH[1]} && port <= 10#${BASH_REMATCH[2]})) || return 1
  else
    [[ $ep == "$port" ]] || return 1
  fi
  [[ -n $etag && $etag != null && $etag == "$except" ]] && return 1
  [[ -z $elisten || $elisten == null ]] && elisten=0.0.0.0
  listen_clash "$listen" "$elisten" || return 1
  uses_tcp "$eproto" "$enet" && ct=1
  uses_udp "$eproto" "$enet" && cu=1
  (( (nt && ct) || (nu && cu) )) || return 1
  if [[ -z $etag || $etag == null ]]; then
    return 2
  fi
  CONFLICT_TAG=$etag
}

port_conflict() {
  local port=$1 except=$2 proto=$3 network=$4 listen=${5:-0.0.0.0}
  local f etag ep eproto enet elisten nt=0 nu=0 rc
  CONFLICT_TAG=""
  uses_tcp "$proto" "$network" && nt=1
  uses_udp "$proto" "$network" && nu=1
  for f in "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    IFS=$'\t' read -r etag ep eproto enet elisten < <(jq -r '[.tag, (.port | tostring), .protocol, (.network // ""), (.listen // "0.0.0.0")] | @tsv' "$f")
    if endpoint_hits "$port" "$except" "$listen" "$nt" "$nu" "$etag" "$eproto" "$enet" "$ep" "$elisten"; then
      return 0
    fi
  done
  if [[ -f $CONF ]]; then
    while IFS=$'\x1f' read -r _ etag eproto enet ep elisten; do
      etag=${etag#.}
      if [[ -n $except && $etag == "$except" ]]; then
        continue
      fi
      endpoint_hits "$port" "$except" "$listen" "$nt" "$nu" "$etag" "$eproto" "$enet" "$ep" "$elisten"
      rc=$?
      if [[ $rc -eq 0 ]]; then
        return 0
      fi
      if [[ $rc -eq 2 ]]; then
        CONFLICT_TAG="config.json"
        return 0
      fi
    done < <(jq -rj '.inbounds[]? | ["x", "." + (if (.tag // "") == "" then "config.json" else .tag end), .protocol // "", (if .settings.udp == true then "tcp,udp" else (.streamSettings.method // .streamSettings.network // .settings.network // "") end), (.port | tostring), (.listen // "0.0.0.0")] | join("\u001f") + "\n"' "$CONF" 2>/dev/null || true)
  fi
  return 1
}

is_domain() {
  ((${#1} <= 253)) && [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

is_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1:4}"; do
    ((10#$o <= 255)) || return 1
  done
}

ipv6_groups() {
  local s=$1 g
  [[ -z $s ]] && return 0
  [[ $s == :* || $s == *: || $s == *::* ]] && return 1
  local IFS=:
  # shellcheck disable=SC2086
  set -- $s
  for g in "$@"; do
    [[ $g =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
  done
}

is_ipv6() {
  local ip=$1 left right lg=0 rg=0
  [[ $ip == "::" ]] && return 0
  [[ $ip =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ $ip == *::*::* ]] && return 1
  if [[ $ip == *::* ]]; then
    left=${ip%%::*}
    right=${ip#*::}
    ipv6_groups "$left" || return 1
    ipv6_groups "$right" || return 1
    [[ -n $left ]] && lg=$(awk -F: '{print NF}' <<<"$left")
    [[ -n $right ]] && rg=$(awk -F: '{print NF}' <<<"$right")
    ((lg + rg > 0 && lg + rg < 8))
  else
    ipv6_groups "$ip" || return 1
    lg=$(awk -F: '{print NF}' <<<"$ip")
    ((lg == 8))
  fi
}

ask_listen() {
  local default=$1 ans
  while true; do
    ans=$(prompt "监听地址" "$default" "q 取消") || return 2
    cancelled "$ans" && return 2
    ans=$(unbracket "$ans")
    if is_ipv4 "$ans" || is_ipv6 "$ans"; then
      printf '%s' "$ans"
      return 0
    fi
    err "请输入 IPv4、IPv6、0.0.0.0 或 ::。"
  done
}

ask_port() {
  local default=$1 except=$2 proto=$3 network=$4 listen=${5:-0.0.0.0} ans p
  while true; do
    ans=$(prompt "端口" "$default" "q 取消") || return 2
    cancelled "$ans" && return 2
    if [[ ! $ans =~ ^[0-9]{1,5}$ ]] || ((10#$ans < 1 || 10#$ans > 65535)); then
      err "端口须为 1-65535。"
      continue
    fi
    p=$((10#$ans))
    if port_conflict "$p" "$except" "$proto" "$network" "$listen"; then
      err "端口 ${p} 与入站 ${CONFLICT_TAG} 冲突。"
      continue
    fi
    printf '%s' "$p"
    return 0
  done
}

ask_remark() {
  local default=$1 ans
  while true; do
    ans=$(prompt "备注" "$default" "q 取消") || return 2
    cancelled "$ans" && return 2
    if [[ -z $ans ]]; then
      err "备注不能为空。"
      continue
    fi
    printf '%s' "$ans"
    return 0
  done
}

ask_name() {
  local label=$1 default=$2 mode=$3 ans host tport
  while true; do
    ans=$(prompt "$label" "$default" "q 取消") || return 2
    cancelled "$ans" && return 2
    ans=$(unbracket "$ans")
    host=$ans
    tport=443
    if ! is_ipv6 "$ans" && [[ $ans =~ ^([A-Za-z0-9.-]+):([0-9]{1,5})$ ]]; then
      host=${BASH_REMATCH[1]}
      tport=${BASH_REMATCH[2]}
      if ((10#$tport < 1 || 10#$tport > 65535)); then
        err "端口不合法。"
        continue
      fi
      tport=$((10#$tport))
    fi
    if [[ $mode == domain ]]; then
      if [[ $host =~ [A-Za-z] ]] && is_domain "$host"; then
        printf '%s\n%s' "$host" "$tport"
        return 0
      fi
      err "请输入域名，例如 www.microsoft.com，不要用 CDN。"
      continue
    fi
    if is_ipv4 "$host" || is_ipv6 "$host" || is_domain "$host"; then
      printf '%s\n%s' "$host" "$tport"
      return 0
    fi
    err "请输入域名、IPv4 或 IPv6。"
  done
}

ask_choice() {
  local max=$1 hint=${2:-返回} ans
  ans=$(prompt "选择" "" "q ${hint}") || return 2
  cancelled "$ans" && return 3
  if [[ -z $ans ]]; then
    return 5
  fi
  if [[ $ans =~ ^[0-9]{1,5}$ ]] && ((10#$ans >= 1 && 10#$ans <= max)); then
    printf '%s' "$((10#$ans))"
    return 0
  fi
  return 4
}

choice_menu() {
  local mode=$1 title=$2 hint=$3 subtitle=$4
  shift 4
  local -a rows=("$@")
  local choice msg='' rc i
  while true; do
    header "$title"
    [[ -z $subtitle ]] || { note "$subtitle"; blank; }
    for ((i = 0; i < ${#rows[@]}; i++)); do
      if [[ $mode == fields ]]; then
        printf '  %b%s%b%s%s\n' "$ACC" "$(pad "$((i + 1))" "$MENU_NUM_W")" "$RST" \
          "$(pad "${rows[i]%%=*}" 9)" "${rows[i]#*=}" >&4
      else
        item "$((i + 1))" "${rows[i]}"
      fi
    done
    blank
    [[ -z $msg ]] || err "$msg"
    choice=$(ask_choice "${#rows[@]}" "$hint") && rc=0 || rc=$?
    case $rc in
      0) printf '%s' "$choice"; return 0 ;;
      4) msg="无效选项。" ;;
      5) msg='' ;;
      *) return "$rc" ;;
    esac
  done
}

choose() {
  local title=$1 hint=$2
  shift 2
  choice_menu items "$title" "$hint" '' "$@"
}

SS_METHODS=(
  2022-blake3-aes-128-gcm
  2022-blake3-aes-256-gcm
  2022-blake3-chacha20-poly1305
  aes-128-gcm
  aes-256-gcm
  chacha20-ietf-poly1305
)

method_name() {
  local i=$((10#$1 - 1))
  ((i >= 0 && i < ${#SS_METHODS[@]})) || return 1
  printf '%s' "${SS_METHODS[i]}"
}

ss2022_bytes() {
  case $1 in
    2022-blake3-aes-128-gcm) printf 16 ;;
    2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305) printf 32 ;;
    *) return 1 ;;
  esac
}

ask_method() {
  local choice i label
  local -a rows=()
  for ((i = 0; i < ${#SS_METHODS[@]}; i++)); do
    label=${SS_METHODS[i]}
    [[ $i == 0 ]] && label+="    推荐"
    rows+=("$label")
  done
  choice=$(choose "加密方式" "取消" "${rows[@]}") || return $?
  method_name "$choice"
}

ask_ss_network() {
  local choice
  choice=$(choose "传输" "取消" "tcp,udp" "tcp" "udp") || return $?
  case $choice in
    2) printf 'tcp' ;;
    3) printf 'udp' ;;
    *) printf 'tcp,udp' ;;
  esac
}

gen_ss_password() {
  local n=24
  n=$(ss2022_bytes "$1") || n=24
  openssl rand -base64 "$n" | tr -d '\n'
}

gen_uuid() {
  if [[ -x $BIN ]]; then
    "$BIN" uuid | tr -d '[:space:]'
  else
    tr -d '[:space:]' </proc/sys/kernel/random/uuid
  fi
}

regen_prompt() {
  if [[ -n $2 ]]; then
    prompt "$1" "" "回车保留，g 重新生成，q 取消"
  else
    prompt "$1" "" "回车生成，q 取消"
  fi
}

gen_shortid() {
  openssl rand -hex 8 | tr -d '[:space:]'
}

gen_auth() {
  openssl rand -hex 16 | tr -d '[:space:]'
}

gen_reality_pair() {
  local out priv pub
  if [[ ! -x $BIN ]]; then
    err "请先安装内核。"
    return 1
  fi
  out=$("$BIN" x25519 2>&1 | tr -d '\r') || true
  priv=$(printf '%s\n' "$out" | awk 'tolower($0) ~ /private/{print $NF; exit}')
  pub=$(printf '%s\n' "$out" | awk 'tolower($0) ~ /public|password/{print $NF; exit}')
  if [[ -z $priv || -z $pub ]]; then
    err "无法解析 xray x25519 输出。"
    return 1
  fi
  printf '%s\n%s\n' "$priv" "$pub"
}

is_uuid() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

normalize_uuid() {
  local value=$1 result
  if is_uuid "$value"; then
    printf '%s' "${value,,}"
    return 0
  fi
  [[ -x $BIN ]] || return 1
  result=$("$BIN" uuid -i "$value") || return 1
  is_uuid "$result" || return 1
  printf '%s' "${result,,}"
}

ask_uuid() {
  local current=$1 ans bytes
  while true; do
    ans=$(regen_prompt "UUID" "$current") || return 2
    cancelled "$ans" && return 2
    if [[ -z $ans ]]; then
      if [[ -n $current ]]; then
        normalize_uuid "$current"
        return $?
      else
        gen_uuid
      fi
      return 0
    fi
    if is_regen "$ans"; then
      gen_uuid
      return 0
    fi
    bytes=$(printf '%s' "$ans" | wc -c | tr -d ' ')
    if is_uuid "$ans"; then
      printf '%s' "${ans,,}"
      return 0
    fi
    if ((bytes > 0 && bytes <= 30)); then
      normalize_uuid "$ans" && return 0
    fi
    err "UUID 不合法。可留空生成，或输入不超过 30 字节。"
  done
}

ask_password() {
  local label=$1 current=$2 method=$3 ans
  while true; do
    ans=$(regen_prompt "$label" "$current") || return 2
    if [[ -z $ans && -n $current ]]; then
      if [[ -n $method ]] && ! ss_key_ok "$method" "$current"; then
        err "密码长度不符，请输入 g 重新生成。"
        continue
      fi
      printf '%s' "$current"
      return 0
    fi
    if [[ -z $ans ]] || is_regen "$ans"; then
      if [[ -n $method ]]; then
        gen_ss_password "$method"
      else
        gen_auth
      fi
      return 0
    fi
    if cancelled "$ans"; then
      return 2
    fi
    if [[ -n $method ]] && ! ss_key_ok "$method" "$ans"; then
      err "密码长度与加密方式不匹配。"
      continue
    fi
    printf '%s' "$ans"
    return 0
  done
}

ask_reality_keys() {
  local cur_priv=$1 cur_pub=$2 cur_sid=$3 ans
  if [[ -n $cur_priv && -n $cur_pub ]]; then
    while true; do
      ans=$(regen_prompt "REALITY 密钥" "$cur_priv") || return 2
      if [[ -z $ans ]]; then
        printf '%s\n%s\n%s\n' "$cur_priv" "$cur_pub" "$cur_sid"
        return 0
      fi
      if is_regen "$ans"; then
        break
      fi
      if cancelled "$ans"; then
        return 2
      fi
      err "请回车，或输入 g。"
    done
  fi
  local pair priv pub sid
  pair=$(gen_reality_pair) || return 1
  read_fields "$pair" priv pub
  sid=$(gen_shortid)
  printf '%s\n%s\n%s\n' "$priv" "$pub" "$sid"
}

make_self_signed() {
  local cn=$1 dir san crt key
  dir=$(mktemp -d) || return 1
  crt=$dir/cert.crt
  key=$dir/cert.key
  if is_ipv4 "$cn" || is_ipv6 "$cn"; then
    san="IP:${cn}"
  else
    san="DNS:${cn}"
  fi
  if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$key" -out "$crt" -days 3650 \
    -subj "/CN=${cn}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    rm -rf -- "$dir"
    err "生成证书失败。"
    return 1
  fi
  chmod 600 "$crt" "$key" || { rm -rf -- "$dir"; return 1; }
  printf 'temp\n%s\n%s\n1\n' "$crt" "$key"
}

validate_cert_pair() {
  local crt=$1 key=$2 cert_pub key_pub
  openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1 || { err "证书无效或已过期。"; return 1; }
  cert_pub=$(openssl x509 -in "$crt" -pubkey -noout 2>/dev/null) || return 1
  key_pub=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) || return 1
  [[ $cert_pub == "$key_pub" ]] || { err "证书与私钥不匹配。"; return 1; }
}

copy_cert_pair() {
  local tag=$1 src_crt=$2 src_key=$3 crt key staging
  crt=$CERT_DIR/${tag}.crt
  key=$CERT_DIR/${tag}.key
  if [[ ! -f $src_crt || ! -r $src_crt || ! -f $src_key || ! -r $src_key ]]; then
    err "证书或私钥不可读。"
    return 1
  fi
  validate_cert_pair "$src_crt" "$src_key" || return 1
  install -d -m 750 -o root -g xray "$CERT_DIR" || return 1
  staging=$(mktemp -d "$CERT_DIR/.stage.XXXXXX") || return 1
  if ! install -m 640 -o root -g xray "$src_crt" "$staging/cert" \
    || ! install -m 640 -o root -g xray "$src_key" "$staging/key" \
    || ! mv -f -- "$staging/cert" "$crt" || ! mv -f -- "$staging/key" "$key"; then
    rm -rf -- "$staging"
    return 1
  fi
  rmdir "$staging" || return 1
  printf '%s\n%s\n' "$crt" "$key"
}

ask_cert() {
  local cn=$1 cur_crt=${2:-} cur_key=${3:-} cur_insecure=${4:-1}
  local choice src_crt src_key insecure ans
  local -a rows=("自动生成自签证书" "使用已有证书")
  if [[ -n $cur_crt && -f $cur_crt && -n $cur_key && -f $cur_key ]]; then
    rows+=("保留当前证书")
  fi
  choice=$(choose "证书" "取消" "${rows[@]}") || return $?
  case $choice in
    1) make_self_signed "$cn" ;;
    2)
      src_crt=$(prompt "证书文件" "" "q 取消") || return 2
      cancelled "$src_crt" && return 2
      src_key=$(prompt "私钥文件" "" "q 取消") || return 2
      cancelled "$src_key" && return 2
      if [[ ! -f $src_crt || ! -r $src_crt || ! -f $src_key || ! -r $src_key ]]; then
        err "证书或私钥不可读。"
        return 1
      fi
      validate_cert_pair "$src_crt" "$src_key" || return 1
      ans=$(prompt "跳过证书校验" "n" "q 取消") || return 2
      cancelled "$ans" && return 2
      if [[ $ans == y || $ans == Y ]]; then
        insecure=1
      else
        insecure=0
      fi
      printf 'src\n%s\n%s\n%s\n' "$src_crt" "$src_key" "$insecure"
      ;;
    3) printf 'keep\n%s\n%s\n%s\n' "$cur_crt" "$cur_key" "$cur_insecure" ;;
    *) return 2 ;;
  esac
}

tag_used() {
  local tag=$1
  [[ -f $META_DIR/${tag}.json ]] && return 0
  if [[ -f $CONF ]] && jq -e --arg t "$tag" 'any(.inbounds[]?; .tag == $t)' "$CONF" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

new_tag() {
  local prefix=$1 port=$2 tag i=2
  tag="${prefix}-${port}"
  while tag_used "$tag"; do
    tag="${prefix}-${port}-${i}"
    i=$((i + 1))
  done
  printf '%s' "$tag"
}

meta_ss() {
  jq -n \
    --arg tag "$1" --arg remark "$2" --arg listen "$3" \
    --argjson port "$4" --arg method "$5" --arg network "$7" \
    --rawfile password <(printf '%s' "$6") \
    '{tag:$tag,remark:$remark,protocol:"shadowsocks",listen:$listen,port:$port,
      network:$network,method:$method,password:$password}'
}

meta_vless() {
  jq -n \
    --arg tag "$1" --arg remark "$2" --arg listen "$3" --argjson port "$4" \
    --arg flow "$6" --arg sni "$7" \
    --arg target "$8" --argjson targetPort "$9" --arg pub "${11}" --arg sid "${12}" \
    --rawfile uuid <(printf '%s' "$5") --rawfile priv <(printf '%s' "${10}") \
    '{tag:$tag,remark:$remark,protocol:"vless",listen:$listen,port:$port,
      network:"tcp",uuid:$uuid,flow:$flow,security:"reality",sni:$sni,
      target:$target,targetPort:$targetPort,privateKey:$priv,publicKey:$pub,shortId:$sid}'
}

meta_hy() {
  local insecure=false
  [[ $9 == 1 ]] && insecure=true
  jq -n \
    --arg tag "$1" --arg remark "$2" --arg listen "$3" --argjson port "$4" \
    --arg sni "$6" --arg cert "$7" --arg key "$8" \
    --argjson insecure "$insecure" --rawfile auth <(printf '%s' "$5") \
    '{tag:$tag,remark:$remark,protocol:"hysteria2",listen:$listen,port:$port,
      network:"udp",security:"tls",sni:$sni,auth:$auth,
      certFile:$cert,keyFile:$key,insecure:$insecure}'
}

render_inbound() {
  jq '
    def hy_sni:
      if (.sni | length) > 0 and .sni != "null"
         and ((.sni | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")) or (.sni | test(":")))
      then {} else {serverName:.sni} end;
    if .protocol == "shadowsocks" then
      {tag:.tag, listen:.listen, port:.port, protocol:"shadowsocks",
        settings:{method:.method, password:.password, network:.network}}
    elif .protocol == "vless" then
      . as $m
      | {tag:$m.tag, listen:$m.listen, port:$m.port, protocol:"vless",
          settings:{decryption:"none",
            clients:[{id:$m.uuid, flow:$m.flow, email:$m.tag}]},
          streamSettings:{network:"tcp", security:"reality",
            realitySettings:{target:($m.target + ":" + ($m.targetPort | tostring)),
              serverNames:[$m.sni], privateKey:$m.privateKey, shortIds:[$m.shortId]}}}
    elif .protocol == "hysteria2" then
      . as $m
      | {tag:$m.tag, listen:$m.listen, port:$m.port, protocol:"hysteria",
          settings:{version:2, users:[{auth:$m.auth, email:$m.tag}]},
          streamSettings:{security:"tls",
            tlsSettings:({alpn:["h3"], certificates:[{certificateFile:$m.certFile, keyFile:$m.keyFile}]} + ($m | hy_sni)),
            method:"hysteria",
            hysteriaSettings:{version:2, masquerade:{type:"string", content:"404 not found", statusCode:404}}}}
    else
      error("unknown protocol")
    end
  '
}

rebuild_config() {
  local parts tags rc
  local -a files=("$META_DIR"/*.json) previous=()
  [[ -z $TX ]] || previous=("$TX"/meta/*.json)
  parts=$(mktemp) || return 1
  if ((${#files[@]})); then
    if ! jq -s '.[]' "${files[@]}" | render_inbound | jq -s . >"$parts"; then
      rm -f -- "$parts"
      return 1
    fi
  else
    printf '[]\n' >"$parts"
  fi
  # 连同快照里的旧 tag 一起删，外部入站仍保留。
  tags='[]'
  if ((${#files[@]} + ${#previous[@]})); then
    tags=$(jq -s 'map(.tag) | unique' "${files[@]}" "${previous[@]}") || { rm -f -- "$parts"; return 1; }
  fi
  ensure_base_config || { rm -f -- "$parts"; return 1; }
  jq --slurpfile ins "$parts" --argjson tags "$tags" '
    if type != "object" or ((.inbounds // []) | type) != "array" then error("invalid config") else . end
    | .inbounds = ([.inbounds[]? | select(.tag as $t | $tags | index($t) | not)] + $ins[0])
  ' "$CONF" | atomic_json "$CONF" 640 root xray
  rc=$?
  rm -f -- "$parts"
  return "$rc"
}

save_meta_and_inbound() {
  local tag=$1 meta_json
  [[ $tag =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  meta_json=$(cat)
  if [[ -z $meta_json ]] || ! printf '%s' "$meta_json" | jq -e --arg t "$tag" '.tag == $t' >/dev/null; then
    return 1
  fi
  printf '%s' "$meta_json" | atomic_json "$META_DIR/${tag}.json" 600 root root || return 1
  rebuild_config
}

list_meta_files() {
  local f
  for f in "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    jq -r '[.port, .tag] | @tsv' "$f"
  done | sort -n -k1,1 | while IFS=$'\t' read -r _port tag; do
    printf '%s\n' "$META_DIR/${tag}.json"
  done
}

proto_label() {
  local meta=$1 security
  case $(jq -r '.protocol' "$meta") in
    shadowsocks) printf 'Shadowsocks' ;;
    hysteria2) printf 'Hysteria2' ;;
    vless)
      security=$(jq -r '.security' "$meta")
      if [[ $security == reality ]]; then
        printf 'VLESS/REALITY'
      else
        printf 'VLESS/TLS'
      fi
      ;;
    *) printf '未知' ;;
  esac
}

pick_inbound() {
  local title=$1
  local -a files=()
  local line
  while IFS= read -r line; do
    [[ -n $line ]] && files+=("$line")
  done < <(list_meta_files)
  if ((${#files[@]} == 0)); then
    header "$title"
    plainln "  暂无入站，主菜单选 6 添加。"
    pause
    return 1
  fi
  local f label port remark choice
  local -a rows=()
  for f in "${files[@]}"; do
    label=$(proto_label "$f")
    port=$(jq -r '.port' "$f")
    remark=$(jq -r '.remark' "$f")
    rows+=("$(pad "$label" 16)$(pad "$port" 7)$remark")
  done
  choice=$(choose "$title" "返回" "${rows[@]}") || return 1
  PICKED=${files[$((choice - 1))]}
}

firewall_hint() {
  local proto=$1 port=$2 network=${3:-}
  case $proto in
    hysteria2) plainln "  请放行 UDP ${port}。" ;;
    shadowsocks)
      case $network in
        tcp) plainln "  请放行 TCP ${port}。" ;;
        udp) plainln "  请放行 UDP ${port}。" ;;
        *) plainln "  请放行 TCP/UDP ${port}。" ;;
      esac
      ;;
    *) plainln "  请放行 TCP ${port}。" ;;
  esac
}

need_tx() {
  if ! begin_tx; then
    err "无法创建配置快照。"
    pause
    return 1
  fi
}

commit_inbound() {
  local tag=$1 proto=$2 port=$3 doc=$4 network listen
  if [[ -z $doc ]]; then
    [[ -z $TX ]] || rollback_tx || true
    err "写入失败。"
    pause
    return 1
  fi
  if [[ -z $TX ]] && ! need_tx; then
    return 1
  fi
  network=$(jq -r '.network // ""' <<<"$doc") || { rollback_tx; return 1; }
  listen=$(jq -r '.listen' <<<"$doc") || { rollback_tx; return 1; }
  if port_conflict "$port" "$tag" "$proto" "$network" "$listen"; then
    err "端口 ${port} 与入站 ${CONFLICT_TAG} 冲突。"
    rollback_tx
    pause
    return 1
  fi
  save_meta_and_inbound "$tag" <<<"$doc" || { rollback_tx; err "写入失败。"; pause; return 1; }
  commit_tx || { pause; return 1; }
  firewall_hint "$proto" "$port" "$network"
  pause
}

load_cert_fields() {
  read_fields "$1" cert_mode cert key insecure
  if [[ $cert_mode == temp ]]; then
    cert_show="自签证书"
    TMP_PATHS+=("$(dirname "$cert")")
  else
    cert_show=$cert
  fi
}

drop_temp_cert() {
  local dir p
  [[ $1 == temp && $2 == /* ]] || return 0
  dir=$(dirname "$2")
  for p in "${TMP_PATHS[@]}"; do
    if [[ $p == "$dir" ]]; then
      rm -rf -- "$dir"
      return 0
    fi
  done
}

confirm_write() {
  confirm "确认写入？" || {
    drop_temp_cert "${cert_mode:-}" "${cert:-}"
    return 1
  }
}

stage_chosen_cert() {
  local paths src_crt=$cert src_key=$key
  if [[ $cert_mode == keep ]]; then
    paths=$(printf '%s\n%s\n' "$src_crt" "$src_key")
  else
    paths=$(copy_cert_pair "$1" "$src_crt" "$src_key") || {
      rollback_tx
      drop_temp_cert "${cert_mode:-}" "${cert:-}"
      err "证书写入失败。"
      pause
      return 1
    }
  fi
  read_fields "$paths" cert key
  drop_temp_cert "$cert_mode" "$src_crt"
  cert_mode=keep
}

load_plain() {
  local file=$1 key val
  shift
  for key in "$@"; do
    val=$(jq -r --arg k "$key" '.[$k]' "$file")
    printf -v "$key" '%s' "$val"
  done
}

ss_wizard() {
  local tag="" listen port remark method password network doc
  header "Shadowsocks"
  listen=$(ask_listen "0.0.0.0") || return 0
  network=$(ask_ss_network) || return 0
  port=$(ask_port 8388 "" shadowsocks "$network" "$listen") || return 0
  tag=$(new_tag ss "$port")
  remark=$(ask_remark "ss-${port}") || return 0
  method=$(ask_method) || return 0
  password=$(ask_password "密码" "" "$method") || return 0
  blank
  kv "协议" "Shadowsocks"
  kv "监听" "$(uri_host "$listen"):${port}"
  kv "加密" "$method"
  kv "传输" "$network"
  kv "密码" "$password"
  kv "备注" "$remark"
  blank
  confirm_write || return 0
  doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") || doc=""
  commit_inbound "$tag" shadowsocks "$port" "$doc" || return 0
}

vless_wizard() {
  local tag="" listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys doc
  header "VLESS / REALITY"
  flow=xtls-rprx-vision
  note "VLESS REALITY 仅 TCP，流控 xtls-rprx-vision。"
  blank
  listen=$(ask_listen "0.0.0.0") || return 0
  port=$(ask_port 443 "" vless tcp "$listen") || return 0
  tag=$(new_tag vless "$port")
  remark=$(ask_remark "vless-${port}") || return 0
  while true; do
    note "伪装站点需要 TLS 1.3，不要用 CDN。"
    name_pack=$(ask_name "伪装域名" "www.microsoft.com:443" domain) || return 0
    read_fields "$name_pack" host tport
    reality_dest_ok "$host" "$tport" && break
  done
  sni=$host
  target=$host
  keys=$(ask_reality_keys "" "" "") || { [[ $? -eq 1 ]] && pause; return 0; }
  read_fields "$keys" priv pub sid
  uuid=$(ask_uuid "") || return 0
  blank
  kv "协议" "VLESS / REALITY"
  kv "伪装" "${target}:${tport}"
  kv "ShortId" "$sid"
  kv "公钥" "$pub"
  kv "监听" "$(uri_host "$listen"):${port}"
  kv "流控" "$flow"
  kv "UUID" "$uuid"
  kv "备注" "$remark"
  blank
  confirm_write || return 0
  doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
    "$sni" "$target" "$tport" "$priv" "$pub" "$sid") || doc=""
  commit_inbound "$tag" vless "$port" "$doc" || return 0
}

hy_wizard() {
  local tag="" listen port remark auth sni cert key insecure
  local name_pack host cert_pack cert_mode="" cert_show="" doc
  header "Hysteria2"
  note "Hysteria2 走 QUIC，必须启用 TLS。"
  blank
  listen=$(ask_listen "0.0.0.0") || return 0
  port=$(ask_port 443 "" hysteria2 udp "$listen") || return 0
  tag=$(new_tag hy2 "$port")
  remark=$(ask_remark "hy2-${port}") || return 0
  name_pack=$(ask_name "证书域名或 IP" "" name) || return 0
  read_fields "$name_pack" host
  sni=$host
  cert_pack=$(ask_cert "$sni" "" "" 1) || { [[ $? -eq 1 ]] && pause; return 0; }
  load_cert_fields "$cert_pack"
  auth=$(ask_password "认证密码" "" "") || { drop_temp_cert "$cert_mode" "$cert"; return 0; }
  blank
  kv "协议" "Hysteria2"
  kv "监听" "$(uri_host "$listen"):${port}/udp"
  kv "SNI" "$sni"
  kv "证书" "$cert_show"
  kv "ALPN" "h3"
  kv "认证" "$auth"
  kv "备注" "$remark"
  blank
  confirm_write || return 0
  need_tx || return 0
  stage_chosen_cert "$tag" || return 0
  doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") || doc=""
  commit_inbound "$tag" hysteria2 "$port" "$doc" || return 0
}

prepare_store() {
  if ! id -u xray >/dev/null 2>&1; then
    err "缺少服务用户，请先安装内核。"
    pause
    return 1
  fi
  ensure_dirs
}

add_inbound() {
  local choice
  require_kernel || return 0
  prepare_store || return 0
  while true; do
    choice=$(choose "添加入站" "返回" "Shadowsocks" "VLESS REALITY" "Hysteria2") || return 0
    case $choice in
      1) ss_wizard ;;
      2) vless_wizard ;;
      3) hy_wizard ;;
    esac
    [[ -z $TX ]] || return 1
  done
}

edit_loop() {
  local title=$1 remark=$2
  shift 2
  choice_menu fields "$title" 返回 "$remark" "$@"
}

ss_key_ok() {
  local method=$1 password=$2 need got
  need=$(ss2022_bytes "$method") || return 0
  [[ $password =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
  got=$(printf '%s' "$password" | openssl base64 -d -A 2>/dev/null | openssl base64 -A) || return 1
  [[ $got == "$password" ]] || return 1
  got=$(printf '%s' "$password" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ') || return 1
  [[ $got -eq $need ]]
}

apply_field_cert() {
  local cert_pack rc
  cert_pack=$(ask_cert "$1" "$2" "$3" "$4") || {
    rc=$?
    [[ $rc -eq 1 ]] && pause
    return "$rc"
  }
  load_cert_fields "$cert_pack"
  confirm_write || return 1
}

edit_ss() {
  local meta=$1 choice doc
  local tag listen port remark method password network
  while [[ -z $TX ]]; do
    load_plain "$meta" tag listen port remark method password network
    choice=$(edit_loop "修改 Shadowsocks" "$remark" \
      "监听=$listen" "端口=$port" "传输=$network" \
      "备注=$remark" "加密=$method" "密码=$password") || return 0
    case $choice in
      1) listen=$(ask_listen "$listen") || continue ;;
      2) port=$(ask_port "$port" "$tag" shadowsocks "$network" "$listen") || continue ;;
      3)
        network=$(ask_ss_network) || continue
        if port_conflict "$port" "$tag" shadowsocks "$network" "$listen"; then
          err "端口 ${port} 与入站 ${CONFLICT_TAG} 冲突。"
          pause
          continue
        fi
        ;;
      4) remark=$(ask_remark "$remark") || continue ;;
      5)
        method=$(ask_method) || continue
        if ! ss_key_ok "$method" "$password"; then
          note "新加密方式需要重新设置密码。"
          password=$(ask_password "密码" "" "$method") || continue
          kv "加密" "$method"
          kv "密码" "$password"
        fi
        ;;
      6) password=$(ask_password "密码" "$password" "$method") || continue ;;
      *) continue ;;
    esac
    confirm_write || continue
    doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") || doc=""
    commit_inbound "$tag" shadowsocks "$port" "$doc" || continue
  done
}

edit_vless() {
  local meta=$1 choice doc
  local tag listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys dest
  while [[ -z $TX ]]; do
    load_plain "$meta" tag listen port remark uuid sni target
    priv=$(jq -r '.privateKey // empty' "$meta")
    pub=$(jq -r '.publicKey // empty' "$meta")
    sid=$(jq -r '.shortId // empty' "$meta")
    flow=$(jq -r '.flow // "xtls-rprx-vision"' "$meta")
    [[ -z $flow || $flow == null ]] && flow=xtls-rprx-vision
    tport=$(jq -r '.targetPort // 443' "$meta")
    choice=$(edit_loop "修改 VLESS REALITY" "$remark" \
      "监听=$listen" "端口=$port" "备注=$remark" \
      "伪装=${target}:${tport}" "公钥=$pub" "UUID=$uuid") || return 0
    case $choice in
      1) listen=$(ask_listen "$listen") || continue ;;
      2) port=$(ask_port "$port" "$tag" vless tcp "$listen") || continue ;;
      3) remark=$(ask_remark "$remark") || continue ;;
      4)
        dest=$target
        [[ -z $dest || $dest == null ]] && dest=$sni
        [[ -n $tport && $tport != null && $tport != 443 ]] && dest="${dest}:${tport}"
        plainln "  伪装站点需要 TLS 1.3，不要用 CDN。"
        name_pack=$(ask_name "伪装域名" "$dest" domain) || continue
        read_fields "$name_pack" host tport
        reality_dest_ok "$host" "$tport" || continue
        sni=$host
        target=$host
        ;;
      5)
        keys=$(ask_reality_keys "$priv" "$pub" "$sid") || {
          [[ $? -eq 1 ]] && pause
          continue
        }
        read_fields "$keys" priv pub sid
        ;;
      6) uuid=$(ask_uuid "$uuid") || continue ;;
      *) continue ;;
    esac
    confirm_write || continue
    doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
      "$sni" "$target" "$tport" "$priv" "$pub" "$sid") || doc=""
    commit_inbound "$tag" vless "$port" "$doc" || continue
  done
}

edit_hy() {
  local meta=$1 choice doc staged
  local tag listen port remark auth sni cert key insecure name_pack
  local cert_mode='' cert_show=''
  while [[ -z $TX ]]; do
    load_plain "$meta" tag listen port remark auth sni
    cert=$(jq -r '.certFile // empty' "$meta")
    key=$(jq -r '.keyFile // empty' "$meta")
    insecure=$(jq -r 'if .insecure then 1 else 0 end' "$meta")
    staged=0
    choice=$(edit_loop "修改 Hysteria2" "$remark" \
      "监听=$listen" "端口=$port" "备注=$remark" \
      "域名=$sni" "证书=$cert" "认证=$auth") || return 0
    case $choice in
      1) listen=$(ask_listen "$listen") || continue ;;
      2) port=$(ask_port "$port" "$tag" hysteria2 udp "$listen") || continue ;;
      3) remark=$(ask_remark "$remark") || continue ;;
      4)
        name_pack=$(ask_name "证书域名或 IP" "$sni" name) || continue
        read_fields "$name_pack" sni
        ;;
      5)
        apply_field_cert "$sni" "$cert" "$key" "$insecure" || continue
        need_tx || continue
        stage_chosen_cert "$tag" || continue
        staged=1
        ;;
      6) auth=$(ask_password "认证密码" "$auth" "") || continue ;;
      *) continue ;;
    esac
    if ((staged == 0)) && ! confirm_write; then
      continue
    fi
    doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") || doc=""
    commit_inbound "$tag" hysteria2 "$port" "$doc" || continue
  done
}

edit_inbound() {
  local picked
  require_kernel || return 0
  prepare_store || return 0
  while true; do
    pick_inbound "修改入站" || return 0
    picked=$PICKED
    case $(jq -r '.protocol' "$picked") in
      shadowsocks) edit_ss "$picked" ;;
      vless) edit_vless "$picked" ;;
      hysteria2) edit_hy "$picked" ;;
      *)
        err "未知协议。"
        pause
        ;;
    esac
    [[ -z $TX ]] || return 1
  done
}

delete_inbound() {
  local picked tag
  pick_inbound "删除入站" || return 0
  picked=$PICKED
  tag=$(jq -r '.tag' "$picked")
  blank
  kv "删除" "$(proto_label "$picked")  $(jq -r '.port' "$picked")  $(jq -r '.remark' "$picked")"
  confirm "确认删除？" || return 0
  prepare_store || return 0
  need_tx || return 0
  rm -f -- "$META_DIR/${tag}.json" || { rollback_tx; pause; return 0; }
  if ! rebuild_config || ! gc_certs; then
    rollback_tx
    err "写入失败。"
    pause
    return 0
  fi
  if [[ -x $BIN ]]; then
    commit_tx || { pause; return 0; }
  else
    if ! fix_tree_perms || ! end_tx; then rollback_tx; pause; return 0; fi
    plainln "  已删除。"
  fi
  pause
}

unbracket() {
  local h=$1
  [[ $h == \[*\] ]] && h=${h:1:${#h}-2}
  printf '%s' "$h"
}

uri_host() {
  local h=$1
  if [[ $h == *:* && $h != \[*\] ]]; then
    printf '[%s]' "$h"
  else
    printf '%s' "$h"
  fi
}

urlenc() {
  jq -nr --arg v "$1" '$v|@uri'
}

b64url() {
  printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '=\n'
}

is_public_ipv4() {
  local o1 o2
  is_ipv4 "$1" || return 1
  IFS=. read -r o1 o2 _ _ <<<"$1"
  o1=$((10#$o1))
  o2=$((10#$o2))
  ((o1 == 0 || o1 == 10 || o1 == 127 || o1 >= 224)) && return 1
  ((o1 == 100 && o2 >= 64 && o2 <= 127)) && return 1
  ((o1 == 169 && o2 == 254)) && return 1
  ((o1 == 172 && o2 >= 16 && o2 <= 31)) && return 1
  ((o1 == 192 && o2 == 168)) && return 1
  return 0
}

is_public_ipv6() {
  local ip=${1,,} head
  is_ipv6 "$ip" || return 1
  [[ $ip == :: || $ip == ::1 || $ip == ::ffff:* || $ip == fc* || $ip == fd* || $ip == ff* ]] && return 1
  head=${ip%%:*}
  [[ $head =~ ^fe[89ab][0-9a-f]$ ]] && return 1
  return 0
}

fetch_ip() {
  local rc=0
  curl -"$1" -fsS --connect-timeout 2 --max-time 4 -o "$3" "$2" 2>/dev/null || rc=$?
  printf '%s' "$rc" >"${3}.rc"
}

read_public_ip() {
  local ip
  [[ -s $1 ]] || return 1
  ip=$(tr -d '[:space:]' <"$1")
  if [[ $2 == 4 ]]; then is_public_ipv4 "$ip"; else is_public_ipv6 "$ip"; fi || return 1
  printf '%s' "$ip"
}

# 先并行查询，只有不是网络不可达时才换备用地址。输出两行，缺失则留空。
detect_public_ips() {
  local dir fam file ip rc v4="" v6=""
  dir=$(mktemp -d) || return 1
  fetch_ip 4 https://api.ipify.org "$dir/4" &
  fetch_ip 6 https://api6.ipify.org "$dir/6" &
  wait || true
  for fam in 4 6; do
    file=$dir/$fam
    ip=$(read_public_ip "$file" "$fam" || true)
    rc=$(cat "$file.rc" 2>/dev/null || true)
    if [[ -z $ip && $rc != 6 && $rc != 7 ]]; then
      if [[ $fam == 4 ]]; then fetch_ip 4 https://ipv4.icanhazip.com "$file"; else fetch_ip 6 https://ipv6.icanhazip.com "$file"; fi
      ip=$(read_public_ip "$file" "$fam" || true)
    fi
    [[ $fam == 4 ]] && v4=$ip || v6=$ip
  done
  rm -rf -- "$dir"
  printf '%s\n%s\n' "$v4" "$v6"
}

share_host_ok() {
  local host
  host=$(unbracket "$1")
  is_ipv4 "$host" || is_ipv6 "$host" || is_domain "$host"
}

# Xray 在支持双栈的 Linux 上使用双栈通配监听，不按字符串限定地址族。
share_host_fits() {
  local host listen
  host=$(unbracket "$1")
  listen=$(unbracket "$2")
  share_host_ok "$host" || return 1
  wildcard_listen "$listen" && return 0
  if is_ipv6 "$listen"; then
    ! is_ipv4 "$host"
  else
    ! is_ipv6 "$host"
  fi
}

share_listen_hosts() {
  local listen=$1 v4=$2 v6=$3
  listen=$(unbracket "$listen")
  if ! wildcard_listen "$listen"; then
    printf '%s\n' "$listen"
    return 0
  fi
  [[ -z $v4 ]] || printf '%s\n' "$v4"
  [[ -z $v6 ]] || printf '%s\n' "$v6"
  return 0
}

reality_dest_ok() {
  local host=$1 port=$2 out
  plainln "  正在检查 ${host}:${port} 的 TLS 1.3..."
  if ! command -v timeout >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    err "缺少 timeout 或 openssl，无法检查伪装站点。"
    return 1
  fi
  out=$(timeout 8 openssl s_client -connect "${host}:${port}" -servername "$host" -tls1_3 -showcerts </dev/null 2>&1) || true
  if ! grep -q 'TLSv1.3' <<<"$out"; then
    err "${host}:${port} 未完成 TLS 1.3 握手。请换一个本机能直连、且不在 CDN 后的站点。"
    return 1
  fi
  if grep -Eiq 'cloudflare|akamai|fastly|cloudfront|incapsula|sucuri|stackpath|edgecast|keycdn|bunnycdn' <<<"$out"; then
    err "这个站点的证书属于 CDN，REALITY 不能拿它做伪装。"
    return 1
  fi
  return 0
}

saved_host() {
  if [[ -f $STATE_DIR/server_addr ]]; then
    tr -d '[:space:]' <"$STATE_DIR/server_addr"
  fi
}

build_share() {
  local meta=$1 host=$2
  local proto remark port enc flow sni pub sid fp insecure auth method password uuid
  proto=$(jq -r '.protocol' "$meta")
  remark=$(jq -r '.remark' "$meta")
  port=$(jq -r '.port' "$meta")
  enc=$(urlenc "$remark")
  host=$(uri_host "$host")
  case $proto in
    shadowsocks)
      method=$(jq -r '.method' "$meta")
      password=$(jq -r '.password' "$meta")
      if [[ $method == 2022-* ]]; then
        printf 'ss://%s:%s@%s:%s#%s\n' "$method" "$(urlenc "$password")" "$host" "$port" "$enc"
      else
        printf 'ss://%s@%s:%s#%s\n' "$(b64url "${method}:${password}")" "$host" "$port" "$enc"
      fi
      ;;
    vless)
      uuid=$(normalize_uuid "$(jq -r '.uuid' "$meta")") || return 1
      flow=$(jq -r '.flow' "$meta")
      sni=$(urlenc "$(jq -r '.sni' "$meta")")
      fp=$(urlenc chrome)
      pub=$(urlenc "$(jq -r '.publicKey' "$meta")")
      sid=$(urlenc "$(jq -r '.shortId' "$meta")")
      local query="encryption=none&security=reality&sni=${sni}&fp=${fp}&type=tcp&pbk=${pub}&sid=${sid}"
      if [[ -n $flow && $flow != null ]]; then
        query+="&flow=$(urlenc "$flow")"
      fi
      printf 'vless://%s@%s:%s?%s#%s\n' "$uuid" "$host" "$port" "$query" "$enc"
      ;;
    hysteria2)
      auth=$(urlenc "$(jq -r '.auth' "$meta")")
      sni=$(urlenc "$(jq -r '.sni' "$meta")")
      insecure=$(jq -r 'if .insecure then 1 else 0 end' "$meta")
      local extra="sni=${sni}"
      if [[ $insecure == 1 ]]; then
        extra+="&insecure=1"
      fi
      printf 'hysteria2://%s@%s:%s/?%s#%s\n' "$auth" "$host" "$port" "$extra" "$enc"
      ;;
    *)
      return 1
      ;;
  esac
}

share_details() {
  local meta=$1
  local proto
  proto=$(jq -r '.protocol' "$meta")
  kv "协议" "$(proto_label "$meta")"
  kv "监听" "$(uri_host "$(jq -r '.listen' "$meta")"):$(jq -r '.port' "$meta")"
  kv "备注" "$(jq -r '.remark' "$meta")"
  case $proto in
    shadowsocks)
      kv "加密" "$(jq -r '.method' "$meta")"
      kv "传输" "$(jq -r '.network' "$meta")"
      kv "密码" "$(jq -r '.password' "$meta")"
      ;;
    vless)
      kv "UUID" "$(jq -r '.uuid' "$meta")"
      kv "流控" "$(jq -r '.flow // "无"' "$meta")"
      kv "SNI" "$(jq -r '.sni' "$meta")"
      kv "公钥" "$(jq -r '.publicKey' "$meta")"
      kv "ShortId" "$(jq -r '.shortId' "$meta")"
      kv "指纹" "chrome"
      ;;
    hysteria2)
      kv "认证" "$(jq -r '.auth' "$meta")"
      kv "SNI" "$(jq -r '.sni' "$meta")"
      kv "ALPN" "h3"
      ;;
  esac
}

share_inbound() {
  local picked host default link listen v4="" v6=""
  local -a found=() hosts=()
  if ! command -v jq >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    ensure_deps || {
      header "分享入站"
      err "缺少 jq 或 openssl。"
      pause
      return 0
    }
  fi
  pick_inbound "分享入站" || return 0
  picked=$PICKED
  listen=$(jq -r '.listen // "0.0.0.0"' "$picked")
  plainln "  正在检测公网地址..."
  mapfile -t found < <(detect_public_ips || true)
  v4=${found[0]:-}
  v6=${found[1]:-}
  mapfile -t hosts < <(share_listen_hosts "$listen" "$v4" "$v6")
  if ((${#hosts[@]} == 0)); then
    default=$(saved_host)
    host=$(prompt "服务器地址" "$default" "q 取消") || return 0
    cancelled "$host" && return 0
    if [[ -z $host ]]; then
      err "地址不能为空。"
      pause
      return 0
    fi
    if ! share_host_fits "$host" "$listen"; then
      err "服务器地址无效，或与监听地址的地址族不匹配。"
      pause
      return 0
    fi
    if [[ ! -d $STATE_DIR ]]; then
      install -d -m 750 -o root -g xray "$STATE_DIR" || {
        err "无法保存服务器地址。"
        pause
        return 0
      }
    else
      if ! chown root:xray "$STATE_DIR" || ! chmod 750 "$STATE_DIR"; then
        err "无法设置地址存储目录权限。"
        pause
        return 0
      fi
    fi
    printf '%s\n' "$host" | atomic_text "$STATE_DIR/server_addr" || {
      err "无法保存服务器地址。"
      pause
      return 0
    }
    hosts=("$host")
  fi
  header "分享入站"
  share_details "$picked"
  for host in "${hosts[@]}"; do
    link=$(build_share "$picked" "$host") || { err "无法生成链接。"; pause; return 0; }
    blank
    share_addr "地址" "$host"
    note "分享链接"
    printf '  %s\n' "$link" >&4
  done
  if [[ $(jq -r '.protocol' "$picked") == vless ]]; then
    note "链接里的指纹是 chrome。小火箭请到「设置 → 隧道 → TCP → 指纹」改选 Chrome140。"
  fi
  if [[ -n $v6 ]] && ! share_host_fits "$v6" "$listen"; then
    note "监听不接收 IPv6，未生成 IPv6 链接。"
  fi
  if [[ -n $v4 ]] && ! share_host_fits "$v4" "$listen"; then
    note "监听不接收 IPv4，未生成 IPv4 链接。"
  fi
  pause
}

# 填表期间持锁，避免另一个面板同时写入。
mutate() {
  local rc
  ensure_deps || { err "依赖安装失败。"; pause; return 1; }
  acquire_lock || { pause; return 1; }
  ACTION_LOCK=1
  "$@"
  rc=$?
  if [[ -n $TX ]]; then
    rollback_tx || rc=1
  fi
  ACTION_LOCK=0
  release_lock
  return "$rc"
}

main_menu() {
  local choice msg="" p
  p=$(printf '\001%s\002  选择 \001%s\002q 退出\001%s\002: ' "$GRN" "$DIM" "$GRN")
  while true; do
    draw_panel
    if [[ -n $msg ]]; then
      err "$msg"
    fi
    msg=""
    tty_read choice "$p" || return 0
    case $choice in
      q | Q) ui $'\n'; return 0 ;;
      1) mutate install_kernel ;;
      2) mutate upgrade_kernel ;;
      3) mutate start_kernel ;;
      4) mutate stop_kernel ;;
      5) mutate uninstall_kernel ;;
      6) mutate add_inbound ;;
      7) mutate edit_inbound ;;
      8) mutate share_inbound ;;
      9) mutate delete_inbound ;;
      10) view_logs ;;
      "") ;;
      *) msg="无效选项。" ;;
    esac
    [[ -z $TX ]] || return 1
  done
}

usage() {
  cat <<'EOF'
xray 管理面板

用法: sudo ./xray.sh

文档: https://xtls.github.io/
系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
入站: Shadowsocks、VLESS REALITY、Hysteria2
内核以 xray 用户运行。
EOF
}

main() {
  if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    return 0
  fi
  if [[ $(id -u) -ne 0 ]]; then
    echo "请使用 root 运行。" >&2
    return 1
  fi
  if ! detect_os; then
    return 1
  fi
  if [[ ! -c /dev/tty ]]; then
    echo "请在交互终端中运行。" >&2
    return 1
  fi
  [[ $OS != alpine ]] || SERVICE_FILE=/etc/init.d/xray
  [[ -d ${LOCK_FILE%/*} ]] || LOCK_FILE=/var/lock/xray.lock
  init_ui
  main_menu
}

if [[ ${XRAY_PANEL_SOURCE:-0} != 1 ]]; then
  if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    main "$@"
    exit $?
  fi
  if ! exec 4>/dev/tty; then
    echo "请在交互终端中运行。" >&2
    exit 1
  fi
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  main "$@"
fi
XRAY_PANEL_PAYLOAD
