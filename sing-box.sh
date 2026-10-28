#!/usr/bin/env bash
# sing-box.sh — SSH 终端管理面板
# https://sing-box.sagernet.org
# Debian/Ubuntu (systemd)、Alpine (OpenRC)
# 入站: Shadowsocks、VLESS、Hysteria2。sing-box 始终以 sing-box:sing-box 运行。
set -euo pipefail

SINGBOX_PREFIX="${SINGBOX_PREFIX:-}"
BIN="${SINGBOX_PREFIX}/usr/local/bin/sing-box"
CFG_DIR="${SINGBOX_PREFIX}/usr/local/etc/sing-box"
CFG="${CFG_DIR}/config.json"
LOG_DIR="${SINGBOX_PREFIX}/var/log/sing-box"
LOG_FILE="${LOG_DIR}/sing-box.log"
STATE_DIR="${SINGBOX_PREFIX}/var/lib/sing-box"
WORK_DIR="${STATE_DIR}/work"
REALITY_DB="${STATE_DIR}/reality-pubs.json"
LOCK_FILE="${STATE_DIR}/mutate.lock"
SYSTEMD_UNIT="${SINGBOX_PREFIX}/etc/systemd/system/sing-box.service"
OPENRC_INIT="${SINGBOX_PREFIX}/etc/init.d/sing-box"
LOGROTATE="${SINGBOX_PREFIX}/etc/logrotate.d/sing-box"
RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

INIT_KIND=""
MACHINE=""
BOLD="" ACC="" CYN="" GRN="" RED="" YEL="" DIM="" BORD="" RST=""
CHOOSE=""
LISTEN="" PORT="" TAGPART=""
NOTICE=""
REISSUE_SNI=""
PENDING_TAG=""
PICKED=""
MUTATE_RC=0
ASSET_NAME="" ASSET_URL="" ASSET_SHA=""
DEST_HOST="" DEST_PORT=""

# 提前安全初始化 fd 4，确保以库模式加载时不会因缺少 fd 4 崩溃。
if [ -e /proc/self/fdinfo/4 ] && grep -Eq '^flags:[[:space:]]*[0-9]*[12]' /proc/self/fdinfo/4 2>/dev/null; then
  :
else
  exec 4>&1
fi

# 界面输出走 fd 4。
ui() { printf '%b\n' "$*" >&4; }
uin() { printf '%b' "$*" >&4; }
notice() { NOTICE="$*"; }
hold() { ui "$1"; notice "$1"; }
err() { hold "${RED}[错误]${RST}  $*"; }
warn() { hold "${YEL}[警告]${RST}  $*"; }
note() { ui "${DIM}[提示]${RST}  $*"; }
sticky() { note "$1"; notice "${DIM}[提示]${RST}  $1"; }
okmsg() { hold "${GRN}[完成]${RST}  $*"; }
cancelled() { sticky "已取消"; }

readin() {
  local _v=""
  IFS= read -r _v || _v="q"
  printf '%s' "${_v//$'\r'/}"
}

is_q() { [[ "$1" == q || "$1" == Q ]]; }
is_g() { [[ "$1" == g || "$1" == G ]]; }

dw() {
  # 按字节走，不依赖 locale。ASCII 宽 1，U+0080–U+07FF 宽 1，其余非 ASCII 宽 2。
  local LC_ALL=C rest="$1" n=0 c b
  while [[ -n "$rest" ]]; do
    c="${rest:0:1}"
    rest="${rest:1}"
    printf -v b '%d' "'$c"
    if (( b == 27 )); then
      while [[ -n "$rest" && "${rest:0:1}" != "m" ]]; do rest="${rest:1}"; done
      rest="${rest:1}"
      continue
    fi
    if (( b < 128 )); then n=$((n + 1)); continue; fi
    if (( b >= 194 && b <= 223 )); then n=$((n + 1)); rest="${rest:1}"; continue; fi
    if (( b >= 224 && b <= 239 )); then n=$((n + 2)); rest="${rest:2}"; continue; fi
    if (( b >= 240 && b <= 247 )); then n=$((n + 2)); rest="${rest:3}"; continue; fi
    n=$((n + 1))
  done
  printf '%d' "$n"
}

pad() {
  local s="$1" width="$2" w
  w=$(dw "$s")
  if (( w >= width )); then printf '%s' "$s"; else printf '%s%*s' "$s" $((width - w)) ''; fi
}

ui_tty() { [[ -t 4 && "${TERM:-}" != "dumb" && "${NO_COLOR:-}" != "1" ]]; }
init_ui() {
  BOLD="" ACC="" CYN="" GRN="" RED="" YEL="" DIM="" BORD="" RST=""
  ui_tty || return 0
  BOLD=$'\e[1m'
  ACC=$'\e[38;2;100;181;246m'   # 科技蓝
  CYN=$'\e[38;2;77;208;225m'    # 极光青
  GRN=$'\e[38;2;129;199;132m'   # 翡翠绿
  RED=$'\e[38;2;239;83;80m'     # 珊瑚红
  YEL=$'\e[38;2;255;202;40m'    # 琥珀黄
  DIM=$'\e[38;2;144;164;174m'   # 柔和灰蓝
  BORD=$'\e[38;2;90;110;130m'   # 边框色
  RST=$'\e[0m'
}

cls() {
  ui_tty || return 0
  printf '\e[H\e[2J' >&4 2>/dev/null || true
}

header() {
  cls
  ui " ${ACC}┌──${RST} ${BOLD}$1${RST} ${BORD}──────────────────────────────────────────${RST}"
  ui ""
}

# 窄终端单列，宽终端两列。编号按显示宽度对齐，不用字符串长度。
menu_wide() {
  local c="${COLUMNS:-80}"
  [[ "$c" =~ ^[0-9]+$ ]] || c=80
  (( c >= 72 )) && return 0
  return 1
}

menu_row() {
  local n1="$1" l1="$2" n2="${3:-}" l2="${4:-}"
  local k1 k2
  printf -v k1 '%2d.' "$n1"
  if menu_wide && [[ -n "$n2" ]]; then
    printf -v k2 '%2d.' "$n2"
    ui " ${BORD}│${RST}  ${ACC}${BOLD}${k1}${RST} $(pad "$l1" 12)  ${ACC}${BOLD}${k2}${RST} ${l2}"
  else
    ui " ${BORD}│${RST}  ${ACC}${BOLD}${k1}${RST} ${l1}"
    if [[ -n "$n2" ]]; then
      printf -v k2 '%2d.' "$n2"
      ui " ${BORD}│${RST}  ${ACC}${BOLD}${k2}${RST} ${l2}"
    fi
  fi
}

pause() { uin "  ${DIM}按回车返回${RST} "; readin >/dev/null || true; }

choose() {
  local opt key ans k
  for opt in "$@"; do
    key="${opt%%:*}"
    printf -v k '%2s.' "$key"
    ui "    ${ACC}${BOLD}${k}${RST}  ${opt#*:}"
  done
  while true; do
    uin "  ${CYN}➜${RST} 请选择 ${DIM}(q 返回)${RST} ${ACC}›${RST} "
    ans=$(readin)
    is_q "$ans" && { CHOOSE=""; return 1; }
    for opt in "$@"; do
      key="${opt%%:*}"
      if [[ "$ans" == "$key" ]]; then CHOOSE="$key"; return 0; fi
    done
    err "无效"
  done
}

prompt() {
  local __var="$1" label="$2" def="${3:-}" ans
  if [[ -n "$def" ]]; then
    uin "  ${CYN}➜${RST} ${label} ${DIM}[${def}] (q 返回)${RST} ${ACC}›${RST} "
  else
    uin "  ${CYN}➜${RST} ${label} ${DIM}(q 返回)${RST} ${ACC}›${RST} "
  fi
  ans=$(readin)
  is_q "$ans" && return 1
  [[ -z "$ans" ]] && ans="$def"
  [[ -n "$ans" ]] || return 1
  printf -v "$__var" '%s' "$ans"
}

confirm() {
  local ans
  uin "  ${YEL}？${RST} $1 ${DIM}[y/N] (q 返回)${RST} ${ACC}›${RST} "
  ans=$(readin)
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]
}

# 0 写入；1 取消。输入 n 不会退出，也不会删掉已生成的证书。
confirm_write() {
  local ans
  while true; do
    uin "  ${ACC}➜${RST} ${BOLD}回车写入，q 返回${RST} ${ACC}›${RST} "
    ans=$(readin)
    if is_q "$ans"; then cancelled; return 1; fi
    [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]] && return 0
    err "回车写入，或 q 返回"
  done
}

pick_one() {
  local i=1 item args=()
  for item in "$@"; do args+=("$i:$item"); i=$((i + 1)); done
  choose "${args[@]}" || return 1
  printf '%s' "${@:CHOOSE:1}"
}

kv() {
  local left v="$2" vw
  left=$(pad "$1" 10)
  vw=$(dw "$v")
  if (( vw > 64 )); then
    ui "  ${DIM}${left}${RST}"
    ui "    ${ACC}${v}${RST}"
  else
    ui "  ${DIM}${left}${RST} :  ${ACC}${BOLD}${v}${RST}"
  fi
}

# g 重新生成，回车接受，其他输入替换。
ask_gen() {
  local __var="$1" label="$2" value="$3" ans
  shift 3
  while true; do
    uin "  ${CYN}➜${RST} ${label} ${DIM}[回车接受 / g 重新生成 / q 返回]${RST} ${ACC}›${RST} "
    ans=$(readin)
    is_q "$ans" && return 1
    if is_g "$ans"; then
      local gen=""
      gen=$("$@") || { err "生成失败"; continue; }
      value="$gen"
      continue
    fi
    [[ -n "$ans" ]] && value="$ans"
    [[ -n "$value" ]] || { err "空值"; continue; }
    printf -v "$__var" '%s' "$value"
    return 0
  done
}

need_root() {
  [[ "${SINGBOX_SH_SKIP_ROOT:-}" == "1" || "$(id -u)" -eq 0 ]] && return 0
  printf '%s\n' "必须以 root 运行。"
  exit 1
}

detect_init() {
  if [[ -f /etc/alpine-release ]] && command -v rc-service >/dev/null 2>&1; then
    INIT_KIND="openrc"
  elif command -v systemctl >/dev/null 2>&1; then
    INIT_KIND="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_KIND="openrc"
  else
    return 1
  fi
}

# 发行文件名里的架构，不是 xray 的 zip 后缀。
detect_arch() {
  case "$(uname -m)" in
    i386|i686) MACHINE="386" ;;
    amd64|x86_64) MACHINE="amd64" ;;
    armv5tel|armv5tejl) MACHINE="armv5" ;;
    armv6l) MACHINE="armv6" ;;
    armv7|armv7l|armv8l) MACHINE="armv7" ;;
    armv8|aarch64) MACHINE="arm64" ;;
    loongarch64) MACHINE="loong64" ;;
    mips) MACHINE="mips" ;;
    mipsle) MACHINE="mipsle" ;;
    mips64) MACHINE="mips64" ;;
    mips64le) MACHINE="mips64le" ;;
    ppc64le) MACHINE="ppc64le" ;;
    riscv64) MACHINE="riscv64" ;;
    s390x) MACHINE="s390x" ;;
    *) return 1 ;;
  esac
}

need_musl() {
  [[ -f /etc/alpine-release ]] && return 0
  if command -v ldd >/dev/null 2>&1; then
    ldd --version 2>&1 | grep -qi musl && return 0
  fi
  local f
  for f in /lib/ld-musl-*.so.1 /lib/libc.musl-* /usr/lib/libc.musl-*; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

ensure_tools() {
  local missing=() bin
  for bin in curl tar jq openssl logrotate; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [[ ! -f /etc/ssl/certs/ca-certificates.crt && ! -f /etc/ssl/cert.pem ]]; then
    missing+=(ca-certificates)
  fi
  ((${#missing[@]})) || return 0
  note "安装 ${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${missing[@]}" >/dev/null
  else
    err "无法安装 ${missing[*]}"
    return 1
  fi
}

singbox_is_root_account() {
  id -u sing-box >/dev/null 2>&1 && { [[ "$(id -u sing-box)" -eq 0 || "$(id -g sing-box)" -eq 0 ]]; }
}

ensure_user() {
  if id -u sing-box >/dev/null 2>&1; then
    singbox_is_root_account && { err "sing-box 是 root"; return 1; }
    return 0
  fi
  local shell="/usr/sbin/nologin"
  [[ -x /sbin/nologin ]] && shell="/sbin/nologin"
  if [[ -f /etc/alpine-release ]]; then
    addgroup -S sing-box 2>/dev/null || true
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G sing-box sing-box 2>/dev/null || true
  else
    getent group sing-box >/dev/null || groupadd --system sing-box
    useradd --system --gid sing-box --home-dir /var/empty --shell "$shell" --comment "sing-box" sing-box
  fi
  id -u sing-box >/dev/null 2>&1 || { err "创建用户失败"; return 1; }
  if singbox_is_root_account; then err "sing-box 必须非 root"; return 1; fi
}

own() { chown "$@" 2>/dev/null || true; }

install_dirs() {
  install -d -m 755 -o 0 -g 0 "$(dirname "$BIN")" "$(dirname "$SYSTEMD_UNIT")" "$(dirname "$OPENRC_INIT")"
  install -d -m 750 -o 0 -g sing-box "$CFG_DIR"
  install -d -m 700 -o sing-box -g sing-box "$LOG_DIR"
  install -d -m 750 -o 0 -g sing-box "$STATE_DIR"
  install -d -m 750 -o sing-box -g sing-box "$WORK_DIR"
  [[ -f "$CFG" ]] || write_base_config
  touch "$LOG_FILE"
  own sing-box:sing-box "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  write_logrotate
}

write_logrotate() {
  install -d -m 755 -o 0 -g 0 "$(dirname "$LOGROTATE")"
  cat >"$LOGROTATE" <<EOF
${LOG_DIR}/*.log {
    su sing-box sing-box
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  chmod 644 "$LOGROTATE"
}

write_services() {
  if [[ "$INIT_KIND" == "systemd" ]]; then
    cat >"$SYSTEMD_UNIT" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=sing-box
Group=sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
UMask=0077
ExecStart=${BIN} run --disable-color -c ${CFG} -D ${WORK_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SYSTEMD_UNIT"
    systemctl daemon-reload
  else
    cat >"$OPENRC_INIT" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="The universal proxy platform"
supervisor=supervise-daemon
respawn_delay=5
respawn_max=2
respawn_period=600
pidfile="/run/\${RC_SVCNAME}.pid"
rc_ulimit="-n 1024000 -u 1024000"
capabilities="^cap_net_bind_service,^cap_net_admin,^cap_net_raw"
no_new_privs=yes
umask=0077
extra_commands="checkconfig"
command="${BIN}"
command_user="sing-box:sing-box"
command_args="run --disable-color -c ${CFG} -D ${WORK_DIR}"
required_files="${CFG}"
depend() { need net; after firewall; }
checkconfig() { su -s /bin/sh -c "\$command check --disable-color -c ${CFG} -D ${WORK_DIR}" "\${command_user%:*}"; eend \$?; }
start_pre() { checkconfig; }
EOF
    chmod 755 "$OPENRC_INIT"
  fi
}

svc() {
  local act="$1"
  {
  if [[ "$INIT_KIND" == "systemd" ]]; then
    case "$act" in
      installed) [[ -x "$BIN" && -f "$SYSTEMD_UNIT" ]] ;;
      running) systemctl is-active --quiet sing-box ;;
      start|restart) systemctl enable sing-box >/dev/null 2>&1 || true; systemctl "$act" sing-box ;;
      stop) timeout 20 systemctl stop sing-box ;;
      disable) systemctl disable sing-box >/dev/null 2>&1 || true; rm -f "$SYSTEMD_UNIT"; systemctl daemon-reload || true ;;
    esac
  else
    case "$act" in
      installed) [[ -x "$BIN" && -f "$OPENRC_INIT" ]] ;;
      running) rc-service sing-box status >/dev/null 2>&1 ;;
      start|restart) rc-update add sing-box default >/dev/null 2>&1 || true; rc-service sing-box "$act" >/dev/null 2>&1 </dev/null ;;
      stop) timeout 20 rc-service sing-box stop >/dev/null 2>&1 </dev/null ;;
      disable) rc-update del sing-box default >/dev/null 2>&1 || true; rm -f "$OPENRC_INIT" ;;
    esac
  fi
  } </dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
}

svc_wait() {
  svc "$1" || return 1
  sleep 0.4
  svc running
}

assert_runtime_user() {
  local unit_user=""
  if [[ "$INIT_KIND" == "systemd" && -f "$SYSTEMD_UNIT" ]]; then
    unit_user=$(awk -F= '/^User=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$SYSTEMD_UNIT")
  elif [[ -f "$OPENRC_INIT" ]]; then
    unit_user=$(sed -n 's/^command_user="\([^:"]*\).*/\1/p' "$OPENRC_INIT" | head -n1)
  fi
  [[ "$unit_user" == "sing-box" ]] || { err "服务用户不是 sing-box"; return 1; }
  local uid
  uid=$(id -u sing-box 2>/dev/null) || { err "没有 sing-box 用户"; return 1; }
  [[ "$uid" != "0" ]] || { err "sing-box uid 为 0"; return 1; }
}

current_version() {
  [[ -x "$BIN" ]] || return 0
  "$BIN" version -n 2>/dev/null | head -n1
}

latest_version() {
  local tmp tag
  tmp=$(mktemp)
  curl -fsSL --connect-timeout 8 --max-time 20 -H "Accept: application/vnd.github+json" -o "$tmp" "$RELEASE_API" || { rm -f "$tmp"; return 1; }
  tag=$(jq -r '.tag_name // empty' "$tmp")
  rm -f "$tmp"
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "${tag#v}"
}

# 官方包是 tar.gz。musl 系统优先用带 -musl 的包，通用包做兜底。
pick_asset() {
  local json="$1" ver="$2" name url sha
  local -a names=()
  ASSET_NAME="" ASSET_URL="" ASSET_SHA=""
  if need_musl; then
    names=(
      "sing-box-${ver}-linux-${MACHINE}-musl.tar.gz"
      "sing-box-${ver}-linux-${MACHINE}-softfloat-musl.tar.gz"
      "sing-box-${ver}-linux-${MACHINE}.tar.gz"
    )
  else
    names=("sing-box-${ver}-linux-${MACHINE}.tar.gz")
  fi
  for name in "${names[@]}"; do
    url=$(jq -r --arg n "$name" '.assets[]? | select(.name==$n) | .browser_download_url // empty' "$json")
    [[ -n "$url" ]] || continue
    sha=$(jq -r --arg n "$name" '.assets[]? | select(.name==$n) | .digest // empty' "$json")
    ASSET_NAME="$name"
    ASSET_URL="$url"
    ASSET_SHA="${sha#sha256:}"
    ASSET_SHA="${ASSET_SHA,,}"
    return 0
  done
  return 1
}

# 密钥在这个目录里。用户已存在时保留组可进入，供服务读工作目录。
secure_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  if id -g sing-box >/dev/null 2>&1; then
    chown "0:sing-box" "$STATE_DIR" 2>/dev/null || true
    chmod 750 "$STATE_DIR" 2>/dev/null || true
  else
    chmod 700 "$STATE_DIR" 2>/dev/null || true
  fi
}

mktemp_json() {
  local name="$1" f
  secure_state || return 1
  f=$(mktemp "${STATE_DIR}/${name}.XXXXXX") || return 1
  chmod 600 "$f" || true
  mv "$f" "${f}.json"
  chmod 600 "${f}.json" || true
  printf '%s\n' "${f}.json"
}

human_size() {
  local n=${1:-0}
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n >= 1048576 )); then
    printf '%d.%d MB' $((n / 1048576)) $(((n % 1048576) * 10 / 1048576))
  elif (( n >= 1024 )); then
    printf '%d KB' $((n / 1024))
  else
    printf '%d B' "$n"
  fi
}

dl_meter() {
  local got=${1:-0} total=${2:-0} width=22 fill=0 pct=0 bar rest
  [[ "$got" =~ ^[0-9]+$ ]] || got=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  if (( total > 0 )); then
    fill=$((got * width / total))
    if (( fill > width )); then fill=$width; fi
    pct=$((got * 100 / total))
    if (( pct > 100 )); then pct=100; fi
    printf -v bar '%*s' "$fill" ''
    printf -v rest '%*s' $((width - fill)) ''
    printf '[%s] %3d%%  %s / %s' "${bar// /#}${rest// /-}" "$pct" "$(human_size "$got")" "$(human_size "$total")"
  else
    human_size "$got"
  fi
}

dl_draw() {
  printf '\r\e[K  %b' "$(pad "下载进度" 10) : ${ACC}$(dl_meter "$1" "$2")${RST}" >&4
}

download_install() {
  local ver="$1" tmp rel tar src got total=0 pid size="" arch
  detect_arch || { err "不支持 $(uname -m)"; return 1; }
  rel=$(mktemp)
  curl -fsSL --connect-timeout 8 --max-time 20 -H "Accept: application/vnd.github+json" -o "$rel" "$RELEASE_API" || { rm -f "$rel"; err "获取版本失败"; return 1; }
  if [[ "$(jq -r '.tag_name // empty' "$rel")" != "v${ver}" ]]; then
    rm -f "$rel"
    err "发布版本不一致"
    return 1
  fi
  pick_asset "$rel" "$ver" || { rm -f "$rel"; err "没有对应安装包"; return 1; }
  rm -f "$rel"
  arch="${ASSET_NAME#sing-box-"${ver}"-linux-}"
  arch="${arch%.tar.gz}"
  kv "版本" "v${ver}"
  kv "架构" "$arch"
  kv "文件" "$ASSET_NAME"
  tmp=$(mktemp -d)
  # RETURN 会在调用者也返回时再跑一次，第一次清掉陷阱，避免 tmp 已失效。
  trap 'rm -rf "$tmp"; trap - RETURN' RETURN
  tar="${tmp}/sing-box.tar.gz"
  total=$(curl -fsSLI --retry 2 --connect-timeout 8 --max-time 15 "$ASSET_URL" 2>/dev/null | awk 'tolower($1)=="content-length:" {n=$2} END{gsub(/\r/,"",n); print n}' || true)
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  curl -fsSL --retry 3 --connect-timeout 8 -o "$tar" "$ASSET_URL" 2>/dev/null &
  pid=$!
  if ui_tty; then
    while kill -0 "$pid" 2>/dev/null; do
      size=$(wc -c <"$tar" 2>/dev/null || true)
      dl_draw "${size// /}" "$total"
      sleep 0.25
    done
    size=$(wc -c <"$tar" 2>/dev/null || true)
    dl_draw "${size// /}" "$total"
    printf '\n' >&4
  fi
  wait "$pid" || { err "下载失败"; return 1; }
  if ! ui_tty; then
    size=$(wc -c <"$tar" 2>/dev/null || true)
    kv "大小" "$(human_size "${size// /}")"
  fi
  if [[ -n "${ASSET_SHA:-}" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      got=$(sha256sum "$tar" | awk '{print tolower($1)}')
    else
      got=$(openssl dgst -sha256 "$tar" | awk '{print tolower($NF)}')
    fi
    if [[ "$ASSET_SHA" != "$got" ]]; then err "校验失败"; return 1; fi
    kv "校验" "通过"
  else
    warn "无校验信息"
  fi
  mkdir -p "$tmp/out"
  tar -xzf "$tar" -C "$tmp/out" || { err "解压失败"; return 1; }
  src=""
  while IFS= read -r src; do break; done < <(find "$tmp/out" -type f -name sing-box)
  [[ -n "$src" && -f "$src" ]] || { err "压缩包里没有内核"; return 1; }
  ensure_user || return 1
  install_dirs || { err "建目录失败"; return 1; }
  install -m 755 -o 0 -g 0 "$src" "$BIN" || { err "安装失败"; return 1; }
  write_services || { err "写服务失败"; return 1; }
  assert_runtime_user || return 1
}

# https://sing-box.sagernet.org/configuration/log/
# https://sing-box.sagernet.org/configuration/route/rule_action/#sniff
write_base_config() {
  mkdir -p "$(dirname "$CFG")" 2>/dev/null || true
  jq -n --arg out "$LOG_FILE" \
    '{log:{level:"info",timestamp:true,output:$out},inbounds:[],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[{action:"sniff"}],final:"direct"}}' >"$CFG"
  own "0:sing-box" "$CFG"
  chmod 640 "$CFG"
}

cfg_ok() { [[ -f "$CFG" ]] && jq -e . "$CFG" >/dev/null 2>&1; }

inbound_count() {
  cfg_ok && jq '[.inbounds[]?] | length' "$CFG" || printf '0'
}

list_tags() {
  cfg_ok || return 0
  jq -r '.inbounds[]?.tag' "$CFG"
}

inbound_json() { jq -c --arg t "$1" '.inbounds[] | select(.tag==$t)' "$CFG"; }
j() { jq -r "$1" <<<"$obj"; }
inbound_sec() {
  if [[ "$(j '.tls.reality.enabled // false')" == "true" ]]; then printf '%s' "reality"
  elif [[ "$(j '.tls.enabled // false')" == "true" ]]; then printf '%s' "tls"
  else printf '%s' "none"; fi
}

port_in_cfg() {
  local port="$1" except="${2:-}" kind="${3:-tcpudp}"
  cfg_ok || return 1
  jq -e --arg p "$port" --arg ex "$except" --arg kind "$kind" '
    def inet:
      if .type == "hysteria2" then "udp"
      elif .type == "shadowsocks" then
        if .network == null or .network == "" then "tcp,udp"
        elif (.network|type) == "array" then
          if ((.network|index("tcp")) and (.network|index("udp"))) then "tcp,udp"
          elif (.network|index("udp")) then "udp"
          else "tcp" end
        elif .network == "udp" then "udp"
        elif .network == "tcp" then "tcp"
        else "tcp,udp" end
      else "tcp" end;
    def hit($n):
      if $kind == "tcp" then ($n == "tcp" or $n == "tcp,udp")
      elif $kind == "udp" then ($n == "udp" or $n == "tcp,udp")
      else true end;
    [.inbounds[]? | select(.tag != $ex) | select((.listen_port|tostring) == $p) | select(hit(inet))] | any
  ' "$CFG" >/dev/null
}

# 没有 ss 时读 /proc/net。TCP 只算 LISTEN（0A），UDP 绑定即算占用。
proc_port_open() {
  local port="$1" kind="$2" hex files=() f
  printf -v hex '%04X' "$((10#$port))"
  hex="${hex,,}"
  case "$kind" in
    tcp) files=(/proc/net/tcp /proc/net/tcp6) ;;
    udp) files=(/proc/net/udp /proc/net/udp6) ;;
    *) files=(/proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6) ;;
  esac
  for f in "${files[@]}"; do
    [[ -r "$f" ]] || continue
    awk -v hex="$hex" -v kind="${f##*/}" 'NR>1 {
      split($2, a, ":")
      if (tolower(a[2]) != hex) next
      if (kind ~ /^tcp/ && $4 != "0A") next
      found=1
    } END { exit found ? 0 : 1 }' "$f" && return 0
  done
  return 1
}

port_taken() {
  local port="$1" except="${2:-}" kind="${3:-tcpudp}" flags="-lntuH"
  port_in_cfg "$port" "$except" "$kind" && return 0
  if command -v ss >/dev/null 2>&1; then
    case "$kind" in
      tcp) flags="-lntH" ;;
      udp) flags="-lnuH" ;;
    esac
    ss $flags 2>/dev/null | awk '{print $(NF-1)}' | grep -Eq "(^|:|\])${port}$"
    return
  fi
  proc_port_open "$port" "$kind"
}

gen_uuid() {
  if [[ -x "$BIN" ]]; then "$BIN" generate uuid 2>/dev/null | head -n1
  else cat /proc/sys/kernel/random/uuid; fi
}

# 私钥留在服务端配置里。公钥用 sing-box 自己的输出存起来，推导只做旧配置的后备。
remember_reality_pub() {
  local priv="$1" pub="$2" tmp
  [[ -n "$priv" && -n "$pub" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  secure_state || return 0
  [[ -f "$REALITY_DB" ]] || printf '%s\n' '{}' >"$REALITY_DB"
  chown 0:0 "$REALITY_DB" 2>/dev/null || true
  chmod 600 "$REALITY_DB" || true
  tmp=$(mktemp_json reality) || return 0
  if jq --arg k "$priv" --arg v "$pub" '.[$k]=$v' "$REALITY_DB" >"$tmp"; then
    chown 0:0 "$tmp" 2>/dev/null || true
    chmod 600 "$tmp" || true
    mv "$tmp" "$REALITY_DB"
  else
    rm -f "$tmp"
  fi
}

stored_reality_pub() {
  local priv="$1" pub=""
  [[ -f "$REALITY_DB" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  pub=$(jq -r --arg k "$priv" '.[$k] // empty' "$REALITY_DB" 2>/dev/null) || return 1
  [[ -n "$pub" && "$pub" != "null" ]] || return 1
  printf '%s\n' "$pub"
}

gen_reality_keys() {
  local out p pub
  [[ -x "$BIN" ]] || return 1
  out=$("$BIN" generate reality-keypair 2>/dev/null) || return 1
  p=$(awk '/^PrivateKey:/ {print $2; exit}' <<<"$out")
  pub=$(awk '/^PublicKey:/ {print $2; exit}' <<<"$out")
  [[ -n "$p" ]] || return 1
  [[ -n "$pub" ]] && remember_reality_pub "$p" "$pub"
  printf '%s\n' "$p"
}

b64_rawurl_decode() {
  local s="$1"
  s=${s//$'\n'/}
  s=$(printf '%s' "$s" | tr '_-' '/+')
  case $(( ${#s} % 4 )) in
    2) s+="==" ;;
    3) s+="=" ;;
  esac
  printf '%s' "$s" | openssl base64 -d -A 2>/dev/null
}

reality_public() {
  local priv="$1" tmp pub
  [[ -n "$priv" ]] || return 1
  if pub=$(stored_reality_pub "$priv"); then
    printf '%s\n' "$pub"
    return 0
  fi
  tmp=$(mktemp -d)
  b64_rawurl_decode "$priv" >"$tmp/raw" || { rm -rf "$tmp"; return 1; }
  [[ $(wc -c <"$tmp/raw") -eq 32 ]] || { rm -rf "$tmp"; return 1; }
  printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20' >"$tmp/hdr"
  cat "$tmp/hdr" "$tmp/raw" >"$tmp/priv.der"
  openssl pkey -inform DER -in "$tmp/priv.der" -pubout -outform DER -out "$tmp/pub.der" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  pub=$(tail -c 32 "$tmp/pub.der" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  rm -rf "$tmp"
  [[ -n "$pub" ]] || return 1
  printf '%s\n' "$pub"
}

gen_short_id() { openssl rand -hex 8; }
rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; printf '\n'; }

gen_ss_password() {
  local n=32
  case "$1" in
    2022-blake3-aes-128-gcm) n=16 ;;
    2022-*) ;;
    *) n=24 ;;
  esac
  rand_b64 "$n"
}

# 2022 要的是解码后的 16 或 32 字节，不是字符串长度。
ss_password_ok() {
  local method="$1" pw="$2" need got
  case "$method" in
    2022-blake3-aes-128-gcm) need=16 ;;
    2022-*) need=32 ;;
    *) [[ ${#pw} -ge 8 ]]; return ;;
  esac
  got=$(printf '%s' "$pw" | openssl base64 -d -A 2>/dev/null | wc -c) || return 1
  [[ "${got// /}" -eq "$need" ]]
}
ss_pw_err() { if [[ "$1" == 2022-* ]]; then err "密码无效"; else err "密码过短"; fi; }

gen_obfs() { rand_b64 18; }

urlencode() { jq -nr --arg s "$1" '$s|@uri'; }

v6_skip() { [[ "$1" =~ ^fe[89a-f][0-9a-f]:|^(fc|fd)[0-9a-f]*: ]]; }

# 去掉掩码后的公网地址。内网、链路本地和回环不参与分享。
share_keep() {
  local ip="${1%%/*}"
  ip="${ip//$'\r'/}"
  ip="${ip,,}"
  [[ -n "$ip" ]] || return 1
  if [[ "$ip" == ::ffff:* ]]; then
    local mapped="${ip#::ffff:}"
    [[ "$mapped" == *.* ]] || return 1
    share_keep "$mapped"
    return
  fi
  case "$ip" in
    10.*|127.*|192.168.*|169.254.*|0.*|::|::1) return 1 ;;
  esac
  v6_skip "$ip" && return 1
  [[ "$ip" =~ ^2001:0*db8:|^172\.(1[6-9]|2[0-9]|3[01])\.|^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|^192\.0\.2\.|^198\.51\.100\.|^203\.0\.113\.|^198\.1[89]\.|^(22[4-9]|23[0-9])\.|^(24[0-9]|25[0-5])\. ]] && return 1
  printf '%s\n' "$ip"
}

v6_routable() {
  local raw ip
  command -v ip >/dev/null 2>&1 || return 1
  while read -r raw; do
    ip="${raw%%/*}"
    ip="${ip,,}"
    [[ -n "$ip" ]] || continue
    v6_skip "$ip" && continue
    return 0
  done < <(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}')
  return 1
}

SHARE_VIA=""
SHARE_SEEN="|"
SHARE_LINES=()

share_take() {
  local ip
  ip=$(share_keep "$1") || return 0
  case "$SHARE_SEEN" in
    *"|$ip|"*) return 0 ;;
  esac
  SHARE_SEEN="${SHARE_SEEN}${ip}|"
  [[ "$ip" == *:* ]] && ip="[$ip]"
  SHARE_LINES+=("$ip")
}

share_has() {
  local host
  for host in "${SHARE_LINES[@]}"; do
    case "$1" in
      4) [[ "$host" != \[* ]] && return 0 ;;
      6) [[ "$host" == \[* ]] && return 0 ;;
    esac
  done
  return 1
}

share_load() {
  local raw out fam
  SHARE_SEEN="|"
  SHARE_LINES=()
  SHARE_VIA="iface"
  if command -v ip >/dev/null 2>&1; then
    for fam in -4 -6; do
      while read -r raw; do share_take "$raw"; done \
        < <(ip -o "$fam" addr show scope global 2>/dev/null | awk '{print $4}')
    done
  elif out=$(hostname -I 2>/dev/null); then
    for raw in $out; do share_take "$raw"; done
  fi
  if command -v curl >/dev/null 2>&1; then
    if ! share_has 4; then
      share_egress -4 https://1.1.1.1/cdn-cgi/trace https://api.ipify.org
    fi
    if ! share_has 6 && v6_routable; then
      share_egress -6 'https://[2606:4700:4700::1111]/cdn-cgi/trace' https://api6.ipify.org
    fi
  fi
  return 0
}

share_egress() {
  local addr before=${#SHARE_LINES[@]}
  addr=$(curl "$1"fsS --connect-timeout 2 --max-time 3 "$2" 2>/dev/null || true)
  addr=$(printf '%s\n' "$addr" | sed -n 's/^ip=//p' | head -n1)
  [[ -z "$addr" ]] && addr=$(curl "$1"fsS --connect-timeout 2 --max-time 3 "$3" 2>/dev/null || true)
  [[ -n "$addr" ]] && share_take "$addr"
  if (( ${#SHARE_LINES[@]} > before )); then SHARE_VIA="egress"; fi
  return 0
}

# https://sing-box.sagernet.org/configuration/inbound/vless/
# https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
# https://sing-box.sagernet.org/configuration/shared/tls/
build_vless() {
  local tag="$1" listen="$2" port="$3" uuid="$4" kind="$5"
  shift 5
  local flow="" sni="" dest_host="" dest_port="" priv="" sid="" path="" host="" alpn="" sec="" method=""
  case "$kind" in
    tcp-reality)
      flow="xtls-rprx-vision"; sni="$1"; dest_host="$2"; dest_port="$3"; priv="$4"; sid="$5"
      sec="reality" ;;
    ws-tls)
      sni="$1"; path="$2"; host="$3"
      sec="tls"; method="ws"; alpn="http/1.1" ;;
    *) return 1 ;;
  esac
  jq -n \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg uuid "$uuid" --arg flow "$flow" --arg sni "$sni" \
    --arg dest_host "$dest_host" --arg dest_port "$dest_port" \
    --arg priv "$priv" --arg sid "$sid" --arg path "$path" --arg host "$host" \
    --arg alpn "$alpn" --arg sec "$sec" --arg method "$method" \
    --arg certdir "${CFG_DIR}/certs" \
    '{
      type:"vless", tag:$tag, listen:$listen, listen_port:$port,
      users:[({name:$tag, uuid:$uuid} + (if $flow=="" then {} else {flow:$flow} end))],
      tls:(
        {enabled:true, server_name:$sni}
        + (if $alpn=="" then {} else {alpn:[$alpn]} end)
        + (if $sec=="reality" then {reality:{
            enabled:true,
            handshake:{server:$dest_host, server_port:($dest_port|tonumber)},
            private_key:$priv,
            short_id:[$sid]
          }} else {
            certificate_path:($certdir+"/"+$tag+".crt"),
            key_path:($certdir+"/"+$tag+".key")
          } end)
      )
    }
    + (if $method=="ws" then {
        transport: ({type:"ws", path:$path} + (if $host=="" then {} else {headers:{Host:$host}} end))
      } else {} end)'
}

# https://sing-box.sagernet.org/configuration/inbound/shadowsocks/
# https://sing-box.sagernet.org/configuration/inbound/hysteria2/
build_inbound() {
  local proto="$1" tag="$2" listen="$3" port="$4"
  shift 4
  case "$proto" in
    shadowsocks)
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
        --arg method "$1" --arg password "$2" --arg network "$3" \
        '{type:"shadowsocks", tag:$tag, listen:$listen, listen_port:$port,
          method:$method, password:$password}
         + (if $network=="" or $network=="tcp,udp" then {} else {network:$network} end)'
      ;;
    vless) build_vless "$tag" "$listen" "$port" "$@" ;;
    hysteria2)
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
        --arg auth "$1" --arg sni "$2" --arg obfs "$3" --argjson up "$4" --argjson down "$5" \
        --arg certdir "${CFG_DIR}/certs" \
        '{type:"hysteria2", tag:$tag, listen:$listen, listen_port:$port,
          up_mbps:$up, down_mbps:$down,
          obfs:{type:"salamander", password:$obfs},
          users:[{name:$tag, password:$auth}],
          tls:{
            enabled:true, server_name:$sni, alpn:["h3"],
            certificate_path:($certdir+"/"+$tag+".crt"),
            key_path:($certdir+"/"+$tag+".key")
          }}'
      ;;
    *) return 1 ;;
  esac
}

install_cert_pair() {
  local crt="$1" key="$2" src_crt="$3" src_key="$4" dir
  dir=$(dirname "$crt")
  install -d -m 750 -o 0 -g sing-box "$dir"
  install -m 640 -o 0 -g sing-box "$src_crt" "$crt"
  install -m 640 -o 0 -g sing-box "$src_key" "$key"
}

mark_self_signed() { printf '%s\n' self >"${CFG_DIR}/certs/${1}.self"; chmod 644 "${CFG_DIR}/certs/${1}.self"; }
cert_is_self() { [[ -f "${CFG_DIR}/certs/${1}.self" ]]; }

make_cert_files() {
  local dir="$1" cn="$2" subj ext
  cn="${cn//$'\n'/}"
  cn="${cn//$'\r'/}"
  cn="${cn//\//_}"
  cn="${cn//=/_}"
  cn="${cn//\"/_}"
  cn="${cn//\\/_}"
  [[ -n "$cn" ]] || return 1
  printf -v subj '/CN=%s' "$cn"
  ext="subjectAltName=DNS:${cn}"
  [[ "$cn" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && ext="subjectAltName=IP:${cn}"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$dir/k" -out "$dir/c" -days 3650 -nodes -subj "$subj" \
    -addext "$ext" >/dev/null 2>&1
}

ensure_self_signed() {
  local tag="$1" sni="$2" tmp rc=0
  local crt="${CFG_DIR}/certs/${tag}.crt" key="${CFG_DIR}/certs/${tag}.key"
  [[ -f "$crt" && -f "$key" ]] && return 0
  tmp=$(mktemp -d)
  make_cert_files "$tmp" "$sni" && install_cert_pair "$crt" "$key" "$tmp/c" "$tmp/k" && mark_self_signed "$tag" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

drop_cert() {
  rm -f "${CFG_DIR}/certs/${1}.crt" "${CFG_DIR}/certs/${1}.key" "${CFG_DIR}/certs/${1}.self"
}

ask_cert() {
  local tag="$1" sni="$2" crt key
  choose "1:自签名" "2:已有证书" || return 1
  if [[ "$CHOOSE" == "1" ]]; then
    ensure_self_signed "$tag" "$sni" || { err "证书失败"; return 1; }
  else
    prompt crt "证书" || return 1
    prompt key "私钥" || return 1
    [[ "$crt" == /* && "$key" == /* && -f "$crt" && -f "$key" && ! -L "$crt" && ! -L "$key" ]] \
      || { err "证书不存在"; return 1; }
    install_cert_pair "${CFG_DIR}/certs/${tag}.crt" "${CFG_DIR}/certs/${tag}.key" "$crt" "$key" \
      || { err "证书安装失败"; return 1; }
  fi
}

sb_test_file() {
  local file="$1" out rc=0
  [[ -x "$BIN" ]] || { err "未安装"; return 1; }
  if [[ "${SINGBOX_AS_USER:-1}" != "0" ]]; then
    id -u sing-box >/dev/null 2>&1 || { err "没有 sing-box 用户"; return 1; }
    install -d -m 750 -o 0 -g sing-box "$STATE_DIR"
    install -m 640 -o 0 -g sing-box "$file" "${STATE_DIR}/test-config.json"
    file="${STATE_DIR}/test-config.json"
    out=$(su -s /bin/sh sing-box -c "'${BIN}' check --disable-color -c '${file}' -D '${WORK_DIR}'" 2>&1) || rc=$?
    rm -f "$file"
  else
    out=$("$BIN" check --disable-color -c "$file" -D "$WORK_DIR" 2>&1) || rc=$?
  fi
  (( rc == 0 )) && return 0
  err "配置无效"
  note "$(printf '%s\n' "$out" | tail -n 5 | tr '\n' ' ' | cut -c1-240)"
  return 1
}

finish_mutate() {
  flock -u 9 || true
  exec 9>&-
  MUTATE_RC="$1"
  return 0
}

mutate() {
  local newf="$1" bak="${STATE_DIR}/config.json.bak"
  MUTATE_RC=1
  secure_state || { err "无法建立状态目录"; return 1; }
  exec 9>"$LOCK_FILE"
  flock -n 9 || { exec 9>&-; err "正在写入"; return 1; }
  if [[ -f "$CFG" ]]; then cp -a "$CFG" "$bak"; else printf '%s\n' '{}' >"$bak"; fi
  chown 0:0 "$bak" 2>/dev/null || true
  chmod 600 "$bak" || true
  if ! sb_test_file "$newf"; then finish_mutate 1; return 0; fi
  install -m 640 -o 0 -g sing-box "$newf" "$CFG"
  restore_bak() { cp -a "$bak" "$CFG"; own "0:sing-box" "$CFG"; chmod 640 "$CFG"; }
  if ! svc installed || ! svc running; then
    if svc installed && ! svc start; then
      restore_bak
      err "启动失败，已回滚"
      svc start || err "回滚后仍未启动"
      finish_mutate 1; return 0
    fi
    finish_mutate 0; return 0
  fi
  if ! svc restart; then
    restore_bak
    err "重启失败，正在回滚"
    if ! svc restart; then
      err "回滚失败，服务未拉起"
      note "服务管理器返回非零"
      finish_mutate 2; return 0
    fi
    warn "已回滚并启动"
    finish_mutate 1; return 0
  fi
  sleep 0.4
  if ! svc running; then
    restore_bak
    if ! svc restart; then err "回滚失败"; finish_mutate 2; return 0; fi
    err "进程退出，已回滚"
    finish_mutate 1; return 0
  fi
  finish_mutate 0
  return 0
}

mutate_jq() {
  local name="$1" tmp
  shift
  MUTATE_RC=1
  tmp=$(mktemp_json "$name") || return 1
  if ! jq "$@" "$CFG" >"$tmp"; then rm -f "$tmp"; err "配置无效"; return 1; fi
  mutate "$tmp" || true
  rm -f "$tmp"
}

upsert_inbound() {
  local obj="$1" old="${2:-}"
  cfg_ok || write_base_config
  mutate_jq upsert --argjson obj "$obj" --arg old "$old" \
    '.inbounds |= (map(select(.tag != $old and .tag != $obj.tag)) + [$obj])'
}

remove_inbound() {
  mutate_jq remove --arg t "$1" '.inbounds |= map(select(.tag != $t))'
  if [[ "${MUTATE_RC:-1}" == 0 ]]; then drop_cert "$1"; fi
}

share_link_of() {
  local tag="$1" host obj proto port
  host="${2:-}"
  [[ -n "$host" ]] || return 1
  obj=$(inbound_json "$tag") || return 1
  proto=$(j '.type')
  port=$(j '.listen_port')
  case "$proto" in
    shadowsocks)
      local method password userinfo
      method=$(j '.method')
      password=$(j '.password')
      userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w0 2>/dev/null || printf '%s:%s' "$method" "$password" | base64)
      printf 'ss://%s@%s:%s#%s\n' "$(printf '%s' "$userinfo" | tr -d '\n')" "$host" "$port" "$(urlencode "$tag")"
      ;;
    vless)
      local id flow net sec sni sid pub path hosth q alpn
      id=$(j '.users[0].uuid')
      flow=$(j '.users[0].flow // empty')
      net=$(j '.transport.type // "tcp"')
      sec=$(inbound_sec)
      path=$(j '.transport.path // empty')
      hosth=$(j '(.transport.headers.Host // empty) | if type=="array" then .[0] else . end')
      q="encryption=none&security=${sec}&type=${net}&fp=chrome"
      [[ -n "$flow" && "$flow" != "null" ]] && q+="&flow=$(urlencode "$flow")"
      if [[ "$sec" == "reality" ]]; then
        pub=$(reality_public "$(j '.tls.reality.private_key // empty')" || true)
        [[ -n "$pub" ]] || return 1
        sni=$(j '.tls.server_name // empty')
        sid=$(j '.tls.reality.short_id[0] // empty')
        q+="&sni=$(urlencode "$sni")&pbk=$(urlencode "$pub")&sid=$(urlencode "$sid")"
      else
        sni=$(j '.tls.server_name // empty')
        alpn=$(j '.tls.alpn // [] | if type=="array" then join(",") else . end')
        q+="&sni=$(urlencode "$sni")"
        cert_is_self "$tag" && q+="&allowInsecure=1"
        [[ -n "$alpn" && "$alpn" != "null" ]] && q+="&alpn=$(urlencode "$alpn")"
      fi
      [[ "$net" == "ws" ]] && q+="&path=$(urlencode "$path")"
      [[ "$net" == "ws" && -n "$hosth" && "$hosth" != "null" ]] && q+="&host=$(urlencode "$hosth")"
      printf 'vless://%s@%s:%s?%s#%s\n' "$(urlencode "$id")" "$host" "$port" "$q" "$(urlencode "$tag")"
      ;;
    hysteria2)
      local auth sni obfs insecure=""
      auth=$(j '.users[0].password')
      sni=$(j '.tls.server_name // empty')
      obfs=$(j '.obfs.password // empty')
      cert_is_self "$tag" && insecure="&insecure=1"
      printf 'hysteria2://%s@%s:%s?sni=%s%s&obfs=salamander&obfs-password=%s#%s\n' \
        "$(urlencode "$auth")" "$host" "$port" "$(urlencode "$sni")" "$insecure" "$(urlencode "$obfs")" "$(urlencode "$tag")"
      ;;
  esac
}

net_label() {
  j 'if .network == null or .network == "" then "tcp,udp"
     elif (.network|type)=="array" then (.network|join(","))
     else .network end'
}

summary_of() {
  local obj="$1" proto port listen tag vnet vsec vflow hosth
  proto=$(j '.type')
  port=$(j '.listen_port')
  listen=$(j '.listen')
  tag=$(j '.tag')
  ui "  ${ACC}┌── 节点配置摘要 ──────────────────────────────${RST}"
  kv "协议" "$proto"
  kv "备注" "$tag"
  kv "监听" "$(fmt_addr "$listen" "$port")"
  case "$proto" in
    shadowsocks)
      kv "加密" "$(j '.method')"
      kv "网络" "$(net_label)"
      ;;
    vless)
      vnet=$(j '.transport.type // "tcp"')
      vsec=$(inbound_sec)
      vflow=$(j '.users[0].flow // "-"')
      [[ -z "$vflow" || "$vflow" == "null" ]] && vflow="-"
      kv "传输" "$vnet"
      kv "安全" "$vsec"
      [[ "$vflow" != "-" ]] && kv "流控" "$vflow"
      if [[ "$vsec" == "reality" ]]; then
        kv "SNI" "$(j '.tls.server_name')"
        kv "目标" "$(fmt_addr "$(j '.tls.reality.handshake.server')" "$(j '.tls.reality.handshake.server_port')")"
        kv "ShortId" "$(j '.tls.reality.short_id[0]')"
      else
        kv "SNI" "$(j '.tls.server_name // "-"')"
      fi
      if has_path "$vnet"; then
        kv "路径" "$(j '.transport.path // "/"')"
        hosth=$(j '(.transport.headers.Host // "-") | if type=="array" then .[0] else . end')
        [[ -n "$hosth" && "$hosth" != "null" && "$hosth" != "-" ]] && kv "主机" "$hosth"
      fi
      ;;
    hysteria2)
      kv "SNI" "$(j '.tls.server_name')"
      kv "混淆" "$(j '.obfs.type // "salamander"')"
      kv "上传" "$(j '.up_mbps') Mbps"
      kv "下载" "$(j '.down_mbps') Mbps"
      ;;
  esac
  ui "  ${ACC}└──────────────────────────────────────────────${RST}"
  return 0
}

fmt_addr() {
  local listen="$1" port="$2"
  if [[ "$listen" == *:* ]]; then printf '[%s]:%s' "$listen" "$port"
  else printf '%s:%s' "$listen" "$port"; fi
}

valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
parse_mbps() {
  local v="${1//[[:space:]]/}"
  v="${v%[mM][bB][pP][sS]}"
  v="${v%[mM][bB]}"
  v="${v%[mM]}"
  if [[ "$v" =~ ^[1-9][0-9]{0,6}$ ]] && (( 10#$v <= 1000000 )); then
    printf '%d' "$(( 10#$v ))"
    return 0
  fi
  return 1
}
valid_mbps() { parse_mbps "$1" >/dev/null; }
valid_ipv6() {
  local a="${1,,}" left="" right="" n=0 g compressed=0
  [[ "$a" =~ ^[0-9a-f:]+$ && "$a" == *:* && "$a" != *::*::* && "$a" != *:::* ]] || return 1
  [[ "$a" == *::* ]] && compressed=1
  if (( compressed )); then
    left="${a%%::*}"
    right="${a#*::}"
    [[ -n "$left" ]] && n=$(awk -F: '{print NF}' <<<"$left")
    [[ -n "$right" ]] && n=$((n + $(awk -F: '{print NF}' <<<"$right")))
    (( n < 8 )) || return 1
  else
    [[ "$a" != :* && "$a" != *: ]] || return 1
    n=$(awk -F: '{print NF}' <<<"$a")
    (( n == 8 )) || return 1
  fi
  local IFS=:
  for g in ${a//::/:}; do
    if [[ -z "$g" ]]; then
      (( compressed )) && continue
      return 1
    fi
    [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1
  done
}
has_path() { [[ "$1" == ws ]]; }
valid_listen() {
  local a="$1" o
  if [[ "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    for o in ${a//./ }; do [[ "$o" == 0* && "$o" != 0 ]] || (( 10#o > 255 )) && return 1; done
    return 0
  fi
  valid_ipv6 "$a"
}
valid_tag_part() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }
valid_ss_net() { [[ "$1" == "tcp" || "$1" == "udp" || "$1" == "tcp,udp" ]]; }
ss_kind() { case "$1" in tcp|udp) printf '%s' "$1" ;; *) printf '%s' tcpudp ;; esac; }
rand_port() { printf '%s\n' "$((20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000))"; }
rand_tag() { openssl rand -hex 3; }

take_tag() {
  tag="$1-${TAGPART}"
  if list_tags | grep -qx "$tag"; then err "备注重复"; return 1; fi
}

ask_common() {
  prompt LISTEN "监听" "0.0.0.0" || return 1
  valid_listen "$LISTEN" || { err "地址无效"; return 1; }
  prompt PORT "端口" "$(rand_port)" || return 1
  valid_port "$PORT" || { err "端口无效"; return 1; }
  prompt TAGPART "备注" "$(rand_tag)" || return 1
  valid_tag_part "$TAGPART" || { err "备注无效"; return 1; }
}

save_new() {
  local tag="$1" obj="$2"
  header "确认配置"
  summary_of "$obj"
  confirm_write || { drop_cert "$tag"; PENDING_TAG=""; return 1; }
  upsert_inbound "$obj" || true
  PENDING_TAG=""
  if [[ "${MUTATE_RC:-1}" == 0 ]]; then
    okmsg "已添加 ${tag}"
    if cert_is_self "$tag"; then
      note "自签证书，客户端允许不安全 (allowInsecure=1)"
    fi
    show_links "$tag"
    pause
  else
    drop_cert "$tag"
    pause
  fi
}

form_shadowsocks() {
  local method password network="tcp,udp" tag obj
  header "Shadowsocks"
  method=$(pick_one 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-256-gcm chacha20-ietf-poly1305) || return 1
  while true; do
    ask_gen password "密码" "$(gen_ss_password "$method")" gen_ss_password "$method" || return 1
    ss_password_ok "$method" "$password" && break
    ss_pw_err "$method"
  done
  prompt network "网络" "tcp,udp" || return 1
  valid_ss_net "$network" || { err "网络无效"; return 1; }
  ask_common || return 1
  take_tag ss || return 1
  port_taken "$PORT" "" "$(ss_kind "$network")" && { err "端口占用"; return 1; }
  obj=$(build_inbound shadowsocks "$tag" "$LISTEN" "$PORT" "$method" "$password" "$network")
  save_new "$tag" "$obj"
}

split_dest() {
  local dest="$1"
  DEST_HOST="" DEST_PORT=""
  if [[ "$dest" == \[*\]:* ]]; then
    DEST_HOST="${dest%:*}"
    DEST_HOST="${DEST_HOST#[}"
    DEST_HOST="${DEST_HOST%]}"
    DEST_PORT="${dest##*:}"
  elif [[ "$dest" == *:* ]]; then
    DEST_HOST="${dest%:*}"
    DEST_PORT="${dest##*:}"
  else
    return 1
  fi
  [[ -n "$DEST_HOST" && "$DEST_PORT" =~ ^[0-9]+$ && "$DEST_PORT" -ge 1 && "$DEST_PORT" -le 65535 ]]
}

ask_reality() {
  local sni="$1" ans
  prompt dest "目标" "${sni}:443" || return 1
  split_dest "$dest" || { err "目标缺端口"; return 1; }
  apply_keys() {
    priv=$(gen_reality_keys) || return 1
    sid=$(gen_short_id)
  }
  apply_keys || { err "密钥失败，需已安装 sing-box"; return 1; }
  while true; do
    uin "  ${CYN}➜${RST} 密钥 ${DIM}[回车接受 / g 重新生成 / q 返回]${RST} ${ACC}›${RST} "
    ans=$(readin)
    is_q "$ans" && return 1
    is_g "$ans" || return 0
    apply_keys || { err "生成失败"; continue; }
  done
}

ask_path() {
  prompt path "路径" "/" || return 1
  [[ "$path" == /* ]] || { err "路径必须以 / 开头"; return 1; }
}

form_vless() {
  local kinds=(tcp-reality ws-tls) kind uuid sni tag obj
  local dest="" priv="" sid="" path="/" host=""
  header "VLESS"
  choose "1:TCP + REALITY" "2:WebSocket + TLS" || return 1
  kind="${kinds[$((CHOOSE - 1))]}"
  ask_gen uuid "UUID" "$(gen_uuid)" gen_uuid || return 1
  prompt sni "SNI" "www.amd.com" || return 1
  case "$kind" in
    tcp-reality) ask_reality "$sni" || return 1 ;;
    ws-tls)
      ask_path || return 1
      prompt host "Host" "$sni" || return 1
      [[ "$host" == "-" ]] && host=""
      ;;
  esac
  ask_common || return 1
  take_tag vless || return 1
  port_taken "$PORT" "" tcp && { err "端口占用"; return 1; }
  if [[ "$kind" != "tcp-reality" ]]; then
    PENDING_TAG="$tag"
    ask_cert "$tag" "$sni" || { PENDING_TAG=""; return 1; }
  fi
  case "$kind" in
    tcp-reality) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "$sni" "$DEST_HOST" "$DEST_PORT" "$priv" "$sid") ;;
    ws-tls) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "$sni" "$path" "$host") ;;
  esac
  save_new "$tag" "$obj"
}

form_hysteria() {
  local auth sni obfs up down tag obj
  header "Hysteria2"
  ask_gen auth "认证" "$(gen_uuid)" gen_uuid || return 1
  prompt sni "SNI" "www.amd.com" || return 1
  prompt up "上传 (Mbps)" "100" || return 1
  up=$(parse_mbps "$up") || { err "带宽无效"; return 1; }
  prompt down "下载 (Mbps)" "100" || return 1
  down=$(parse_mbps "$down") || { err "带宽无效"; return 1; }
  ask_common || return 1
  take_tag hy2 || return 1
  port_taken "$PORT" "" udp && { err "端口占用"; return 1; }
  PENDING_TAG="$tag"
  ask_cert "$tag" "$sni" || { PENDING_TAG=""; return 1; }
  obfs=$(gen_obfs)
  obj=$(build_inbound hysteria2 "$tag" "$LISTEN" "$PORT" "$auth" "$sni" "$obfs" "$up" "$down")
  save_new "$tag" "$obj"
}

pick_inbound() {
  local tags=() t i=1 ans
  mapfile -t tags < <(list_tags)
  ((${#tags[@]})) || { warn "当前没有任何入站节点"; return 1; }
  header "选择入站节点"
  for t in "${tags[@]}"; do
    local meta
    meta=$(jq -r --arg t "$t" '.inbounds[]|select(.tag==$t)|"\(.type)  \(.listen):\(.listen_port)"' "$CFG")
    ui "    ${ACC}${BOLD}[$(pad "$i" 2)]${RST}  $(pad "$t" 22)  ${DIM}${meta}${RST}"
    i=$((i + 1))
  done
  ui ""
  while true; do
    uin "  ${CYN}➜${RST} 请选择节点编号 ${DIM}(q 返回)${RST} ${ACC}›${RST} "
    ans=$(readin)
    is_q "$ans" && return 1
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#tags[@]} )); then
      PICKED="${tags[$((ans - 1))]}"
      return 0
    fi
    err "无效"
  done
}

page_add() {
  header "添加入站"
  choose "1:Shadowsocks" "2:VLESS" "3:Hysteria2" || return 0
  case "$CHOOSE" in
    1) form_shadowsocks ;;
    2) form_vless ;;
    3) form_hysteria ;;
  esac || pause
}

commit_edit() {
  local tag="$1" new="$2" tmp="" bak_crt="" bak_key=""
  header "修改配置确认"
  summary_of "$new"
  confirm_write || return 0
  if [[ -n "${REISSUE_SNI:-}" ]]; then
    tmp=$(mktemp -d)
    make_cert_files "$tmp" "$REISSUE_SNI" || { rm -rf "$tmp"; err "证书失败"; return 0; }
    [[ -f "${CFG_DIR}/certs/${tag}.crt" ]] && bak_crt=$(mktemp) && cp -a "${CFG_DIR}/certs/${tag}.crt" "$bak_crt"
    [[ -f "${CFG_DIR}/certs/${tag}.key" ]] && bak_key=$(mktemp) && cp -a "${CFG_DIR}/certs/${tag}.key" "$bak_key"
    install_cert_pair "${CFG_DIR}/certs/${tag}.crt" "${CFG_DIR}/certs/${tag}.key" "$tmp/c" "$tmp/k"
    mark_self_signed "$tag"
  fi
  upsert_inbound "$new" "$tag" || true
  if [[ "${MUTATE_RC:-1}" == 0 ]]; then
    okmsg "已更新 ${tag}"
    show_links "$tag"
  else
    if [[ -n "$bak_crt" ]]; then
      cp -a "$bak_crt" "${CFG_DIR}/certs/${tag}.crt"
      cp -a "$bak_key" "${CFG_DIR}/certs/${tag}.key"
    fi
    err "未写入"
  fi
  rm -f "$bak_crt" "$bak_key"
  if [[ -n "$tmp" ]]; then rm -rf "$tmp"; fi
}

page_edit() {
  pick_inbound || return 0
  local tag="$PICKED" obj proto value pkind priv sid path method sec label oldnet port opts=()
  while true; do
    REISSUE_SNI=""
    obj=$(inbound_json "$tag")
    proto=$(j '.type')
    method=$(j '.transport.type // "tcp"')
    sec=$(inbound_sec)
    header "修改 ${tag}"
    summary_of "$obj"
    ui ""
    case "$proto" in
      shadowsocks) opts=(监听 端口 密码 网络) ;;
      hysteria2) opts=(监听 端口 认证 SNI 混淆 上传 下载) ;;
      vless)
        opts=(监听 端口 UUID SNI)
        [[ "$sec" == "reality" ]] && opts+=(密钥)
        has_path "$method" && opts+=(主机 路径)
        ;;
      *) err "未知协议"; pause; return 0 ;;
    esac
    label=$(pick_one "${opts[@]}") || return 0
    case "$label" in
      监听)
        prompt value "监听" "$(j '.listen')" || continue
        valid_listen "$value" || { err "地址无效"; pause; continue; }
        obj=$(jq --arg v "$value" '.listen=$v' <<<"$obj") ;;
      端口)
        prompt value "端口" "$(j '.listen_port')" || continue
        valid_port "$value" || { err "端口无效"; pause; continue; }
        pkind="tcp"
        if [[ "$proto" == "hysteria2" ]]; then pkind="udp"
        elif [[ "$proto" == "shadowsocks" ]]; then pkind=$(ss_kind "$(net_label)")
        fi
        if [[ "$value" != "$(j '.listen_port')" ]] && port_taken "$value" "$tag" "$pkind"; then err "端口占用"; pause; continue; fi
        obj=$(jq --argjson v "$value" '.listen_port=$v' <<<"$obj") ;;
      密码)
        local sm
        sm=$(j '.method')
        ask_gen value "密码" "$(j '.password')" gen_ss_password "$sm" || continue
        if ! ss_password_ok "$sm" "$value"; then ss_pw_err "$sm"; pause; continue; fi
        obj=$(jq --arg v "$value" '.password=$v' <<<"$obj") ;;
      UUID)
        ask_gen value "UUID" "$(j '.users[0].uuid')" gen_uuid || continue
        obj=$(jq --arg v "$value" '.users[0].uuid=$v' <<<"$obj") ;;
      认证)
        ask_gen value "认证" "$(j '.users[0].password')" gen_uuid || continue
        obj=$(jq --arg v "$value" '.users[0].password=$v' <<<"$obj") ;;
      网络)
        oldnet=$(net_label)
        port=$(j '.listen_port')
        prompt value "网络" "$oldnet" || continue
        valid_ss_net "$value" || { err "网络无效"; pause; continue; }
        for side in tcp udp; do
          [[ "$value" == *"$side"* ]] || continue
          if port_in_cfg "$port" "$tag" "$side"; then err "端口占用"; pause; continue 2; fi
          if [[ "$oldnet" != *"$side"* ]] && port_taken "$port" "$tag" "$side"; then err "端口占用"; pause; continue 2; fi
        done
        if [[ "$value" == "tcp,udp" ]]; then
          obj=$(jq 'del(.network)' <<<"$obj")
        else
          obj=$(jq --arg v "$value" '.network=$v' <<<"$obj")
        fi ;;
      SNI)
        prompt value "SNI" "$(j '.tls.server_name')" || continue
        if [[ "$sec" == "reality" ]]; then
          local tport
          tport=$(j '.tls.reality.handshake.server_port // 443')
          [[ "$tport" =~ ^[0-9]+$ ]] || tport=443
          obj=$(jq --arg v "$value" --argjson p "$tport" \
            '.tls.server_name=$v | .tls.reality.handshake.server=$v | .tls.reality.handshake.server_port=$p' <<<"$obj")
        else
          obj=$(jq --arg v "$value" '.tls.server_name=$v' <<<"$obj")
          if cert_is_self "$tag"; then REISSUE_SNI="$value"; else note "已有证书未更换，SNI 须与证书一致"; fi
        fi ;;
      密钥)
        priv=$(gen_reality_keys) || { err "生成失败"; pause; continue; }
        sid=$(gen_short_id)
        obj=$(jq --arg priv "$priv" --arg sid "$sid" \
          '.tls.reality.private_key=$priv | .tls.reality.short_id=[$sid]' <<<"$obj") ;;
      混淆)
        ask_gen value "混淆" "$(j '.obfs.password')" gen_obfs || continue
        [[ ${#value} -ge 4 ]] || { err "混淆过短"; pause; continue; }
        obj=$(jq --arg v "$value" '.obfs.type="salamander" | .obfs.password=$v' <<<"$obj") ;;
      路径)
        path=$(j '.transport.path // "/"')
        prompt value "路径" "$path" || continue
        [[ "$value" == /* ]] || { err "路径必须以 / 开头"; pause; continue; }
        obj=$(jq --arg v "$value" '.transport.path=$v' <<<"$obj") ;;
      主机)
        prompt value "Host" "$(j '(.transport.headers.Host // empty) | if type=="array" then .[0] else . end')" || continue
        [[ "$value" == "-" ]] && value=""
        if [[ -n "$value" ]]; then
          obj=$(jq --arg v "$value" '.transport.headers.Host=$v' <<<"$obj")
        else
          obj=$(jq 'del(.transport.headers)' <<<"$obj")
        fi ;;
      上传|下载)
        local field=up_mbps
        [[ "$label" == "下载" ]] && field=down_mbps
        prompt value "${label} (Mbps)" "$(j ".$field")" || continue
        value=$(parse_mbps "$value") || { err "带宽无效"; pause; continue; }
        obj=$(jq --argjson v "$value" --arg f "$field" '.[$f]=$v' <<<"$obj") ;;
    esac
    commit_edit "$tag" "$obj"
    pause
  done
}

show_links() {
  local tag="$1" host link proto up down
  share_load
  if ((${#SHARE_LINES[@]} == 0)); then
    err "没有可用的公网地址"
    return 0
  fi
  ui "  ${CYN}┌── 节点分享链接 [${tag}] ──────────────────────────${RST}"
  [[ "$SHARE_VIA" == "egress" ]] && note "通过出口探测获取公网 IP"
  proto=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag==$t) | .type' "$CFG" 2>/dev/null || true)
  if [[ "$proto" == "hysteria2" ]]; then
    up=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag==$t) | .up_mbps // empty' "$CFG")
    down=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag==$t) | .down_mbps // empty' "$CFG")
    if [[ -n "$up" || -n "$down" ]]; then
      note "Brutal 上限 上传 ${up:-不限} / 下载 ${down:-不限} mbps。链接不含带宽，客户端没填时走 BBR。"
    fi
  fi
  for host in "${SHARE_LINES[@]}"; do
    link=$(share_link_of "$tag" "$host") || { err "链接失败"; continue; }
    if [[ "$host" == \[* ]]; then
      ui "  ${BORD}│${RST} $(pad "IPv6" 8) ${link}"
    else
      ui "  ${BORD}│${RST} $(pad "IPv4" 8) ${link}"
    fi
  done
  ui "  ${CYN}└──────────────────────────────────────────────────${RST}"
}

page_share() {
  pick_inbound || return 0
  header "$PICKED"
  show_links "$PICKED"
  pause
}

page_delete() {
  pick_inbound || return 0
  header "删除入站: ${PICKED}"
  summary_of "$(inbound_json "$PICKED")"
  confirm "确认删除?" || { cancelled; pause; return 0; }
  remove_inbound "$PICKED" || true
  if [[ "${MUTATE_RC:-1}" == 0 ]]; then
    okmsg "已删除 ${PICKED}"
  else
    pause
  fi
}

page_logs() {
  header "服务实时日志"
  [[ -f "$LOG_FILE" ]] || { warn "无日志"; pause; return 0; }
  note "正在查看实时日志，按 Ctrl+C 返回"
  ui ""
  local old_trap pid
  old_trap=$(trap -p INT || true)
  set +e
  tail -n 40 -f "$LOG_FILE" >&4 &
  pid=$!
  stop_tail() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  trap stop_tail INT
  wait "$pid" 2>/dev/null || true
  stop_tail
  trap - INT
  [[ -n "$old_trap" ]] && eval "$old_trap"
  set -e
  note "日志查看已停止"
}

fetch_ver() {
  latest_version || { err "获取版本失败"; return 1; }
}

page_install() {
  local ver act="start" fail="已安装，未启动"
  header "安装 Sing-box 内核"
  if svc installed; then
    warn "当前已安装 $(current_version)"
    confirm "是否覆盖重新安装?" || { cancelled; pause; return 0; }
  else
    confirm "是否安装最新版本内核?" || { cancelled; pause; return 0; }
  fi
  ver=$(fetch_ver) || { pause; return 0; }
  download_install "$ver" || { pause; return 0; }
  svc running && { act="restart"; fail="已安装，未重启"; }
  svc_wait "$act" || { warn "$fail"; return 0; }
  okmsg "已安装 v${ver}"
}

page_upgrade() {
  local cur new was=0
  header "升级 Sing-box 内核"
  svc installed || { warn "未安装"; pause; return 0; }
  cur=$(current_version)
  new=$(fetch_ver) || { pause; return 0; }
  kv "当前版本" "v${cur#v}"
  kv "最新版本" "v${new#v}"
  ui ""
  if [[ "v${cur#v}" == "v${new#v}" ]]; then
    note "当前已是最新版本"
    confirm "是否重新安装当前版本?" || { cancelled; pause; return 0; }
  else
    confirm "确认升级到 v${new}?" || { cancelled; pause; return 0; }
  fi
  svc running && was=1
  download_install "$new" || { pause; return 0; }
  if (( was == 0 )); then okmsg "已升级到 v${new}"; return 0; fi
  svc_wait restart || { err "重启失败"; return 0; }
  okmsg "已升级到 v${new}"
}

page_start() {
  header "启动 Sing-box 服务"
  svc installed || { warn "内核未安装"; pause; return 0; }
  assert_runtime_user || { pause; return 0; }
  if svc running; then sticky "服务已在运行中"; return 0; fi
  svc_wait start || { err "启动失败"; return 0; }
  okmsg "已启动"
}

page_stop() {
  header "停止 Sing-box 服务"
  svc installed || { warn "内核未安装"; pause; return 0; }
  confirm "确认停止服务?" || { cancelled; pause; return 0; }
  if svc stop; then okmsg "已停止"; else err "停止失败"; fi
}

remove_singbox_account() {
  id -u sing-box >/dev/null 2>&1 || return 0
  if singbox_is_root_account; then warn "sing-box 是 root，未删除"; return 0; fi
  if [[ -f /etc/alpine-release ]] && command -v deluser >/dev/null 2>&1; then
    deluser sing-box >/dev/null 2>&1 || true
    delgroup sing-box >/dev/null 2>&1 || true
  else
    userdel sing-box >/dev/null 2>&1 || true
    if getent group sing-box >/dev/null 2>&1; then
      groupdel sing-box >/dev/null 2>&1 || true
    fi
  fi
  if id -u sing-box >/dev/null 2>&1; then warn "用户占用，未删除"; fi
}

page_uninstall() {
  header "卸载 Sing-box 内核"
  note "彻底删除程序文件、配置文件、数据资源、系统日志及运行用户。"
  confirm "确认卸载?" || { cancelled; pause; return 0; }
  svc stop >/dev/null 2>&1 || true
  svc disable >/dev/null 2>&1 || true
  pkill -x sing-box >/dev/null 2>&1 || true
  pkill -f 'supervise-daemon sing-box' >/dev/null 2>&1 || true
  local files=("$BIN" "$SYSTEMD_UNIT" "$OPENRC_INIT" "$LOGROTATE" /usr/bin/sing-box /lib/systemd/system/sing-box.service /usr/lib/systemd/system/sing-box.service /run/sing-box.pid /var/run/sing-box.pid)
  local dirs=("$CFG_DIR" "$LOG_DIR" "$STATE_DIR" /etc/sing-box /run/sing-box /var/run/sing-box /var/lib/sing-box-panel) f left=""
  rm -f "${files[@]}"
  rm -rf "${dirs[@]}"
  if [[ "$INIT_KIND" == "systemd" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
  fi
  remove_singbox_account
  for f in "${files[@]}" "${dirs[@]}"; do
    if [[ -e "$f" || -L "$f" ]]; then left="文件"; fi
  done
  id -u sing-box >/dev/null 2>&1 && left="${left:+$left、}用户"
  getent group sing-box >/dev/null 2>&1 && left="${left:+$left、}用户组"
  if [[ -n "$left" ]]; then err "未删干净: ${left}"; return 0; fi
  okmsg "已卸载"
}

status_word() {
  if ! svc installed; then printf '%s○ 未安装%s' "$YEL" "$RST"; return; fi
  if svc running; then printf '%s● 运行中%s' "$GRN" "$RST"; else printf '%s● 已停止%s' "$RED" "$RST"; fi
}

main_menu() {
  local ver count init_name
  ver=$(current_version)
  [[ -n "$ver" ]] && ver="v${ver#v}" || ver="未安装"
  count=$(inbound_count)
  init_name="systemd"
  [[ "$INIT_KIND" == "openrc" ]] && init_name="OpenRC"
  cls
  ui " ${ACC}┌──${RST} ${BOLD}❖ SING-BOX 管理面板${RST} ${BORD}──────────────────────────────────${RST}"
  ui " ${BORD}│${RST}  内核: ${CYN}${BOLD}${ver}${RST}   服务: $(status_word) ${DIM}(${init_name})${RST}   入站: ${ACC}${BOLD}${count}${RST} ${DIM}个${RST}"
  ui " ${BORD}└──────────────────────────────────────────────────────${RST}"
  if [[ -n "${NOTICE:-}" ]]; then
    ui "  ${NOTICE}"
    NOTICE=""
  fi
  ui " ${ACC}╭──${RST} ${BOLD}核心与系统服务${RST} ${BORD}────────────────────────────────────${RST}"
  menu_row 1 安装内核 2 升级内核
  menu_row 3 启动服务 4 停止服务
  menu_row 5 查看日志 6 卸载内核
  ui " ${ACC}├──${RST} ${BOLD}节点与入站管理${RST} ${BORD}────────────────────────────────────${RST}"
  menu_row 7 添加入站 8 修改入站
  menu_row 9 分享链接 10 删除入站
  ui " ${ACC}╰──────────────────────────────────────────────────────${RST}"
  ui ""
  uin "  ${CYN}➜${RST} 请输入编号 ${DIM}(q 退出)${RST} ${ACC}›${RST} "
}

dispatch() {
  case "$1" in
    1) page_install ;; 2) page_upgrade ;; 3) page_start ;; 4) page_stop ;;
    5) page_logs ;; 6) page_uninstall ;; 7) page_add ;; 8) page_edit ;;
    9) page_share ;; 10) page_delete ;; *) err "无效"; pause ;;
  esac
}

main() {
  need_root
  init_ui
  detect_init || { err "只支持 systemd 与 OpenRC"; exit 1; }
  secure_state || true
  trap '[[ -n "${PENDING_TAG:-}" ]] && drop_cert "$PENDING_TAG"; exit 130' INT TERM HUP
  while true; do
    main_menu
    local ans
    IFS= read -r ans || { note "再见"; exit 0; }
    ans="${ans//$'\r'/}"
    if is_q "$ans"; then
      note "再见"
      exit 0
    fi
    dispatch "$ans"
  done
}

if [[ "${SINGBOX_SH_LIB:-}" != "1" ]]; then
  main "$@"
fi
