#!/bin/sh
# sing-box 管理面板
# 文档: https://sing-box.sagernet.org/
# 系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
# 入站: Shadowsocks、VLESS REALITY、Hysteria2、TUIC v5
# 内核以 sing-box 用户运行
#
# 用法: sudo sh sing-box.sh

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
exec bash /dev/fd/3 "$@" 3<<'SINGBOX_PANEL_PAYLOAD'
set -uo pipefail
set +H
set +o history
export HISTFILE=/dev/null
umask 077
shopt -s nullglob

# 程序、配置、证书、运行目录和日志都在 STATE_DIR。服务单元仍由 systemd / OpenRC 从 /etc 加载。
STATE_DIR=/var/lib/sing-box
BIN=$STATE_DIR/bin/sing-box
CMD_LINK=/usr/local/bin/sing-box
CONF_DIR=$STATE_DIR/etc
CONF=$CONF_DIR/config.json
LOG_DIR=$STATE_DIR/log
RUN_DIR=$STATE_DIR/runtime
META_DIR=$STATE_DIR/meta
CERT_DIR=$STATE_DIR/certs
STDOUT_LOG=$LOG_DIR/stdout.log
STDERR_LOG=$LOG_DIR/stderr.log
SERVICE_FILE=/etc/systemd/system/sing-box.service
LOGROTATE_FILE=/etc/logrotate.d/sing-box
REPO=SagerNet/sing-box
LOCK_FILE=/run/lock/sing-box.lock
PID_FILE=/run/sing-box.pid
OPENRC_DIR=/run/openrc

GRN=$'\033[38;2;126;217;167m'
RED=$'\033[38;2;255;107;107m'
YEL=$'\033[38;2;240;200;120m'
DIM=$'\033[38;2;145;155;170m'
ACC=$'\033[38;2;116;180;255m'
RST=$'\033[0m'
BOLD=$'\033[1m'
MENU_NUM_W=4
MENU_LABEL_W=18
PANEL_KERNEL=("1 安装内核 2 升级内核" "3 启动服务 4 停止服务")
PANEL_INBOUND=("6 添加入站 7 修改入站" "8 分享链接 9 删除入站")
PANEL_DIAG=("10 查看日志 q 退出面板")

OS=""
TX=""
TX_MODE=""
TX_WAS_RUNNING=0
LOCK_HELD=0
TX_OWNS_LOCK=0
FOLLOW_PID=""
CONFLICT_TAG=""
PICKED=""
TMP_PATHS=()
RULE=""
STORE_REV=""

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
  if [[ -n $FOLLOW_PID ]]; then
    kill "$FOLLOW_PID" 2>/dev/null || true
    wait "$FOLLOW_PID" 2>/dev/null || true
  fi
  if [[ -n $TX ]]; then
    warn "操作中断，正在恢复修改前的状态。"
    rollback_tx || rc=1
  fi
  if ((${#TMP_PATHS[@]})); then
    for p in "${TMP_PATHS[@]}"; do
      [[ -z $p ]] || rm -rf -- "$p"
    done
  fi
  release_lock
  printf '%b' "$RST" >&4 2>/dev/null || true
  return "$rc"
}

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
  printf '  %bSING-BOX%b  /  %s\n' "$ACC$BOLD" "$RST" "$1" >&4
  uin "  ${DIM}${RULE}${RST}"
  blank
}

pause() {
  blank
  ui "  ${DIM}回车继续${RST}${GRN}"
  IFS= read -r _ </dev/tty || true
  ui $'\n'
}

trim_line() {
  local s=$1
  s=${s//$'\r'/}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

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

tty_read() {
  local -n _out=$1
  local _prompt=$2 _silent=${3:-} _ans
  if [[ -n $_silent ]]; then
    if ! IFS= read -r -s -p "$_prompt" _ans </dev/tty 2>&4; then
      ui $'\n'
      return 2
    fi
    ui $'\n'
  elif ! IFS= read -r -e -p "$_prompt" _ans </dev/tty 2>&4; then
    ui $'\n'
    return 2
  fi
  _out=$(trim_line "$_ans")
}

prompt() {
  local msg=$1 default=${2:-} hint=${3:-} silent=${4:-} ans p=""
  p=$(printf '\001%s\002  %s' "$GRN" "$msg")
  if [[ -n $default ]]; then
    p+=$(printf ' \001%s\002%s\001%s\002' "$DIM" "$default" "$GRN")
  fi
  if [[ -n $hint ]]; then
    p+=$(printf ' \001%s\002%s\001%s\002' "$DIM" "$hint" "$GRN")
  fi
  p+=$(printf ': ')
  tty_read ans "$p" "$silent" || return 2
  if [[ $ans == *[[:cntrl:]]* ]]; then
    err "输入不能包含控制字符。"
    return 2
  fi
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
  if [[ $OS == alpine ]]; then
    SERVICE_FILE=/etc/init.d/sing-box
  fi
}

asset_arch() {
  local machine
  case $(uname -m) in
    i386 | i686) machine=386 ;;
    amd64 | x86_64) machine=amd64 ;;
    armv5tel) machine=armv5 ;;
    armv6l | armv7 | armv7l)
      machine=armv7
      [[ $(uname -m) == armv6l ]] && machine=armv6
      grep -q ' vfp' /proc/cpuinfo 2>/dev/null || machine=armv5
      ;;
    armv8 | aarch64) machine=arm64 ;;
    mips) machine=mips-softfloat ;;
    mipsle) machine=mipsle ;;
    mips64)
      machine=mips64-softfloat
      if lscpu 2>/dev/null | grep -q 'Little Endian'; then
        machine=mips64le
      fi
      ;;
    mips64le) machine=mips64le ;;
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

# Debian 用带 cgo 的 glibc 包；Alpine 用 musl。没有对应产物的架构用实际上传的文件名。
release_asset_id() {
  local machine
  machine=$(asset_arch) || return 1
  if [[ $OS == alpine ]]; then
    case $machine in
      amd64 | arm64 | 386 | armv7 | riscv64 | loong64) machine+=-musl ;;
      mipsle) machine=mipsle-softfloat-musl ;;
    esac
  else
    case $machine in
      amd64 | arm64 | 386 | armv7 | mipsle | mips64le | riscv64 | loong64) machine+=-glibc ;;
    esac
  fi
  printf '%s' "$machine"
}

ensure_deps() {
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || pkgs+=(ca-certificates)
  command -v tar >/dev/null 2>&1 || pkgs+=(tar)
  command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  command -v sha256sum >/dev/null 2>&1 || pkgs+=(coreutils)
  command -v flock >/dev/null 2>&1 || pkgs+=(flock)
  command -v su >/dev/null 2>&1 || pkgs+=(util-linux)
  command -v logrotate >/dev/null 2>&1 || pkgs+=(logrotate)
  if ((${#pkgs[@]} == 0)); then
    return 0
  fi
  plainln "  安装依赖: ${pkgs[*]}"
  if [[ $OS == alpine ]]; then
    apk add -q --no-cache "${pkgs[@]}" ca-certificates >/dev/null 2>&1
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq -y >/dev/null 2>&1 || return 1
    # Debian 将 flock 与 su 一并放在 util-linux 中。
    local i
    for i in "${!pkgs[@]}"; do
      [[ ${pkgs[i]} == flock ]] && pkgs[i]=util-linux
    done
    apt-get install -qq -y --no-install-recommends "${pkgs[@]}" ca-certificates >/dev/null 2>&1
  fi
}

deps_ok() {
  ensure_deps || { err "依赖安装失败。"; pause; return 1; }
}

box_group_ok() {
  [[ $(id -gn sing-box 2>/dev/null) == sing-box ]]
}

create_box_user() {
  install -d -m 755 -o root -g root /var/empty || return 1
  if id -u sing-box >/dev/null 2>&1; then
    if [[ $(id -u sing-box) -eq 0 || $(id -g sing-box) -eq 0 ]]; then
      err "已有的 sing-box 账户不能是 root。"
      return 1
    fi
    if ! box_group_ok; then
      err "已有的 sing-box 账户必须以 sing-box 为主组。"
      return 1
    fi
    warn "已有 sing-box 用户，继续使用。"
    return 0
  fi
  if [[ $OS == debian ]] && command -v systemd-sysusers >/dev/null 2>&1; then
    plainln "  创建 sing-box 用户"
    systemd-sysusers - >/dev/null 2>&1 <<'EOF' || true
u sing-box - "sing-box" /var/empty
EOF
  elif [[ $OS == alpine ]]; then
    if ! grep -q '^sing-box:' /etc/group 2>/dev/null; then
      addgroup -S sing-box || return 1
    fi
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G sing-box -g "sing-box" sing-box || true
  else
    if ! getent group sing-box >/dev/null 2>&1; then
      groupadd --system sing-box || return 1
    fi
    useradd --system --gid sing-box --home-dir /var/empty --shell /usr/sbin/nologin --comment "sing-box" sing-box || true
  fi
  if ! id -u sing-box >/dev/null 2>&1; then
    err "无法创建 sing-box 用户。"
    return 1
  fi
  if [[ $(id -u sing-box) -eq 0 || $(id -g sing-box) -eq 0 ]] || ! box_group_ok; then
    err "sing-box 账户身份或主组不安全。"
    return 1
  fi
}

remove_box_user() {
  local uid="" gid=""
  if id -u sing-box >/dev/null 2>&1; then
    uid=$(id -u sing-box) || return 1
    gid=$(id -g sing-box) || return 1
    if [[ $uid == 0 || $gid == 0 ]]; then
      err "拒绝删除 root 账户。"
      return 1
    fi
    if [[ $OS == alpine ]]; then deluser sing-box; else userdel sing-box; fi || return 1
  fi
  if getent group sing-box >/dev/null 2>&1; then
    if [[ $OS == alpine ]]; then delgroup sing-box; else groupdel sing-box; fi || return 1
  fi
}

make_dir() {
  local mode=$1 owner=$2 group=$3 dir=$4
  if [[ -L $dir || ( -e $dir && ! -d $dir ) ]]; then
    err "拒绝使用非目录或符号链接: ${dir}"
    return 1
  fi
  install -d -m "$mode" -o "$owner" -g "$group" "$dir"
}

ensure_dirs() {
  local f
  # 只设置本程序创建的目录，不放宽 /var 或 /var/lib。
  make_dir 750 root sing-box "$STATE_DIR" || return 1
  make_dir 755 root root "${BIN%/*}" || return 1
  make_dir 700 root root "$META_DIR" || return 1
  make_dir 750 sing-box sing-box "$RUN_DIR" || return 1
  for f in "$CONF_DIR" "$LOG_DIR" "$CERT_DIR"; do
    make_dir 750 root sing-box "$f" || return 1
  done
  for f in "$STDOUT_LOG" "$STDERR_LOG"; do
    [[ ! -L $f && ( ! -e $f || -f $f ) ]] || return 1
    if [[ ! -e $f ]]; then
      install -m 600 -o sing-box -g sing-box /dev/null "$f" || return 1
    fi
    chown sing-box:sing-box "$f" && chmod 600 "$f" || return 1
  done
  fix_tree_perms
}

atomic_json() {
  local dest=$1 mode=$2 owner=$3 group=$4 dir tmp
  dir=$(dirname "$dest")
  if [[ ! -d $dir || -L $dest || ( -e $dest && ! -f $dest ) ]]; then
    return 1
  fi
  tmp=$(mktemp -p "$dir") || return 1
  # 非空、可解析，并在改名前定好属主和权限。
  if ! cat >"$tmp" || [[ ! -s $tmp ]] || ! jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null <"$tmp" \
    || ! chown "${owner}:${group}" "$tmp" || ! chmod "$mode" "$tmp" \
    || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

empty_config() {
  jq -n '{log:{level:"warn",timestamp:true},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}'
}

ensure_base_config() {
  [[ ! -L $CONF ]] || return 1
  if [[ -f $CONF ]]; then
    return 0
  fi
  empty_config | atomic_json "$CONF" 640 root sing-box
}

fix_tree_perms() {
  local f
  for f in "$CONF_DIR" "$LOG_DIR" "$STATE_DIR" "$CERT_DIR"; do
    [[ ! -L $f ]] || return 1
    [[ -d $f ]] || continue
    chown root:sing-box "$f" && chmod 750 "$f" || return 1
  done
  if [[ -d ${BIN%/*} && ! -L ${BIN%/*} ]]; then
    chown root:root "${BIN%/*}" && chmod 755 "${BIN%/*}" || return 1
  fi
  if [[ -d $META_DIR ]]; then
    [[ ! -L $META_DIR ]] || return 1
    chown root:root "$META_DIR" && chmod 700 "$META_DIR" || return 1
  fi
  for f in "$META_DIR"/*.json "$CERT_DIR"/* "$CONF"; do
    [[ ! -L $f ]] || { err "拒绝使用符号链接: ${f}"; return 1; }
    [[ -f $f ]] || continue
    if [[ $f == "$META_DIR/"* ]]; then
      chown root:root "$f" && chmod 600 "$f" || return 1
    else
      chown root:sing-box "$f" && chmod 640 "$f" || return 1
    fi
  done
}

gc_certs() {
  # 只删除本事务不再引用的证书。
  local meta f tag
  [[ -n $TX && -f $CONF ]] || return 0
  for meta in "$TX/meta"/*.json; do
    [[ -f $meta ]] || continue
    [[ ! -f $META_DIR/${meta##*/} ]] || continue
    tag=${meta##*/}; tag=${tag%.json}
    valid_tag "$tag" || return 1
    for f in "$CERT_DIR/${tag}.crt" "$CERT_DIR/${tag}.key"; do
      [[ -f $f && ! -L $f ]] || continue
      if jq -e --arg p "$f" 'any(.. | strings; . == $p)' "$CONF" >/dev/null; then
        continue
      fi
      rm -f -- "$f" || return 1
    done
  done
}

restore_tree() {
  local live=$1 snap=$2 f rel
  [[ -d $snap ]] || return 0
  if [[ ! -d $live || -L $live ]]; then
    rm -rf -- "$live" || return 1
    mkdir -p -- "$live" || return 1
  fi
  while IFS= read -r -d '' f; do
    rel=${f#"$live"/}
    if [[ -L $f || ( ! -e $snap/$rel && ! -L $snap/$rel ) \
      || ( -d $f && ! -d $snap/$rel ) || ( ! -d $f && -d $snap/$rel ) ]]; then
      rm -rf -- "$f" || return 1
    fi
  done < <(find "$live" -mindepth 1 -depth -print0)
  cp -a "$snap"/. "$live"/
}

store_revision() {
  local f
  for f in "$CONF" "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    sha256sum "$f" || return 1
  done | sha256sum
}

service_enabled() {
  if [[ $OS == alpine ]]; then
    [[ -L /etc/runlevels/default/sing-box ]]
  else
    systemctl is-enabled --quiet sing-box 2>/dev/null
  fi
}

disable_service() {
  if [[ $OS == alpine ]]; then
    if service_enabled; then
      rc-update del sing-box default
    fi
  else
    if service_enabled; then
      systemctl disable sing-box
    fi
  fi
}

tx_path() {
  case $1 in
    conf) printf '%s' "$CONF_DIR" ;;
    meta) printf '%s' "$META_DIR" ;;
    certs) printf '%s' "$CERT_DIR" ;;
    service) printf '%s' "$SERVICE_FILE" ;;
    logrotate) printf '%s' "$LOGROTATE_FILE" ;;
    *) return 1 ;;
  esac
}

snapshot_tx() {
  local key path
  [[ ! -L $STATE_DIR && ! -L ${BIN%/*} ]] || return 1
  if service_enabled; then
    touch "$TX/enabled" || return 1
  fi
  for key in conf meta certs service logrotate; do
    path=$(tx_path "$key") || return 1
    [[ ! -L $path ]] || { err "拒绝备份符号链接: ${path}"; return 1; }
    if [[ -e $path ]]; then
      cp -a -- "$path" "$TX/$key" || return 1
    fi
  done
  if [[ $TX_MODE == deploy ]]; then
    [[ ! -L $BIN && ( ! -e $BIN || -f $BIN ) ]] || return 1
    if [[ -e $BIN ]]; then
      cp -a -- "$BIN" "$TX/binary" || return 1
    fi
  fi
  if [[ -L $CMD_LINK && $(readlink -- "$CMD_LINK") == "$BIN" ]]; then
    cp -a -- "$CMD_LINK" "$TX/command" || return 1
  fi
  touch "$TX/ready"
}

acquire_lock() {
  [[ -z $TX ]] || { err "存在未恢复的事务: ${TX}"; return 1; }
  if ((LOCK_HELD)); then
    return 0
  fi
  command -v flock >/dev/null 2>&1 || { err "缺少 flock，无法安全修改。"; return 1; }
  [[ -d ${LOCK_FILE%/*} ]] || { err "缺少锁目录。"; return 1; }
  [[ ! -L $LOCK_FILE ]] || { err "锁文件不能是符号链接。"; return 1; }
  exec 9>"$LOCK_FILE" || return 1
  if ! flock -n 9; then
    exec 9>&-
    err "另一个面板正在操作，请稍后重试。"
    return 1
  fi
  LOCK_HELD=1
}

release_lock() {
  if ((LOCK_HELD)); then
    exec 9>&-
    LOCK_HELD=0
  fi
  TX_OWNS_LOCK=0
}

with_lock() {
  local rc=0
  acquire_lock || return 1
  "$@" || rc=$?
  [[ -n $TX ]] || release_lock
  return "$rc"
}

end_tx() {
  local saved=$TX owns=$TX_OWNS_LOCK
  TX=""
  TX_MODE=""
  TX_WAS_RUNNING=0
  TX_OWNS_LOCK=0
  [[ -z $saved ]] || rm -rf -- "$saved" || warn "临时快照未能删除: ${saved}"
  STORE_REV=$(store_revision) || STORE_REV=""
  if ((owns)); then
    release_lock
  fi
}

begin_tx() {
  local owns=0
  [[ -z $TX ]] || { err "已有未结束的事务。"; return 1; }
  if ! ((LOCK_HELD)); then
    acquire_lock || return 1
    owns=1
  fi
  # 与状态目录处于同一文件系统，卸载时可原子移走整个目录。
  TX=$(mktemp -d -p "${STATE_DIR%/*}" .sing-box-tx.XXXXXX) || { ((owns)) && release_lock; return 1; }
  TX_MODE=${1:-config}
  TX_OWNS_LOCK=$owns
  if [[ $TX_MODE == config && -n $STORE_REV && $STORE_REV != "$(store_revision)" ]]; then
    end_tx
    err "配置已被其他进程修改，请重新进入此菜单。"
    return 1
  fi
  TX_WAS_RUNNING=0
  is_running && TX_WAS_RUNNING=1
  if ! snapshot_tx; then
    end_tx
    return 1
  fi
}

rollback_tx() {
  local key path failed=0
  [[ -n $TX ]] || return 0
  if [[ ! -f $TX/ready ]]; then
    end_tx
    return
  fi
  if [[ -f $TX/service-touched ]] && { [[ ! -f $TX/service-stopped ]] || is_running; }; then
    if ! svc stop || is_running; then
      err "无法停止服务，快照保留在 ${TX}。请勿继续修改。"
      return 1
    fi
  fi
  if [[ -d $TX/state ]]; then
    if [[ -e $STATE_DIR || -L $STATE_DIR ]] || ! mv -- "$TX/state" "$STATE_DIR"; then
      err "无法恢复状态目录，快照保留在 ${TX}。"
      return 1
    fi
  fi
  if [[ ! -f $TX/enabled ]] && service_enabled; then
    disable_service || failed=1
  fi
  for key in conf meta certs service logrotate; do
    path=$(tx_path "$key") || return 1
    if [[ -d $TX/$key ]]; then
      restore_tree "$path" "$TX/$key" || failed=1
    elif [[ -f $TX/$key ]]; then
      cp -a -- "$TX/$key" "$path" || failed=1
    else
      rm -rf -- "$path" || failed=1
    fi
  done
  if [[ $TX_MODE == deploy ]]; then
    if [[ -f $TX/binary ]]; then
      make_dir 755 root root "${BIN%/*}" && place_binary "$TX/binary" || failed=1
    else
      rm -f -- "$BIN" || failed=1
    fi
  fi
  if [[ -L $TX/command ]]; then
    if [[ ! -e $CMD_LINK && ! -L $CMD_LINK ]]; then
      cp -a -- "$TX/command" "$CMD_LINK" || failed=1
    elif [[ ! -L $CMD_LINK || $(readlink -- "$CMD_LINK") != "$BIN" ]]; then
      failed=1
    fi
  elif [[ -f $TX/command-created ]]; then
    unlink_command || failed=1
  fi
  if [[ -f $TX/service-changed ]]; then
    if [[ $OS == debian ]]; then
      systemctl daemon-reload || failed=1
      if [[ -f $TX/enabled ]]; then
        systemctl enable sing-box >/dev/null 2>&1 || failed=1
      fi
    elif [[ -f $TX/enabled ]]; then
      rc-update add sing-box default >/dev/null 2>&1 || failed=1
    fi
  fi
  if ((failed == 0 && TX_WAS_RUNNING)) && [[ -f $TX/service-touched ]]; then
    kernel_stays_up restart || failed=1
  fi
  if ((failed)); then
    err "恢复不完整，快照保留在 ${TX}。请勿继续修改。"
    return 1
  fi
  end_tx
}

box_as_user() {
  local bin=$1 log=$2 conf=$3
  if ! id -u sing-box >/dev/null 2>&1 || ! command -v su >/dev/null 2>&1; then
    printf '%s\n' '缺少 sing-box 用户或 su，拒绝以 root 代替校验。' >"$log"
    return 1
  fi
  # 参数交给目标 shell 展开，不在当前 shell 拼接。
  # shellcheck disable=SC2016
  su -s /bin/sh -c 'exec "$1" check -c "$2"' sing-box sh "$bin" "$conf" >"$log" 2>&1
}

box_test() {
  local log
  log=$(mktemp) || return 1
  TMP_PATHS+=("$log")
  if [[ ! -x $BIN ]]; then
    err "未找到 sing-box，无法校验配置。"
    return 1
  fi
  if [[ ! -f $CONF ]]; then
    err "配置文件不存在。"
    return 1
  fi
  if box_as_user "$BIN" "$log" "$CONF"; then
    rm -f -- "$log"
    return 0
  fi
  err "配置校验失败:"
  cat "$log" >&4 || true
  rm -f -- "$log"
  ui "$GRN"
  return 1
}

service_pid() {
  local pid='' procs supervisor='' stat rest state ppid exe
  if [[ $OS == alpine ]]; then
    # supervise-daemon 的 PID 不是内核 PID；child_pid 可能没有结尾换行。
    [[ -r $PID_FILE && -r $OPENRC_DIR/options/sing-box/child_pid ]] || return 1
    supervisor=$(<"$PID_FILE")
    pid=$(<"$OPENRC_DIR/options/sing-box/child_pid")
    [[ $supervisor =~ ^[0-9]+$ ]] && ((supervisor > 1)) || return 1
    kill -0 "$supervisor" 2>/dev/null || return 1
  elif command -v systemctl >/dev/null 2>&1; then
    pid=$(systemctl show -p MainPID --value sing-box 2>/dev/null) || return 1
  else
    for procs in \
      /sys/fs/cgroup/system.slice/sing-box.service/cgroup.procs \
      /sys/fs/cgroup/systemd/system.slice/sing-box.service/cgroup.procs
    do
      [[ -r $procs ]] || continue
      IFS= read -r pid <"$procs" || return 1
      break
    done
  fi
  [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1)) || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  IFS= read -r stat 2>/dev/null <"/proc/$pid/stat" || return 1
  rest=${stat##*) }
  read -r state ppid _ <<<"$rest"
  [[ $state != Z && $state != X ]] || return 1
  [[ -z $supervisor || $ppid == "$supervisor" ]] || return 1
  if [[ ! /proc/$pid/exe -ef $BIN ]]; then
    exe=$(readlink -- "/proc/$pid/exe" 2>/dev/null) || return 1
    [[ $exe == "$BIN (deleted)" ]] || return 1
  fi
  printf '%s' "$pid"
}

is_running() { service_pid >/dev/null; }

# ^ 放入 ambient；! 从 bounding set 去掉。配合 no_new_privs，避免再通过文件能力提权。
alpine_iab() {
  local last=40 i caps
  if [[ -r /proc/sys/kernel/cap_last_cap ]]; then
    IFS= read -r last </proc/sys/kernel/cap_last_cap || last=40
  fi
  [[ $last =~ ^[0-9]+$ ]] || last=40
  ((last > 40)) && last=40
  caps='^cap_net_bind_service'
  for ((i = 0; i <= last; i++)); do
    ((i == 10)) && continue
    caps+=",!${i}"
  done
  printf '%s' "$caps"
}

service_uses_panel_conf() {
  [[ -f $SERVICE_FILE && ! -L $SERVICE_FILE ]] || return 1
  grep -qF 'sing-box-panel-v3' "$SERVICE_FILE" || return 1
  if [[ $OS == alpine ]]; then
    grep -qxF "command=\"$BIN\"" "$SERVICE_FILE" \
      && grep -qxF "command_args=\"run -c $CONF -D $RUN_DIR\"" "$SERVICE_FILE"
  else
    grep -qxF "ExecStart=$BIN run -c $CONF -D $RUN_DIR" "$SERVICE_FILE"
  fi
}

drop_file_caps() {
  local bin=$1
  [[ -f $bin ]] || return 0
  if command -v setcap >/dev/null 2>&1; then
    setcap -r "$bin" 2>/dev/null || true
  fi
}

install_service() {
  local caps
  [[ ! -L $SERVICE_FILE ]] || return 1
  [[ -z $TX ]] || touch "$TX/service-changed" || return 1
  if [[ $OS == alpine ]]; then
    if ! command -v rc-service >/dev/null 2>&1; then
      apk add -q --no-cache openrc >/dev/null 2>&1 || return 1
    fi
    caps=$(alpine_iab) || return 1
    cat >"$SERVICE_FILE" <<EOF || return 1
#!/sbin/openrc-run
# sing-box-panel-v3

description="sing-box Service"

supervisor=supervise-daemon
command="$BIN"
command_args="run -c $CONF -D $RUN_DIR"
command_user="sing-box:sing-box"
pidfile="/run/\${RC_SVCNAME}.pid"
no_new_privs=yes
capabilities="${caps}"
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
    chmod 755 "$SERVICE_FILE" || return 1
    rc-update add sing-box default >/dev/null 2>&1 || return 1
  else
    if ! command -v systemctl >/dev/null 2>&1; then
      err "Debian 需要 systemd。"
      return 1
    fi
    cat >"$SERVICE_FILE" <<EOF || return 1
# sing-box-panel-v3
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
User=sing-box
Group=sing-box
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
UMask=0077
ExecStart=$BIN run -c $CONF -D $RUN_DIR
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2s
LimitNPROC=10000
LimitNOFILE=infinity
# 元数据和证书不放进内核可写目录。
WorkingDirectory=$RUN_DIR
ProtectSystem=strict
ReadWritePaths=$RUN_DIR $LOG_DIR
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE" || return 1
    systemctl daemon-reload || return 1
    plainln "  设置开机启动"
    systemctl enable sing-box >/dev/null 2>&1 || return 1
  fi
  install_logrotate || return 1
  drop_file_caps "$BIN"
}

svc() {
  if [[ -n $TX && ( $1 == start || $1 == restart || $1 == stop ) ]]; then
    touch "$TX/service-touched" || return 1
    if [[ $1 != stop ]]; then
      rm -f -- "$TX/service-stopped" || return 1
    fi
  fi
  if [[ $OS == alpine ]]; then
    rc-service sing-box "$1" 9>&- || return $?
  else
    # 清掉上一轮限流，否则连续修改后无法再启动。
    if [[ $1 == start || $1 == restart ]]; then
      systemctl reset-failed sing-box >/dev/null 2>&1 || true
    fi
    systemctl "$1" sing-box 9>&- || return $?
  fi
  if [[ -n $TX && $1 == stop ]]; then
    touch "$TX/service-stopped" || return 1
  fi
}

kernel_stays_up() {
  local i pid previous='' stable=0
  svc "$1" || return 1
  # 最多等待 5 秒，要求同一个实际进程连续存活 2 秒。
  for ((i = 0; i < 50; i++)); do
    pid=$(service_pid) || pid=''
    if [[ -n $pid && $pid == "$previous" ]]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    previous=$pid
    ((stable >= 20)) && return 0
    sleep 0.1
  done
  return 1
}

show_service_log() {
  if [[ $OS == debian ]] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u sing-box -n 40 --no-pager >&4 || true
  fi
  if [[ -f $STDERR_LOG && -s $STDERR_LOG ]]; then
    plainln "  --- stderr ---"
    tail -n 40 "$STDERR_LOG" >&4 || true
  fi
  ui "$GRN"
}

abort_tx() {
  err "$1"
  rollback_tx && plainln "  已恢复修改前的文件与服务状态。"
  return 1
}

commit_tx() {
  if ! fix_tree_perms || ! box_test; then
    abort_tx "配置校验失败。"
    return 1
  fi
  if ! service_uses_panel_conf; then
    plainln "  正在更新服务..."
    install_service || { abort_tx "服务更新失败。"; return 1; }
  fi
  if ((TX_WAS_RUNNING)); then
    if ! kernel_stays_up restart; then
      show_service_log
      abort_tx "重启失败。"
      return 1
    fi
    plainln "  配置已生效，服务已重启。"
  else
    plainln "  配置已保存，服务未启动。主菜单选 3。"
  fi
  gc_certs || warn "部分闲置证书未能清理。"
  end_tx
}

current_version() {
  local line raw
  if [[ ! -x $BIN ]]; then
    printf '-'
    return
  fi
  IFS= read -r line < <("$BIN" version 2>/dev/null) || true
  raw=${line##* }
  raw=${raw#v}
  raw=${raw%%[^0-9.]*}
  if [[ -z $raw ]]; then
    printf '-'
    return
  fi
  printf 'v%s' "$raw"
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
  url=$(curl -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 \
    "https://github.com/${REPO}/releases/latest") || return 1
  tag=${url##*/}
  if [[ ! $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
  uin "  ${ACC}${BOLD}SING-BOX${RST}  ${DIM}服务与入站管理${RST}"
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

github_asset_sha() {
  local version=$1 name=$2 body
  body=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/releases/tags/${version}") || return 1
  printf '%s' "$body" | jq -r --arg n "$name" '
    .assets[]? | select(.name == $n) | .digest // ""
  ' | awk '
    BEGIN { found = 0 }
    /^sha256:/ {
      sub(/^sha256:/, "")
      print tolower($0)
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  '
}

download_release() {
  local version=$1 dest=$2 asset url name sum actual sha_pid
  asset=$(release_asset_id) || return 1
  name="sing-box-${version#v}-linux-${asset}.tar.gz"
  url="https://github.com/${REPO}/releases/download/${version}/${name}"
  plainln "  下载 ${url}"
  # 校验值与压缩包同时取，避免校验提示后再等一次 GitHub。
  github_asset_sha "$version" "$name" >"$dest/sha256" &
  sha_pid=$!
  if ! curl -fsSL --connect-timeout 10 --max-time 300 --retry 5 --retry-delay 2 -o "$dest/sing-box.tar.gz" "$url"; then
    kill "$sha_pid" 2>/dev/null || true
    wait "$sha_pid" 2>/dev/null || true
    err "下载失败，请检查网络。"
    return 1
  fi
  plainln "  校验 SHA256"
  if ! wait "$sha_pid"; then
    err "无法获取 SHA256。"
    return 1
  fi
  sum=$(tr -d '[:space:]' <"$dest/sha256")
  actual=$(sha256sum "$dest/sing-box.tar.gz" | awk '{print tolower($1)}')
  if [[ -z $sum || ${#sum} -ne 64 || $sum != "$actual" ]]; then
    err "SHA256 校验失败。"
    return 1
  fi
  plainln "  解压"
  mkdir -p "$dest/pack" || return 1
  # 仅将预期的可执行文件写到固定路径，不提取压缩包中的其他条目。
  if ! tar -xOzf "$dest/sing-box.tar.gz" "sing-box-${version#v}-linux-${asset}/sing-box" >"$dest/pack/sing-box"; then
    err "无法从压缩包读取 sing-box。"
    return 1
  fi
  chmod 755 "$dest/pack/sing-box" || return 1
  if ! "$dest/pack/sing-box" version >/dev/null 2>&1; then
    err "程序无法执行，请确认架构。"
    return 1
  fi
}

place_binary() {
  local src=$1 new
  [[ ! -L $BIN && ( ! -e $BIN || -f $BIN ) ]] || return 1
  new=$(mktemp -p "$(dirname "$BIN")" .sing-box.XXXXXX) || return 1
  if ! cp -- "$src" "$new" || ! chown root:root "$new" || ! chmod 755 "$new"; then
    rm -f -- "$new"
    return 1
  fi
  drop_file_caps "$new"
  if ! mv -f -- "$new" "$BIN"; then
    rm -f -- "$new"
    return 1
  fi
}

# 仅给 /var/lib 下的正式安装提供命令名，测试目录不写 /usr/local/bin。
link_command() {
  local link=$CMD_LINK target
  [[ $BIN == /var/lib/* && -d ${link%/*} && ! -L ${link%/*} ]] || return 0
  if [[ -L $link ]]; then
    target=$(readlink -- "$link") || return 1
    if [[ $target == "$BIN" ]]; then
      return 0
    fi
    warn "已有 ${link}，未覆盖。"
    return 0
  fi
  if [[ -e $link ]]; then
    warn "已有 ${link}，未覆盖。"
    return 0
  fi
  [[ -z $TX ]] || touch "$TX/command-created" || return 1
  ln -s -- "$BIN" "$link"
}

unlink_command() {
  local target
  [[ -L $CMD_LINK ]] || return 0
  target=$(readlink -- "$CMD_LINK") || return 1
  [[ $target == "$BIN" ]] || return 0
  rm -f -- "$CMD_LINK"
}

install_logrotate() {
  local dir=${LOGROTATE_FILE%/*}
  [[ ! -L $dir && ! -L $LOGROTATE_FILE ]] || return 1
  if [[ ! -d $dir ]]; then
    install -d -m 755 "$dir" || return 1
  fi
  cat >"$LOGROTATE_FILE" <<EOF || return 1
$LOG_DIR/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
    su root root
}
EOF
  chmod 644 "$LOGROTATE_FILE"
}

deploy_pack() {
  local src=$1
  create_box_user || return 1
  ensure_dirs || return 1
  place_binary "$src/sing-box" && link_command || return 1
  ensure_base_config || return 1
  rebuild_config || return 1
  fix_tree_perms && box_test || return 1
  install_service
}

apply_pack() {
  local src=$1
  begin_tx deploy || return 1
  if ! deploy_pack "$src"; then
    abort_tx "内核部署失败。"
    return 1
  fi
  if ((TX_WAS_RUNNING)) && ! kernel_stays_up restart; then
    show_service_log
    abort_tx "新内核未能保持运行。"
    return 1
  fi
  end_tx
}

resolve_latest() {
  local version
  plainln "  获取最新版本..."
  version=$(latest_version) || {
    err "无法获取版本，请检查到 GitHub 的网络。"
    pause
    return 1
  }
  plainln "  最新版本 ${version}"
  printf '%s' "$version"
}

stage_release() {
  local -n _dest=$1
  local version=$2 _stage_dir
  _stage_dir=$(mktemp -d) || { err "无法创建下载目录。"; pause; return 1; }
  TMP_PATHS+=("$_stage_dir")
  if ! download_release "$version" "$_stage_dir"; then
    rm -rf -- "$_stage_dir"
    pause
    return 1
  fi
  _dest=$_stage_dir
}

install_kernel() {
  local work version
  header "安装内核"
  if [[ -x $BIN ]]; then
    plainln "  已安装 $(current_version)，更新请选「升级内核」。"
    pause
    return 0
  fi
  deps_ok || return 0
  version=$(resolve_latest) || return 0
  stage_release work "$version" || return 0
  apply_pack "$work/pack" || { rm -rf -- "$work"; pause; return 0; }
  rm -rf -- "$work"
  blank
  plainln "  安装完成。"
  kv "版本" "$(current_version)"
  kv "程序" "$BIN"
  kv "配置" "$CONF"
  kv "日志" "$LOG_DIR"
  kv "用户" "sing-box"
  blank
  note "回到主菜单选 3 启动。"
  pause
}

upgrade_kernel() {
  local work version current cmp
  header "升级内核"
  if [[ ! -x $BIN ]]; then
    err "请先安装内核。"
    pause
    return 0
  fi
  deps_ok || return 0
  current=$(current_version)
  plainln "  当前版本 ${current}"
  version=$(resolve_latest) || return 0
  cmp=$(ver_cmp "$version" "$current")
  if [[ $cmp -le 0 ]]; then
    if [[ $cmp -eq 0 ]]; then
      plainln "  已是最新版本。"
    else
      warn "当前版本高于最新正式版。"
    fi
    confirm "是否仍要重新安装此版本？" || return 0
  fi
  stage_release work "$version" || return 0
  if [[ -f $CONF ]]; then
    plainln "  正在校验现有配置..."
    # 只开放目录执行位，不允许列出内容。
    chmod 711 "$work" "$work/pack" || { pause; return 0; }
    if ! box_as_user "$work/pack/sing-box" "$work/test.err" "$CONF"; then
      err "新版本无法加载当前配置，已取消升级。"
      cat "$work/test.err" >&4 || true
      rm -rf -- "$work"
      ui "$GRN"
      pause
      return 0
    fi
  fi
  if apply_pack "$work/pack"; then
    plainln "  已升级到 $(current_version)。"
    is_running || note "服务未启动，主菜单选 3。"
  fi
  rm -rf -- "$work"
  pause
}

start_kernel() {
  header "启动服务"
  if [[ ! -x $BIN ]]; then
    err "请先安装内核。"
    pause
    return 0
  fi
  deps_ok || return 0
  with_lock start_kernel_locked || true
}

start_kernel_locked() {
  if ! service_uses_panel_conf; then
    plainln "  正在更新服务..."
    begin_tx service || { pause; return 0; }
    if ! create_box_user || ! ensure_dirs || ! ensure_base_config || ! box_test || ! install_service; then
      abort_tx "服务修复失败。"
      pause
      return 0
    fi
    if ((TX_WAS_RUNNING)) && ! kernel_stays_up restart; then
      abort_tx "服务迁移失败。"
      pause
      return 0
    fi
    end_tx
  fi
  if is_running; then
    plainln "  服务已在运行。"
    pause
    return 0
  fi
  if ! box_test; then
    pause
    return 0
  fi
  if ! kernel_stays_up start; then
    err "启动失败。"
    show_service_log
    pause
    return 0
  fi
  plainln "  服务已启动。"
  pause
}

stop_kernel() {
  header "停止服务"
  acquire_lock || { pause; return 0; }
  if ! is_running; then
    release_lock
    plainln "  服务未在运行。"
    pause
    return 0
  fi
  if ! svc stop || is_running; then
    err "停止失败。"
    release_lock
    pause
    return 0
  fi
  release_lock
  plainln "  服务已停止。"
  pause
}

uninstall_kernel() {
  header "卸载内核"
  if [[ ! -x $BIN && ! -e $CONF_DIR && ! -e $STATE_DIR && ! -e $LOG_DIR && ! -f $SERVICE_FILE ]]; then
    note "内核未安装。"; pause; return 0
  fi
  note "将删除内核、配置、证书、日志和用户。"
  confirm "确认卸载？" || return 0
  with_lock uninstall_kernel_locked || true
  pause
}

uninstall_kernel_locked() {
  local path
  begin_tx deploy || return 1
  if { [[ -f $SERVICE_FILE ]] || ((TX_WAS_RUNNING)); } && { ! svc stop || is_running; }; then
    abort_tx "无法停止服务，已取消卸载。"; return 1
  fi
  touch "$TX/service-changed" || return 1
  if ! disable_service; then
    abort_tx "无法取消开机启动。"; return 1
  fi
  for path in "$STATE_DIR" "$CONF_DIR" "$META_DIR" "$CERT_DIR" "$LOG_DIR" "${BIN%/*}"; do
    if [[ -L $path ]]; then
      abort_tx "拒绝删除符号链接: ${path}"; return 1
    fi
  done
  if ! rm -f -- "$SERVICE_FILE" "$LOGROTATE_FILE"; then
    abort_tx "无法删除服务文件。"; return 1
  fi
  if [[ $OS == debian ]] && ! systemctl daemon-reload; then
    abort_tx "无法重载服务管理器。"; return 1
  fi
  # 整个目录原子移入快照，失败或中断时仍可恢复日志及运行数据。
  if [[ -d $STATE_DIR ]] && ! mv -- "$STATE_DIR" "$TX/state"; then
    abort_tx "无法移除状态目录。"; return 1
  fi
  unlink_command || { abort_tx "命令链接未删除。"; return 1; }
  end_tx
  remove_box_user || warn "账户或组未完全删除。"
  plainln "  卸载完成。"
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
  header "实时日志"
  note "Ctrl+C 返回"
  blank
  if [[ $OS == debian ]]; then
    journalctl -u sing-box -n 20 -f --no-pager >&4 &
  elif [[ -f $STDERR_LOG ]]; then
    tail -n 20 -f -- "$STDERR_LOG" >&4 &
  else
    note "暂无日志。"
    pause
    return 0
  fi
  FOLLOW_PID=$!
  trap 'kill "$FOLLOW_PID" 2>/dev/null || true' INT
  wait "$FOLLOW_PID" 2>/dev/null || true
  FOLLOW_PID=""
  trap 'exit 130' INT
  ui "$RST"
  ui $'\n'
}

view_logs() {
  local choice
  while true; do
    choice=$(choose "日志" "返回" "最近服务日志" "实时跟踪" "标准输出日志（OpenRC）") || return 0
    case $choice in
      1) header "服务日志"; show_service_log; pause ;;
      2) follow_log ;;
      3) show_file "标准输出日志" "$STDOUT_LOG" ;;
    esac
  done
}

uses_tcp() {
  local proto=$1 net=$2
  if [[ $proto == hysteria2 || $proto == tuic ]]; then
    return 1
  fi
  if [[ $proto == shadowsocks && -n $net && $net != *tcp* ]]; then
    return 1
  fi
  return 0
}

uses_udp() {
  local proto=$1 net=$2
  if [[ $proto == hysteria2 || $proto == tuic ]]; then
    return 0
  fi
  if [[ $proto == shadowsocks && ( -z $net || $net == *udp* ) ]]; then
    return 0
  fi
  return 1
}

canon_ipv4() {
  local ip=$1 o1 o2 o3 o4
  is_ipv4 "$ip" || return 1
  IFS=. read -r o1 o2 o3 o4 <<<"$ip"
  printf '%d.%d.%d.%d' "$((10#$o1))" "$((10#$o2))" "$((10#$o3))" "$((10#$o4))"
}

canon_ipv6() {
  local ip=${1,,} left right i g hex best=-1 bestlen=0 zeros=-1 zlen=0
  local -a L=() R=() G=()
  is_ipv6 "$ip" || return 1
  if [[ $ip == *::* ]]; then
    left=${ip%%::*}
    right=${ip#*::}
    if [[ -n $left ]]; then
      IFS=: read -r -a L <<<"$left"
    fi
    if [[ -n $right ]]; then
      IFS=: read -r -a R <<<"$right"
    fi
    if ((${#L[@]})); then
      for g in "${L[@]}"; do
        G+=("$((16#$g))")
      done
    fi
    for ((i = ${#L[@]} + ${#R[@]}; i < 8; i++)); do
      G+=(0)
    done
    if ((${#R[@]})); then
      for g in "${R[@]}"; do
        G+=("$((16#$g))")
      done
    fi
  else
    IFS=: read -r -a L <<<"$ip"
    for g in "${L[@]}"; do
      G+=("$((16#$g))")
    done
  fi
  [[ ${#G[@]} -eq 8 ]] || return 1
  for ((i = 0; i < 8; i++)); do
    if ((G[i] == 0)); then
      if ((zeros < 0)); then
        zeros=$i
        zlen=1
      else
        zlen=$((zlen + 1))
      fi
      if ((zlen > bestlen)); then
        best=$zeros
        bestlen=$zlen
      fi
    else
      zeros=-1
      zlen=0
    fi
  done
  ((bestlen < 2)) && best=-1
  local out=""
  for ((i = 0; i < 8; i++)); do
    if ((best >= 0 && i >= best && i < best + bestlen)); then
      if ((i == best)); then
        out+="::"
      fi
      continue
    fi
    printf -v hex '%x' "${G[i]}"
    if [[ -z $out || $out == *: ]]; then
      out+="$hex"
    else
      out+=":$hex"
    fi
  done
  printf '%s' "$out"
}

canon_listen() {
  local ip=$1
  if [[ $ip == \[*\] ]]; then
    ip=${ip#\[}
    ip=${ip%\]}
  fi
  if is_ipv4 "$ip"; then
    canon_ipv4 "$ip"
  elif is_ipv6 "$ip"; then
    canon_ipv6 "$ip"
  else
    return 1
  fi
}

listen_clash() {
  local a b
  a=$(canon_listen "$1") || return 0
  b=$(canon_listen "$2") || return 0
  [[ $a == "$b" || $a == :: || $b == :: ]] && return 0
  # IPv4 通配监听不会占用一个独立 IPv6 地址。
  [[ $a == 0.0.0.0 && $b != *:* || $b == 0.0.0.0 && $a != *:* ]]
}

endpoint_hits() {
  local port=$1 except=$2 listen=$3 nt=$4 nu=$5 etag=$6 eproto=$7 enet=$8 ep=$9 elisten=${10}
  local ct=0 cu=0
  [[ -n $ep && $ep != null && $ep == "$port" ]] || return 1
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
    etag=$(jq -r '.tag' "$f")
    ep=$(jq -r '.port' "$f")
    eproto=$(jq -r '.protocol' "$f")
    enet=$(jq -r '.network // ""' "$f")
    elisten=$(jq -r '.listen // "0.0.0.0"' "$f")
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
    done < <(jq -rj '.inbounds[]? | ["x", "." + (if (.tag // "") == "" then "config.json" else .tag end), .type // "", (.network // ""), (.listen_port | tostring), (.listen // "0.0.0.0")] | join("\u001f") + "\n"' "$CONF" 2>/dev/null || true)
  fi
  return 1
}

is_domain() {
  [[ ${#1} -le 253 && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
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
    if [[ $ans == \[*\] ]]; then
      ans=${ans#\[}
      ans=${ans%\]}
    fi
    if is_ipv4 "$ans" || is_ipv6 "$ans"; then
      canon_listen "$ans"
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
    if [[ -z $ans || ${#ans} -gt 80 || $ans == *[[:cntrl:]]* ]]; then
      err "备注须为 1–80 个字符，不能包含控制字符。"
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
    if [[ $ans == \[*\] ]]; then
      ans=${ans#\[}
      ans=${ans%\]}
    fi
    host=$ans
    tport=443
    if ! is_ipv6 "$ans" && [[ $ans =~ ^([A-Za-z0-9.-]+):([0-9]+)$ ]]; then
      host=${BASH_REMATCH[1]}
      tport=${BASH_REMATCH[2]}
      if [[ ${#tport} -gt 5 ]] || ((10#$tport < 1 || 10#$tport > 65535)); then
        err "端口不合法。"
        continue
      fi
    fi
    if [[ $mode == domain ]]; then
      if [[ $host =~ [A-Za-z] ]] && is_domain "$host"; then
        printf '%s\n%s' "$host" "$((10#$tport))"
        return 0
      fi
      err "请输入域名，例如 www.microsoft.com，不要用 CDN。"
      continue
    fi
    if is_ipv4 "$host" || is_ipv6 "$host" || is_domain "$host"; then
      printf '%s\n%s' "$host" "$((10#$tport))"
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
  if [[ $ans =~ ^[0-9]{1,3}$ ]] && ((10#$ans >= 1 && 10#$ans <= max)); then
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
    next_choice choice msg "${#rows[@]}" "$hint"
    rc=$?
    case $rc in
      0) printf '%s' "$choice"; return 0 ;;
      1) ;;
      *) return "$rc" ;;
    esac
  done
}

choose() {
  local title=$1 hint=$2
  shift 2
  choice_menu items "$title" "$hint" '' "$@"
}

next_choice() {
  local _var=$1 _msg=$2 _choice _rc
  _choice=$(ask_choice "$3" "$4")
  _rc=$?
  case $_rc in
    0)
      printf -v "$_var" '%s' "$_choice"
      printf -v "$_msg" '%s' ""
      ;;
    4) printf -v "$_msg" '%s' "无效选项。" ;;
    5) printf -v "$_msg" '%s' "" ;;
    *) return "$_rc" ;;
  esac
  return "$((_rc == 0 ? 0 : 1))"
}

method_name() {
  case $1 in
    1) printf '2022-blake3-aes-128-gcm' ;;
    2) printf '2022-blake3-aes-256-gcm' ;;
    3) printf '2022-blake3-chacha20-poly1305' ;;
    4) printf 'aes-128-gcm' ;;
    5) printf 'aes-256-gcm' ;;
    6) printf 'chacha20-ietf-poly1305' ;;
    *) return 1 ;;
  esac
}

ask_congestion() {
  local choice
  choice=$(choose "拥塞控制" "取消" "bbr" "cubic" "new_reno") || return $?
  case $choice in
    2) printf 'cubic' ;;
    3) printf 'new_reno' ;;
    *) printf 'bbr' ;;
  esac
}

ask_method() {
  local choice
  choice=$(choose "加密方式" "取消" \
    "2022-blake3-aes-128-gcm    推荐" \
    "2022-blake3-aes-256-gcm" \
    "2022-blake3-chacha20-poly1305" \
    "aes-128-gcm" \
    "aes-256-gcm" \
    "chacha20-ietf-poly1305") || return $?
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

ss_key_bytes() {
  case $1 in
    2022-blake3-aes-128-gcm) printf '16' ;;
    2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305) printf '32' ;;
    *) return 1 ;;
  esac
}

gen_ss_password() {
  local need
  if need=$(ss_key_bytes "$1"); then
    openssl rand -base64 "$need" | tr -d '\n'
  else
    openssl rand -base64 24 | tr -d '\n'
  fi
}

gen_uuid() {
  if [[ -x $BIN ]]; then
    "$BIN" generate uuid | tr -d '[:space:]'
  else
    cat /proc/sys/kernel/random/uuid | tr -d '[:space:]'
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
  out=$("$BIN" generate reality-keypair 2>&1 | tr -d '\r') || return 1
  priv=$(printf '%s\n' "$out" | awk '/[Pp]rivate[Kk]ey/{print $NF; exit}')
  pub=$(printf '%s\n' "$out" | awk '/[Pp]ublic[Kk]ey/{print $NF; exit}')
  if [[ -z $priv || -z $pub ]]; then
    err "无法解析 sing-box generate reality-keypair 输出。"
    return 1
  fi
  printf '%s\n%s\n' "$priv" "$pub"
}

is_uuid() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

mint_secret() {
  if [[ $1 == uuid ]]; then
    gen_uuid
  elif [[ -n $2 ]]; then
    gen_ss_password "$2"
  else
    gen_auth
  fi
}

emit_secret() {
  local kind=$1 method=$2 value=$3 canon
  if [[ $kind == password && -n $method ]]; then
    if ! canon=$(ss_key_canon "$method" "$value"); then
      return 1
    fi
    if [[ -n $canon ]]; then
      printf '%s' "$canon"
      return 0
    fi
  fi
  printf '%s' "$value"
}

ask_secret() {
  local label=$1 current=$2 kind=$3 method=$4 ans
  while true; do
    if [[ -n $current ]]; then
      ans=$(prompt "$label" "" "回车保留，g 重新生成，q 取消" secret) || return 2
    else
      ans=$(prompt "$label" "" "回车生成，q 取消" secret) || return 2
    fi
    cancelled "$ans" && return 2
    if [[ -z $ans ]]; then
      if [[ -n $current ]]; then
        if ! emit_secret "$kind" "$method" "$current"; then
          err "密码长度不符，请输入 g 重新生成。"
          continue
        fi
      else
        mint_secret "$kind" "$method" || return 1
      fi
      return 0
    fi
    if is_regen "$ans"; then
      mint_secret "$kind" "$method" || return 1
      return 0
    fi
    if [[ $kind == uuid ]]; then
      if is_uuid "$ans"; then
        printf '%s' "$ans"
        return 0
      fi
      err "请输入标准 UUID，或留空生成。"
      continue
    fi
    if [[ $kind == password ]] && ! secret_text_ok "$ans"; then
      err "密码须为 1–256 个字符，不能为 null 或包含控制字符。"
      continue
    fi
    if ! emit_secret "$kind" "$method" "$ans"; then
      err "密码长度与加密方式不匹配。"
      continue
    fi
    return 0
  done
}

ask_uuid() { ask_secret UUID "$1" uuid ""; }
ask_password() { ask_secret "$1" "$2" password "${3:-}"; }

ask_reality_keys() {
  local cur_priv=$1 cur_pub=$2 cur_sid=$3 ans
  if [[ -n $cur_priv && -n $cur_pub ]]; then
    while true; do
      ans=$(prompt "REALITY 密钥" "" "回车保留，g 重新生成，q 取消") || return 2
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
  sid=$(gen_shortid) || return 1
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

copy_cert_pair() {
  local tag=$1 src_crt=$2 src_key=$3 crt key staged cert_pub key_pub
  valid_tag "$tag" || return 1
  if [[ ! -f $src_crt || ! -r $src_crt || ! -f $src_key || ! -r $src_key ]]; then
    err "证书或私钥不可读。"
    return 1
  fi
  make_dir 750 root sing-box "$CERT_DIR" || return 1
  staged=$(mktemp -d -p "$CERT_DIR") || return 1
  if ! install -m 640 -o root -g sing-box "$src_crt" "$staged/cert" \
    || ! install -m 640 -o root -g sing-box "$src_key" "$staged/key"; then
    rm -rf -- "$staged"
    return 1
  fi
  cert_pub=$(openssl x509 -in "$staged/cert" -pubkey -noout 2>/dev/null) || cert_pub=""
  key_pub=$(openssl pkey -in "$staged/key" -passin pass: -pubout 2>/dev/null) || key_pub=""
  if [[ -z $cert_pub || $cert_pub != "$key_pub" ]] \
    || ! openssl x509 -in "$staged/cert" -checkend 0 -noout >/dev/null 2>&1; then
    rm -rf -- "$staged"
    err "证书已过期、与私钥不匹配，或私钥需要密码。"
    return 1
  fi
  crt=$CERT_DIR/${tag}.crt
  key=$CERT_DIR/${tag}.key
  if [[ -L $crt || -L $key || -d $crt || -d $key ]] || ! mv -f -- "$staged/cert" "$crt" || ! mv -f -- "$staged/key" "$key"; then
    rm -rf -- "$staged"
    return 1
  fi
  rmdir "$staged"
  printf '%s\n%s\n' "$crt" "$key"
}

materialize_cert() {
  local tag=$1 mode=$2 src_crt=$3 src_key=$4
  if [[ $mode == keep ]]; then
    printf '%s\n%s\n' "$src_crt" "$src_key"
    return 0
  fi
  copy_cert_pair "$tag" "$src_crt" "$src_key"
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

meta_doc() {
  jq -n --argjson extra "$(cat)" \
    '{tag:"",remark:"",protocol:"",listen:"",port:0,
      network:"",method:"",password:"",uuid:"",flow:"",
      security:"",sni:"",target:"",targetPort:443,privateKey:"",publicKey:"",shortId:"",
      fingerprint:"chrome",auth:"",certFile:"",keyFile:"",insecure:false} + $extra'
}

meta_ss() {
  jq -n \
    --arg tag "$1" --arg remark "$2" --arg listen "$3" \
    --argjson port "$4" --arg method "$5" --arg network "$7" \
    '{tag:$tag,remark:$remark,protocol:"shadowsocks",listen:$listen,port:$port,
      network:$network,method:$method,password:""}' | meta_doc \
    | jq --rawfile password <(printf '%s' "$6") '.password = ($password | rtrimstr("\n"))'
}

meta_vless() {
  jq -n \
    --arg tag "$1" --arg remark "$2" --arg listen "$3" --argjson port "$4" \
    --arg flow "$6" --arg sni "$7" \
    --arg target "$8" --argjson targetPort "$9" --arg pub "${11}" --arg sid "${12}" \
    '{tag:$tag,remark:$remark,protocol:"vless",listen:$listen,port:$port,
      network:"tcp",uuid:"",flow:$flow,security:"reality",sni:$sni,
      target:$target,targetPort:$targetPort,privateKey:"",publicKey:$pub,shortId:$sid}' | meta_doc \
    | jq --rawfile uuid <(printf '%s' "$5") --rawfile priv <(printf '%s' "${10}") \
      '.uuid = ($uuid | rtrimstr("\n")) | .privateKey = ($priv | rtrimstr("\n"))'
}

meta_hy() {
  local insecure=false
  [[ $9 == 1 ]] && insecure=true
  jq -n \
    --arg tag "$1" --arg remark "$2" --arg listen "$3" --argjson port "$4" \
    --arg sni "$6" --arg cert "$7" --arg key "$8" \
    --argjson insecure "$insecure" \
    '{tag:$tag,remark:$remark,protocol:"hysteria2",listen:$listen,port:$port,
      network:"udp",security:"tls",sni:$sni,auth:"",
      certFile:$cert,keyFile:$key,insecure:$insecure}' | meta_doc \
    | jq --rawfile auth <(printf '%s' "$5") '.auth = ($auth | rtrimstr("\n"))'
}

meta_tuic() {
  local insecure=false
  is_uuid "$5" || return 1
  [[ -n $6 && $6 != *$'\n'* && ${11} =~ ^(bbr|cubic|new_reno)$ ]] || return 1
  [[ ${10} == 1 ]] && insecure=true
  jq -n \
    --arg tag "$1" --arg remark "$2" --arg listen "$3" --argjson port "$4" \
    --arg sni "$7" --arg cert "$8" --arg key "$9" \
    --arg congestion "${11}" \
    --argjson insecure "$insecure" \
    '{tag:$tag,remark:$remark,protocol:"tuic",listen:$listen,port:$port,
      network:"udp",security:"tls",uuid:"",password:"",sni:$sni,
      certFile:$cert,keyFile:$key,insecure:$insecure,congestion:$congestion}' | meta_doc \
    | jq --rawfile uuid <(printf '%s' "$5") --rawfile password <(printf '%s' "$6") \
      '.uuid = ($uuid | rtrimstr("\n")) | .password = ($password | rtrimstr("\n"))'
}

render_inbound() {
  jq '
    def tls_cert:
      {enabled:true, certificate_path:.certFile, key_path:.keyFile}
      + (if (.sni | length) > 0 and .sni != "null"
            and ((.sni | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")) or (.sni | test(":")))
         then {} else {server_name:.sni} end);
    if .protocol == "shadowsocks" then
      {type:"shadowsocks", tag:.tag, listen:.listen, listen_port:.port,
        method:.method, password:.password}
      + (if .network == "tcp" or .network == "udp" then {network:.network} else {} end)
    elif .protocol == "vless" then
      . as $m
      | {type:"vless", tag:$m.tag, listen:$m.listen, listen_port:$m.port,
          users:[
            {name:$m.tag, uuid:$m.uuid}
            + (if ($m.flow | length) > 0 and $m.flow != "null" then {flow:$m.flow} else {} end)
          ],
          tls:{enabled:true, server_name:$m.sni,
            reality:{enabled:true,
              handshake:{server:$m.target, server_port:$m.targetPort},
              private_key:$m.privateKey, short_id:[$m.shortId]}}}
    elif .protocol == "hysteria2" then
      . as $m
      | {type:"hysteria2", tag:$m.tag, listen:$m.listen, listen_port:$m.port,
          users:[{name:$m.tag, password:$m.auth}],
          tls:($m | tls_cert | . + {alpn:["h3"]}),
          masquerade:{type:"string",status_code:404,content:"404 not found"}}
    elif .protocol == "tuic" then
      . as $m
      | {type:"tuic", tag:$m.tag, listen:$m.listen, listen_port:$m.port,
          users:[{name:$m.tag, uuid:$m.uuid, password:$m.password}],
          congestion_control:$m.congestion,
          tls:($m | tls_cert | . + {alpn:["h3"]})}
    else
      error("unknown protocol")
    end
  '
}

valid_tag() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$ ]]
}

ss_method_ok() {
  case $1 in
    2022-blake3-aes-128-gcm | 2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305 | \
      aes-128-gcm | aes-256-gcm | chacha20-ietf-poly1305) return 0 ;;
    *) return 1 ;;
  esac
}

secret_text_ok() {
  local s=$1
  [[ -n $s && $s != null && ${#s} -le 256 && $s != *[[:cntrl:]]* ]]
}

panel_cert_ok() {
  local tag=$1 ext=$2 path=$3
  [[ $path == "$CERT_DIR/${tag}.${ext}" && -f $path && ! -L $path ]]
}

reality_key_ok() {
  ss_key_canon 2022-blake3-aes-256-gcm "$1" >/dev/null
}

validate_meta() {
  local file=$1 tag proto listen method password uuid flow sni target priv pub sid auth cert key
  [[ -f $file && ! -L $file ]] || return 1
  tag=${file##*/}
  tag=${tag%.json}
  valid_tag "$tag" || return 1
  jq -se --arg tag "$tag" '
    def text: type == "string" and (test("[\u0000-\u001f\u007f-\u009f]") | not);
    length == 1 and (.[0] |
      type == "object" and .tag == $tag
      and (.port | type == "number" and . == floor and . >= 1 and . <= 65535)
      and (.listen | text)
      and (.remark | text and length >= 1 and length <= 80)
      and (if .protocol == "shadowsocks" then
        (.network == "tcp" or .network == "udp" or .network == "tcp,udp")
        and (.method | text) and (.password | text)
      elif .protocol == "vless" then
        ([.uuid, .sni, .target, .privateKey, .publicKey, (.shortId // ""), (.flow // "")] | all(.[]; text))
        and (.targetPort | type == "number" and . == floor and . >= 1 and . <= 65535)
      elif .protocol == "hysteria2" or .protocol == "tuic" then
        ([.sni, .certFile, .keyFile] | all(.[]; text))
        and (.insecure | type == "boolean")
        and (if .protocol == "hysteria2" then (.auth | text)
          else (.uuid | text) and (.password | text)
            and (.congestion == "bbr" or .congestion == "cubic" or .congestion == "new_reno") end)
      else false end))
  ' "$file" >/dev/null || return 1
  load_plain "$file" proto=protocol listen method password uuid flow sni \
    target priv=privateKey pub=publicKey sid=shortId auth cert=certFile key=keyFile || return 1
  canon_listen "$listen" >/dev/null || return 1
  case $proto in
    shadowsocks)
      ss_method_ok "$method" && secret_text_ok "$password" && ss_key_ok "$method" "$password"
      ;;
    vless)
      is_uuid "$uuid" || return 1
      [[ -z $flow || $flow == xtls-rprx-vision ]] || return 1
      host_ok "$sni" && host_ok "$target" || return 1
      reality_key_ok "$priv" && reality_key_ok "$pub" || return 1
      [[ $sid =~ ^([0-9a-fA-F]{2}){0,8}$ ]]
      ;;
    hysteria2 | tuic)
      host_ok "$sni" || return 1
      panel_cert_ok "$tag" crt "$cert" && panel_cert_ok "$tag" key "$key" || return 1
      if [[ $proto == hysteria2 ]]; then
        secret_text_ok "$auth"
      else
        is_uuid "$uuid" && secret_text_ok "$password"
      fi
      ;;
  esac
}

rebuild_config() {
  local staged
  staged=$(mktemp -d) || return 1
  # 密钥经临时文件传递，不进入进程参数。
  if ! build_config_parts "$staged"; then
    rm -rf -- "$staged"
    return 1
  fi
  if ! jq -s --slurpfile ins "$staged/inbounds" --slurpfile owned "$staged/owned" '
    .[0]
    | .log = (.log // {level:"warn",timestamp:true})
    | .outbounds = (if (.outbounds | type) == "array" and (.outbounds | length) > 0
                    then .outbounds else [{type:"direct",tag:"direct"}] end)
    | .inbounds = ([.inbounds[]? | select(.tag as $t | $owned | index($t) | not)] + $ins)
  ' "$staged/base" | atomic_json "$CONF" 640 root sing-box; then
    rm -rf -- "$staged"
    return 1
  fi
  rm -rf -- "$staged"
}

build_config_parts() {
  local staged=$1 f tag
  : >"$staged/inbounds"
  : >"$staged/owned"
  for f in "$META_DIR"/*.json; do
    validate_meta "$f" || { err "元数据不合法: ${f}"; return 1; }
    render_inbound <"$f" >>"$staged/inbounds" || return 1
    jq '.tag' "$f" >>"$staged/owned" || return 1
  done
  # 删除时也要清掉事务开始前属于面板的 tag。
  if [[ -n $TX ]]; then
    for f in "$TX/meta"/*.json; do
      # 旧元数据仅用于移除原 tag，不依赖已被替换的证书。
      tag=${f##*/}; tag=${tag%.json}
      valid_tag "$tag" || return 1
      jq -n --arg tag "$tag" '$tag' >>"$staged/owned" || return 1
    done
  fi
  if [[ -f $CONF ]]; then
    jq -se 'length == 1 and (.[0] | type == "object" and ((.inbounds // []) | type == "array"))' "$CONF" >/dev/null || return 1
    cp -- "$CONF" "$staged/base"
  else
    empty_config >"$staged/base"
  fi
}

save_meta_and_inbound() {
  local tag=$1 meta_json
  valid_tag "$tag" || return 1
  meta_json=$(cat)
  if [[ -z $meta_json ]] || ! printf '%s' "$meta_json" | jq -e . >/dev/null; then
    return 1
  fi
  printf '%s' "$meta_json" | atomic_json "$META_DIR/${tag}.json" 600 root root || return 1
  rebuild_config
}

list_meta_files() {
  local f
  for f in "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    validate_meta "$f" || { err "跳过损坏的元数据: ${f}"; continue; }
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
    tuic) printf 'TUIC v5' ;;
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
  STORE_REV=$(store_revision) || return 1
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
    hysteria2 | tuic) plainln "  请放行 UDP ${port}。" ;;
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

finish_inbound() {
  local tag=$1 proto=$2 port=$3 network
  printf '%s' "$4" | save_meta_and_inbound "$tag" || { rollback_tx; err "写入失败。"; pause; return 1; }
  commit_tx || { pause; return 1; }
  network=$(printf '%s' "$4" | jq -r '.network // ""')
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

take_cert() {
  local cert_pack rc=0
  cert_pack=$(ask_cert "$@") || rc=$?
  if ((rc)); then
    [[ $rc -eq 1 ]] && pause
    return "$rc"
  fi
  load_cert_fields "$cert_pack"
}

ask_fresh_cert() {
  local _dest=$1 name_pack host
  name_pack=$(ask_name "证书域名或 IP" "" name) || return $?
  read_fields "$name_pack" host
  take_cert "$host" "" "" 1 || return $?
  printf -v "$_dest" '%s' "$host"
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

install_chosen_cert() {
  local paths src_crt src_key
  src_crt=$cert
  src_key=$key
  paths=$(materialize_cert "$1" "$cert_mode" "$src_crt" "$src_key") || return 1
  read_fields "$paths" cert key
  drop_temp_cert "$cert_mode" "$src_crt"
  cert_mode=keep
}

stage_chosen_cert() {
  install_chosen_cert "$1" || {
    rollback_tx
    drop_temp_cert "${cert_mode:-}" "${cert:-}"
    err "证书写入失败。"
    pause
    return 1
  }
}

load_plain() {
  local _load_file=$1 _load_values _load_spec
  local -a _load_names=()
  shift
  for _load_spec in "$@"; do
    _load_names+=("${_load_spec%%=*}")
  done
  _load_values=$(jq -r --arg fields "$*" '
    . as $doc | $fields | split(" ")[] | split("=") | $doc[.[-1]]
    | if . == null then "" else . end
  ' "$_load_file") || return 1
  read_fields "$_load_values" "${_load_names[@]}"
}

meta_write_error() {
  [[ -z $TX ]] || rollback_tx
  err "写入失败。"
  pause
  return 1
}

finish_doc() {
  local tag=$1 proto=$2 port=$3 doc=$4
  if [[ -z $doc ]]; then
    meta_write_error
    return
  fi
  finish_inbound "$tag" "$proto" "$port" "$doc"
}

ask_bind() {
  local proto=$1 network=$2 prefix=$3 port_default=$4
  local listen port tag remark
  listen=$(ask_listen "0.0.0.0") || return $?
  if [[ $proto == shadowsocks ]]; then
    network=$(ask_ss_network) || return $?
  fi
  port=$(ask_port "$port_default" "" "$proto" "$network" "$listen") || return $?
  tag=$(new_tag "$prefix" "$port")
  remark=$(ask_remark "${prefix}-${port}") || return $?
  printf '%s\n%s\n%s\n%s\n%s' "$listen" "$port" "$tag" "$remark" "$network"
}

open_new() {
  confirm_write || return 1
  need_tx || return 1
  if [[ -n ${1:-} ]]; then
    stage_chosen_cert "$1"
  fi
}

ss_wizard() {
  STORE_REV=$(store_revision)
  local tag="" listen port remark method password network doc pack
  pack=$(ask_bind shadowsocks "" ss 8388) || return 0
  read_fields "$pack" listen port tag remark network
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
  open_new || return 0
  doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") || doc=""
  finish_doc "$tag" shadowsocks "$port" "$doc" || return 0
}

vless_wizard() {
  STORE_REV=$(store_revision)
  local tag="" listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys doc pack
  flow=xtls-rprx-vision
  note "VLESS REALITY 仅 TCP，流控 xtls-rprx-vision。"
  blank
  pack=$(ask_bind vless tcp vless 443) || return 0
  read_fields "$pack" listen port tag remark
  note "伪装站点需要 TLS 1.3，不要用 CDN。"
  name_pack=$(ask_name "伪装域名" "www.microsoft.com:443" domain) || return 0
  read_fields "$name_pack" host tport
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
  open_new || return 0
  doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
    "$sni" "$target" "$tport" "$priv" "$pub" "$sid") || doc=""
  finish_doc "$tag" vless "$port" "$doc" || return 0
}

hy_wizard() {
  STORE_REV=$(store_revision)
  local tag="" listen port remark auth sni cert key insecure
  local cert_mode="" cert_show="" doc pack
  note "Hysteria2 走 QUIC，必须启用 TLS。"
  blank
  pack=$(ask_bind hysteria2 udp hy2 443) || return 0
  read_fields "$pack" listen port tag remark
  ask_fresh_cert sni || return 0
  auth=$(ask_password "认证密码" "" "") || return 0
  blank
  kv "协议" "Hysteria2"
  kv "监听" "$(uri_host "$listen"):${port}/udp"
  kv "SNI" "$sni"
  kv "证书" "$cert_show"
  kv "ALPN" "h3"
  kv "认证" "$auth"
  kv "备注" "$remark"
  blank
  open_new "$tag" || return 0
  doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") || doc=""
  finish_doc "$tag" hysteria2 "$port" "$doc" || return 0
}

tuic_wizard() {
  STORE_REV=$(store_revision)
  local tag="" listen port remark uuid password sni cert key insecure congestion
  local cert_mode="" cert_show="" doc pack
  note "TUIC v5 走 QUIC，必须启用 TLS。"
  blank
  pack=$(ask_bind tuic udp tuic 443) || return 0
  read_fields "$pack" listen port tag remark
  congestion=$(ask_congestion) || return 0
  ask_fresh_cert sni || return 0
  uuid=$(ask_uuid "") || return 0
  password=$(ask_password "密码" "" "") || return 0
  blank
  kv "协议" "TUIC v5"
  kv "监听" "$(uri_host "$listen"):${port}/udp"
  kv "SNI" "$sni"
  kv "证书" "$cert_show"
  kv "ALPN" "h3"
  kv "拥塞" "$congestion"
  kv "UUID" "$uuid"
  kv "密码" "$password"
  kv "备注" "$remark"
  blank
  open_new "$tag" || return 0
  doc=$(meta_tuic "$tag" "$remark" "$listen" "$port" "$uuid" "$password" "$sni" \
    "$cert" "$key" "$insecure" "$congestion") || doc=""
  finish_doc "$tag" tuic "$port" "$doc" || return 0
}

prepare_store() {
  if ! id -u sing-box >/dev/null 2>&1; then
    err "缺少服务用户，请先安装内核。"
    pause
    return 1
  fi
  ensure_dirs || return 1
  STORE_REV=$(store_revision)
}

add_inbound() {
  local choice
  require_kernel || return 0
  deps_ok || return 0
  prepare_store || return 0
  while true; do
    choice=$(choose "添加入站" "返回" "Shadowsocks" "VLESS REALITY" "Hysteria2" "TUIC v5") || return 0
    case $choice in
      1)
        header "Shadowsocks"
        ss_wizard
        ;;
      2)
        header "VLESS / REALITY"
        vless_wizard
        ;;
      3)
        header "Hysteria2"
        hy_wizard
        ;;
      4)
        header "TUIC v5"
        tuic_wizard
        ;;
    esac
  done
}

edit_loop() {
  local title=$1 remark=$2
  shift 2
  choice_menu fields "$title" 返回 "$remark" "$@"
}

apply_edited() {
  local tag=$1 proto=$2 port=$3 network=$4 listen=$5 doc=$6
  if port_conflict "$port" "$tag" "$proto" "$network" "$listen"; then
    err "监听端点与 ${CONFLICT_TAG} 冲突。"
    pause
    return 1
  fi
  confirm_write || return 1
  need_tx || return 1
  finish_inbound "$tag" "$proto" "$port" "$doc"
}

# 证书项已开过事务；其余字段仍先确认再开事务。
save_edit() {
  local staged=$1 tag=$2 proto=$3 port=$4 network=$5 listen=$6 doc=$7
  if ((staged)); then
    finish_doc "$tag" "$proto" "$port" "$doc"
  elif [[ -z $doc ]]; then
    meta_write_error
  else
    apply_edited "$tag" "$proto" "$port" "$network" "$listen" "$doc"
  fi
}

ss_key_canon() {
  local method=$1 password=$2 need padded got canonical
  need=$(ss_key_bytes "$method") || return 0
  [[ $password =~ ^[A-Za-z0-9+/_-]+={0,2}$ ]] || return 1
  padded=${password//-/+}
  padded=${padded//_//}
  padded=${padded%%=*}
  case $((${#padded} % 4)) in
    0) ;;
    2) padded+='==' ;;
    3) padded+='=' ;;
    *) return 1 ;;
  esac
  got=$(printf '%s' "$padded" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ') || return 1
  [[ ${got:-0} -eq $need ]] || return 1
  canonical=$(printf '%s' "$padded" | openssl base64 -d -A 2>/dev/null | openssl base64 -A) || return 1
  [[ -n $canonical ]] || return 1
  printf '%s' "$canonical"
}

ss_key_ok() {
  ss_key_canon "$1" "$2" >/dev/null
}

apply_field_cert() {
  take_cert "$@" || return $?
  confirm_write || return 1
}

stage_field_cert() {
  local _flag=$1 tag=$2
  shift 2
  apply_field_cert "$@" || return $?
  need_tx || return $?
  stage_chosen_cert "$tag" || return $?
  printf -v "$_flag" 1
}

edit_ss() {
  local meta=$1 choice doc
  local tag listen port remark method password network canon
  while true; do
    STORE_REV=$(store_revision)
    validate_meta "$meta" || return 1
    load_plain "$meta" tag listen port remark method password network
    choice=$(edit_loop "修改 Shadowsocks" "$remark" \
      "监听=$listen" "端口=$port" "传输=$network" \
      "备注=$remark" "加密=$method" "密码=已设置 · 选择修改") || return 0
    case $choice in
      1) listen=$(ask_listen "$listen") || continue ;;
      2) port=$(ask_port "$port" "$tag" shadowsocks "$network" "$listen") || continue ;;
      3) network=$(ask_ss_network) || continue ;;
      4) remark=$(ask_remark "$remark") || continue ;;
      5)
        method=$(ask_method) || continue
        if canon=$(ss_key_canon "$method" "$password"); then
          [[ -z $canon ]] || password=$canon
        else
          note "新加密方式需要不同长度的密钥，请设置密码。"
          password=$(ask_password "密码" "" "$method") || continue
        fi
        ;;
      6) password=$(ask_password "密码" "$password" "$method") || continue ;;
      *) continue ;;
    esac
    doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") || doc=""
    save_edit 0 "$tag" shadowsocks "$port" "$network" "$listen" "$doc" || continue
  done
}

edit_vless() {
  local meta=$1 choice doc
  local tag listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys dest
  while true; do
    STORE_REV=$(store_revision)
    validate_meta "$meta" || return 1
    load_plain "$meta" tag listen port remark uuid sni target priv=privateKey pub=publicKey sid=shortId
    flow=$(jq -r '.flow // "xtls-rprx-vision"' "$meta")
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
    doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
      "$sni" "$target" "$tport" "$priv" "$pub" "$sid") || doc=""
    save_edit 0 "$tag" vless "$port" tcp "$listen" "$doc" || continue
  done
}

edit_quic() {
  local meta=$1 choice doc staged proto title
  local tag listen port remark auth uuid password sni cert key insecure congestion name_pack
  local cert_mode="" cert_show=""
  local -a rows
  while true; do
    STORE_REV=$(store_revision)
    validate_meta "$meta" || return 1
    load_plain "$meta" proto=protocol tag listen port remark auth uuid password sni cert=certFile key=keyFile congestion
    insecure=$(jq -r 'if .insecure then 1 else 0 end' "$meta")
    staged=0
    rows=("监听=$listen" "端口=$port" "备注=$remark" "域名=$sni" "证书=$cert")
    if [[ $proto == hysteria2 ]]; then
      title=Hysteria2
      rows+=("认证=已设置 · 选择修改")
    else
      title="TUIC v5"
      rows+=("拥塞=$congestion" "UUID=$uuid" "密码=已设置 · 选择修改")
    fi
    choice=$(edit_loop "修改 $title" "$remark" "${rows[@]}") || return 0
    case $choice in
      1) listen=$(ask_listen "$listen") || continue ;;
      2) port=$(ask_port "$port" "$tag" "$proto" udp "$listen") || continue ;;
      3) remark=$(ask_remark "$remark") || continue ;;
      4)
        name_pack=$(ask_name "证书域名或 IP" "$sni" name) || continue
        read_fields "$name_pack" sni
        ;;
      5) stage_field_cert staged "$tag" "$sni" "$cert" "$key" "$insecure" || continue ;;
      6)
        if [[ $proto == hysteria2 ]]; then
          auth=$(ask_password "认证密码" "$auth" "") || continue
        else
          congestion=$(ask_congestion) || continue
        fi
        ;;
      7) uuid=$(ask_uuid "$uuid") || continue ;;
      8) password=$(ask_password "密码" "$password" "") || continue ;;
      *) continue ;;
    esac
    if [[ $proto == hysteria2 ]]; then
      doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") || doc=""
    else
      doc=$(meta_tuic "$tag" "$remark" "$listen" "$port" "$uuid" "$password" "$sni" \
        "$cert" "$key" "$insecure" "$congestion") || doc=""
    fi
    save_edit "$staged" "$tag" "$proto" "$port" udp "$listen" "$doc" || continue
  done
}

edit_inbound() {
  local picked
  require_kernel || return 0
  deps_ok || return 0
  prepare_store || return 0
  while true; do
    pick_inbound "修改入站" || return 0
    picked=$PICKED
    case $(jq -r '.protocol' "$picked") in
      shadowsocks) edit_ss "$picked" ;;
      vless) edit_vless "$picked" ;;
      hysteria2 | tuic) edit_quic "$picked" ;;
      *)
        err "未知协议。"
        pause
        ;;
    esac
  done
}

delete_inbound() {
  local picked tag
  if ! command -v jq >/dev/null 2>&1; then
    ensure_deps || {
      header "删除入站"
      err "缺少 jq。"
      pause
      return 0
    }
  fi
  pick_inbound "删除入站" || return 0
  picked=$PICKED
  tag=$(jq -r '.tag' "$picked")
  blank
  kv "删除" "$(proto_label "$picked")  $(jq -r '.port' "$picked")  $(jq -r '.remark' "$picked")"
  confirm "确认删除？" || return 0
  need_tx || return 0
  rm -f -- "$META_DIR/${tag}.json" || { rollback_tx; return 0; }
  if ! rebuild_config; then
    meta_write_error || return 0
  fi
  if [[ -x $BIN ]]; then
    commit_tx || { pause; return 0; }
  else
    gc_certs
    end_tx
    plainln "  已删除。"
  fi
  pause
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
  printf '%s' "$1" | jq -sRr '@uri'
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
  ((o1 == 0 || o1 == 10 || o1 == 127 || o1 >= 224 \
    || (o1 == 100 && o2 >= 64 && o2 <= 127) \
    || (o1 == 169 && o2 == 254) \
    || (o1 == 172 && o2 >= 16 && o2 <= 31) \
    || (o1 == 192 && o2 == 168))) && return 1
  return 0
}

is_public_ipv6() {
  local ip head
  ip=$(canon_ipv6 "$1") || return 1
  head=${ip%%:*}
  # 公网单播地址为 2000::/3，排除文档保留网段。
  [[ $head =~ ^[23][0-9a-f]{3}$ && $ip != 2001:db8:* ]]
}

fetch_ip() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    curl -"$1" -fsS --noproxy '*' --connect-timeout 2 --max-time 4 -o "$3" "$2" 2>/dev/null || true
}

read_public_ip() {
  local ip
  [[ -s $1 ]] || return 1
  ip=$(tr -d '[:space:]' <"$1")
  if [[ $2 == 4 ]]; then
    is_public_ipv4 "$ip" || return 1
  else
    is_public_ipv6 "$ip" || return 1
  fi
  printf '%s' "$ip"
}

take_public() {
  local ip
  ip=$(read_public_ip "$2" "$1" || true)
  if [[ -z $ip ]]; then
    fetch_ip "$1" "$3" "${2}b"
    ip=$(read_public_ip "${2}b" "$1" || true)
  fi
  printf '%s' "$ip"
}

# 输出两行：公网 IPv4、公网 IPv6，没有则留空。
detect_public_ips() {
  local dir v4 v6 p4 p6
  dir=$(mktemp -d) || return 1
  fetch_ip 4 https://api.ipify.org "$dir/4" &
  p4=$!
  fetch_ip 6 https://api6.ipify.org "$dir/6" &
  p6=$!
  wait "$p4" || true
  wait "$p6" || true
  v4=$(take_public 4 "$dir/4" https://ipv4.icanhazip.com)
  v6=$(take_public 6 "$dir/6" https://ipv6.icanhazip.com)
  rm -rf -- "$dir"
  printf '%s\n%s\n' "$v4" "$v6"
}

host_ok() {
  is_ipv4 "$1" || is_ipv6 "$1" || is_domain "$1"
}

share_host_ok() {
  local host=$1
  if [[ $host == \[*\] ]]; then
    host=${host#\[}
    host=${host%\]}
  fi
  host_ok "$host"
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
      local userinfo
      local network query=""
      network=$(jq -r '.network // "tcp,udp"' "$meta")
      if [[ $method == 2022-* ]]; then
        userinfo="$(urlenc "$method"):$(urlenc "$password")"
      else
        userinfo=$(b64url "${method}:${password}")
      fi
      case $network in
        tcp | udp) query="?network=${network}" ;;
      esac
      printf 'ss://%s@%s:%s%s#%s\n' "$userinfo" "$host" "$port" "$query" "$enc"
      ;;
    vless)
      uuid=$(urlenc "$(jq -r '.uuid' "$meta")")
      flow=$(jq -r '.flow' "$meta")
      sni=$(urlenc "$(jq -r '.sni' "$meta")")
      fp=$(urlenc "$(jq -r '.fingerprint // "chrome"' "$meta")")
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
    tuic)
      uuid=$(urlenc "$(jq -r '.uuid' "$meta")")
      password=$(urlenc "$(jq -r '.password' "$meta")")
      sni=$(urlenc "$(jq -r '.sni' "$meta")")
      local cc extra
      cc=$(urlenc "$(jq -r '.congestion' "$meta")")
      insecure=$(jq -r 'if .insecure then 1 else 0 end' "$meta")
      extra="sni=${sni}&alpn=h3&congestion_control=${cc}&udp_relay_mode=native"
      if [[ $insecure == 1 ]]; then
        extra+="&allow_insecure=1"
      fi
      printf 'tuic://%s:%s@%s:%s?%s#%s\n' "$uuid" "$password" "$host" "$port" "$extra" "$enc"
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
    tuic)
      kv "UUID" "$(jq -r '.uuid' "$meta")"
      kv "密码" "$(jq -r '.password' "$meta")"
      kv "SNI" "$(jq -r '.sni' "$meta")"
      kv "拥塞" "$(jq -r '.congestion' "$meta")"
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
  plainln "  正在检测公网地址..."
  mapfile -t found < <(detect_public_ips || true)
  v4=${found[0]:-}
  v6=${found[1]:-}
  listen=$(jq -r '.listen' "$picked")
  if [[ $listen != *:* || $listen == :: ]]; then
    [[ -z $v4 ]] || hosts+=("$v4")
  fi
  if [[ $listen == *:* ]]; then
    [[ -z $v6 ]] || hosts+=("$v6")
  fi
  if ((${#hosts[@]} == 0)); then
    default=$(saved_host)
    host=$(prompt "服务器地址" "$default" "q 取消") || return 0
    cancelled "$host" && return 0
    if [[ -z $host ]]; then
      err "地址不能为空。"
      pause
      return 0
    fi
    if ! share_host_ok "$host"; then
      err "请输入域名、IPv4 或 IPv6，不要带端口。"
      pause
      return 0
    fi
    make_dir 750 root sing-box "$STATE_DIR" || { pause; return 0; }
    if [[ -L $STATE_DIR/server_addr ]]; then
      err "服务器地址文件不能是符号链接。"; pause; return 0
    fi
    printf '%s\n' "$host" >"$STATE_DIR/server_addr" || {
      err "无法保存服务器地址。"
      pause
      return 0
    }
    chmod 600 "$STATE_DIR/server_addr"
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
  pause
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
      1) install_kernel ;;
      2) upgrade_kernel ;;
      3) start_kernel ;;
      4) stop_kernel ;;
      5) uninstall_kernel ;;
      6) add_inbound ;;
      7) edit_inbound ;;
      8) share_inbound ;;
      9) delete_inbound ;;
      10) view_logs ;;
      "") ;;
      *) msg="无效选项。" ;;
    esac
  done
}

usage() {
  cat <<'EOF'
sing-box 管理面板

用法: sudo sh sing-box.sh

文档: https://sing-box.sagernet.org/
系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
入站: Shadowsocks、VLESS REALITY、Hysteria2、TUIC v5
内核以 sing-box 用户运行。
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
  if [[ ! -e /dev/tty ]]; then
    echo "请在交互终端中运行。" >&2
    return 1
  fi
  [[ -d ${LOCK_FILE%/*} ]] || LOCK_FILE=/var/lock/sing-box.lock
  init_ui
  main_menu
}

if [[ ${SINGBOX_PANEL_SOURCE:-0} != 1 ]]; then
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
  trap 'exit 143' TERM HUP
  main "$@"
fi
SINGBOX_PANEL_PAYLOAD
