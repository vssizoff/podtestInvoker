#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
jetstream_dir=$(mktemp -d "${TMPDIR:-/tmp}/podtest-jetstream.XXXXXX")
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$jetstream_dir"
}
trap cleanup EXIT
zig build -Djetstream-tests=true
nats-server -a 127.0.0.1 -p -1 -js -sd "$jetstream_dir/store" \
    -P "$jetstream_dir/server.pid" >"$jetstream_dir/server.log" 2>&1 &
server_pid=$!
port=
for ((i=0; i<50; i++)); do
    if grep -q 'Server is ready' "$jetstream_dir/server.log"; then
        port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$jetstream_dir/server.log")
        break
    fi
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.1
done
if [[ -z "$port" ]]; then
    cat "$jetstream_dir/server.log" >&2
    exit 1
fi
./zig-out/bin/test-invoker-jetstream "$port" "$jetstream_dir"
