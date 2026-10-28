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
RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

INIT_KIND=""
MACHINE=""
ACC="" GRN="" RED="" YEL="" DIM="" RST=""
CHOOSE=""
LISTEN="" PORT="" TAGPART=""

# ---------------------------------------------------------------------------
# UI。面板输出走 fd 4。
# ---------------------------------------------------------------------------
ui() { printf '%b\n' "$*" >&4; }
uin() { printf '%b' "$*" >&4; }
plainln() { printf '%s\n' "$*" >&4; }
blank() { printf '\n' >&4; }
err() { ui "${RED}错误${RST}  $*"; }
warn() { ui "${YEL}警告${RST}  $*"; }
note() { ui "${DIM}$*${RST}"; }
okmsg() { ui "${GRN}完成${RST}  $*"; }

readin() {
  local _v=""
  IFS= read -r _v || _v="q"
  printf '%s' "${_v//$'\r'/}"
}

dw() {
  local s="$1" rest="$1" n=0 c b
  while [[ -n "$rest" ]]; do
    c="${rest:0:1}"
    rest="${rest:1}"
    printf -v b '%d' "'$c"
    if (( b == 27 )); then
      while [[ -n "$rest" && "${rest:0:1}" != "m" ]]; do rest="${rest:1}"; done
      rest="${rest:1}"
      continue
    fi
    if (( b < 128 || (b >= 194 && b <= 223) )); then n=$((n + 1))
    else n=$((n + 2))
    fi
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

cls() {
  [[ -t 4 && "${TERM:-}" != "dumb" && "${NO_COLOR:-}" != "1" ]] || return 0
  printf '\e[H\e[2J' >&4 2>/dev/null || true
}

section() { ui "${DIM}$1${RST}"; }

header() {
  cls
  blank
  ui "${ACC}$1${RST}"
  ui "${DIM}----------------------${RST}"
  blank
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
  if menu_wide && [[ -n "$n2" ]]; then
    ui "${ACC}$(pad "$n1" 2)${RST}  $(pad "$l1" 10)${ACC}$(pad "$n2" 2)${RST}  ${l2}"
  else
    ui "${ACC}$(pad "$n1" 2)${RST}  ${l1}"
    if [[ -n "$n2" ]]; then
      ui "${ACC}$(pad "$n2" 2)${RST}  ${l2}"
    fi
  fi
}

pause() { blank; uin "${DIM}回车${RST} "; readin >/dev/null || true; }

choose() {
  local opt key ans
  blank
  for opt in "$@"; do
    ui "${ACC}$(pad "${opt%%:*}" 2)${RST}  ${opt#*:}"
  done
  blank
  while true; do
    uin "${GRN}>${RST} "
    ans=$(readin)
    [[ "$ans" == "q" || "$ans" == "Q" ]] && { CHOOSE=""; return 1; }
    for opt in "$@"; do
      key="${opt%%:*}"
      if [[ "$ans" == "$key" ]]; then CHOOSE="$key"; return 0; fi
    done
    err "无效"
  done
}

prompt() {
  local __var="$1" label="$2" def="${3:-}" hint="${4:-}" ans
  while true; do
    [[ -n "$hint" ]] && note "$hint"
    if [[ -n "$def" ]]; then uin "${GRN}${label}${RST} ${DIM}[${def}]${RST} "
    else uin "${GRN}${label}${RST} "; fi
    ans=$(readin) || return 1
    [[ "$ans" == "q" || "$ans" == "Q" ]] && return 1
    [[ -z "$ans" ]] && ans="$def"
    [[ -n "$ans" ]] || return 1
    printf -v "$__var" '%s' "$ans"
    return 0
  done
}

confirm() {
  local ans
  uin "${YEL}$1${RST} ${DIM}[y/N]${RST} "
  ans=$(readin)
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]
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

# ask_gen VAR label value command [args...]
# g 调用 command 重新生成，回车接受，其他输入替换。
ask_gen() {
  local __var="$1" label="$2" value="$3" ans
  shift 3
  while true; do
    uin "${GRN}${label}${RST} ${DIM}[回车/g]${RST} "
    ans=$(readin)
    [[ "$ans" == "q" || "$ans" == "Q" ]] && return 1
    if [[ "$ans" == "g" || "$ans" == "G" ]]; then
      value=$("$@")
      continue
    fi
    [[ -n "$ans" ]] && value="$ans"
    [[ -n "$value" ]] || { err "空值"; continue; }
    printf -v "$__var" '%s' "$value"
    return 0
  done
}

# ---------------------------------------------------------------------------
# 系统
# ---------------------------------------------------------------------------
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
  for bin in curl unzip jq openssl; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
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
  if xray_is_root_account; then
    err "xray 必须非 root"
    return 1
  fi
  return 0
}

own() { chown "$@" 2>/dev/null || true; }

install_dirs() {
  install -d -m 755 -o 0 -g 0 "$(dirname "$BIN")" "$(dirname "$SYSTEMD_UNIT")" "$(dirname "$OPENRC_INIT")"
  install -d -m 750 -o 0 -g xray "$CFG_DIR"
  install -d -m 755 -o xray -g xray "$DAT_PATH"
  install -d -m 700 -o xray -g xray "$LOG_DIR"
  install -d -m 700 -o 0 -g 0 "$STATE_DIR"
  if [[ ! -f "$CFG" ]]; then
    install -m 640 -o 0 -g xray /dev/null "$CFG"
    write_base_config
  fi
  touch "$LOG_FILE" "$ACCESS_LOG"
  own xray:xray "$LOG_FILE" "$ACCESS_LOG"
  chmod 600 "$LOG_FILE" "$ACCESS_LOG"
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
      start) systemctl enable xray >/dev/null 2>&1 || true; systemctl start xray ;;
      stop) timeout 20 systemctl stop xray ;;
      restart) systemctl enable xray >/dev/null 2>&1 || true; systemctl restart xray ;;
      disable) systemctl disable xray >/dev/null 2>&1 || true; rm -f "$SYSTEMD_UNIT"; systemctl daemon-reload || true ;;
    esac
  else
    case "$act" in
      installed) [[ -x "$BIN" && -f "$OPENRC_INIT" ]] ;;
      running) rc-service xray status >/dev/null 2>&1 ;;
      start) rc-update add xray default >/dev/null 2>&1 || true; rc-service xray start >/dev/null 2>&1 </dev/null ;;
      stop) timeout 20 rc-service xray stop >/dev/null 2>&1 </dev/null ;;
      restart) rc-update add xray default >/dev/null 2>&1 || true; rc-service xray restart >/dev/null 2>&1 </dev/null ;;
      disable) rc-update del xray default >/dev/null 2>&1 || true; rm -f "$OPENRC_INIT" ;;
    esac
  fi
  } </dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
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

download_install() {
  local ver="$1" url tmp zip expect got
  detect_arch || { err "不支持 $(uname -m)"; return 1; }
  url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-${MACHINE}.zip"
  tmp=$(mktemp -d)
  zip="${tmp}/xray.zip"
  note "下载 v${ver}"
  if ! curl -fL --retry 3 -o "$zip" "$url"; then
    rm -rf "$tmp"; err "下载失败"; return 1
  fi
  if curl -fsSL -o "${zip}.dgst" "${url}.dgst"; then
    expect=$(awk -F'=' '/256=/ {gsub(/ /,"",$2); print tolower($2)}' "${zip}.dgst")
    got=$(sha256sum "$zip" | awk '{print $1}')
    if [[ -n "$expect" && "$expect" != "$got" ]]; then
      rm -rf "$tmp"; err "校验失败"; return 1
    fi
  else
    warn "无校验文件"
  fi
  unzip -qo "$zip" -d "$tmp/out" || { rm -rf "$tmp"; err "解压失败"; return 1; }
  ensure_user || { rm -rf "$tmp"; return 1; }
  install_dirs || { rm -rf "$tmp"; err "建目录失败"; return 1; }
  if ! install -m 755 -o 0 -g 0 "${tmp}/out/xray" "$BIN"; then
    rm -rf "$tmp"; err "安装失败"; return 1
  fi
  [[ -f "${tmp}/out/geoip.dat" ]] && install -m 644 -o xray -g xray "${tmp}/out/geoip.dat" "${DAT_PATH}/geoip.dat"
  [[ -f "${tmp}/out/geosite.dat" ]] && install -m 644 -o xray -g xray "${tmp}/out/geosite.dat" "${DAT_PATH}/geosite.dat"
  write_services || { rm -rf "$tmp"; err "写服务失败"; return 1; }
  assert_runtime_user || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
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

port_taken() {
  local port="$1" except="${2:-}" kind="${3:-tcpudp}" flags="-lntuH" net
  case "$kind" in tcp) net='["tcp"]' ;; udp) net='["udp"]' ;; *) net='["tcp","udp","tcp,udp"]' ;; esac
  if cfg_ok && jq -e --arg p "$port" --arg ex "$except" --argjson nets "$net" \
    '[.inbounds[]? | select(.tag != $ex) | select((.port|tostring) == $p)
      | select((.settings.network // "tcp,udp") as $n | $nets | index($n))] | any' "$CFG" >/dev/null; then
    return 0
  fi
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

gen_reality_keys() {
  local out
  [[ -x "$BIN" ]] || return 1
  out=$("$BIN" x25519 2>/dev/null) || return 1
  awk -F': ' 'tolower($1) ~ /private/ {p=$2} tolower($1) ~ /password|public/ {u=$2} END {if (p=="" || u=="") exit 1; print p; print u}' <<<"$out"
}

gen_short_id() { openssl rand -hex 8; }

gen_ss_password() {
  local n=32
  case "$1" in
    2022-blake3-aes-128-gcm) n=16 ;;
    2022-*) n=32 ;;
    *) n=24 ;;
  esac
  openssl rand -base64 "$n" | tr -d '\n'
  printf '\n'
}

urlencode() { jq -nr --arg s "$1" '$s|@uri'; }

# 去掉掩码后的公网地址。内网、链路本地和回环不参与分享。
share_keep() {
  local ip="${1%%/*}"
  ip="${ip//$'\r'/}"
  [[ -n "$ip" ]] || return 1
  case "$ip" in
    10.*|127.*|192.168.*|169.254.*|0.*|fe80:*|fc*:*|fd*:*|::1) return 1 ;;
  esac
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 1
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 1
  printf '%s\n' "$ip"
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

share_load() {
  local raw out trace addr
  SHARE_SEEN="|"
  SHARE_LINES=()
  SHARE_VIA="iface"
  if command -v ip >/dev/null 2>&1; then
    while read -r raw; do share_take "$raw"; done \
      < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}')
    while read -r raw; do share_take "$raw"; done \
      < <(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}')
  elif out=$(hostname -I 2>/dev/null); then
    for raw in $out; do share_take "$raw"; done
  fi
  # NAT 后面的机器网卡只有内网地址，改查出口的公网地址。
  if ((${#SHARE_LINES[@]} == 0)) && command -v curl >/dev/null 2>&1; then
    SHARE_VIA="egress"
    trace=$(curl -4fsS --connect-timeout 2 --max-time 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)
    addr=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -n1)
    [[ -z "$addr" ]] && addr=$(curl -4fsS --connect-timeout 2 --max-time 3 https://api.ipify.org 2>/dev/null || true)
    [[ -n "$addr" ]] && share_take "$addr"
    if [[ -z "$(ip -o -6 addr show scope global 2>/dev/null)" ]]; then
      :
    else
    trace=$(curl -6fsS --connect-timeout 2 --max-time 3 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null || true)
    addr=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -n1)
    [[ -z "$addr" ]] && addr=$(curl -6fsS --connect-timeout 2 --max-time 3 https://api6.ipify.org 2>/dev/null || true)
    fi
    [[ -n "$addr" ]] && share_take "$addr"
  fi
}

# https://xtls.github.io/en/config/inbounds/vless.html
# 传输用 streamSettings.method，不用旧字段 network。
build_vless() {
  local tag="$1" listen="$2" port="$3" uuid="$4" kind="$5"
  shift 5
  local flow="" sni="" dest="" priv="" sid="" pub="" path="" host="" mode="" method sec
  case "$kind" in
    raw-reality)
      flow="$1"; sni="$2"; dest="$3"; priv="$4"; sid="$5"; pub="$6"
      method="raw"; sec="reality" ;;
    ws-tls)
      sni="$1"; path="$2"; host="$3"
      method="websocket"; sec="tls" ;;
    xhttp-tls)
      sni="$1"; path="$2"; mode="$3"
      method="xhttp"; sec="tls" ;;
    xhttp-reality)
      sni="$1"; dest="$2"; priv="$3"; sid="$4"; pub="$5"; path="$6"; mode="$7"
      method="xhttp"; sec="reality" ;;
    *) return 1 ;;
  esac
  jq -n \
    --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg uuid "$uuid" --arg flow "$flow" --arg sni "$sni" --arg dest "$dest" \
    --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --arg path "$path" --arg host "$host" \
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
        + (if $sec=="reality" then {realitySettings:(
            {show:false, target:$dest, serverNames:[$sni], privateKey:$priv, shortIds:[$sid]}
            + (if $pub=="" then {} else {publicKey:$pub} end)
          )} else {} end)
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

ensure_self_signed() {
  local tag="$1" sni="$2" dir="${CFG_DIR}/certs" crt="${CFG_DIR}/certs/${1}.crt" key="${CFG_DIR}/certs/${1}.key" tmp
  install -d -m 750 -o 0 -g xray "$dir"
  [[ -f "$crt" && -f "$key" ]] && return 0
  tmp=$(mktemp -d)
  local rc=0 cn="$sni"
  cn=${cn//\//_}
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$tmp/k" -out "$tmp/c" -days 3650 -nodes -subj "/CN=${cn}" >/dev/null 2>&1 \
    && install_cert_pair "$crt" "$key" "$tmp/c" "$tmp/k" && mark_self_signed "$tag" || rc=$?
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

upsert_inbound() {
  local obj="$1" old="${2:-}" tmp
  tmp=$(mktemp_json upsert)
  cfg_ok || write_base_config
  jq --argjson obj "$obj" --arg old "$old" \
    '.inbounds |= (map(select(.tag != $old and .tag != $obj.tag)) + [$obj])' "$CFG" >"$tmp"
  mutate "$tmp" || true
  rm -f "$tmp"
  return 0
}

remove_inbound() {
  local tag="$1" tmp
  tmp=$(mktemp_json remove)
  jq --arg t "$tag" '.inbounds |= map(select(.tag != $t))' "$CFG" >"$tmp"
  mutate "$tmp" || true
  rm -f "$tmp"
  [[ "${MUTATE_RC:-1}" == 0 ]] && drop_cert "$tag"
  return 0
}

share_link_of() {
  local tag="$1" host obj proto port
  host="${2:-}"
  [[ -n "$host" ]] || return 1
  obj=$(inbound_json "$tag") || return 1
  proto=$(jq -r '.protocol' <<<"$obj")
  port=$(jq -r '.port' <<<"$obj")
  case "$proto" in
    shadowsocks)
      local method password userinfo
      method=$(jq -r '.settings.method' <<<"$obj")
      password=$(jq -r '.settings.password' <<<"$obj")
      userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w0 2>/dev/null || printf '%s:%s' "$method" "$password" | base64)
      printf 'ss://%s@%s:%s#%s\n' "${userinfo//$'\n'/}" "$host" "$port" "$(urlencode "$tag")"
      ;;
    vless)
      local id flow net sec sni sid pub path hosth mode q alpn j
      j() { jq -r "$1" <<<"$obj"; }
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
      pub=$(j '.streamSettings.realitySettings.publicKey // empty')
      q="type=${net}&security=${sec}&encryption=none&fp=chrome"
      [[ -n "$flow" ]] && q+="&flow=$(urlencode "$flow")"
      if [[ "$sec" == "reality" ]]; then
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
      printf 'vless://%s@%s:%s?%s#%s\n' "$id" "$host" "$port" "$q" "$(urlencode "$tag")"
      ;;
    hysteria)
      local auth sni obfs
      local insecure="" j
      j() { jq -r "$1" <<<"$obj"; }
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
  local j
  j() { jq -r "$1" <<<"$obj"; }
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
      if [[ "$vnet" == "ws" || "$vnet" == "websocket" || "$vnet" == "xhttp" ]]; then
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

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_listen() {
  local a="$1" o
  [[ "$a" == "::" ]] && return 0
  if [[ "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    IFS=. read -r o o o o <<<"$a"
    for o in ${a//./ }; do [[ "$o" == 0* && "$o" != 0 || 10#$o -gt 255 ]] && return 1; done
    return 0
  fi
  [[ "$a" =~ ^[0-9A-Fa-f:]+$ && "$a" == *:* && "$a" != *::*::* ]]
}
valid_tag_part() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }
rand_port() { printf '%s\n' "$((20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000))"; }
rand_tag() { openssl rand -hex 3 | tr -d '\n'; printf '\n'; }

ask_common() {
  prompt LISTEN "监听" "0.0.0.0" || return 1
  valid_listen "$LISTEN" || { err "地址无效"; return 1; }
  prompt PORT "端口" "$(rand_port)" || return 1
  valid_port "$PORT" || { err "端口无效"; return 1; }
  prompt TAGPART "备注" "$(rand_tag)" || return 1
  valid_tag_part "$TAGPART" || { err "备注无效"; return 1; }
}

save_new() {
  local tag="$1" obj="$2" ans
  header "确认"
  summary_of "$obj"
  blank
  uin "${DIM}回车写入，q 取消${RST} ${GRN}>${RST} "
  ans=$(readin) || return 1
  if [[ "$ans" == "q" || "$ans" == "Q" ]]; then note "已取消"; drop_cert "$tag"; return 1; fi
  if [[ -n "$ans" && "$ans" != "y" && "$ans" != "Y" ]]; then
    err "回车写入，或 q 取消"
    drop_cert "$tag"
    return 1
  fi
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
  local method password network="tcp,udp" tag obj pkind="tcpudp"
  header "Shadowsocks"
  choose \
    "1:2022-blake3-aes-128-gcm" \
    "2:2022-blake3-aes-256-gcm" \
    "3:2022-blake3-chacha20-poly1305" \
    "4:aes-256-gcm" \
    "5:chacha20-poly1305" || return 1
  case "$CHOOSE" in
    1) method="2022-blake3-aes-128-gcm" ;;
    2) method="2022-blake3-aes-256-gcm" ;;
    3) method="2022-blake3-chacha20-poly1305" ;;
    4) method="aes-256-gcm" ;;
    5) method="chacha20-poly1305" ;;
  esac
  while true; do
    ask_gen password "密码" "$(gen_ss_password "$method")" gen_ss_password "$method" || return 1
    [[ ${#password} -ge 8 ]] && break
    err "密码过短"
  done
  prompt network "网络" "tcp,udp" || return 1
  [[ "$network" == "tcp" || "$network" == "udp" || "$network" == "tcp,udp" ]] || { err "网络无效"; return 1; }
  ask_common || return 1
  tag="ss-${TAGPART}"
  list_tags | grep -qx "$tag" && { err "备注重复"; return 1; }
  [[ "$network" == "tcp" ]] && pkind="tcp"
  [[ "$network" == "udp" ]] && pkind="udp"
  port_taken "$PORT" "" "$pkind" && { err "端口占用"; return 1; }
  obj=$(build_inbound shadowsocks "$tag" "$LISTEN" "$PORT" "$method" "$password" "$network")
  save_new "$tag" "$obj"
}

ask_reality() {
  local sni="$1" keys
  prompt dest "目标" "${sni}:443" || return 1
  [[ "$dest" == *:* ]] || { err "目标缺端口"; return 1; }
  apply_keys() {
    keys=$(gen_reality_keys) || return 1
    priv=$(sed -n '1p' <<<"$keys")
    pub=$(sed -n '2p' <<<"$keys")
    sid=$(gen_short_id)
  }
  apply_keys || { err "密钥失败，需已安装 xray"; return 1; }
  while true; do
    uin "${GRN}密钥${RST} ${DIM}[回车/g]${RST} "
    local ans
    ans=$(readin)
    [[ "$ans" == "q" || "$ans" == "Q" ]] && return 1
    [[ "$ans" != "g" && "$ans" != "G" ]] && return 0
    apply_keys || { err "生成失败"; continue; }
  done
}

ask_path() {
  prompt path "路径" "/" || return 1
  [[ "$path" == /* ]] || { err "路径必须以 / 开头"; return 1; }
}

form_vless() {
  local kind uuid sni dest="" priv="" pub="" sid="" path="/" host="" mode="auto" tag obj
  header "VLESS"
  choose "1:RAW + REALITY" "2:WebSocket + TLS" "3:XHTTP + TLS" "4:XHTTP + REALITY" || return 1
  case "$CHOOSE" in
    1) kind="raw-reality" ;;
    2) kind="ws-tls" ;;
    3) kind="xhttp-tls" ;;
    4) kind="xhttp-reality" ;;
  esac
  ask_gen uuid "UUID" "$(gen_uuid)" gen_uuid || return 1
  prompt sni "SNI" "www.microsoft.com" || return 1
  case "$kind" in
    raw-reality) ask_reality "$sni" || return 1 ;;
    ws-tls)
      ask_path "以 / 开头；Early Data 可写 /path?ed=2560" || return 1
      prompt host "Host" "$sni" || return 1
      [[ "$host" == "-" ]] && host=""
      ;;
    xhttp-tls|xhttp-reality)
      ask_path "以 / 开头。服务端用它关联上下行" || return 1
      choose "1:auto" "2:packet-up" "3:stream-up" "4:stream-one" || return 1
      case "$CHOOSE" in
        1) mode="auto" ;; 2) mode="packet-up" ;; 3) mode="stream-up" ;; 4) mode="stream-one" ;;
      esac
      [[ "$kind" == "xhttp-reality" ]] && { ask_reality "$sni" || return 1; }
      ;;
  esac
  ask_common || return 1
  tag="vless-${TAGPART}"
  list_tags | grep -qx "$tag" && { err "备注重复"; return 1; }
  port_taken "$PORT" "" tcp && { err "端口占用"; return 1; }
  if [[ "$kind" == "ws-tls" || "$kind" == "xhttp-tls" ]]; then
    PENDING_TAG="$tag"
    ask_cert "$tag" "$sni" || { PENDING_TAG=""; return 1; }
  fi
  case "$kind" in
    raw-reality) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "xtls-rprx-vision" "$sni" "$dest" "$priv" "$sid" "$pub") ;;
    ws-tls) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "$sni" "$path" "$host") ;;
    xhttp-tls) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "$sni" "$path" "$mode") ;;
    xhttp-reality) obj=$(build_inbound vless "$tag" "$LISTEN" "$PORT" "$uuid" "$kind" "$sni" "$dest" "$priv" "$sid" "$pub" "$path" "$mode") ;;
  esac
  save_new "$tag" "$obj"
}

form_hysteria() {
  local auth sni obfs up down tag obj
  header "Hysteria2"
  ask_gen auth "认证" "$(gen_uuid)" gen_uuid || return 1
  prompt sni "SNI" "www.microsoft.com" || return 1
  prompt up "上传" "100 mbps" || return 1
  prompt down "下载" "100 mbps" || return 1
  ask_common || return 1
  tag="hy2-${TAGPART}"
  list_tags | grep -qx "$tag" && { err "备注重复"; return 1; }
  port_taken "$PORT" "" udp && { err "端口占用"; return 1; }
  PENDING_TAG="$tag"
  ask_cert "$tag" "$sni" || { PENDING_TAG=""; return 1; }
  obfs=$(openssl rand -base64 18 | tr -d '\n')
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
  blank
  while true; do
    uin "${GRN}>${RST} "
    ans=$(readin)
    [[ "$ans" == "q" || "$ans" == "Q" ]] && return 1
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

page_edit() {
  pick_inbound || return 0
  local tag="$PICKED" obj proto listen port pkind="tcp" new vsec keys priv pub sid
  obj=$(inbound_json "$tag")
  proto=$(jq -r '.protocol' <<<"$obj")
  header "修改 ${tag}"
  summary_of "$obj"
  blank
  listen=$(jq -r '.listen' <<<"$obj")
  port=$(jq -r '.port' <<<"$obj")
  prompt listen "监听" "$listen" || { note "已取消"; pause; return 0; }
  valid_listen "$listen" || { err "地址无效"; pause; return 0; }
  prompt port "端口" "$port" || { note "已取消"; pause; return 0; }
  valid_port "$port" || { err "端口无效"; pause; return 0; }
  [[ "$proto" == "hysteria" ]] && pkind="udp"
  [[ "$proto" == "shadowsocks" ]] && pkind="tcpudp"
  if [[ "$port" != "$(jq -r '.port' <<<"$obj")" ]] && port_taken "$port" "$tag" "$pkind"; then
    err "端口占用"; pause; return 0
  fi
  new=$(jq --arg l "$listen" --argjson p "$port" '.listen=$l | .port=$p' <<<"$obj")
  case "$proto" in
    vless)
      vsec=$(jq -r '.streamSettings.security // "none"' <<<"$new")
      if [[ "$vsec" == "reality" ]] && confirm "新密钥?"; then
        keys=$(gen_reality_keys) || { err "生成失败"; pause; return 0; }
        priv=$(sed -n '1p' <<<"$keys"); pub=$(sed -n '2p' <<<"$keys"); sid=$(gen_short_id)
        new=$(jq --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" \
          '.streamSettings.realitySettings.privateKey=$priv | .streamSettings.realitySettings.publicKey=$pub | .streamSettings.realitySettings.shortIds=[$sid]' <<<"$new")
      elif [[ "$vsec" != "reality" ]] && confirm "新 UUID?"; then
        new=$(jq --arg id "$(gen_uuid)" '.settings.users[0].id=$id' <<<"$new")
      fi
      ;;
    shadowsocks)
      confirm "新密码?" && new=$(jq --arg pw "$(gen_ss_password "$(jq -r '.settings.method' <<<"$new")")" '.settings.password=$pw' <<<"$new")
      ;;
    hysteria)
      if confirm "新认证?"; then
        new=$(jq --arg a "$(gen_uuid)" --arg o "$(openssl rand -base64 18 | tr -d '\n')" \
          '.settings.users[0].auth=$a | .streamSettings.hysteriaSettings.auth=$a | .streamSettings.finalmask.udp[0].settings.password=$o' <<<"$new")
      fi
      ;;
  esac
  blank
  summary_of "$new"
  blank
  uin "${DIM}回车写入，q 取消${RST} ${GRN}>${RST} "
  local ans
  ans=$(readin) || return 0
  [[ "$ans" == "q" || "$ans" == "Q" ]] && { note "已取消"; pause; return 0; }
  [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]] || { err "回车写入，或 q 取消"; pause; return 0; }
  upsert_inbound "$new" "$tag" || true
  if [[ "${MUTATE_RC:-1}" == 0 ]]; then okmsg "已更新 ${tag}"; show_links "$tag"; else err "未写入"; fi
  pause
}

show_links() {
  local tag="$1" host link
  share_load
  if ((${#SHARE_LINES[@]} == 0)); then
    err "没有可用的公网地址"
    return 0
  fi
  [[ "$SHARE_VIA" == "egress" ]] && note "出口地址"
  for host in "${SHARE_LINES[@]}"; do
    blank
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
  blank
  confirm "删除?" || { note "已取消"; pause; return 0; }
  remove_inbound "$PICKED" || true
  [[ "${MUTATE_RC:-1}" == 0 ]] && okmsg "已删除 ${PICKED}"
}

page_logs() {
  header "实时日志"
  [[ -f "$LOG_FILE" ]] || { warn "无日志"; pause; return 0; }
  note "Ctrl+C 返回"
  blank
  local old_trap pid
  old_trap=$(trap -p INT || true)
  set +e
  tail -n 40 -f "$LOG_FILE" >&4 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' INT
  wait "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - INT
  [[ -n "$old_trap" ]] && eval "$old_trap"
  set -e
  note "已停止"
}

page_install() {
  local ver
  header "安装内核"
  if svc installed; then
    warn "已安装 $(current_version)"
    confirm "重装?" || { note "已取消"; pause; return 0; }
  else
    confirm "安装最新版?" || { note "已取消"; pause; return 0; }
  fi
  ensure_tools || { pause; return 0; }
  ver=$(latest_version) || { err "获取版本失败"; pause; return 0; }
  note "v${ver}"
  download_install "$ver" || { pause; return 0; }
  if svc running; then
    if svc restart; then okmsg "已安装 v${ver}"
    else warn "已安装，未重启"; fi
  elif svc start; then okmsg "已安装 v${ver}"
  else warn "已安装，未启动"; fi
}

page_upgrade() {
  local cur new
  header "升级内核"
  svc installed || { warn "未安装"; pause; return 0; }
  ensure_tools || { pause; return 0; }
  cur=$(current_version)
  new=$(latest_version) || { err "获取版本失败"; pause; return 0; }
  kv "当前" "v${cur#v}"
  kv "最新" "v${new#v}"
  blank
  if [[ "v${cur#v}" == "v${new#v}" ]]; then
    note "已是最新"
    confirm "重装?" || { note "已取消"; pause; return 0; }
  else
    confirm "升级到 v${new}?" || { note "已取消"; pause; return 0; }
  fi
  download_install "$new" || { pause; return 0; }
  if svc restart; then okmsg "已升级到 v${new}"; else err "重启失败"; fi
}

page_start() {
  header "启动服务"
  svc installed || { warn "未安装"; pause; return 0; }
  assert_runtime_user || { pause; return 0; }
  svc running && { note "已在运行"; return 0; }
  if svc start && svc running; then okmsg "已启动"; else err "启动失败"; fi
}

page_stop() {
  header "停止服务"
  svc installed || { warn "未安装"; pause; return 0; }
  confirm "停止?" || { note "已取消"; pause; return 0; }
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
  if id -u xray >/dev/null 2>&1; then
    warn "用户占用，未删除"
  fi
  return 0
}

page_uninstall() {
  header "卸载内核"
  warn "删除程序、配置、日志和用户。"
  blank
  confirm "卸载?" || { note "已取消"; pause; return 0; }
  svc stop >/dev/null 2>&1 || true
  svc disable >/dev/null 2>&1 || true
  pkill -x xray >/dev/null 2>&1 || true
  pkill -f 'supervise-daemon xray' >/dev/null 2>&1 || true
  rm -f "$BIN" "$SYSTEMD_UNIT" "$OPENRC_INIT"
  rm -rf "$CFG_DIR" "$LOG_DIR" "$STATE_DIR" /run/xray /var/run/xray
  if [[ "$INIT_KIND" == "systemd" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed xray >/dev/null 2>&1 || true
  fi
  remove_xray_account
  local left=""
  [[ -e "$BIN" || -e "$SYSTEMD_UNIT" || -e "$OPENRC_INIT" || -d "$CFG_DIR" || -d "$LOG_DIR" ]] && left="文件"
  id -u xray >/dev/null 2>&1 && left="${left:+$left、}用户"
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
  blank
  ui "${ACC}XRAY${RST}  ${ver}  $(status_word)  入站 ${count}"
  blank
  section "内核"
  menu_row 1 安装内核 2 升级内核
  menu_row 3 启动服务 4 停止服务
  menu_row 5 查看日志 6 卸载内核
  blank
  section "入站"
  menu_row 7 添加入站 8 修改入站
  menu_row 9 分享链接 10 删除入站
  blank
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
    IFS= read -r ans || exit 0
    ans="${ans//$'\r'/}"
    if [[ "$ans" == "q" || "$ans" == "Q" ]]; then
      blank
      note "再见"
      exit 0
    fi
    dispatch "$ans"
  done
}

if [[ "${XRAY_SH_LIB:-}" != "1" ]]; then
  main "$@"
fi
