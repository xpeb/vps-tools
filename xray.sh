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
    apk add --no-cache bash
  elif [ -f /etc/debian_version ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends bash
  else
    echo "仅支持 Debian 与 Alpine。" >&2
    exit 1
  fi
fi

# 脚本走独立 fd，避免 bash -s 把 heredoc 当成 read 的输入。
exec bash /dev/fd/3 "$@" 3<<'XRAY_PANEL_PAYLOAD'
set -uo pipefail
set +H
set +o history
umask 077
shopt -s nullglob

BIN=/usr/local/bin/xray
CONF=/usr/local/etc/xray/config.json
CONF_DIR=/usr/local/etc/xray
LOG_DIR=/var/log/xray
STATE_DIR=/var/lib/xray
META_DIR=/var/lib/xray/meta
CERT_DIR=/var/lib/xray/certs
STDOUT_LOG=/var/log/xray/stdout.log
STDERR_LOG=/var/log/xray/stderr.log
WIDTH=42
REPO=XTLS/Xray-core

GRN=$'\033[38;2;126;217;167m'
RED=$'\033[38;2;255;107;107m'
YEL=$'\033[38;2;240;200;120m'
DIM=$'\033[38;2;90;122;104m'
RST=$'\033[0m'
BOLD=$'\033[1m'
OFFBOLD=$'\033[22m'

OS=""
TX=""
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
item() { printf '  %s%s\n' "$(pad "$1" 3)" "$2" >&4; }
blank() { uin ""; }

cleanup() {
  local p
  if ((${#TMP_PATHS[@]})); then
    for p in "${TMP_PATHS[@]}"; do
      if [[ -n $p && -e $p ]]; then
        rm -rf -- "$p"
      fi
    done
  fi
  printf '%b' "$RST" >&4 2>/dev/null || printf '%b' "$RST" || true
}

char_width() {
  local cp=$1
  if ((cp < 0x1100)); then
    printf '1'
    return
  fi
  if (( (cp >= 0x1100 && cp <= 0x115F) \
     || (cp >= 0x2E80 && cp <= 0xA4CF) \
     || (cp >= 0xAC00 && cp <= 0xD7A3) \
     || (cp >= 0xF900 && cp <= 0xFAFF) \
     || (cp >= 0xFE10 && cp <= 0xFE6F) \
     || (cp >= 0xFF00 && cp <= 0xFF60) \
     || (cp >= 0xFFE0 && cp <= 0xFFE6) \
     || (cp >= 0x1F300 && cp <= 0x1FAFF) \
     || (cp >= 0x20000 && cp <= 0x3FFFD) )); then
    printf '2'
  else
    printf '1'
  fi
}

dw() {
  local s=$1 i n w cp
  n=${#s}
  w=0
  for ((i = 0; i < n; i++)); do
    cp=$(printf '%d' "'${s:i:1}")
    w=$((w + $(char_width "$cp")))
  done
  printf '%s' "$w"
}

pad() {
  local s=$1 width=$2 w
  w=$(dw "$s")
  printf '%s' "$s"
  while ((w < width)); do
    printf ' '
    w=$((w + 1))
  done
}

spaces() {
  local n=$1 i s=""
  for ((i = 0; i < n; i++)); do
    s+=" "
  done
  printf '%s' "$s"
}

cls() {
  ui $'\033[H\033[2J'
  ui "$GRN"
}

header() {
  cls
  uin "  ${BOLD}${1}${OFFBOLD}"
  uin "  ${RULE}"
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
  if ((${#pkgs[@]} == 0)); then
    return 0
  fi
  plainln "  安装依赖: ${pkgs[*]}"
  if [[ $OS == alpine ]]; then
    apk add --no-cache "${pkgs[@]}" ca-certificates
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends "${pkgs[@]}" ca-certificates
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
  install -d -m 755 -o root -g root /var/empty
  if id -u xray >/dev/null 2>&1; then
    if [[ $(id -u xray) -eq 0 || $(id -g xray) -eq 0 ]]; then
      err "已有的 xray 账户不能是 root。"
      return 1
    fi
    if ! box_group_ok; then
      err "已有的 xray 账户不在 xray 组中，校验与服务会使用不同身份。"
      return 1
    fi
    warn "已存在 xray 用户，继续使用该账户运行内核。"
    return 0
  fi
  plainln "  创建 xray 用户"
  # systemd-sysusers 把 "Creating group/user" 写到 stderr，必须两路都丢掉。
  # 装了 systemd 的 Alpine 也会走到这里，不能只看发行版。
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
  if [[ $(id -u xray) -eq 0 || $(id -g xray) -eq 0 ]]; then
    err "xray 账户不能是 root。"
    return 1
  fi
}

make_dir() {
  local mode=$1 owner=$2 group=$3 dir=$4
  if [[ -d $dir ]]; then
    return 0
  fi
  install -d -m "$mode" -o "$owner" -g "$group" "$dir"
}

ensure_dirs() {
  local f
  make_dir 750 root xray "$CONF_DIR"
  make_dir 750 root xray "$LOG_DIR"
  make_dir 750 root xray "$STATE_DIR"
  make_dir 700 root root "$META_DIR"
  make_dir 750 root xray "$CERT_DIR"
  if [[ -d $STATE_DIR ]]; then
    chown root:xray "$STATE_DIR"
    chmod 750 "$STATE_DIR"
  fi
  for f in "$STDOUT_LOG" "$STDERR_LOG"; do
    if [[ ! -e $f ]]; then
      install -m 600 -o xray -g xray /dev/null "$f"
    fi
  done
  repair_conf_access
}

atomic_json() {
  local dest=$1 mode=$2 owner=$3 group=$4 dir tmp
  dir=$(dirname "$dest")
  if [[ ! -d $dir ]]; then
    return 1
  fi
  tmp=$(mktemp -p "$dir") || return 1
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ ! -s $tmp ]] || ! jq -e . >/dev/null <"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chown "${owner}:${group}" "$tmp" || ! chmod "$mode" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$dest"
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

fix_tree_perms() {
  local f
  if [[ -f $CONF ]]; then
    chown root:xray "$CONF"
    chmod 640 "$CONF"
  fi
  if [[ -d $CONF_DIR ]]; then
    chown root:xray "$CONF_DIR"
    chmod 750 "$CONF_DIR"
  fi
  if [[ -d $STATE_DIR ]]; then
    chown root:xray "$STATE_DIR"
    chmod 750 "$STATE_DIR"
  fi
  if [[ -d $LOG_DIR ]]; then
    chown root:xray "$LOG_DIR"
    chmod 750 "$LOG_DIR"
  fi
  if [[ -d $META_DIR ]]; then
    chown root:root "$META_DIR"
    chmod 700 "$META_DIR"
    for f in "$META_DIR"/*.json; do
      [[ -f $f ]] || continue
      chown root:root "$f"
      chmod 600 "$f"
    done
  fi
  if [[ -d $CERT_DIR ]]; then
    chown root:xray "$CERT_DIR"
    chmod 750 "$CERT_DIR"
    for f in "$CERT_DIR"/*; do
      [[ -e $f ]] || continue
      chown root:xray "$f"
      chmod 640 "$f"
    done
  fi
  repair_conf_access
}

# Alpine 默认 umask 077，mkdir 出来的父目录是 0700。
# 配置目录本身是 750 也没用，xray 过不了 /usr/local/etc 这一层。
open_parent_dirs() {
  local dir=$1 parent
  dir=$(dirname "$dir")
  while [[ $dir != / && $dir != . ]]; do
    parent=$(dirname "$dir")
    if [[ -d $dir && $(stat -c '%u' "$dir") -eq 0 && $(stat -c '%a' "$parent") =~ [1357]$ ]]; then
      chmod o+x "$dir" 2>/dev/null || true
    fi
    dir=$parent
  done
}

repair_conf_access() {
  [[ -d $CONF_DIR ]] || return 0
  open_parent_dirs "$CONF_DIR"
  open_parent_dirs "$LOG_DIR"
  open_parent_dirs "$STATE_DIR"
  if ! id -u xray >/dev/null 2>&1 || ! command -v su >/dev/null 2>&1; then
    return 0
  fi
  if su -s /bin/sh -c "test -x $(printf '%q' "$CONF_DIR") && test -r $(printf '%q' "$CONF_DIR")" xray; then
    return 0
  fi
  chown root:xray "$CONF_DIR"
  chmod 750 "$CONF_DIR"
}

gc_certs() {
  local f base
  for f in "$CERT_DIR"/*; do
    [[ -f $f ]] || continue
    base=$(basename "$f")
    base=${base%.*}
    if [[ ! -f $META_DIR/${base}.json ]]; then
      rm -f -- "$f"
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
      rm -rf -- "$f"
    fi
  done < <(find "$live" -mindepth 1 -depth -print0)
  cp -a "$snap"/. "$live"/
}

begin_tx() {
  local lockdir=/run/lock
  [[ -d $lockdir ]] || lockdir=/var/lock
  if [[ ! -d $lockdir ]]; then
    err "缺少锁目录，无法安全修改配置。"
    return 1
  fi
  exec 9>"$lockdir/xray-panel.lock" || return 1
  if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
    err "另一个面板正在修改配置。"
    return 1
  fi
  TX=$(mktemp -d) || return 1
  TMP_PATHS+=("$TX")
  mkdir -p "$TX/conf" "$TX/meta" "$TX/certs" || return 1
  if [[ -d $CONF_DIR ]]; then
    cp -a "$CONF_DIR"/. "$TX/conf"/ || return 1
  fi
  if [[ -d $META_DIR ]]; then
    cp -a "$META_DIR"/. "$TX/meta"/ || return 1
  fi
  if [[ -d $CERT_DIR ]]; then
    cp -a "$CERT_DIR"/. "$TX/certs"/ || return 1
  fi
}

rollback_tx() {
  restore_tree "$CONF_DIR" "$TX/conf" || true
  restore_tree "$META_DIR" "$TX/meta" || true
  if [[ -d $CERT_DIR ]] || [[ -n $(ls -A "$TX/certs" 2>/dev/null) ]]; then
    restore_tree "$CERT_DIR" "$TX/certs" || true
  fi
  fix_tree_perms
  gc_certs
}

box_as_user() {
  local bin=$1 log=$2 conf=$3 cmd
  cmd=$(printf '%q run -c %q -test' "$bin" "$conf")
  if id -u xray >/dev/null 2>&1 && command -v su >/dev/null 2>&1; then
    su -s /bin/sh -c "$cmd" xray >"$log" 2>&1
  else
    "$bin" run -c "$conf" -test >"$log" 2>&1
  fi
}

box_test() {
  local log
  log=$(mktemp)
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

is_running() {
  if [[ ! -x $BIN ]]; then
    return 1
  fi
  if [[ $OS == alpine ]]; then
    command -v rc-service >/dev/null 2>&1 || return 1
    local out
    out=$(rc-service xray status 2>/dev/null || true)
    [[ $out == *started* ]]
  else
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet xray
  fi
}

service_installed() {
  if [[ $OS == alpine ]]; then
    [[ -x /etc/init.d/xray ]]
  else
    [[ -f /etc/systemd/system/xray.service ]]
  fi
}

service_uses_panel_conf() {
  if [[ $OS == alpine ]]; then
    [[ -f /etc/init.d/xray ]] && grep -q -- 'run -c /usr/local/etc/xray/config.json' /etc/init.d/xray
  else
    [[ -f /etc/systemd/system/xray.service ]] && grep -q -- 'run -c /usr/local/etc/xray/config.json' /etc/systemd/system/xray.service
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
  if [[ $OS == alpine ]]; then
    if ! command -v rc-service >/dev/null 2>&1; then
      apk add --no-cache openrc
    fi
    cat >/etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

description="xray Service"

supervisor=supervise-daemon
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_user="xray:xray"
pidfile="/run/${RC_SVCNAME}.pid"
capabilities="^cap_net_bind_service"
output_log="/var/log/xray/stdout.log"
error_log="/var/log/xray/stderr.log"
respawn_delay=2
respawn_max=10
umask=0077

depend() {
	need net
	after firewall
}
EOF
    chmod 755 /etc/init.d/xray
    plainln "  设置开机启动"
    rc-update add xray default >/dev/null 2>&1 || rc-update add xray default >/dev/null 2>&1 || true
    drop_file_caps "$BIN"
  else
    if ! command -v systemctl >/dev/null 2>&1; then
      err "Debian 需要 systemd。"
      return 1
    fi
    cat >/etc/systemd/system/xray.service <<'EOF'
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
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=2s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/xray.service
    if [[ -d /etc/logrotate.d ]]; then
      cat >/etc/logrotate.d/xray <<'EOF'
/var/log/xray/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
    su xray xray
}
EOF
      chmod 644 /etc/logrotate.d/xray
    fi
    systemctl daemon-reload
    plainln "  设置开机启动"
    systemctl enable xray >/dev/null 2>&1
    drop_file_caps "$BIN"
  fi
}

svc() {
  if [[ $OS == alpine ]]; then
    rc-service xray "$1"
  else
    systemctl "$1" xray
  fi
}

kernel_stays_up() {
  local i
  svc "$1" || return 1
  for ((i = 0; i < 6; i++)); do
    sleep 0.5
    is_running || return 1
  done
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
  if ! box_test; then
    rollback_tx
    err "已回滚本次修改。"
    return 1
  fi
  fix_tree_perms
  if ! service_uses_panel_conf; then
    plainln "  正在把服务切换到面板配置。"
    if ! install_service; then
      rollback_tx
      err "无法更新服务文件，已回滚。"
      return 1
    fi
  fi
  if is_running; then
    if ! kernel_stays_up restart; then
      rollback_tx
      svc restart || true
      err "重启失败，已回滚。"
      show_service_log
      return 1
    fi
    plainln "  配置已生效，内核已重启。"
  else
    plainln "  配置已保存。内核当前未运行，可在主菜单选择 3 启动。"
  fi
}

current_version() {
  local raw
  if [[ ! -x $BIN ]]; then
    printf '-'
    return
  fi
  raw=$("$BIN" version 2>/dev/null | awk 'NR==1 {print $2}') || true
  raw=${raw#v}
  raw=${raw%%[^0-9.]*}
  if [[ -z $raw ]]; then
    printf '-'
  else
    printf 'v%s' "$raw"
  fi
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
  url=$(curl -fsSL -o /dev/null -w '%{url_effective}' --retry 3 --retry-delay 2 \
    "https://github.com/${REPO}/releases/latest") || return 1
  tag=${url##*/}
  if [[ ! $tag =~ ^v?[0-9] ]]; then
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
  local state=$1 ver=$2 count=$3
  local mark left mid right gap
  case $state in
    运行中) mark="${GRN}●${GRN}" ;;
    未运行) mark="${YEL}●${GRN}" ;;
    *) mark="${RED}●${GRN}" ;;
  esac
  left="● ${state}"
  mid=$ver
  right="入站 ${count}"
  gap=$((WIDTH - $(dw "$left") - $(dw "$mid") - $(dw "$right")))
  ((gap < 2)) && gap=2
  printf '%b%s%b%s%s%s' "$mark" " ${state}" "$GRN" "$(spaces $((gap / 2)))" "$mid" "$(spaces $((gap - gap / 2)))$right"
}

menu_row() {
  local n1=$1 l1=$2 n2=$3 l2=$4
  printf '  %s%s  %s%s\n' \
    "$(pad "$n1" 3)" "$(pad "$l1" 16)" \
    "$(pad "$n2" 3)" "$l2" >&4
}

draw_panel() {
  local state ver count
  state=$(kernel_state)
  ver=$(current_version)
  count=$(count_inbounds)
  cls
  blank
  uin "  ${BOLD}xray${OFFBOLD}"
  uin "  ${RULE}"
  uin "  $(status_text "$state" "$ver" "$count")"
  uin "  ${RULE}"
  blank
  note "内核"
  menu_row "1" "安装" "2" "升级"
  menu_row "3" "启动" "4" "停止"
  item "5" "卸载"
  blank
  note "入站"
  menu_row "6" "添加" "7" "修改"
  menu_row "8" "分享" "9" "删除"
  item "10" "日志"
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
  local version=$1 dest=$2 machine url name sum actual
  machine=$(asset_arch) || return 1
  name="Xray-linux-${machine}.zip"
  url="https://github.com/${REPO}/releases/download/${version}/${name}"
  plainln "  下载 ${url}"
  if ! curl -fL --retry 5 --retry-delay 2 -o "$dest/xray.zip" "$url"; then
    err "下载失败，请检查网络。"
    return 1
  fi
  if ! curl -fL --retry 5 --retry-delay 2 -o "$dest/xray.zip.dgst" "${url}.dgst"; then
    err "无法下载校验文件。"
    return 1
  fi
  plainln "  校验 SHA256"
  sum=$(dgst_sha256 "$dest/xray.zip.dgst") || {
    err "无法读取 SHA256。"
    return 1
  }
  actual=$(sha256sum "$dest/xray.zip" | awk '{print tolower($1)}')
  if [[ -z $sum || $sum != "$actual" ]]; then
    err "SHA256 校验失败。"
    return 1
  fi
  # BusyBox unzip 没有 -Z，用 -l。两种格式的文件名都在行尾。
  if unzip -l "$dest/xray.zip" | awk 'NR>3 && NF>=4 {print $NF}' | grep -qE '(^|/)\.\.(/|$)|^/'; then
    err "压缩包路径不安全。"
    return 1
  fi
  mkdir -p "$dest/pack"
  if ! unzip -q -o "$dest/xray.zip" -d "$dest/pack"; then
    err "解压失败。"
    return 1
  fi
  if [[ ! -f $dest/pack/xray ]]; then
    err "压缩包中没有 xray。"
    return 1
  fi
  chmod 755 "$dest/pack/xray"
  if ! "$dest/pack/xray" version >/dev/null 2>&1; then
    err "二进制无法执行，请确认架构是否匹配。"
    return 1
  fi
}

place_binary() {
  local src=$1 new
  new=/usr/local/bin/xray.new
  cp -- "$src" "$new" || return 1
  chown root:root "$new" || { rm -f -- "$new"; return 1; }
  chmod 755 "$new" || { rm -f -- "$new"; return 1; }
  drop_file_caps "$new"
  mv -f -- "$new" "$BIN"
}

deploy_pack() {
  local src=$1
  create_box_user || return 1
  ensure_dirs || return 1
  place_binary "$src/xray" || return 1
  ensure_base_config || return 1
  rebuild_config || return 1
  fix_tree_perms || return 1
  install_service
}

restore_binary() {
  local saved=$1
  if [[ -n $saved && -f $saved ]]; then
    place_binary "$saved" || return 1
  else
    rm -f -- "$BIN"
  fi
}

install_kernel() {
  local work version
  header "安装内核"
  if [[ -x $BIN ]]; then
    plainln "  内核已安装 ($(current_version))。如需更新请选择「升级内核」。"
    pause
    return 0
  fi
  if ! ensure_deps; then
    err "依赖安装失败。"
    pause
    return 0
  fi
  plainln "  获取最新版本..."
  version=$(latest_version) || {
    err "无法获取 xray 版本，请检查到 GitHub 的网络。"
    pause
    return 0
  }
  plainln "  最新版本 ${version}"
  work=$(mktemp -d)
  TMP_PATHS+=("$work")
  mkdir -p "$work/pack"
  if ! download_release "$version" "$work"; then
    pause
    return 0
  fi
  deploy_pack "$work/pack" || { pause; return 0; }
  if ! box_test; then
    warn "内核已安装，但基础配置未通过校验。"
    pause
    return 0
  fi
  blank
  plainln "  安装完成。"
  kv "版本" "$(current_version)"
  kv "程序" "$BIN"
  kv "配置" "$CONF"
  kv "日志" "$LOG_DIR"
  kv "用户" "xray"
  blank
  note "回到主菜单，选择 3 启动。"
  pause
}

upgrade_kernel() {
  local work version current cmp was=0 saved=""
  header "升级内核"
  if [[ ! -x $BIN ]]; then
    err "请先安装内核。"
    pause
    return 0
  fi
  if ! ensure_deps; then
    err "依赖安装失败。"
    pause
    return 0
  fi
  current=$(current_version)
  plainln "  当前版本 ${current}"
  plainln "  获取最新版本..."
  version=$(latest_version) || {
    err "无法获取 xray 版本，请检查到 GitHub 的网络。"
    pause
    return 0
  }
  plainln "  最新版本 ${version}"
  cmp=$(ver_cmp "$version" "$current")
  if [[ $cmp -le 0 ]]; then
    if [[ $cmp -eq 0 ]]; then
      plainln "  已是最新版本。"
    else
      warn "当前版本高于最新正式版。"
    fi
    confirm "是否仍要重新安装此版本？" || return 0
  fi
  work=$(mktemp -d)
  TMP_PATHS+=("$work")
  mkdir -p "$work/pack"
  if ! download_release "$version" "$work"; then
    pause
    return 0
  fi
  if [[ -f $CONF ]]; then
    plainln "  用新版本校验现有配置..."
    chmod 755 "$work" "$work/pack" "$work/pack/xray"
    if ! box_as_user "$work/pack/xray" "$work/test.err" "$CONF"; then
      err "新版本无法加载当前配置，已取消升级。"
      cat "$work/test.err" >&4 || true
      ui "$GRN"
      pause
      return 0
    fi
  fi
  is_running && was=1
  if [[ -x $BIN ]]; then
    saved=$work/xray.prev
    cp -a -- "$BIN" "$saved" || {
      err "无法备份当前内核，已取消升级。"
      pause
      return 0
    }
  fi
  if ! deploy_pack "$work/pack"; then
    restore_binary "$saved" || err "恢复旧内核失败。"
    pause
    return 0
  fi
  if [[ $was -eq 1 ]]; then
    if kernel_stays_up restart; then
      plainln "  已升级到 $(current_version)，内核已重启。"
    else
      err "新内核未能保持运行，正在恢复旧版本。"
      show_service_log
      if restore_binary "$saved" && install_service && kernel_stays_up restart; then
        plainln "  已恢复到 ${current}。"
      else
        err "恢复旧内核失败。"
        show_service_log
      fi
    fi
  else
    plainln "  已升级到 $(current_version)。内核当前未运行。"
  fi
  pause
}

start_kernel() {
  header "启动内核"
  if [[ ! -x $BIN ]]; then
    err "请先安装内核。"
    pause
    return 0
  fi
  if ! service_installed; then
    plainln "  服务文件不存在，正在修复..."
    create_box_user || { pause; return 0; }
    ensure_dirs
    ensure_base_config
    install_service || { pause; return 0; }
  fi
  if is_running; then
    plainln "  内核已在运行。"
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
  plainln "  内核已启动。"
  pause
}

stop_kernel() {
  header "停止内核"
  if ! is_running; then
    plainln "  内核未在运行。"
    pause
    return 0
  fi
  if ! svc stop; then
    err "停止失败。"
    pause
    return 0
  fi
  plainln "  内核已停止。"
  pause
}

uninstall_kernel() {
  header "卸载内核"
  if [[ ! -x $BIN && ! -f $CONF ]] && ! service_installed; then
    plainln "  内核未安装。"
    pause
    return 0
  fi
  plainln "  将停止服务并删除内核程序和服务文件。"
  local purge=0
  confirm "确认卸载？" || return 0
  if confirm "是否同时清除面板配置、证书、日志和 xray 用户？"; then
    purge=1
  fi
  if is_running || service_installed; then
    if [[ $OS == alpine ]]; then
      rc-service xray stop >/dev/null 2>&1 || true
      rc-update del xray default >/dev/null 2>&1 || true
    else
      systemctl disable --now xray >/dev/null 2>&1 || true
    fi
  fi
  rm -f -- "$BIN" /usr/local/bin/xray.new
  if [[ $OS == alpine ]]; then
    rm -f -- /etc/init.d/xray
  else
    rm -f -- /etc/systemd/system/xray.service /etc/logrotate.d/xray
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload || true
    fi
  fi
  if [[ $purge -eq 1 ]]; then
    local f kept=0
    if [[ -f $CONF ]]; then
      rm -f -- "$CONF"
    fi
    for f in "$CONF_DIR"/*; do
      [[ -e $f ]] || continue
      kept=1
    done
    rm -rf -- "$LOG_DIR" "$STATE_DIR"
    if [[ $kept -eq 0 ]]; then
      rmdir "$CONF_DIR" 2>/dev/null || true
      if id -u xray >/dev/null 2>&1; then
        if [[ $OS == alpine ]]; then
          deluser xray >/dev/null 2>&1 || true
          delgroup xray >/dev/null 2>&1 || true
        else
          userdel xray >/dev/null 2>&1 || true
          groupdel xray >/dev/null 2>&1 || true
        fi
      fi
      plainln "  内核、面板配置、日志和用户已清除。"
    else
      plainln "  内核和面板配置已清除。已保留原有配置文件，因此未删除 xray 用户。"
    fi
  else
    plainln "  内核已卸载。配置与日志仍保留在:"
    plainln "  ${CONF}"
    plainln "  ${LOG_DIR}"
  fi
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
  trap - INT
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
  if [[ $proto == hysteria2 ]]; then
    return 1
  fi
  if [[ $proto == shadowsocks && -n $net && $net != *tcp* ]]; then
    return 1
  fi
  return 0
}

uses_udp() {
  local proto=$1 net=$2
  if [[ $proto == hysteria2 ]]; then
    return 0
  fi
  if [[ $proto == shadowsocks && $net == *udp* ]]; then
    return 0
  fi
  return 1
}

listen_clash() {
  local a=$1 b=$2
  [[ $a == "$b" || $a == 0.0.0.0 || $b == 0.0.0.0 || $a == :: || $b == :: ]]
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
  local f etag ep eproto enet elisten base nt=0 nu=0 rc
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
    done < <(jq -rj '.inbounds[]? | ["x", "." + (if (.tag // "") == "" then "config.json" else .tag end), .protocol // "", (.settings.network // ""), (.port | tostring), (.listen // "0.0.0.0")] | join("\u001f") + "\n"' "$CONF" 2>/dev/null || true)
  fi
  return 1
}

is_domain() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$ ]]
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
    if [[ ! $ans =~ ^[0-9]+$ ]]; then
      err "端口须为 1-65535。"
      continue
    fi
    p=$((10#$ans))
    if ((p < 1 || p > 65535)); then
      err "端口须为 1-65535。"
      continue
    fi
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
    if [[ $ans == \[*\] ]]; then
      ans=${ans#\[}
      ans=${ans%\]}
    fi
    host=$ans
    tport=443
    if ! is_ipv6 "$ans" && [[ $ans =~ ^([A-Za-z0-9.-]+):([0-9]+)$ ]]; then
      host=${BASH_REMATCH[1]}
      tport=${BASH_REMATCH[2]}
      if ((10#$tport < 1 || 10#$tport > 65535)); then
        err "端口不合法。"
        continue
      fi
    fi
    if [[ $mode == domain ]]; then
      if [[ $host =~ [A-Za-z] ]] && is_domain "$host"; then
        printf '%s\n%s' "$host" "$tport"
        return 0
      fi
      err "请输入域名，例如 www.microsoft.com。不要使用 Cloudflare CDN 站点。"
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
  if [[ $ans =~ ^[0-9]+$ ]] && ((10#$ans >= 1 && 10#$ans <= max)); then
    printf '%s' "$((10#$ans))"
    return 0
  fi
  return 4
}

choose() {
  local title=$1 hint=$2
  shift 2
  local -a rows=("$@")
  local choice msg="" rc n=${#rows[@]}
  while true; do
    header "$title"
    for ((choice = 0; choice < n; choice++)); do
      item "$((choice + 1))" "${rows[choice]}"
    done
    blank
    if [[ -n $msg ]]; then
      err "$msg"
    fi
    msg=""
    next_choice choice msg "$n" "$hint"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      printf '%s' "$choice"
      return 0
    fi
    if [[ $rc -eq 1 ]]; then
      continue
    fi
    return "$rc"
  done
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
  choice=$(choose "传输" "取消" "tcp,udp" "tcp" "udp") || return $?
  case $choice in
    2) printf 'tcp' ;;
    3) printf 'udp' ;;
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
  if [[ -x $BIN ]]; then
    "$BIN" uuid | tr -d '[:space:]'
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
    err "请先安装内核，才能生成 REALITY 密钥。"
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

ask_uuid() {
  local current=$1 ans bytes
  while true; do
    if [[ -n $current ]]; then
      ans=$(prompt "UUID" "" "回车保留，g 重新生成，q 取消") || return 2
    else
      ans=$(prompt "UUID" "" "回车生成，q 取消") || return 2
    fi
    cancelled "$ans" && return 2
    if [[ -z $ans ]]; then
      if [[ -n $current ]]; then
        printf '%s' "$current"
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
    if is_uuid "$ans" || ((bytes > 0 && bytes < 30)); then
      printf '%s' "$ans"
      return 0
    fi
    err "UUID 不合法。可留空自动生成，或输入少于 30 字节的字符串。"
  done
}

ask_password() {
  local label=$1 current=$2 method=$3 ans
  while true; do
    if [[ -n $current ]]; then
      ans=$(prompt "$label" "" "回车保留，g 重新生成，q 取消") || return 2
    else
      ans=$(prompt "$label" "" "回车生成，q 取消") || return 2
    fi
    if [[ -z $ans ]]; then
      if [[ -n $current ]]; then
        if [[ -n $method ]] && ! ss_key_ok "$method" "$current"; then
          err "当前密码长度与加密方式不匹配，请输入 g 重新生成。"
          continue
        fi
        printf '%s' "$current"
      elif [[ -n $method ]]; then
        gen_ss_password "$method"
      else
        gen_auth
      fi
      return 0
    fi
    if is_regen "$ans"; then
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
      err "请直接回车，或输入 g。"
    done
  fi
  local pair priv pub sid
  pair=$(gen_reality_pair) || return 1
  priv=$(printf '%s\n' "$pair" | sed -n '1p')
  pub=$(printf '%s\n' "$pair" | sed -n '2p')
  sid=$(gen_shortid)
  printf '%s\n%s\n%s\n' "$priv" "$pub" "$sid"
}

make_self_signed() {
  local cn=$1 dir san crt key
  dir=$(mktemp -d)
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
  chmod 600 "$crt" "$key"
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
  install -d -m 750 -o root -g xray "$CERT_DIR"
  install -m 640 -o root -g xray "$src_crt" "$crt"
  install -m 640 -o root -g xray "$src_key" "$key"
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
  local tag=$1 f
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
            tlsSettings:({certificates:[{certificateFile:$m.certFile, keyFile:$m.keyFile}]} + ($m | hy_sni)),
            method:"hysteria",
            hysteriaSettings:{version:2, masquerade:{type:"string", content:"404 not found", statusCode:404}}}}
    else
      error("unknown protocol")
    end
  '
}

rebuild_config() {
  local f parts='[]' doc inbound
  for f in "$META_DIR"/*.json; do
    [[ -f $f ]] || continue
    inbound=$(render_inbound <"$f") || return 1
    parts=$(jq -n --argjson a "$parts" --argjson b "$inbound" '$a + [$b]') || return 1
  done
  if [[ -f $CONF ]]; then
    doc=$(jq --argjson ins "$parts" '.log = (.log // {loglevel:"warning"}) | .outbounds = (if (.outbounds | type) == "array" and (.outbounds | length) > 0 then .outbounds else [{protocol:"freedom", tag:"direct"}] end) | .inbounds = $ins' "$CONF") || return 1
  else
    doc=$(jq -n --argjson ins "$parts" '{log:{loglevel:"warning"}, inbounds:$ins, outbounds:[{protocol:"freedom", tag:"direct"}]}') || return 1
  fi
  printf '%s' "$doc" | atomic_json "$CONF" 640 root xray
}

save_meta_and_inbound() {
  local tag=$1 meta_json
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
    plainln "  暂无入站。回到主菜单，选择 6 添加。"
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

finish_inbound() {
  local tag=$1 proto=$2 port=$3 network
  printf '%s' "$4" | save_meta_and_inbound "$tag" || { rollback_tx; err "写入失败。"; pause; return 1; }
  commit_tx || { pause; return 1; }
  network=$(printf '%s' "$4" | jq -r '.network // ""')
  firewall_hint "$proto" "$port" "$network"
  pause
}

load_cert_fields() {
  cert_mode=$(printf '%s\n' "$1" | sed -n '1p')
  cert=$(printf '%s\n' "$1" | sed -n '2p')
  key=$(printf '%s\n' "$1" | sed -n '3p')
  insecure=$(printf '%s\n' "$1" | sed -n '4p')
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

install_chosen_cert() {
  local paths src_crt src_key
  src_crt=$cert
  src_key=$key
  paths=$(materialize_cert "$1" "$cert_mode" "$src_crt" "$src_key") || return 1
  cert=$(printf '%s\n' "$paths" | sed -n '1p')
  key=$(printf '%s\n' "$paths" | sed -n '2p')
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

ss_wizard() {
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
  confirm_write || return 0
  need_tx || return 0
  doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") \
    || { rollback_tx; err "写入失败。"; pause; return 0; }
  finish_inbound "$tag" shadowsocks "$port" "$doc" || return 0
}

vless_wizard() {
  local tag="" listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys doc
  flow=xtls-rprx-vision
  note "VLESS REALITY 使用 TCP，流控为 xtls-rprx-vision。"
  blank
  listen=$(ask_listen "0.0.0.0") || return 0
  port=$(ask_port 443 "" vless tcp "$listen") || return 0
  tag=$(new_tag vless "$port")
  remark=$(ask_remark "vless-${port}") || return 0
  note "伪装站点需要 TLS 1.3，不要用 Cloudflare CDN。"
  name_pack=$(ask_name "伪装域名" "www.microsoft.com:443" domain) || return 0
  host=$(printf '%s\n' "$name_pack" | sed -n '1p')
  tport=$(printf '%s\n' "$name_pack" | sed -n '2p')
  sni=$host
  target=$host
  keys=$(ask_reality_keys "" "" "") || { [[ $? -eq 1 ]] && pause; return 0; }
  priv=$(printf '%s\n' "$keys" | sed -n '1p')
  pub=$(printf '%s\n' "$keys" | sed -n '2p')
  sid=$(printf '%s\n' "$keys" | sed -n '3p')
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
  need_tx || return 0
  doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
    "$sni" "$target" "$tport" "$priv" "$pub" "$sid") \
    || { rollback_tx; err "写入失败。"; pause; return 0; }
  finish_inbound "$tag" vless "$port" "$doc" || return 0
}

hy_wizard() {
  local tag="" listen port remark auth sni cert key insecure
  local name_pack host cert_pack cert_mode="" cert_show="" doc
  note "Hysteria2 使用 QUIC，必须启用 TLS。"
  blank
  listen=$(ask_listen "0.0.0.0") || return 0
  port=$(ask_port 443 "" hysteria2 udp "$listen") || return 0
  tag=$(new_tag hy2 "$port")
  remark=$(ask_remark "hy2-${port}") || return 0
  name_pack=$(ask_name "证书域名或 IP" "" name) || return 0
  host=$(printf '%s\n' "$name_pack" | sed -n '1p')
  sni=$host
  cert_pack=$(ask_cert "$sni" "" "" 1) || { [[ $? -eq 1 ]] && pause; return 0; }
  load_cert_fields "$cert_pack"
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
  confirm_write || return 0
  need_tx || return 0
  stage_chosen_cert "$tag" || return 0
  doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") \
    || { rollback_tx; err "写入失败。"; pause; return 0; }
  finish_inbound "$tag" hysteria2 "$port" "$doc" || return 0
}

prepare_store() {
  if ! id -u xray >/dev/null 2>&1; then
    err "缺少 xray 用户。请先安装内核。"
    pause
    return 1
  fi
  ensure_dirs
}

add_inbound() {
  local choice
  require_kernel || return 0
  if ! ensure_deps; then
    err "依赖安装失败。"
    pause
    return 0
  fi
  prepare_store || return 0
  while true; do
    choice=$(choose "添加入站" "返回" "Shadowsocks" "VLESS REALITY" "Hysteria2") || return 0
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
    esac
  done
}

show_field() {
  printf '  %s%s%s\n' "$(pad "$1" 3)" "$(pad "$2" 9)" "$3" >&4
}

edit_loop() {
  local title=$1 remark=$2
  shift 2
  local -a rows=("$@")
  local choice msg="" rc n=${#rows[@]}
  while true; do
    header "$title"
    note "$remark"
    blank
    for ((choice = 0; choice < n; choice++)); do
      show_field "$((choice + 1))" "${rows[choice]%%=*}" "${rows[choice]#*=}"
    done
    blank
    if [[ -n $msg ]]; then
      err "$msg"
    fi
    msg=""
    next_choice choice msg "$n" "返回"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      printf '%s' "$choice"
      return 0
    fi
    if [[ $rc -eq 1 ]]; then
      continue
    fi
    return 1
  done
}

ss_key_ok() {
  local method=$1 password=$2 need got
  case $method in
    2022-blake3-aes-128-gcm) need=16 ;;
    2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305) need=32 ;;
    *) return 0 ;;
  esac
  got=$(printf '%s' "$password" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ') || return 1
  [[ ${got:-0} -eq $need ]]
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
  while true; do
    tag=$(jq -r '.tag' "$meta")
    listen=$(jq -r '.listen' "$meta")
    port=$(jq -r '.port' "$meta")
    remark=$(jq -r '.remark' "$meta")
    method=$(jq -r '.method' "$meta")
    password=$(jq -r '.password' "$meta")
    network=$(jq -r '.network' "$meta")
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
          err "当前密码长度与新的加密方式不匹配，请改为修改密码。"
          pause
          continue
        fi
        ;;
      6) password=$(ask_password "密码" "$password" "$method") || continue ;;
      *) continue ;;
    esac
    confirm_write || continue
    doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") \
      || { err "写入失败。"; pause; continue; }
    need_tx || continue
    finish_inbound "$tag" shadowsocks "$port" "$doc" || continue
  done
}

edit_vless() {
  local meta=$1 choice doc
  local tag listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys dest
  while true; do
    tag=$(jq -r '.tag' "$meta")
    listen=$(jq -r '.listen' "$meta")
    port=$(jq -r '.port' "$meta")
    remark=$(jq -r '.remark' "$meta")
    uuid=$(jq -r '.uuid' "$meta")
    flow=$(jq -r '.flow // "xtls-rprx-vision"' "$meta")
    [[ -z $flow || $flow == null ]] && flow=xtls-rprx-vision
    sni=$(jq -r '.sni' "$meta")
    target=$(jq -r '.target' "$meta")
    tport=$(jq -r '.targetPort // 443' "$meta")
    priv=$(jq -r '.privateKey' "$meta")
    pub=$(jq -r '.publicKey' "$meta")
    sid=$(jq -r '.shortId' "$meta")
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
        plainln "  伪装站点需要支持 TLS 1.3，并避免 Cloudflare CDN。"
        name_pack=$(ask_name "伪装域名" "$dest" domain) || continue
        host=$(printf '%s\n' "$name_pack" | sed -n '1p')
        tport=$(printf '%s\n' "$name_pack" | sed -n '2p')
        sni=$host
        target=$host
        ;;
      5)
        keys=$(ask_reality_keys "$priv" "$pub" "$sid") || {
          [[ $? -eq 1 ]] && pause
          continue
        }
        priv=$(printf '%s\n' "$keys" | sed -n '1p')
        pub=$(printf '%s\n' "$keys" | sed -n '2p')
        sid=$(printf '%s\n' "$keys" | sed -n '3p')
        ;;
      6) uuid=$(ask_uuid "$uuid") || continue ;;
      *) continue ;;
    esac
    confirm_write || continue
    doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
      "$sni" "$target" "$tport" "$priv" "$pub" "$sid") \
      || { err "写入失败。"; pause; continue; }
    need_tx || continue
    finish_inbound "$tag" vless "$port" "$doc" || continue
  done
}

edit_hy() {
  local meta=$1 choice doc
  local tag listen port remark auth sni cert key insecure name_pack
  while true; do
    tag=$(jq -r '.tag' "$meta")
    listen=$(jq -r '.listen' "$meta")
    port=$(jq -r '.port' "$meta")
    remark=$(jq -r '.remark' "$meta")
    auth=$(jq -r '.auth' "$meta")
    sni=$(jq -r '.sni' "$meta")
    cert=$(jq -r '.certFile' "$meta")
    key=$(jq -r '.keyFile' "$meta")
    insecure=$(jq -r 'if .insecure then 1 else 0 end' "$meta")
    choice=$(edit_loop "修改 Hysteria2" "$remark" \
      "监听=$listen" "端口=$port" "备注=$remark" \
      "域名=$sni" "证书=$cert" "认证=$auth") || return 0
    case $choice in
      1) listen=$(ask_listen "$listen") || continue ;;
      2) port=$(ask_port "$port" "$tag" hysteria2 udp "$listen") || continue ;;
      3) remark=$(ask_remark "$remark") || continue ;;
      4)
        name_pack=$(ask_name "证书域名或 IP" "$sni" name) || continue
        sni=$(printf '%s\n' "$name_pack" | sed -n '1p')
        ;;
      5)
        apply_field_cert "$sni" "$cert" "$key" "$insecure" || continue
        need_tx || continue
        stage_chosen_cert "$tag" || continue
        doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") \
          || { rollback_tx; err "写入失败。"; pause; continue; }
        finish_inbound "$tag" hysteria2 "$port" "$doc" || continue
        continue
        ;;
      6) auth=$(ask_password "认证密码" "$auth" "") || continue ;;
      *) continue ;;
    esac
    confirm_write || continue
    doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") \
      || { err "写入失败。"; pause; continue; }
    need_tx || continue
    finish_inbound "$tag" hysteria2 "$port" "$doc" || continue
  done
}

edit_inbound() {
  local picked
  require_kernel || return 0
  if ! ensure_deps; then
    err "依赖安装失败。"
    pause
    return 0
  fi
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
  prepare_store || return 0
  need_tx || return 0
  rm -f -- "$META_DIR/${tag}.json"
  gc_certs
  if ! rebuild_config; then
    rollback_tx
    err "写入失败。"
    pause
    return 0
  fi
  if [[ -x $BIN ]]; then
    commit_tx || { pause; return 0; }
  else
    fix_tree_perms
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

detect_ip() {
  local ip
  ip=$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
  if ! is_ipv4 "$ip"; then
    ip=$(curl -4 -fsS --max-time 4 https://ifconfig.me/ip 2>/dev/null || true)
  fi
  if is_ipv4 "$ip"; then
    printf '%s' "$ip"
    return 0
  fi
  ip=$(curl -6 -fsS --max-time 4 https://api64.ipify.org 2>/dev/null || true)
  if is_ipv6 "$ip"; then
    printf '%s' "$ip"
  fi
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
  local picked host default link
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
  default=$(saved_host)
  if [[ -z $default ]]; then
    plainln "  正在检测公网地址..."
    default=$(detect_ip || true)
  fi
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
  if [[ ! -d $STATE_DIR ]]; then
    install -d -m 750 -o root -g xray "$STATE_DIR" || {
      err "无法保存服务器地址。"
      pause
      return 0
    }
  else
    chown root:xray "$STATE_DIR"
    chmod 750 "$STATE_DIR"
  fi
  printf '%s\n' "$host" >"$STATE_DIR/server_addr" || {
    err "无法保存服务器地址。"
    pause
    return 0
  }
  chmod 600 "$STATE_DIR/server_addr"
  link=$(build_share "$picked" "$host") || { err "无法生成链接。"; pause; return 0; }
  header "分享入站"
  share_details "$picked"
  kv "地址" "$host"
  blank
  note "分享链接"
  printf '  %s\n' "$link" >&4
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
xray 管理面板

用法: sudo ./xray.sh

文档: https://xtls.github.io/
系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
入站: Shadowsocks、VLESS REALITY、Hysteria2
内核以 xray 用户运行。
EOF
}

main() {
  local i
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
  RULE=""
  for ((i = 0; i < WIDTH; i++)); do
    RULE+="─"
  done
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
  main "$@"
fi
XRAY_PANEL_PAYLOAD
