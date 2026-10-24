#!/bin/sh
# sing-box 管理面板
# 文档: https://sing-box.sagernet.org/
# 系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
# 入站: Shadowsocks、VLESS REALITY、Hysteria2
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
exec bash /dev/fd/3 "$@" 3<<'SINGBOX_PANEL_PAYLOAD'
set -uo pipefail
set +H
set +o history
umask 077
shopt -s nullglob

BIN=/usr/local/bin/sing-box
CONF=/usr/local/etc/sing-box/config.json
CONF_DIR=/usr/local/etc/sing-box
LOG_DIR=/var/log/sing-box
STATE_DIR=/var/lib/sing-box
RUN_DIR=/var/lib/sing-box/runtime
SERVICE_FILE=/etc/systemd/system/sing-box.service
LOGROTATE_FILE=/etc/logrotate.d/sing-box
META_DIR=/var/lib/sing-box/meta
CERT_DIR=/var/lib/sing-box/certs
STDOUT_LOG=/var/log/sing-box/stdout.log
STDERR_LOG=/var/log/sing-box/stderr.log
REPO=SagerNet/sing-box
LOCK_DIR=/run/lock

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
item() { printf '  %b%s%b%s\n' "$ACC" "$(pad "$1" "$MENU_NUM_W")" "$RST" "$2" >&4; }
blank() { uin ""; }

cleanup() {
  local p
  if [[ -n $FOLLOW_PID ]]; then
    kill "$FOLLOW_PID" 2>/dev/null || true
  fi
  if [[ -n $TX && ! -f $TX/ready ]]; then
    end_tx
  fi
  if [[ -n $TX ]]; then
    warn "操作中断，正在恢复修改前的状态。"
    ((TX_WAS_RUNNING)) && svc stop || true
    if rollback_tx && ((TX_WAS_RUNNING)); then
      svc restart || true
    fi
  fi
  if ((${#TMP_PATHS[@]})); then
    for p in "${TMP_PATHS[@]}"; do
      if [[ -n $p && -e $p ]]; then
        rm -rf -- "$p"
      fi
    done
  fi
  printf '%b' "$RST" >&4 2>/dev/null || printf '%b' "$RST" || true
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
  if ((${#pkgs[@]} == 0)); then
    return 0
  fi
  plainln "  安装依赖: ${pkgs[*]}"
  if [[ $OS == alpine ]]; then
    apk add --no-cache "${pkgs[@]}" ca-certificates
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || return 1
    # Debian 将 flock 与 su 一并放在 util-linux 中。
    local i
    for i in "${!pkgs[@]}"; do
      [[ ${pkgs[i]} == flock ]] && pkgs[i]=util-linux
    done
    apt-get install -y --no-install-recommends "${pkgs[@]}" ca-certificates
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
    warn "已存在 sing-box 用户，继续使用该账户运行内核。"
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
  make_dir 750 root sing-box "$CONF_DIR" || return 1
  make_dir 750 root sing-box "$LOG_DIR" || return 1
  make_dir 750 root sing-box "$STATE_DIR" || return 1
  make_dir 700 root root "$META_DIR" || return 1
  make_dir 750 root sing-box "$CERT_DIR" || return 1
  make_dir 750 sing-box sing-box "$RUN_DIR" || return 1
  for f in "$STDOUT_LOG" "$STDERR_LOG"; do
    [[ ! -L $f ]] || return 1
    if [[ ! -e $f ]]; then
      install -m 600 -o sing-box -g sing-box /dev/null "$f" || return 1
    fi
  done
  fix_tree_perms
}

atomic_json() {
  local dest=$1 mode=$2 owner=$3 group=$4 dir tmp
  dir=$(dirname "$dest")
  if [[ ! -d $dir || -L $dest ]]; then
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
  if ! mv -f -- "$tmp" "$dest"; then
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
  return 0
}

gc_certs() {
  # 只清理由本事务删除的入站证书，不碰手工配置引用的文件。
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
    if [[ ! -e $snap/$rel && ! -L $snap/$rel ]]; then
      rm -rf -- "$f"
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
  if [[ $TX_MODE == deploy && -e $BIN ]]; then
    cp -a -- "$BIN" "$TX/binary" || return 1
  fi
  touch "$TX/ready"
}

end_tx() {
  local saved=$TX
  TX=""
  TX_MODE=""
  exec 9>&-
  [[ -z $saved ]] || rm -rf -- "$saved"
  STORE_REV=$(store_revision)
}

begin_tx() {
  local lockdir=$LOCK_DIR
  [[ -z $TX ]] || { err "已有未结束的事务。"; return 1; }
  command -v flock >/dev/null 2>&1 || { err "缺少 flock，无法安全修改。"; return 1; }
  [[ -d $lockdir ]] || lockdir=/var/lock
  [[ -d $lockdir ]] || { err "缺少锁目录。"; return 1; }
  [[ ! -L $lockdir/sing-box-panel.lock ]] || { err "锁文件不能是符号链接。"; return 1; }
  exec 9>"$lockdir/sing-box-panel.lock" || return 1
  if ! flock -n 9; then
    exec 9>&-
    err "另一个面板正在修改，请稍后重试。"
    return 1
  fi
  TX=$(mktemp -d) || { exec 9>&-; return 1; }
  TX_MODE=${1:-config}
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
  local key path failed=0 saved=$TX
  [[ -n $TX && -f $TX/ready ]] || return 1
  # 在恢复/删除服务文件前清掉本事务创建的启用链接。
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
      place_binary "$TX/binary" || failed=1
    else
      rm -f -- "$BIN" || failed=1
    fi
  fi
  if [[ $OS == debian ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || failed=1
    if [[ -f $TX/enabled ]]; then
      systemctl enable sing-box >/dev/null 2>&1 || failed=1
    elif [[ -f $SERVICE_FILE ]]; then
      systemctl disable sing-box >/dev/null 2>&1 || failed=1
    fi
  elif [[ $OS == alpine ]] && command -v rc-update >/dev/null 2>&1; then
    if [[ -f $TX/enabled ]]; then
      rc-update add sing-box default >/dev/null 2>&1 || failed=1
    elif service_enabled; then
      rc-update del sing-box default >/dev/null 2>&1 || failed=1
    fi
  fi
  if ((failed)); then
    # 恢复失败保留快照供人工救援，绝不把失败伪装成“已回滚”。
    TX=""
    TX_MODE=""
    exec 9>&-
    err "恢复不完整，请保留并检查快照: ${saved}"
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
  # 参数由目标 /bin/sh 展开，而非当前 Bash；账户已校验 sing-box 为主组。
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

is_running() {
  [[ -x $BIN ]] || return 1
  if [[ $OS == alpine ]]; then
    command -v rc-service >/dev/null 2>&1 || return 1
    rc-service sing-box status >/dev/null 2>&1
  else
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet sing-box
  fi
}

service_uses_panel_conf() {
  [[ -f $SERVICE_FILE ]] && grep -qF 'sing-box-panel-v2' "$SERVICE_FILE"
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
      apk add --no-cache openrc || return 1
    fi
    cat >"$SERVICE_FILE" <<'EOF' || return 1
#!/sbin/openrc-run
# sing-box-panel-v2

description="sing-box Service"

supervisor=supervise-daemon
command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json -D /var/lib/sing-box/runtime"
command_user="sing-box:sing-box"
pidfile="/run/${RC_SVCNAME}.pid"
capabilities="^cap_net_bind_service"
output_log="/var/log/sing-box/stdout.log"
error_log="/var/log/sing-box/stderr.log"
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
    drop_file_caps "$BIN"
  else
    if ! command -v systemctl >/dev/null 2>&1; then
      err "Debian 需要 systemd。"
      return 1
    fi
    cat >"$SERVICE_FILE" <<'EOF' || return 1
# sing-box-panel-v2
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
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json -D /var/lib/sing-box/runtime
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=2s
LimitNPROC=10000
LimitNOFILE=1000000
# 面板的元数据和证书不属于内核的可写状态目录。
WorkingDirectory=/var/lib/sing-box/runtime
ProtectSystem=strict
ReadWritePaths=/var/lib/sing-box/runtime /var/log/sing-box
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE" || return 1
    if [[ -d /etc/logrotate.d ]]; then
      cat >"$LOGROTATE_FILE" <<'EOF' || return 1
/var/log/sing-box/*.log {
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
      chmod 644 "$LOGROTATE_FILE" || return 1
    fi
    systemctl daemon-reload || return 1
    plainln "  设置开机启动"
    systemctl enable sing-box >/dev/null 2>&1 || return 1
    drop_file_caps "$BIN"
  fi
}

svc() {
  if [[ $OS == alpine ]]; then
    rc-service sing-box "$1" 9>&-
  else
    systemctl "$1" sing-box 9>&-
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
    journalctl -u sing-box -n 40 --no-pager >&4 || true
  fi
  if [[ -f $STDERR_LOG && -s $STDERR_LOG ]]; then
    plainln "  --- stderr ---"
    tail -n 40 "$STDERR_LOG" >&4 || true
  fi
  ui "$GRN"
}

abort_tx() {
  local message=$1 was=$TX_WAS_RUNNING
  err "$message"
  if ((was)) && is_running; then
    svc stop || { err "无法停止服务，保留事务等待退出时恢复。"; return 1; }
  fi
  if rollback_tx; then
    if ((was)); then
      if kernel_stays_up restart; then
        plainln "  已恢复修改前的配置与服务。"
      else
        err "文件已恢复，但服务未能恢复运行。"
        show_service_log
      fi
    else
      plainln "  已恢复修改前的文件。"
    fi
  fi
  return 1
}

commit_tx() {
  if ! fix_tree_perms || ! box_test; then
    abort_tx "配置校验失败。"
    return 1
  fi
  if ! service_uses_panel_conf; then
    plainln "  正在更新服务配置。"
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
    plainln "  配置已保存 · 服务未启动（主菜单 3）。"
  fi
  gc_certs || warn "部分闲置证书未能清理。"
  end_tx
}

current_version() {
  local raw
  if [[ ! -x $BIN ]]; then
    printf '-'
    return
  fi
  raw=$("$BIN" version 2>/dev/null | awk 'NR==1 {print $NF}') || true
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
  body=$(curl -fsSL --retry 3 --retry-delay 2 \
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
  local version=$1 dest=$2 machine url name sum actual inner libc=""
  machine=$(asset_arch) || return 1
  # Alpine 显式选择 musl 构建，避免依赖 glibc 动态链接器。
  if [[ $OS == alpine ]]; then
    libc="-musl"
  fi
  name="sing-box-${version#v}-linux-${machine}${libc}.tar.gz"
  url="https://github.com/${REPO}/releases/download/${version}/${name}"
  plainln "  下载 ${url}"
  if ! curl -fL --retry 5 --retry-delay 2 -o "$dest/sing-box.tar.gz" "$url"; then
    err "下载失败，请检查网络。"
    return 1
  fi
  plainln "  校验 SHA256"
  sum=$(github_asset_sha "$version" "$name") || {
    err "无法获取 SHA256。"
    return 1
  }
  actual=$(sha256sum "$dest/sing-box.tar.gz" | awk '{print tolower($1)}')
  if [[ -z $sum || ${#sum} -ne 64 || $sum != "$actual" ]]; then
    err "SHA256 校验失败。"
    return 1
  fi
  if ! tar -tzf "$dest/sing-box.tar.gz" >"$dest/entries" \
    || grep -qE '(^|/)\.\.(/|$)|^/' "$dest/entries"; then
    err "压缩包路径不安全。"
    return 1
  fi
  if ! tar -xzf "$dest/sing-box.tar.gz" -C "$dest"; then
    err "解压失败。"
    return 1
  fi
  inner=$dest/sing-box-${version#v}-linux-${machine}${libc}
  if [[ ! -d $inner ]]; then
    inner=$(find "$dest" -mindepth 1 -maxdepth 1 -type d -name 'sing-box-*' | head -n 1)
  fi
  if [[ -z $inner || ! -f $inner/sing-box || -L $inner || -L $inner/sing-box ]]; then
    err "压缩包中没有 sing-box。"
    return 1
  fi
  mkdir -p "$dest/pack" || return 1
  cp -- "$inner/sing-box" "$dest/pack/sing-box" || return 1
  chmod 755 "$dest/pack/sing-box" || return 1
  if ! "$dest/pack/sing-box" version >/dev/null 2>&1; then
    err "二进制无法执行，请确认架构是否匹配。"
    return 1
  fi
}

place_binary() {
  local src=$1 new
  [[ ! -L $BIN ]] || return 1
  new=$(mktemp -p "$(dirname "$BIN")" .sing-box.XXXXXX) || return 1
  cp -- "$src" "$new" || { rm -f -- "$new"; return 1; }
  chown root:root "$new" || { rm -f -- "$new"; return 1; }
  chmod 755 "$new" || { rm -f -- "$new"; return 1; }
  drop_file_caps "$new"
  if ! mv -f -- "$new" "$BIN"; then
    rm -f -- "$new"
    return 1
  fi
}

deploy_pack() {
  local src=$1
  create_box_user || return 1
  ensure_dirs || return 1
  place_binary "$src/sing-box" || return 1
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
    err "无法获取 sing-box 版本，请检查到 GitHub 的网络。"
    pause
    return 1
  }
  plainln "  最新版本 ${version}"
  printf '%s' "$version"
}

stage_release() {
  local work
  work=$(mktemp -d) || { err "无法创建下载目录。"; pause; return 1; }
  TMP_PATHS+=("$work")
  if ! download_release "$1" "$work"; then
    rm -rf -- "$work"
    pause
    return 1
  fi
  printf '%s' "$work"
}

install_kernel() {
  local work version
  header "安装内核"
  if [[ -x $BIN ]]; then
    plainln "  内核已安装 ($(current_version))。如需更新请选择「升级内核」。"
    pause
    return 0
  fi
  deps_ok || return 0
  version=$(resolve_latest) || return 0
  work=$(stage_release "$version") || return 0
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
  note "回到主菜单，选择 3 启动。"
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
  work=$(stage_release "$version") || return 0
  if [[ -f $CONF ]]; then
    plainln "  用新版本校验现有配置..."
    # 只让服务账户穿越目录，不公开列出下载及诊断文件。
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
    is_running || note "服务未启动，可在主菜单选择 3。"
  fi
  rm -rf -- "$work"
  pause
}

start_kernel() {
  header "启动内核"
  if [[ ! -x $BIN ]]; then
    err "请先安装内核。"
    pause
    return 0
  fi
  deps_ok || return 0
  if ! service_uses_panel_conf; then
    plainln "  正在修复服务与运行目录..."
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
  local purge=0 kept=0
  header "卸载内核"
  if [[ ! -x $BIN && ! -f $CONF && ! -f $SERVICE_FILE ]]; then
    note "内核未安装。"; pause; return 0
  fi
  note "停止服务并删除内核；默认保留所有配置。"
  confirm "确认卸载？" || return 0
  confirm "同时清除面板入站和日志？（手工入站仍保留）" && purge=1
  if ! ensure_deps || ! begin_tx deploy; then
    pause; return 0
  fi
  if ((TX_WAS_RUNNING)) && ! svc stop; then
    abort_tx "无法停止服务，已取消卸载。"; pause; return 0
  fi
  if ! disable_service; then
    abort_tx "无法取消开机启动。"; pause; return 0
  fi
  if ((purge)); then
    if ! rm -f -- "$META_DIR"/*.json || ! rebuild_config; then
      abort_tx "无法清理面板入站。"; pause; return 0
    fi
    gc_certs || warn "部分闲置证书未能删除。"
    if jq -e '.inbounds | length > 0' "$CONF" >/dev/null; then
      kept=1
    else
      rm -f -- "$CONF" || { abort_tx "无法删除配置。"; pause; return 0; }
    fi
  fi
  if ! rm -f -- "$BIN" "$SERVICE_FILE" "$LOGROTATE_FILE"; then
    abort_tx "无法删除内核或服务文件。"; pause; return 0
  fi
  if [[ $OS == debian ]]; then
    systemctl daemon-reload || { abort_tx "无法重载服务管理器。"; pause; return 0; }
  fi
  end_tx
  if ((purge)); then
    [[ -z $(find "$CONF_DIR" -mindepth 1 -print -quit 2>/dev/null) ]] || kept=1
    if ((kept)); then
      note "手工配置、证书与 sing-box 用户已保留。"
    else
      rm -rf -- "$STATE_DIR" || warn "状态目录未能完全删除。"
      rmdir "$CONF_DIR" 2>/dev/null || true
      # 不自动删除可能由系统管理员创建或被其他服务使用的账户。
      note "保留 sing-box 系统账户，便于安全重装。"
    fi
    rm -rf -- "$LOG_DIR" || warn "日志未能完全删除。"
  else
    note "已保留配置: ${CONF}"
  fi
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
  if [[ $proto == shadowsocks && ( -z $net || $net == *udp* ) ]]; then
    return 0
  fi
  return 1
}

listen_clash() {
  local a=$1 b=$2
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
      err "请输入域名，例如 www.microsoft.com。不要使用 Cloudflare CDN 站点。"
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
    err "请先安装内核，才能生成 REALITY 密钥。"
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

ask_uuid() {
  local current=$1 ans
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
        gen_uuid || return 1
      fi
      return 0
    fi
    if is_regen "$ans"; then
      gen_uuid || return 1
      return 0
    fi
    if is_uuid "$ans"; then
      printf '%s' "$ans"
      return 0
    fi
    err "请输入标准 UUID，或留空自动生成。"
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
        gen_ss_password "$method" || return 1
      else
        gen_auth || return 1
      fi
      return 0
    fi
    if is_regen "$ans"; then
      if [[ -n $method ]]; then
        gen_ss_password "$method" || return 1
      else
        gen_auth || return 1
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
  if [[ -L $crt || -L $key ]] || ! mv -f -- "$staged/cert" "$crt" || ! mv -f -- "$staged/key" "$key"; then
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
    else
      error("unknown protocol")
    end
  '
}

valid_tag() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$ ]]
}

validate_meta() {
  local file=$1 tag
  [[ -f $file && ! -L $file ]] || return 1
  tag=${file##*/}
  tag=${tag%.json}
  valid_tag "$tag" || return 1
  jq -e --arg tag "$tag" '
    type == "object" and .tag == $tag
    and (.protocol == "shadowsocks" or .protocol == "vless" or .protocol == "hysteria2")
    and (.port | type == "number" and . == floor and . >= 1 and . <= 65535)
    and (.listen | type == "string")
    and (.remark | type == "string" and (test("[\u0000-\u001f\u007f]") | not))
  ' "$file" >/dev/null
}

rebuild_config() {
  local staged
  staged=$(mktemp -d) || return 1
  # 通过临时文件传递密钥，避免出现在 jq 的进程参数里。
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
  local staged=$1 f
  : >"$staged/inbounds"
  : >"$staged/owned"
  for f in "$META_DIR"/*.json; do
    validate_meta "$f" || { err "元数据不合法: ${f}"; return 1; }
    render_inbound <"$f" >>"$staged/inbounds" || return 1
    jq '.tag' "$f" >>"$staged/owned" || return 1
  done
  # 删除操作也要从现有配置中移除事务开始时属于面板的 tag。
  if [[ -n $TX ]]; then
    for f in "$TX/meta"/*.json; do
      validate_meta "$f" || return 1
      jq '.tag' "$f" >>"$staged/owned" || return 1
    done
  fi
  if [[ -f $CONF ]]; then
    jq -e 'type == "object" and ((.inbounds // []) | type == "array")' "$CONF" >/dev/null || return 1
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
  STORE_REV=$(store_revision)
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

ss_wizard() {
  STORE_REV=$(store_revision)
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
  STORE_REV=$(store_revision)
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
  confirm_write || return 0
  need_tx || return 0
  doc=$(meta_vless "$tag" "$remark" "$listen" "$port" "$uuid" "$flow" \
    "$sni" "$target" "$tport" "$priv" "$pub" "$sid") \
    || { rollback_tx; err "写入失败。"; pause; return 0; }
  finish_inbound "$tag" vless "$port" "$doc" || return 0
}

hy_wizard() {
  STORE_REV=$(store_revision)
  local tag="" listen port remark auth sni cert key insecure
  local name_pack host cert_pack cert_mode="" cert_show="" doc
  note "Hysteria2 使用 QUIC，必须启用 TLS。"
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
  if ! id -u sing-box >/dev/null 2>&1; then
    err "缺少 sing-box 用户。请先安装内核。"
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

ss_key_ok() {
  local method=$1 password=$2 need got canonical
  need=$(ss_key_bytes "$method") || return 0
  [[ $password =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
  got=$(printf '%s' "$password" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ') || return 1
  [[ ${got:-0} -eq $need ]] || return 1
  canonical=$(printf '%s' "$password" | openssl base64 -d -A | openssl base64 -A) || return 1
  [[ $canonical == "$password" ]]
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
    STORE_REV=$(store_revision)
    validate_meta "$meta" || return 1
    tag=$(jq -r '.tag' "$meta")
    listen=$(jq -r '.listen' "$meta")
    port=$(jq -r '.port' "$meta")
    remark=$(jq -r '.remark' "$meta")
    method=$(jq -r '.method' "$meta")
    password=$(jq -r '.password' "$meta")
    network=$(jq -r '.network' "$meta")
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
        if ! ss_key_ok "$method" "$password"; then
          note "新加密方式需要不同长度的密钥，请设置密码。"
          password=$(ask_password "密码" "" "$method") || continue
        fi
        ;;
      6) password=$(ask_password "密码" "$password" "$method") || continue ;;
      *) continue ;;
    esac
    doc=$(meta_ss "$tag" "$remark" "$listen" "$port" "$method" "$password" "$network") \
      || { err "写入失败。"; pause; continue; }
    apply_edited "$tag" shadowsocks "$port" "$network" "$listen" "$doc" || continue
  done
}

edit_vless() {
  local meta=$1 choice doc
  local tag listen port remark uuid flow sni target tport priv pub sid
  local name_pack host keys dest
  while true; do
    STORE_REV=$(store_revision)
    validate_meta "$meta" || return 1
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
      "$sni" "$target" "$tport" "$priv" "$pub" "$sid") \
      || { err "写入失败。"; pause; continue; }
    apply_edited "$tag" vless "$port" tcp "$listen" "$doc" || continue
  done
}

edit_hy() {
  local meta=$1 choice doc
  local tag listen port remark auth sni cert key insecure name_pack
  local cert_mode="" cert_show=""
  while true; do
    STORE_REV=$(store_revision)
    validate_meta "$meta" || return 1
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
      "域名=$sni" "证书=$cert" "认证=已设置 · 选择修改") || return 0
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
        doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") \
          || { rollback_tx; err "写入失败。"; pause; continue; }
        finish_inbound "$tag" hysteria2 "$port" "$doc" || continue
        continue
        ;;
      6) auth=$(ask_password "认证密码" "$auth" "") || continue ;;
      *) continue ;;
    esac
    doc=$(meta_hy "$tag" "$remark" "$listen" "$port" "$auth" "$sni" "$cert" "$key" "$insecure") \
      || { err "写入失败。"; pause; continue; }
    apply_edited "$tag" hysteria2 "$port" udp "$listen" "$doc" || continue
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
  need_tx || return 0
  rm -f -- "$META_DIR/${tag}.json" || { rollback_tx; return 0; }
  if ! rebuild_config; then
    rollback_tx
    err "写入失败。"
    pause
    return 0
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
      local userinfo
      if [[ $method == 2022-* ]]; then
        userinfo="$(urlenc "$method"):$(urlenc "$password")"
      else
        userinfo=$(b64url "${method}:${password}")
      fi
      printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "$enc"
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
sing-box 管理面板

用法: sudo sh sing-box.sh

文档: https://sing-box.sagernet.org/
系统: Debian / Ubuntu（systemd）、Alpine（OpenRC）
入站: Shadowsocks、VLESS REALITY、Hysteria2
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
