#!/usr/bin/env bash
set -euo pipefail
state=$(mktemp -d "${TMPDIR:-/tmp}/podtest-outbox-crash.XXXXXX")
pid=
cleanup() {
    if [[ -n $pid ]]; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f -- "$state/ready" "$state/event-outbox.wal"
    rmdir -- "$state"
}
trap cleanup EXIT
"$1" write "$state" &
pid=$!
for ((i=0; i<100; i++)); do
    if [[ -f $state/ready ]]; then break; fi
    kill -0 "$pid"
    sleep 0.05
done
[[ -f $state/ready ]]
kill -KILL "$pid"
result=0
wait "$pid" 2>/dev/null || result=$?
pid=
[[ $result == 137 ]]
"$1" replay "$state"
