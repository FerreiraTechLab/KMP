#!/bin/bash
set -u

command_name=${1:-status}
aria2_binary=${2:-aria2c}
state_dir=${3:-"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/conf/daemon"}
download_dir=${4:-"$state_dir/downloads"}

pid_file="$state_dir/pid"
secret_file="$state_dir/rpc.secret"
env_file="$state_dir/rpc.env"
session_file="$state_dir/session.txt"
log_file="$state_dir/aria2.log"
settings_file="$state_dir/settings.conf"
version_file="$state_dir/daemon.version"
backend_file="$state_dir/daemon.backend"
monitor_pid_file="$state_dir/battery-monitor.pid"
monitor_log_file="$state_dir/battery-monitor.log"
monitor_script="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/battery_seed.py"
mapper_pid_file="$state_dir/port-mapper.pid"
mapper_state_file="$state_dir/port-mapping.json"
mapper_script="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/port_mapper.py"
python_binary=${KMP_PYTHON:-}
if [ -z "$python_binary" ]; then
  python_binary=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
fi
daemon_version=10

backend_identity() {
  resolved=$aria2_binary
  case "$resolved" in
    /*) ;;
    *) resolved=$(command -v "$resolved" 2>/dev/null || printf '%s' "$resolved") ;;
  esac
  if [ -f "$resolved" ] && command -v sha256sum >/dev/null 2>&1; then
    backend_hash=$(sha256sum "$resolved" 2>/dev/null | awk '{print $1}')
    printf '%s:%s\n' "$resolved" "$backend_hash"
  else
    printf '%s\n' "$resolved"
  fi
}

is_kmp_torrentd() {
  [ "${aria2_binary##*/}" = "kmp-torrentd" ]
}

valid_pid() {
  [ -f "$pid_file" ] || return 1
  daemon_pid=$(cat "$pid_file" 2>/dev/null) || return 1
  case "$daemon_pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$daemon_pid" 2>/dev/null || return 1
  [ -r "/proc/$daemon_pid/cmdline" ] || return 1
  daemon_cmdline=$(tr '\0' ' ' < "/proc/$daemon_pid/cmdline")
  printf '%s' "$daemon_cmdline" | grep -F -- '--enable-rpc=true' >/dev/null 2>&1 ||
    printf '%s' "$daemon_cmdline" | grep -F -- 'kmp-torrentd' >/dev/null 2>&1
}

read_setting() {
  setting_name=$1
  fallback=$2
  setting_value=""
  if [ -f "$settings_file" ]; then
    setting_value=$(sed -n "s/^${setting_name}=//p" "$settings_file" | tail -n 1)
  fi
  [ -n "$setting_value" ] && printf '%s' "$setting_value" || printf '%s' "$fallback"
}

write_env() {
  umask 077
  {
    printf 'KMP_ARIA2_RPC=%s\n' "http://127.0.0.1:${rpc_port}/jsonrpc"
    printf 'KMP_ARIA2_SECRET=%s\n' "$rpc_secret"
  } > "$env_file.tmp"
  mv "$env_file.tmp" "$env_file"
}

stop_monitor() {
  if [ -f "$monitor_pid_file" ]; then
    monitor_pid=$(cat "$monitor_pid_file" 2>/dev/null || true)
    case "$monitor_pid" in ''|*[!0-9]*) ;; *) kill "$monitor_pid" 2>/dev/null || true ;; esac
  fi
  rm -f "$monitor_pid_file"
}

stop_mapper() {
  if [ -f "$mapper_pid_file" ]; then
    mapper_pid=$(cat "$mapper_pid_file" 2>/dev/null || true)
    case "$mapper_pid" in ''|*[!0-9]*) ;; *) kill "$mapper_pid" 2>/dev/null || true ;; esac
  fi
  rm -f "$mapper_pid_file"
}

start_mapper() {
  [ -n "$python_binary" ] && [ -f "$mapper_script" ] || return 0
  if [ -f "$mapper_pid_file" ]; then
    mapper_pid=$(cat "$mapper_pid_file" 2>/dev/null || true)
    case "$mapper_pid" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$mapper_pid" 2>/dev/null && return 0 ;;
    esac
  fi
  stop_mapper
  setsid "$python_binary" "$mapper_script" --port "$listen_port" \
    --state "$mapper_state_file" >> "$log_file" 2>&1 < /dev/null &
  printf '%s\n' "$!" > "$mapper_pid_file"
}

start_monitor() {
  [ -n "$python_binary" ] || return 0
  if [ -f "$monitor_pid_file" ]; then
    monitor_pid=$(cat "$monitor_pid_file" 2>/dev/null || true)
    case "$monitor_pid" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$monitor_pid" 2>/dev/null && return 0 ;;
    esac
  fi
  stop_monitor
  seed_threshold=$(read_setting seed_battery_min 30)
  case "$seed_threshold" in ''|*[!0-9]*) seed_threshold=30 ;; esac
  setsid "$python_binary" "$monitor_script" --rpc "http://127.0.0.1:${rpc_port}/jsonrpc" \
    --secret "$rpc_secret" --threshold "$seed_threshold" \
    --state "$state_dir/battery-paused.json" \
    >> "$monitor_log_file" 2>&1 < /dev/null &
  printf '%s\n' "$!" > "$monitor_pid_file"
}

case "$command_name" in
  start)
    mkdir -p "$state_dir" "$download_dir"
    chmod 700 "$state_dir"
    touch "$session_file"
    chmod 600 "$session_file"
    if [ -s "$secret_file" ]; then
      rpc_secret=$(cat "$secret_file")
    else
      rpc_secret=$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')
      umask 077
      printf '%s\n' "$rpc_secret" > "$secret_file"
    fi
    case "$rpc_secret" in ''|*[!0-9a-f]*) printf 'segredo RPC inválido\n' >&2; exit 1 ;; esac
    rpc_port=$(read_setting rpc_port 26801)
    if valid_pid; then
      if [ "$(cat "$version_file" 2>/dev/null)" = "$daemon_version" ] &&
         [ "$(cat "$backend_file" 2>/dev/null)" = "$(backend_identity)" ]; then
        start_monitor
        listen_port=$(read_setting listen_port 6881)
        start_mapper
        cat "$env_file"
        exit 0
      fi
      kill "$daemon_pid" 2>/dev/null || true
      for _attempt in 1 2 3 4 5; do
        kill -0 "$daemon_pid" 2>/dev/null || break
        sleep 1
      done
    fi
    rm -f "$pid_file" "$env_file"
    if [ ! -x "$aria2_binary" ] && ! command -v "$aria2_binary" >/dev/null 2>&1; then
      printf 'aria2c não encontrado\n' >&2
      exit 1
    fi
    listen_port=$(read_setting listen_port 6881)
    upload_limit=$(read_setting upload_limit 100K)
    max_concurrent_downloads=$(read_setting max_concurrent_downloads 50)
    case "$rpc_port:$listen_port" in *[!0-9:]*) printf 'porta inválida\n' >&2; exit 1 ;; esac
    case "$upload_limit" in *[!0-9KMGkmg]*) printf 'limite de upload inválido\n' >&2; exit 1 ;; esac
    case "$max_concurrent_downloads" in
      ''|*[!0-9]*|0) printf 'limite de downloads simultâneos inválido\n' >&2; exit 1 ;;
    esac
    write_env
    if [ -f "$log_file" ] && [ "$(wc -c < "$log_file")" -gt 1048576 ]; then
      mv "$log_file" "$log_file.old"
    fi
    if is_kmp_torrentd; then
      setsid "$aria2_binary" \
        --rpc-listen="127.0.0.1:${rpc_port}" --rpc-secret="$rpc_secret" \
        --state-dir="$state_dir/torrentd" --data-dir="$download_dir" \
        --listen-port="$listen_port" --upload-limit="$upload_limit" \
        < /dev/null >> "$log_file" 2>&1 &
    else
      setsid "$aria2_binary" \
        --enable-rpc=true --rpc-listen-all=false \
        --rpc-listen-port="$rpc_port" --rpc-secret="$rpc_secret" \
        --input-file="$session_file" --save-session="$session_file" \
        --save-session-interval=30 --force-save=true \
        --continue=true --auto-file-renaming=false --file-allocation=none \
        --enable-dht=true --enable-peer-exchange=true --bt-enable-lpd=true \
        --listen-port="$listen_port" --dht-listen-port="$listen_port" \
        --seed-ratio=0 --max-overall-upload-limit="$upload_limit" \
        --max-concurrent-downloads="$max_concurrent_downloads" --dir="$download_dir" \
        --console-log-level=warn < /dev/null >> "$log_file" 2>&1 &
    fi
    daemon_pid=$!
    printf '%s\n' "$daemon_pid" > "$pid_file"
    sleep 1
    for _attempt in 1 2 3 4 5; do
      if valid_pid; then
        printf '%s\n' "$daemon_version" > "$version_file"
        backend_identity > "$backend_file"
        start_monitor
        start_mapper
        cat "$env_file"
        exit 0
      fi
      sleep 1
    done
    printf 'daemon BitTorrent não iniciou; consulte %s\n' "$log_file" >&2
    rm -f "$pid_file" "$env_file" "$backend_file"
    exit 1
    ;;
  status)
    if valid_pid; then
      printf 'running pid=%s\n' "$daemon_pid"
      exit 0
    fi
    printf 'stopped\n'
    exit 1
    ;;
  env)
    valid_pid && cat "$env_file" || exit 1
    ;;
  stop)
    stop_monitor
    stop_mapper
    if valid_pid; then
      kill "$daemon_pid" 2>/dev/null || true
      for _attempt in 1 2 3 4 5; do
        kill -0 "$daemon_pid" 2>/dev/null || break
        sleep 1
      done
    fi
    rm -f "$pid_file" "$env_file"
    ;;
  *)
    printf 'uso: %s {start|status|env|stop} [aria2c] [state-dir] [download-dir]\n' "$0" >&2
    exit 2
    ;;
esac
