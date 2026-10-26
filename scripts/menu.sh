#!/usr/bin/env bash
set -u

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BASE="$(dirname "$SELF")"

if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E "$SELF" "$@"
  fi
  echo "root privileges required" >&2
  exit 1
fi

XRAY="$BASE/xray"
CONV="$BASE/uri2xray"
CFG_DIR="$BASE/configs"
CURRENT="$BASE/current.json"
ACTIVE_FILE="$BASE/active"
CONF_FILE="$BASE/xclient.conf"
UNIT="xclient"
UNIT_FILE="/etc/systemd/system/$UNIT.service"
LINK="/usr/local/bin/xclient"
METRICS_PORT=11111
PROBE_SOCKS=21808
PROBE_HTTP=21809
PROBE_METRICS=21111
SOCKS_PORT=10808
HTTP_PORT=10809
TEST_URL="https://www.gstatic.com/generate_204"
NO_PROXY_LIST="localhost,127.0.0.1,::1"
ASSUME_YES=0
PICKED=""
LAST_ADDED=""
BEST_FILE=""
PROBE_MS=0

if [[ -f $CONF_FILE ]]; then
  . "$CONF_FILE"
fi

PROXY_URL="http://127.0.0.1:$HTTP_PORT"

if [[ ${1:-} == "-y" ]]; then
  ASSUME_YES=1
  shift
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

COMPS=(apt env curl wget docker git)
APT_FILE="/etc/apt/apt.conf.d/80proxy"
ENV_FILE="/etc/profile.d/proxy.sh"
DOCKER_DIR="/etc/systemd/system/docker.service.d"
DOCKER_FILE="$DOCKER_DIR/http-proxy.conf"
CURLRC="$TARGET_HOME/.curlrc"
WGETRC="$TARGET_HOME/.wgetrc"

for bin in "$XRAY" "$CONV"; do
  if [[ ! -x $bin ]]; then
    echo "missing or not executable: $bin" >&2
    exit 1
  fi
done

mkdir -p "$CFG_DIR"
chmod 700 "$CFG_DIR"

version() {
  cat "$BASE/VERSION" 2>/dev/null || echo dev
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer =~ ^[Yy]$ ]]
}

ask_yes() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local answer
  read -r -p "$1 [Y/n] " answer
  [[ ! $answer =~ ^[Nn]$ ]]
}

as_target() {
  if [[ $TARGET_USER == root ]]; then
    "$@"
  else
    sudo -u "$TARGET_USER" -H "$@"
  fi
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

port_state() {
  if ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; then
    echo up
  else
    echo down
  fi
}

remark_of() {
  local value
  value="$(sed -n 's/^ *"remarks": "\(.*\)",*$/\1/p' "$1" | head -n1)"
  printf '%s' "${value:-$(basename "$1")}"
}

retarget() {
  sed -e 's/"port": 10808,/"port": @S@,/' \
      -e 's/"port": 10809,/"port": @H@,/' \
      -e 's/"port": 11111,/"port": @M@,/' "$1" |
    sed -e "s/@S@/$2/" -e "s/@H@/$3/" -e "s/@M@/$4/"
}

write_current() {
  (umask 077; retarget "$1" "$SOCKS_PORT" "$HTTP_PORT" "$METRICS_PORT" >"$CURRENT.new") &&
    mv -f "$CURRENT.new" "$CURRENT"
}

active_name() {
  [[ -f $ACTIVE_FILE ]] && cat "$ACTIVE_FILE"
}

CONFIGS=()

load_configs() {
  shopt -s nullglob
  CONFIGS=("$CFG_DIR"/*.json)
  shopt -u nullglob
}

list_configs() {
  load_configs
  if [[ ${#CONFIGS[@]} -eq 0 ]]; then
    echo "No saved configs"
    return 1
  fi
  local i=1 f mark active
  active="$(active_name)"
  for f in "${CONFIGS[@]}"; do
    mark=" "
    [[ "$(basename "$f")" == "$active" ]] && mark="*"
    printf '%s %2d) %s\n' "$mark" "$i" "$(remark_of "$f")"
    i=$((i + 1))
  done
}

resolve_config() {
  local arg="${1:-}" f
  load_configs
  if [[ ${#CONFIGS[@]} -eq 0 ]]; then
    echo "No saved configs" >&2
    return 1
  fi
  if [[ -z $arg ]]; then
    list_configs
    read -r -p "Select: " arg
  fi
  if [[ -z $arg ]]; then
    return 1
  fi
  if [[ $arg =~ ^[0-9]+$ ]]; then
    if (( 10#$arg < 1 || 10#$arg > ${#CONFIGS[@]} )); then
      echo "Invalid selection" >&2
      return 1
    fi
    PICKED="${CONFIGS[$((10#$arg - 1))]}"
    return 0
  fi
  for f in "${CONFIGS[@]}"; do
    if [[ "$(basename "$f")" == *"$arg"* || "$(remark_of "$f")" == *"$arg"* ]]; then
      PICKED="$f"
      return 0
    fi
  done
  echo "No match: $arg" >&2
  return 1
}

unit_installed() {
  [[ -f $UNIT_FILE ]]
}

unit_active() {
  systemctl is-active --quiet "$UNIT"
}

write_unit() {
  if [[ $BASE =~ [[:space:]] ]]; then
    echo "install path must not contain spaces: $BASE" >&2
    return 1
  fi
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=xclient Xray proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$XRAY run -test -format json -c $CURRENT
ExecStart=$XRAY run -format json -c $CURRENT
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT_FILE"
  systemctl daemon-reload
}

service_failed() {
  echo "Service failed to start" >&2
  journalctl -u "$UNIT" -n 20 --no-pager >&2
  return 1
}

svc_start() {
  if [[ ! -f $CURRENT ]]; then
    echo "No active config. Add or select one first" >&2
    return 1
  fi
  unit_installed || write_unit || return 1
  systemctl start "$UNIT"
  sleep 1
  if unit_active; then
    echo "Started"
  else
    service_failed
  fi
}

svc_stop() {
  if ! unit_installed; then
    echo "Service not installed" >&2
    return 1
  fi
  systemctl stop "$UNIT"
  echo "Stopped"
}

svc_restart() {
  if [[ ! -f $CURRENT ]]; then
    echo "No active config. Add or select one first" >&2
    return 1
  fi
  unit_installed || write_unit || return 1
  systemctl restart "$UNIT"
  sleep 1
  if unit_active; then
    echo "Restarted"
  else
    service_failed
  fi
}

svc_enable() {
  if [[ ! -f $CURRENT ]]; then
    echo "No active config. Add or select one first" >&2
    return 1
  fi
  unit_installed || write_unit || return 1
  systemctl enable "$UNIT" >/dev/null 2>&1
  echo "Enabled at boot"
}

svc_disable() {
  if ! unit_installed; then
    echo "Service not installed" >&2
    return 1
  fi
  systemctl disable "$UNIT" >/dev/null 2>&1
  echo "Disabled at boot"
}

svc_logs() {
  if [[ ${1:-} == "-f" ]]; then
    journalctl -u "$UNIT" -f
  else
    journalctl -u "$UNIT" -n 40 --no-pager
  fi
}

activate() {
  local file="$1"
  write_current "$file" || return 1
  basename "$file" >"$ACTIVE_FILE"
  echo "Active: $(remark_of "$file")"
  if unit_installed && unit_active; then
    systemctl restart "$UNIT"
    sleep 1
    if unit_active; then
      echo "Service restarted"
    else
      service_failed
    fi
  else
    echo "Service is not running. Start it with: xclient start"
  fi
}

add_uris() {
  local out line
  LAST_ADDED=""
  out="$("$CONV" -o "$CFG_DIR" "$@")" || true
  while IFS= read -r line; do
    [[ -f $line ]] || continue
    echo "Saved: $(remark_of "$line")"
    LAST_ADDED="$line"
  done <<<"$out"
  [[ -n $LAST_ADDED ]]
}

add_interactive() {
  local uri
  read -r -e -p "URI: " uri
  uri="${uri//[[:space:]]/}"
  if [[ ! $uri =~ ^(vless|vmess|ss|trojan):// ]]; then
    echo "Unsupported or empty URI"
    return 1
  fi
  add_uris "$uri" || return 1
  if ask_yes "Use it now?"; then
    activate "$LAST_ADDED"
  fi
}

add_cmd() {
  if [[ $# -eq 0 ]]; then
    add_interactive
    return
  fi
  add_uris "$@" || return 1
  if ask_yes "Use it now?"; then
    activate "$LAST_ADDED"
  fi
}

import_file() {
  local file="${1:-}" out line count=0
  if [[ -z $file ]]; then
    read -r -e -p "File with URIs: " file
  fi
  if [[ ! -f $file ]]; then
    echo "File not found" >&2
    return 1
  fi
  out="$("$CONV" -i "$file" -o "$CFG_DIR")" || true
  while IFS= read -r line; do
    [[ -f $line ]] || continue
    count=$((count + 1))
  done <<<"$out"
  echo "Imported $count config(s)"
}

remove_config() {
  resolve_config "${1:-}" || return 1
  local name
  name="$(remark_of "$PICKED")"
  confirm "Delete '$name'?" || return 0
  if [[ "$(basename "$PICKED")" == "$(active_name)" ]]; then
    if unit_installed && unit_active; then
      systemctl stop "$UNIT"
    fi
    rm -f "$ACTIVE_FILE" "$CURRENT"
    echo "Active config removed, service stopped"
  fi
  rm -f "$PICKED"
  echo "Deleted"
}

probe_config() {
  local cfg="$1" tmp pid out code seconds
  tmp="$(mktemp)"
  retarget "$cfg" "$PROBE_SOCKS" "$PROBE_HTTP" "$PROBE_METRICS" >"$tmp"
  "$XRAY" run -format json -c "$tmp" >/dev/null 2>&1 &
  pid=$!
  sleep 1.5
  out="$(curl -q -s -m 10 -o /dev/null -w '%{http_code} %{time_total}' \
    -x "socks5h://127.0.0.1:$PROBE_SOCKS" "$TEST_URL" 2>/dev/null)"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -f "$tmp"
  code="${out%% *}"
  seconds="${out##* }"
  if [[ $code =~ ^(200|204)$ ]]; then
    PROBE_MS="$(awk -v t="$seconds" 'BEGIN { printf "%d", t * 1000 }')"
    return 0
  fi
  return 1
}

check_all() {
  local mode="${1:-}" f best_ms=999999
  BEST_FILE=""
  load_configs
  if [[ ${#CONFIGS[@]} -eq 0 ]]; then
    echo "No saved configs"
    return 1
  fi
  for f in "${CONFIGS[@]}"; do
    printf '%-40s ' "$(remark_of "$f")"
    if probe_config "$f"; then
      echo "$PROBE_MS ms"
      if (( PROBE_MS < best_ms )); then
        best_ms=$PROBE_MS
        BEST_FILE="$f"
      fi
    else
      echo "failed"
    fi
  done
  if [[ -z $BEST_FILE ]]; then
    echo "No working config"
    return 1
  fi
  echo "Fastest: $(remark_of "$BEST_FILE") ($best_ms ms)"
  if [[ $mode == use ]]; then
    activate "$BEST_FILE"
  fi
}

test_proxy() {
  local socks="socks5h://127.0.0.1:$SOCKS_PORT" http="http://127.0.0.1:$HTTP_PORT"
  if [[ "$(port_state "$SOCKS_PORT")" != up ]]; then
    echo "Nothing is listening on 127.0.0.1:$SOCKS_PORT"
    return 1
  fi
  echo "Direct: $(curl -q -s -m 10 --noproxy '*' https://api.ipify.org || echo failed)"
  echo "SOCKS5: $(curl -q -s -m 15 -x "$socks" https://api.ipify.org || echo failed)"
  echo "HTTP:   $(curl -q -s -m 15 -x "$http" https://api.ipify.org || echo failed)"
  curl -q -s -m 20 -o /dev/null -x "$socks" \
    -w 'Timing: connect %{time_connect}s  tls %{time_appconnect}s  ttfb %{time_starttransfer}s  total %{time_total}s\n' \
    https://www.google.com || echo "Timing test failed"
}

valid_comp() {
  local c
  for c in "${COMPS[@]}"; do
    [[ $c == "$1" ]] && return 0
  done
  return 1
}

comp_available() {
  case "$1" in
    apt) command -v apt-get >/dev/null 2>&1 ;;
    curl) command -v curl >/dev/null 2>&1 ;;
    wget) command -v wget >/dev/null 2>&1 ;;
    git) command -v git >/dev/null 2>&1 ;;
    docker) systemctl cat docker.service >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

comp_state() {
  local found=""
  case "$1" in
    apt) [[ -f $APT_FILE ]] && found="$(cat "$APT_FILE")" ;;
    env) [[ -f $ENV_FILE ]] && found="$(cat "$ENV_FILE")" ;;
    curl) [[ -f $CURLRC ]] && found="$(grep -E '^proxy = ' "$CURLRC")" ;;
    wget) [[ -f $WGETRC ]] && found="$(grep -E '^(http|https)_proxy = ' "$WGETRC")" ;;
    docker) [[ -f $DOCKER_FILE ]] && found="$(cat "$DOCKER_FILE")" ;;
    git) found="$(as_target git config --global --get http.proxy 2>/dev/null)" ;;
  esac
  if [[ -z $found ]]; then
    echo off
  elif [[ $found =~ ${PROXY_URL}([^0-9]|$) ]]; then
    echo on
  else
    echo other
  fi
}

docker_restart() {
  if confirm "Restart Docker now? Running containers may be interrupted"; then
    systemctl restart docker
  else
    echo "Restart skipped. Run: systemctl restart docker"
  fi
}

comp_on() {
  case "$1" in
    apt)
      printf 'Acquire::http::Proxy "%s/";\nAcquire::https::Proxy "%s/";\n' "$PROXY_URL" "$PROXY_URL" >"$APT_FILE"
      chmod 644 "$APT_FILE"
      ;;
    env)
      cat >"$ENV_FILE" <<EOF
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export ALL_PROXY="$PROXY_URL"
export NO_PROXY="$NO_PROXY_LIST"
export no_proxy="$NO_PROXY_LIST"
EOF
      chmod 644 "$ENV_FILE"
      ;;
    curl)
      comp_off curl
      printf 'proxy = "%s"\n' "$PROXY_URL" >>"$CURLRC"
      chown "$TARGET_USER:$TARGET_GROUP" "$CURLRC"
      ;;
    wget)
      comp_off wget
      printf 'use_proxy = on\nhttp_proxy = %s\nhttps_proxy = %s\n' "$PROXY_URL" "$PROXY_URL" >>"$WGETRC"
      chown "$TARGET_USER:$TARGET_GROUP" "$WGETRC"
      ;;
    docker)
      mkdir -p "$DOCKER_DIR"
      cat >"$DOCKER_FILE" <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=$NO_PROXY_LIST"
EOF
      chmod 644 "$DOCKER_FILE"
      systemctl daemon-reload
      docker_restart
      ;;
    git)
      as_target git config --global http.proxy "$PROXY_URL"
      ;;
  esac
}

comp_off() {
  case "$1" in
    apt) rm -f "$APT_FILE" ;;
    env) rm -f "$ENV_FILE" ;;
    curl)
      if [[ -f $CURLRC ]]; then
        sed -i -E '/^proxy = "http:\/\/127\.0\.0\.1:[0-9]+"$/d' "$CURLRC"
        [[ -s $CURLRC ]] || rm -f "$CURLRC"
      fi
      ;;
    wget)
      if [[ -f $WGETRC ]]; then
        sed -i -E '/^(use_proxy = on|http_proxy = http:\/\/127\.0\.0\.1:[0-9]+|https_proxy = http:\/\/127\.0\.0\.1:[0-9]+)$/d' "$WGETRC"
        [[ -s $WGETRC ]] || rm -f "$WGETRC"
      fi
      ;;
    docker)
      if [[ -f $DOCKER_FILE ]]; then
        rm -f "$DOCKER_FILE"
        systemctl daemon-reload
        docker_restart
      fi
      ;;
    git)
      as_target git config --global --unset http.proxy 2>/dev/null || true
      ;;
  esac
}

proxy_apply() {
  local mode="$1" c wanted=("${@:2}") env_touched=0
  if [[ ${#wanted[@]} -eq 0 ]]; then
    wanted=("${COMPS[@]}")
  fi
  if [[ $mode == on && "$(port_state "$HTTP_PORT")" != up ]]; then
    echo "Nothing is listening on 127.0.0.1:$HTTP_PORT"
    confirm "Apply anyway? Tools will fail until the proxy is up" || return 1
  fi
  for c in "${wanted[@]}"; do
    if ! valid_comp "$c"; then
      echo "$c: unknown component"
      continue
    fi
    if ! comp_available "$c"; then
      echo "$c: not installed, skipped"
      continue
    fi
    "comp_$mode" "$c"
    echo "$c: $(comp_state "$c")"
    [[ $c == env ]] && env_touched=1
  done
  if [[ $env_touched -eq 1 ]]; then
    if [[ $mode == on ]]; then
      echo "Current shell: source $ENV_FILE"
    else
      echo "Current shell: unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY no_proxy"
    fi
  fi
}

proxy_status() {
  local c
  echo "Proxy URL: $PROXY_URL ($(port_state "$HTTP_PORT"))"
  for c in "${COMPS[@]}"; do
    if comp_available "$c"; then
      printf '  %-7s %s\n' "$c" "$(comp_state "$c")"
    else
      printf '  %-7s n/a\n' "$c"
    fi
  done
}

sys_summary() {
  local c out=""
  for c in "${COMPS[@]}"; do
    if comp_available "$c"; then
      out+="$c:$(comp_state "$c") "
    fi
  done
  printf '%s' "$out"
}

proxy_menu() {
  local choice c i
  while true; do
    echo
    echo "System proxy -> $PROXY_URL ($(port_state "$HTTP_PORT"))"
    i=1
    for c in "${COMPS[@]}"; do
      if comp_available "$c"; then
        printf '%d) %-7s %s\n' "$i" "$c" "$(comp_state "$c")"
      else
        printf '%d) %-7s n/a\n' "$i" "$c"
      fi
      i=$((i + 1))
    done
    echo "a) enable all"
    echo "d) disable all"
    echo "0) back"
    read -r -p "> " choice || return 0
    case "$choice" in
      a) proxy_apply on ;;
      d) proxy_apply off ;;
      0) return 0 ;;
      [1-6])
        c="${COMPS[$((choice - 1))]}"
        if [[ "$(comp_state "$c")" == on ]]; then
          proxy_apply off "$c"
        else
          proxy_apply on "$c"
        fi
        ;;
      *) echo "Invalid choice" ;;
    esac
  done
}

proxy_cmd() {
  case "${1:-status}" in
    on) shift; proxy_apply on "$@" ;;
    off) shift; proxy_apply off "$@" ;;
    status) proxy_status ;;
    menu) proxy_menu ;;
    *) usage; return 2 ;;
  esac
}

set_ports() {
  local s="${1:-}" h="${2:-}" c
  if [[ -z $s ]]; then
    read -r -p "SOCKS port [$SOCKS_PORT]: " s
  fi
  if [[ -z $h ]]; then
    read -r -p "HTTP port [$HTTP_PORT]: " h
  fi
  s="${s:-$SOCKS_PORT}"
  h="${h:-$HTTP_PORT}"
  if ! valid_port "$s" || ! valid_port "$h"; then
    echo "Ports must be numbers between 1 and 65535" >&2
    return 1
  fi
  if [[ $s == "$h" || $s == "$METRICS_PORT" || $h == "$METRICS_PORT" ]]; then
    echo "Ports must differ from each other and from $METRICS_PORT" >&2
    return 1
  fi
  SOCKS_PORT="$s"
  HTTP_PORT="$h"
  PROXY_URL="http://127.0.0.1:$HTTP_PORT"
  touch "$CONF_FILE"
  sed -i -e '/^SOCKS_PORT=/d' -e '/^HTTP_PORT=/d' "$CONF_FILE"
  printf 'SOCKS_PORT=%s\nHTTP_PORT=%s\n' "$SOCKS_PORT" "$HTTP_PORT" >>"$CONF_FILE"
  chmod 600 "$CONF_FILE"
  echo "Ports: socks $SOCKS_PORT, http $HTTP_PORT"
  if [[ -f $ACTIVE_FILE && -f "$CFG_DIR/$(active_name)" ]]; then
    activate "$CFG_DIR/$(active_name)"
  fi
  for c in "${COMPS[@]}"; do
    if comp_available "$c" && [[ "$(comp_state "$c")" == other ]]; then
      echo "System proxy still points elsewhere. Run: xclient proxy on"
      break
    fi
  done
}

report() {
  printf '%-5s %s\n' "$1" "$2"
}

doctor() {
  local ntp
  if [[ -x $XRAY ]]; then
    report OK "xray: $("$XRAY" version 2>/dev/null | head -n1)"
  else
    report FAIL "xray binary missing"
  fi
  if [[ -f $CURRENT ]]; then
    if "$XRAY" run -test -format json -c "$CURRENT" >/dev/null 2>&1; then
      report OK "active config valid: $(remark_of "$CURRENT")"
    else
      report FAIL "active config rejected by xray"
    fi
  else
    report FAIL "no active config"
  fi
  if unit_installed; then
    if unit_active; then
      report OK "service running"
    else
      report FAIL "service not running"
    fi
    report INFO "boot: $(systemctl is-enabled "$UNIT" 2>/dev/null)"
  else
    report FAIL "service not installed (xclient install)"
  fi
  report INFO "socks $SOCKS_PORT: $(port_state "$SOCKS_PORT"), http $HTTP_PORT: $(port_state "$HTTP_PORT")"
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  if [[ $ntp == yes ]]; then
    report OK "clock synchronized"
  else
    report FAIL "clock not synchronized (VMess and REALITY break on time skew)"
  fi
  echo
  proxy_status
  echo
  test_proxy
}

do_install() {
  write_unit || return 1
  ln -sf "$SELF" "$LINK"
  systemctl enable "$UNIT" >/dev/null 2>&1
  echo "Installed $UNIT.service (enabled at boot) and command: xclient"
  if [[ -f $CURRENT ]]; then
    svc_start
  else
    echo "Add a config, then run: xclient start"
  fi
}

do_uninstall() {
  confirm "Stop and remove the xclient service?" || return 0
  if unit_installed; then
    systemctl disable --now "$UNIT" >/dev/null 2>&1
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
  fi
  rm -f "$LINK"
  if confirm "Remove system proxy settings too?"; then
    proxy_apply off
  fi
  echo "Uninstalled. Configs are kept in $CFG_DIR"
}

show_header() {
  local state boot name
  if unit_installed; then
    state="$(systemctl is-active "$UNIT" 2>/dev/null)"
    boot="$(systemctl is-enabled "$UNIT" 2>/dev/null)"
  else
    state="not installed"
    boot="-"
  fi
  name="$(active_name)"
  printf 'xclient %s\n' "$(version)"
  printf 'Service: %s (boot: %s)\n' "$state" "$boot"
  if [[ -n $name && -f "$CFG_DIR/$name" ]]; then
    printf 'Active:  %s\n' "$(remark_of "$CFG_DIR/$name")"
  else
    printf 'Active:  none\n'
  fi
  printf 'Ports:   socks %s %s | http %s %s\n' "$SOCKS_PORT" "$(port_state "$SOCKS_PORT")" "$HTTP_PORT" "$(port_state "$HTTP_PORT")"
  printf 'System:  %s\n' "$(sys_summary)"
}

service_menu() {
  local choice
  while true; do
    echo
    echo "1) Start"
    echo "2) Stop"
    echo "3) Restart"
    echo "4) Enable at boot"
    echo "5) Disable at boot"
    echo "6) Logs"
    echo "0) Back"
    read -r -p "> " choice || return 0
    case "$choice" in
      1) svc_start ;;
      2) svc_stop ;;
      3) svc_restart ;;
      4) svc_enable ;;
      5) svc_disable ;;
      6) svc_logs ;;
      0) return 0 ;;
      *) echo "Invalid choice" ;;
    esac
  done
}

main_menu() {
  local choice
  while true; do
    echo
    show_header
    echo "-----------------------------------------"
    echo " 1) Add config (paste URI)"
    echo " 2) Import URIs from file"
    echo " 3) Select config"
    echo " 4) Remove config"
    echo " 5) Check configs (latency)"
    echo " 6) Service control"
    echo " 7) System proxy (apt, env, curl, wget, docker, git)"
    echo " 8) Test connection"
    echo " 9) Doctor"
    echo "10) Ports"
    echo "11) Install service"
    echo "12) Uninstall"
    echo " 0) Exit"
    read -r -p "> " choice || exit 0
    case "$choice" in
      1) add_interactive ;;
      2) import_file ;;
      3) resolve_config && activate "$PICKED" ;;
      4) remove_config ;;
      5)
        if check_all && ask_yes "Switch to the fastest?"; then
          activate "$BEST_FILE"
        fi
        ;;
      6) service_menu ;;
      7) proxy_menu ;;
      8) test_proxy ;;
      9) doctor ;;
      10) set_ports ;;
      11) do_install ;;
      12) do_uninstall ;;
      0) exit 0 ;;
      *) echo "Invalid choice" ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage: xclient [-y] [command]

  (none)                   interactive menu
  add [URI...]             save URIs as configs
  import [FILE]            save every URI found in FILE
  list                     list saved configs
  use [N|NAME]             activate a config
  remove [N|NAME]          delete a config
  check                    measure latency of every config
  best                     activate the fastest working config
  test                     show IPs and timing through the proxy
  doctor                   full health report
  status                   short status
  start|stop|restart       control the service
  enable|disable           start the service at boot or not
  logs [-f]                service logs
  install                  install the service and the xclient command
  uninstall                remove the service and the xclient command
  proxy on|off [PART...]   system proxy: apt env curl wget docker git
  proxy status|menu
  ports [SOCKS HTTP]       change the local proxy ports
  run                      run xray in the foreground
  version

  -y                       answer yes to every question
EOF
}

case "${1:-menu}" in
  menu) main_menu ;;
  add) shift; add_cmd "$@" ;;
  import) shift; import_file "${1:-}" ;;
  list|ls) list_configs ;;
  use) shift; resolve_config "${1:-}" && activate "$PICKED" ;;
  remove|rm) shift; remove_config "${1:-}" ;;
  check) check_all ;;
  best) check_all use ;;
  test) test_proxy ;;
  doctor) doctor ;;
  status) show_header ;;
  start) svc_start ;;
  stop) svc_stop ;;
  restart) svc_restart ;;
  enable) svc_enable ;;
  disable) svc_disable ;;
  logs) shift; svc_logs "${1:-}" ;;
  install) do_install ;;
  uninstall) do_uninstall ;;
  proxy) shift; proxy_cmd "$@" ;;
  ports) shift; set_ports "${1:-}" "${2:-}" ;;
  run) exec "$XRAY" run -format json -c "$CURRENT" ;;
  version) version ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
