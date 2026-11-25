#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/podtest-artifact.XXXXXX")
pid=
cleanup() {
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
mkdir -m 0700 "$work/workspaces"
mkdir -m 0700 "$work/spool"
go build -o "$work/bundle-fixture" spikes/bundle-fixture.go
"$work/bundle-fixture" "$work/standard.tar" verify
"$work/bundle-fixture" "$work/lua.tar" lua
"$work/bundle-fixture" "$work/lua-unsupported.tar" lua-unsupported
openssl req -x509 -newkey rsa:2048 -noenc -days 1 -subj /CN=podtest-fixture \
    -addext subjectAltName=IP:127.0.0.1 -keyout "$work/key" -out "$work/cert" 2>/dev/null
zig build-exe src/workspace/download_test.zig -cflags -Wall -Wextra -Werror -- \
    src/workspace/download.c -lc -lcurl "-femit-bin=$work/client"
python3 spikes/artifact-server.py "$work/cert" "$work/key" "$work/origin" "$work/standard.tar" "$work/lua.tar" "$work/lua-unsupported.tar" &
pid=$!
for ((i=0; i<50; i++)); do
    [[ -s "$work/origin" ]] && break
    kill -0 "$pid"
    sleep 0.1
done
test -s "$work/origin"
"$work/client" "$(<"$work/origin")" "$work/cert" "$work/spool"
"$work/client" "$(<"$work/origin")" "$work/cert" "$work/spool" verify-reopen
for fixture in standard lua lua-unsupported; do
    archive="$work/$fixture.tar"
    read -r bundle_hash _ < <(sha256sum "$archive")
    bundle_bytes=$(stat -c '%s' "$archive")
    mkdir -m 0700 "$work/workspaces/$fixture" "$work/spool-$fixture"
    "$work/client" "$(<"$work/origin")" "$work/cert" "$work/spool-$fixture" "$work/workspaces/$fixture" "$bundle_bytes" "$bundle_hash" "$fixture"
done
printf '%s\n' 'HTTPS GET/PUT verification, cancellation, retry, and spool limits after restart verified'
printf '%s\n' 'Go USTAR Standard and Lua API 1 bundles published; unsupported Lua API rejected without a workspace'
