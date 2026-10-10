#!/bin/bash
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/kmp-daemon-test.XXXXXX)
cleanup() {
  "$repo_dir/KMP/daemon.sh" stop "$test_dir/fake-aria2c" \
    "$test_dir/state" "$test_dir/downloads" >/dev/null 2>&1 || true
  rm -rf "$test_dir"
}
trap cleanup EXIT

cat > "$test_dir/fake-aria2c" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$(dirname "$0")/aria2.args"
while :; do sleep 1; done
EOF
chmod +x "$test_dir/fake-aria2c"

"$repo_dir/KMP/daemon.sh" start "$test_dir/fake-aria2c" \
  "$test_dir/state" "$test_dir/downloads" > "$test_dir/first.env"
first_pid=$(cat "$test_dir/state/pid")
first_monitor_pid=$(cat "$test_dir/state/battery-monitor.pid")
kill -0 "$first_pid"
kill -0 "$first_monitor_pid"
grep '^KMP_ARIA2_RPC=http://127.0.0.1:26801/jsonrpc$' "$test_dir/first.env" >/dev/null
grep -E '^KMP_ARIA2_SECRET=[0-9a-f]{32}$' "$test_dir/first.env" >/dev/null
[ "$(stat -c %a "$test_dir/state/rpc.secret")" = 600 ]
grep '^--max-concurrent-downloads=50$' "$test_dir/aria2.args" >/dev/null

"$repo_dir/KMP/daemon.sh" start "$test_dir/fake-aria2c" \
  "$test_dir/state" "$test_dir/downloads" > "$test_dir/second.env"
[ "$first_pid" = "$(cat "$test_dir/state/pid")" ]
[ "$first_monitor_pid" = "$(cat "$test_dir/state/battery-monitor.pid")" ]
cmp "$test_dir/first.env" "$test_dir/second.env"
"$repo_dir/KMP/daemon.sh" status "$test_dir/fake-aria2c" \
  "$test_dir/state" "$test_dir/downloads" | grep '^running pid=' >/dev/null

"$repo_dir/KMP/daemon.sh" stop "$test_dir/fake-aria2c" \
  "$test_dir/state" "$test_dir/downloads"
! kill -0 "$first_pid" 2>/dev/null
[ ! -e "$test_dir/state/rpc.env" ]
printf 'daemon tests: ok\n'
