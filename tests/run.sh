#!/usr/bin/env bash
# Build the invoker and run the integration test suite.
#
#   ./tests/run.sh                 # edge cases + container end-to-end
#   RUN_E2E=0 ./tests/run.sh       # protocol/edge cases only (no containers)
#   CALIBRATION=1 ./tests/run.sh   # exercise the CPU benchmark at startup
#   KEEP=1 ./tests/run.sh          # keep the temporary work directory
#
# Environment:
#   PODTEST_TOKEN       shared token               (default: test-token)
#   PODTEST_PORT        main server port           (default: 50071)
#   PODTEST_CHUNK_PORT  small-event-chunk server   (default: 50072)
#   PODTEST_WORK_ROOT   use this directory instead of a temp directory
#   RUN_E2E             1/0, run container tests   (default: 1)
#   E2E_IMAGE           image for the container test
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)

TOKEN=${PODTEST_TOKEN:-test-token}
PORT=${PODTEST_PORT:-50071}
CHUNK_PORT=${PODTEST_CHUNK_PORT:-50072}
RUN_E2E=${RUN_E2E:-1}
KEEP=${KEEP:-0}

if [[ -n "${PODTEST_WORK_ROOT:-}" ]]; then
  work=$PODTEST_WORK_ROOT
  mkdir -p "$work"
  temp=0
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/podtest-tests.XXXXXX")
  temp=1
fi

main_pid=""
chunk_pid=""
cleanup() {
  local rc=$?
  if [[ -n "$main_pid" ]]; then kill "$main_pid" 2>/dev/null || true; fi
  if [[ -n "$chunk_pid" ]]; then kill "$chunk_pid" 2>/dev/null || true; fi
  if [[ -n "$main_pid" ]]; then wait "$main_pid" 2>/dev/null || true; fi
  if [[ -n "$chunk_pid" ]]; then wait "$chunk_pid" 2>/dev/null || true; fi
  if [[ $temp -eq 1 && $KEEP -eq 0 ]]; then
    rm -rf "$work"
  else
    echo "work directory kept: $work"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

cd "$root"

echo "== building =="
zig build

bin="$root/zig-out/bin/podtest-invoker"
mkdir -p "$work/runs" "$work/runs-chunk"

cat >"$work/chunk.json" <<JSON
{
  "listen": "127.0.0.1:${CHUNK_PORT}",
  "token": "${TOKEN}",
  "work_root": "${work}/runs-chunk",
  "state_file": "${work}/state-chunk.json",
  "event_chunk_bytes": 64,
  "grpc_max_message_bytes": 1048576,
  "run_timeout_sec": 60,
  "calibration_runs": 1,
  "log_level": "warn"
}
JSON

calibration_flag=--no-calibration
if [[ "${CALIBRATION:-0}" == "1" ]]; then
  calibration_flag=""
fi

echo "== starting servers (ports ${PORT} and ${CHUNK_PORT}) =="
"$bin" \
  --listen "127.0.0.1:${PORT}" \
  --token "$TOKEN" \
  --work-root "$work/runs" \
  --state-file "$work/state.json" \
  --log-level warn \
  $calibration_flag \
  >"$work/server.log" 2>&1 &
main_pid=$!

"$bin" --config "$work/chunk.json" $calibration_flag \
  >"$work/server-chunk.log" 2>&1 &
chunk_pid=$!

wait_port() {
  python3 - "$1" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
deadline = time.time() + 20
while time.time() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), 0.2):
            sys.exit(0)
    except OSError:
        time.sleep(0.05)
sys.exit(1)
PY
}

ready=1
wait_port "$PORT" || ready=0
wait_port "$CHUNK_PORT" || ready=0
if [[ $ready -ne 1 ]]; then
  echo "servers failed to start" >&2
  echo "--- server.log ---" >&2
  tail -50 "$work/server.log" >&2 || true
  echo "--- server-chunk.log ---" >&2
  tail -50 "$work/server-chunk.log" >&2 || true
  exit 1
fi

failed=0

echo
echo "== protocol edge cases =="
if ! python3 "$here/grpc_edge.py" \
  --url "http://127.0.0.1:${PORT}" \
  --chunk-url "http://127.0.0.1:${CHUNK_PORT}" \
  --work-root "$work/runs"; then
  failed=1
fi

if [[ "$RUN_E2E" == "1" ]]; then
  echo
  echo "== container end-to-end =="
  if ! "$root/examples/make-task.sh" >/dev/null; then
    echo "cannot build examples/task.tar.gz" >&2
    failed=1
  elif ! python3 "$here/grpc_e2e.py" \
    --url "http://127.0.0.1:${PORT}" \
    --archive "$root/examples/task.tar.gz"; then
    failed=1
  fi
fi

if [[ $failed -ne 0 ]]; then
  echo
  echo "== server log (main) =="
  tail -80 "$work/server.log" || true
  echo
  echo "== server log (chunked) =="
  tail -80 "$work/server-chunk.log" || true
  echo
  echo "TESTS FAILED"
  exit 1
fi

echo
echo "ALL TESTS PASSED"
