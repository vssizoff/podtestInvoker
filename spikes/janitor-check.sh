#!/usr/bin/env bash
set -euo pipefail
bin=$1
fixture=$2
config=$3
: "${PODTEST_PODMAN_SOCKET:?Set the rootless Podman socket path}"
: "${PODTEST_LIBPOD_API_VERSION:?Set the socket API version}"
: "${PODTEST_TEST_IMAGE_ID:?Set a local Alpine-compatible image ID}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/podtest-janitor.XXXXXX")
mkdir -m 700 "$tmp/a" "$tmp/b"
pid_a= pid_b=
sweep() {
    PODTEST_STATE_DIR="$tmp/$1" PODTEST_INVOKER_ID="phase8-$1" "$bin" sweep-resources "$config"
}
cleanup() {
    for pid in "$pid_a" "$pid_b"; do
        if [[ -n "$pid" ]]; then
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    if sweep a >/dev/null; then clean_a=true; else clean_a=false; fi
    if sweep b >/dev/null; then clean_b=true; else clean_b=false; fi
    if $clean_a && $clean_b; then
        rm -f -- "$tmp/a/ready" "$tmp/b/ready"
        for slot in a b; do
            if [[ -d "$tmp/$slot/container-journal-v1" ]]; then
                rmdir -- "$tmp/$slot/container-journal-v1"
            fi
        done
        rmdir -- "$tmp/a" "$tmp/b" "$tmp"
    else
        echo "Fixture state retained for recovery: $tmp" >&2
    fi
}
trap cleanup EXIT
"$fixture" "$tmp/a" phase8-a &
pid_a=$!
"$fixture" "$tmp/b" phase8-b &
pid_b=$!
for ((i=0; i<200; i++)); do
    if [[ -f "$tmp/a/ready" && -f "$tmp/b/ready" ]]; then break; fi
    kill -0 "$pid_a" "$pid_b"
    sleep 0.1
done
id_a=$(<"$tmp/a/ready")
id_b=$(<"$tmp/b/ready")
[[ $id_a =~ ^[0-9a-f]{64}$ && $id_b =~ ^[0-9a-f]{64}$ ]]
status() {
    curl --silent --show-error --max-time 5 --unix-socket "$PODTEST_PODMAN_SOCKET" --output /dev/null --write-out '%{http_code}' \
        "http://localhost/v$PODTEST_LIBPOD_API_VERSION/libpod/$1/$2/json"
}
if output=$(sweep a); then exit 1; fi
grep -q 'InstanceAlreadyRunning' <<< "$output"
kill -KILL "$pid_a"
wait "$pid_a" 2>/dev/null || true
pid_a=
[[ $(status containers "$id_a") == 200 ]]
if output=$(PODTEST_STATE_DIR="$tmp/a" PODTEST_INVOKER_ID=phase8-b "$bin" sweep-resources "$config"); then exit 1; fi
grep -q '"removed":0,"rejected":3' <<< "$output"
[[ $(status containers "$id_a") == 200 ]]
sweep a | grep '"removed":3,"rejected":0,"unresolved":0'
[[ $(status containers "$id_a") == 404 && $(status containers "$id_b") == 200 ]]
sweep a | grep '"removed":0,"rejected":0,"unresolved":0'
kill -KILL "$pid_b"
wait "$pid_b" 2>/dev/null || true
pid_b=
sweep b | grep '"removed":3,"rejected":0,"unresolved":0'
[[ $(status containers "$id_b") == 404 ]]
[[ $(status images "$PODTEST_TEST_IMAGE_ID") == 200 ]]
