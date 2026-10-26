#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY="$DIR/xray"
CONV="$DIR/uri2xray"
CFG_DIR="$DIR/configs"
PID_FILE="$DIR/xray.pid"
LOG_FILE="$DIR/xray.log"
ACTIVE_FILE="$DIR/active"
SOCKS="socks5h://127.0.0.1:10808"
PICKED=""

for bin in "$XRAY" "$CONV"; do
  if [[ ! -x "$bin" ]]; then
    echo "missing or not executable: $bin" >&2
    exit 1
  fi
done

mkdir -p "$CFG_DIR"
chmod 700 "$CFG_DIR"

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

remark_of() {
  local value
  value="$(sed -n 's/^ *"remarks": "\(.*\)",*$/\1/p' "$1" | head -n1)"
  printf '%s' "${value:-$(basename "$1")}"
}

stop_proxy() {
  if ! is_running; then
    rm -f "$PID_FILE"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  rm -f "$PID_FILE"
  echo "Stopped"
}

start_proxy() {
  local cfg="$1"
  stop_proxy >/dev/null
  nohup "$XRAY" run -c "$cfg" >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  disown
  sleep 1.5
  if is_running; then
    echo "$cfg" >"$ACTIVE_FILE"
    echo "Started: $(remark_of "$cfg")"
    echo "SOCKS5 127.0.0.1:10808  HTTP 127.0.0.1:10809"
  else
    echo "Xray failed to start:" >&2
    tail -n 20 "$LOG_FILE" >&2
    rm -f "$PID_FILE"
    return 1
  fi
}

pick_config() {
  local files=("$CFG_DIR"/*.json)
  if [[ ! -e "${files[0]}" ]]; then
    echo "No saved configs"
    return 1
  fi
  local i=1
  for f in "${files[@]}"; do
    printf '%2d) %s\n' "$i" "$(remark_of "$f")"
    i=$((i + 1))
  done
  local n
  read -r -p "Select: " n
  if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#files[@]} )); then
    echo "Invalid selection"
    return 1
  fi
  PICKED="${files[$((n - 1))]}"
}

add_uri() {
  local uri out
  read -r -p "URI: " uri
  uri="${uri//[[:space:]]/}"
  if [[ ! "$uri" =~ ^(vless|vmess|ss|trojan):// ]]; then
    echo "Unsupported or empty URI"
    return 1
  fi
  out="$("$CONV" -o "$CFG_DIR" "$uri")" || return 1
  start_proxy "$out"
}

import_file() {
  local file
  read -r -p "File with URIs: " file
  if [[ ! -f "$file" ]]; then
    echo "File not found"
    return 1
  fi
  "$CONV" -i "$file" -o "$CFG_DIR" >/dev/null
  echo "Imported to $CFG_DIR"
}

start_saved() {
  pick_config || return 1
  start_proxy "$PICKED"
}

delete_saved() {
  pick_config || return 1
  if is_running && [[ "$(cat "$ACTIVE_FILE" 2>/dev/null)" == "$PICKED" ]]; then
    stop_proxy
  fi
  rm -f "$PICKED"
  echo "Deleted"
}

show_status() {
  if is_running; then
    echo "Running (pid $(cat "$PID_FILE"))"
    if [[ -f "$ACTIVE_FILE" && -f "$(cat "$ACTIVE_FILE")" ]]; then
      echo "Active: $(remark_of "$(cat "$ACTIVE_FILE")")"
    fi
  else
    echo "Not running"
  fi
}

test_proxy() {
  if ! is_running; then
    echo "Proxy is not running"
    return 1
  fi
  echo "Direct:  $(curl -s -m 10 https://api.ipify.org || echo failed)"
  echo "Proxied: $(curl -s -m 15 -x "$SOCKS" https://api.ipify.org || echo failed)"
  curl -s -m 20 -o /dev/null -x "$SOCKS" \
    -w 'connect %{time_connect}s  tls %{time_appconnect}s  ttfb %{time_starttransfer}s  total %{time_total}s\n' \
    https://www.google.com || echo "Timing test failed"
}

show_log() {
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 30 "$LOG_FILE"
  else
    echo "No log yet"
  fi
}

while true; do
  echo
  show_status
  echo "-----------------------------"
  echo "1) Add URI and start"
  echo "2) Import URIs from file"
  echo "3) Start saved config"
  echo "4) Stop"
  echo "5) Test connection"
  echo "6) Show log"
  echo "7) Delete saved config"
  echo "0) Exit"
  read -r -p "> " choice
  case "$choice" in
    1) add_uri ;;
    2) import_file ;;
    3) start_saved ;;
    4) stop_proxy ;;
    5) test_proxy ;;
    6) show_log ;;
    7) delete_saved ;;
    0) exit 0 ;;
    *) echo "Invalid choice" ;;
  esac
done
