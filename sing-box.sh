#!/usr/bin/env bash
# sing-box 管理面板（Debian / Ubuntu / Alpine）。需要 >= 1.14.0。用法: bash sing-box.sh
# Alpine 先 apk add bash。下载可设 GH_PROXY；校验只走 api.github.com，或设 SINGBOX_SHA256

shopt -s nullglob

BASE=/etc/sing-box
INB_DIR=$BASE/inbounds
CERT_DIR=$BASE/certs
ACME_DIR=$BASE/acme
CONF=$BASE/config.json
BIN=/usr/local/bin/sing-box
SVC=sing-box
SVC_USER=sing-box
UNIT=/etc/systemd/system/sing-box.service
LOG=/var/log/sing-box.log
MIN_VER=1.14.0
GH_PROXY="${GH_PROXY:-}"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'

# NOTICE 留到下一屏；HOLD=1 时先按回车再离开结果页
NOTICE=""; HOLD=0

ok()   { local m="  ${G}✓${N} $*"; echo "$m"; NOTICE+="$m"$'\n'; }
warn() { local m="  ${Y}!${N} $*"; echo "$m"; NOTICE+="$m"$'\n'; }
tip()  { local m="  ${D}$*${N}";   echo "$m"; NOTICE+="$m"$'\n'; }
err()  { echo "  ${R}✗${N} $*"; HOLD=1; }
soft() { echo "  ${R}✗${N} $*"; }
info() { echo "  ${D}$*${N}"; }
line() { echo "$RULE"; }
kv()   { echo "  ${D}$1${N}  $2"; }
# clear 会查 terminfo，SSH 上常多一次往返；整页一次写出
CLS=$'\033[H\033[2J'
RULE="  ${D}──────────────────────────────────${N}"
MENU=$'  1   安装内核      6   查看日志
  2   升级内核      7   添加入站
  3   启动内核      8   修改入站
  4   停止内核      9   分享入站
  5   卸载内核      10  删除入站
'
paint() { printf '%s%s' "$CLS" "$1"; }
page() {
  local b=$'\n'"  ${B}sing-box${N} ${D}›${N} ${B}$1${N}"$'\n'"$RULE"$'\n\n'
  if [ -n "$NOTICE" ]; then b+="$NOTICE$RULE"$'\n\n'; NOTICE=""; fi
  paint "$b"
}

[ "$(id -u)" -eq 0 ] || { echo "请使用 root 运行"; exit 1; }
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

detect_system() {
  if [ -f /etc/alpine-release ]; then
    OS=alpine; INIT=openrc; UNIT=/etc/init.d/$SVC
    [ -e /run/openrc/softlevel ] || [ -e /var/run/openrc/softlevel ] \
      || { echo "OpenRC 未运行"; exit 1; }
    command -v rc-service >/dev/null 2>&1 || { echo "需要 OpenRC（apk add openrc）"; exit 1; }
  elif [ -f /etc/debian_version ] || command -v apt-get >/dev/null 2>&1; then
    OS=debian; INIT=systemd
    command -v systemctl >/dev/null 2>&1 || { echo "需要 systemd"; exit 1; }
  else
    echo "仅支持 Debian / Ubuntu / Alpine Linux"; exit 1
  fi
}
detect_system

# svc active|start|stop|restart|enable|disable|logs N|-f
SVC_ST=""
svc() {
  case $1 in
    active)
      if [ "$INIT" = systemd ]; then systemctl is-active --quiet "$SVC"
      else rc-service "$SVC" status >/dev/null 2>&1; fi;;
    start|stop)
      SVC_ST=""
      if [ "$INIT" = systemd ]; then systemctl "$1" "$SVC"
      else rc-service "$SVC" "$1" >/dev/null 2>&1; fi;;
    restart)
      SVC_ST=""
      if [ "$INIT" = systemd ]; then systemctl restart "$SVC"
      elif svc active; then rc-service "$SVC" restart >/dev/null 2>&1
      else rc-service "$SVC" start >/dev/null 2>&1; fi;;
    enable)
      if [ "$INIT" = systemd ]; then systemctl enable "$SVC" >/dev/null 2>&1
      else rc-update add "$SVC" default >/dev/null 2>&1 || warn "开机自启失败：rc-update add $SVC default"; fi;;
    disable)
      if [ "$INIT" = systemd ]; then systemctl disable "$SVC" >/dev/null 2>&1
      else rc-update del "$SVC" default >/dev/null 2>&1; fi;;
    logs)
      if [ "$INIT" = systemd ]; then
        if [ "$2" = -f ]; then journalctl -u "$SVC" -f -o cat
        else journalctl -u "$SVC" -n "$2" --no-pager -o cat; fi
      else
        touch "$LOG" 2>/dev/null
        if [ "$2" = -f ]; then tail -n 20 -f "$LOG"; else tail -n "$2" "$LOG"; fi
      fi;;
  esac
}

svc_user() {
  local u
  if [ -f "$UNIT" ]; then
    if [ "$INIT" = systemd ]; then u=$(sed -n 's/^User=//p' "$UNIT" | head -n1)
    else u=$(sed -n 's/^[[:space:]]*command_user="\{0,1\}\([^":[:space:]]*\).*/\1/p' "$UNIT" | head -n1); fi
  fi
  printf '%s' "${u:-root}"
}

ensure_dirs() { mkdir -p "$INB_DIR" "$CERT_DIR" "$ACME_DIR" /var/lib/sing-box; }

# 配置归 root，服务组只读；只有 ACME 目录给服务写
secure_tree() {
  local u f
  [ -d "$BASE" ] || return 0
  ensure_dirs
  chown -R root:root "$BASE" 2>/dev/null || true
  find "$BASE" -type d -exec chmod 700 {} + 2>/dev/null || true
  find "$BASE" -type f -exec chmod 600 {} + 2>/dev/null || true
  u=$(svc_user)
  if [ "$u" != root ] && id "$u" >/dev/null 2>&1; then
    chgrp "$u" "$BASE" "$INB_DIR" "$CERT_DIR" 2>/dev/null || true
    chmod 750 "$BASE" "$INB_DIR" "$CERT_DIR" 2>/dev/null || true
    find "$INB_DIR" "$CERT_DIR" -type f -exec chgrp "$u" {} + -exec chmod 640 {} + 2>/dev/null || true
    for f in "$CONF" "$CONF.new"; do
      [ -f "$f" ] || continue
      chgrp "$u" "$f" 2>/dev/null || true
      chmod 640 "$f" 2>/dev/null || true
    done
    chown -R "$u:$u" "$ACME_DIR" 2>/dev/null || true
    chmod 700 "$ACME_DIR" 2>/dev/null || true
    if [ -d "$BASE/.bak" ]; then chown -R root:root "$BASE/.bak"; chmod -R go-rwx "$BASE/.bak"; fi
    if [ -d "$BASE/.certbak" ]; then chown -R root:root "$BASE/.certbak"; chmod -R go-rwx "$BASE/.certbak"; fi
  fi
}

ask() { local _ans; read -rp "  $2${3:+ [$3]}: " _ans; printf -v "$1" '%s' "${_ans:-$3}"; }

confirm() {
  local _a _d=${2:-n} _h="y/N"; [ "$_d" = y ] && _h="Y/n"
  read -rp "  $1 [$_h]: " _a; _a=${_a:-$_d}; [[ $_a =~ ^[Yy] ]]
}

sel() { # 回车返回 1
  local _c _l=${3:-返回}
  while true; do
    read -rp "  请选择 [回车$_l]: " _c
    case $_c in
      "") return 1;;
      *[!0-9]*) ;;
      *)   if [ "$_c" -ge 1 ] && [ "$_c" -le "$2" ]; then printf -v "$1" '%s' "$_c"; return 0; fi;;
    esac
  done
}

rand_str() { head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$1"; }
rand_hex() { head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
urlenc()   { SB_SECRET=$1 jq -rn 'env.SB_SECRET|@uri'; }
b64url()   { printf %s "$1" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }
bare_ip() { local ip=$1; ip=${ip#[}; ip=${ip%"]"}; printf '%s' "${ip%%%*}"; }
host_fmt() { [[ $1 == *:* ]] && echo "[$1]" || echo "$1"; }

jq_edit()  { local f=$1; shift; jq "$@" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"; }
listen_host() {
  local f=/proc/sys/net/ipv6/conf/all/disable_ipv6
  if [ -r "$f" ] && [ "$(cat "$f" 2>/dev/null)" = 0 ]; then printf '%s' '::'
  else printf '%s' '0.0.0.0'; fi
}

installed() { [ -x "$BIN" ]; }
need_core() { installed || { warn "请先安装内核"; return 1; }; }
CORE_VER=""
core_ver() {
  [ -n "$CORE_VER" ] || CORE_VER=$("$BIN" version 2>/dev/null | awk 'NR==1{print $3}')
  printf '%s' "$CORE_VER"
}
list_inb() {
  local -n _inb=$1
  _inb=("$INB_DIR"/*.json)
  [ ${#_inb[@]} -gt 0 ]
}
has_inb() { local -a _a; list_inb _a; }
inb_count() { local -a a; list_inb a; echo "${#a[@]}"; }
is_acme() { [ "$1" = acme ]; }
ver_ge() { # a >= b；同一版本号的预发布比正式版更旧
  local a=${1%%-*} b=${2%%-*} ap=0 bp=0
  [[ $1 == *-* ]] && ap=1
  [[ $2 == *-* ]] && bp=1
  if [ "$a" = "$b" ]; then [ "$ap" -le "$bp" ]; return; fi
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$b" ]
}

pname() {
  case $1 in
    socks) echo "SOCKS5";; shadowsocks) echo "Shadowsocks";; vless) echo "VLESS";;
    hysteria2) echo "Hysteria2";; anytls) echo "AnyTLS";; tuic) echo "TUIC";; snell) echo "Snell v6";;
  esac
}
tls_proto() { case $1 in vless|hysteria2|anytls|tuic) return 0;; *) return 1;; esac; }

SERVER_IP="" SERVER_IP4="" SERVER_IP6=""

norm_ip() {
  local ip=$1 left right g s="" i
  local -a lg=() rg=() out=()
  ip=$(bare_ip "$1")
  [[ $ip == *:* ]] || { printf '%s' "$ip"; return 0; }
  ip=$(printf '%s' "$ip" | tr 'A-F' 'a-f')
  if [[ $ip == *::* ]]; then
    left=${ip%%::*}; right=${ip#*::}
    [ -n "$left" ] && IFS=: read -ra lg <<< "$left"
    [ -n "$right" ] && IFS=: read -ra rg <<< "$right"
    out=("${lg[@]}")
    for ((i=${#lg[@]}+${#rg[@]}; i<8; i++)); do out+=(0); done
    out+=("${rg[@]}")
  else
    IFS=: read -ra out <<< "$ip"
  fi
  [ ${#out[@]} -eq 8 ] || { printf '%s' "$1"; return 1; }
  for g in "${out[@]}"; do
    [[ ${g:-0} =~ ^[0-9a-f]{1,4}$ ]] || { printf '%s' "$1"; return 1; }
    printf -v g '%04x' "$((16#${g:-0}))"
    s+="${s:+:}$g"
  done
  printf '%s' "$s"
}

is_public_v4() {
  local ip=$1 o
  valid_ip "$ip" || return 1
  [[ $ip == *:* ]] && return 1
  case $ip in
    10.*|127.*|192.168.*|169.254.*|0.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|255.*|192.0.2.*|198.51.100.*|203.0.113.*) return 1;;
  esac
  # CGNAT 100.64/10、基准测试 198.18/15 不当公网地址
  if [[ $ip =~ ^100\.([0-9]+)\. ]]; then
    o=$((10#${BASH_REMATCH[1]}))
    [ "$o" -ge 64 ] && [ "$o" -le 127 ] && return 1
  fi
  if [[ $ip =~ ^198\.([0-9]+)\. ]]; then
    o=$((10#${BASH_REMATCH[1]}))
    [ "$o" -ge 18 ] && [ "$o" -le 19 ] && return 1
  fi
  if [[ $ip =~ ^([0-9]+)\. ]]; then
    o=$((10#${BASH_REMATCH[1]}))
    [ "$o" -ge 224 ] && return 1
  fi
  return 0
}

is_public_v6() {
  local n
  valid_ip "$1" || return 1
  [[ $1 == *:* ]] || return 1
  n=$(norm_ip "$1") || return 1
  case $n in
    0000:0000:0000:0000:0000:0000:0000:0001|fe80:*|fc*|fd*|ff*) return 1;;
    2*|3*) return 0;;
  esac
  return 1
}

local_addrs() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -"$1" -o addr show scope global 2>/dev/null | awk '
    /temporary|deprecated|dadfailed|tentative/ { next }
    {
      for (i = 1; i <= NF; i++)
        if ($i == "inet" || $i == "inet6") { split($(i + 1), a, "/"); print a[1]; break }
    }'
}

is_public() {
  if [ "$1" = 4 ]; then is_public_v4 "$2"; else is_public_v6 "$2"; fi
}
local_public() {
  local a
  while read -r a; do
    is_public "$1" "$a" || continue
    printf '%s' "$a"; return 0
  done < <(local_addrs "$1")
  return 1
}

curl_ip() {
  local fam=$1 u r
  shift
  command -v curl >/dev/null 2>&1 || return 1
  for u in "$@"; do
    r=$(curl -"$fam" -fsS --connect-timeout 2 -m 3 "$u" 2>/dev/null | tr -d '[:space:]')
    is_public "$fam" "$r" && { printf '%s' "$r"; return 0; }
  done
  return 1
}

ip_is_ours() {
  local n want
  n=$(norm_ip "$1") || return 1
  for want in $SERVER_IP4 $SERVER_IP6 $SERVER_IP; do
    [ -n "$want" ] && [ "$(norm_ip "$want")" = "$n" ] && return 0
  done
  return 1
}

local_ips() {
  local s=""
  [ -n "$SERVER_IP4" ] && s+="$SERVER_IP4 "
  [ -n "$SERVER_IP6" ] && s+="$SERVER_IP6 "
  [ -z "$s" ] && s="$SERVER_IP "
  printf '%s' "${s% }"
}

get_ip() {
  [ -n "$SERVER_IP" ] && return 0
  local v4e="" v6e="" v4f v6f p4 p6
  v4f=$(mktemp); v6f=$(mktemp)
  curl_ip 4 https://api.ipify.org https://ipv4.icanhazip.com >"$v4f" & p4=$!
  curl_ip 6 https://api6.ipify.org https://ipv6.icanhazip.com >"$v6f" & p6=$!
  wait "$p4" || true
  wait "$p6" || true
  v4e=$(cat "$v4f"); v6e=$(cat "$v6f")
  rm -f "$v4f" "$v6f"
  # 公网 IPv4 多半在 NAT 后，探不到再看网卡，最后才用 IPv6
  if [ -n "$v4e" ]; then SERVER_IP4=$v4e; else SERVER_IP4=$(local_public 4 || true); fi
  if [ -n "$v6e" ]; then SERVER_IP6=$v6e; else SERVER_IP6=$(local_public 6 || true); fi
  if [ -n "$SERVER_IP4" ]; then SERVER_IP=$SERVER_IP4
  elif [ -n "$SERVER_IP6" ]; then SERVER_IP=$SERVER_IP6
  else
    ask SERVER_IP "无法获取公网 IP，请手动输入" ""
    SERVER_IP=$(bare_ip "$SERVER_IP")
    if [[ $SERVER_IP == *:* ]]; then SERVER_IP6=$SERVER_IP; else SERVER_IP4=$SERVER_IP; fi
  fi
}

acme_left() {
  local -a a
  list_inb a || return 1
  jq -se 'any(.[]; .cert=="acme")' "${a[@]}" >/dev/null
}
# HTTP-01 占 80；TLS-ALPN 占 443，本入站自己听 443 时可共用
acme_listen_conflict() {
  local mine=$1 f p
  local -a a
  [ "$mine" = 80 ] && return 0
  list_inb a || return 1
  for f in "${a[@]}"; do
    p=$(jq -r '.inbound.listen_port // empty' "$f" 2>/dev/null) || continue
    [ "$p" = 80 ] && return 0
    [ "$p" = 443 ] && [ "$mine" != 443 ] && return 0
  done
  return 1
}
require_acme_ports() {
  acme_listen_conflict "${TLS_PORT:-}" || return 0
  err "ACME 需要空闲的 80；443 只能由本入站占用"
  return 1
}

sys_port_used() { ss -H -ltun "sport = :$1" 2>/dev/null | grep -q .; }
inb_port_used() {
  local -a a
  list_inb a || return 1
  jq -se --argjson p "$1" 'any(.[]; .inbound.listen_port==$p)' "${a[@]}" >/dev/null 2>&1
}
port_ok() { [[ $1 =~ ^[1-9][0-9]*$ ]] && [ "$1" -le 65535 ]; }
read_port() {
  local _got
  ask _got "$2" "$3"
  port_ok "$_got" || { soft "端口须为 1-65535"; return 1; }
  printf -v "$1" '%s' "$_got"
}

rand_port() {
  local p
  while true; do
    p=$(shuf -i 10000-60000 -n 1)
    sys_port_used "$p" || inb_port_used "$p" || { echo "$p"; return; }
  done
}

ask_mbps() {
  local _v
  while true; do
    ask _v "$2" "$3"
    [[ $_v =~ ^[1-9][0-9]*$ ]] && { printf -v "$1" '%s' "$_v"; return; }
    soft "须为正整数"
  done
}

ask_port() {
  local _p _d; _d=$(rand_port)
  while true; do
    read_port _p "监听端口" "${2:-$_d}" || continue
    if [ "$_p" != "$2" ]; then
      inb_port_used "$_p" && { soft "端口已被其他入站使用"; continue; }
      sys_port_used "$_p" && { soft "端口已被系统占用"; continue; }
      if acme_left && { [ "$_p" = 80 ] || [ "$_p" = 443 ]; }; then
        soft "80/443 已留给 ACME，请换端口"
        continue
      fi
    fi
    printf -v "$1" '%s' "$_p"; return
  done
}

detect_arch() {
  case $(uname -m) in
    x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;;
    armv7l|armv7) echo armv7;; i386|i686) echo 386;; s390x) echo s390x;;
    *) return 1;;
  esac
}

REL_JSON=""
REL_VER=""
latest_version() {
  local j s
  j=$(curl -fsSL -m 15 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null) || return 1
  s=$(jq -r '.tag_name // empty' <<<"$j" | sed 's/^v//')
  [ -n "$s" ] && ver_ge "$s" "$MIN_VER" || return 1
  REL_JSON=$j; REL_VER=$s
  printf '%s' "$s"
}

VER=""
accept_version() {
  if [ -z "$VER" ]; then
    warn "无法获取最新版本信息"
    ask VER "请手动输入版本号，如 1.14.0" ""
  fi
  ver_ge "$VER" "$MIN_VER" || { err "版本需不低于 $MIN_VER"; return 1; }
}
pick_version() {
  VER=$(latest_version)
  accept_version
}

ensure_user() {
  id "$SVC_USER" >/dev/null 2>&1 && return 0
  if [ "$OS" = alpine ]; then
    addgroup -S "$SVC_USER" 2>/dev/null || true
    adduser -S -D -H -h /var/lib/sing-box -G "$SVC_USER" -s /sbin/nologin "$SVC_USER"
  else
    useradd --system --user-group --home-dir /var/lib/sing-box --shell /usr/sbin/nologin "$SVC_USER" \
      || useradd --system --user-group --home-dir /var/lib/sing-box --shell /bin/false "$SVC_USER"
  fi
  id "$SVC_USER" >/dev/null 2>&1
}

remove_user() {
  id "$SVC_USER" >/dev/null 2>&1 || return 0
  if [ "$OS" = alpine ]; then
    deluser "$SVC_USER" >/dev/null 2>&1 || warn "未能删除用户 $SVC_USER"
  else
    userdel "$SVC_USER" >/dev/null 2>&1 || warn "未能删除用户 $SVC_USER"
    groupdel "$SVC_USER" >/dev/null 2>&1 || true
  fi
}

# systemd 用 ambient 能力并去掉文件能力。OpenRC 只能给文件加能力，模式 750
grant_bind() {
  [ -e "$BIN" ] || return 0
  if id "$SVC_USER" >/dev/null 2>&1; then
    chown root:"$SVC_USER" "$BIN" 2>/dev/null || true
    chmod 750 "$BIN" 2>/dev/null || true
  fi
  if [ "$INIT" = systemd ]; then
    command -v setcap >/dev/null 2>&1 && setcap -r "$BIN" 2>/dev/null || true
    return 0
  fi
  command -v setcap >/dev/null 2>&1 || { warn "没有 setcap，低端口将无法监听"; return 0; }
  setcap cap_net_bind_service=+ep "$BIN" || warn "设置低端口能力失败"
}

verify_download() { # 摘要只向 api.github.com 索取
  local file=$1 asset=$2 ver=$3 dig expect got pin
  got=$(sha256sum "$file" | awk 'NR==1{print $1}')
  if [ -n "${SINGBOX_SHA256:-}" ]; then
    pin=$(printf '%s' "$SINGBOX_SHA256" | tr 'A-F' 'a-f')
    [[ $pin =~ ^[0-9a-f]{64}$ ]] || { err "SINGBOX_SHA256 须为 64 位十六进制"; return 1; }
    [ "$got" = "$pin" ] || { err "下载文件与 SINGBOX_SHA256 不一致"; return 1; }
    return 0
  fi
  if [ "$REL_VER" != "$ver" ] || [ -z "$REL_JSON" ]; then
    REL_JSON=$(curl -fsSL -m 20 "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${ver}") || REL_JSON=""
    REL_VER=$ver
  fi
  dig=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .digest' <<<"$REL_JSON" | head -n1)
  expect=${dig#sha256:}
  [[ $expect =~ ^[0-9a-f]{64}$ ]] || { err "拿不到官方 sha256，可设置 SINGBOX_SHA256 后重试"; return 1; }
  [ "$got" = "$expect" ] || { err "与 GitHub 官方 sha256 不一致"; return 1; }
}

download_core() {
  local ver=$1 arch tmp bin asset url
  arch=$(detect_arch) || { err "不支持的 CPU 架构：$(uname -m)"; return 1; }
  tmp=$(mktemp -d)
  asset="sing-box-${ver}-linux-${arch}.tar.gz"
  [ "$OS" = alpine ] && asset="sing-box-${ver}-linux-${arch}-musl.tar.gz"
  url="${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v${ver}/$asset"
  if ! curl -fL --progress-bar -o "$tmp/sb.tgz" "$url"; then
    err "下载失败，可设置 GH_PROXY 后重试"; rm -rf "$tmp"; return 1
  fi
  if ! verify_download "$tmp/sb.tgz" "$asset" "$ver"; then
    rm -rf "$tmp"; return 1
  fi
  tar -xzf "$tmp/sb.tgz" -C "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 1; }
  bin=$(find "$tmp" -type f -name sing-box | head -n1)
  [ -n "$bin" ] || { err "压缩包内未找到 sing-box"; rm -rf "$tmp"; return 1; }
  install -m 755 "$bin" "$BIN" || { rm -rf "$tmp"; return 1; }
  CORE_VER=""
  grant_bind
  rm -rf "$tmp"
}

put_file() { # 内容相同则不写；0 已更新，1 未变
  local path=$1 body cur
  body=$(cat)
  if [ -f "$path" ]; then
    cur=$(cat "$path")
    [ "$cur" = "$body" ] && return 1
  fi
  printf '%s\n' "$body" > "$path" || return 2
  return 0
}
write_unit() {
  ensure_user || { err "无法创建系统用户 $SVC_USER"; return 1; }
  ensure_dirs
  touch "$LOG"
  chown "$SVC_USER:$SVC_USER" /var/lib/sing-box "$LOG" 2>/dev/null || true
  chmod 750 /var/lib/sing-box 2>/dev/null || true
  local st=0
  if [ "$INIT" = openrc ]; then
    put_file "$UNIT" <<EOF
#!/sbin/openrc-run

name=\$RC_SVCNAME
description="sing-box service"
supervisor=supervise-daemon
command="$BIN"
command_user="$SVC_USER:$SVC_USER"
command_args="-D /var/lib/sing-box run --disable-color -c $CONF"
directory="/var/lib/sing-box"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="$LOG"
error_log="$LOG"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 1048576"

depend() {
    after net dns
}

start_pre() {
    checkpath --directory --owner $SVC_USER:$SVC_USER --mode 0750 /var/lib/sing-box
    if ! "\$command" check -c $CONF >>$LOG 2>&1; then
        eerror "配置校验失败，详见 $LOG"
        return 1
    fi
}
EOF
    st=$?
    [ "$st" -eq 2 ] && { err "服务单元写入失败"; return 1; }
    chmod 755 "$UNIT" || { err "服务单元权限设置失败"; return 1; }
  else
    put_file "$UNIT" <<EOF
[Unit]
Description=sing-box service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=/var/lib/sing-box
ExecStartPre=$BIN check -c $CONF
ExecStart=$BIN -D /var/lib/sing-box run -c $CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/sing-box
ReadWritePaths=/etc/sing-box/acme /var/lib/sing-box

[Install]
WantedBy=multi-user.target
EOF
    st=$?
    [ "$st" -eq 2 ] && { err "服务单元写入失败"; return 1; }
    if [ "$st" -eq 0 ]; then
      systemctl daemon-reload || { err "systemd 重载失败"; return 1; }
    fi
  fi
  grant_bind
}

alpine_enable_community() {
  local f=/etc/apk/repositories
  [ -f "$f" ] || return 0
  grep -Eq '^[^#].*/community([[:space:]]|$)' "$f" && return 0
  warn "未改 apk 源。安装失败时请启用 community"
}

install_deps() {
  local -a pkgs=()
  local log
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
  command -v tar >/dev/null 2>&1 || pkgs+=(tar)
  command -v ip >/dev/null 2>&1 || pkgs+=(iproute2)
  [ -f /etc/ssl/certs/ca-certificates.crt ] || pkgs+=(ca-certificates)
  if [ "$INIT" != systemd ] && ! command -v setcap >/dev/null 2>&1; then
    if [ "$OS" = alpine ]; then pkgs+=(libcap); else pkgs+=(libcap2-bin); fi
  fi
  command -v shuf >/dev/null 2>&1 || pkgs+=(coreutils)
  [ ${#pkgs[@]} -eq 0 ] && return 0
  info "正在安装依赖…"
  if [ "$OS" = alpine ]; then
    log=$(mktemp)
    alpine_enable_community
    if ! apk add --no-cache "${pkgs[@]}" >"$log" 2>&1 \
      && { ! apk update >"$log" 2>&1 || ! apk add --no-cache "${pkgs[@]}" >"$log" 2>&1; }; then
      err "依赖安装失败，请检查 apk 源与网络"
      tail -n 12 "$log" | sed 's/^/    /'
      rm -f "$log"; return 1
    fi
    rm -f "$log"
  else
    apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1 \
           && apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1; } \
      || { err "依赖安装失败，请检查 apt 源与网络"; return 1; }
  fi
}

install_core() {
  local vf jf dp vp
  page "安装内核"
  if installed; then
    warn "已安装 v$(core_ver)，更新请用「升级内核」"
    write_unit || return
    secure_tree
    return
  fi
  vf=$(mktemp); jf=$(mktemp)
  install_deps & dp=$!
  (
    s=$(latest_version) || exit 1
    printf '%s' "$s" >"$vf"
    printf '%s' "$REL_JSON" >"$jf"
  ) & vp=$!
  if ! wait "$dp"; then
    kill "$vp" 2>/dev/null || true
    wait "$vp" 2>/dev/null || true
    rm -f "$vf" "$jf"
    return
  fi
  wait "$vp" || true
  VER=$(cat "$vf" 2>/dev/null || true)
  REL_JSON=$(cat "$jf" 2>/dev/null || true)
  REL_VER=$VER
  rm -f "$vf" "$jf"
  # 依赖刚装上时，并行的版本检查可能因为还没有 curl/jq 失败
  if [ -z "$VER" ]; then
    VER=$(latest_version) || true
  fi
  accept_version || return
  info "正在下载 sing-box v$VER …"
  download_core "$VER" || return
  write_unit || return
  build_config || { err "生成配置失败"; return; }
  mv -f "$CONF.new" "$CONF"
  secure_tree
  svc enable
  ok "安装完成（v$(core_ver)）"
}

upgrade_core() {
  page "升级内核"
  need_core || return
  local cur was=0; cur=$(core_ver)
  info "正在检查最新版本…"
  pick_version || return
  if [ "$cur" = "$VER" ]; then
    if write_unit; then
      secure_tree
      ok "已是最新版本 v$cur"
    fi
    return
  fi
  info "v$cur → v$VER"
  svc active && was=1
  cp -f "$BIN" "$BIN.old" || { err "无法备份旧内核，已取消"; return; }
  [ $was -eq 1 ] && svc stop
  if download_core "$VER" && { [ ! -f "$CONF" ] || "$BIN" check -c "$CONF" >/dev/null 2>&1; }; then
    rm -f "$BIN.old"
    if write_unit; then
      secure_tree
      if [ $was -eq 1 ]; then
        svc start
        svc_report || return
      fi
      ok "升级完成（v$(core_ver)）"
      return
    fi
    err "二进制已升级，但服务单元没有更新"
  else
    if [ -f "$BIN.old" ] && mv -f "$BIN.old" "$BIN"; then
      grant_bind
      err "升级失败，已恢复旧版本"
    else
      err "升级失败，且旧内核恢复失败"
    fi
  fi
  if [ $was -eq 1 ]; then
    svc start
    svc_report || true
  fi
}

svc_wait() {
  local i
  svc active && return 0
  for i in 1 2 3 4 5 6 7 8; do
    sleep 0.5
    svc active && return 0
  done
  return 1
}
show_fail_logs() { svc logs 15 | sed 's/^/    /'; }
halt_if_empty() {
  [ "$(inb_count)" -eq 0 ] || return 1
  svc stop >/dev/null 2>&1 || true
}
svc_report() {
  if svc_wait; then ok "内核运行中"; return 0; fi
  err "内核启动失败，最近日志："
  show_fail_logs
  return 1
}

start_core() {
  page "启动内核"
  need_core || return
  [ "$(inb_count)" -eq 0 ] && { warn "还没有入站"; return; }
  write_unit || warn "服务单元未更新"
  secure_tree
  svc start
  svc_report
}

stop_core() {
  page "停止内核"
  need_core || return
  svc stop && ok "内核已停止"
}

uninstall_core() {
  page "卸载内核"
  need_core || return
  confirm "确认卸载 sing-box？" n || return
  svc stop >/dev/null 2>&1; svc disable
  rm -f "$UNIT" "$BIN" "$BIN.old"
  [ "$INIT" = systemd ] && systemctl daemon-reload
  if confirm "同时删除所有入站与配置？" n; then
    rm -rf "$BASE" /var/lib/sing-box
    [ "$INIT" = openrc ] && rm -f "$LOG"
    remove_user
    ok "已卸载，配置已清除"
  else
    ok "已卸载，配置保留在 $BASE"
  fi
}

view_logs() {
  page "查看日志"
  need_core || return
  echo "  1  最近 100 行"
  echo "  2  实时日志"
  echo
  local n; sel n 2 || return
  echo
  if [ "$n" = 2 ]; then
    trap ':' INT; svc logs -f; trap - INT
  else
    svc logs 100; HOLD=1
  fi
}

# 键顺序：log、dns、证书、inbounds、outbounds、route
config_order='{log,dns}
  + (if ((.certificate_providers//[])|length)>0 then {certificate_providers} else {} end)
  + {inbounds,outbounds,route}'
build_config() {
  local -a files=()
  local listen
  listen=$(listen_host)
  if list_inb files; then
    jq -s --arg ad "$ACME_DIR" --arg listen "$listen" "
    {
      log:{level:\"info\"},
      dns:{servers:[{type:\"tls\",tag:\"google\",server:\"8.8.8.8\"}]},
      certificate_providers: ([ .[] | select(.cert==\"acme\") |
        ({type:\"acme\",
          tag:(\"acme-\"+(.domain|gsub(\"[:/]\";\"-\"))),
          domain:[.domain],
          data_directory:\$ad,
          provider:\"letsencrypt\"}
         + (if (.email//\"\")!=\"\" then {email:.email} else {} end)
        ) ] | unique_by(.tag)),
      inbounds: [ .[].inbound | .listen = \$listen
        | if .type == \"vless\" and ((.users[0].flow // \"\") == \"xtls-rprx-vision\")
          then .tls.alpn = [\"http/1.1\"] else . end ],
      outbounds:[{type:\"direct\"}],
      route:{rules:[{port:53,action:\"hijack-dns\"}]}
    } | $config_order
    " "${files[@]}" > "$CONF.new" || { rm -f "$CONF.new"; return 1; }
  else
    jq -n "
    {log:{level:\"info\"},
     dns:{servers:[{type:\"tls\",tag:\"google\",server:\"8.8.8.8\"}]},
     inbounds:[],
     outbounds:[{type:\"direct\"}],
     route:{rules:[{port:53,action:\"hijack-dns\"}]}} | $config_order
    " > "$CONF.new" || { rm -f "$CONF.new"; return 1; }
  fi
  chmod 600 "$CONF.new" 2>/dev/null || true
}

apply() { # 0 成功；1 未替换；2 已替换但未跑起来
  build_config || { err "生成配置失败"; return 1; }
  if ! "$BIN" check -c "$CONF.new" 2> "$BASE/.check.err"; then
    err "配置校验未通过："; sed 's/^/    /' "$BASE/.check.err"; rm -f "$CONF.new"; return 1
  fi
  mv -f "$CONF.new" "$CONF"
  write_unit || warn "服务单元未更新"
  secure_tree
  if halt_if_empty; then
    tip "已无入站，内核已停止"
    return 0
  fi
  info "正在应用配置…"
  svc restart
  svc_report && return 0
  return 2
}

restore_running() {
  build_config || { err "回滚后生成配置失败"; return; }
  mv -f "$CONF.new" "$CONF" || { err "回滚后写回配置失败"; return; }
  secure_tree
  halt_if_empty && return
  svc restart >/dev/null 2>&1 || true
  if ! svc_wait; then
    err "已恢复旧配置，但内核未能启动"
    show_fail_logs
  fi
}

commit() {
  echo
  local st
  apply
  st=$?
  if [ "$st" -eq 0 ]; then drop_snap; return 0; fi
  rollback
  [ "$st" -eq 2 ] && restore_running
  return 1
}

snapshot() {
  mkdir -p "$INB_DIR" "$CERT_DIR"
  rm -rf "$BASE/.bak" "$BASE/.certbak"
  cp -a "$INB_DIR" "$BASE/.bak"
  cp -a "$CERT_DIR" "$BASE/.certbak"
}
rollback() {
  rm -rf "$INB_DIR"; mv "$BASE/.bak" "$INB_DIR"
  if [ -d "$BASE/.certbak" ]; then rm -rf "$CERT_DIR"; mv "$BASE/.certbak" "$CERT_DIR"; fi
  warn "已恢复到修改前的配置"
}
drop_snap() { rm -rf "$BASE/.bak" "$BASE/.certbak"; }

rm_cert() { rm -f "$CERT_DIR/$1.crt" "$CERT_DIR/$1.key"; }
leaf_sha256() {
  local hex
  [ -f "$1" ] || return 1
  hex=$(openssl x509 -in "$1" -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print tolower($NF)}')
  [[ $hex =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$hex"
}
# 没有其他入站还在用这个域名时，删掉 certmagic 里对应的证书数据
forget_acme() {
  local domain=$1 f act
  local -a a=()
  [ -n "$domain" ] && [ -d "$ACME_DIR" ] || return 0
  case $domain in *'*'*|*'?'*|*'['*) return 0;; esac
  if list_inb a; then
    act=$(jq -r --arg d "$domain" 'if any(.[]; .cert=="acme" and .domain==$d) then "keep"
      elif any(.[]; .cert=="acme") then "drop" else "wipe" end' "${a[@]}") || return 0
  else
    act=wipe
  fi
  [ "$act" = keep ] && return 0
  if [ "$act" = drop ]; then
    while IFS= read -r -d '' f; do rm -rf "$f"; done \
      < <(find "$ACME_DIR" -depth -name "$domain" -print0 2>/dev/null)
  else
    find "$ACME_DIR" -mindepth 1 -depth -exec rm -rf {} + 2>/dev/null || true
  fi
}

save_inbound() {
  ensure_dirs
  SB_PROTO=$2 SB_NAME=$3 SB_CERT=$4 SB_DOMAIN=$5 SB_EMAIL=$6 SB_INB=$7 \
    jq -n '{proto:env.SB_PROTO,name:env.SB_NAME,cert:env.SB_CERT,domain:env.SB_DOMAIN,email:env.SB_EMAIL,inbound:(env.SB_INB|fromjson)}' \
    > "$INB_DIR/$1.json" || return 1
  chmod 600 "$INB_DIR/$1.json" 2>/dev/null || true
}

TLS_MODE=""; TLS_DOMAIN=""; TLS_EMAIL=""

resolve_ips() {
  local h=$1 r=""
  if command -v getent >/dev/null 2>&1; then
    r=$(getent ahosts "$h" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  fi
  if [ -z "$r" ] && command -v nslookup >/dev/null 2>&1; then
    r=$(nslookup "$h" 2>/dev/null | awk '
      /^Name:/ { inn=1; next }
      inn && /^Address[0-9]*:/ {
        ip=$2
        if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print ip
        else if (ip ~ /:/ && ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/) print ip
      }
      inn && /^Address [0-9]+:/ {
        ip=$3; sub(/%.*/,"",ip)
        if (ip ~ /^[0-9.]+$/ || ip ~ /:/) print ip
      }
    ' | sort -u | tr '\n' ' ')
  fi
  printf '%s' "$r"
}

check_domain() {
  get_ip
  local r hit=0 ip bad=0 foreign=""
  r=$(resolve_ips "$1")
  for ip in $r; do
    if ip_is_ours "$ip"; then hit=1; else foreign+="${foreign:+ }$ip"; fi
  done
  if [ -z "$r" ]; then warn "域名尚无解析，无法签发"; bad=1
  elif [ "$hit" -eq 0 ]; then warn "解析（${r% }）与本机（$(local_ips)）不一致"; bad=1
  elif [ -n "$foreign" ]; then warn "仍有解析未指向本机（$foreign）"; bad=1; fi
  warn_acme_ports || bad=1
  confirm_go "$bad"
}

warn_listen_port() {
  local line pid exe any=0 ours=0 port=$1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    any=1
    pid=$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' <<<"$line")
    exe=""
    [ -n "$pid" ] && exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    if [ "$exe" = "$BIN" ] || [ "$(basename "${exe:-}")" = sing-box ]; then ours=1; fi
  done < <(ss -H -ltnp "sport = :$port" 2>/dev/null || true)
  if [ "$any" = 1 ] && [ "$ours" = 0 ]; then
    warn "端口 ${port} 被占用，验证可能失败"
    return 1
  fi
  return 0
}
warn_acme_ports() {
  local bad=0
  warn_listen_port 80 || bad=1
  warn_listen_port 443 || bad=1
  [ "$bad" -eq 0 ]
}

valid_domain() { [[ $1 =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

valid_ip() {
  local ip=$1 o o1 o2 o3 o4
  if [[ $ip == *:* ]]; then norm_ip "$ip" >/dev/null; return; fi
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [ "$((10#$o))" -le 255 ] 2>/dev/null || return 1
    [ "$o" = "$((10#$o))" ] || return 1
  done
}

acme_tag() { printf 'acme-%s' "$(printf '%s' "$1" | tr ':/' '--')"; }

confirm_go() { # 1=有风险，须原样再输入要签的名字
  local typed
  if [ "$1" != 1 ]; then confirm "继续申请？" y; return; fi
  warn "继续申请可能失败"
  ask typed "继续请原样输入 ${TLS_DOMAIN}" ""
  [ "$typed" = "$TLS_DOMAIN" ] || { warn "输入不一致，已取消"; return 1; }
}

ask_tls() {
  echo "  1  自签名"
  echo "  2  域名证书"
  echo
  local n; sel n 2 || return 1
  echo
  TLS_EMAIL=""
  if [ "$n" = 2 ]; then
    TLS_MODE=acme
    require_acme_ports || return 1
    while true; do
      ask TLS_DOMAIN "域名" ""
      valid_domain "$TLS_DOMAIN" && break
      soft "域名格式不正确"
    done
    check_domain "$TLS_DOMAIN" || return 1
  else
    TLS_MODE=self
    while true; do
      ask TLS_DOMAIN "SNI" ""
      TLS_DOMAIN=$(bare_ip "$TLS_DOMAIN")
      { valid_domain "$TLS_DOMAIN" || valid_ip "$TLS_DOMAIN"; } && break
      soft "SNI 须为域名或 IP"
    done
    return 0
  fi
  while true; do
    ask TLS_EMAIL "邮箱（可选，到期通知）" ""
    [ -z "$TLS_EMAIL" ] && break
    [[ $TLS_EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
    soft "邮箱格式不正确"
  done
}

gen_cert() { # 先写临时文件，成功才替换
  local cn=$2 san cfg st key crt
  valid_domain "$cn" || valid_ip "$cn" || return 1
  ensure_dirs
  if valid_ip "$cn"; then san="IP:$cn"; else san="DNS:$cn"; fi
  cfg=$(mktemp); key=$(mktemp); crt=$(mktemp)
  cat > "$cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$cn
[v3]
subjectAltName=$san
basicConstraints=CA:FALSE
EOF
  openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null \
  && openssl req -new -x509 -days 3650 -key "$key" -out "$crt" \
       -config "$cfg" 2>/dev/null
  st=$?
  if [ "$st" -eq 0 ]; then
    mv -f "$key" "$CERT_DIR/$1.key" && mv -f "$crt" "$CERT_DIR/$1.crt" \
      && chmod 600 "$CERT_DIR/$1.key" "$CERT_DIR/$1.crt"
    st=$?
  fi
  rm -f "$cfg" "$key" "$crt"
  return $st
}

proto_alpn() {
  # Vision 不能协商 h2
  case $1 in vless) echo '["http/1.1"]';; hysteria2|tuic) echo '["h3"]';; *) echo '[]';; esac
}

make_tls() {
  local extra
  if is_acme "$TLS_MODE"; then
    extra=$(jq -n --arg t "$(acme_tag "$TLS_DOMAIN")" '{certificate_provider:$t}')
  else
    gen_cert "$1" "$TLS_DOMAIN" || { rm_cert "$1"; err "自签名证书生成失败"; return 1; }
    extra=$(jq -n --arg c "$CERT_DIR/$1.crt" --arg k "$CERT_DIR/$1.key" '{certificate_path:$c, key_path:$k}')
  fi
  jq -n --arg d "$TLS_DOMAIN" --argjson a "$2" --argjson e "$extra" \
    '{enabled:true, server_name:$d} + (if ($a|length)>0 then {alpn:$a} else {} end) + $e'
}

SS_METHOD=""
pick_ss_method() {
  local m=(2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305
           aes-128-gcm aes-256-gcm chacha20-ietf-poly1305)
  local n i
  for i in "${!m[@]}"; do printf "  %d  %s\n" "$((i+1))" "${m[$i]}"; done
  echo
  sel n ${#m[@]} || return 1
  echo
  SS_METHOD=${m[$((n-1))]}
}
ss_keylen() {
  case $1 in
    2022-blake3-aes-128-gcm) echo 16;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) echo 32;;
    *) echo 0;;
  esac
}
ss_password() {
  local n; n=$(ss_keylen "$1")
  if [ "$n" -gt 0 ]; then openssl rand -base64 "$n" | tr -d '\n'; else rand_str 20; fi
}
ss_key_ok() {
  local need got
  need=$(ss_keylen "$1")
  if [ "$need" -eq 0 ]; then [ -n "$2" ]; return; fi
  got=$(printf '%s' "$2" | base64 -d 2>/dev/null | wc -c) || return 1
  [ "$got" -eq "$need" ]
}

SEL_FILE=""
pick_inbound() {
  local -a files names
  local i n body="" raw
  list_inb files || { warn "还没有入站"; return 1; }
  raw=$(jq -r .name "${files[@]}") || { warn "无法读取入站"; return 1; }
  mapfile -t names <<< "$raw"
  for i in "${!files[@]}"; do body+="  $((i+1))  ${names[$i]}"$'\n'; done
  printf '%s\n' "$body"
  sel n ${#files[@]} || return 1
  SEL_FILE=${files[$((n-1))]}
}

add_inbound() {
  need_core || return
  local protos=(socks shadowsocks vless hysteria2 anytls tuic snell) n i body=""
  for i in "${!protos[@]}"; do body+="  $((i+1))  $(pname "${protos[$i]}")"$'\n'; done
  while true; do
    page "添加入站"
    printf '%s\n' "$body"
    sel n ${#protos[@]} || return
    add_one "${protos[$((n-1))]}"
    settle
  done
}

add_one() {
  local proto=$1
  local port name tag cert=none domain="" email="" inb tls listen
  echo
  tag="$proto-$(rand_hex)"
  ask_port port
  ask name "备注名称" "$(pname $proto)-$port"
  echo
  listen=$(listen_host)

  case $proto in
    socks)
      inb=$(SB_USER=$(rand_str 8) SB_PASS=$(rand_str 16) jq -n --arg t "$tag" --argjson port "$port" --arg listen "$listen" \
        '{type:"socks",tag:$t,listen:$listen,listen_port:$port,users:[{username:env.SB_USER,password:env.SB_PASS}]}');;
    shadowsocks)
      pick_ss_method || return
      inb=$(SB_PASS=$(ss_password "$SS_METHOD") jq -n --arg t "$tag" --argjson port "$port" --arg m "$SS_METHOD" --arg listen "$listen" \
        '{type:"shadowsocks",tag:$t,listen:$listen,listen_port:$port,method:$m,password:env.SB_PASS}');;
    snell)
      inb=$(SB_PASS=$(rand_str 24) jq -n --arg t "$tag" --argjson port "$port" --arg listen "$listen" \
        '{type:"snell",tag:$t,listen:$listen,listen_port:$port,version:6,psk:env.SB_PASS}');;
    vless|hysteria2|anytls|tuic)
      TLS_PORT=$port
      ask_tls || return
      tls=$(make_tls "$tag" "$(proto_alpn $proto)") || { rm_cert "$tag"; return; }
      cert=$TLS_MODE; domain=$TLS_DOMAIN; email=$TLS_EMAIL
      local id="" pw=""
      case $proto in vless|tuic) id=$(gen_uuid);; esac
      [ "$proto" != vless ] && pw=$(rand_str 20)
      inb=$(SB_ID="$id" SB_PASS="$pw" jq -n --arg ty "$proto" --arg t "$tag" --argjson port "$port" --arg listen "$listen" --argjson tls "$tls" '
        {type:$ty,tag:$t,listen:$listen,listen_port:$port,tls:$tls}
        + (if $ty=="vless" then {users:[{name:"user",uuid:env.SB_ID,flow:"xtls-rprx-vision"}]}
           elif $ty=="tuic" then {users:[{name:"user",uuid:env.SB_ID,password:env.SB_PASS}], congestion_control:"cubic"}
           else {users:[{name:"user",password:env.SB_PASS}]} end)');;
  esac

  echo
  snapshot
  save_inbound "$tag" "$proto" "$name" "$cert" "$domain" "$email" "$inb" \
    || { rollback; rm_cert "$tag"; err "保存入站失败"; return; }
  if commit; then
    ok "入站已添加"
    show_share "$INB_DIR/$tag.json"
  else
    rm_cert "$tag"
  fi
}

add_cred_fields() {
  case $1 in
    socks) keys+=(user pass); labels+=(用户名 密码);;
    shadowsocks) keys+=(method pass); labels+=(加密 密码);;
    vless) keys+=(uuid); labels+=(UUID);;
    hysteria2|anytls) keys+=(pass); labels+=(密码);;
    tuic) keys+=(uuid pass); labels+=(UUID 密码);;
    snell) keys+=(psk); labels+=(PSK);;
  esac
}

pick_key() {
  local i n
  [ ${#keys[@]} -gt 0 ] || return 1
  if [ ${#keys[@]} -eq 1 ]; then key=${keys[0]}; return 0; fi
  echo
  for i in "${!keys[@]}"; do echo "  $((i+1))  ${labels[$i]}"; done
  echo
  sel n ${#keys[@]} || return 1
  key=${keys[$((n-1))]}
}

nonempty() { [ -n "$1" ]; }
uuid_ok() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
psk_ok() { [ ${#1} -ge 12 ] && [ ${#1} -le 255 ]; }
ss_pass_ok() { ss_key_ok "$method" "$1"; }

edit_value() { # 未改动返回 2。空输入按校验失败处理，不把原值填回去
  local cur v blank=0
  cur=$(jq -r "$3" "$1")
  while true; do
    read -rp "  $2 [$cur]: " v || return 2
    if [ -z "$v" ]; then
      soft "$6"
      [ "$blank" = 1 ] && return 2
      blank=1
      continue
    fi
    blank=0
    "$5" "$v" && break
    soft "$6"
  done
  [ "$v" = "$cur" ] && return 2
  SB_SECRET=$v jq_edit "$1" "$4" || return 1
}

edit_pass() {
  local method
  if [ "$(jq -r .proto "$1")" = shadowsocks ]; then
    method=$(jq -r .inbound.method "$1")
    edit_value "$1" "密码" '.inbound.password' '.inbound.password=env.SB_SECRET' ss_pass_ok "密码格式不正确"
  else
    edit_value "$1" "密码" '.inbound.users[0].password' '.inbound.users[0].password=env.SB_SECRET' nonempty "密码不能为空"
  fi
}

edit_method() {
  local cur
  cur=$(jq -r .inbound.method "$1")
  pick_ss_method || return 2
  [ "$SS_METHOD" = "$cur" ] && return 2
  SB_METHOD=$SS_METHOD SB_SECRET=$(ss_password "$SS_METHOD") \
    jq_edit "$1" '.inbound.method=env.SB_METHOD | .inbound.password=env.SB_SECRET' || return 1
}

edit_field() {
  case $1 in
    user) edit_value "$2" "用户名" '.inbound.users[0].username' '.inbound.users[0].username=env.SB_SECRET' nonempty "用户名不能为空";;
    pass) edit_pass "$2";;
    uuid) edit_value "$2" "UUID" '.inbound.users[0].uuid' '.inbound.users[0].uuid=env.SB_SECRET' uuid_ok "UUID 格式不正确";;
    psk) edit_value "$2" "PSK（12-255 位）" '.inbound.psk' '.inbound.psk=env.SB_SECRET' psk_ok "PSK 长度须为 12-255";;
    method) edit_method "$2";;
    sni) edit_sni "$2";;
    flow) edit_flow "$2";;
    cc) edit_cc "$2";;
    hcc) edit_hcc "$2";;
    tls) edit_tls "$2";;
    *) return 1;;
  esac
}

edit_tls() {
  local f=$1 tag proto tls old_mode old_domain old_email
  tag=$(jq -r .inbound.tag "$f"); proto=$(jq -r .proto "$f")
  old_mode=$(jq -r .cert "$f"); old_domain=$(jq -r .domain "$f"); old_email=$(jq -r '.email // ""' "$f")
  TLS_PORT=$(jq -r '.inbound.listen_port' "$f")
  ask_tls || return 2
  if [ "$TLS_MODE" = "$old_mode" ] && [ "$TLS_DOMAIN" = "$old_domain" ] \
     && { [ "$TLS_MODE" = self ] || [ "$TLS_EMAIL" = "$old_email" ]; }; then
    return 2
  fi
  tls=$(make_tls "$tag" "$(proto_alpn "$proto")") || return 1
  jq_edit "$f" --argjson t "$tls" --arg c "$TLS_MODE" --arg d "$TLS_DOMAIN" --arg e "$TLS_EMAIL" \
    '.inbound.tls=$t|.cert=$c|.domain=$d|.email=$e' || return 1
}

edit_sni() {
  local f=$1 tag proto mode domain old tls
  tag=$(jq -r .inbound.tag "$f"); proto=$(jq -r .proto "$f"); mode=$(jq -r .cert "$f")
  old=$(jq -r '.inbound.tls.server_name // .domain' "$f")
  ask domain "SNI" "$old"
  domain=$(bare_ip "$domain")
  [ -n "$domain" ] || { err "SNI 不能为空"; return 1; }
  [ "$domain" = "$old" ] && return 2
  if [ "$mode" = self ]; then
    valid_domain "$domain" || valid_ip "$domain" || { err "SNI 须为域名或 IP"; return 1; }
    gen_cert "$tag" "$domain" || { err "自签名证书生成失败"; return 1; }
    jq_edit "$f" --arg d "$domain" '.domain=$d | .inbound.tls.server_name=$d' || return 1
    return 0
  fi
  TLS_MODE=$mode; TLS_DOMAIN=$domain; TLS_EMAIL=$(jq -r '.email // ""' "$f")
  if [ "$mode" != acme ]; then err "请改用域名证书或自签名"; return 1; fi
  valid_domain "$domain" || { err "域名格式不正确"; return 1; }
  check_domain "$domain" || return 1
  tls=$(make_tls "$tag" "$(proto_alpn "$proto")") || return 1
  jq_edit "$f" --argjson t "$tls" --arg d "$domain" '.inbound.tls=$t | .domain=$d' || return 1
}

edit_flow() {
  local f=$1 n cur new
  cur=$(jq -r '.inbound.users[0].flow // ""' "$f")
  echo "  1  xtls-rprx-vision"
  echo "  2  无"
  echo
  sel n 2 || return 2
  if [ "$n" = 1 ]; then new=xtls-rprx-vision; else new=""; fi
  [ "$new" = "$cur" ] && return 2
  if [ -n "$new" ]; then jq_edit "$f" --arg v "$new" '.inbound.users[0].flow=$v' || return 1
  else jq_edit "$f" 'del(.inbound.users[0].flow)' || return 1; fi
}

edit_cc() {
  local f=$1 m=(cubic new_reno bbr) n i cur
  cur=$(jq -r '.inbound.congestion_control // "cubic"' "$f")
  for i in "${!m[@]}"; do printf "  %d  %s\n" "$((i+1))" "${m[$i]}"; done
  echo
  sel n ${#m[@]} || return 2
  [ "${m[$((n-1))]}" = "$cur" ] && return 2
  jq_edit "$f" --arg c "${m[$((n-1))]}" '.inbound.congestion_control=$c' || return 1
}

edit_hcc() {
  local f=$1 n up down cur up0 down0
  cur=$(jq -r 'if .inbound.ignore_client_bandwidth==true then "1"
    elif (.inbound.up_mbps and .inbound.down_mbps) then "2" else "3" end' "$f")
  echo "  1  BBR"
  echo "  2  Brutal"
  echo "  3  不限制"
  echo
  sel n 3 || return 2
  case $n in
    1) [ "$cur" = 1 ] && return 2
       jq_edit "$f" 'del(.inbound.up_mbps,.inbound.down_mbps) | .inbound.ignore_client_bandwidth=true' || return 1;;
    3) [ "$cur" = 3 ] && return 2
       jq_edit "$f" 'del(.inbound.up_mbps,.inbound.down_mbps,.inbound.ignore_client_bandwidth)' || return 1;;
    2)
      up0=$(jq -r '.inbound.up_mbps // 100' "$f")
      down0=$(jq -r '.inbound.down_mbps // 100' "$f")
      echo "  服务器带宽：上行=客户端下载，下行=客户端上传"
      ask_mbps up "服务端上行 Mbps" "$up0"
      ask_mbps down "服务端下行 Mbps" "$down0"
      [ "$cur" = 2 ] && [ "$up" = "$up0" ] && [ "$down" = "$down0" ] && return 2
      jq_edit "$f" --argjson u "$up" --argjson d "$down" \
        'del(.inbound.ignore_client_bandwidth) | .inbound.up_mbps=$u | .inbound.down_mbps=$d' || return 1;;
  esac
}

take_edit() {
  local st
  edit_field "$1" "$2"
  st=$?
  if [ "$st" -eq 2 ]; then drop_snap; return 2; fi
  if [ "$st" -ne 0 ]; then rollback; return 1; fi
}

with_inbound() {
  local title=$1 action=$2
  need_core || return
  if ! has_inb; then warn "还没有入站"; return; fi
  while has_inb; do
    page "$title"
    pick_inbound || return
    "$action"
    settle
  done
}

modify_inbound() { with_inbound "修改入站" modify_one; }

modify_one() {
  local f=$SEL_FILE proto tag oport key old_cert="" old_domain=""
  proto=$(jq -r .proto "$f"); tag=$(jq -r .inbound.tag "$f"); oport=$(jq -r .inbound.listen_port "$f")

  local keys=(port) labels=("端口")
  add_cred_fields "$proto"
  tls_proto "$proto" && { keys+=(sni); labels+=(SNI); }
  case $proto in
    vless) keys+=(flow); labels+=("流控");;
    tuic) keys+=(cc); labels+=("拥塞");;
    hysteria2) keys+=(hcc); labels+=("拥塞");;
  esac
  tls_proto "$proto" && { keys+=(tls); labels+=(证书); }
  keys+=(name); labels+=("备注")
  pick_key || return

  echo
  snapshot
  local nport="" nname="" cur
  case $key in
    port)
      ask_port nport "$oport"
      [ "$nport" = "$oport" ] && { drop_snap; return; }
      jq_edit "$f" --argjson p "$nport" '.inbound.listen_port=$p' || { rollback; return; };;
    name)
      cur=$(jq -r .name "$f")
      ask nname "新备注" "$cur"
      [ "$nname" = "$cur" ] && { drop_snap; return; }
      jq_edit "$f" --arg n "$nname" '.name=$n' || { rollback; return; }
      drop_snap
      secure_tree
      ok "修改完成"
      return;;
    *)
      old_cert=$(jq -r .cert "$f")
      old_domain=$(jq -r .domain "$f")
      take_edit "$key" "$f" || return;;
  esac

  commit || return
  if [ "$key" = tls ]; then
    local c; c=$(jq -r .cert "$f")
    if is_acme "$c"; then rm_cert "$tag"; fi
  fi
  if { [ "$key" = tls ] || [ "$key" = sni ]; } && is_acme "$old_cert" \
    && { [ "$old_cert" != "$(jq -r .cert "$f")" ] || [ "$old_domain" != "$(jq -r .domain "$f")" ]; }; then
    forget_acme "$old_domain"
  fi
  ok "修改完成"
  show_share "$f"
}

surge_name_ok() { [[ $1 == *$'\n'* || $1 == *','* || $1 == *'='* ]] && return 1; [ -n "$1" ]; }
surge_psk_ok() { [[ $1 == *$'\n'* || $1 == *','* || $1 == *'='* || $1 == *' '* || $1 == *'"'* ]] && return 1; [ -n "$1" ]; }

show_share() {
  local f=$1 proto name port cert domain ins="" nm pw="" id="" m="" cs="" sniq flow="" cc=""
  local su="" sp="" raw host lab url alpn="" hy_up="" hy_down="" brutal=0 pcs=""
  local -a hosts=()
  proto=$(jq -r .proto "$f"); name=$(jq -r .name "$f")
  cert=$(jq -r .cert "$f"); domain=$(jq -r .domain "$f")
  port=$(jq -r .inbound.listen_port "$f")
  get_ip
  case $cert in
    acme) cs="ACME";;
    self) cs="自签名"; ins=1;;
  esac
  sniq=$domain
  [[ $domain == *:* ]] && sniq=$(urlenc "$domain")
  nm=$(urlenc "$name")
  HOLD=1

  echo; echo "  ${B}$name${N}  ${D}$(pname "$proto")${N}"; line
  kv "IPv4" "${SERVER_IP4:-无}"
  kv "IPv6" "${SERVER_IP6:-无}"
  [ "$cert" = acme ] && kv "域名" "$domain"
  kv "端口" "$port"

  case $proto in
    socks)
      su=$(jq -r '.inbound.users[0].username' "$f"); sp=$(jq -r '.inbound.users[0].password' "$f")
      kv "用户" "$su"; kv "密码" "$sp";;
    shadowsocks)
      m=$(jq -r .inbound.method "$f"); pw=$(jq -r .inbound.password "$f")
      kv "加密" "$m"; kv "密码" "$pw";;
    vless)
      id=$(jq -r '.inbound.users[0].uuid' "$f")
      flow=$(jq -r '.inbound.users[0].flow // ""' "$f")
      alpn=$(jq -r '(.inbound.tls.alpn // []) | join(",")' "$f")
      [ "$flow" = xtls-rprx-vision ] && alpn=http/1.1
      if [ -n "$ins" ]; then pcs=$(leaf_sha256 "$CERT_DIR/$(jq -r .inbound.tag "$f").crt") || pcs=""; fi
      kv "UUID" "$id"; kv "流控" "${flow:-无}"; kv "SNI " "$domain"; kv "证书" "$cs";;
    hysteria2|anytls)
      pw=$(jq -r '.inbound.users[0].password' "$f")
      kv "密码" "$pw"; kv "SNI " "$domain"; kv "证书" "$cs"
      if [ "$proto" = hysteria2 ]; then
        hy_up=$(jq -r '.inbound.up_mbps // empty' "$f")
        hy_down=$(jq -r '.inbound.down_mbps // empty' "$f")
        kv "拥塞" "$(jq -r 'if .inbound.ignore_client_bandwidth==true then "BBR"
          elif (.inbound.up_mbps and .inbound.down_mbps) then "Brutal \(.inbound.up_mbps)/\(.inbound.down_mbps) Mbps"
          else "不限制" end' "$f")"
      fi;;
    tuic)
      id=$(jq -r '.inbound.users[0].uuid' "$f"); pw=$(jq -r '.inbound.users[0].password' "$f")
      cc=$(jq -r '.inbound.congestion_control // "cubic"' "$f")
      kv "UUID" "$id"; kv "密码" "$pw"; kv "拥塞" "$cc"; kv "SNI " "$domain"; kv "证书" "$cs";;
    snell)
      pw=$(jq -r .inbound.psk "$f")
      kv "PSK " "$pw"; kv "版本" "v6";;
  esac

  [ "$cert" = acme ] && hosts+=("$domain")
  [ -n "$SERVER_IP4" ] && hosts+=("$SERVER_IP4")
  [ -n "$SERVER_IP6" ] && hosts+=("$SERVER_IP6")
  [ "$cert" != acme ] && [ ${#hosts[@]} -eq 0 ] && [ -n "$SERVER_IP" ] && hosts+=("$SERVER_IP")

  if [[ $hy_up =~ ^[0-9]+$ ]] && [[ $hy_down =~ ^[0-9]+$ ]]; then brutal=1; fi

  for raw in "${hosts[@]}"; do
    raw=$(bare_ip "$raw")
    host=$(host_fmt "$raw")
    if valid_ip "$raw"; then [[ $raw == *:* ]] && lab=IPv6 || lab=IPv4; else lab=域名; fi
    case $proto in
      socks) url="socks5://$(urlenc "$su"):$(urlenc "$sp")@$host:$port#$nm";;
      shadowsocks) url="ss://$(b64url "$m:$pw")@$host:$port#$nm";;
      vless)
        url="vless://$id@$host:$port?encryption=none${flow:+&flow=$flow}&security=tls&sni=$sniq&type=tcp"
        [ -n "$alpn" ] && url+="&alpn=$(urlenc "$alpn")"
        [ -n "$ins" ] && url+="&allowInsecure=1"
        [ -n "$pcs" ] && url+="&pcs=$pcs"
        url+="#$nm";;
      hysteria2|anytls)
        url="$proto://$(urlenc "$pw")@$host:$port/?sni=$sniq"
        [ -n "$ins" ] && url+="&insecure=1"
        [ "$brutal" = 1 ] && url+="&upmbps=${hy_down}&downmbps=${hy_up}"
        url+="#$nm";;
      tuic)
        url="tuic://$(urlenc "$id"):$(urlenc "$pw")@$host:$port/?sni=$sniq&alpn=h3&congestion_control=$cc"
        [ -n "$ins" ] && url+="&allow_insecure=1"
        url+="#$nm";;
      snell)
        if surge_name_ok "$name" && surge_psk_ok "$pw"; then url="$name = snell, $raw, $port, psk=$pw, version=6"
        else url=""; fi;;
    esac
    echo; echo "  ${D}${lab}${N}"
    if [ "$proto" = snell ]; then
      if [ -n "$url" ]; then
        echo "  ${D}Surge 配置${N}"
        printf '  %s\n' "$url"
      else
        tip "名称或 PSK 含保留字符，已省略 Surge 行"
      fi
      echo "  ${D}sing-box 出站${N}"
      SB_NAME=$name SB_HOST=$raw SB_PSK=$pw jq -nc --argjson p "$port" \
        '{type:"snell",tag:env.SB_NAME,server:env.SB_HOST,server_port:$p,version:6,psk:env.SB_PSK}' | sed 's/^/  /'
    else
      printf '  %s\n' "$url"
    fi
  done
}

share_selected() { show_share "$SEL_FILE"; }
share_inbound() { with_inbound "分享入站" share_selected; }

delete_inbound() { with_inbound "删除入站" delete_one; }

delete_one() {
  local f=$SEL_FILE tag name cert domain
  tag=$(jq -r .inbound.tag "$f")
  name=$(jq -r .name "$f")
  cert=$(jq -r .cert "$f"); domain=$(jq -r .domain "$f")
  echo
  confirm "确认删除「$name」？" n || return
  snapshot; rm -f "$f"
  commit || return
  rm_cert "$tag"
  is_acme "$cert" && forget_acme "$domain"
  ok "已删除「$name」"
}

home() {
  local st v b
  if installed; then
    v="v$(core_ver)"
    if [ -z "$SVC_ST" ]; then svc active && SVC_ST=1 || SVC_ST=0; fi
    if [ "$SVC_ST" = 1 ]; then st="${G}● 运行中${N}"; else st="${R}○ 已停止${N}"; fi
  else
    v="未安装"; st="${D}○ 未安装${N}"
  fi
  b=$'\n'"  ${B}sing-box${N} 管理面板"$'\n'"$RULE"$'\n'
  b+="  $st    $v    入站 $(inb_count)"$'\n'"$RULE"$'\n'
  if [ -n "$NOTICE" ]; then b+="$NOTICE$RULE"$'\n'; NOTICE=""; fi
  b+=$'\n'"$MENU"$'\n'
  paint "$b"
}

wait_back() {
  local _c
  while true; do
    read -rp "  请选择 [回车返回]: " _c
    [ -z "$_c" ] && return
  done
}
settle() {
  if [ "$HOLD" = 1 ]; then echo; wait_back; HOLD=0; NOTICE=""; fi
}

acquire_lock() {
  local dir=/run/lock pid
  [ -d /run/lock ] || dir=/tmp
  LOCKDIR=$dir/sb-sing-box.lock
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    pid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "另一个 sing-box.sh 正在运行"
      exit 1
    fi
    rm -rf "$LOCKDIR"
  done
  echo $$ > "$LOCKDIR/pid"
  trap 'rm -rf "$LOCKDIR"' EXIT
}

main() {
  local n
  acquire_lock
  while true; do
    HOLD=0
    home
    sel n 10 退出 || { printf '%s' "$CLS"; exit 0; }
    NOTICE=""
    case $n in
      1) install_core;;   2) upgrade_core;;    3) start_core;;
      4) stop_core;;      5) uninstall_core;;  6) view_logs;;
      7) add_inbound;;    8) modify_inbound;;
      9) share_inbound;;  10) delete_inbound;;
    esac
    settle
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
