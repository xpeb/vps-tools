#!/usr/bin/env bash
# xray.sh — SSH 终端管理面板
# https://xtls.github.io
# Debian/Ubuntu (systemd)、Alpine (OpenRC)
# 入站: Shadowsocks、VLESS、Hysteria2。Xray 始终以 xray:xray 运行。
set -euo pipefail

XRAY_PREFIX="${XRAY_PREFIX:-}"
BIN="${XRAY_PREFIX}/usr/local/bin/xray"
CFG_DIR="${XRAY_PREFIX}/usr/local/etc/xray"
CFG="${CFG_DIR}/config.json"
DAT_PATH="${XRAY_PREFIX}/usr/local/share/xray"
LOG_DIR="${XRAY_PREFIX}/var/log/xray"
LOG_FILE="${LOG_DIR}/error.log"
ACCESS_LOG="${LOG_DIR}/access.log"
STATE_DIR="${XRAY_PREFIX}/var/lib/xray-panel"
LOCK_FILE="${STATE_DIR}/mutate.lock"
SYSTEMD_UNIT="${XRAY_PREFIX}/etc/systemd/system/xray.service"
OPENRC_INIT="${XRAY_PREFIX}/etc/init.d/xray"
LOGROTATE="${XRAY_PREFIX}/etc/logrotate.d/xray"
RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

INIT_KIND=""
MACHINE=""
ACC="" GRN="" RED="" YEL="" DIM="" RST=""
CHOOSE=""
LISTEN="" PORT="" TAGPART=""
NOTICE=""

# 面板输出走 fd 4。
ui() { printf '%b\n' "$*" >&4; }
uin() { printf '%b' "$*" >&4; }
plainln() { printf '%s\n' "$*" >&4; }
notice() { NOTICE="$*"; }
hold() { ui "$1"; notice "$1"; }
err() { hold "${RED}错误${RST}  $*"; }
warn() { hold "${YEL}警告${RST}  $*"; }
note() { ui "${DIM}$*${RST}"; }
okmsg() { hold "${GRN}完成${RST}  $*"; }
cancelled() { note "已取消"; notice "${DIM}已取消${RST}"; }

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
  done
  printf '%d' "$n"
}

pad() {
  local s="$1" width="$2" w
  w=$(dw "$s")
  if (( w >= width )); then printf '%s' "$s"; else printf '%s%*s' "$s" $((width - w)) ''; fi
}

init_ui() {
  ACC="" GRN="" RED="" YEL="" DIM="" RST=""
  [[ -t 4 && "${NO_COLOR:-}" != "1" && "${TERM:-}" != "dumb" ]] || return 0
  ACC=$'\e[38;2;116;180;255m'
  GRN=$'\e[38;2;126;217;167m'
  RED=$'\e[38;2;255;107;107m'
  YEL=$'\e[38;2;240;200;120m'
  DIM=$'\e[38;2;145;155;170m'
  RST=$'\e[0m'
}

ui_tty() { [[ -t 4 && "${TERM:-}" != "dumb" && "${NO_COLOR:-}" != "1" ]]; }
cls() {
  ui_tty || return 0
  printf '\e[H\e[2J' >&4 2>/dev/null || true
}

section() { ui "${DIM}$1${RST}"; }

header() { cls; ui "${ACC}$1${RST}"; }

# 窄终端单列，宽终端两列。编号按显示宽度对齐，不用字符串长度。
menu_wide() {
  local c="${COLUMNS:-80}"
  [[ "$c" =~ ^[0-9]+$ ]] || c=80
  (( c >= 72 )) && return 0
  return 1
}

menu_row() {
  local n1="$1" l1="$2" n2="${3:-}" l2="${4:-}"
  if menu_wide && [[ -n "$n2" ]]; then
    ui "${ACC}$(pad "$n1" 2)${RST}  $(pad "$l1" 10)${ACC}$(pad "$n2" 2)${RST}  ${l2}"
  else
    ui "${ACC}$(pad "$n1" 2)${RST}  ${l1}"
    if [[ -n "$n2" ]]; then
      ui "${ACC}$(pad "$n2" 2)${RST}  ${l2}"
    fi
  fi
}

pause() { uin "${DIM}回车返回${RST} "; readin >/dev/null || true; }

choose() {
  local opt key ans
  for opt in "$@"; do
    ui "${ACC}$(pad "${opt%%:*}" 2)${RST}  ${opt#*:}"
  done
  while true; do
    uin "${DIM}q 返回${RST} ${GRN}>${RST} "
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
  if [[ -n "$def" ]]; then uin "${GRN}${label}${RST} ${DIM}[${def}] q 返回${RST} ${GRN}>${RST} "
  else uin "${GRN}${label}${RST} ${DIM}q 返回${RST} ${GRN}>${RST} "; fi
  ans=$(readin)
  is_q "$ans" && return 1
  [[ -z "$ans" ]] && ans="$def"
  [[ -n "$ans" ]] || return 1
  printf -v "$__var" '%s' "$ans"
}

confirm() {
  local ans
  uin "${YEL}$1${RST} ${DIM}[y/N] q 返回${RST} ${GRN}>${RST} "
  ans=$(readin)
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]
}

# 0 写入；1 取消或非法（已提示）
confirm_write() {
  local ans
  uin "${DIM}回车写入，q 返回${RST} ${GRN}>${RST} "
  ans=$(readin)
  if is_q "$ans"; then cancelled; return 1; fi
  [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]] && return 0
  err "回车写入，或 q 返回"
  return 1
}

kv() {
  local left v="$2" vw
  left=$(pad "$1" 10)
  vw=$(dw "$v")
  if (( vw > 64 )); then
    ui "${left}"
    ui "${ACC}${v}${RST}"
  else
    ui "${left}${ACC}${v}${RST}"
  fi
}

# g 重新生成，回车接受，其他输入替换。
ask_gen() {
  local __var="$1" label="$2" value="$3" ans
  shift 3
  while true; do
    uin "${GRN}${label}${RST} ${DIM}[回车/g] q 返回${RST} ${GRN}>${RST} "
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
  [[ "${XRAY_SH_SKIP_ROOT:-}" == "1" || "$(id -u)" -eq 0 ]] && return 0
  plainln "必须以 root 运行。"
  exit 1
}

detect_init() {
  if [[ -f /etc/alpine-release ]] && command -v rc-service >/dev/null 2>&1; then
    INIT_KIND="openrc"
  elif command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || -f /etc/debian_version ]]; then
    INIT_KIND="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_KIND="openrc"
  elif command -v systemctl >/dev/null 2>&1; then
    INIT_KIND="systemd"
  else
    return 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    i386|i686) MACHINE="32" ;;
    amd64|x86_64) MACHINE="64" ;;
    armv5tel|armv5tejl) MACHINE="arm32-v5" ;;
    armv6l) MACHINE="arm32-v6" ;;
    armv7|armv7l|armv8l) MACHINE="arm32-v7a" ;;
    armv8|aarch64) MACHINE="arm64-v8a" ;;
    loongarch64) MACHINE="loong64" ;;
    mips) MACHINE="mips32" ;;
    mipsle) MACHINE="mips32le" ;;
    mips64) MACHINE="mips64" ;;
    mips64le) MACHINE="mips64le" ;;
    ppc64) MACHINE="ppc64" ;;
    ppc64le) MACHINE="ppc64le" ;;
    riscv64) MACHINE="riscv64" ;;
    s390x) MACHINE="s390x" ;;
    *) return 1 ;;
  esac
}

ensure_tools() {
  local missing=() bin
  for bin in curl unzip jq openssl logrotate; do
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

xray_is_root_account() {
  id -u xray >/dev/null 2>&1 && { [[ "$(id -u xray)" -eq 0 || "$(id -g xray)" -eq 0 ]]; }
}

ensure_user() {
  if id -u xray >/dev/null 2>&1; then
    xray_is_root_account && { err "xray 是 root"; return 1; }
    return 0
  fi
  if [[ "$INIT_KIND" == "systemd" ]] && command -v systemd-sysusers >/dev/null 2>&1; then
    systemd-sysusers - <<'EOF'
u xray - "Xray" /var/empty
EOF
  elif [[ -f /etc/alpine-release ]]; then
    addgroup -S xray 2>/dev/null || true
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G xray xray 2>/dev/null || true
  else
    local shell="/usr/sbin/nologin"
    [[ -x /sbin/nologin ]] && shell="/sbin/nologin"
    getent group xray >/dev/null || groupadd --system xray
    useradd --system --gid xray --home-dir /var/empty --shell "$shell" --comment "Xray" xray
  fi
  id -u xray >/dev/null 2>&1 || { err "创建用户失败"; return 1; }
  if xray_is_root_account; then err "xray 必须非 root"; return 1; fi
}

own() { chown "$@" 2>/dev/null || true; }

install_dirs() {
  install -d -m 755 -o 0 -g 0 "$(dirname "$BIN")" "$(dirname "$SYSTEMD_UNIT")" "$(dirname "$OPENRC_INIT")"
  install -d -m 750 -o 0 -g xray "$CFG_DIR"
  install -d -m 755 -o xray -g xray "$DAT_PATH"
  install -d -m 700 -o xray -g xray "$LOG_DIR"
  install -d -m 700 -o 0 -g 0 "$STATE_DIR"
  [[ -f "$CFG" ]] || write_base_config
  touch "$LOG_FILE" "$ACCESS_LOG"
  own xray:xray "$LOG_FILE" "$ACCESS_LOG"
  chmod 600 "$LOG_FILE" "$ACCESS_LOG"
  write_logrotate
}

write_logrotate() {
  install -d -m 755 -o 0 -g 0 "$(dirname "$LOGROTATE")"
  cat >"$LOGROTATE" <<EOF
${LOG_DIR}/*.log {
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
Description=Xray Service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
UMask=0077
Environment=XRAY_LOCATION_ASSET=${DAT_PATH}/
ExecStart=${BIN} run -config ${CFG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SYSTEMD_UNIT"
    systemctl daemon-reload
  else
    cat >"$OPENRC_INIT" <<EOF
#!/sbin/openrc-run
name="Xray Daemon"
description="A unified platform for anti-censorship"
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
env=\${env:-"XRAY_LOCATION_ASSET=${DAT_PATH}/"}
command="${BIN}"
command_user="xray:xray"
command_args="run -config ${CFG}"
required_files="${CFG}"
depend() { need net; want dns ntp-client; after firewall; }
checkconfig() { export \$env; su -s /bin/sh -c "\$command \$command_args -test" "\${command_user%:*}"; eend \$?; }
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
      running) systemctl is-active --quiet xray ;;
      start|restart) systemctl enable xray >/dev/null 2>&1 || true; systemctl "$act" xray ;;
      stop) timeout 20 systemctl stop xray ;;
      disable) systemctl disable xray >/dev/null 2>&1 || true; rm -f "$SYSTEMD_UNIT"; systemctl daemon-reload || true ;;
    esac
  else
    case "$act" in
      installed) [[ -x "$BIN" && -f "$OPENRC_INIT" ]] ;;
      running) rc-service xray status >/dev/null 2>&1 ;;
      start|restart) rc-update add xray default >/dev/null 2>&1 || true; rc-service xray "$act" >/dev/null 2>&1 </dev/null ;;
      stop) timeout 20 rc-service xray stop >/dev/null 2>&1 </dev/null ;;
      disable) rc-update del xray default >/dev/null 2>&1 || true; rm -f "$OPENRC_INIT" ;;
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
  [[ "$unit_user" == "xray" ]] || { err "服务用户不是 xray"; return 1; }
  local uid
  uid=$(id -u xray 2>/dev/null) || { err "没有 xray 用户"; return 1; }
  [[ "$uid" != "0" ]] || { err "xray uid 为 0"; return 1; }
}

current_version() {
  [[ -x "$BIN" ]] || return 0
  "$BIN" version 2>/dev/null | awk 'NR==1 {print $2}'
}

latest_version() {
  local tmp tag
  tmp=$(mktemp)
  curl -fsSL -H "Accept: application/vnd.github+json" -o "$tmp" "$RELEASE_API" || { rm -f "$tmp"; return 1; }
  tag=$(jq -r '.tag_name // empty' "$tmp")
  rm -f "$tmp"
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "${tag#v}"
}

mktemp_json() {
  local name="$1" f
  mkdir -p "$STATE_DIR"
  f=$(mktemp "${STATE_DIR}/${name}.XXXXXX") || return 1
  mv "$f" "${f}.json"
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
  local got=${1:-0} total=${2:-0} width=24 fill=0 pct=0 bar="" i
  [[ "$got" =~ ^[0-9]+$ ]] || got=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  if (( total > 0 )); then
    fill=$((got * width / total))
    if (( fill > width )); then fill=$width; fi
    pct=$((got * 100 / total))
    if (( pct > 100 )); then pct=100; fi
    for ((i = 0; i < width; i++)); do
      if (( i < fill )); then bar+='#'; else bar+='-'; fi
    done
    printf '[%s] %3d%%  %s/%s' "$bar" "$pct" "$(human_size "$got")" "$(human_size "$total")"
  else
    human_size "$got"
  fi
}

dl_draw() {
  printf '\r\e[K%b' "$(pad "下载" 10)${ACC}$(dl_meter "$1" "$2")${RST}" >&4
}

download_install() {
  local ver="$1" url tmp zip expect got total=0 pid size=""
  detect_arch || { err "不支持 $(uname -m)"; return 1; }
  url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-${MACHINE}.zip"
  kv "版本" "v${ver}"
  kv "架构" "linux-${MACHINE}"
  kv "文件" "Xray-linux-${MACHINE}.zip"
  tmp=$(mktemp -d)
  # RETURN 会在调用者也返回时再跑一次，第一次清掉陷阱，避免 tmp 已失效。
  trap 'rm -rf "$tmp"; trap - RETURN' RETURN
  zip="${tmp}/xray.zip"
  total=$(curl -fsSLI --retry 2 --max-time 15 "$url" 2>/dev/null | awk 'tolower($1)=="content-length:" {n=$2} END{gsub(/\r/,"",n); print n}' || true)
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  curl -fsSL --retry 3 -o "$zip" "$url" 2>/dev/null &
  pid=$!
  if ui_tty; then
    while kill -0 "$pid" 2>/dev/null; do
      size=$(wc -c <"$zip" 2>/dev/null || true)
      dl_draw "${size// /}" "$total"
      sleep 0.25
    done
    size=$(wc -c <"$zip" 2>/dev/null || true)
    dl_draw "${size// /}" "$total"
    printf '\n' >&4
  fi
  wait "$pid" || { err "下载失败"; return 1; }
  if ! ui_tty; then
    size=$(wc -c <"$zip" 2>/dev/null || true)
    kv "大小" "$(human_size "${size// /}")"
  fi
  if curl -fsSL -o "${zip}.dgst" "${url}.dgst"; then
    expect=$(awk -F'=' '/256=/ {gsub(/ /,"",$2); print tolower($2)}' "${zip}.dgst")
    got=$(sha256sum "$zip" | awk '{print $1}')
    if [[ -n "$expect" && "$expect" != "$got" ]]; then err "校验失败"; return 1; fi
    kv "校验" "通过"
  else
    warn "无校验文件"
  fi
  unzip -qo "$zip" -d "$tmp/out" || { err "解压失败"; return 1; }
  ensure_user || return 1
  install_dirs || { err "建目录失败"; return 1; }
  install -m 755 -o 0 -g 0 "${tmp}/out/xray" "$BIN" || { err "安装失败"; return 1; }
  [[ -f "${tmp}/out/geoip.dat" ]] && install -m 644 -o xray -g xray "${tmp}/out/geoip.dat" "${DAT_PATH}/geoip.dat"
  [[ -f "${tmp}/out/geosite.dat" ]] && install -m 644 -o xray -g xray "${tmp}/out/geosite.dat" "${DAT_PATH}/geosite.dat"
  write_services || { err "写服务失败"; return 1; }
  assert_runtime_user || return 1
}

write_base_config() {
  jq -n --arg err "$LOG_FILE" --arg acc "$ACCESS_LOG" \
    '{log:{access:$acc,error:$err,loglevel:"warning"},inbounds:[],outbounds:[{protocol:"freedom",tag:"direct"}]}' >"$CFG"
  own 0:xray "$CFG"
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

port_in_cfg() {
  local port="$1" except="${2:-}" kind="${3:-tcpudp}"
  cfg_ok || return 1
  jq -e --arg p "$port" --arg ex "$except" --arg kind "$kind" '
    def inet:
      if .protocol == "hysteria" then "udp"
      elif .protocol == "shadowsocks" then (.settings.network // "tcp,udp")
      else "tcp" end;
    def hit($n):
      if $kind == "tcp" then ($n == "tcp" or $n == "tcp,udp")
      elif $kind == "udp" then ($n == "udp" or $n == "tcp,udp")
      else true end;
    [.inbounds[]? | select(.tag != $ex) | select((.port|tostring) == $p) | select(hit(inet))] | any
  ' "$CFG" >/dev/null
}

port_taken() {
  local port="$1" except="${2:-}" kind="${3:-tcpudp}" flags="-lntuH"
  port_in_cfg "$port" "$except" "$kind" && return 0
  command -v ss >/dev/null 2>&1 || return 1
  case "$kind" in
    tcp) flags="-lntH" ;;
    udp) flags="-lnuH" ;;
  esac
  ss $flags 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:|\])${port}$"
}

gen_uuid() {
  if [[ -x "$BIN" ]]; then "$BIN" uuid 2>/dev/null | head -n1
  else cat /proc/sys/kernel/random/uuid; fi
}

x25519_field() { awk -F': ' -v k="$1" 'tolower($1) ~ k {print $2; exit}'; }

gen_reality_keys() {
  local out p u
  [[ -x "$BIN" ]] || return 1
  out=$("$BIN" x25519 2>/dev/null) || return 1
  p=$(x25519_field private <<<"$out")
  u=$(x25519_field 'password|public' <<<"$out")
  [[ -n "$p" && -n "$u" ]] || return 1
  printf '%s\n' "$p"
}

# 服务端 realitySettings 不写客户端 password。分享链接的 pbk 用 xray x25519 -i 从私钥推导。
reality_public() {
  local out
  [[ -n "$1" && -x "$BIN" ]] || return 1
  out=$("$BIN" x25519 -i "$1" 2>/dev/null) || return 1
  x25519_field 'password|public' <<<"$out"
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
  # IPv4 映射地址按里面的 IPv4 判断，避免把内网地址当成公网。
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

# 只有 ULA 或链路本地时，不要为了 IPv6 出口多等一次超时。
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
  # 某一族没有公网地址时单独查出口。有独享 IPv6 不能挡住共享 IPv4。
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

# https://xtls.github.io/en/config/inbounds/vless.html
# 传输用 streamSettings.method，不用旧字段 network。
build_vless() {
  local tag="$1" listen="$2" port="$3" uuid="$4" kind="$5"
  shift 5
  local flow="" sni="" dest="" priv="" sid="" path="" host="" mode="" method sec
  case "$kind" in
    raw-reality)
      flow="$1"; sni="$2"; dest="$3"; priv="$4"; sid="$5"
      method="raw"; sec="reality" ;;
    ws-tls)
      sni="$1"; path="$2"; host="$3"
      method="websocket"; sec="tls" ;;
    xhttp-tls)
      sni="$1"; path="$2"; mode="$3"
      method="xhttp"; sec="tls" ;;
    xhttp-reality)
      sni="$1"; dest="$2"; priv="$3"; sid="$4"; path="$5"; mode="$6"
      method="xhttp"; sec="reality" ;;
    *) return 1 ;;
  esac
  jq -n \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg uuid "$uuid" --arg flow "$flow" --arg sni "$sni" --arg dest "$dest" \
    --arg priv "$priv" --arg sid "$sid" --arg path "$path" --arg host "$host" \
    --arg mode "$mode" --arg method "$method" --arg sec "$sec" \
    --arg certdir "${CFG_DIR}/certs" \
    '{
      tag:$tag, listen:$listen, port:$port, protocol:"vless",
      settings:{
        users:[({id:$uuid,email:$tag}+(if $flow=="" then {} else {flow:$flow} end))],
        decryption:"none"
      },
      streamSettings:(
        {method:$method, security:$sec}
        + (if $method=="websocket" then {wsSettings:{path:$path,host:$host}} else {} end)
        + (if $method=="xhttp" then {xhttpSettings:{path:$path,mode:$mode}} else {} end)
        + (if $sec=="reality" then {realitySettings:{
            show:false, target:$dest, serverNames:[$sni], privateKey:$priv, shortIds:[$sid]
          }} else {} end)
        + (if $sec=="tls" then {tlsSettings:{
            serverName:$sni, rejectUnknownSni:true,
            alpn:(if $method=="websocket" then ["http/1.1"] else ["h2","http/1.1"] end),
            certificates:[{certificateFile:($certdir+"/"+$tag+".crt"), keyFile:($certdir+"/"+$tag+".key")}]
          }} else {} end)
      ),
      sniffing:{enabled:true,destOverride:["http","tls","quic"]}
    }'
}

build_inbound() {
  local proto="$1" tag="$2" listen="$3" port="$4"
  shift 4
  case "$proto" in
    shadowsocks)
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
        --arg method "$1" --arg password "$2" --arg network "$3" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"shadowsocks",
          settings:{method:$method,password:$password,network:$network},
          sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
      ;;
    vless) build_vless "$tag" "$listen" "$port" "$@" ;;
    hysteria2)
      jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
        --arg auth "$1" --arg sni "$2" --arg obfs "$3" --arg up "$4" --arg down "$5" \
        --arg certdir "${CFG_DIR}/certs" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"hysteria",
          settings:{version:2,users:[{auth:$auth,email:$tag}]},
          streamSettings:{
            method:"hysteria", security:"tls",
            hysteriaSettings:{version:2,auth:$auth},
            tlsSettings:{
              serverName:$sni, alpn:["h3"],
              certificates:[{certificateFile:($certdir+"/"+$tag+".crt"),keyFile:($certdir+"/"+$tag+".key")}]
            },
            finalmask:{
              udp:[{type:"salamander",settings:{password:$obfs}}],
              quicParams:{congestion:"brutal",brutalUp:$up,brutalDown:$down}
            }
          },
          sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
      ;;
    *) return 1 ;;
  esac
}

install_cert_pair() {
  local crt="$1" key="$2" src_crt="$3" src_key="$4" dir
  dir=$(dirname "$crt")
  install -d -m 750 -o 0 -g xray "$dir"
  install -m 640 -o 0 -g xray "$src_crt" "$crt"
  install -m 640 -o 0 -g xray "$src_key" "$key"
}

mark_self_signed() { printf '%s\n' self >"${CFG_DIR}/certs/${1}.self"; chmod 644 "${CFG_DIR}/certs/${1}.self"; }
cert_is_self() { [[ -f "${CFG_DIR}/certs/${1}.self" ]]; }

make_cert_files() {
  local dir="$1" cn="$2" subj
  cn="${cn//$'\n'/}"
  cn="${cn//$'\r'/}"
  cn="${cn//\//_}"
  cn="${cn//=/_}"
  cn="${cn//\"/_}"
  cn="${cn//\\/_}"
  [[ -n "$cn" ]] || return 1
  printf -v subj '/CN=%s' "$cn"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$dir/k" -out "$dir/c" -days 3650 -nodes -subj "$subj" >/dev/null 2>&1
}

ensure_self_signed() {
  local tag="$1" sni="$2" crt="${CFG_DIR}/certs/${1}.crt" key="${CFG_DIR}/certs/${1}.key" tmp rc=0
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

xray_test_file() {
  local file="$1" out rc=0
  [[ -x "$BIN" ]] || { err "未安装"; return 1; }
  if [[ "${XRAY_AS_XRAY:-1}" != "0" ]]; then
    install -d -m 750 -o 0 -g xray "$STATE_DIR"
    install -m 640 -o 0 -g xray "$file" "${STATE_DIR}/test-config.json"
    file="${STATE_DIR}/test-config.json"
    out=$(su -s /bin/sh xray -c "XRAY_LOCATION_ASSET='${DAT_PATH}/' '${BIN}' run -test -config '${file}'" 2>&1) || rc=$?
    rm -f "$file"
  else
    out=$(XRAY_LOCATION_ASSET="${DAT_PATH}/" "$BIN" run -test -config "$file" 2>&1) || rc=$?
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
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock -n 9 || { exec 9>&-; err "正在写入"; return 1; }
  if [[ -f "$CFG" ]]; then cp -a "$CFG" "$bak"; else printf '%s\n' '{}' >"$bak"; fi
  if ! xray_test_file "$newf"; then finish_mutate 1; return 0; fi
  install -m 640 -o 0 -g xray "$newf" "$CFG"
  restore_bak() { cp -a "$bak" "$CFG"; own 0:xray "$CFG"; chmod 640 "$CFG"; }
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
  proto=$(j '.protocol')
  port=$(j '.port')
  case "$proto" in
    shadowsocks)
      local method password userinfo
      method=$(j '.settings.method')
      password=$(j '.settings.password')
      userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w0 2>/dev/null || printf '%s:%s' "$method" "$password" | base64)
      printf 'ss://%s@%s:%s#%s\n' "${userinfo//$'\n'/}" "$host" "$port" "$(urlencode "$tag")"
      ;;
    vless)
      local id flow net sec sni sid pub path hosth mode q alpn
      id=$(j '.settings.users[0].id // .settings.clients[0].id')
      flow=$(j '.settings.users[0].flow // .settings.clients[0].flow // empty')
      net=$(j '.streamSettings.method // .streamSettings.network // "raw"')
      sec=$(j '.streamSettings.security // "none"')
      case "$net" in
        websocket|ws) net="ws" ;;
        raw|tcp) net="tcp" ;;
      esac
      path=$(j '.streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path // empty')
      hosth=$(j '.streamSettings.wsSettings.host // empty')
      mode=$(j '.streamSettings.xhttpSettings.mode // empty')
      q="type=${net}&security=${sec}&encryption=none&fp=chrome"
      [[ -n "$flow" ]] && q+="&flow=$(urlencode "$flow")"
      if [[ "$sec" == "reality" ]]; then
        pub=$(reality_public "$(j '.streamSettings.realitySettings.privateKey // empty')" || true)
        [[ -n "$pub" ]] || pub=$(j '.streamSettings.realitySettings.publicKey // .streamSettings.realitySettings.password // empty')
        [[ -n "$pub" && "$pub" != "null" ]] || return 1
        sni=$(j '.streamSettings.realitySettings.serverNames[0] // empty')
        sid=$(j '.streamSettings.realitySettings.shortIds[0] // empty')
        q+="&sni=$(urlencode "$sni")&pbk=$(urlencode "$pub")&sid=$(urlencode "$sid")"
      else
        sni=$(j '.streamSettings.tlsSettings.serverName // empty')
        alpn=$(j '.streamSettings.tlsSettings.alpn // [] | join(",")')
        q+="&sni=$(urlencode "$sni")"
        cert_is_self "$tag" && q+="&allowInsecure=1"
        [[ -n "$alpn" ]] && q+="&alpn=$(urlencode "$alpn")"
      fi
      [[ "$net" == "ws" || "$net" == "xhttp" ]] && q+="&path=$(urlencode "$path")"
      [[ "$net" == "ws" && -n "$hosth" ]] && q+="&host=$(urlencode "$hosth")"
      [[ "$net" == "xhttp" && -n "$mode" ]] && q+="&mode=$(urlencode "$mode")"
      printf 'vless://%s@%s:%s?%s#%s\n' "$(urlencode "$id")" "$host" "$port" "$q" "$(urlencode "$tag")"
      ;;
    hysteria)
      local auth sni obfs insecure=""
      auth=$(j '.settings.users[0].auth')
      sni=$(j '.streamSettings.tlsSettings.serverName // empty')
      obfs=$(j '.streamSettings.finalmask.udp[0].settings.password // empty')
      cert_is_self "$tag" && insecure="&insecure=1"
      printf 'hysteria2://%s@%s:%s?sni=%s%s&obfs=salamander&obfs-password=%s#%s\n' \
        "$(urlencode "$auth")" "$host" "$port" "$(urlencode "$sni")" "$insecure" "$(urlencode "$obfs")" "$(urlencode "$tag")"
      ;;
  esac
}

summary_of() {
  local obj="$1" proto port listen tag vnet vsec vflow
  proto=$(j '.protocol')
  port=$(j '.port')
  listen=$(j '.listen')
  tag=$(j '.tag')
  kv "协议" "$proto"
  kv "备注" "$tag"
  kv "监听" "${listen}:${port}"
  case "$proto" in
    shadowsocks)
      kv "加密" "$(j '.settings.method')"
      kv "网络" "$(j '.settings.network')"
      ;;
    vless)
      vnet=$(j '.streamSettings.method // .streamSettings.network // "raw"')
      vsec=$(j '.streamSettings.security')
      vflow=$(j '.settings.users[0].flow // .settings.clients[0].flow // "-"')
      [[ -z "$vflow" || "$vflow" == "null" ]] && vflow="-"
      kv "传输" "$vnet"
      kv "安全" "$vsec"
      [[ "$vflow" != "-" ]] && kv "流控" "$vflow"
      if [[ "$vsec" == "reality" ]]; then
        kv "SNI" "$(j '.streamSettings.realitySettings.serverNames[0]')"
        kv "目标" "$(j '.streamSettings.realitySettings.target')"
        kv "ShortId" "$(j '.streamSettings.realitySettings.shortIds[0]')"
      else
        kv "SNI" "$(j '.streamSettings.tlsSettings.serverName // "-"')"
      fi
      if has_path "$vnet"; then
        kv "路径" "$(j '.streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path // "/"')"
      fi
      [[ "$vnet" == "xhttp" ]] && kv "模式" "$(j '.streamSettings.xhttpSettings.mode // "auto"')"
      ;;
    hysteria)
      kv "SNI" "$(j '.streamSettings.tlsSettings.serverName')"
      kv "混淆" "salamander"
      kv "上传" "$(j '.streamSettings.finalmask.quicParams.brutalUp')"
      ;;
  esac
}

valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
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
is_ws() { [[ "$1" == ws || "$1" == websocket ]]; }
has_path() { is_ws "$1" || [[ "$1" == xhttp ]]; }
valid_listen() {
  local a="$1" o
  if [[ "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    for o in ${a//./ }; do [[ "$o" == 0* && "$o" != 0 || 10#$o -gt 255 ]] && return 1; done
    return 0
  fi
  valid_ipv6 "$a"
}
valid_tag_part() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }
valid_ss_net() { [[ "$1" == "tcp" || "$1" == "udp" || "$1" == "tcp,udp" ]]; }
ss_kind() { case "$1" in tcp|udp) printf '%s' "$1" ;; *) printf '%s' tcpudp ;; esac; }
rand_port() { printf '%s\n' "$((20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000))"; }
rand_tag() { openssl rand -hex 3 | tr -d '\n'; printf '\n'; }

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
  local tag="$1" obj="$2" rc=0
  header "确认"
  summary_of "$obj"
  confirm_write || { drop_cert "$tag"; return 1; }
  upsert_inbound "$obj" || true
  PENDING_TAG=""
  if [[ "${MUTATE_RC:-1}" == 0 ]]; then
    okmsg "已添加 ${tag}"
    if cert_is_self "$tag"; then
      note "自签证书，客户端允许不安全"
    fi
    show_links "$tag"
    pause
  else
    drop_cert "$tag"
    pause
  fi
}

form_shadowsocks() {
  local methods password network="tcp,udp" tag obj
  methods=(2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-256-gcm chacha20-poly1305)
  header "Shadowsocks"
  choose "1:${methods[0]}" "2:${methods[1]}" "3:${methods[2]}" "4:${methods[3]}" "5:${methods[4]}" || return 1
  local method="${methods[$((CHOOSE - 1))]}"
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

ask_reality() {
  local sni="$1"
  prompt dest "目标" "${sni}:443" || return 1
  [[ "$dest" == *:* ]] || { err "目标缺端口"; return 1; }
  apply_keys() {
    priv=$(gen_reality_keys) || return 1
    sid=$(gen_short_id)
  }
  apply_keys || { err "密钥失败，需已安装 xray"; return 1; }
  while true; do
    uin "${GRN}密钥${RST} ${DIM}[回车/g] q 返回${RST} ${GRN}>${RST} "
    local ans
    ans=$(readin)
    is_q "$ans" && return 1
    is_g "$ans" || return 0
    apply_keys || { err "生成失败"; continue; }
  done
}

xhttp_mode() {
  local modes=(auto packet-up stream-up stream-one)
  choose "1:${modes[0]}" "2:${modes[1]}" "3:${modes[2]}" "4:${modes[3]}" || return 1
  printf '%s' "${modes[$((CHOOSE - 1))]}"
}

ask_path() {
  prompt path "路径" "/" || return 1
  [[ "$path" == /* ]] || { err "路径必须以 / 开头"; return 1; }
}

form_vless() {
  local kind uuid sni dest="" priv="" sid="" path="/" host="" mode="auto" tag obj
  header "VLESS"
  choose "1:RAW + REALITY" "2:WebSocket + TLS" "3:XHTTP + TLS" "4:XHTTP + REALITY" || return 1
  case "$CHOOSE" in
    1) kind="raw-reality" ;;
    2) kind="ws-tls" ;;
    3) kind="xhttp-tls" ;;
    4) kind="xhttp-reality" ;;
  esac
  ask_gen uuid "UUID" "$(gen_uuid)" gen_uuid || return 1
  prompt sni "SNI" "www.amd.com" || return 1
  case "$kind" in
    raw-reality) ask_reality "$sni" || return 1 ;;
    ws-tls)
      ask_path || return 1
      prompt host "Host" "$sni" || return 1
      [[ "$host" == "-" ]] && host=""
      ;;
    xhttp-tls|xhttp-reality)
      ask_path || return 1
      mode=$(xhttp_mode) || return 1
      [[ "$kind" == "xhttp-reality" ]] && { ask_reality "$sni" || return 1; }
      ;;
  esac
  ask_common || return 1
  take_tag vless || return 1
  port_taken "$PORT" "" tcp && { err "端口占用"; return 1; }
  if [[ "$kind" == "ws-tls" || "$kind" == "xhttp-tls" ]]; then
    PENDING_TAG="$tag"
    ask_cert "$tag" "$sni" || { PENDING_TAG=""; return 1; }
  fi
  case "$kind" in
    raw-reality) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "xtls-rprx-vision" "$sni" "$dest" "$priv" "$sid") ;;
    ws-tls) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "$sni" "$path" "$host") ;;
    xhttp-tls) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "$sni" "$path" "$mode") ;;
    xhttp-reality) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "$sni" "$dest" "$priv" "$sid" "$path" "$mode") ;;
  esac
  save_new "$tag" "$obj"
}

form_hysteria() {
  local auth sni obfs up down tag obj
  header "Hysteria2"
  ask_gen auth "认证" "$(gen_uuid)" gen_uuid || return 1
  prompt sni "SNI" "www.amd.com" || return 1
  prompt up "上传" "100 mbps" || return 1
  prompt down "下载" "100 mbps" || return 1
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
  ((${#tags[@]})) || { warn "没有入站"; return 1; }
  header "选择入站"
  for t in "${tags[@]}"; do
    local meta
    meta=$(jq -r --arg t "$t" '.inbounds[]|select(.tag==$t)|"\(.protocol)  \(.listen):\(.port)"' "$CFG")
    ui "${ACC}$(pad "$i" 2)${RST}  $(pad "$t" 22)"
    ui "${DIM}${meta}${RST}"
    i=$((i + 1))
  done
  while true; do
    uin "${DIM}q 返回${RST} ${GRN}>${RST} "
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
  local tag="$1" new="$2" tmp=""
  summary_of "$new"
  confirm_write || return 0
  if [[ -n "${REISSUE_SNI:-}" ]]; then
    tmp=$(mktemp -d)
    make_cert_files "$tmp" "$REISSUE_SNI" || { rm -rf "$tmp"; err "证书失败"; return 0; }
  fi
  upsert_inbound "$new" "$tag" || true
  if [[ "${MUTATE_RC:-1}" == 0 ]]; then
    if [[ -n "$tmp" ]]; then
      install_cert_pair "${CFG_DIR}/certs/${tag}.crt" "${CFG_DIR}/certs/${tag}.key" "$tmp/c" "$tmp/k" \
        && mark_self_signed "$tag" || err "证书未更换"
    fi
    okmsg "已更新 ${tag}"
    show_links "$tag"
  else
    err "未写入"
  fi
  if [[ -n "$tmp" ]]; then rm -rf "$tmp"; fi
}

page_edit() {
  pick_inbound || return 0
  local tag="$PICKED" obj proto value pkind priv sid path method sec label oldnet port opts=() menu=() name i
  while true; do
    REISSUE_SNI=""
    obj=$(inbound_json "$tag")
    proto=$(j '.protocol')
    method=$(j '.streamSettings.method // .streamSettings.network // "raw"')
    sec=$(j '.streamSettings.security // "none"')
    header "修改 ${tag}"
    summary_of "$obj"
    case "$proto" in
      shadowsocks) opts=(监听 端口 密码 网络) ;;
      hysteria) opts=(监听 端口 认证 SNI 混淆 上传 下载) ;;
      vless)
        opts=(监听 端口 UUID SNI)
        [[ "$sec" == "reality" ]] && opts+=(密钥)
        is_ws "$method" && opts+=(主机)
        has_path "$method" && opts+=(路径)
        [[ "$method" == "xhttp" ]] && opts+=(模式)
        ;;
      *) err "未知协议"; pause; return 0 ;;
    esac
    menu=(); i=1
    for name in "${opts[@]}"; do menu+=("$i:$name"); i=$((i + 1)); done
    choose "${menu[@]}" || return 0
    label="${opts[$((CHOOSE - 1))]}"
    case "$label" in
      监听)
        prompt value "监听" "$(j '.listen')" || continue
        valid_listen "$value" || { err "地址无效"; pause; continue; }
        obj=$(jq --arg v "$value" '.listen=$v' <<<"$obj") ;;
      端口)
        prompt value "端口" "$(j '.port')" || continue
        valid_port "$value" || { err "端口无效"; pause; continue; }
        pkind="tcp"
        if [[ "$proto" == "hysteria" ]]; then pkind="udp"
        elif [[ "$proto" == "shadowsocks" ]]; then pkind=$(ss_kind "$(j '.settings.network')")
        fi
        if [[ "$value" != "$(j '.port')" ]] && port_taken "$value" "$tag" "$pkind"; then err "端口占用"; pause; continue; fi
        obj=$(jq --argjson v "$value" '.port=$v' <<<"$obj") ;;
      密码)
        local sm
        sm=$(j '.settings.method')
        ask_gen value "密码" "$(j '.settings.password')" gen_ss_password "$sm" || continue
        if ! ss_password_ok "$sm" "$value"; then ss_pw_err "$sm"; pause; continue; fi
        obj=$(jq --arg v "$value" '.settings.password=$v' <<<"$obj") ;;
      UUID)
        ask_gen value "UUID" "$(j '.settings.users[0].id')" gen_uuid || continue
        obj=$(jq --arg v "$value" '.settings.users[0].id=$v' <<<"$obj") ;;
      认证)
        ask_gen value "认证" "$(j '.settings.users[0].auth')" gen_uuid || continue
        obj=$(jq --arg v "$value" '.settings.users[0].auth=$v | .streamSettings.hysteriaSettings.auth=$v' <<<"$obj") ;;
      网络)
        oldnet=$(j '.settings.network')
        port=$(j '.port')
        prompt value "网络" "$oldnet" || continue
        valid_ss_net "$value" || { err "网络无效"; pause; continue; }
        for side in tcp udp; do
          [[ "$value" == *"$side"* ]] || continue
          if port_in_cfg "$port" "$tag" "$side"; then err "端口占用"; pause; continue 2; fi
          if [[ "$oldnet" != *"$side"* ]] && port_taken "$port" "$tag" "$side"; then err "端口占用"; pause; continue 2; fi
        done
        obj=$(jq --arg v "$value" '.settings.network=$v' <<<"$obj") ;;
      SNI)
        prompt value "SNI" "$(j '.streamSettings.realitySettings.serverNames[0] // .streamSettings.tlsSettings.serverName')" || continue
        if [[ "$sec" == "reality" ]]; then
          local dest tport
          dest=$(j '.streamSettings.realitySettings.target // empty')
          tport="${dest##*:}"
          [[ "$tport" =~ ^[0-9]+$ ]] || tport=443
          obj=$(jq --arg v "$value" --arg d "${value}:${tport}" \
            '.streamSettings.realitySettings.serverNames[0]=$v | .streamSettings.realitySettings.target=$d' <<<"$obj")
        else
          obj=$(jq --arg v "$value" '.streamSettings.tlsSettings.serverName=$v' <<<"$obj")
          if cert_is_self "$tag"; then REISSUE_SNI="$value"; else note "已有证书未更换，SNI 须与证书一致"; fi
        fi ;;
      密钥)
        priv=$(gen_reality_keys) || { err "生成失败"; pause; continue; }
        sid=$(gen_short_id)
        obj=$(jq --arg priv "$priv" --arg sid "$sid" \
          'del(.streamSettings.realitySettings.publicKey) | .streamSettings.realitySettings.privateKey=$priv | .streamSettings.realitySettings.shortIds=[$sid]' <<<"$obj") ;;
      混淆)
        ask_gen value "混淆" "$(j '.streamSettings.finalmask.udp[0].settings.password')" gen_obfs || continue
        [[ ${#value} -ge 4 ]] || { err "混淆过短"; pause; continue; }
        obj=$(jq --arg v "$value" '.streamSettings.finalmask.udp[0].settings.password=$v' <<<"$obj") ;;
      路径)
        path=$(j '.streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path // "/"')
        prompt value "路径" "$path" || continue
        [[ "$value" == /* ]] || { err "路径必须以 / 开头"; pause; continue; }
        if is_ws "$method"; then
          obj=$(jq --arg v "$value" '.streamSettings.wsSettings.path=$v' <<<"$obj")
        else
          obj=$(jq --arg v "$value" '.streamSettings.xhttpSettings.path=$v' <<<"$obj")
        fi ;;
      主机)
        prompt value "Host" "$(j '.streamSettings.wsSettings.host // empty')" || continue
        [[ "$value" == "-" ]] && value=""
        obj=$(jq --arg v "$value" '.streamSettings.wsSettings.host=$v' <<<"$obj") ;;
      上传|下载)
        local field=brutalUp
        [[ "$label" == "下载" ]] && field=brutalDown
        prompt value "$label" "$(j ".streamSettings.finalmask.quicParams.$field")" || continue
        obj=$(jq --arg v "$value" --arg f "$field" '.streamSettings.finalmask.quicParams[$f]=$v' <<<"$obj") ;;
      模式)
        value=$(xhttp_mode) || continue
        obj=$(jq --arg v "$value" '.streamSettings.xhttpSettings.mode=$v' <<<"$obj") ;;
    esac
    commit_edit "$tag" "$obj"
    pause
  done
}

show_links() {
  local tag="$1" host link
  share_load
  if ((${#SHARE_LINES[@]} == 0)); then
    err "没有可用的公网地址"
    return 0
  fi
  [[ "$SHARE_VIA" == "egress" ]] && note "出口地址"
  if jq -e --arg t "$tag" 'any(.inbounds[]?; .tag==$t and .streamSettings.security=="reality")' "$CFG" >/dev/null 2>&1; then
    note "REALITY 客户端指纹需带 X25519MLKEM768，小火箭用 Chrome140"
  fi
  for host in "${SHARE_LINES[@]}"; do
    link=$(share_link_of "$tag" "$host") || { err "链接失败"; continue; }
    plainln "$link"
  done
}

page_share() {
  pick_inbound || return 0
  header "$PICKED"
  show_links "$PICKED"
  pause
}

page_delete() {
  pick_inbound || return 0
  header "删除 ${PICKED}"
  summary_of "$(inbound_json "$PICKED")"
  confirm "删除?" || { cancelled; pause; return 0; }
  remove_inbound "$PICKED" || true
  [[ "${MUTATE_RC:-1}" == 0 ]] && okmsg "已删除 ${PICKED}"
}

page_logs() {
  header "实时日志"
  [[ -f "$LOG_FILE" ]] || { warn "无日志"; pause; return 0; }
  note "Ctrl+C 返回"
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
  note "已停止"
}

page_install() {
  local ver act="start" fail="已安装，未启动"
  header "安装内核"
  if svc installed; then
    warn "已安装 $(current_version)"
    confirm "重装?" || { cancelled; pause; return 0; }
  else
    confirm "安装最新版?" || { cancelled; pause; return 0; }
  fi
  ensure_tools || { pause; return 0; }
  ver=$(latest_version) || { err "获取版本失败"; pause; return 0; }
  download_install "$ver" || { pause; return 0; }
  svc running && { act="restart"; fail="已安装，未重启"; }
  svc_wait "$act" || { warn "$fail"; return 0; }
  okmsg "已安装 v${ver}"
}

page_upgrade() {
  local cur new was=0
  header "升级内核"
  svc installed || { warn "未安装"; pause; return 0; }
  ensure_tools || { pause; return 0; }
  cur=$(current_version)
  new=$(latest_version) || { err "获取版本失败"; pause; return 0; }
  kv "当前" "v${cur#v}"
  kv "最新" "v${new#v}"
  if [[ "v${cur#v}" == "v${new#v}" ]]; then
    note "已是最新"
    confirm "重装?" || { cancelled; pause; return 0; }
  else
    confirm "升级到 v${new}?" || { cancelled; pause; return 0; }
  fi
  svc running && was=1
  download_install "$new" || { pause; return 0; }
  if (( was == 0 )); then okmsg "已升级到 v${new}"; return 0; fi
  svc_wait restart || { err "重启失败"; return 0; }
  okmsg "已升级到 v${new}"
}

page_start() {
  header "启动服务"
  svc installed || { warn "未安装"; pause; return 0; }
  assert_runtime_user || { pause; return 0; }
  if svc running; then note "已在运行"; notice "${DIM}已在运行${RST}"; return 0; fi
  svc_wait start || { err "启动失败"; return 0; }
  okmsg "已启动"
}

page_stop() {
  header "停止服务"
  svc installed || { warn "未安装"; pause; return 0; }
  confirm "停止?" || { cancelled; pause; return 0; }
  if svc stop; then okmsg "已停止"; else err "停止失败"; fi
}

remove_xray_account() {
  id -u xray >/dev/null 2>&1 || return 0
  if xray_is_root_account; then warn "xray 是 root，未删除"; return 0; fi
  if [[ -f /etc/alpine-release ]] && command -v deluser >/dev/null 2>&1; then
    deluser xray >/dev/null 2>&1 || true
    delgroup xray >/dev/null 2>&1 || true
  else
    userdel xray >/dev/null 2>&1 || true
    if getent group xray >/dev/null 2>&1; then
      groupdel xray >/dev/null 2>&1 || true
    fi
  fi
  if id -u xray >/dev/null 2>&1; then warn "用户占用，未删除"; fi
}

page_uninstall() {
  header "卸载内核"
  note "删除程序、配置、日志和用户。"
  confirm "卸载?" || { cancelled; pause; return 0; }
  svc stop >/dev/null 2>&1 || true
  svc disable >/dev/null 2>&1 || true
  pkill -x xray >/dev/null 2>&1 || true
  pkill -f 'supervise-daemon xray' >/dev/null 2>&1 || true
  local files=("$BIN" "$SYSTEMD_UNIT" "$OPENRC_INIT" "$LOGROTATE" /run/xray.pid /var/run/xray.pid)
  local dirs=("$CFG_DIR" "$LOG_DIR" "$STATE_DIR" /run/xray /var/run/xray) f left=""
  rm -f "${files[@]}"
  rm -rf "${dirs[@]}"
  if [[ "$INIT_KIND" == "systemd" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed xray >/dev/null 2>&1 || true
  fi
  remove_xray_account
  for f in "${files[@]}" "${dirs[@]}"; do
    if [[ -e "$f" ]]; then left="文件"; fi
  done
  id -u xray >/dev/null 2>&1 && left="${left:+$left、}用户"
  getent group xray >/dev/null 2>&1 && left="${left:+$left、}用户组"
  if [[ -n "$left" ]]; then err "未删干净: ${left}"; return 0; fi
  okmsg "已卸载"
}

status_word() {
  if ! svc installed; then printf '%s未安装%s' "$YEL" "$RST"; return; fi
  if svc running; then printf '%s运行中%s' "$GRN" "$RST"; else printf '%s未运行%s' "$YEL" "$RST"; fi
}

main_menu() {
  local ver count
  ver=$(current_version)
  [[ -n "$ver" ]] && ver="v${ver#v}" || ver="-"
  count=$(inbound_count)
  cls
  ui "${ACC}XRAY${RST}  ${ver}  $(status_word)  入站 ${count}"
  if [[ -n "${NOTICE:-}" ]]; then ui "$NOTICE"; NOTICE=""; fi
  section "内核"
  menu_row 1 安装内核 2 升级内核
  menu_row 3 启动服务 4 停止服务
  menu_row 5 查看日志 6 卸载内核
  section "入站"
  menu_row 7 添加入站 8 修改入站
  menu_row 9 分享链接 10 删除入站
  uin "${DIM}编号，q 退出${RST} ${GRN}>${RST} "
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
  { true >&4; } 2>/dev/null || exec 4>&1
  init_ui
  detect_init || { err "只支持 systemd 与 OpenRC"; exit 1; }
  mkdir -p "$STATE_DIR" 2>/dev/null || true
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

if [[ "${XRAY_SH_LIB:-}" != "1" ]]; then
  main "$@"
fi
