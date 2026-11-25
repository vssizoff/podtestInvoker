#!/usr/bin/env bash
set -euo pipefail
supervisor=$1
runner=$2
if [[ ${3:-} == --require-podman ]]; then
    : "${PODTEST_PODMAN_SOCKET:?expected rootless Podman socket}"
    : "${PODTEST_TEST_IMAGE_ID:?expected local Alpine image ID}"
    export PODTEST_REQUIRE_PODMAN=1
else
    unset PODTEST_PODMAN_SOCKET PODTEST_TEST_IMAGE_ID PODTEST_REQUIRE_PODMAN
fi
bwrap=$(command -v bwrap)
deps=$(LC_ALL=C ldd "$runner")
mapfile -t libraries < <(awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' <<< "$deps")
[[ ${#libraries[@]} -gt 0 && $deps != *'not found'* ]]
tmp=$(mktemp -d "${TMPDIR:-/tmp}/podtest-lua.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

check() {
    local expected=$1 script=$2 actual=0
    printf '%s' "$script" | timeout --kill-after=1s "${3:-5s}" env -i "$runner" >"$tmp/out" 2>"$tmp/err" || actual=$?
    if [[ $actual != "$expected" ]]; then
        printf 'runner: expected exit %s, got %s\n' "$expected" "$actual" >&2
        cat "$tmp/err" >&2
        exit 1
    fi
}

check 0 'assert(_VERSION == "Lua 5.5"); assert(not (os or io or debug or package or load or loadfile or dofile or string.dump)); assert(require("judge.runtime").api_version == 1); assert(not pcall(require, "../other")); print("runner ok")'
grep -Fxq 'runner ok' "$tmp/out"
check 2 'local function bad() error("fixture error") end; bad()'
grep -Fq 'stack traceback:' "$tmp/err"
check 2 $'\x1bLua'
check 3 'local s = string.rep("x", 16 * 1024 * 1024); print(#s)'
check 4 'while true do end'
check 4 'local t = coroutine.create(function() while true do end end); coroutine.resume(t)'
check 0 'local j = require("judge.runtime"); local a = j.spawn(function() print("a-start"); j.sleep(30); print("a-end") end); local b = j.spawn(function() print("b-start"); j.sleep(0); print("b-end") end); j.join(a); j.join(b); print("done")'
diff -u <(printf 'a-start\nb-start\nb-end\na-end\ndone\n') "$tmp/out"
check 2 'local j = require("judge.runtime"); local a,b; a=j.spawn(function() j.join(b) end); b=j.spawn(function() j.join(a) end); j.join(a)'
grep -Fq 'task join deadlock' "$tmp/err"
check 2 'local j = require("judge.runtime"); for i=1,32 do j.spawn(function() end) end'
grep -Fq 'task limit' "$tmp/err"
check 2 'local j = require("judge.runtime"); local a=j.spawn(function() j.sleep(0); error("child failed") end); j.join(a)'
grep -Fq 'child failed' "$tmp/err"
grep -Fq 'stack traceback:' "$tmp/err"
check 124 'local j = require("judge.runtime"); while true do j.sleep(100) end' 1s
check 6 'print(string.rep("x", 70000))'
[[ $(wc -c < "$tmp/out") == 65536 ]]
systemd-run --user --scope --quiet -p MemoryMax=128M -p MemorySwapMax=0 -p TasksMax=16 -p CPUQuota=100% \
    /usr/bin/bash -ec '
        IFS=: read -r hierarchy controllers group < /proc/self/cgroup
        [[ $hierarchy == 0 && -z $controllers && $group == /*.scope ]]
        dir=/sys/fs/cgroup$group
        [[ $(< "$dir/memory.max") == 134217728 && $(< "$dir/memory.swap.max") == 0 && $(< "$dir/pids.max") == 16 ]]
        read -r quota period < "$dir/cpu.max"
        [[ $quota =~ ^[0-9]+$ && $quota == "$period" ]]
        exec "$@"
    ' bash "$supervisor" "$runner" "$bwrap" "${libraries[@]}"
printf 'Lua runner embedding and caps passed\n'
