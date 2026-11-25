#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
state=$(mktemp -d "${TMPDIR:-/tmp}/podtest-host-check.XXXXXX")
pid=
cleanup() {
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f -- "$state/log"
    rmdir -- "$state"
}
trap cleanup EXIT
export PODTEST_STATE_DIR="$state"
bin=./zig-out/bin/podtest-invoker
"$bin" check config.example.json | rg '"operation":"host_check_passed".*"execution_ready":false'
PODTEST_LIBPOD_API_VERSION=1.0.0 "$bin" check config.example.json > "$state/log" && exit 1
rg 'LibpodVersionMismatch' "$state/log"
"$bin" serve-diagnostics config.example.json > "$state/log" &
pid=$!
for ((i=0; i<50; i++)); do
    rg -q diagnostics_started "$state/log" && break
    kill -0 "$pid"
    sleep 0.1
done
rg -q diagnostics_started "$state/log"
if result=$("$bin" check config.example.json); then exit 1; fi
rg 'InstanceAlreadyRunning' <<< "$result"
kill -TERM "$pid"
wait "$pid"
pid=
rg '"operation":"shutdown"' "$state/log"
"$bin" check config.example.json | rg '"operation":"host_check_passed"'
