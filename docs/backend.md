# Backend protocol

The invoker exposes a single gRPC method over HTTP/2 (h2c, no TLS):

```proto
service Invoker {
  rpc Run(stream RunRequest) returns (stream RunEvent);
}
```

The full schema is in [`proto/invoker.proto`](../proto/invoker.proto).  This
document describes the wire behaviour implemented by the server.

## Transport and authentication

- HTTP/2 prior knowledge (h2c).  There is no TLS and no HTTP/1.1 fallback.
- The server accepts **one `Run` stream per TCP connection**.  Open a new
  connection for every run; do not multiplex multiple runs on one connection.
- `content-type` must start with `application/grpc`.
- Every call must carry the shared token in one of these headers:
  - `authorization: Bearer <token>`
  - `x-invoker-token: <token>`
- Messages are normal gRPC frames: `0x00`, 4-byte big-endian length, payload.
  Compressed messages (`0x01`) are not supported and are rejected.
- Maximum inbound message size is `grpc_max_message_bytes` (default 64 MiB).

## Run lifecycle

```
client                                            server
  |-- RunRequest{start} --------------------------->|
  |-- RunRequest{archive_chunk} ------------------->|   (zero or more)
  |-- RunRequest{archive_end} --------------------->|
  |                                                | extract archive
  |<------------------------ RunEvent{run_started} |
  |<------------------------ RunEvent{event} ...    |   (runner events)
  |<------------------------ RunEvent{run_finished} |
  |<------------------------ trailers grpc-status=0 |
```

### 1. `RunStart`

| Field | Required | Meaning |
| --- | --- | --- |
| `run_id` | yes | 1..128 characters `[A-Za-z0-9_.-]`, must not start with `.`. Used as the run directory name, so it must be unique per invoker process. |
| `runner` | no | Entry script inside the archive, default `runner.lua`. |
| `timeout_ms` | no | Per-run timeout in milliseconds. `0` uses the configured default (300 000 ms). |

`RunStart` must be the first message.  A second `RunStart`, or an archive
chunk before `RunStart`, terminates the RPC with `INVALID_ARGUMENT`.

### 2. Archive upload

- Send the task archive as any number of `archive_chunk` messages, in order.
- `archive_end` marks the end of the archive and starts the run.
- The server accepts a plain `.tar` or a gzip-compressed `.tar.gz` (detected by
  the gzip magic bytes).
- The archive is streamed to a private file under
  `<work_root>/.incoming/`; the maximum size is
  `max(grpc_max_message_bytes, 16 MiB)`.
- Extraction is sandboxed:
  - absolute paths, `..` components and paths that resolve outside the run
    directory are rejected (`INVALID_ARGUMENT`);
  - symlinks are created as symlinks, but later entries that would traverse
    them outside the run directory are rejected;
  - device nodes and FIFOs are ignored.
- If the client half-closes the stream before `archive_end`, the RPC fails with
  `INVALID_ARGUMENT` (`archive incomplete`).

The run directory is `<work_root>/<run_id>/`; the archive contents are
extracted at its root.  A `solution/` directory in the archive is therefore
available to the runner as `solution/...`.  The directory is removed when the
run finishes (containers are stopped and removed first); set `keep_run_dirs` in
the configuration or pass `--keep-run-dirs` to keep it for inspection.

### 3. Events

Events are sent as `RunEvent` messages:

- `RunEvent.event` — one complete serialised `Event`.
- `RunEvent.chunk` — a fragment of a serialised `Event`.

If the serialised `Event` is larger than `event_chunk_bytes` (default 1 MiB),
the server splits it into consecutive `EventChunk` messages.  For one event:

- `sequence` starts at `0` and increases by one;
- `total` is the number of fragments;
- `data` are the raw bytes.

Concatenate `data` for `sequence = 0..total-1` and parse the result as an
`Event`.  Fragments of different events are never interleaved, so a client can
reassemble each event as it arrives.

The first event of every run is always `RunStarted{run_id, instance_id}`.
The last event is always `RunFinished{ok, status}`:

| `status` | `ok` | Meaning |
| --- | --- | --- |
| `ok` | `true` | Runner completed normally. |
| `timeout` | `false` | Global run timeout expired. A `RunTimeout` event precedes it. |
| `stopped` | `false` | Cancelled via `RunStop`, client disconnect, or server shutdown. |
| `runner_error` | `false` | Uncaught Lua error. A `RunnerError` event precedes it. |

After `RunFinished` the server closes the response stream with trailers
`grpc-status: 0`.

### 4. Cancellation

- `RunRequest.stop{reason}` cancels a running run:
  - container processes are killed immediately;
  - the executor stops at the next scheduler tick;
  - the run still emits `RunFinished{ok=false, status="stopped"}`;
  - the RPC itself succeeds (`grpc-status: 0`), so clients can read the final
    events.
- `RunStop` before `archive_end` has no run to cancel and terminates the RPC
  with `CANCELLED` (`grpc-status: 1`).
- If the client resets or closes the connection, the run is cancelled and its
  containers are removed.
- On server shutdown (SIGINT/SIGTERM) all active runs are cancelled, their
  containers are removed, and the connections are closed.

## Error statuses

Errors are reported as trailers (and a `grpc-message`).  A stream that was
rejected before any response data is sent uses a trailers-only response.

| Situation | `grpc-status` |
| --- | --- |
| Success | `0` |
| Cancelled (`RunStop` before archive end) | `1` |
| Malformed protobuf / bad gRPC framing | `3` |
| Duplicate `RunStart`, chunk before start, archive already ended | `3` |
| Invalid archive, path escape, absolute path, unsupported entry | `3` |
| Invalid `run_id` or duplicate run id | `3` |
| Wrong `content-type` | `3` |
| Compressed gRPC message | `3` |
| Message larger than `grpc_max_message_bytes` | `8` |
| `max_concurrent_runs` reached or server shutting down | `8` |
| Unknown method/path | `12` |
| Internal error (Podman failure, out of memory, ...) | `13` |
| Missing or wrong token | `16` |

A runner failure is **not** an RPC error: the RPC succeeds with
`grpc-status: 0` and the failure is visible as a `RunnerError` event followed
by `RunFinished{ok=false, status="runner_error"}`.  The same applies to a
missing runner script or invalid Lua syntax.

## Concurrency and resource limits

- Each run executes on its own executor thread; the connection thread owns the
  HTTP/2 session and only moves framed bytes.
- `max_concurrent_runs` (default `0` = unlimited) limits the number of
  simultaneously active runs across all connections.
- The run timeout covers the whole run, including image builds and container
  execution.  Timers and sleeps are interrupted by cancellation and timeout.
- Captured container output is bounded by `stdio_history_limit_bytes`
  (default 512 MiB per stream).  `TestStdio` events carry the bytes the runner
  explicitly reports, not the whole history.

## Minimal client example

The client must send three kinds of messages on the same stream:

```text
RunRequest{ start = RunStart{ run_id = "demo-1", runner = "runner.lua" } }
RunRequest{ archive_chunk = <bytes of task.tar.gz> }     # repeated
RunRequest{ archive_end = RunArchiveEnd{} }
```

then read `RunEvent` messages until `RunFinished`.

The repository contains a dependency-free Python integration harness in
[`tests/`](../tests) that builds the gRPC frames by hand, uploads an archive,
reassembles chunked events and exercises every error status described above.
`tests/run.sh` is the entry point.
