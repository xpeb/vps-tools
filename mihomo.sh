#!/bin/sh
# mihomo 管理面板
# 文档: https://wiki.metacubex.one/
# 系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
# 入站: Shadowsocks、VLESS REALITY、Hysteria2、TUIC v5
# 内核以 mihomo 用户运行
#
# 用法: sudo ./mihomo.sh

set -eu

if ! command -v bash >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "需要 bash。请用 root 运行，或先安装 bash。" >&2
    exit 1
  fi
  if [ -f /etc/alpine-release ]; then
    apk add --no-cache bash || {
      echo "安装 bash 失败。" >&2
      exit 1
    }
  elif [ -f /etc/debian_version ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || {
      echo "安装 bash 失败。" >&2
      exit 1
    }
    apt-get install -y --no-install-recommends bash || {
      echo "安装 bash 失败。" >&2
      exit 1
    }
  else
    echo "仅支持 Debian 与 Alpine。" >&2
    exit 1
  fi
fi

# 输出走独立 fd，避免 heredoc 被 read 读走。
exec bash /dev/fd/3 "$@" 3<<'MIHOMO_PANEL_PAYLOAD'
set -uo pipefail
set +H
set +o history
umask 077
shopt -s nullglob

# 程序、配置、证书、运行目录和日志都在 STATE_DIR。服务单元仍由 systemd / OpenRC 从 /etc 加载。
: "${STATE_DIR:=/var/lib/mihomo}"
: "${BIN:=$STATE_DIR/bin/mihomo}"
: "${CMD_LINK:=/usr/local/bin/mihomo}"
: "${CONF_DIR:=$STATE_DIR/etc}"
: "${CONF:=$CONF_DIR/config.yaml}"
: "${LOG_DIR:=$STATE_DIR/log}"
: "${RUNTIME_DIR:=$STATE_DIR/runtime}"
: "${META_DIR:=$STATE_DIR/meta}"
: "${CERT_DIR:=$STATE_DIR/certs}"
: "${STDOUT_LOG:=$LOG_DIR/stdout.log}"
: "${STDERR_LOG:=$LOG_DIR/stderr.log}"
: "${SYSTEMD_UNIT:=/etc/systemd/system/mihomo.service}"
: "${OPENRC_SERVICE:=/etc/init.d/mihomo}"
: "${LOGROTATE_FILE:=/etc/logrotate.d/mihomo}"
: "${SYSTEMD_ENABLE_LINK:=/etc/systemd/system/multi-user.target.wants/mihomo.service}"
: "${OPENRC_ENABLE_LINK:=/etc/runlevels/default/mihomo}"
: "${PID_FILE:=/run/mihomo.pid}"
: "${OPENRC_DIR:=/run/openrc}"
LOCK_FILE=/run/mihomo.lock
REPO=MetaCubeX/mihomo

GRN=$'\033[38;2;126;217;167m'
RED=$'\033[38;2;255;107;107m'
YEL=$'\033[38;2;240;200;120m'
DIM=$'\033[38;2;145;155;170m'
ACC=$'\033[38;2;116;180;255m'
RST=$'\033[0m'
BOLD=$'\033[1m'

OS=""
TX=""
TX_RESTART=0
TX_READY=0
TX_WAS_RUNNING=0
TX_FILES=()
TX_OWNS_LOCK=0
LOCK_HELD=0
STORE_REV=""
WORK_DIR=""
BOX_USER_CREATED=0
CONFLICT_TAG=""
PICKED=""
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

MENU_NUM_W=4
MENU_LABEL_W=18
PANEL_KERNEL=("1 安装内核 2 升级内核" "3 启动服务 4 停止服务")
PANEL_INBOUND=("6 添加入站 7 修改入站" "8 分享链接 9 删除入站")
PANEL_DIAG=("10 查看日志 q 退出面板")

menu_row_width() {
  dw "$(pad "$1" "$MENU_NUM_W")$(pad "$2" "$MENU_LABEL_W")  $(pad "$3" "$MENU_NUM_W")$4"
}

menu_rule() {
  local max=0 w spec n1 l1 n2 l2
  for spec in "$@"; do
    read -r n1 l1 n2 l2 <<<"$spec"
    w=$(menu_row_width "$n1" "$l1" "$n2" "$l2")
    if ((w > max)); then
      max=$w
    fi
  done
  printf '%*s' "$max" '' | tr ' ' '-'
}

init_ui() {
  if [[ -n ${NO_COLOR:-} || ${TERM:-dumb} == dumb ]]; then
    GRN='' RED='' YEL='' DIM='' ACC='' RST='' BOLD=''
  fi
  RULE=$(menu_rule "${PANEL_KERNEL[@]}" "${PANEL_INBOUND[@]}" "${PANEL_DIAG[@]}")
}

cleanup() {
  if [[ -n $TX ]]; then
    if ((TX_READY)); then rollback_tx || true; else end_tx; fi
  else
    release_lock
  fi
  [[ -z $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
  printf '%b' "$RST" >&4 2>/dev/null || printf '%b' "$RST" || true
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
  printf '  %bMIHOMO%b  /  %s\n' "$ACC$BOLD" "$RST" "$1" >&4
  uin "  ${DIM}${RULE}${RST}"
  blank
}

pause() {
  blank
  ui "  ${DIM}回车继续${RST}${GRN}"
  IFS= read -r _ </dev/tty || true
  ui $'\n'
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

trim_line() {
  local s=$1
  s=${s//$'\r'/}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

tty_read() {
  local -n _out=$1
  local _prompt=$2 _mode=${3:-} _ans
  if ! IFS= read -r -e -p "$_prompt" _ans </dev/tty 2>&4; then
    ui $'\n'
    return 2
  fi
  if [[ $_mode == raw ]]; then
    _out=${_ans//$'\r'/}
  else
    _out=$(trim_line "$_ans")
  fi
}

prompt() {
  local msg=$1 default=${2:-} hint=${3:-} mode=${4:-} ans p=""
  p=$(printf '\001%s\002  %s' "$GRN" "$msg")
  if [[ -n $default ]]; then
    p+=$(printf ' \001%s\002%s\001%s\002' "$DIM" "$default" "$GRN")
  fi
  if [[ -n $hint ]]; then
    p+=$(printf ' \001%s\002%s\001%s\002' "$DIM" "$hint" "$GRN")
  fi
  p+=$(printf ': ')
  tty_read ans "$p" "$mode" || return 2
  if [[ -z $ans && $mode != raw ]]; then
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

regen_prompt() {
  if [[ -n ${2:-} ]]; then
    prompt "$1" "" "回车保留，g 重新生成，q 取消"
  else
    prompt "$1" "" "回车生成，q 取消"
  fi
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
    i386 | i686) machine=386 ;;
    amd64 | x86_64) machine=amd64 ;;
    armv5tel) machine=armv5 ;;
    armv6l)
      machine=armv6
      grep -q ' vfp' /proc/cpuinfo 2>/dev/null || machine=armv5
      ;;
    armv7 | armv7l)
      machine=armv7
      grep -q ' vfp' /proc/cpuinfo 2>/dev/null || machine=armv5
      ;;
    armv8 | aarch64) machine=arm64 ;;
    mips) machine=mips-softfloat ;;
    mipsle) machine=mipsle-softfloat ;;
    mips64)
      machine=mips64
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

ensure_deps() {
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v gzip >/dev/null 2>&1 || pkgs+=(gzip)
  command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  command -v sha256sum >/dev/null 2>&1 || pkgs+=(coreutils)
  command -v logrotate >/dev/null 2>&1 || pkgs+=(logrotate)
  if ! command -v flock >/dev/null 2>&1; then
    if [[ $OS == alpine ]]; then pkgs+=(flock); else pkgs+=(util-linux); fi
  fi
  if ! command -v ss >/dev/null 2>&1; then
    if [[ $OS == alpine ]]; then pkgs+=(iproute2-ss); else pkgs+=(iproute2); fi
  fi
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

need_deps() {
  if ! ensure_deps; then
    err "依赖安装失败。"
    pause
    return 1
  fi
}

box_group_ok() {
  local primary listed
  if ! getent group mihomo >/dev/null 2>&1; then
    return 1
  fi
  primary=$(id -gn mihomo 2>/dev/null || true)
  if [[ $primary == mihomo ]]; then
    return 0
  fi
  listed=$(id -nG mihomo 2>/dev/null || true)
  [[ " ${listed} " == *" mihomo "* ]]
}

create_box_user() {
  install -d -m 755 -o root -g root /var/empty
  if id -u mihomo >/dev/null 2>&1; then
    if [[ $(id -u mihomo) -eq 0 || $(id -g mihomo) -eq 0 ]]; then
      err "已有的 mihomo 账户不能是 root。"
      return 1
    fi
    if ! box_group_ok; then
      err "已有的 mihomo 账户必须属于 mihomo 组。"
      return 1
    fi
    warn "已有 mihomo 用户，继续使用。"
    return 0
  fi
  plainln "  创建 mihomo 用户"
  # systemd-sysusers 的提示在 stderr；装了 systemd 的 Alpine 也走这里。
  if command -v systemd-sysusers >/dev/null 2>&1; then
    systemd-sysusers - >/dev/null 2>&1 <<'EOF' || true
u mihomo - "mihomo" /var/empty
EOF
  elif [[ $OS == alpine ]]; then
    if ! grep -q '^mihomo:' /etc/group 2>/dev/null; then
      addgroup -S mihomo >/dev/null 2>&1 || return 1
    fi
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G mihomo -g "mihomo" mihomo >/dev/null 2>&1 || true
  else
    if ! getent group mihomo >/dev/null 2>&1; then
      groupadd --system mihomo >/dev/null 2>&1 || return 1
    fi
    useradd --system --gid mihomo --home-dir /var/empty --shell /usr/sbin/nologin --comment "mihomo" mihomo >/dev/null 2>&1 || true
  fi
  if ! id -u mihomo >/dev/null 2>&1; then
    err "无法创建 mihomo 用户。"
    return 1
  fi
  BOX_USER_CREATED=1
  if [[ $(id -u mihomo) -eq 0 || $(id -g mihomo) -eq 0 ]]; then
    err "mihomo 账户不能是 root。"
    return 1
  fi
  box_group_ok || { err "mihomo 用户与组不匹配。"; return 1; }
}

remove_box_user() {
  local uid="" gid=""
  if id -u mihomo >/dev/null 2>&1; then
    uid=$(id -u mihomo) || return 1
    gid=$(id -g mihomo) || return 1
    if [[ $uid == 0 || $gid == 0 ]]; then
      err "拒绝删除 root 账户。"
      return 1
    fi
    if [[ $OS == alpine ]]; then deluser mihomo; else userdel mihomo; fi || return 1
  fi
  if getent group mihomo >/dev/null 2>&1; then
    if [[ $OS == alpine ]]; then delgroup mihomo; else groupdel mihomo; fi || return 1
  fi
}

real_dir() {
  local dir=$1
  if [[ -L $dir || ( -e $dir && ! -d $dir ) ]]; then
    err "拒绝使用非目录或符号链接: ${dir}"
    return 1
  fi
}

make_dir() {
  local mode=$1 owner=$2 group=$3 dir=$4
  local cursor="" part i last
  local -a parts=()
  real_dir "$dir" || return 1
  [[ $dir == /* && /$dir/ != */../* && /$dir/ != */./* ]] || {
    err "目录必须是没有 . 或 .. 的绝对路径: ${dir}"
    return 1
  }
  # 一层层建。install -d 在 umask 077 下只会把最后一层设成 -m，
  # 中间层会变成 0700；已存在的父目录（例如 /root）不再改权限。
  IFS=/ read -r -a parts <<< "${dir#/}"
  last=$((${#parts[@]} - 1))
  for ((i = 0; i < ${#parts[@]}; i++)); do
    part=${parts[i]}
    [[ -n $part ]] || continue
    cursor+="/$part"
    if [[ -d $cursor ]]; then
      real_dir "$cursor" || return 1
      continue
    fi
    if [[ -e $cursor || -L $cursor ]]; then
      err "拒绝使用非目录或符号链接: ${cursor}"
      return 1
    fi
    if ((i == last)); then
      install -d -m "$mode" -o "$owner" -g "$group" "$cursor" || return 1
    else
      install -d -m 755 -o root -g root "$cursor" || return 1
    fi
  done
}

own_dir() {
  local mode=$1 owner=$2 group=$3 dir=$4
  real_dir "$dir" || return 1
  [[ -d $dir ]] || return 0
  chown "${owner}:${group}" "$dir" || return 1
  chmod "$mode" "$dir"
}

ensure_dirs() {
  local spec mode owner group dir f
  for spec in \
    "750 root mihomo $STATE_DIR" \
    "755 root root ${BIN%/*}" \
    "750 root mihomo $CONF_DIR" \
    "750 root mihomo $LOG_DIR" \
    "750 mihomo mihomo $RUNTIME_DIR" \
    "700 root root $META_DIR" \
    "750 root mihomo $CERT_DIR"; do
    read -r mode owner group dir <<<"$spec"
    make_dir "$mode" "$owner" "$group" "$dir" || return 1
  done
  for f in "$STDOUT_LOG" "$STDERR_LOG"; do
    [[ ! -L $f && ( ! -e $f || -f $f ) ]] || return 1
    if [[ ! -e $f ]]; then
      install -m 600 -o mihomo -g mihomo /dev/null "$f" || return 1
    fi
    chown mihomo:mihomo "$f" && chmod 600 "$f" || return 1
  done
  fix_tree_perms
}

atomic_text() {
  local dest=$1 mode=$2 owner=$3 group=$4 dir tmp
  dir=$(dirname "$dest")
  if [[ ! -d $dir || -L $dest || ( -e $dest && ! -f $dest ) ]]; then
    return 1
  fi
  tmp=$(mktemp -p "$dir") || return 1
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ ! -s $tmp ]]; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chown "${owner}:${group}" "$tmp" || ! chmod "$mode" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

validate_paths() {
  local path
  for path in "$STATE_DIR" "$CONF_DIR" "$LOG_DIR" "$RUNTIME_DIR" "$META_DIR" "$CERT_DIR" "${BIN%/*}"; do
    case $path in
      / | /bin | /sbin | /usr | /usr/bin | /usr/sbin | /etc | /var | /var/lib | /var/log | /run | /tmp | /root | /home)
        err "不能使用系统目录作为数据目录: ${path}"; return 1 ;;
    esac
  done
  for path in "$STATE_DIR" "$BIN" "$CMD_LINK" "$CONF_DIR" "$CONF" "$LOG_DIR" "$RUNTIME_DIR" "$META_DIR" \
    "$CERT_DIR" "$STDOUT_LOG" "$STDERR_LOG" "$SYSTEMD_UNIT" "$OPENRC_SERVICE" "$LOGROTATE_FILE" \
    "$SYSTEMD_ENABLE_LINK" "$OPENRC_ENABLE_LINK"; do
    [[ $path =~ ^/[-A-Za-z0-9_./]+$ && $path != */ && $path != *//* \
      && /$path/ != */../* && /$path/ != */./* ]] || {
      err "路径须为不含空白或特殊字符的绝对路径: ${path}"
      return 1
    }
  done
}

empty_config() {
  cat <<'EOF'
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: true
proxies: []
rules:
  - MATCH,DIRECT
EOF
}

ensure_base_config() {
  [[ ! -L $CONF ]] || return 1
  if [[ -f $CONF ]]; then
    return 0
  fi
  empty_config | atomic_text "$CONF" 640 root mihomo
}

fix_tree_perms() {
  local f
  for f in "$CONF_DIR" "$STATE_DIR" "${BIN%/*}" "$RUNTIME_DIR" "$LOG_DIR" "$META_DIR" "$CERT_DIR" \
    "$CONF" "$STATE_DIR/server_addr" "$META_DIR"/*.json "$CERT_DIR"/*; do
    [[ ! -L $f ]] || { err "拒绝使用符号链接: ${f}"; return 1; }
  done
  if [[ -f $CONF ]]; then
    chown root:mihomo "$CONF" || return 1
    chmod 640 "$CONF" || return 1
  fi
  own_dir 750 root mihomo "$CONF_DIR" || return 1
  own_dir 750 root mihomo "$STATE_DIR" || return 1
  own_dir 755 root root "${BIN%/*}" || return 1
  own_dir 750 mihomo mihomo "$RUNTIME_DIR" || return 1
  own_dir 750 root mihomo "$LOG_DIR" || return 1
  if [[ -d $META_DIR ]]; then
    own_dir 700 root root "$META_DIR" || return 1
    for f in "$META_DIR"/*.json; do
      [[ -f $f ]] || continue
      chown root:root "$f" || return 1
      chmod 600 "$f" || return 1
    done
  fi
  if [[ -d $CERT_DIR ]]; then
    own_dir 750 root mihomo "$CERT_DIR" || return 1
    for f in "$CERT_DIR"/*; do
      [[ -e $f ]] || continue
      chown root:mihomo "$f" || return 1
      chmod 640 "$f" || return 1
    done
  fi
  if [[ -f $STATE_DIR/server_addr ]]; then
    chown root:root "$STATE_DIR/server_addr" || return 1
    chmod 600 "$STATE_DIR/server_addr" || return 1
  fi
  repair_conf_access
}

repair_conf_access() {
  [[ -d $CONF_DIR ]] || return 0
  if ! id -u mihomo >/dev/null 2>&1 || ! command -v su >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck disable=SC2016
  if su -s /bin/sh -c 'test -x "$1" && test -r "$1"' mihomo sh "$CONF_DIR"; then
    return 0
  fi
  chown root:mihomo "$CONF_DIR" || return 1
  chmod 750 "$CONF_DIR" || return 1
  # shellcheck disable=SC2016
  if su -s /bin/sh -c 'test -x "$1" && test -r "$1"' mihomo sh "$CONF_DIR"; then
    return 0
  fi
  err "mihomo 用户无法进入配置目录。父目录须允许穿越，且不能是符号链接。"
  return 1
}

gc_certs() {
  local meta tag f
  [[ -n $TX ]] || return 0
  for meta in "$TX/meta"/*.json; do
    tag=${meta##*/}; tag=${tag%.json}
    [[ ! -f $META_DIR/${tag}.json ]] || continue
    valid_tag "$tag" || return 1
    for f in "$CERT_DIR/${tag}.crt" "$CERT_DIR/${tag}.key"; do
      [[ -f $f && ! -L $f ]] || continue
      grep -qF -- "$f" "$CONF" && continue
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
  for f in "$CONF" "$META_DIR"/*.json "$CERT_DIR"/*; do
    [[ -f $f && ! -L $f ]] || continue
    sha256sum "$f" || return 1
  done | sha256sum
}

acquire_lock() {
  [[ -z $TX ]] || { err "存在未恢复的事务: ${TX}"; return 1; }
  ((LOCK_HELD == 0)) || return 0
  if [[ ! -d ${LOCK_FILE%/*} ]] || ! command -v flock >/dev/null 2>&1; then
    err "缺少锁目录或 flock，无法安全修改配置。"
    return 1
  fi
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
  exec 9>&-
  LOCK_HELD=0
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
  local snap=$TX owns=$TX_OWNS_LOCK
  TX=""
  TX_RESTART=0
  TX_READY=0
  TX_WAS_RUNNING=0
  TX_FILES=()
  TX_OWNS_LOCK=0
  BOX_USER_CREATED=0
  [[ -z $snap ]] || rm -rf -- "$snap"
  STORE_REV=$(store_revision) || STORE_REV=""
  if ((owns)); then release_lock; fi
}

snapshot_tx() {
  local mode=$1 name dir i
  mkdir -p "$TX/files" || return 1
  [[ ! -L $STATE_DIR && ! -L ${BIN%/*} ]] || return 1
  [[ ! -d $STATE_DIR ]] || touch "$TX/had-state" || return 1
  if [[ -L $CMD_LINK && $(readlink -- "$CMD_LINK") == "$BIN" ]]; then
    cp -a -- "$CMD_LINK" "$TX/command" || return 1
  fi
  for name in conf meta certs; do
    case $name in
      conf) dir=$CONF_DIR ;;
      meta) dir=$META_DIR ;;
      certs) dir=$CERT_DIR ;;
    esac
    [[ ! -L $dir ]] || return 1
    if [[ -d $dir ]]; then
      mkdir "$TX/$name" || return 1
      cp -a "$dir"/. "$TX/$name"/ || return 1
    fi
  done
  TX_FILES=("$CONF" "$SYSTEMD_UNIT" "$OPENRC_SERVICE" "$LOGROTATE_FILE"
    "$SYSTEMD_ENABLE_LINK" "$OPENRC_ENABLE_LINK")
  [[ $mode != deploy ]] || TX_FILES+=("$BIN")
  for ((i = 0; i < ${#TX_FILES[@]}; i++)); do
    if [[ -e ${TX_FILES[i]} || -L ${TX_FILES[i]} ]]; then
      cp -a -- "${TX_FILES[i]}" "$TX/files/$i" || return 1
    fi
  done
}

begin_tx() {
  if [[ -n $TX ]]; then
    err "已有未结束的事务。"
    return 1
  fi
  local parent owns=0
  if ((LOCK_HELD == 0)); then
    acquire_lock || return 1
    owns=1
  fi
  parent=$(private_parent) || {
    ((owns == 0)) || release_lock
    err "无法创建临时目录。"
    return 1
  }
  # 快照含私钥；独立于 WORK_DIR，恢复失败时保留。
  TX=$(mktemp -d "$parent/.mihomo.XXXXXXXX") || {
    ((owns == 0)) || release_lock
    err "无法创建临时目录。"
    return 1
  }
  TX_OWNS_LOCK=$owns
  if [[ ${1:-config} == config && -n $STORE_REV && $STORE_REV != "$(store_revision)" ]]; then
    end_tx
    err "配置已被其他进程修改，请重新进入此菜单。"
    return 1
  fi
  TX_RESTART=0
  TX_READY=0
  TX_WAS_RUNNING=0
  is_running && TX_WAS_RUNNING=1
  if ! snapshot_tx "${1:-config}"; then
    end_tx
    err "无法创建配置快照。"
    return 1
  fi
  TX_READY=1
}

rollback_tx() {
  [[ -n $TX ]] || return 0
  local name dir i rc=0 snap=$TX
  if ((TX_RESTART)) && { [[ ! -f $TX/service-stopped ]] || is_running; }; then
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
  for name in conf meta certs; do
    case $name in
      conf) dir=$CONF_DIR ;;
      meta) dir=$META_DIR ;;
      certs) dir=$CERT_DIR ;;
    esac
    if [[ -d $snap/$name ]]; then
      restore_tree "$dir" "$snap/$name" || rc=1
    else
      rm -rf -- "$dir" || rc=1
    fi
  done
  for ((i = 0; i < ${#TX_FILES[@]}; i++)); do
    if [[ -e $snap/files/$i || -L $snap/files/$i ]]; then
      mkdir -p -- "$(dirname "${TX_FILES[i]}")" || { rc=1; continue; }
      rm -f -- "${TX_FILES[i]}" || { rc=1; continue; }
      cp -a -- "$snap/files/$i" "${TX_FILES[i]}" || rc=1
    else
      rm -f -- "${TX_FILES[i]}" || rc=1
    fi
  done
  if [[ -L $snap/command ]]; then
    if [[ ! -e $CMD_LINK && ! -L $CMD_LINK ]]; then
      cp -a -- "$snap/command" "$CMD_LINK" || rc=1
    elif [[ ! -L $CMD_LINK || $(readlink -- "$CMD_LINK") != "$BIN" ]]; then
      rc=1
    fi
  elif [[ -f $snap/command-created ]]; then
    unlink_command || rc=1
  fi
  if [[ ! -f $snap/had-state ]]; then
    rm -rf -- "$STATE_DIR" || rc=1
  fi
  fix_tree_perms || rc=1
  if [[ $OS == debian ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || rc=1
  fi
  if ((rc == 0 && TX_RESTART && TX_WAS_RUNNING)); then
    kernel_stays_up restart || rc=1
  fi
  # 新建的账户只在本次没有旧数据时一并删掉，避免把已恢复文件的属主丢掉。
  if ((rc == 0 && BOX_USER_CREATED)) && [[ ! -f $snap/had-state ]]; then
    remove_box_user || rc=1
  fi
  if ((rc)); then
    # 恢复失败时留下快照，不能当成已经回滚。
    err "回滚未完全成功，快照保留在 ${snap}。请勿继续修改。"
    return 1
  fi
  end_tx
}

box_as_user() {
  local bin=$1 log=$2 conf=$3
  if ! id -u mihomo >/dev/null 2>&1 || ! command -v su >/dev/null 2>&1; then
    printf '%s\n' '缺少 mihomo 用户或 su，无法以服务用户校验。' >"$log"
    return 1
  fi
  # shellcheck disable=SC2016
  su -s /bin/sh -c 'export SAFE_PATHS="$4"; exec "$1" -t -d "$2" -f "$3"' \
    mihomo sh "$bin" "$RUNTIME_DIR" "$conf" "$CERT_DIR" >"$log" 2>&1
}

box_test() {
  local log
  log=$(private_tmpfile) || return 1
  if [[ ! -x $BIN ]]; then
    err "未找到 mihomo，无法校验配置。"
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
    [[ -r $PID_FILE && -r $OPENRC_DIR/options/mihomo/child_pid ]] || return 1
    supervisor=$(<"$PID_FILE")
    pid=$(<"$OPENRC_DIR/options/mihomo/child_pid")
    [[ $supervisor =~ ^[0-9]+$ ]] && ((supervisor > 1)) || return 1
    kill -0 "$supervisor" 2>/dev/null || return 1
  elif command -v systemctl >/dev/null 2>&1; then
    pid=$(systemctl show -p MainPID --value mihomo 2>/dev/null) || return 1
  else
    for procs in \
      /sys/fs/cgroup/system.slice/mihomo.service/cgroup.procs \
      /sys/fs/cgroup/systemd/system.slice/mihomo.service/cgroup.procs
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

service_uses_panel_conf() {
  local unit
  if [[ $OS == alpine ]]; then
    unit=$OPENRC_SERVICE
  else
    unit=$SYSTEMD_UNIT
  fi
  # 运行目录可写，配置目录保持 root 所有。证书不在家目录，须加入 SAFE_PATHS。
  [[ -f $unit && ! -L $unit ]] && grep -qF 'mihomo-panel-v2' "$unit" \
    && grep -qF -- "-d $RUNTIME_DIR" "$unit" \
    && grep -qF -- "-f $CONF" "$unit" \
    && grep -qF -- "SAFE_PATHS=$CERT_DIR" "$unit" \
    && ! grep -Eq '^[[:space:]]*StateDirectory=' "$unit" \
    && service_unit_current "$unit"
}

# 旧单元没有日志重定向或 no_new_privs 时，下次启动会重写。
service_unit_current() {
  local unit=$1
  if [[ $OS == alpine ]]; then
    grep -qF 'no_new_privs=yes' "$unit" \
      && grep -qF ',!0' "$unit"
  else
    grep -qF "StandardOutput=append:${STDOUT_LOG}" "$unit" \
      && grep -qF "StandardError=append:${STDERR_LOG}" "$unit"
  fi
}

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

drop_file_caps() {
  local bin=$1
  [[ -f $bin ]] || return 0
  if command -v setcap >/dev/null 2>&1; then
    setcap -r "$bin" 2>/dev/null || true
  fi
}

install_service() {
  local caps
  if [[ $OS == alpine ]]; then
    if ! command -v rc-service >/dev/null 2>&1; then
      apk add -q --no-cache openrc >/dev/null 2>&1 || return 1
    fi
    caps=$(alpine_iab) || return 1
    atomic_text "$OPENRC_SERVICE" 755 root root <<EOF || return 1
#!/sbin/openrc-run

description="mihomo Service"
# mihomo-panel-v2
export SAFE_PATHS=$CERT_DIR

supervisor=supervise-daemon
command="$BIN"
command_args="-d $RUNTIME_DIR -f $CONF"
command_user="mihomo:mihomo"
directory="$RUNTIME_DIR"
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
    install_logrotate || return 1
    plainln "  设置开机启动"
    if ! rc-update show default 2>/dev/null | grep -qw mihomo; then
      rc-update add mihomo default >/dev/null 2>&1 || return 1
    fi
    drop_file_caps "$BIN"
  else
    if ! command -v systemctl >/dev/null 2>&1; then
      err "Debian 需要 systemd。"
      return 1
    fi
    atomic_text "$SYSTEMD_UNIT" 644 root root <<EOF || return 1
[Unit]
# mihomo-panel-v2
Description=mihomo Service
Documentation=https://wiki.metacubex.one/
After=network.target nss-lookup.target

[Service]
User=mihomo
Group=mihomo
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
UMask=0077
WorkingDirectory=$RUNTIME_DIR
Environment=SAFE_PATHS=$CERT_DIR
ExecStart=$BIN -d $RUNTIME_DIR -f $CONF
StandardOutput=append:$STDOUT_LOG
StandardError=append:$STDERR_LOG
Restart=on-failure
RestartSec=2s
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    install_logrotate || return 1
    systemctl daemon-reload || return 1
    plainln "  设置开机启动"
    systemctl enable mihomo >/dev/null 2>&1 || return 1
    drop_file_caps "$BIN"
  fi
}

svc() {
  local action=$1 rc=0
  if [[ -n $TX && ( $action == start || $action == restart || $action == stop ) ]]; then
    TX_RESTART=1
    rm -f -- "$TX/service-stopped" || return 1
  fi
  # 服务进程不能继承配置锁。
  if [[ $OS == alpine ]]; then
    rc-service mihomo "$action" 9>&- || rc=$?
  else
    if [[ $action == start || $action == restart ]]; then
      systemctl reset-failed mihomo >/dev/null 2>&1 9>&- || true
    fi
    systemctl "$action" mihomo 9>&- || rc=$?
  fi
  if ((rc == 0)) && [[ -n $TX && $action == stop ]]; then
    touch "$TX/service-stopped" || return 1
  fi
  return "$rc"
}

# ss 本地地址形如 0.0.0.0:443 或 [::]:443。过滤表达式不接受方括号。
ss_local_host() {
  local line=$1 tok i
  local -a toks=()
  line=${line%% users:*}
  read -r -a toks <<< "$line"
  for ((i = ${#toks[@]} - 1; i >= 1; i--)); do
    tok=${toks[i]}
    [[ $tok == *:* ]] || continue
    tok=${toks[i - 1]}
    [[ $tok == *:* ]] || continue
    if [[ $tok == \[*\]:* ]]; then
      tok=${tok#\[}
      tok=${tok%%\]:*}
    else
      tok=${tok%:*}
    fi
    printf '%s' "${tok,,}"
    return 0
  done
  return 1
}

listen_matches() {
  local want got
  want=$(ip_key "$1") || return 1
  if [[ $2 == '*' ]]; then
    [[ $want == 0.0.0.0 || $want == 0:0:0:0:0:0:0:0 ]]
  else
    got=$(ip_key "$2") || return 1
    [[ $got == "$want" ]]
  fi
}

socket_owned_by_kernel() {
  local transport=$1 listen=$2 port=$3 output line pid host
  [[ $transport == t || $transport == u ]] || return 1
  pid=$(service_pid) || return 1
  [[ $port =~ ^[0-9]+$ ]] || return 1
  # 只按端口过滤。IPv6 地址放进 ss 表达式会被方括号截断。
  output=$(ss -H -lnp "-$transport" "sport = :${port}" 2>/dev/null) || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    host=$(ss_local_host "$line") || continue
    listen_matches "$listen" "$host" || continue
    if [[ $line == *"pid=$pid,"* || $line == *"pid=$pid)"* ]]; then
      return 0
    fi
  done <<< "$output"
  return 1
}

listeners_ready() {
  local f proto net listen port
  command -v ss >/dev/null 2>&1 || return 1
  for f in "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    proto=$(jq -er '.protocol' "$f") || return 1
    net=$(jq -r '.network // ""' "$f") || return 1
    listen=$(jq -er '.listen' "$f") || return 1
    port=$(jq -er '.port' "$f") || return 1
    if uses_tcp "$proto" "$net"; then
      socket_owned_by_kernel t "$listen" "$port" || return 1
    fi
    if uses_udp "$proto" "$net"; then
      socket_owned_by_kernel u "$listen" "$port" || return 1
    fi
  done
}

kernel_stays_up() {
  local i pid previous='' stable=0
  svc "$1" || return 1
  for ((i = 0; i < 50; i++)); do
    pid=$(service_pid) || pid=''
    if [[ -n $pid && $pid == "$previous" ]] && listeners_ready; then
      stable=$((stable + 1))
      ((stable < 5)) || return 0
    else
      stable=0
    fi
    previous=$pid
    sleep 0.2
  done
  err "服务未稳定运行，或入站未完成 TCP/UDP 监听。"
  return 1
}

show_service_log() {
  if [[ $OS == debian ]] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u mihomo -n 40 --no-pager >&4 || true
  fi
  if [[ -f $STDERR_LOG && -s $STDERR_LOG ]]; then
    plainln "  --- stderr ---"
    tail -n 40 "$STDERR_LOG" >&4 || true
  fi
  ui "$GRN"
}

validate_managed_endpoints() {
  local f tag port proto network listen
  for f in "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    validate_meta "$f" || { err "元数据不合法: ${f}"; return 1; }
    tag=$(jq -er '.tag' "$f") || return 1
    port=$(jq -er '.port' "$f") || return 1
    proto=$(jq -er '.protocol' "$f") || return 1
    network=$(jq -r '.network // ""' "$f") || return 1
    listen=$(jq -er '.listen' "$f") || return 1
    if port_conflict "$port" "$tag" "$proto" "$network" "$listen"; then
      err "入站 ${tag} 与 ${CONFLICT_TAG} 的监听端点冲突。"
      return 1
    fi
  done
}

commit_tx() {
  if ! validate_managed_endpoints || ! box_test; then
    rollback_tx
    err "已回滚本次修改。"
    return 1
  fi
  if ! fix_tree_perms; then
    rollback_tx
    return 1
  fi
  if ! service_uses_panel_conf; then
    plainln "  正在更新服务..."
    if ! install_service; then
      rollback_tx
      err "无法更新服务文件，已回滚。"
      return 1
    fi
  fi
  if ((TX_WAS_RUNNING)); then
    TX_RESTART=1
    if ! kernel_stays_up restart; then
      rollback_tx
      err "入站启动失败，已尝试恢复原配置和服务。"
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
  if [[ ! -x $BIN ]]; then
    printf '%s' '-'
    return
  fi
  raw=$("$BIN" -v 2>/dev/null | head -n 1) || true
  raw=$(printf '%s\n' "$raw" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)
  raw=${raw#v}
  if [[ -z $raw ]]; then
    printf '%s' '-'
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
  # 只接受发行页上的数字版本，避免重定向落到奇怪的路径。
  if [[ ! $tag =~ ^v?[0-9]+(\.[0-9]+){1,2}$ ]]; then
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
  uin "  ${ACC}${BOLD}MIHOMO${RST}  ${DIM}服务与入站管理${RST}"
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

fetch_asset() {
  local version=$1 dest=$2 name=$3 url sum actual sha_pid
  url="https://github.com/${REPO}/releases/download/${version}/${name}"
  plainln "  下载 ${url}"
  rm -f -- "$dest/mihomo.gz" "$dest/sha256" "$dest/pack/mihomo"
  github_asset_sha "$version" "$name" >"$dest/sha256" &
  sha_pid=$!
  if ! curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 -o "$dest/mihomo.gz" "$url"; then
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
  actual=$(sha256sum "$dest/mihomo.gz" | awk '{print tolower($1)}')
  if [[ -z $sum || ${#sum} -ne 64 || $sum != "$actual" ]]; then
    err "SHA256 校验失败。"
    return 1
  fi
  plainln "  解压"
  gzip -dc "$dest/mihomo.gz" >"$dest/pack/mihomo" || { err "解压失败。"; return 1; }
  chmod 755 "$dest/pack/mihomo" || return 1
}

# 临时目录是 0700，nobody 需要沿路径穿越后才能执行。探测结束后收回工作目录权限。
probe_bin() {
  local bin=$1 p rc=0
  [[ -n $WORK_DIR && -d $WORK_DIR ]] || return 1
  if ! id -u nobody >/dev/null 2>&1 || ! command -v su >/dev/null 2>&1; then
    "$bin" -v >/dev/null 2>&1
    return
  fi
  p=${bin%/*}
  while [[ -n $p && $p != / ]]; do
    chmod o+x "$p" || return 1
    [[ $p == "$WORK_DIR" ]] && break
    p=${p%/*}
  done
  su -s /bin/sh -c 'exec "$1" -v >/dev/null 2>&1' nobody sh "$bin" || rc=$?
  chmod 700 "$WORK_DIR" || true
  return "$rc"
}

download_release() {
  local version=$1 dest=$2 machine name
  machine=$(asset_arch) || return 1
  name="mihomo-linux-${machine}-${version}.gz"
  fetch_asset "$version" "$dest" "$name" || return 1
  if probe_bin "$dest/pack/mihomo"; then
    return 0
  fi
  if [[ $machine != amd64 ]]; then
    err "程序无法执行，请确认架构。"
    return 1
  fi
  warn "当前 CPU 无法运行标准构建，改下 compatible。"
  name="mihomo-linux-${machine}-compatible-${version}.gz"
  fetch_asset "$version" "$dest" "$name" || return 1
  probe_bin "$dest/pack/mihomo" || { err "程序无法执行，请确认架构或 CPU。"; return 1; }
}

stage_release() {
  local version=$1 dest
  dest=$(private_tmpdir) || {
    err "无法创建临时目录。"
    return 1
  }
  mkdir -p "$dest/pack" || return 1
  download_release "$version" "$dest" || return 1
  printf '%s' "$dest"
}

place_binary() {
  local src=$1 new
  new=$(mktemp -p "$(dirname "$BIN")" .mihomo.XXXXXXXX) || return 1
  cp -- "$src" "$new" || { rm -f -- "$new"; return 1; }
  chown root:root "$new" || { rm -f -- "$new"; return 1; }
  chmod 755 "$new" || { rm -f -- "$new"; return 1; }
  drop_file_caps "$new"
  if ! mv -f -- "$new" "$BIN"; then
    rm -f -- "$new"
    return 1
  fi
  link_command
}

# 仅给 /var/lib 下的正式安装提供命令名，测试目录不写 /usr/local/bin。
link_command() {
  local link=$CMD_LINK
  [[ $BIN == /var/lib/* && -d ${link%/*} && ! -L ${link%/*} ]] || return 0
  if [[ -e $link || -L $link ]]; then
    [[ -L $link && $(readlink -- "$link") == "$BIN" ]] || warn "命令路径已被占用，未覆盖: ${link}"
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

# 不使用常被挂载为 noexec 的 /tmp；临时目录由 mktemp 创建为 0700。
private_parent() {
  local parent=${STATE_DIR%/*}
  if [[ -n $parent && -d $parent && ! -L $parent && -w $parent ]]; then
    printf '%s' "$parent"
    return 0
  fi
  if [[ -d /var/tmp && ! -L /var/tmp && -w /var/tmp ]]; then
    printf '%s' /var/tmp
    return 0
  fi
  return 1
}

private_tmpdir() {
  [[ -n $WORK_DIR && -d $WORK_DIR ]] || return 1
  mktemp -d "$WORK_DIR/tmp.XXXXXXXX"
}

private_tmpfile() {
  [[ -n $WORK_DIR && -d $WORK_DIR ]] || return 1
  mktemp "$WORK_DIR/file.XXXXXXXX"
}

install_logrotate() {
  local dir=${LOGROTATE_FILE%/*}
  [[ ! -L $dir && ! -L $LOGROTATE_FILE ]] || return 1
  if [[ ! -d $dir ]]; then
    install -d -m 755 "$dir" || return 1
  fi
  atomic_text "$LOGROTATE_FILE" 644 root root <<EOF
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
}

deploy_pack() {
  local src=$1
  create_box_user || return 1
  ensure_dirs || return 1
  place_binary "$src/mihomo" || return 1
  ensure_base_config || return 1
  rebuild_config || return 1
  fix_tree_perms || return 1
  install_service
}

fetch_latest() {
  local version
  plainln "  获取最新版本..."
  version=$(latest_version) || {
    err "无法获取版本，请检查到 GitHub 的网络。"
    return 1
  }
  plainln "  最新版本 ${version}"
  printf '%s' "$version"
}

install_kernel() {
  local work version
  header "安装内核"
  if [[ -x $BIN ]]; then
    plainln "  已安装 $(current_version)，更新请选「升级内核」。"
    pause
    return 0
  fi
  need_deps || return 0
  version=$(fetch_latest) || {
    pause
    return 0
  }
  work=$(stage_release "$version") || {
    pause
    return 0
  }
  begin_tx deploy || {
    pause
    return 0
  }
  if [[ -x $BIN ]]; then
    err "内核已被其他进程安装，请重新进入菜单。"
    end_tx
    pause
    return 0
  fi
  if ! deploy_pack "$work/pack" || ! validate_managed_endpoints || ! box_test; then
    rollback_tx
    err "安装失败，已尝试恢复安装前的文件。"
    pause
    return 0
  fi
  end_tx
  blank
  plainln "  安装完成。"
  kv "版本" "$(current_version)"
  kv "程序" "$BIN"
  kv "配置" "$CONF"
  kv "日志" "$LOG_DIR"
  kv "用户" "mihomo"
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
  need_deps || return 0
  current=$(current_version)
  plainln "  当前版本 ${current}"
  version=$(fetch_latest) || {
    pause
    return 0
  }
  cmp=$(ver_cmp "$version" "$current")
  if [[ $cmp -le 0 ]]; then
    if [[ $cmp -eq 0 ]]; then
      plainln "  已是最新版本。"
    else
      warn "当前版本高于最新正式版。"
    fi
    confirm "是否仍要重新安装此版本？" || return 0
  fi
  work=$(stage_release "$version") || {
    pause
    return 0
  }
  begin_tx deploy || {
    pause
    return 0
  }
  if [[ -f $CONF ]]; then
    plainln "  正在校验现有配置..."
    # 目录保持 root:mihomo 750，避免 /var/lib 下的临时内核被其他用户读到。
    chown root:mihomo "$WORK_DIR" "$work" "$work/pack" || {
      err "无法准备升级目录。"
      end_tx
      pause
      return 0
    }
    chmod 750 "$WORK_DIR" "$work" "$work/pack" || {
      err "无法准备升级目录。"
      end_tx
      pause
      return 0
    }
    chmod 755 "$work/pack/mihomo"
    if ! box_as_user "$work/pack/mihomo" "$work/test.err" "$CONF"; then
      err "新版本无法加载当前配置，已取消升级。"
      cat "$work/test.err" >&4 || true
      ui "$GRN"
      end_tx
      pause
      return 0
    fi
  fi
  if ! deploy_pack "$work/pack" || ! validate_managed_endpoints || ! box_test; then
    rollback_tx
    err "升级失败，已恢复原来的程序、配置和服务。"
    pause
    return 0
  fi
  if ((TX_WAS_RUNNING)); then
    TX_RESTART=1
    if kernel_stays_up restart; then
      plainln "  已升级到 $(current_version)，服务已重启。"
    else
      err "新版本没有完成监听，正在恢复。"
      show_service_log
      if rollback_tx; then
        plainln "  已恢复到 ${current}。"
      else
        show_service_log
      fi
      pause
      return 0
    fi
  else
    plainln "  已升级到 $(current_version)，服务未启动。"
  fi
  end_tx
  pause
}

start_kernel() {
  header "启动服务"
  need_deps || return 0
  with_lock start_kernel_locked || true
  pause
}

start_kernel_locked() {
  local action=start
  [[ -x $BIN ]] || { err "请先安装内核。"; return 1; }
  if is_running && service_uses_panel_conf; then
    plainln "  服务已在运行。"
    return 0
  fi
  begin_tx service || return 1
  if ! create_box_user || ! ensure_dirs || ! ensure_base_config \
    || ! validate_managed_endpoints || ! box_test \
    || { ! service_uses_panel_conf && ! install_service; }; then
    rollback_tx
    return 1
  fi
  ((TX_WAS_RUNNING == 0)) || action=restart
  if ! kernel_stays_up "$action"; then
    err "启动失败，正在恢复原配置和服务。"
    show_service_log
    rollback_tx
    return 1
  fi
  end_tx
  plainln "  服务已启动。"
}

stop_kernel() {
  header "停止服务"
  need_deps || return 0
  with_lock stop_kernel_locked || true
  pause
}

stop_kernel_locked() {
  if ! svc stop || is_running; then
    err "停止失败。"
    return 1
  fi
  plainln "  服务已停止。"
}

uninstall_kernel() {
  header "卸载内核"
  note "将删除内核、配置、证书、日志和用户。"
  confirm "确认卸载？" || return 0
  need_deps || return 0
  with_lock uninstall_kernel_locked || true
  pause
}

uninstall_kernel_locked() {
  validate_paths || return 1
  if [[ ! -x $BIN && ! -e $CONF_DIR && ! -e $STATE_DIR && ! -e $LOG_DIR ]] \
    && [[ ! -f $SYSTEMD_UNIT && ! -f $OPENRC_SERVICE ]]; then
    plainln "  内核未安装。"
    return 0
  fi
  begin_tx deploy || return 1
  if ! uninstall_files; then
    err "卸载失败，正在恢复文件和服务。"
    rollback_tx
    return 1
  fi
  rm -rf -- "$LOG_DIR" "$META_DIR" "$CERT_DIR" "$RUNTIME_DIR" || warn "外置数据目录未能完全删除。"
  remove_box_user || warn "账户或组未完全删除。"
  end_tx
  plainln "  卸载完成。"
}

uninstall_files() {
  local path
  if is_running || [[ -f $SYSTEMD_UNIT || -f $OPENRC_SERVICE ]]; then
    svc stop && ! is_running || return 1
    if [[ $OS == alpine ]]; then
      [[ ! -L $OPENRC_ENABLE_LINK ]] || rc-update del mihomo default || return 1
    elif [[ -e $SYSTEMD_ENABLE_LINK || -L $SYSTEMD_ENABLE_LINK ]]; then
      systemctl disable mihomo >/dev/null 2>&1 || return 1
    fi
  fi
  for path in "$CONF_DIR" "$STATE_DIR" "$META_DIR" "$CERT_DIR" "$LOG_DIR" "$RUNTIME_DIR" "${BIN%/*}"; do
    real_dir "$path" || return 1
  done
  [[ ! -d $STATE_DIR ]] || mv -- "$STATE_DIR" "$TX/state" || return 1
  rm -f -- "$BIN" "$SYSTEMD_UNIT" "$SYSTEMD_ENABLE_LINK" "$LOGROTATE_FILE" \
    "$OPENRC_SERVICE" "$OPENRC_ENABLE_LINK" || return 1
  rm -rf -- "$CONF_DIR" || return 1
  unlink_command || return 1
  if [[ $OS == debian ]]; then systemctl daemon-reload || return 1; fi
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
  local file=$1 pid
  header "实时日志"
  if [[ ! -f $file ]]; then
    plainln "  暂无日志。"
    pause
    return 0
  fi
  note "Ctrl+C 返回"
  blank
  tail -n 20 -f -- "$file" >&4 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' INT
  wait "$pid" 2>/dev/null || true
  trap 'exit 130' INT
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
  local proto=$1
  if [[ $proto == hysteria2 || $proto == tuic ]]; then
    return 1
  fi
  # Shadowsocks 的 udp 只额外打开 UDP，TCP 始终开启。
  return 0
}

uses_udp() {
  local proto=$1 net=$2
  if [[ $proto == hysteria2 || $proto == tuic ]]; then
    return 0
  fi
  if [[ $proto == shadowsocks && $net == *udp* ]]; then
    return 0
  fi
  return 1
}

listen_clash() {
  local a b
  a=$(ip_key "$1") || return 1
  b=$(ip_key "$2") || return 1
  [[ $a == "$b" || $a == 0:0:0:0:0:0:0:0 || $b == 0:0:0:0:0:0:0:0 ]] && return 0
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
  CONFLICT_TAG=${etag:-未命名监听}
}

yaml_top() {
  local key=$1 line val
  [[ -f $CONF ]] || return 1
  line=$(grep -m1 -E "^[\"']?${key}[\"']?[[:space:]]*:[[:space:]]*" "$CONF" || true)
  [[ -n $line ]] || return 1
  val=${line#*:}
  val=${val%%#*}
  val=${val//\"/}
  val=${val//\'/}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  [[ -n $val && $val != null && $val != '~' ]] || return 1
  printf '%s' "$val"
}

port_conflict() {
  local port=$1 except=$2 proto=$3 network=$4 listen=${5:-0.0.0.0}
  local f etag ep eproto enet elisten nt=0 nu=0
  local name value net allow bind builtin=127.0.0.1
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
  # 内置端口不在 listeners 里，仍占用地址。
  [[ -f $CONF ]] || return 1
  allow=$(yaml_top allow-lan || true)
  if [[ ${allow,,} == true || ${allow,,} == yes ]]; then
    bind=$(yaml_top bind-address || true)
    if [[ $bind == \[*\] ]]; then
      bind=${bind#\[}
      bind=${bind%\]}
    fi
    case ${bind,,} in
      ''|'*'|0.0.0.0) builtin=0.0.0.0 ;;
      ::) builtin=:: ;;
      *) builtin=$bind ;;
    esac
  fi
  for name in mixed-port socks-port tproxy-port port redir-port; do
    value=$(yaml_top "$name" || true)
    [[ -n $value ]] || continue
    value=${value#"${value%%[!0]*}"}
    [[ $value =~ ^[0-9]{1,5}$ ]] || continue
    ((10#$value >= 1 && 10#$value <= 65535)) || continue
    case $name in
      port|redir-port) net=tcp ;;
      *) net=tcp,udp ;;
    esac
    if endpoint_hits "$port" "$except" "$listen" "$nt" "$nu" "$name" shadowsocks "$net" "$value" "$builtin"; then
      return 0
    fi
  done
  return 1
}

is_domain() {
  ((${#1} <= 253)) && [[ $1 =~ [A-Za-z] && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
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

# 比较监听地址时展开 IPv6，避免同一地址的不同写法漏过冲突检查。
ip_key() {
  local ip=$1 a b c d
  if is_ipv4 "$ip"; then
    IFS=. read -r a b c d <<<"$ip"
    printf '%d.%d.%d.%d' "$((10#$a))" "$((10#$b))" "$((10#$c))" "$((10#$d))"
  else
    is_ipv6 "$ip" || return 1
    awk '
      function emit(s) { sub(/^0+/, "", s); printf "%s%s", sep, s == "" ? "0" : s; sep=":" }
      {
        split(tolower($0), halves, "::")
        n=split(halves[1], left, ":"); if (halves[1]=="") n=0
        if (index($0,"::")) {
          m=split(halves[2], right, ":"); if (halves[2]=="") m=0
          for(i=1;i<=n;i++) emit(left[i])
          for(i=0;i<8-n-m;i++) emit("0")
          for(i=1;i<=m;i++) emit(right[i])
        } else for(i=1;i<=n;i++) emit(left[i])
      }
    ' <<<"$ip"
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
      if is_ipv4 "$ans"; then ip_key "$ans"; else printf '%s' "${ans,,}"; fi
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
    ans=${ans#"${ans%%[!0]*}"}
    [[ -n $ans ]] || ans=0
    # 先限定位数，避免整数溢出。
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
      err "备注须为 1-80 个字符，且不能包含控制字符。"
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
      tport=${tport#"${tport%%[!0]*}"}
      [[ -n $tport ]] || tport=0
      if ((${#tport} > 5)) || ((10#$tport < 1 || 10#$tport > 65535)); then
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
  ans=${ans#"${ans%%[!0]*}"}
  [[ -n $ans ]] || ans=0
  if [[ $ans =~ ^[0-9]+$ ]] && ((${#ans} <= ${#max})) && ((10#$ans >= 1 && 10#$ans <= max)); then
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
    [[ -z $TX ]] || return 2
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
  choice=$(choose "传输" "取消" "tcp,udp" "tcp") || return $?
  case $choice in
    2) printf 'tcp' ;;
    *) printf 'tcp,udp' ;;
  esac
}

gen_ss_password() {
  local method=$1
  case $method in
    2022-blake3-aes-128-gcm) openssl rand -base64 16 | tr -d '\n' ;;
    2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305) openssl rand -base64 32 | tr -d '\n' ;;
    *) openssl rand -base64 24 | tr -d '\n' ;;
  esac
}

gen_uuid() {
  local h v
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '[:space:]' </proc/sys/kernel/random/uuid
    return
  fi
  h=$(openssl rand -hex 16 | tr -d '[:space:]') || return 1
  [[ ${#h} -eq 32 ]] || return 1
  v=$(printf '%x' $(( (16#${h:16:1} & 3) | 8 )))
  printf '%s-%s-4%s-%s%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$v" "${h:17:3}" "${h:20:12}"
}

gen_shortid() {
  openssl rand -hex 8 | tr -d '[:space:]'
}

gen_auth() {
  openssl rand -hex 16 | tr -d '[:space:]'
}

# 优先用内核生成密钥；否则用 openssl 从 32 字节种子构造 X25519 公钥。
gen_reality_pair() {
  local out priv pub
  if [[ -x $BIN ]]; then
    out=$("$BIN" generate reality-keypair 2>/dev/null | tr -d '\r') || true
    priv=$(printf '%s\n' "$out" | awk '/[Pp]rivate[Kk]ey/{print $NF; exit}')
    pub=$(printf '%s\n' "$out" | awk '/[Pp]ublic[Kk]ey/{print $NF; exit}')
    if [[ -n $priv && -n $pub ]]; then
      printf '%s\n%s\n' "$priv" "$pub"
      return 0
    fi
  fi
  local dir
  dir=$(private_tmpdir) || return 1
  # 种子含空字节，只能走文件；退出时由 WORK_DIR 统一清理。
  if ! openssl rand -out "$dir/seed" 32; then
    rm -rf -- "$dir"
    err "无法生成随机数。"
    return 1
  fi
  # RFC 8410：X25519 PKCS8 固定前缀，后面接 32 字节私钥种子。
  printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20' >"$dir/key.der"
  cat "$dir/seed" >>"$dir/key.der"
  if ! openssl pkey -inform DER -in "$dir/key.der" -pubout -outform DER -out "$dir/pub.der" 2>/dev/null; then
    rm -rf -- "$dir"
    err "无法生成 REALITY 密钥，请确认 openssl 支持 X25519。"
    return 1
  fi
  tail -c 32 "$dir/pub.der" >"$dir/pub"
  priv=$(openssl base64 -A -in "$dir/seed" | tr '+/' '-_' | tr -d '=\n')
  pub=$(openssl base64 -A -in "$dir/pub" | tr '+/' '-_' | tr -d '=\n')
  rm -rf -- "$dir"
  if [[ ${#priv} -lt 40 || ${#pub} -lt 40 ]]; then
    err "REALITY 密钥生成结果不完整。"
    return 1
  fi
  printf '%s\n%s\n' "$priv" "$pub"
}

is_uuid() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

ask_uuid() {
  local strict=${2:-} current=$1 ans bytes
  while true; do
    ans=$(regen_prompt "UUID" "$current") || return 2
    cancelled "$ans" && return 2
    if [[ -z $ans ]]; then
      if [[ -n $current ]]; then
        printf '%s' "$current"
      else
        gen_uuid || return 1
      fi
      return 0
    fi
    if is_regen "$ans"; then
      gen_uuid || return 1
      return 0
    fi
    if [[ $ans == *[[:cntrl:]]* ]]; then
      err "认证信息不能包含控制字符。"
      continue
    fi
    if [[ -n $strict ]]; then
      if is_uuid "$ans"; then
        printf '%s' "$ans"
        return 0
      fi
      err "请输入标准 UUID，或留空生成。"
      continue
    fi
    bytes=$(printf '%s' "$ans" | wc -c | tr -d ' ')
    if is_uuid "$ans" || ((bytes > 0 && bytes <= 30)); then
      printf '%s' "$ans"
      return 0
    fi
    err "UUID 不合法。可留空生成，或输入不超过 30 字节。"
  done
}

ask_password() {
  local label=$1 current=$2 method=$3 ans rc literal hint
  if [[ -n $current ]]; then
    hint="回车保留，g 重新生成，q 取消，\\ 后按字面"
  else
    hint="回车生成，q 取消，\\ 后按字面"
  fi
  while true; do
    ans=$(prompt "$label" "" "$hint" raw) || return 2
    literal=0
    if [[ $ans == \\* ]]; then
      ans=${ans:1}
      literal=1
    fi
    if ((literal == 0)); then
      if [[ -z $ans ]]; then
        if [[ -n $current ]]; then
          if [[ -n $method ]]; then
            ans=$(ss_key_canon "$method" "$current") || { err "密码长度不符，请输入 g 重新生成。"; continue; }
            printf '%s' "$ans"
          else
            printf '%s' "$current"
          fi
        elif [[ -n $method ]]; then
          gen_ss_password "$method" || return 1
        else
          gen_auth || return 1
        fi
        return 0
      fi
      if is_regen "$ans"; then
        if [[ -n $method ]]; then gen_ss_password "$method" || return 1
        else gen_auth || return 1; fi
        return 0
      fi
      cancelled "$ans" && return 2
    fi
    if ! secret_text_ok "$ans"; then
      err "密码须为 1-256 个字符，且不能包含控制字符。"
      continue
    fi
    if [[ -n $method ]]; then
      if ! ans=$(ss_key_canon "$method" "$ans"); then
        rc=$?
        if [[ $rc -eq 2 ]]; then err "2022 密钥须为标准或 URL-safe Base64。"
        else err "密码长度与加密方式不匹配。"; fi
        continue
      fi
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
  sid=$(gen_shortid) || return 1
  printf '%s\n%s\n%s\n' "$priv" "$pub" "$sid"
}

make_self_signed() {
  local cn=$1 dir san crt key
  dir=$(private_tmpdir) || {
    err "无法创建临时目录。"
    return 1
  }
  crt=$dir/cert.crt
  key=$dir/cert.key
  if is_ipv4 "$cn" || is_ipv6 "$cn"; then
    san="IP:${cn}"
  else
    san="DNS:${cn}"
  fi
  local subject=$cn
  # CN 最长 64 字节。超长名称只放进 SAN，校验以 SAN 为准。
  ((${#subject} <= 64)) || subject=mihomo
  if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$key" -out "$crt" -days 3650 \
    -subj "/CN=${subject}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    rm -rf -- "$dir"
    err "生成证书失败。"
    return 1
  fi
  chmod 600 "$crt" "$key" || return 1
  printf 'temp\n%s\n%s\n1\n' "$crt" "$key"
}

copy_cert_pair() {
  local tag=$1 src_crt=$2 src_key=$3 crt key
  crt=$CERT_DIR/${tag}.crt
  key=$CERT_DIR/${tag}.key
  if [[ ! -f $src_crt || ! -r $src_crt || ! -f $src_key || ! -r $src_key ]]; then
    err "证书或私钥不可读。"
    return 1
  fi
  local cert_pub key_pub
  openssl x509 -in "$src_crt" -checkend 0 -noout >/dev/null 2>&1 || { err "证书已过期。"; return 1; }
  cert_pub=$(openssl x509 -in "$src_crt" -pubkey -noout 2>/dev/null) || return 1
  key_pub=$(openssl pkey -in "$src_key" -passin pass: -pubout 2>/dev/null) || return 1
  [[ $cert_pub == "$key_pub" ]] || { err "证书与私钥不匹配。"; return 1; }
  make_dir 750 root mihomo "$CERT_DIR" || return 1
  # 先暂存，复制失败必须上报；事务负责恢复旧证书。
  local staged
  staged=$(private_tmpdir) || return 1
  if ! cp -- "$src_crt" "$staged/cert" || ! cp -- "$src_key" "$staged/key" \
    || ! atomic_text "$crt" 640 root mihomo <"$staged/cert" \
    || ! atomic_text "$key" 640 root mihomo <"$staged/key"; then
    rm -rf -- "$staged"
    return 1
  fi
  rm -rf -- "$staged"
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

ask_new_cert() {
  local pack host
  pack=$(ask_name "证书域名或 IP" "" name) || return 2
  read_fields "$pack" host
  sni=$host
  pack=$(ask_cert "$sni" "" "" 1) || return
  load_cert_fields "$pack"
}

ask_sni() {
  local pack
  pack=$(ask_name "证书域名或 IP" "$1" name) || return 1
  read_fields "$pack" sni
}

cert_covers() {
  local file=$1 name=$2
  [[ -f $file && ! -L $file ]] || return 1
  if is_ipv4 "$name" || is_ipv6 "$name"; then
    openssl x509 -in "$file" -noout -checkip "$name" >/dev/null 2>&1
  else
    openssl x509 -in "$file" -noout -checkhost "$name" >/dev/null 2>&1
  fi
}

# 证书盖不住 SNI 时，客户端不能开校验，否则分享链接一定握手失败。
note_cert_gap() {
  cert_covers "$cert" "$sni" && return 0
  [[ $insecure == 1 ]] && return 0
  warn "证书不包含 ${sni}，分享链接改为跳过校验。"
  insecure=1
}

set_share_insecure() {
  if [[ $1 == 0 ]]; then
    if ! cert_covers "$cert" "$sni"; then
      warn "证书不包含 ${sni}，不能改为校验证书。"
      return 1
    fi
    insecure=0
    return 0
  fi
  note "客户端将跳过证书校验。"
  insecure=1
}

align_sni_cert() {
  local old=$1
  if [[ $sni == "$old" ]] || cert_covers "$cert" "$sni"; then
    return 0
  fi
  warn "当前证书不包含 ${sni}。"
  if confirm "现在更换证书？"; then
    apply_field_cert "$sni" "$cert" "$key" "$insecure" || { sni=$old; return 1; }
    return 0
  fi
  if confirm "分享链接改为跳过证书校验？"; then
    insecure=1
    return 0
  fi
  sni=$old
  return 1
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
  [[ -f $META_DIR/${tag}.json ]]
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
  jq '{tag:"",remark:"",protocol:"",listen:"",port:0,
      network:"",method:"",password:"",uuid:"",flow:"",
      security:"",sni:"",target:"",targetPort:443,privateKey:"",publicKey:"",shortId:"",
      fingerprint:"chrome",auth:"",certFile:"",keyFile:"",insecure:false} + .'
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

valid_tag() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }

secret_text_ok() {
  [[ -n $1 && ${#1} -le 256 && $1 != *[[:cntrl:]]* ]]
}

validate_meta() {
  local file=$1 tag proto listen method password uuid flow sni target priv pub sid auth cert key bytes
  [[ -f $file && ! -L $file ]] || return 1
  tag=${file##*/}; tag=${tag%.json}
  valid_tag "$tag" || return 1
  jq -se --arg tag "$tag" '
    def text: type == "string" and (test("[\u0000-\u001f\u007f-\u009f]") | not);
    length == 1 and (.[0] |
      type == "object" and .tag == $tag
      and (.port | type == "number" and . == floor and . >= 1 and . <= 65535)
      and (.listen | text) and (.remark | text and length >= 1 and length <= 80)
      and (if .protocol == "shadowsocks" then
        (.network == "tcp" or .network == "udp" or .network == "tcp,udp")
        and (.method | text) and (.password | text)
      elif .protocol == "vless" then
        .security == "reality"
        and ([.uuid, .sni, .target, .privateKey, .publicKey, (.shortId // ""), (.flow // "")] | all(.[]; text))
        and (.targetPort | type == "number" and . == floor and . >= 1 and . <= 65535)
      elif .protocol == "hysteria2" or .protocol == "tuic" then
        ([.sni, .certFile, .keyFile] | all(.[]; text)) and (.insecure | type == "boolean")
        and (if .protocol == "hysteria2" then (.auth | text)
          else (.uuid | text) and (.password | text)
            and (.congestion == "bbr" or .congestion == "cubic" or .congestion == "new_reno") end)
      else false end))
  ' "$file" >/dev/null || return 1
  load_plain "$file" proto=protocol listen method password uuid flow sni target \
    priv=privateKey pub=publicKey sid=shortId auth cert=certFile key=keyFile || return 1
  ip_key "$listen" >/dev/null || return 1
  case $proto in
    shadowsocks)
      case $method in
        2022-blake3-aes-128-gcm | 2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305 \
          | aes-128-gcm | aes-256-gcm | chacha20-ietf-poly1305) ;;
        *) return 1 ;;
      esac
      secret_text_ok "$password" && ss_key_ok "$method" "$password"
      ;;
    vless)
      bytes=$(printf '%s' "$uuid" | wc -c)
      is_uuid "$uuid" || ((bytes > 0 && bytes <= 30)) || return 1
      [[ -z $flow || $flow == xtls-rprx-vision ]] || return 1
      share_host_ok "$sni" && share_host_ok "$target" || return 1
      [[ $priv =~ ^[A-Za-z0-9_-]{43}$ && $pub =~ ^[A-Za-z0-9_-]{43}$ \
        && $sid =~ ^([0-9a-fA-F]{2}){0,8}$ ]]
      ;;
    hysteria2 | tuic)
      share_host_ok "$sni" || return 1
      [[ $cert == "$CERT_DIR/${tag}.crt" && $key == "$CERT_DIR/${tag}.key" \
        && -f $cert && ! -L $cert && -f $key && ! -L $key ]] || return 1
      if [[ $proto == hysteria2 ]]; then secret_text_ok "$auth"
      else is_uuid "$uuid" && secret_text_ok "$password"; fi
      ;;
  esac
}

# 只替换标记之间的面板配置，不解析其余 YAML。
render_managed() {
  local f block
  printf '%s\n' "# mihomo-panel:begin"
  printf '%s\n' "listeners:"
  if ! compgen -G "$META_DIR/*.json" >/dev/null; then
    printf '%s\n' "  []"
  else
    for f in "$META_DIR"/*.json; do
      validate_meta "$f" || { err "元数据不合法: ${f}"; return 1; }
      block=$(render_listener <"$f") || return 1
      printf '%s\n' "$block"
    done
  fi
  printf '%s\n' "# mihomo-panel:end"
}

render_listener() {
  jq -r '
    def q: tojson;
    def listen_line:
      "  - name: " + (.tag | q) + "\n"
      + "    type: " + .protocol + "\n"
      + "    listen: " + (.listen | q) + "\n"
      + "    port: " + (.port | tostring);
    if .protocol == "shadowsocks" then
      listen_line
      + "\n    cipher: " + (.method | q)
      + "\n    password: " + (.password | q)
      + (if .network == "tcp" then "\n    udp: false" else "\n    udp: true" end)
    elif .protocol == "vless" then
      listen_line
      + "\n    users:"
      + "\n      - username: " + (.tag | q)
      + "\n        uuid: " + (.uuid | q)
      + "\n        flow: " + (.flow | q)
      + "\n    reality-config:"
      + "\n      dest: " + (((if (.target | contains(":")) then "[" + .target + "]" else .target end) + ":" + (.targetPort | tostring)) | q)
      + "\n      private-key: " + (.privateKey | q)
      + "\n      short-id:"
      + "\n        - " + (.shortId | q)
      + "\n      server-names:"
      + "\n        - " + (.sni | q)
    elif .protocol == "hysteria2" then
      listen_line
      + "\n    users:"
      + "\n      " + (.tag | q) + ": " + (.auth | q)
      + "\n    ignore-client-bandwidth: true"
      + "\n    certificate: " + (.certFile | q)
      + "\n    private-key: " + (.keyFile | q)
      + "\n    alpn:"
      + "\n      - h3"
    elif .protocol == "tuic" then
      if (.congestion != "bbr" and .congestion != "cubic" and .congestion != "new_reno")
        or (.uuid | length) == 0 or (.password | length) == 0 then
        error("invalid tuic")
      else
        listen_line
        + "\n    users:"
        + "\n      " + (.uuid | q) + ": " + (.password | q)
        + "\n    certificate: " + (.certFile | q)
        + "\n    private-key: " + (.keyFile | q)
        + "\n    congestion-controller: " + (.congestion | q)
        + "\n    alpn:"
        + "\n      - h3"
      end
    else
      error("unknown protocol")
    end
  '
}

# 用单次扫描替换标记块；发现手写入站或损坏标记时不改原文件。
rebuild_config() {
  local managed base tmp rc=0
  managed=$(private_tmpfile) || return 1
  base=$(private_tmpfile) || return 1
  tmp=$(private_tmpfile) || return 1
  render_managed >"$managed" || return 1
  if [[ -f $CONF ]]; then cp -- "$CONF" "$base" || return 1
  else empty_config >"$base" || return 1; fi
  if ! awk -v block="$managed" '
    function insert_block( line) {
      while ((getline line < block) > 0) print line
      close(block)
    }
    { sub(/\r$/, "") }
    /^# mihomo-panel:begin$/ {
      if (begins++ || ends) bad=1
      managed=1; insert_block(); next
    }
    /^# mihomo-panel:end$/ {
      if (!managed || ends++) bad=1
      managed=0; next
    }
    managed { next }
    empty_list {
      if ($0 ~ /^[[:space:]]*(#.*)?$/) { print; next }
      if ($0 ~ /^[[:space:]]*\[\][[:space:]]*(#.*)?$/) { empty_list=0; next }
      bad=1; empty_list=0
    }
    /^[\042\047]?listeners[\042\047]?[[:space:]]*:/ {
      value=$0; sub(/^[^:]*:[[:space:]]*/, "", value)
      if (value ~ /^\[\][[:space:]]*(#.*)?$/) next
      if (value ~ /^(#.*)?$/) { empty_list=1; next }
      bad=1; next
    }
    { print }
    END {
      if (managed || begins != ends || empty_list) bad=1
      if (!begins && !bad) { print ""; insert_block() }
      exit bad
    }
  ' "$base" >"$tmp"; then
    err "配置含有面板外的 listeners，或面板标记不完整；原配置未改动。"
    rc=1
  elif ! atomic_text "$CONF" 640 root mihomo <"$tmp"; then
    rc=1
  fi
  rm -f -- "$managed" "$base" "$tmp"
  return "$rc"
}

save_meta_and_inbound() {
  local tag=$1 meta_json
  valid_tag "$tag" || return 1
  meta_json=$(cat) || return 1
  if [[ -z $meta_json ]] || ! printf '%s' "$meta_json" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null; then
    return 1
  fi
  printf '%s' "$meta_json" | atomic_text "$META_DIR/${tag}.json" 600 root root || return 1
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
  local proto=$1 port=$2 network=${3:-} what="TCP"
  if [[ $proto == hysteria2 || $proto == tuic ]]; then
    what="UDP"
  elif [[ $proto == shadowsocks && $network != tcp ]]; then
    what="TCP/UDP"
  fi
  plainln "  请放行 ${what} ${port}。"
}

need_tx() {
  begin_tx || { pause; return 1; }
}

finish_inbound() {
  local tag=$1 proto=$2 port=$3 network
  # 在当前 shell 重建，避免状态留在管道子 shell。
  save_meta_and_inbound "$tag" <<<"$4" || { rollback_tx; err "写入失败。"; pause; return 1; }
  commit_tx || { pause; return 1; }
  network=$(printf '%s' "$4" | jq -r '.network // ""')
  firewall_hint "$proto" "$port" "$network"
  pause
}

load_cert_fields() {
  read_fields "$1" cert_mode cert key insecure
  if [[ $cert_mode == temp ]]; then
    cert_show="自签证书"
  else
    cert_show=$cert
  fi
}

drop_temp_cert() {
  [[ $1 == temp && -n $WORK_DIR && $2 == "$WORK_DIR/"*/cert.crt ]] || return 0
  rm -rf -- "${2%/*}"
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

commit_edit() {
  local staged=$1 tag=$2 proto=$3 port=$4 doc=$5
  if ((staged == 0)); then
    confirm_write || return 1
    if [[ -z $doc ]]; then
      meta_write_error
      return 1
    fi
    need_tx || return 1
  fi
  finish_doc "$tag" "$proto" "$port" "$doc"
}

ss_wizard() {
  STORE_REV=$(store_revision) || return 1
  local tag="" listen port remark method password network doc
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
  doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") || doc=""
  commit_edit 0 "$tag" shadowsocks "$port" "$doc" || return 0
}

vless_wizard() {
  STORE_REV=$(store_revision) || return 1
  local tag="" listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys doc
  flow=xtls-rprx-vision
  note "VLESS REALITY 仅 TCP，流控 xtls-rprx-vision。"
  blank
  listen=$(ask_listen "0.0.0.0") || return 0
  port=$(ask_port 443 "" vless tcp "$listen") || return 0
  tag=$(new_tag vless "$port")
  remark=$(ask_remark "vless-${port}") || return 0
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
  doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
    "$sni" "$target" "$tport" "$priv" "$pub" "$sid") || doc=""
  commit_edit 0 "$tag" vless "$port" "$doc" || return 0
}

hy_wizard() {
  STORE_REV=$(store_revision) || return 1
  local tag="" listen port remark auth sni cert key insecure
  local cert_mode="" cert_show="" doc
  note "Hysteria2 走 QUIC，必须启用 TLS。"
  blank
  listen=$(ask_listen "0.0.0.0") || return 0
  port=$(ask_port 443 "" hysteria2 udp "$listen") || return 0
  tag=$(new_tag hy2 "$port")
  remark=$(ask_remark "hy2-${port}") || return 0
  ask_new_cert || { [[ $? -eq 1 ]] && pause; return 0; }
  note_cert_gap
  auth=$(ask_password "认证密码" "" "") || return 0
  blank
  kv "协议" "Hysteria2"
  kv "监听" "$(uri_host "$listen"):${port}/udp"
  kv "SNI" "$sni"
  kv "证书" "$cert_show"
  kv "校验" "$([[ $insecure == 1 ]] && printf '跳过' || printf '启用')"
  kv "ALPN" "h3"
  kv "认证" "$auth"
  kv "备注" "$remark"
  blank
  confirm_write || return 0
  need_tx || return 0
  stage_chosen_cert "$tag" || return 0
  doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") || doc=""
  finish_doc "$tag" hysteria2 "$port" "$doc" || return 0
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

tuic_wizard() {
  STORE_REV=$(store_revision) || return 1
  local tag="" listen port remark uuid password sni cert key insecure congestion
  local cert_mode="" cert_show="" doc
  note "TUIC v5 走 QUIC，必须启用 TLS。"
  blank
  listen=$(ask_listen "0.0.0.0") || return 0
  port=$(ask_port 443 "" tuic udp "$listen") || return 0
  tag=$(new_tag tuic "$port")
  remark=$(ask_remark "tuic-${port}") || return 0
  congestion=$(ask_congestion) || return 0
  ask_new_cert || { [[ $? -eq 1 ]] && pause; return 0; }
  note_cert_gap
  uuid=$(ask_uuid "" strict) || return 0
  password=$(ask_password "密码" "" "") || return 0
  blank
  kv "协议" "TUIC v5"
  kv "监听" "$(uri_host "$listen"):${port}/udp"
  kv "SNI" "$sni"
  kv "证书" "$cert_show"
  kv "校验" "$([[ $insecure == 1 ]] && printf '跳过' || printf '启用')"
  kv "ALPN" "h3"
  kv "拥塞" "$congestion"
  kv "UUID" "$uuid"
  kv "密码" "$password"
  kv "备注" "$remark"
  blank
  confirm_write || return 0
  need_tx || return 0
  stage_chosen_cert "$tag" || return 0
  doc=$(meta_tuic "$tag" "$remark" "$listen" "$port" "$uuid" "$password" "$sni" \
    "$cert" "$key" "$insecure" "$congestion") || doc=""
  finish_doc "$tag" tuic "$port" "$doc" || return 0
}

prepare_store() {
  if ! id -u mihomo >/dev/null 2>&1; then
    err "缺少服务用户，请先安装内核。"
    pause
    return 1
  fi
  ensure_dirs || return 1
  STORE_REV=$(store_revision) || return 1
}

ready_panel() {
  require_kernel || return 1
  need_deps || return 1
  prepare_store
}

add_inbound() {
  local choice
  ready_panel || return 0
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
  choice_menu fields "$title" "完成" "$remark" "$@"
}

ss_key_canon() {
  local method=$1 password=$2 need padded got canonical
  case $method in
    2022-blake3-aes-128-gcm) need=16 ;;
    2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305) need=32 ;;
    *) printf '%s' "$password"; return 0 ;;
  esac
  [[ $password =~ ^[A-Za-z0-9+/_-]+={0,2}$ ]] || return 2
  padded=${password//-/+}
  padded=${padded//_//}
  padded=${padded%%=*}
  case $((${#padded} % 4)) in
    0) ;;
    2) padded+='==' ;;
    3) padded+='=' ;;
    *) return 2 ;;
  esac
  got=$(printf '%s' "$padded" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]') || return 1
  [[ ${got:-0} -eq $need ]] || return 1
  canonical=$(printf '%s' "$padded" | openssl base64 -d -A 2>/dev/null | openssl base64 -A | tr -d '\n') || return 1
  [[ -n $canonical ]] || return 1
  printf '%s' "$canonical"
}

ss_key_ok() { ss_key_canon "$1" "$2" >/dev/null; }

apply_field_cert() {
  local cert_pack rc
  cert_pack=$(ask_cert "$1" "$2" "$3" "$4") || {
    rc=$?
    [[ $rc -eq 1 ]] && pause
    return "$rc"
  }
  load_cert_fields "$cert_pack"
  note_cert_gap
}

set_value() {
  local name=$1 value rc
  shift
  if value=$("$@"); then
    printf -v "$name" '%s' "$value"
  else
    rc=$?
    return "$rc"
  fi
}

edit_ss() {
  local meta=$1 choice doc
  local tag listen port remark method password network orig cur
  validate_meta "$meta" || return 1
  load_plain "$meta" tag listen port remark method password || return 1
  network=$(jq -r 'if .network == "udp" then "tcp,udp" else .network end' "$meta")
  orig=$(printf '%s\n' "$listen" "$port" "$network" "$remark" "$method" "$password")
  while true; do
    choice=$(edit_loop "修改 Shadowsocks" "$remark" \
      "监听=$listen" "端口=$port" "传输=$network" \
      "备注=$remark" "加密=$method" "密码=已设置 · 选择修改") || break
    case $choice in
      1) set_value listen ask_listen "$listen" || continue ;;
      2) set_value port ask_port "$port" "$tag" shadowsocks "$network" "$listen" || continue ;;
      3)
        local next_network
        next_network=$(ask_ss_network) || continue
        if port_conflict "$port" "$tag" shadowsocks "$next_network" "$listen"; then
          err "端口 ${port} 与入站 ${CONFLICT_TAG} 冲突。"
          pause
          continue
        fi
        network=$next_network
        ;;
      4) set_value remark ask_remark "$remark" || continue ;;
      5)
        local next_method next_password
        next_method=$(ask_method) || continue
        if ! next_password=$(ss_key_canon "$next_method" "$password"); then
          note "新加密方式需要不同长度的密钥，请设置密码。"
          next_password=$(ask_password "密码" "" "$next_method") || continue
        fi
        method=$next_method
        password=$next_password
        ;;
      6) set_value password ask_password "密码" "$password" "$method" || continue ;;
      *) continue ;;
    esac
  done
  cur=$(printf '%s\n' "$listen" "$port" "$network" "$remark" "$method" "$password")
  [[ $cur == "$orig" ]] && return 0
  doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") || doc=""
  commit_edit 0 "$tag" shadowsocks "$port" "$doc" || return 0
}

edit_vless() {
  local meta=$1 choice doc
  local tag listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys dest orig cur
  validate_meta "$meta" || return 1
  load_plain "$meta" tag listen port remark uuid sni target priv=privateKey pub=publicKey sid=shortId || return 1
  flow=$(jq -r '.flow // "xtls-rprx-vision"' "$meta")
  tport=$(jq -r '.targetPort // 443' "$meta")
  orig=$(printf '%s\n' "$listen" "$port" "$remark" "$uuid" "$flow" \
    "$sni" "$target" "$tport" "$priv" "$pub" "$sid")
  while true; do
    choice=$(edit_loop "修改 VLESS REALITY" "$remark" \
      "监听=$listen" "端口=$port" "备注=$remark" \
      "伪装=${target}:${tport}" "公钥=$pub" "UUID=$uuid") || break
    case $choice in
      1) set_value listen ask_listen "$listen" || continue ;;
      2) set_value port ask_port "$port" "$tag" vless tcp "$listen" || continue ;;
      3) set_value remark ask_remark "$remark" || continue ;;
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
      6) set_value uuid ask_uuid "$uuid" || continue ;;
    esac
  done
  cur=$(printf '%s\n' "$listen" "$port" "$remark" "$uuid" "$flow" \
    "$sni" "$target" "$tport" "$priv" "$pub" "$sid")
  [[ $cur == "$orig" ]] && return 0
  doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
    "$sni" "$target" "$tport" "$priv" "$pub" "$sid") || doc=""
  commit_edit 0 "$tag" vless "$port" "$doc" || return 0
}

edit_quic() {
  local meta=$1 choice doc proto title tag listen port remark auth uuid password sni cert key insecure congestion
  local cert_mode=keep cert_show='' orig cur old_sni check_choice check_label
  local -a rows
  validate_meta "$meta" || return 1
  load_plain "$meta" proto=protocol tag listen port remark auth uuid password sni cert=certFile key=keyFile congestion || return 1
  insecure=$(jq -r 'if .insecure then 1 else 0 end' "$meta")
  orig=$(printf '%s\n' "$listen" "$port" "$remark" "$auth" "$uuid" "$password" \
    "$sni" "$cert" "$key" "$insecure" "$congestion" "$cert_mode")
  while true; do
    rows=("监听=$listen" "端口=$port" "备注=$remark" "域名=$sni" "证书=$cert")
    if [[ $proto == hysteria2 ]]; then
      title=Hysteria2
      rows+=("认证=已设置 · 选择修改")
    else
      title="TUIC v5"
      rows+=("拥塞=$congestion" "UUID=$uuid" "密码=已设置 · 选择修改")
    fi
    check_label=启用
    [[ $insecure == 1 ]] && check_label=跳过
    rows+=("校验=$check_label")
    check_choice=${#rows[@]}
    choice=$(edit_loop "修改 $title" "$remark" "${rows[@]}") || break
    case $choice in
      1) set_value listen ask_listen "$listen" || continue ;;
      2) set_value port ask_port "$port" "$tag" "$proto" udp "$listen" || continue ;;
      3) set_value remark ask_remark "$remark" || continue ;;
      4)
        old_sni=$sni
        ask_sni "$sni" || continue
        align_sni_cert "$old_sni" || continue
        ;;
      5) apply_field_cert "$sni" "$cert" "$key" "$insecure" || continue ;;
      6)
        if [[ $proto == hysteria2 ]]; then set_value auth ask_password "认证密码" "$auth" "" || continue
        else set_value congestion ask_congestion || continue; fi
        ;;
      "$check_choice") set_share_insecure $((1 - insecure)) || continue ;;
      7) set_value uuid ask_uuid "$uuid" strict || continue ;;
      8) set_value password ask_password "密码" "$password" "" || continue ;;
      *) continue ;;
    esac
  done
  cur=$(printf '%s\n' "$listen" "$port" "$remark" "$auth" "$uuid" "$password" \
    "$sni" "$cert" "$key" "$insecure" "$congestion" "$cert_mode")
  [[ $cur == "$orig" ]] && return 0
  confirm_write || return 0
  need_tx || return 0
  if [[ $cert_mode != keep ]]; then stage_chosen_cert "$tag" || return 0; fi
  if [[ $proto == hysteria2 ]]; then
    doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") || doc=""
  else
    doc=$(meta_tuic "$tag" "$remark" "$listen" "$port" "$uuid" "$password" "$sni" \
      "$cert" "$key" "$insecure" "$congestion") || doc=""
  fi
  finish_doc "$tag" "$proto" "$port" "$doc" || return 0
}

edit_inbound() {
  local picked
  ready_panel || return 0
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
  need_deps || return 0
  prepare_store || return 0
  pick_inbound "删除入站" || return 0
  picked=$PICKED
  tag=$(jq -r '.tag' "$picked")
  blank
  kv "删除" "$(proto_label "$picked")  $(jq -r '.port' "$picked")  $(jq -r '.remark' "$picked")"
  confirm "确认删除？" || return 0
  need_tx || return 0
  if ! rm -f -- "$META_DIR/${tag}.json" || ! rebuild_config || ! gc_certs; then
    rollback_tx
    err "写入失败。"
    pause
    return 0
  fi
  if [[ -x $BIN ]]; then
    commit_tx || { pause; return 0; }
  else
    if ! fix_tree_perms; then
      rollback_tx
      pause
      return 0
    fi
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
  jq -nr --arg v "$1" '$v|@uri'
}

b64url() {
  printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '=\n'
}

is_public_ipv4() {
  local o1 o2 o3
  is_ipv4 "$1" || return 1
  IFS=. read -r o1 o2 o3 _ <<<"$1"
  o1=$((10#$o1))
  o2=$((10#$o2))
  ((o1 == 0 || o1 == 10 || o1 == 127 || o1 >= 224)) && return 1
  ((o1 == 100 && o2 >= 64 && o2 <= 127)) && return 1
  ((o1 == 169 && o2 == 254)) && return 1
  ((o1 == 172 && o2 >= 16 && o2 <= 31)) && return 1
  o3=$((10#$o3))
  ((o1 == 192 && (o2 == 168 || (o2 == 0 && (o3 == 0 || o3 == 2))))) && return 1
  ((o1 == 198 && (o2 == 18 || o2 == 19 || (o2 == 51 && o3 == 100)))) && return 1
  ((o1 == 203 && o2 == 0 && o3 == 113)) && return 1
  return 0
}

is_public_ipv6() {
  local ip head
  ip=$(ip_key "$1") || return 1
  head=${ip%%:*}
  [[ $head =~ ^[23][0-9a-f]{3}$ && $ip != 2001:db8:* && $ip != 3fff:* ]]
}

fetch_ip() {
  curl -"$1" -fsS --connect-timeout 2 --max-time 4 -o "$3" "$2" 2>/dev/null
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

fallback_ip() {
  local fam=$1 primary=$2 alt_url=$3 alt_file=$4 ip
  ip=$(read_public_ip "$primary" "$fam" || true)
  if [[ -z $ip ]]; then
    fetch_ip "$fam" "$alt_url" "$alt_file" || true
    ip=$(read_public_ip "$alt_file" "$fam" || true)
  fi
  printf '%s' "$ip"
}

# 输出两行：公网 IPv4、公网 IPv6，没有则留空。
detect_public_ips() {
  local dir v4="" v6="" p4 p6
  dir=$(private_tmpdir) || return 1
  fetch_ip 4 https://api.ipify.org "$dir/4" &
  p4=$!
  fetch_ip 6 https://api6.ipify.org "$dir/6" &
  p6=$!
  wait "$p4" || true
  wait "$p6" || true
  v4=$(fallback_ip 4 "$dir/4" https://ipv4.icanhazip.com "$dir/4b")
  v6=$(fallback_ip 6 "$dir/6" https://ipv6.icanhazip.com "$dir/6b")
  rm -rf -- "$dir"
  printf '%s\n%s\n' "$v4" "$v6"
}

share_host_ok() {
  local host=$1
  if [[ $host == \[*\] ]]; then
    host=${host#\[}
    host=${host%\]}
  fi
  is_ipv4 "$host" || is_ipv6 "$host" || is_domain "$host"
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
      printf 'ss://%s@%s:%s#%s\n' "$(b64url "${method}:${password}")" "$host" "$port" "$enc"
      ;;
    vless)
      uuid=$(jq -r '.uuid' "$meta")
      flow=$(jq -r '.flow' "$meta")
      sni=$(urlenc "$(jq -r '.sni' "$meta")")
      fp=$(urlenc "$(jq -r '.fingerprint // "chrome"' "$meta")")
      pub=$(urlenc "$(jq -r '.publicKey' "$meta")")
      sid=$(urlenc "$(jq -r '.shortId' "$meta")")
      local query="encryption=none&security=reality&sni=${sni}&fp=${fp}&type=tcp&pbk=${pub}&sid=${sid}"
      if [[ -n $flow && $flow != null ]]; then
        query+="&flow=$(urlenc "$flow")"
      fi
      printf 'vless://%s@%s:%s?%s#%s\n' "$(urlenc "$uuid")" "$host" "$port" "$query" "$enc"
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
      kv "传输" "$(jq -r 'if .network == "udp" then "tcp,udp" else .network end' "$meta")"
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

save_host() {
  make_dir 750 root mihomo "$STATE_DIR" || return 1
  printf '%s\n' "$1" | atomic_text "$STATE_DIR/server_addr" 600 root root
}

share_inbound() {
  local picked host default link v4="" v6=""
  local -a found=() hosts=()
  need_deps || return 0
  pick_inbound "分享入站" || return 0
  picked=$PICKED
  plainln "  正在检测公网地址..."
  mapfile -t found < <(detect_public_ips || true)
  v4=${found[0]:-}
  v6=${found[1]:-}
  local listen
  listen=$(jq -er '.listen' "$picked") || return 0
  if [[ -n $v4 ]] && listen_clash "$listen" "$v4"; then hosts+=("$v4"); fi
  if [[ -n $v6 ]] && listen_clash "$listen" "$v6"; then hosts+=("$v6"); fi
  if ((${#hosts[@]})); then
    blank
    note "检测到的公网地址："
    for host in "${hosts[@]}"; do
      share_addr "地址" "$host"
    done
    if ! confirm "用这些地址生成分享链接？"; then
      hosts=()
    fi
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
    with_lock save_host "$host" || {
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
  pause
}

main_menu() {
  local choice msg="" p
  p=$(printf '\001%s\002  选择 \001%s\002q 退出\001%s\002: ' "$GRN" "$DIM" "$GRN")
  while true; do
    [[ -z $TX ]] || { err "存在未恢复的事务: ${TX}，退出面板。"; return 1; }
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
mihomo 管理面板

用法: sudo ./mihomo.sh

文档: https://wiki.metacubex.one/
系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
入站: Shadowsocks、VLESS REALITY、Hysteria2、TUIC v5
内核以 mihomo 用户运行。
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
  if [[ ! -d /run || -L /run ]]; then
    LOCK_FILE=${STATE_DIR%/*}/.mihomo.lock
  fi
  validate_paths || return 1
  init_ui
  local parent
  parent=$(private_parent) || return 1
  WORK_DIR=$(mktemp -d "$parent/.mihomo-work.XXXXXXXX") || return 1
  main_menu
}

if [[ ${MIHOMO_PANEL_SOURCE:-0} != 1 ]]; then
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
MIHOMO_PANEL_PAYLOAD
