# podtest-invoker

A Linux-only test invoker for programming-contest style tasks.  It runs one Lua
script per run, lets that script drive rootless Podman containers over the
Podman HTTP API, and streams structured reports back to the backend over gRPC.

The invoker is written in Zig 0.17 and embeds Lua 5.5.  It never shells out to
`podman`: all container, image and network operations go through the rootless
Podman API socket.

## Features

- Rootless Podman through the HTTP API on the user socket.
- One bidirectional gRPC stream per run (`Invoker.Run`), bearer-token auth.
- Sandboxed Lua runner with coroutines: blocking API calls yield, so several
  containers can make progress concurrently.
- Secure task-archive extraction (`..`, absolute paths and symlink escapes are
  rejected).
- Per-run directories, per-run timeouts, immediate cancellation, startup
  cleanup of orphaned resources.
- Container stdout/stderr capture with a bounded 512 MiB history per stream,
  streaming and pipe modes.
- cgroup v2 CPU and memory accounting; CPU time normalised by a deterministic
  benchmark image.
- Multiple independent invoker instances can share one Podman daemon; every
  resource is labelled with `managed-by=invoker`, `invoker.instance=<id>` and
  `run=<run_id>`.

## Requirements

- Linux with cgroup v2 (`stat -fc %T /sys/fs/cgroup` → `cgroup2fs`).
- Rootless Podman with the user API socket enabled.
- Zig **0.17.x**.
- System libraries: `libnghttp2` and `zlib` (headers and runtime).
- `curl` with HTTP/2 for the integration tests, Python 3.10+ for the harness.

## Build

```bash
zig build            # zig-out/bin/podtest-invoker and zig-out/bin/bench
zig build test       # unit tests (no Podman needed)
zig build -Doptimize=ReleaseSafe
```

The vendored Lua sources live in `third_party/lua/src`; the reference benchmark
is built for `x86_64-linux-musl` and embedded into the invoker at build time.

## Podman setup

Enable the rootless API socket:

```bash
systemctl --user enable --now podman.socket
curl --unix-socket "$XDG_RUNTIME_DIR/podman/podman.sock" \
     http://d/v4.0.0/libpod/_ping
```

The invoker expects cgroup v2 `cpu` and `memory` controllers to be delegated to
the user manager.  Check:

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
```

It should contain `cpu memory`.  If the list is empty, enable delegation for the
user manager and re-login:

```bash
mkdir -p ~/.config/systemd/user/user@.service.d
printf '[Service]\nDelegate=yes\n' > ~/.config/systemd/user/user@.service.d/delegate.conf
systemctl --user daemon-reload
```

Podman's own rootless setup normally takes care of this.  `container:cpu_time()`
and `container:memory_peak()` read the container cgroup; if the container has no
cgroup path the values are reported as zero.

Image references passed to `container.create` / `image.pull` must be fully
qualified, e.g. `docker.io/library/alpine:3.20`.  The Podman HTTP API does not
resolve short names such as `alpine:latest`.

## Quick start

```bash
zig build
./examples/make-task.sh            # creates examples/task.tar.gz

mkdir -p /tmp/invoker/runs
./zig-out/bin/podtest-invoker \
  --listen 127.0.0.1:50051 \
  --token secret \
  --work-root /tmp/invoker/runs \
  --state-file /tmp/invoker/state.json \
  --no-calibration
```

Upload the example task and print the events (the harness is dependency-free):

```bash
python3 - <<'PY'
import sys
sys.path.insert(0, "tests")
import grpc_client as gc

archive = open("examples/task.tar.gz", "rb").read()
body = (
    gc.grpc_frame(gc.start_request("demo-1", timeout_ms=120_000))
    + gc.grpc_frame(gc.archive_chunk_request(archive))
    + gc.grpc_frame(gc.archive_end_request())
)
res = gc.call("http://127.0.0.1:50051", body, token="secret", timeout=180)
print("grpc-status:", res.status)
for event in res.events:
    print(event)
PY
```

The example runner pulls `docker.io/library/alpine:3.20`, mounts `solution/`
read-only, feeds stdin, captures stdout/stderr and reports a verdict.  See
[`examples/task/runner.lua`](examples/task/runner.lua).

## Configuration

Pass a JSON file with `--config PATH`.  Fields omitted from the file use the
defaults below; CLI flags override the file.

| Field | Default | Meaning |
| --- | --- | --- |
| `podman_socket` | `/run/user/<uid>/podman/podman.sock` | Rootless Podman API unix socket. When no config file is used, `$XDG_RUNTIME_DIR/podman/podman.sock` is used instead. |
| `listen` | `127.0.0.1:50051` | gRPC listen address, `host:port`. |
| `token` | *(required)* | Shared bearer token. |
| `work_root` | `$XDG_DATA_HOME/podtest-invoker/runs` | Per-run directories. |
| `state_file` | `$XDG_DATA_HOME/podtest-invoker/state.json` | Stable `instance-id` file. |
| `podman_api` | `v4.0.0` | Podman API version prefix. |
| `run_timeout_sec` | `300` | Default global run timeout. |
| `stdio_history_limit_bytes` | `536870912` (512 MiB) | Retained bytes per stdout/stderr stream. |
| `stop_grace_ms` | `500` | Grace period for `container:stop()`. |
| `calibration_runs` | `5` | Benchmark samples at startup (max 64). |
| `calibration_interval_sec` | `3600` | Background recalibration period (`0` disables). |
| `grpc_max_message_bytes` | `67108864` (64 MiB) | Maximum inbound gRPC message. |
| `event_chunk_bytes` | `1048576` (1 MiB) | Events larger than this are split into chunks. |
| `max_concurrent_runs` | `0` (unlimited) | Active runs across all connections. |
| `log_level` | `info` | `debug`, `info`, `warn`, `error`. |

Example:

```json
{
  "podman_socket": "/run/user/1000/podman/podman.sock",
  "listen": "127.0.0.1:50051",
  "token": "change-me",
  "work_root": "/var/lib/podtest-invoker/runs",
  "state_file": "/var/lib/podtest-invoker/state.json",
  "run_timeout_sec": 300,
  "stdio_history_limit_bytes": 536870912,
  "calibration_runs": 5,
  "event_chunk_bytes": 1048576,
  "max_concurrent_runs": 4,
  "log_level": "info"
}
```

### CLI flags

```text
--config PATH            JSON configuration file
--listen HOST:PORT       gRPC listen address (default 127.0.0.1:50051)
--token TOKEN            bearer token required from clients
--work-root PATH         directory for per-run directories
--state-file PATH        stable instance-id file
--podman-socket PATH     rootless Podman API unix socket
--podman-api PREFIX      Podman API version prefix (default v4.0.0)
--log-level LEVEL        debug|info|warn|error
--run-timeout-sec N      default run timeout (default 300)
--history-limit BYTES    per-stream stdio history limit (default 512 MiB)
--max-concurrent N       limit concurrent runs (0 = unlimited)
--no-calibration         skip the CPU benchmark at startup
--help
```

Environment variables: `PODTEST_INVOKER_TOKEN`, `PODTEST_INVOKER_LISTEN`,
`XDG_DATA_HOME`, `XDG_RUNTIME_DIR`.

### Running as a user service

```ini
# ~/.config/systemd/user/podtest-invoker.service
[Unit]
Description=podtest-invoker
After=podman.socket

[Service]
Type=simple
ExecStart=%h/.local/bin/podtest-invoker --config %h/.config/podtest-invoker/config.json
Restart=on-failure
Delegate=yes
KillMode=mixed

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now podtest-invoker.service
journalctl --user -u podtest-invoker -f
```

### Multiple instances

Each invoker needs its own `listen`, `token`, `work_root` and `state_file`.
Instances may share the Podman daemon.  Resources are scoped by the instance id
stored in `state_file`, so cleanup at startup only removes containers, images
and networks belonging to that instance, plus stale directories below its own
`work_root`.

## Protocol and runner API

- [`proto/invoker.proto`](proto/invoker.proto) — gRPC schema.
- [`docs/backend.md`](docs/backend.md) — transport, run lifecycle, archive
  upload, event chunking, cancellation and error statuses.
- [`docs/lua-api.md`](docs/lua-api.md) — Lua sandbox, coroutines, filesystem,
  images, networks, containers, stdio modes and reporting.

In short: send `RunStart`, upload the tar/tar.gz archive, send `RunArchiveEnd`,
then read `RunEvent` messages until `RunFinished`.  `RunStop` cancels the run.
A runner failure is not an RPC error; it is a `RunnerError` event followed by
`RunFinished{ok=false, status="runner_error"}`.

## CPU calibration

The invoker builds a `FROM scratch` image containing a static deterministic
benchmark (`assets/benchmark/bench.zig`), runs it several times through the
Podman API and computes

```text
k = 1 / median(raw_cpu_seconds)
```

`container:cpu_time()` returns raw cgroup CPU time multiplied by `k`; the raw
value is available as `container:raw_cpu_time()`.  Calibration runs at startup
and periodically in the background.  Use `--no-calibration` for tests or when
the benchmark image cannot be built.

To build the same image manually for debugging:

```bash
./assets/benchmark/build.sh localhost/podtest-benchmark:latest
```

## Tests

```bash
zig build test     # unit tests, no Podman
./tests/run.sh     # protocol edge cases + container end-to-end
```

`tests/run.sh` starts two invokers (one with `event_chunk_bytes = 64`), runs the
dependency-free Python harnesses and cleans up.  See
[`tests/README.md`](tests/README.md) for options and coverage.

## Isolation and security notes

- The gRPC endpoint has no TLS.  Bind it to loopback or a private network, or
  put a TLS-terminating proxy in front of it.
- Every call must present the shared token (`authorization: Bearer ...` or
  `x-invoker-token`).  The token is compared in constant time.
- Task archives are extracted beneath `<work_root>/<run_id>`; absolute paths,
  `..` components and symlinks that escape the run directory are rejected.
- The Lua sandbox removes `os`, `io`, `package`, `require`, `debug`, `dofile`,
  `loadfile` and `load`.  Filesystem access is limited to the run directory.
- Containers are rootless and can be constrained with `memory`, `network` and
  mounts.  The invoker itself never runs untrusted code on the host.
- Captured output is bounded by `stdio_history_limit_bytes`; older bytes are
  dropped and `container:history().truncated` becomes true.

## Repository layout

```text
src/
  main.zig              startup, config, signals
  config.zig            JSON configuration
  state.zig             persistent instance id
  cleanup.zig           startup orphan cleanup
  calibration.zig       benchmark image and CPU factor
  events.zig            event model and sinks
  podman/client.zig     Podman HTTP client
  run/manager.zig       run registry and archive uploads
  run/executor.zig      Lua runner entry point
  run/scheduler.zig     coroutine scheduler
  run/runtime.zig       containers, stdio, cgroups
  lua/lua.zig           Lua C API bindings
  lua/api.zig           Lua-visible API
  grpc/server.zig       HTTP/2 + gRPC server
  grpc/messages.zig     protobuf codec
  util/                 http, tar, fs, logging, clocks, ...
proto/invoker.proto     gRPC contract
docs/                   backend and Lua API documentation
examples/task/          example runner and task archive
assets/benchmark/       deterministic CPU benchmark
tests/                  integration harnesses
third_party/lua/        vendored Lua 5.5.1
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `error: MissingToken` | Provide `--token`, `token` in the config, or `PODTEST_INVOKER_TOKEN`. |
| `Podman API is not reachable` | `systemctl --user enable --now podman.socket`; check `podman_socket`. |
| Container create fails with an image error | Use a fully qualified reference (`docker.io/library/alpine:3.20`). |
| `cpu_time()` always 0 | cgroup v2 `cpu` controller is not delegated; see *Podman setup*. |
| `Failed to open /dev/net/tun` | Rootless networking is unavailable on the host; use `network = "none"` or fix slirp4netns/`/dev/net/tun`. |
| `duplicate run_id` (`INVALID_ARGUMENT`) | Run ids must be unique for the lifetime of the invoker process. |
| Port already in use | Change `--listen`; check `ss -ltnp`. |
