#!/usr/bin/env bash
# sing-box 管理面板：Debian / Ubuntu / Alpine，内核 >= 1.14.0。
# bash sing-box.sh；Alpine 先 apk add bash。支持 GH_PROXY / SINGBOX_SHA256。
# source 只定义函数；所有环境初始化和系统操作从 main 开始。

# jq 过滤器使用字面量 $变量；&&/|| 链统一表示前置步骤失败即退出。
# shellcheck disable=SC2016,SC2015

# 1. 运行时、平台和终端。业务返回值：0 成功，1 失败，2 取消/无变化。
runtime_paths() {
  local prefix=${1:-}
  BASE=$prefix/etc/sing-box
  INB_DIR=$BASE/inbounds CERT_DIR=$BASE/certs ACME_DIR=$BASE/acme
  CONF=$BASE/config.json TXN_ROOT=$BASE/.transactions
  BIN=$prefix/usr/local/bin/sing-box UNIT=$prefix/etc/systemd/system/sing-box.service
  STATE_DIR=$prefix/var/lib/sing-box LOG=$prefix/var/log/sing-box.log RUN_ROOT=$prefix/run
  SVC=sing-box SVC_USER=sing-box MIN_VER=1.14.0
  OS='' INIT=systemd RUNTIME_DIR='' TXN_DIR='' LOCK_FD='' RUNTIME_BLOCKED=0
  CORE_VER='' REL_VER='' REL_JSON='' SERVER_IP4='' SERVER_IP6=''
  NOTICE='' HOLD=0 UI_EOF=0
  G=$'\033[32m' R=$'\033[31m' Y=$'\033[33m' D=$'\033[2m' B=$'\033[1m' N=$'\033[0m'
  CLS=$'\033[H\033[2J' RULE="  ${D}──────────────────────────────────${N}"
}

ui_ok()   { local msg="  ${G}✓${N} $*"; printf '%s\n' "$msg"; NOTICE+="$msg"$'\n'; }
ui_warn() { local msg="  ${Y}!${N} $*"; printf '%s\n' "$msg" >&2; NOTICE+="$msg"$'\n'; }
ui_tip()  { local msg="  ${D}$*${N}"; printf '%s\n' "$msg"; NOTICE+="$msg"$'\n'; }
ui_err()  { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; HOLD=1; }
ui_soft() { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; }
ui_info() { printf '  %s%s%s\n' "$D" "$*" "$N" >&2; }
ui_line() { printf '%s\n' "$RULE"; }
ui_kv()   { printf '  %s%s%s  %s\n' "$D" "$1" "$N" "$2"; }
ui_page() {
  local body=$'\n'"  ${B}sing-box${N} ${D}›${N} ${B}$1${N}"$'\n'"$RULE"$'\n\n'
  if [ -n "$NOTICE" ]; then body+="$NOTICE$RULE"$'\n\n'; NOTICE=''; fi
  printf '%s%s' "$CLS" "$body"
}

ui_read() {
  local _read_value
  if ! IFS= read -r -p "$2" _read_value; then UI_EOF=1; return 2; fi
  printf -v "$1" '%s' "$_read_value"
}
ui_ask() {
  local _ask_value
  ui_read _ask_value "  $2${3:+ [$3]}: " || return 2
  printf -v "$1" '%s' "${_ask_value:-$3}"
}
ui_confirm() {
  local answer default=${2:-n} hint='y/N'
  [ "$default" = y ] && hint='Y/n'
  ui_read answer "  $1 [$hint]: " || return 2
  [[ ${answer:-$default} =~ ^[Yy]$ ]] || return 2
}
ui_select() {
  local _choice _default=${4:-} _hint=${3:-返回}
  while true; do
    ui_read _choice "  请选择 [回车$_hint]: " || return 2
    if [ -z "$_choice" ]; then
      [ -n "$_default" ] || return 2
      printf -v "$1" '%s' "$_default"; return 0
    fi
    if [[ $_choice =~ ^[1-9][0-9]{0,4}$ ]] && [ "$_choice" -le "$2" ]; then
      printf -v "$1" '%s' "$_choice"; return 0
    fi
  done
}
ui_settle() {
  local answer
  if [ "$HOLD" = 1 ] && [ "$UI_EOF" = 0 ]; then
    printf '\n'
    while ui_read answer '  请选择 [回车返回]: '; do [ -z "$answer" ] && break; done
    HOLD=0 NOTICE=''
  fi
}

platform_detect() {
  if [ -f /etc/alpine-release ]; then
    OS=alpine INIT=openrc UNIT=/etc/init.d/$SVC
    { [ -e /run/openrc/softlevel ] || [ -e /var/run/openrc/softlevel ]; } || {
      ui_err 'OpenRC 未运行'; return 1;
    }
    command -v rc-service >/dev/null 2>&1 || { ui_err '需要 OpenRC（apk add openrc）'; return 1; }
  elif [ -f /etc/debian_version ]; then
    OS=debian INIT=systemd
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 || {
      ui_err '需要正在运行的 systemd'; return 1;
    }
  else ui_err '仅支持 Debian / Ubuntu / Alpine Linux'; return 1; fi
}
platform_packages() {
  [ "$#" -gt 0 ] || return 0
  local log_file
  log_file=$(mktemp) || return 1
  if [ "$OS" = alpine ]; then
    if ! apk add --no-cache "$@" >"$log_file" 2>&1; then
      if ! apk update >>"$log_file" 2>&1 || ! apk add --no-cache "$@" >>"$log_file" 2>&1; then
        tail -n 12 "$log_file" >&2; rm -f "$log_file"; return 1
      fi
    fi
  elif ! apt-get install -y -qq "$@" >"$log_file" 2>&1; then
    if ! apt-get update -qq >>"$log_file" 2>&1 || ! apt-get install -y -qq "$@" >>"$log_file" 2>&1; then
      tail -n 12 "$log_file" >&2; rm -f "$log_file"; return 1
    fi
  fi
  rm -f "$log_file"
}
platform_deps() {
  local cmd
  local -a packages=()
  for cmd in curl jq openssl tar; do command -v "$cmd" >/dev/null 2>&1 || packages+=("$cmd"); done
  if ! command -v ip >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1; then packages+=(iproute2); fi
  command -v shuf >/dev/null 2>&1 || packages+=(coreutils)
  command -v flock >/dev/null 2>&1 || packages+=(util-linux)
  [ -f /etc/ssl/certs/ca-certificates.crt ] || packages+=(ca-certificates)
  if [ "$INIT" = openrc ] && ! command -v setcap >/dev/null 2>&1; then packages+=(libcap); fi
  [ "${#packages[@]}" -eq 0 ] || ui_info '正在安装依赖…'
  platform_packages "${packages[@]}" || { ui_err '依赖安装失败，请检查软件源与网络'; return 1; }
  for cmd in curl jq openssl tar ip ss shuf flock sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { ui_err "缺少必要工具：$cmd"; return 1; }
  done
}
platform_user() {
  id "$SVC_USER" >/dev/null 2>&1 && return 0
  if [ "$OS" = alpine ]; then
    addgroup -S "$SVC_USER" 2>/dev/null || true
    adduser -S -D -H -h "$STATE_DIR" -G "$SVC_USER" -s /sbin/nologin "$SVC_USER" || return 1
  else
    useradd --system --user-group --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$SVC_USER" || return 1
  fi
  id "$SVC_USER" >/dev/null 2>&1
}
platform_remove_user() {
  id "$SVC_USER" >/dev/null 2>&1 || return 0
  if [ "$OS" = alpine ]; then deluser "$SVC_USER"
  else userdel "$SVC_USER" && { groupdel "$SVC_USER" 2>/dev/null || true; }; fi
}
platform_dirs() {
  mkdir -p "$INB_DIR" "$CERT_DIR" "$ACME_DIR" "$STATE_DIR" "$TXN_ROOT" || return 1
  chown root:root "$BASE" "$INB_DIR" "$CERT_DIR" "$TXN_ROOT" || return 1
  chmod 700 "$TXN_ROOT" || return 1
  chgrp "$SVC_USER" "$BASE" "$INB_DIR" "$CERT_DIR" || return 1
  chmod 750 "$BASE" "$INB_DIR" "$CERT_DIR" || return 1
  chown "$SVC_USER:$SVC_USER" "$STATE_DIR" "$ACME_DIR" || return 1
  chmod 750 "$STATE_DIR" && chmod 700 "$ACME_DIR" || return 1
  # 兼容旧安装中的 ACME 存储；不遍历配置、证书或事务目录。
  find "$ACME_DIR" -type d -exec chown "$SVC_USER:$SVC_USER" {} + -exec chmod 700 {} + || return 1
  find "$ACME_DIR" -type f -exec chown "$SVC_USER:$SVC_USER" {} + -exec chmod 600 {} + || return 1
  if [ "$INIT" = openrc ]; then
    mkdir -p "$(dirname "$LOG")" && touch "$LOG" && chown "$SVC_USER:$SVC_USER" "$LOG" && chmod 600 "$LOG" || return 1
  fi
}
platform_file_mode() {
  case ${2:-$1} in
    "$BIN") chown root:"$SVC_USER" "$1" && chmod 750 "$1";;
    "$UNIT") chown root:root "$1" && { if [ "$INIT" = openrc ]; then chmod 755 "$1"; else chmod 644 "$1"; fi; };;
    *) chown root:"$SVC_USER" "$1" && chmod 640 "$1";;
  esac
}
platform_bind() {
  [ -x "$BIN" ] || return 0
  if [ "$INIT" = systemd ]; then
    if command -v getcap >/dev/null 2>&1 && [ -n "$(getcap "$BIN")" ]; then setcap -r "$BIN" || return 1; fi
  else
    setcap cap_net_bind_service=+ep "$BIN" || return 1
  fi
}
platform_arch() {
  case $1 in
    x86_64|amd64) printf amd64;; aarch64|arm64) printf arm64;; armv7l|armv7) printf armv7;;
    i386|i686) printf 386;; s390x) printf s390x;; *) return 1;;
  esac
}
runtime_lock() {
  local lock_dir=$RUN_ROOT/sb-sing-box
  # /run/lock 在部分系统可由普通用户写入；锁放进 /run 下的私有目录。
  [ ! -L "$lock_dir" ] && mkdir -p "$lock_dir" && chmod 700 "$lock_dir" || return 1
  [ ! -L "$lock_dir/panel.lock" ] || return 1
  # 锁文件永不 unlink；由内核在描述符关闭时释放锁。
  exec {LOCK_FD}>>"$lock_dir/panel.lock" || return 1
  flock -n "$LOCK_FD" || { ui_err '另一个 sing-box.sh 正在运行'; exec {LOCK_FD}>&-; LOCK_FD=''; return 1; }
}
runtime_cleanup() {
  local status=${1:-$?}
  trap - EXIT INT TERM
  if [ -n "$TXN_DIR" ]; then txn_rollback || status=1; fi
  [ -z "$RUNTIME_DIR" ] || rm -rf -- "$RUNTIME_DIR"
  if [ -n "$LOCK_FD" ]; then exec {LOCK_FD}>&-; fi
  return "$status"
}

# 2. 数据、校验和协议元数据。路径必须显式传入，读取不修改原文件。
store_list() {
  local -n _store_files=$1
  local entry
  _store_files=()
  for entry in "${2:-$INB_DIR}"/*.json; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then _store_files+=("$entry"); fi
  done
  [ "${#_store_files[@]}" -gt 0 ]
}
store_count() { local -a entries; store_list entries "$1" || true; printf '%s' "${#entries[@]}"; }
store_edit() {
  local path=$1 tmp_file; shift
  tmp_file=$(mktemp "${path}.XXXXXX") || return 1
  if jq "$@" "$path" >"$tmp_file" && chmod 600 "$tmp_file" && mv -f -- "$tmp_file" "$path"; then return 0; fi
  rm -f -- "$tmp_file"; return 1
}
store_save() {
  local out=$1 proto=$2 name=$3 cert=$4 domain=$5 email=$6 inbound=$7
  SB_NAME=$name SB_INB=$inbound jq -n --arg p "$proto" --arg c "$cert" --arg d "$domain" --arg e "$email" \
    '{proto:$p,name:env.SB_NAME,cert:$c,domain:$d,email:$e,inbound:(env.SB_INB|fromjson)}' >"$out"
}
store_validate() {
  local file
  local -a entries=()
  store_list entries "$1" || return 0
  for file in "${entries[@]}"; do
    if [ ! -f "$file" ] || [ -L "$file" ] || ! jq -e '
      type=="object" and (.proto|IN("socks","shadowsocks","vless","hysteria2","anytls","tuic","snell"))
      and (.name|type=="string") and (.cert|IN("none","self","acme"))
      and (.inbound|type=="object") and (.proto==.inbound.type)
      and (.inbound.tag|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$"))
      and (.inbound.listen_port|type=="number" and floor==. and .>=1 and .<=65535)
      and (if .cert=="none" then true else (.domain|type=="string" and length>0) and (.inbound.tls.enabled==true) end)
      and (if .cert=="acme" then (.inbound.tls.certificate_provider|type=="string" and length>0) else true end)
      and (if .proto=="snell" then
        (.inbound.version|IN(5,6))
        and (if .inbound.version==5 then ((.inbound.obfs_mode//"none")|IN("none","http")) else ((.inbound|has("obfs_mode"))|not) end)
        else true end)
    ' "$file" >/dev/null 2>&1; then ui_err "入站文件损坏或不受支持：$file"; return 1; fi
    if [ "$(jq -r .inbound.tag "$file")" != "$(basename "$file" .json)" ]; then
      ui_err "入站 tag 与文件名不一致：$file"; return 1
    fi
  done
  jq -se '([.[].inbound.listen_port]|length== (unique|length)) and
    ([.[].inbound.tag]|length==(unique|length))' "${entries[@]}" >/dev/null || {
    ui_err '入站 tag 或端口重复'; return 1;
  }
}
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
valid_positive() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]; }
valid_nonempty() { [ -n "$1" ]; }
valid_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_psk() { [ "${#1}" -ge 12 ] && [ "${#1}" -le 255 ]; }
valid_domain() {
  local label
  local -a labels
  [ "${#1}" -le 253 ] && [[ $1 == *.* && $1 != *. && $1 != .* && $1 != *..* ]] || return 1
  IFS=. read -ra labels <<<"$1"
  for label in "${labels[@]}"; do
    [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
  [[ ${labels[${#labels[@]}-1]} =~ ^[A-Za-z][A-Za-z0-9-]*$ ]]
}
valid_version() {
  local numeric item
  local -a parts
  [[ $1 =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || return 1
  [[ $1 == *-* ]] || return 0
  numeric=${1#*-}; IFS=. read -ra parts <<<"$numeric"
  for item in "${parts[@]}"; do [[ $item =~ ^0[0-9]+$ ]] && return 1; done
  return 0
}
version_ge() {
  valid_version "$1" && valid_version "$2" || return 1
  local i x y ap='' bp=''
  local -a a b
  IFS=. read -ra a <<<"${1%%-*}"; IFS=. read -ra b <<<"${2%%-*}"
  for i in 0 1 2; do
    [ "${a[$i]}" -gt "${b[$i]}" ] && return 0
    [ "${a[$i]}" -lt "${b[$i]}" ] && return 1
  done
  [[ $1 == *-* ]] && ap=${1#*-}; [[ $2 == *-* ]] && bp=${2#*-}
  [ -n "$ap" ] || return 0
  [ -n "$bp" ] || return 1
  IFS=. read -ra a <<<"$ap"; IFS=. read -ra b <<<"$bp"
  for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
    [ "$i" -lt "${#a[@]}" ] || return 1
    [ "$i" -lt "${#b[@]}" ] || return 0
    x=${a[$i]} y=${b[$i]}; [ "$x" != "$y" ] || continue
    if [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]; then
      [ "${#x}" -eq "${#y}" ] || { [ "${#x}" -gt "${#y}" ]; return; }
      [[ $x > $y ]]; return
    elif [[ $x =~ ^[0-9]+$ ]]; then return 1
    elif [[ $y =~ ^[0-9]+$ ]]; then return 0
    else LC_ALL=C test "$x" \> "$y"; return; fi
  done
  return 0
}
proto_name() {
  case $1 in
    socks) printf SOCKS5;; shadowsocks) printf Shadowsocks;; vless) printf VLESS;; hysteria2) printf Hysteria2;;
    anytls) printf AnyTLS;; tuic) printf TUIC;; snell) printf Snell;; *) return 1;;
  esac
}
proto_tls() { case $1 in vless|hysteria2|anytls|tuic) return 0;; *) return 1;; esac; }
proto_alpn() { case $1 in vless) printf '["http/1.1"]';; hysteria2|tuic) printf '["h3"]';; *) printf '[]';; esac; }
proto_fields() {
  local -n _field_keys=$2 _field_labels=$3
  _field_keys=(port); _field_labels=(端口)
  case $1 in
    socks) _field_keys+=(user pass); _field_labels+=(用户名 密码);;
    shadowsocks) _field_keys+=(method pass); _field_labels+=(加密 密码);;
    vless) _field_keys+=(uuid); _field_labels+=(UUID);;
    hysteria2|anytls) _field_keys+=(pass); _field_labels+=(密码);;
    tuic) _field_keys+=(uuid pass); _field_labels+=(UUID 密码);;
    snell) _field_keys+=(version psk); _field_labels+=(版本 PSK);;
  esac
  if proto_tls "$1"; then _field_keys+=(sni); _field_labels+=(SNI); fi
  case $1 in
    vless) _field_keys+=(flow); _field_labels+=(流控);;
    tuic) _field_keys+=(cc); _field_labels+=(拥塞);;
    hysteria2) _field_keys+=(hcc); _field_labels+=(拥塞);;
  esac
  if proto_tls "$1"; then _field_keys+=(tls); _field_labels+=(证书); fi
  _field_keys+=(name); _field_labels+=(备注)
}
proto_random() {
  local length=$1 value='' chunk
  while [ "${#value}" -lt "$length" ]; do
    chunk=$(openssl rand -base64 "$length") || return 1
    value+=${chunk//[^A-Za-z0-9]/}
  done
  printf '%s' "${value:0:length}"
}
proto_uuid() { local uuid; IFS= read -r uuid </proc/sys/kernel/random/uuid && printf '%s' "$uuid"; }
proto_ss_keylen() {
  case $1 in 2022-blake3-aes-128-gcm) printf 16;; 2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf 32;; *) printf 0;; esac
}
proto_ss_password() {
  local size; size=$(proto_ss_keylen "$1")
  if [ "$size" -gt 0 ]; then openssl rand -base64 "$size" | tr -d '\n'; else proto_random 20; fi
}
proto_ss_valid() {
  local size decoded
  size=$(proto_ss_keylen "$1")
  [ "$size" -gt 0 ] || { valid_nonempty "$2"; return; }
  # 先检查编码形态，再检查解码长度；不把 base64 的失败藏在管道中。
  [[ $2 =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && [ "$((${#2}%4))" -eq 0 ] || return 1
  decoded=$(printf %s "$2" | openssl base64 -d -A | od -An -v -tx1 | tr -d ' \n') || return 1
  [ "${#decoded}" -eq "$((size*2))" ]
}
proto_build() {
  local proto=$1 tag=$2 port=$3 tls_json=${4:-\{\}} method=${5:-aes-128-gcm} version=${6:-6} obfs_mode=${7:-none} secret='' id='' user=''
  case $proto in
    socks) user=$(proto_random 8) || return 1;;
    vless|tuic) id=$(proto_uuid) || return 1;;
  esac
  case $proto in
    vless) ;;
    shadowsocks) secret=$(proto_ss_password "$method") || return 1;;
    *) secret=$(proto_random 24) || return 1;;
  esac
  SB_SECRET=$secret SB_USER=$user SB_UUID=$id jq -n \
    --arg p "$proto" --arg t "$tag" --argjson port "$port" --arg listen "$(net_listen)" --arg m "$method" --argjson tls "$tls_json" --argjson sv "$version" --arg so "$obfs_mode" '
    {type:$p,tag:$t,listen:$listen,listen_port:$port}
    + (if $p=="socks" then {users:[{username:env.SB_USER,password:env.SB_SECRET}]}
       elif $p=="shadowsocks" then {method:$m,password:env.SB_SECRET}
       elif $p=="snell" then {version:$sv,psk:env.SB_SECRET} + (if $sv==5 then {obfs_mode:$so} else {} end)
       elif $p=="vless" then {tls:$tls,users:[{name:"user",uuid:env.SB_UUID,flow:"xtls-rprx-vision"}]}
       elif $p=="tuic" then {tls:$tls,users:[{name:"user",uuid:env.SB_UUID,password:env.SB_SECRET}],congestion_control:"cubic"}
       else {tls:$tls,users:[{name:"user",password:env.SB_SECRET}]} end)'
}

# 3. 网络。探测失败与“未占用”分开返回；端口检测：0 占用，1 空闲，2 失败。
net_bare_ip() { local value=$1; value=${value#[}; value=${value%]}; printf '%s' "${value%%%*}"; }
net_norm_ip() {
  local value left right group result='' i v4 h1 h2
  local -a lhs=() rhs=() groups=() octets
  value=$(net_bare_ip "$1"); value=${value,,}
  if [[ $value != *:* ]]; then valid_ip "$value" || return 1; printf '%s' "$value"; return 0; fi
  if [[ $value == *.* ]]; then
    v4=${value##*:}; valid_ip "$v4" || return 1
    IFS=. read -ra octets <<<"$v4"
    printf -v h1 '%x' "$((10#${octets[0]}*256+10#${octets[1]}))"
    printf -v h2 '%x' "$((10#${octets[2]}*256+10#${octets[3]}))"
    value=${value%:*}:$h1:$h2
  fi
  [[ $value != *[^0-9a-f:]* && $value != *:::* ]] || return 1
  if [[ $value == *::* ]]; then
    left=${value%%::*}; right=${value#*::}; [[ $right != *::* ]] || return 1
    [[ $left != :* && $left != *: && $right != :* && $right != *: ]] || return 1
    [ -z "$left" ] || IFS=: read -ra lhs <<<"$left"
    [ -z "$right" ] || IFS=: read -ra rhs <<<"$right"
    [ "$((${#lhs[@]}+${#rhs[@]}))" -lt 8 ] || return 1
    groups=("${lhs[@]}")
    for ((i=${#lhs[@]}+${#rhs[@]}; i<8; i++)); do groups+=(0); done
    groups+=("${rhs[@]}")
  else
    [[ $value != :* && $value != *: ]] || return 1
    IFS=: read -ra groups <<<"$value"
  fi
  [ "${#groups[@]}" -eq 8 ] || return 1
  for group in "${groups[@]}"; do
    [[ $group =~ ^[0-9a-f]{1,4}$ ]] || return 1
    printf -v group '%04x' "$((16#$group))"; result+=${result:+:}$group
  done
  printf '%s' "$result"
}
valid_ip() {
  local octet
  local -a octets
  if [[ $1 == *:* ]]; then net_norm_ip "$1" >/dev/null; return; fi
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -ra octets <<<"$1"
  for octet in "${octets[@]}"; do
    [ "$((10#$octet))" -le 255 ] && [ "$octet" = "$((10#$octet))" ] || return 1
  done
}
net_public() {
  valid_ip "$2" || return 1
  local value second first
  if [ "$1" = 6 ]; then
    value=$(net_norm_ip "$2") || return 1
    case $value in 2001:0db8:*|2001:0002:*) return 1;; 2*|3*) return 0;; *) return 1;; esac
  fi
  [[ $2 != *:* ]] || return 1
  case $2 in
    0.*|10.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|192.0.0.*|192.0.2.*|198.51.100.*|203.0.113.*) return 1;;
  esac
  IFS=. read -r first second _ <<<"$2"
  [ "$first" -lt 224 ] || return 1
  if [ "$first" = 100 ] && [ "$second" -ge 64 ] && [ "$second" -le 127 ]; then return 1; fi
  if [ "$first" = 198 ] && { [ "$second" = 18 ] || [ "$second" = 19 ]; }; then return 1; fi
  return 0
}
net_local_public() {
  local value
  while IFS= read -r value; do
    net_public "$1" "$value" && { printf '%s' "$value"; return 0; }
  done < <(ip -"$1" -o addr show scope global 2>/dev/null | awk '
    /temporary|deprecated|dadfailed|tentative/ {next}
    {for(i=1;i<=NF;i++) if($i=="inet"||$i=="inet6"){split($(i+1),a,"/");print a[1];break}}')
  return 1
}
net_curl_ip() {
  local family=$1 url result; shift
  for url in "$@"; do
    result=$(curl -"$family" -fsS --connect-timeout 2 -m 3 "$url" 2>/dev/null) || continue
    result=${result//[$' \t\r\n']/}
    net_public "$family" "$result" && { printf '%s' "$result"; return 0; }
  done
  return 1
}
net_get_ip() {
  [ -z "$SERVER_IP4$SERVER_IP6" ] || return 0
  local p4 p6 v4 v6 address
  v4=$(mktemp "$RUNTIME_DIR/ip4.XXXXXX") && v6=$(mktemp "$RUNTIME_DIR/ip6.XXXXXX") || return 1
  net_curl_ip 4 https://api.ipify.org https://ipv4.icanhazip.com >"$v4" & p4=$!
  net_curl_ip 6 https://api6.ipify.org https://ipv6.icanhazip.com >"$v6" & p6=$!
  wait "$p4" || true; wait "$p6" || true
  SERVER_IP4=$(<"$v4"); SERVER_IP6=$(<"$v6"); rm -f "$v4" "$v6"
  [ -n "$SERVER_IP4" ] || SERVER_IP4=$(net_local_public 4) || true
  [ -n "$SERVER_IP6" ] || SERVER_IP6=$(net_local_public 6) || true
  while [ -z "$SERVER_IP4$SERVER_IP6" ]; do
    ui_ask address '无法获取公网 IP，请手动输入' '' || return 2
    address=$(net_bare_ip "$address")
    valid_ip "$address" || { ui_soft 'IP 格式不正确'; continue; }
    if [[ $address == *:* ]]; then SERVER_IP6=$address; else SERVER_IP4=$address; fi
  done
}
net_ours() {
  local normalized candidate
  normalized=$(net_norm_ip "$1") || return 1
  for candidate in "$SERVER_IP4" "$SERVER_IP6"; do
    [ -n "$candidate" ] && [ "$(net_norm_ip "$candidate")" = "$normalized" ] && return 0
  done
  return 1
}
net_resolve() {
  local result=''
  if command -v getent >/dev/null 2>&1; then
    result=$(getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u)
  fi
  if [ -z "$result" ] && command -v nslookup >/dev/null 2>&1; then
    result=$(nslookup "$1" 2>/dev/null | awk '
      /^Name:/ {found=1; next}
      found && /^Address[0-9]*:/ {print $2}
      found && /^Address [0-9]+:/ {print $3}' | sort -u)
  fi
  local value
  while IFS= read -r value; do valid_ip "$value" && printf '%s\n' "$value"; done <<<"$result"
  return 0
}
net_listen() {
  local value
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
    IFS= read -r value </proc/sys/net/ipv6/conf/all/disable_ipv6
    if [ "$value" = 0 ]; then printf '::'; return 0; fi
  fi
  printf '0.0.0.0'
}
net_port_used() {
  local result
  command -v ss >/dev/null 2>&1 || { ui_err '缺少 ss，无法检查端口'; return 2; }
  result=$(ss -H -ltun "sport = :$1" 2>/dev/null) || { ui_err '端口检测失败'; return 2; }
  [ -n "$result" ]
}
net_inbound_port() {
  local -a entries
  store_list entries "${2:-$INB_DIR}" || return 1
  jq -se --argjson p "$1" 'any(.[];.inbound.listen_port==$p)' "${entries[@]}" >/dev/null
}
net_random_port() {
  local attempt port status
  for ((attempt=0; attempt<128; attempt++)); do
    port=$(shuf -i 10000-60000 -n 1) || return 1
    net_port_used "$port"; status=$?
    [ "$status" != 2 ] || return 1
    if [ "$status" = 1 ] && ! net_inbound_port "$port"; then printf '%s' "$port"; return 0; fi
  done
  ui_err '未找到空闲端口'; return 1
}
ui_port() {
  local _port _default=${2:-} status
  [ -n "$_default" ] || _default=$(net_random_port) || return 1
  while true; do
    ui_ask _port 监听端口 "$_default" || return 2
    valid_port "$_port" || { ui_soft '端口须为 1-65535'; continue; }
    if [ "$_port" != "${2:-}" ]; then
      net_inbound_port "$_port" && { ui_soft '端口已被其他入站使用'; continue; }
      net_port_used "$_port"; status=$?
      [ "$status" != 2 ] || return 1
      [ "$status" != 0 ] || { ui_soft '端口已被系统占用'; continue; }
      if tls_has_acme "$INB_DIR" && { [ "$_port" = 80 ] || [ "$_port" = 443 ]; }; then ui_soft '80/443 已留给 ACME'; continue; fi
    fi
    printf -v "$1" '%s' "$_port"; return 0
  done
}

# 4. 配置、服务与 release 适配器。
config_build() {
  local source_dir=$1 certificate_dir=$2 output=$3
  local -a entries=()
  store_validate "$source_dir" || return 1
  store_list entries "$source_dir" || entries=(/dev/null)
  # -n + inputs 同时覆盖空目录和多文件；空目录显式读 /dev/null，避免读取终端。
  jq -n --arg ad "$ACME_DIR" --arg cd "$certificate_dir" --arg listen "$(net_listen)" '
    [inputs] as $items |
    {log:{level:"info"},
     dns:{servers:[{type:"tls",tag:"google",server:"8.8.8.8"}]},
     certificate_providers:([$items[]|select(.cert=="acme")|
       {type:"acme",tag:.inbound.tls.certificate_provider,domain:[.domain],data_directory:$ad,provider:"letsencrypt"}
       + (if (.email//"")!="" then {email:.email} else {} end)]|unique_by(.tag)),
     inbounds:[$items[] | . as $record | .inbound | .listen=$listen |
       if $record.cert=="self" then
         .tls.certificate_path=($cd+"/"+.tag+".crt") | .tls.key_path=($cd+"/"+.tag+".key") else . end |
       if .type=="vless" and (.users[0].flow//"")=="xtls-rprx-vision" then .tls.alpn=["http/1.1"] else . end],
     outbounds:[{type:"direct"}],route:{rules:[{port:53,action:"hijack-dns"}]}}
    | if (.certificate_providers|length)==0 then del(.certificate_providers) else . end
  ' "${entries[@]}" >"$output"
}
service_do() (
  local action=$1; shift
  # OpenRC 的 supervisor 不得继承面板锁，否则退出面板后仍会持锁。
  if [ -n "$LOCK_FD" ]; then exec {LOCK_FD}>&-; fi
  if [ "$INIT" = systemd ]; then
    case $action in
      active) systemctl is-active --quiet "$SVC" >/dev/null 2>&1;;
      enabled) systemctl is-enabled --quiet "$SVC" >/dev/null 2>&1;;
      reload) systemctl daemon-reload;;
      logs) if [ "$1" = -f ]; then journalctl -u "$SVC" -f -o cat; else journalctl -u "$SVC" -n "$1" --no-pager -o cat; fi;;
      *) systemctl "$action" "$SVC";;
    esac
  else
    case $action in
      active) rc-service "$SVC" status >/dev/null 2>&1;;
      enabled) [ -L "/etc/runlevels/default/$SVC" ];;
      reload) return 0;;
      enable) rc-update add "$SVC" default;;
      disable) rc-update del "$SVC" default;;
      logs) if [ "$1" = -f ]; then tail -n 20 -f "$LOG"; else tail -n "$1" "$LOG"; fi;;
      *) rc-service "$SVC" "$action";;
    esac
  fi
)
service_process_alive() {
  [ "$INIT" = openrc ] || return 0
  # OpenRC 的 status 可能只确认 supervisor；另查它记录的实际子进程。
  local pid_file=$RUN_ROOT/openrc/options/$SVC/child_pid child executable
  [ -f "$pid_file" ] || return 1
  child=$(<"$pid_file")
  [[ $child =~ ^[1-9][0-9]*$ ]] && kill -0 "$child" 2>/dev/null || return 1
  executable=$(readlink -f "/proc/$child/exe" 2>/dev/null) || return 1
  [ "$executable" = "$BIN" ]
}
service_wait() {
  local desired=${1:-active} count stable=0
  for ((count=0; count<16; count++)); do
    if service_do active; then
      if [ "$desired" != stopped ] && service_process_alive; then stable=$((stable+1)); else stable=0; fi
    else
      [ "$desired" != stopped ] || return 0
      stable=0
    fi
    [ "$stable" -lt 5 ] || return 0
    sleep 0.5
  done
  return 1
}
service_failure() {
  ui_err '服务操作失败，最近日志：'
  service_do logs 15 | sed 's/^/    /' >&2
  return 1
}
service_check() { "$1" check -c "$2"; }
service_render() {
  if [ "$INIT" = openrc ]; then
    cat <<EOF
#!/sbin/openrc-run
name=\$RC_SVCNAME
description="sing-box service"
supervisor=supervise-daemon
command="$BIN"
command_user="$SVC_USER:$SVC_USER"
command_args="-D $STATE_DIR run --disable-color -c $CONF"
directory="$STATE_DIR"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="$LOG"
error_log="$LOG"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 1048576"
depend() { after net dns; }
start_pre() {
    checkpath --directory --owner $SVC_USER:$SVC_USER --mode 0750 $STATE_DIR
    if ! su -s /bin/sh $SVC_USER -c '"$BIN" check -c "$CONF"' >>"$LOG" 2>&1; then
        eerror "配置校验失败，详见 $LOG"
        return 1
    fi
}
EOF
  else
    cat <<EOF
[Unit]
Description=sing-box service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$STATE_DIR
ExecStartPre=$BIN check -c $CONF
ExecStart=$BIN -D $STATE_DIR run -c $CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=$BASE
ReadWritePaths=$ACME_DIR $STATE_DIR

[Install]
WantedBy=multi-user.target
EOF
  fi
}
release_installed() { [ -x "$BIN" ]; }
release_need_core() { release_installed || { ui_warn '请先安装内核'; return 1; }; }
release_core_version() {
  if [ -z "$CORE_VER" ]; then CORE_VER=$("$BIN" version 2>/dev/null | awk 'NR==1{print $3}'); fi
  [ -n "$CORE_VER" ] || return 1
  printf -v "$1" '%s' "$CORE_VER"
}
release_fetch() {
  local requested=${1:-latest} url document fetched
  if [ "$requested" != latest ] && [ "$REL_VER" = "$requested" ] && [ -n "$REL_JSON" ]; then return 0; fi
  url=https://api.github.com/repos/SagerNet/sing-box/releases
  if [ "$requested" = latest ]; then url+=/latest; else valid_version "$requested" || return 1; url+=/tags/v$requested; fi
  document=$(curl -fsSL --connect-timeout 5 -m 20 "$url") || return 1
  fetched=$(jq -er '.tag_name|strings|ltrimstr("v")' <<<"$document") || return 1
  version_ge "$fetched" "$MIN_VER" || return 1
  [ "$requested" = latest ] || [ "$requested" = "$fetched" ] || return 1
  jq -e '.assets|type=="array"' <<<"$document" >/dev/null || return 1
  REL_JSON=$document REL_VER=$fetched
}
release_pick() {
  local _picked=''
  if release_fetch latest; then _picked=$REL_VER
  else
    ui_warn '无法获取符合要求的最新版本信息'
    ui_ask _picked '请手动输入版本号，如 1.14.0' '' || return 2
    _picked=${_picked#v}
  fi
  version_ge "$_picked" "$MIN_VER" || { ui_err "版本需不低于 $MIN_VER"; return 1; }
  printf -v "$1" '%s' "$_picked"
}
release_verify() {
  local archive=$1 asset=$2 version=$3 actual expected
  actual=$(sha256sum "$archive") || return 1; actual=${actual%% *}
  if [ -n "${SINGBOX_SHA256:-}" ]; then expected=${SINGBOX_SHA256,,}
  else
    release_fetch "$version" || { ui_err '无法获取官方摘要，可设置 SINGBOX_SHA256'; return 1; }
    expected=$(jq -er --arg n "$asset" '[.assets[]|select(.name==$n)|.digest]|select(length==1)|.[0]|strings' <<<"$REL_JSON") || return 1
    expected=${expected#sha256:}; expected=${expected,,}
  fi
  [[ $expected =~ ^[0-9a-f]{64}$ ]] && [ "$actual" = "$expected" ] || {
    ui_err '下载摘要校验失败'; return 1;
  }
}
release_download() {
  local version=$1 output=$2 arch work asset member actual
  local -a binaries=()
  arch=$(platform_arch "$(uname -m)") || { ui_err "不支持的 CPU 架构：$(uname -m)"; return 1; }
  asset=sing-box-$version-linux-$arch
  [ "$OS" != alpine ] || asset+=-musl
  asset+=.tar.gz
  work=$(mktemp -d "$RUNTIME_DIR/download.XXXXXX") || return 1
  if ! curl -fL --connect-timeout 10 --max-time 300 --progress-bar -o "$work/core.tgz" \
    "${GH_PROXY:-}https://github.com/SagerNet/sing-box/releases/download/v$version/$asset"; then
    ui_err '下载失败，可设置 GH_PROXY'; rm -rf "$work"; return 1
  fi
  if ! release_verify "$work/core.tgz" "$asset" "$version"; then rm -rf "$work"; return 1; fi
  if ! tar -tzf "$work/core.tgz" >"$work/members"; then rm -rf "$work"; return 1; fi
  while IFS= read -r member; do
    case $member in /*|..|../*|*/../*|*/..) ui_err '压缩包路径不合法'; rm -rf "$work"; return 1;; esac
    case $member in sing-box|*/sing-box) binaries+=("$member");; esac
  done <"$work/members"
  # 只将内核写入候选路径，避免完整解压后再复制一份大文件。
  if [ "${#binaries[@]}" != 1 ] || ! tar -xOzf "$work/core.tgz" "${binaries[0]}" >"$output" || ! chmod 700 "$output"; then
    ui_err '压缩包内核缺失或写入失败'; rm -rf "$work"; rm -f "$output"; return 1
  fi
  actual=$("$output" version 2>/dev/null | awk 'NR==1{print $3}')
  rm -rf "$work"
  [ "$actual" = "$version" ] || { ui_err '下载内核的版本与请求不一致'; rm -f "$output"; return 1; }
}

# 5. 文件事务。JSON 记录只存目标与原状态；备份/暂存路径由序号推导。
# preparing 阶段不修改正式文件；publishing/rolling_back 可以幂等恢复。
txn_record() { store_edit "$TXN_DIR/manifest.json" "$@"; }
txn_phase() { txn_record --arg phase "$1" '.phase=$phase'; }
txn_allowed() {
  local target=$1 leaf
  case $target in
    "$CONF"|"$BIN"|"$UNIT") ;;
    "$INB_DIR/"*.json) leaf=${target#"$INB_DIR/"}; [[ $leaf =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.json$ ]] || return 1;;
    "$CERT_DIR/"*.crt|"$CERT_DIR/"*.key) leaf=${target#"$CERT_DIR/"}; [[ $leaf =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.(crt|key)$ ]] || return 1;;
    *) return 1;;
  esac
  [ ! -L "$target" ] && [ ! -L "${target%/*}" ] && [ ! -L "$BASE" ]
}
txn_begin() {
  [ "$RUNTIME_BLOCKED" = 0 ] && [ -z "$TXN_DIR" ] || { ui_err '存在未恢复事务，不能修改'; return 1; }
  store_validate "$INB_DIR" || return 1
  mkdir -p "$TXN_ROOT" || return 1
  chmod 700 "$TXN_ROOT" || return 1
  TXN_DIR=$(mktemp -d "$TXN_ROOT/txn.XXXXXXXX") || return 1
  local active=false enabled=false
  service_do active && active=true
  service_do enabled && enabled=true
  if ! mkdir "$TXN_DIR/backups" "$TXN_DIR/stage" "$TXN_DIR/inbounds" "$TXN_DIR/certs" \
    || ! jq -n --arg op "$1" --argjson active "$active" --argjson enabled "$enabled" \
       '{version:1,operation:$op,phase:"preparing",active:$active,enabled:$enabled,service_touched:false,paths:[]}' >"$TXN_DIR/manifest.json"; then
    rm -rf "$TXN_DIR"; TXN_DIR=''; return 1
  fi
  local file
  for file in "$INB_DIR"/*.json; do
    [ -f "$file" ] || continue
    cp -p "$file" "$TXN_DIR/inbounds/" || { txn_rollback; return 1; }
  done
  for file in "$CERT_DIR"/*.crt "$CERT_DIR"/*.key; do
    [ -f "$file" ] || continue
    if [ -L "$file" ] || ! cp -p "$file" "$TXN_DIR/certs/"; then txn_rollback; return 1; fi
  done
}
txn_stage() {
  local target=$1 source=${2:-} index exists=false action=write
  [ "$(jq -r .phase "$TXN_DIR/manifest.json")" = preparing ] && txn_allowed "$target" || return 1
  jq -e --arg target "$target" 'any(.paths[];.target==$target)' "$TXN_DIR/manifest.json" >/dev/null && return 1
  index=$(jq '.paths|length' "$TXN_DIR/manifest.json") || return 1
  if [ -e "$target" ]; then
    [ -f "$target" ] && cp -p "$target" "$TXN_DIR/backups/$index" || return 1
    exists=true
  fi
  if [ -n "$source" ]; then
    cp "$source" "$TXN_DIR/stage/$index" && chmod 600 "$TXN_DIR/stage/$index" || return 1
  else action=delete; fi
  txn_record --arg target "$target" --arg action "$action" --argjson exists "$exists" \
    '.paths += [{target:$target,existed:$exists,action:$action}]'
}
txn_stage_tree() {
  local live=$1 staged=$2 file leaf
  for file in "$staged"/*; do
    [ -f "$file" ] || continue
    leaf=${file##*/}; txn_stage "$live/$leaf" "$file" || return 1
  done
  for file in "$live"/*; do
    [ -f "$file" ] || continue
    leaf=${file##*/}
    case $leaf in *.json|*.crt|*.key) [ -f "$staged/$leaf" ] || txn_stage "$file" || return 1;; esac
  done
}
txn_manifest_valid() {
  local target index count phase
  jq -e '
    .version==1 and (.phase|IN("preparing","publishing","rolling_back","committed"))
    and (.active|type=="boolean") and (.enabled|type=="boolean") and (.service_touched|type=="boolean")
    and (.paths|type=="array") and all(.paths[];
      (.target|type=="string") and (.existed|type=="boolean") and (.action|IN("write","delete")))
    and ([.paths[].target]|length==(unique|length))
  ' "$TXN_DIR/manifest.json" >/dev/null || return 1
  count=$(jq '.paths|length' "$TXN_DIR/manifest.json") || return 1
  phase=$(jq -r .phase "$TXN_DIR/manifest.json") || return 1
  for ((index=0; index<count; index++)); do
    target=$(jq -r ".paths[$index].target" "$TXN_DIR/manifest.json") || return 1
    txn_allowed "$target" || return 1
    if { [ "$phase" = publishing ] || [ "$phase" = rolling_back ]; } && jq -e ".paths[$index].existed" "$TXN_DIR/manifest.json" >/dev/null; then
      [ -f "$TXN_DIR/backups/$index" ] && [ ! -L "$TXN_DIR/backups/$index" ] || return 1
    fi
  done
}
txn_copy() {
  local source=$1 target=$2 index=$3 restore=${4:-false} adjacent
  adjacent=$target.sb-${TXN_DIR##*/}-$index
  [ ! -L "$adjacent" ] || return 1
  mkdir -p "${target%/*}" || return 1
  rm -f -- "$adjacent" || return 1
  cp -p "$source" "$adjacent" || return 1
  if [ "$restore" != true ]; then platform_file_mode "$adjacent" "$target" || return 1; fi
  mv -f -- "$adjacent" "$target"
}
txn_publish() {
  local goal=$1 count index target action reload=0 binary=0
  txn_manifest_valid && txn_phase publishing || return 1
  if [ "$goal" != none ]; then
    txn_record '.service_touched=true' || return 1
    # activating/auto-restart 也必须 stop，取消尚未触发的重启任务。
    if [ -f "$UNIT" ] || service_do active; then service_do stop && service_wait stopped || return 1; fi
  fi
  count=$(jq '.paths|length' "$TXN_DIR/manifest.json") || return 1
  for ((index=0; index<count; index++)); do
    target=$(jq -r ".paths[$index].target" "$TXN_DIR/manifest.json") || return 1
    action=$(jq -r ".paths[$index].action" "$TXN_DIR/manifest.json") || return 1
    if [ "$action" = write ]; then txn_copy "$TXN_DIR/stage/$index" "$target" "$index" || return 1
    else rm -f -- "$target" || return 1; fi
    [ "$target" != "$UNIT" ] || reload=1
    [ "$target" != "$BIN" ] || binary=1
  done
  [ "$binary" = 0 ] || { CORE_VER=''; platform_bind || return 1; }
  [ "$reload" = 0 ] || service_do reload || return 1
  if [ "$goal" != none ]; then
    service_check "$BIN" "$CONF" || return 1
    case $goal in
      install) service_do enable || return 1;;
      apply)
        if [ "$(store_count "$INB_DIR")" -gt 0 ]; then service_do start && service_wait active || return 1
        else service_wait stopped || return 1; fi;;
      preserve)
        if jq -e .active "$TXN_DIR/manifest.json" >/dev/null; then service_do start && service_wait active || return 1; fi;;
      *) return 1;;
    esac
  fi
  txn_commit
}
txn_commit() {
  local completed=$TXN_DIR
  txn_phase committed || return 1
  TXN_DIR=''
  rm -rf -- "$completed" || ui_warn "操作已提交，备份清理失败：$completed"
  return 0
}
txn_rollback() {
  [ -n "$TXN_DIR" ] || return 0
  local phase index count target touched reload=0 binary=0
  if ! txn_manifest_valid; then
    ui_err "事务记录或备份不完整，保留现场：$TXN_DIR"; RUNTIME_BLOCKED=1; return 1
  fi
  phase=$(jq -r .phase "$TXN_DIR/manifest.json") || return 1
  if [ "$phase" = committed ] || [ "$phase" = preparing ]; then
    rm -rf -- "$TXN_DIR" || { RUNTIME_BLOCKED=1; return 1; }
    TXN_DIR=''; return 0
  fi
  txn_phase rolling_back || { RUNTIME_BLOCKED=1; return 1; }
  touched=$(jq -r .service_touched "$TXN_DIR/manifest.json") || return 1
  if [ "$touched" = true ]; then
    if [ -f "$UNIT" ] || service_do active; then
      if ! service_do stop || ! service_wait stopped; then
        ui_err "回滚时无法停止服务，保留备份：$TXN_DIR"; RUNTIME_BLOCKED=1; return 1
      fi
    fi
    if ! jq -e .enabled "$TXN_DIR/manifest.json" >/dev/null && service_do enabled; then
      service_do disable || { RUNTIME_BLOCKED=1; return 1; }
    fi
  fi
  count=$(jq '.paths|length' "$TXN_DIR/manifest.json") || return 1
  for ((index=count-1; index>=0; index--)); do
    target=$(jq -r ".paths[$index].target" "$TXN_DIR/manifest.json") || return 1
    if jq -e ".paths[$index].existed" "$TXN_DIR/manifest.json" >/dev/null; then
      if ! txn_copy "$TXN_DIR/backups/$index" "$target" "$index" true; then
        ui_err "文件恢复失败：$target；备份：$TXN_DIR"; RUNTIME_BLOCKED=1; return 1
      fi
    elif ! rm -f -- "$target"; then RUNTIME_BLOCKED=1; return 1; fi
    rm -f -- "$target.sb-${TXN_DIR##*/}-$index" || true
    [ "$target" != "$UNIT" ] || reload=1
    [ "$target" != "$BIN" ] || binary=1
  done
  [ "$binary" = 0 ] || { CORE_VER=''; platform_bind || { RUNTIME_BLOCKED=1; return 1; }; }
  [ "$reload" = 0 ] || service_do reload || { RUNTIME_BLOCKED=1; return 1; }
  if [ "$touched" = true ]; then
    if jq -e .enabled "$TXN_DIR/manifest.json" >/dev/null; then service_do enable || { RUNTIME_BLOCKED=1; return 1; }; fi
    if jq -e .active "$TXN_DIR/manifest.json" >/dev/null; then
      service_do start && service_wait active || { service_failure; ui_err "旧文件已恢复，服务未恢复；备份：$TXN_DIR"; RUNTIME_BLOCKED=1; return 1; }
    fi
  fi
  # 标记后再清理，清理中断不会在下一次运行重复服务恢复。
  txn_commit || { RUNTIME_BLOCKED=1; return 1; }
  ui_warn '已恢复原文件和操作前的服务状态'
}
txn_recover() {
  local directory
  [ -d "$TXN_ROOT" ] || return 0
  for directory in "$TXN_ROOT"/txn.*; do
    [ -d "$directory" ] || continue
    [ ! -L "$directory" ] || { ui_err "事务目录不能是符号链接：$directory"; RUNTIME_BLOCKED=1; return 1; }
    TXN_DIR=$directory
    # manifest 在任何发布前创建；没有它的目录只可能是未完成的准备。
    if [ ! -e "$TXN_DIR/manifest.json" ]; then
      rm -rf -- "$TXN_DIR" || return 1; TXN_DIR=''; continue
    fi
    ui_warn "检测到遗留事务：$TXN_DIR"
    txn_rollback || return 1
  done
}

# 6. 证书和交互式编辑。生成只作用于事务中的证书目录。
tls_has_acme() {
  local -a entries
  store_list entries "${1:-$INB_DIR}" || return 1
  jq -se 'any(.[];.cert=="acme")' "${entries[@]}" >/dev/null
}
tls_require_ports() {
  local port=$1 file other
  local -a entries=()
  [ "$port" != 80 ] || { ui_err 'ACME 需要空闲的 80 端口'; return 1; }
  store_list entries || true
  for file in "${entries[@]}"; do
    other=$(jq -r .inbound.listen_port "$file") || return 1
    if [ "$other" = 80 ] || { [ "$other" = 443 ] && [ "$port" != 443 ]; }; then
      ui_err 'ACME 需要空闲的 80；443 只能由本入站占用'; return 1
    fi
  done
}
tls_warn_port() {
  local port=$1 sockets socket pid executable foreign=0
  sockets=$(ss -H -ltnp "sport = :$port" 2>/dev/null) || { ui_err '无法检测 ACME 端口'; return 1; }
  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    executable=''
    if [[ $socket =~ pid=([0-9]+) ]]; then
      pid=${BASH_REMATCH[1]}; executable=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || true
    fi
    [ "$executable" = "$BIN" ] || foreign=1
  done <<<"$sockets"
  [ "$foreign" = 0 ] || { ui_warn "端口 $port 被其他进程占用，验证可能失败"; return 1; }
}
ui_check_domain() {
  local domain=$1 result ip hit=0 bad=0 foreign='' typed
  net_get_ip || return $?
  result=$(net_resolve "$domain") || return 1
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    if net_ours "$ip"; then hit=1; else foreign+="${foreign:+ }$ip"; fi
  done <<<"$result"
  if [ -z "$result" ]; then ui_warn '域名尚无解析，无法签发'; bad=1
  elif [ "$hit" = 0 ]; then ui_warn "域名解析未指向本机（${SERVER_IP4:-} ${SERVER_IP6:-}）"; bad=1
  elif [ -n "$foreign" ]; then ui_warn "仍有解析未指向本机：$foreign"; bad=1; fi
  tls_warn_port 80 || bad=1; tls_warn_port 443 || bad=1
  if [ "$bad" = 0 ]; then ui_confirm '继续申请？' y; return; fi
  ui_warn '继续申请可能失败'
  ui_ask typed "继续请原样输入 $domain" '' || return 2
  [ "$typed" = "$domain" ] || { ui_warn '输入不一致，已取消'; return 2; }
}
ui_tls() {
  local _tls_choice _tls_mode=self _tls_domain _tls_email=''
  printf '  1  自签名\n  2  域名证书\n\n'
  ui_select _tls_choice 2 || return 2
  if [ "$_tls_choice" = 2 ]; then
    _tls_mode=acme
    tls_require_ports "$2" || return 1
    while true; do
      ui_ask _tls_domain 域名 '' || return 2
      valid_domain "$_tls_domain" && break
      ui_soft '域名格式不正确'
    done
    ui_check_domain "$_tls_domain" || return $?
    while true; do
      ui_ask _tls_email '邮箱（可选，到期通知）' '' || return 2
      [[ -z $_tls_email || $_tls_email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
      ui_soft '邮箱格式不正确'
    done
  else
    while true; do
      ui_ask _tls_domain SNI www.gnu.org || return 2
      _tls_domain=$(net_bare_ip "$_tls_domain")
      { valid_domain "$_tls_domain" || valid_ip "$_tls_domain"; } && break
      ui_soft 'SNI 须为域名或 IP'
    done
  fi
  local _tls_result
  _tls_result=$(jq -nc --arg m "$_tls_mode" --arg d "$_tls_domain" --arg e "$_tls_email" '{mode:$m,domain:$d,email:$e}') || return 1
  printf -v "$1" '%s' "$_tls_result"
}
tls_generate() {
  local directory=$1 tag=$2 name=$3 work san
  if valid_ip "$name"; then san=IP:$name
  elif valid_domain "$name"; then san=DNS:$name
  else return 1; fi
  work=$(mktemp -d "$directory/.cert.XXXXXX") || return 1
  if ! openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=$name" -addext "subjectAltName=$san" -addext 'basicConstraints=CA:FALSE' \
    -keyout "$work/key" -out "$work/crt" 2>"$work/error"; then
    ui_err '自签名证书生成失败'; rm -rf "$work"; return 1
  fi
  if ! chmod 600 "$work/key" "$work/crt" || ! mv -f "$work/key" "$directory/$tag.key" || ! mv -f "$work/crt" "$directory/$tag.crt"; then
    rm -rf "$work"; return 1
  fi
  rm -rf "$work"
}
tls_build() {
  local tag=$1 proto=$2 mode=$3 domain=$4 directory=$5
  if [ "$mode" != acme ]; then tls_generate "$directory" "$tag" "$domain" || return 1; fi
  jq -nc --arg d "$domain" --arg m "$mode" --arg c "$CERT_DIR/$tag" --argjson a "$(proto_alpn "$proto")" '
    {enabled:true,server_name:$d} + (if ($a|length)>0 then {alpn:$a} else {} end)
    + (if $m=="acme" then {certificate_provider:("acme-"+($d|gsub("[:/]";"-")))}
       else {certificate_path:($c+".crt"),key_path:($c+".key")} end)'
}
tls_fingerprint() {
  local hex
  [ -f "$1" ] || return 1
  hex=$(openssl x509 -in "$1" -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print tolower($NF)}') || return 1
  [[ $hex =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$hex"
}
tls_forget() {
  local domain=$1 file status=0
  local -a entries=()
  [ -n "$domain" ] && [ -d "$ACME_DIR/certificates" ] || return 0
  store_validate "$INB_DIR" || return 1
  store_list entries || true
  if [ "${#entries[@]}" -gt 0 ] && jq -se --arg d "$domain" 'any(.[];.cert=="acme" and .domain==$d)' "${entries[@]}" >/dev/null; then return 0; fi
  # certmagic 的 certificates 子树只含证书；保留 ACME 账户、锁及其他域名。
  while IFS= read -r -d '' file; do rm -rf -- "$file" || status=1; done \
    < <(find "$ACME_DIR/certificates" -type d -name "$domain" -prune -print0)
  [ "$status" = 0 ] || ui_warn "证书缓存清理失败，数据已保留：$domain"
  return "$status"
}
ui_ss_method() {
  local _method_choice i
  local -a methods=(2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-128-gcm aes-256-gcm chacha20-ietf-poly1305)
  for i in "${!methods[@]}"; do printf '  %d  %s\n' "$((i+1))" "${methods[$i]}"; done
  printf '\n'; ui_select _method_choice "${#methods[@]}" '使用 2022-blake3-aes-128-gcm' 1 || return 2
  printf -v "$1" '%s' "${methods[$((_method_choice-1))]}"
}
ui_snell_options() {
  local _snell_choice _version=${3:-6} _obfs=${4:-none} _version_default _obfs_default
  local _selected_version _selected_obfs=none
  printf '  1  Snell v5\n  2  Snell v6\n\n'
  [ "$_version" = 5 ] && _version_default=1 || _version_default=2
  ui_select _snell_choice 2 "使用 Snell v$_version" "$_version_default" || return 2
  [ "$_snell_choice" = 1 ] && _selected_version=5 || _selected_version=6
  if [ "$_selected_version" = 5 ]; then
    printf '  1  不启用 HTTP 混淆\n  2  HTTP 混淆\n\n'
    [ "$_obfs" = http ] && _obfs_default=2 || _obfs_default=1
    if ui_select _snell_choice 2 '使用当前混淆设置' "$_obfs_default"; then
      [ "$_snell_choice" != 2 ] || _selected_obfs=http
    else return 2; fi
  fi
  printf -v "$1" '%s' "$_selected_version"
  printf -v "$2" '%s' "$_selected_obfs"
}
ui_positive() {
  local _positive
  while true; do
    ui_ask _positive "$2" "$3" || return 2
    if valid_positive "$_positive"; then printf -v "$1" '%s' "$_positive"; return 0; fi
    ui_soft '须为正整数（最多 9 位）'
  done
}
ui_edit_value() {
  local file=$1 title=$2 path=$3 validator=$4 message=$5 current value blank=0; shift 5
  current=$(jq -r "$path" "$file") || return 1
  while true; do
    ui_read value "  $title [$current]: " || return 2
    if [ -z "$value" ]; then
      ui_soft "$message"
      [ "$blank" = 0 ] || return 2
      blank=1; continue
    fi
    blank=0
    "$validator" "$@" "$value" && break
    ui_soft "$message"
  done
  [ "$value" != "$current" ] || return 2
  SB_SECRET=$value store_edit "$file" "$path=env.SB_SECRET"
}
proto_edit_tls() {
  local file=$1 field=$2 directory=$3 tag proto mode domain email old_mode old_domain old_email chosen tls_json
  tag=$(jq -r .inbound.tag "$file"); proto=$(jq -r .proto "$file")
  old_mode=$(jq -r .cert "$file"); old_domain=$(jq -r .domain "$file"); old_email=$(jq -r '.email//""' "$file")
  if [ "$field" = tls ]; then
    ui_tls chosen "$(jq -r .inbound.listen_port "$file")" || return $?
    mode=$(jq -r .mode <<<"$chosen"); domain=$(jq -r .domain <<<"$chosen"); email=$(jq -r .email <<<"$chosen")
  else
    mode=$old_mode email=$old_email
    ui_ask domain SNI "$old_domain" || return 2
    domain=$(net_bare_ip "$domain")
    [ "$domain" != "$old_domain" ] || return 2
    if [ "$mode" = acme ]; then
      valid_domain "$domain" || { ui_err '域名格式不正确'; return 1; }
      ui_check_domain "$domain" || return $?
    else valid_domain "$domain" || valid_ip "$domain" || { ui_err 'SNI 须为域名或 IP'; return 1; }; fi
  fi
  if [ "$mode" = "$old_mode" ] && [ "$domain" = "$old_domain" ] && { [ "$mode" = self ] || [ "$email" = "$old_email" ]; }; then return 2; fi
  tls_json=$(tls_build "$tag" "$proto" "$mode" "$domain" "$directory") || return 1
  store_edit "$file" --argjson tls "$tls_json" --arg m "$mode" --arg d "$domain" --arg e "$email" \
    '.inbound.tls=$tls|.cert=$m|.domain=$d|.email=$e' || return 1
  if [ "$mode" = acme ]; then rm -f "$directory/$tag.crt" "$directory/$tag.key" || return 1; fi
}
proto_edit() {
  local file=$1 field=$2 directory=$3 current value choice method port proto up down up0 down0 version obfs
  case $field in
    port)
      current=$(jq -r .inbound.listen_port "$file"); ui_port port "$current" || return $?
      [ "$port" != "$current" ] || return 2
      store_edit "$file" --argjson p "$port" '.inbound.listen_port=$p';;
    name)
      current=$(jq -r .name "$file"); ui_ask value 新备注 "$current" || return 2
      [ "$value" != "$current" ] || return 2
      store_edit "$file" --arg name "$value" '.name=$name';;
    user) ui_edit_value "$file" 用户名 '.inbound.users[0].username' valid_nonempty 用户名不能为空;;
    uuid) ui_edit_value "$file" UUID '.inbound.users[0].uuid' valid_uuid 'UUID 格式不正确';;
    version)
      current=$(jq -r .inbound.version "$file"); up0=$(jq -r '.inbound.obfs_mode//"none"' "$file")
      ui_snell_options version obfs "$current" "$up0" || return 2
      [ "$version:$obfs" != "$current:$up0" ] || return 2
      if [ "$version" = 5 ]; then
        store_edit "$file" --argjson version "$version" --arg obfs "$obfs" '.inbound.version=$version|.inbound.obfs_mode=$obfs'
      else store_edit "$file" --argjson version "$version" 'del(.inbound.obfs_mode)|.inbound.version=$version'; fi;;
    psk) ui_edit_value "$file" 'PSK（12-255 位）' '.inbound.psk' valid_psk 'PSK 长度须为 12-255';;
    pass)
      proto=$(jq -r .proto "$file")
      if [ "$proto" = shadowsocks ]; then
        method=$(jq -r .inbound.method "$file")
        ui_edit_value "$file" 密码 '.inbound.password' proto_ss_valid 密码格式不正确 "$method"
      else ui_edit_value "$file" 密码 '.inbound.users[0].password' valid_nonempty 密码不能为空; fi;;
    method)
      current=$(jq -r .inbound.method "$file"); ui_ss_method method || return 2
      [ "$method" != "$current" ] || return 2
      value=$(proto_ss_password "$method") || return 1
      SB_SECRET=$value store_edit "$file" --arg m "$method" '.inbound.method=$m|.inbound.password=env.SB_SECRET';;
    tls|sni) proto_edit_tls "$file" "$field" "$directory";;
    flow)
      current=$(jq -r '.inbound.users[0].flow//""' "$file")
      printf '  1  xtls-rprx-vision\n  2  无\n\n'; ui_select choice 2 || return 2
      value=''; [ "$choice" != 1 ] || value=xtls-rprx-vision
      [ "$value" != "$current" ] || return 2
      store_edit "$file" --arg value "$value" 'if $value=="" then del(.inbound.users[0].flow) else .inbound.users[0].flow=$value end';;
    cc)
      current=$(jq -r '.inbound.congestion_control//"cubic"' "$file")
      printf '  1  cubic\n  2  new_reno\n  3  bbr\n\n'; ui_select choice 3 || return 2
      case $choice in 1) value=cubic;; 2) value=new_reno;; 3) value=bbr;; esac
      [ "$value" != "$current" ] || return 2
      store_edit "$file" --arg value "$value" '.inbound.congestion_control=$value';;
    hcc)
      current=$(jq -r 'if .inbound.ignore_client_bandwidth==true then "1" elif (.inbound.up_mbps and .inbound.down_mbps) then "2" else "3" end' "$file")
      printf '  1  BBR\n  2  Brutal\n  3  不限制\n\n'; ui_select choice 3 || return 2
      if [ "$choice" = 2 ]; then
        up0=$(jq -r '.inbound.up_mbps//100' "$file"); down0=$(jq -r '.inbound.down_mbps//100' "$file")
        printf '  服务器带宽：上行=客户端下载，下行=客户端上传\n'
        ui_positive up '服务端上行 Mbps' "$up0" && ui_positive down '服务端下行 Mbps' "$down0" || return 2
        [ "$current:$up0:$down0" != "2:$up:$down" ] || return 2
        store_edit "$file" --argjson up "$up" --argjson down "$down" \
          'del(.inbound.ignore_client_bandwidth)|.inbound.up_mbps=$up|.inbound.down_mbps=$down'
      else
        [ "$current" != "$choice" ] || return 2
        store_edit "$file" --arg choice "$choice" 'del(.inbound.up_mbps,.inbound.down_mbps,.inbound.ignore_client_bandwidth)
          | if $choice=="1" then .inbound.ignore_client_bandwidth=true else . end'
      fi;;
    *) return 1;;
  esac
}

# 7. 业务：只编辑事务副本，正式路径的写入由 txn_publish 负责。
app_guard() {
  if [ "$RUNTIME_BLOCKED" != 0 ] || [ -n "$TXN_DIR" ]; then
    ui_err "恢复尚未完成，请处理保留的事务：$TXN_DIR"; return 1
  fi
}
app_prepare() {
  app_guard && platform_user && platform_dirs || { ui_err '无法准备服务用户、目录或权限'; return 1; }
}
app_stage_config() {
  local candidate=$1
  config_build "$TXN_DIR/inbounds" "$TXN_DIR/certs" "$TXN_DIR/check.json" || return 1
  if ! service_check "$candidate" "$TXN_DIR/check.json" >"$TXN_DIR/check.log" 2>&1; then
    ui_err '配置校验未通过：'; sed 's/^/    /' "$TXN_DIR/check.log" >&2; return 1
  fi
  config_build "$TXN_DIR/inbounds" "$CERT_DIR" "$TXN_DIR/config.json" || return 1
  service_render >"$TXN_DIR/unit" || return 1
  txn_stage_tree "$CERT_DIR" "$TXN_DIR/certs" && txn_stage_tree "$INB_DIR" "$TXN_DIR/inbounds" \
    && txn_stage "$CONF" "$TXN_DIR/config.json" && txn_stage "$UNIT" "$TXN_DIR/unit" || return 1
  if [ "$candidate" != "$BIN" ]; then txn_stage "$BIN" "$candidate" || return 1; fi
}
app_finish() {
  local goal=$1 candidate=${2:-$BIN}
  if app_stage_config "$candidate"; then
    if txn_publish "$goal"; then return 0; fi
    service_failure || true
  fi
  ui_err '操作未完成，正在恢复'
  txn_rollback
  return 1
}
app_install() {
  ui_page 安装内核
  app_prepare || return 1
  if release_installed; then
    ui_warn '已安装内核；升级请使用「升级内核」'
    txn_begin repair && app_finish preserve || return 1
    ui_ok '服务配置已检查'; return 0
  fi
  local version candidate
  release_pick version || return $?
  candidate=$(mktemp "$RUNTIME_DIR/core.XXXXXX") || return 1
  ui_info "正在下载 sing-box v$version …"
  release_download "$version" "$candidate" || return 1
  txn_begin install && app_finish install "$candidate" || return 1
  rm -f "$candidate"
  ui_ok "安装完成（v$version），添加入站后启动"
}
app_upgrade() {
  ui_page 升级内核
  release_need_core && app_prepare || return 1
  local current version candidate
  release_core_version current || return 1
  release_pick version || return $?
  if [ "$current" = "$version" ]; then
    txn_begin repair && app_finish preserve || return 1
    ui_ok "已是最新版本 v$current"; return 0
  fi
  ui_info "v$current → v$version"
  candidate=$(mktemp "$RUNTIME_DIR/core.XXXXXX") || return 1
  release_download "$version" "$candidate" || return 1
  txn_begin upgrade && app_finish preserve "$candidate" || return 1
  rm -f "$candidate"
  ui_ok "升级完成（v$version）"
}
app_start() {
  ui_page 启动内核
  release_need_core && app_prepare || return 1
  [ "$(store_count "$INB_DIR")" -gt 0 ] || { ui_warn '还没有入站'; return 2; }
  txn_begin start && app_finish apply || return 1
  ui_ok '内核运行中'
}
app_stop() {
  ui_page 停止内核
  app_guard && release_need_core || return 1
  service_do stop && service_wait stopped || { service_failure; return 1; }
  ui_ok '内核已停止'
}
app_uninstall() {
  ui_page 卸载内核
  app_guard && release_need_core || return 1
  ui_confirm '确认卸载 sing-box？' n || return 2
  local purge=0
  ui_confirm '同时删除所有入站与配置？' n && purge=1
  [ "$UI_EOF" = 0 ] || return 2
  service_do stop && service_wait stopped || { service_failure; return 1; }
  if service_do enabled; then service_do disable || { ui_err '停用自启失败，已停止卸载'; return 1; }; fi
  rm -f "$UNIT" "$BIN" || { ui_err '服务已停止，但文件删除失败'; return 1; }
  CORE_VER=''
  service_do reload || { ui_err '文件已删除，但服务管理器重载失败'; return 1; }
  if [ "$purge" = 1 ]; then
    rm -rf -- "$BASE" "$STATE_DIR" || { ui_err '内核已卸载，但配置清理失败'; return 1; }
    if [ "$INIT" = openrc ]; then rm -f "$LOG" || return 1; fi
    platform_remove_user || { ui_err '内核与配置已清除，但用户删除失败'; return 1; }
    ui_ok '已卸载，配置已清除'
  else ui_ok "已卸载，配置保留在 $BASE"; fi
}
app_logs() {
  ui_page 查看日志
  release_need_core || return 1
  local choice
  printf '  1  最近 100 行\n  2  实时日志\n\n'; ui_select choice 2 || return 2
  if [ "$choice" = 2 ]; then
    trap ':' INT
    service_do logs -f
    trap 'exit 130' INT
  else service_do logs 100; HOLD=1; fi
}
ui_pick_inbound() {
  local -a entries=()
  local index choice display
  store_validate "$INB_DIR" || return 1
  store_list entries || { ui_warn '还没有入站'; return 2; }
  for index in "${!entries[@]}"; do
    display=$(jq -r '.name|gsub("[\u0000-\u001f\u007f]";" ")' "${entries[$index]}") || return 1
    printf '  %d  %s\n' "$((index+1))" "$display"
  done
  printf '\n'; ui_select choice "${#entries[@]}" || return 2
  printf -v "$1" '%s' "${entries[$((choice-1))]}"
}
app_with_inbound() {
  local title=$1 action=$2 selected
  release_need_core || return 1
  while [ "$UI_EOF" = 0 ]; do
    ui_page "$title"
    ui_pick_inbound selected || return $?
    "$action" "$selected"
    ui_settle
  done
}
app_add() {
  release_need_core && app_guard || return 1
  local choice index label
  local -a protocols=(socks shadowsocks vless hysteria2 anytls tuic snell)
  while [ "$UI_EOF" = 0 ]; do
    ui_page 添加入站
    for index in "${!protocols[@]}"; do
      label=$(proto_name "${protocols[$index]}")
      proto_tls "${protocols[$index]}" && label+='（TLS）'
      printf '  %d  %s\n' "$((index+1))" "$label"
    done
    printf '\n'
    ui_select choice "${#protocols[@]}" || return 2
    app_add_one "${protocols[$((choice-1))]}"
    ui_settle
  done
}
app_add_one() {
  local proto=$1 port name tag method='' version=6 obfs_mode=none tls_choice mode=none domain='' email='' inbound tls_json='{}'
  app_prepare && store_validate "$INB_DIR" || return 1
  ui_port port || return $?
  ui_ask name 备注名称 "$(proto_name "$proto")-$port" || return 2
  tag=$proto-$(openssl rand -hex 8) || return 1
  [ ! -e "$INB_DIR/$tag.json" ] || { ui_err '入站标识冲突，请重试'; return 1; }
  if [ "$proto" = shadowsocks ]; then ui_ss_method method || return 2; fi
  if [ "$proto" = snell ]; then ui_snell_options version obfs_mode || return 2; fi
  if proto_tls "$proto"; then
    ui_tls tls_choice "$port" || return $?
    mode=$(jq -r .mode <<<"$tls_choice"); domain=$(jq -r .domain <<<"$tls_choice"); email=$(jq -r .email <<<"$tls_choice")
  fi
  txn_begin add || return 1
  if proto_tls "$proto"; then
    tls_json=$(tls_build "$tag" "$proto" "$mode" "$domain" "$TXN_DIR/certs") || { txn_rollback; return 1; }
  fi
  inbound=$(proto_build "$proto" "$tag" "$port" "$tls_json" "$method" "$version" "$obfs_mode") || { txn_rollback; return 1; }
  store_save "$TXN_DIR/inbounds/$tag.json" "$proto" "$name" "$mode" "$domain" "$email" "$inbound" || { txn_rollback; return 1; }
  app_finish apply || return 1
  ui_ok '入站已添加'; ui_share "$INB_DIR/$tag.json"
}
app_modify_one() {
  local file=$1 proto key choice index status staged old_mode old_domain new_mode new_domain
  local -a keys=() labels=()
  app_prepare || return 1
  proto=$(jq -r .proto "$file"); proto_fields "$proto" keys labels
  for index in "${!keys[@]}"; do printf '  %d  %s\n' "$((index+1))" "${labels[$index]}"; done
  printf '\n'; ui_select choice "${#keys[@]}" || return 2
  key=${keys[$((choice-1))]}
  old_mode=$(jq -r .cert "$file"); old_domain=$(jq -r '.domain//""' "$file")
  txn_begin modify || return 1
  staged=$TXN_DIR/inbounds/${file##*/}
  proto_edit "$staged" "$key" "$TXN_DIR/certs"; status=$?
  if [ "$status" != 0 ]; then txn_rollback || return 1; return "$status"; fi
  if [ "$key" = name ]; then
    if ! txn_stage "$file" "$staged" || ! txn_publish none; then txn_rollback; return 1; fi
    ui_ok '修改完成'; return 0
  fi
  new_mode=$(jq -r .cert "$staged"); new_domain=$(jq -r '.domain//""' "$staged")
  app_finish apply || return 1
  if [ "$old_mode" = acme ] && { [ "$new_mode" != acme ] || [ "$old_domain" != "$new_domain" ]; }; then tls_forget "$old_domain" || true; fi
  ui_ok '修改完成'; ui_share "$file"
}
app_delete_one() {
  local file=$1 name tag mode domain
  app_prepare || return 1
  name=$(jq -r .name "$file"); tag=$(jq -r .inbound.tag "$file"); mode=$(jq -r .cert "$file"); domain=$(jq -r '.domain//""' "$file")
  ui_confirm "确认删除「$name」？" n || return 2
  txn_begin delete || return 1
  rm -f "$TXN_DIR/inbounds/${file##*/}" "$TXN_DIR/certs/$tag.crt" "$TXN_DIR/certs/$tag.key" || { txn_rollback; return 1; }
  app_finish apply || return 1
  if [ "$mode" = acme ]; then tls_forget "$domain" || true; fi
  ui_ok "已删除「$name」"
}

# 8. 分享编码与结果页。编码函数不做网络探测或服务操作。
proto_snell_outbound() {
  jq -c --arg host "$2" '
    .inbound.version as $version
    | {type:"snell",tag:.name,server:$host,server_port:.inbound.listen_port,
       version:(if $version==5 then 4 else $version end),psk:.inbound.psk}
    + (if $version==5 then {obfs_mode:(.inbound.obfs_mode//"none")}
       + (if .inbound.obfs_mode=="http" then {obfs_host:"bing.com"} else {} end) else {} end)
  ' "$1"
}
proto_share() {
  local file=$1 fingerprint='' output
  if jq -e '.proto=="vless" and .cert=="self"' "$file" >/dev/null; then
    fingerprint=$(tls_fingerprint "$CERT_DIR/$(jq -r .inbound.tag "$file").crt") || fingerprint=''
  fi
  output=$(jq -r --arg host "$2" --arg fingerprint "$fingerprint" '
    def component: @uri;
    (.proto) as $proto
    | (.name|component) as $name
    | (.inbound.listen_port|tostring) as $port
    | (.domain//"") as $domain
    | ($domain|component) as $sni
    | (if ($host|contains(":")) then "["+$host+"]" else $host end) as $address
    | if $proto=="socks" then
        "socks5://"+(.inbound.users[0].username|component)+":"+(.inbound.users[0].password|component)+"@"+$address+":"+$port+"#"+$name
      elif $proto=="shadowsocks" then
        "ss://"+((.inbound.method+":"+.inbound.password)|@base64|gsub("=";"")|gsub("\\+";"-")|gsub("/";"_"))+"@"+$address+":"+$port+"#"+$name
      elif $proto=="vless" then
        (.inbound.users[0].flow//"") as $flow
        | (if $flow=="xtls-rprx-vision" then "http/1.1" else ((.inbound.tls.alpn//[])|join(",")) end) as $alpn
        | "vless://"+.inbound.users[0].uuid+"@"+$address+":"+$port+"?encryption=none"
          +(if $flow!="" then "&flow="+($flow|component) else "" end)
          +"&security=tls&sni="+$sni+"&type=tcp"
          +(if $alpn!="" then "&alpn="+($alpn|component) else "" end)
          +(if .cert=="self" then "&allowInsecure=1"+(if $fingerprint!="" then "&pcs="+$fingerprint else "" end) else "" end)
          +"#"+$name
      elif $proto=="hysteria2" or $proto=="anytls" then
        (.inbound.users[0].password|component) as $password
        | $proto+"://"+$password+"@"+$address+":"+$port+"/?sni="+$sni
          +(if .cert=="self" then "&insecure=1" else "" end)
          +(if $proto=="hysteria2" and (.inbound.up_mbps|tostring|test("^[1-9][0-9]{0,8}$"))
             and (.inbound.down_mbps|tostring|test("^[1-9][0-9]{0,8}$"))
            then "&upmbps="+(.inbound.down_mbps|tostring)+"&downmbps="+(.inbound.up_mbps|tostring) else "" end)
          +"#"+$name
      elif $proto=="tuic" then
        "tuic://"+(.inbound.users[0].uuid|component)+":"+(.inbound.users[0].password|component)
          +"@"+$address+":"+$port+"/?sni="+$sni+"&alpn=h3&congestion_control="+((.inbound.congestion_control//"cubic")|component)
          +(if .cert=="self" then "&allow_insecure=1" else "" end)+"#"+$name
      elif $proto=="snell" then
        (.inbound.version//6) as $version
        | (.inbound.obfs_mode//"none") as $obfs
        | if (.name|type=="string" and length>0 and (test("[\\n\\r\\t,=]")|not))
          and (.inbound.psk|type=="string" and length>0 and (test("[\\n\\r\\t ,=\"]")|not))
        then .name+" = snell, "+$host+", "+$port+", psk="+.inbound.psk+", version="+($version|tostring)
          +(if $version==5 and $obfs=="http" then ", obfs=http, obfs-host=bing.com" else "" end)
        else "" end
      else error("unsupported protocol") end
  ' "$file") || return $?
  [ -n "$output" ] || return 2
  printf '%s\n' "$output"
}
ui_share() {
  local file=$1 proto name port mode domain host label output duplicate
  local -a hosts=()
  proto=$(jq -r .proto "$file"); name=$(jq -r .name "$file"); port=$(jq -r .inbound.listen_port "$file")
  mode=$(jq -r .cert "$file"); domain=$(jq -r '.domain//""' "$file")
  net_get_ip || return $?
  HOLD=1
  printf '\n  %s%s%s  %s%s%s\n' "$B" "$name" "$N" "$D" "$(proto_name "$proto")" "$N"; ui_line
  ui_kv IPv4 "${SERVER_IP4:-无}"; ui_kv IPv6 "${SERVER_IP6:-无}"; ui_kv 端口 "$port"
  if proto_tls "$proto"; then
    ui_kv SNI "$domain"
    if [ "$mode" = acme ]; then ui_kv 证书 ACME; else ui_kv 证书 自签名; fi
  fi
  case $proto in
    socks) ui_kv 用户 "$(jq -r '.inbound.users[0].username' "$file")"; ui_kv 密码 "$(jq -r '.inbound.users[0].password' "$file")";;
    shadowsocks) ui_kv 加密 "$(jq -r .inbound.method "$file")"; ui_kv 密码 "$(jq -r .inbound.password "$file")";;
    vless) ui_kv UUID "$(jq -r '.inbound.users[0].uuid' "$file")"; ui_kv 流控 "$(jq -r '.inbound.users[0].flow//"无"' "$file")";;
    tuic) ui_kv UUID "$(jq -r '.inbound.users[0].uuid' "$file")"; ui_kv 密码 "$(jq -r '.inbound.users[0].password' "$file")"; ui_kv 拥塞 "$(jq -r '.inbound.congestion_control//"cubic"' "$file")";;
    hysteria2|anytls)
      ui_kv 密码 "$(jq -r '.inbound.users[0].password' "$file")"
      if [ "$proto" = hysteria2 ]; then ui_kv 拥塞 "$(jq -r 'if .inbound.ignore_client_bandwidth==true then "BBR" elif (.inbound.up_mbps and .inbound.down_mbps) then "Brutal \(.inbound.up_mbps)/\(.inbound.down_mbps) Mbps" else "不限制" end' "$file")"; fi;;
    snell)
      ui_kv PSK "$(jq -r .inbound.psk "$file")"
      version=$(jq -r .inbound.version "$file"); ui_kv 版本 "v$version"
      if [ "$version" = 5 ]; then ui_kv 混淆 "$(jq -r '.inbound.obfs_mode//"none"' "$file")"; fi;;
  esac
  if [ "$mode" = acme ]; then hosts+=("$domain"); fi
  for host in "$SERVER_IP4" "$SERVER_IP6"; do
    [ -n "$host" ] || continue
    duplicate=0
    for label in "${hosts[@]}"; do [ "$label" != "$host" ] || duplicate=1; done
    [ "$duplicate" = 1 ] || hosts+=("$host")
  done
  printf '\n  %s分享链接%s\n' "$B" "$N"
  local primary=1
  for host in "${hosts[@]}"; do
    if valid_ip "$host"; then
      if [[ $host == *:* ]]; then label=IPv6; else label=IPv4; fi
    else label=域名; fi
    [ "$primary" = 0 ] || label+='（主）'
    printf '\n  %s%s%s\n' "$D" "$label" "$N"
    if output=$(proto_share "$file" "$host"); then printf '  %s\n' "$output"
    elif [ "$proto" = snell ]; then ui_tip '名称或 PSK 含保留字符，已省略 Surge 行'
    else ui_err '分享内容生成失败'; return 1; fi
    if [ "$proto" = snell ]; then
      printf '  %ssing-box 出站%s\n' "$D" "$N"
      proto_snell_outbound "$file" "$host" | sed 's/^/  /'
    fi
    primary=0
  done
}
ui_home() {
  local state version body
  if release_installed; then
    release_core_version version || version=未知
    version=v$version
    if service_do active && service_process_alive; then state="${G}● 运行中${N}"; else state="${R}○ 已停止${N}"; fi
  else version=未安装; state="${D}○ 未安装${N}"; fi
  body=$'\n'"  ${B}sing-box${N} 管理面板"$'\n'"$RULE"$'\n'
  body+="  $state    $version    入站 $(store_count "$INB_DIR")"$'\n'"$RULE"$'\n'
  if [ -n "$NOTICE" ]; then body+="$NOTICE$RULE"$'\n'; NOTICE=''; fi
  body+=$'\n  1   安装内核      6   查看日志\n  2   升级内核      7   添加入站\n  3   启动内核      8   修改入站\n  4   停止内核      9   分享入站\n  5   卸载内核      10  删除入站\n\n'
  printf '%s%s' "$CLS" "$body"
}
main() {
  if ((BASH_VERSINFO[0]<4 || (BASH_VERSINFO[0]==4 && BASH_VERSINFO[1]<3))); then printf '需要 Bash >= 4.3\n' >&2; return 1; fi
  [ "$(id -u)" = 0 ] || { printf '请使用 root 运行\n' >&2; return 1; }
  runtime_paths ''
  umask 077
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
  platform_detect || return 1
  if ! command -v flock >/dev/null 2>&1; then platform_packages util-linux || return 1; fi
  runtime_lock || return 1
  trap 'runtime_cleanup $?; exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  platform_deps || return 1
  # /run 通常是小容量 tmpfs；下载与候选内核使用磁盘临时目录。
  RUNTIME_DIR=$(mktemp -d /var/tmp/sb-panel.XXXXXX) || return 1
  txn_recover || { RUNTIME_BLOCKED=1; ui_warn "遗留事务未恢复，修改功能已停用；备份：$TXN_DIR"; }
  local choice
  while [ "$UI_EOF" = 0 ]; do
    HOLD=0
    ui_home
    ui_select choice 10 退出 || break
    NOTICE=''
    case $choice in
      1) app_install;; 2) app_upgrade;; 3) app_start;; 4) app_stop;; 5) app_uninstall;;
      6) app_logs;; 7) app_add;; 8) app_with_inbound 修改入站 app_modify_one;;
      9) app_with_inbound 分享入站 ui_share;; 10) app_with_inbound 删除入站 app_delete_one;;
    esac
    ui_settle
  done
  printf '%s' "$CLS"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
