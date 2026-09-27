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
while :; do sleep 1; done
EOF
chmod +x "$test_dir/fake-aria2c"

"$repo_dir/KMP/daemon.sh" start "$test_dir/fake-aria2c" \
  "$test_dir/state" "$test_dir/downloads" > "$test_dir/first.env"
first_pid=$(cat "$test_dir/state/pid")
kill -0 "$first_pid"
grep '^KMP_ARIA2_RPC=http://127.0.0.1:26801/jsonrpc$' "$test_dir/first.env" >/dev/null
grep -E '^KMP_ARIA2_SECRET=[0-9a-f]{32}$' "$test_dir/first.env" >/dev/null
[ "$(stat -c %a "$test_dir/state/rpc.secret")" = 600 ]

"$repo_dir/KMP/daemon.sh" start "$test_dir/fake-aria2c" \
  "$test_dir/state" "$test_dir/downloads" > "$test_dir/second.env"
[ "$first_pid" = "$(cat "$test_dir/state/pid")" ]
cmp "$test_dir/first.env" "$test_dir/second.env"
"$repo_dir/KMP/daemon.sh" status "$test_dir/fake-aria2c" \
  "$test_dir/state" "$test_dir/downloads" | grep '^running pid=' >/dev/null

"$repo_dir/KMP/daemon.sh" stop "$test_dir/fake-aria2c" \
  "$test_dir/state" "$test_dir/downloads"
! kill -0 "$first_pid" 2>/dev/null
[ ! -e "$test_dir/state/rpc.env" ]
printf 'daemon tests: ok\n'
