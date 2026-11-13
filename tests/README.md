# Integration tests

The suite starts real invoker processes and talks to them over gRPC (HTTP/2
prior knowledge).  It needs:

- a built binary (`zig build`),
- a reachable rootless Podman API socket (the invoker pings it at startup),
- `curl` with HTTP/2 support,
- Python 3.10+ (no third-party packages).

For the container end-to-end test, Podman must also be able to pull/run
`docker.io/library/alpine:3.20` (or whatever `E2E_IMAGE` points to).

## Run everything

```bash
./tests/run.sh
```

`run.sh` builds the project, starts two invokers on `127.0.0.1:50071` and
`127.0.0.1:50072` (the second with `event_chunk_bytes = 64`), waits for the
listeners, runs the harnesses, prints the server logs on failure and removes the
temporary work directory on success.

Common options:

```bash
RUN_E2E=0 ./tests/run.sh          # protocol/edge cases only, no containers
CALIBRATION=1 ./tests/run.sh      # run the CPU benchmark at startup
KEEP=1 ./tests/run.sh             # keep logs and run directories
PODTEST_TOKEN=secret ./tests/run.sh
PODTEST_PORT=6000 PODTEST_CHUNK_PORT=6001 ./tests/run.sh
E2E_IMAGE=localhost/myimage:1 ./tests/run.sh
```

## Harnesses

| File | Purpose |
| --- | --- |
| `grpc_client.py` | Protobuf/gRPC framing, Event decoding, chunk reassembly, `curl` transport. Importable helper and protocol reference. |
| `grpc_edge.py` | Authentication, routing, framing, request validation, archive sandboxing, cancellation, timeouts, event forwarding, duplicate run ids, chunked events. |
| `grpc_e2e.py` | Real containers: uploads `examples/task.tar.gz`, checks mounts, stdin/stdout/stderr, exit codes and reports. |

The harnesses can be run directly against an already running server:

```bash
python3 tests/grpc_edge.py \
  --url http://127.0.0.1:50071 \
  --chunk-url http://127.0.0.1:50072 \
  --work-root /path/to/runs

python3 tests/grpc_e2e.py \
  --url http://127.0.0.1:50071 \
  --archive examples/task.tar.gz \
  --image docker.io/library/alpine:3.20
```

`--work-root` is only used by the duplicate-run-id test, to wait until the first
run directory appears; without it the harness waits a fixed 0.5 s.

## What is covered

- missing/wrong token (`UNAUTHENTICATED`), `x-invoker-token` alternative
- unknown method (`UNIMPLEMENTED`), wrong content type
- malformed protobuf, compressed frames, duplicate `RunStart`
- archive chunk before `RunStart`, missing/incomplete archive, non-tar archive
- invalid `run_id` (slash, leading dot, `..`, empty)
- archive `..` escape, absolute paths, absolute and relative symlink escapes
- `RunStop` before archive end (`CANCELLED`) and after start (`OK`, stopped run)
- missing runner and invalid Lua reported as `RunnerError` events with RPC status 0
- exact forwarding of `TestVerdict`, `SubgroupScore`, `ProblemScore`, `TestStdio`
- global run timeout (`RunTimeout` + `RunFinished{status="timeout"}`)
- duplicate run id while the first run is active
- event splitting/reassembly with a 64-byte `event_chunk_bytes`
- container mounts, stdin, stdout, stderr, exit code and OOM flag
- cgroup CPU time / peak memory accounting after container exit

## Unit tests

```bash
zig build test
```

These do not need Podman.  They cover path normalisation and escape rejection,
nested filesystem helpers, tar extraction, container-create JSON and the Lua
sandbox/coroutine smoke test.
