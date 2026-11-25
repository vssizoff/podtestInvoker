# Architecture and Implementation Record

## Verified host

- Linux x86-64; Zig 0.17.1 (`/usr/bin/zig`), pinned as the project minimum.
- Rootless Podman 6.2.0; REST ping over the configured user Unix socket succeeds. The daemon reports Libpod API 6.2.0 and Docker-compatible API 1.44.
- Podman `/v6.2.0/libpod/info` confirms rootless cgroup v2 and controllers `cpu`, `memory`, `pids`; delegation for a production Invoker service has not yet been verified.
- Go 1.27.4 and protoc 36.1 are installed.
- curl 8.23.0, Lua 5.5.1 and protobuf-c 1.5.2 are installed. The spikes used gRPC C core 1.84.3 from a locally unpacked package and NATS Server 2.12.6 built in a temporary directory.
- `/home/sizoff/programming/podtestInvokerOld` exists. Its files were not read or modified.

## Phase 0 implementation plan / ADRs

1. ADR-001: keep the service in Zig. Prefer official gRPC C core by Zig C interop, with protobuf-c or generated Protobuf bindings, only after dependency closure and Go interoperability tests are proven. Never substitute a home-grown gRPC/HTTP/2 transport. If C core cannot be pinned and deployed reproducibly, propose a small trusted Go transport sidecar for approval; do not implement it as an unapproved fact.
2. ADR-002: pin `nats-io/nats.zig` commit `7f1ad603b6495cb10fed5eee628d845fe214c601`, version 0.1.0, Zig minimum 0.17.0. Its source and README advertise explicit durable pull, fetch, ACK, NAK/redelivery, credentials/NKey, server-authenticated TLS and integration tests. mTLS is not implemented. The package is declared lazy until a runnable JetStream smoke test and TLS decision permit linking it into the executable. NATS C client is the fallback if mutually authenticated TLS is mandatory and the Zig client's TLS support is insufficient.
3. ADR-003: Podman REST through libcurl's Unix socket transport; require a bounded `/libpod/_ping`, exact `Libpod-Api-Version` match and explicit API family/version. Never use Podman CLI for runtime operations.
4. The gRPC spike passed plaintext localhost Heartbeat, Claim and Report plus INVALID_ARGUMENT and DEADLINE_EXCEEDED against a Go server generated from `proto/control.proto`. The protobuf-c 1.5.2 generator rejects proto3 optional. The spike generates its C bindings from a temporary wire-compatible copy with an explicit oneof for score presence and translates the header with `zig translate-c`. Production code generation against the canonical schema needs a generator that supports proto3 optional. Neither the spike transport nor its temporary schema is linked into the daemon.

## Existing wire contract and required extensions

Existing field numbers are preserved: HeartbeatRequest 1-5; ClaimRequest 1-3, with additive `process_epoch = 4`; ClaimResponse 1-3 plus fencing token 4 and descriptors source 5/bundle 6; Event 1-14 plus fencing token 15. Existing RPCs Heartbeat, Claim and Report remain; additive CreateArtifactUpload, RenewArtifactUpload, CompleteArtifactUpload and RefreshArtifacts are in the canonical schema. `source_url` means the submission/solution artifact; `bundle_url` means the immutable task revision execution bundle. They must not be swapped.

Absent: background lease renewal for executing runs, server-to-client cancellation, run limits, Claim scheduling, and reporting execution results. The opt-in Backend mTLS listener accepts artifact events and serves fenced `RenewLease` for existing leases. Explicit input preparation renews a short lease before transfer; the artifact daemon sends zero-capacity heartbeats. Additive field numbers only; never reuse existing numbers. Full worker integration and cross-version Go interop are release gates.

## Compatibility and integration matrix

| Area | Local evidence | Remaining gate |
|---|---|---|
| Zig | 0.17.1, Debug and ReleaseSafe built locally | CI builds |
| Podman | 6.2.0, Libpod 6.2.0 ping | AuthZ/ops/build/container test suite against declared versions |
| NATS Zig candidate | Durable consumers, fetch, explicit ACK, NAK/redelivery, fetch timeout, reconnect and server-authenticated TLS passed upstream tests with NATS 2.12.6. Full suite exited 1 on two KV cross-checks requiring `nats` CLI | Multi-Invoker tests, TLS credentials policy and production integration |
| gRPC / Protobuf | Current three RPCs, INVALID_ARGUMENT and DEADLINE_EXCEEDED passed against a loopback Go server | Reproducible production codegen, TLS/mTLS, auth metadata, streaming commands and reconnect tests |
| Lua | Lua 5.5.1 installed | Isolated Runner, sandbox and API implementation |
| cgroups | Rootless Podman applies CPU/RAM/swap/PID limits; live container checks read the effective cgroup values; timeout and OOM are distinguished from ordinary exits | Production systemd delegation, cgroup counter sampling, output-cap supervisor |

## Risks and blockers

- `serve-artifacts` connects to the Backend listener for upload recovery and artifact Report. It does not consume JetStream jobs. The Backend publisher requires an explicit `execution_ready: true` on the revision; unready jobs are not published. Production Claim scheduling, cancellation and terminal execution reports remain unimplemented.
- NATS candidate has no mTLS. External account/TLS termination or NATS C client needs a security decision if client certificates are required.
- Backend integration of USTAR v1 and Claim artifact descriptors, execution metadata schemas, and deployment-specific limits remains outstanding. See [the bundle integration guide](bundle-format.md).
- Rootless Podman socket access grants the Invoker broad host-user control. Never pass it to jobs, Lua, or workload containers.
- Current login cgroup hierarchy exposes controllers; production systemd service delegation is still unverified. Live resource acceptance validates Podman enforcement only for the test process and does not establish production service delegation.
- Host filesystems may not offer enforceable quotas; workspace/spool byte accounting and disk/project quota policy need deployment decisions.

## Vertical phases

1. Process identity, exclusive host-state lock, validated config/env overrides, host readiness diagnostics, unit tests, systemd/runbook.
2. Generated control protocol bindings and Go integration test; NATS durable consumer, claim, leases, commands, durable outbox.
3. Signed artifact downloads, hashes, agreed versioned bundles and race-safe extraction.
4. Versioned Podman adapter and manager ownership journal.
5. The resource and I/O engine is exercised by rootless Podman acceptance: effective CPU/RAM/swap/PID limits, OOM classification, cgroup sampling, monotonic watchdogs, binary stdio, disk-backed history and output caps, bounded pipe graphs, and group cancellation/cleanup. Results retain the last available cgroup sample; production service delegation and judging-daemon integration are not established by this test.
6. Isolated Lua 5.5 runner, RPC and scheduler.
7. Explicit supported Polygon Standard subset using the shared engine.
8. Crash recovery, integration/security/E2E tests and production hardening.

Phase 1 host diagnostics remain the installed executable entrypoint. Phase 2 now adds a typed job advertisement parser, a claim/ack decision handler, an append-only fsync event/lease journal, and a JetStream pull adapter/test executable. The claim handler is transport-injected; it does not fabricate Backend responses. The daemon is not wired to NATS or gRPC and continues to report `execution_ready: false`. No job can be claimed or executed by the installed binary. The historical project was not inspected: no files read, no files changed.

### Phase 2 spike status

`nats.zig` is linked only in opt-in acceptance builds. The standalone JetStream fixture covers capacity gates, explicit ACK validation, delayed NAK/redelivery, and malformed-message termination. The separate `-Dclaim-fixture=true` acceptance connects to real Backend Claim over mTLS and verifies that local persistence failure prevents ACK, and that redelivery reuses the persisted epoch and fence. Neither fixture enables production consumption.

The event/lease WAL is a bounded, private-directory, single-process journal. Records are length-bounded and CRC-checked, appends are fsynced, and partial final records are truncated on recovery. The drain reuses stored protobuf bytes and reserves space for durable ACK tombstones. Explicit compaction fsyncs a replacement, renames it over the WAL, and fsyncs the directory. It preserves pending events, retained lease records, the WAL high-water mark, and the latest per-run sequence. That sequence is separate from the WAL ordinal; the enqueue API also supplies the protobuf encoder with a random UUID. The Go spike uses this API. WAL v2 refuses v1 records without rewriting them; there is no automatic migration.

Tests cover an interrupted compaction sibling, reopening a compacted WAL, a torn ACK, and independent run sequences after reopen. These are recovery fixtures, not power-loss or filesystem fault-injection results. Compaction may temporarily need space for both files; run cursors and lease records still need an agreed retirement policy, and replay currently materializes the bounded WAL in memory. Fencing-aware Report replay, scheduled retries, and the production control loop remain open.

The local lease guard checks epoch/run/token and uses both wall and monotonic expiry. A loopback Go fixture exercises proposed renewal and a one-message cancel stream. Production authentication, command ordering/replay across reconnect, and supervisor cancellation are not validated by that test.

### Phase 3 progress

`src/workspace/download.zig` and its libcurl C transport implement HTTPS-only signed GET and fixed-length PUT. The URL must share HTTPS origin with the configured artifact endpoint; redirects, proxy use, credentials in URLs, and unverified TLS are disabled. GET verifies exact length and SHA-256 before no-replace publication. PUT rechecks exact size and digest and binds the base64 digest checksum header; it requires a 2xx response. Caller must reserve disk quota before calling the APIs.

`src/workspace/spool.zig` enforces a logical byte limit and a file-count limit in a private flat directory. It supports download, exact-length staging of a completed artifact, upload while holding the spool lock, and removal only after confirmation. It opens the configured path from `/` with `openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS)`, checks directory ownership/mode and holds an exclusive directory lock through quota scan, publication, transfer, or removal. A competing caller gets `SpoolBusy` and can retry. Existing file sizes count after restart; symlinks, hardlinks and non-regular entries fail closed. Host filesystem quotas and crash cleanup of named temporary files still need deployment policy.

`bash spikes/artifact-check.sh` uses a local HTTPS fixture to exercise certificate validation, cross-origin and credentialed URL rejection, redirect refusal, HTTP status classification, size and digest checks, timeouts, cancellation during transfer, retry, and contention between independently opened directory handles. A second client process checks that existing files count toward both quota limits after restart, symlinks are rejected, and repeated removal releases quota safely. The fixture supplies a static query parameter.

`src/workspace/extract.zig` contains a streaming USTAR v1 decoder and manifest validator on top of the parsed-entry writer. It requires a first `manifest.json`, validates ordered file inventory, sizes and hashes, rejects extensions/links/special types, and checks the complete archive digest before publishing with a no-replace rename. A `scripted_lua` bundle requires `runner.lua` and `runner_api_version: 1`; `standard` omits that field. Both use `format_version: 1`. Lua runtime capability negotiation and the `standard.json` payload schema are not implemented. Backend publication and pinned descriptors are covered by Go tests and real PostgreSQL/MinIO acceptance; the executable-specific acceptance is documented in [the upload contract](artifact-upload.md).

The writer resolves paths one component at a time relative to directory descriptors and rejects path collisions and limit overruns. Implicit parent directories count toward the entry limit; files/directories receive fixed private modes. The recovery helper removes interrupted staging trees under the same directory lock used by the writer. It matches the reserved `.extract-<32 lowercase hex digits>` naming pattern. The artifact-enabled process removes interrupted transfer directories and extraction staging under the instance lock before upload recovery. A failed directory sync after publication returns `WorkspacePublicationUncertain`.

The archive unit tests use generated USTAR fixtures and parsed-entry fixtures. The HTTPS integration test downloads USTAR archives produced by Go's `archive/tar`, verifies their size and digest, and publishes workspaces. Backend now uses `internal/artifact.BuildBundle` for Lua revision publication and has a listener that issues pinned descriptors for assigned USTAR revisions.

`spool.stage` persists a completed output with exact-length validation, hash, no-replace publication and file/directory sync. `spool.put` holds the same lock through revalidation and fixed-length HTTPS PUT. The opt-in executable links an mTLS gRPC C-core transport for Claim/refresh, artifact upload and artifact Report. It prepares only explicitly assigned attempts, persists process epoch, pinned descriptors and fence, and keeps execution disabled. Recovery reconciles ambiguous PUT/completion, syncs receipts before releasing spool space, and appends `ARTIFACT_CREATED` to the WAL before sending it. The WAL retries the same event until Backend confirms persistence. Production scheduling, container execution, terminal result delivery and Lua capability negotiation are still not active. See [the upload contract](artifact-upload.md).
