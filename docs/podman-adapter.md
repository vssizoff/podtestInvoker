# Phase 4: Podman Adapter

The adapter uses versioned Libpod HTTP over a local Unix socket. The tested API
matrix currently contains rootless Podman 6.2.0 only; `/_ping` must advertise
the exact configured Libpod API version.

Typed runtime container creation accepts a local image ID and command. It
explicitly sets `network=none`, read-only rootfs, non-root user, no-new-privileges,
zero capabilities, private PID/IPC namespaces, and fixed CPU, memory, swap and
PID limits. There are no mounts, devices, host namespace options, port mappings,
or caller-provided Podman JSON. The internal bridge API is exercised and must
report `internal=true` and DNS disabled. Attaching runtime containers to a
run-owned network is intentionally not yet exposed.

Container lifecycle endpoints are implemented through Libpod: create, inspect,
start, wait, stop, kill and remove. A wait uses a server-side blocking request;
it has an HTTP deadline and an independent cancellation callback. Stop uses a
one-second grace period, not the final 500 ms policy. Logs stream to a bounded
caller sink without whole-response buffering. Current log chunks preserve
Podman framing and have not yet been separated into stdout/stderr.

Image inspect is implemented. Build is currently exposed only as
`buildTrusted`, not as an untrusted task API. It packages an explicit list of
file bytes into a bounded, deterministic tar context; it never traverses the
host filesystem and rejects duplicate and conflicting archive paths. It
uses a unique fixture tag, sets `pullpolicy=never`, `networkmode=none`, memory
and CPU caps, disables HTTP proxy inheritance, streams NDJSON messages with an
output cap, stops on build errors, and confirms the resulting image by inspect.
An external cancellation callback aborts the HTTP transfer. Because that cannot
guarantee Podman has stopped its server-side build, caller cleanup must still
reconcile tagged build resources. Do not use this API for arbitrary task
Containerfiles: build egress needs a separately enforced host policy.

Rootless integration acceptance covers the six Phase 4 adapter checklist items:
Unix socket, API version match and mismatch, image build and inspect, internal
network create and remove, container lifecycle, and streaming build and logs.
It checks build success and failure, writes the build stream to a private
temporary file, and verifies that the resulting image contains a context file.

```sh
PODTEST_PODMAN_SOCKET="$XDG_RUNTIME_DIR/podman/podman.sock" \
PODTEST_TEST_IMAGE_ID="$(podman image inspect --format '{{.Id}}' docker.io/library/alpine:3.20)" \
zig build test-podman
```

Not covered by adapter acceptance: egress-controlled builds, complete build resource
accounting and cancellation cleanup, digest-owned cache references, network
attachment, task-scoped opaque ownership handles/reconciliation, safe workspace
mounts and volumes, and version coverage beyond 6.2.0. These limitations keep
the adapter disconnected from production job execution.

## Phase 5: resource and I/O engine

The adapter resolves typed resource requests against local hard caps before
container creation. The live test reads `cpu.max`, `memory.max`,
`memory.swap.max` and `pids.max` inside a rootless container to verify the
applied limits. It separately verifies ordinary nonzero exit, a real OOM kill,
and a wall timeout that sends SIGKILL and waits for the exit status. OOM
classification uses Podman inspect, not the exit code alone.

`src/podman/group.zig` owns a bounded group from creation through removal.
It attaches every endpoint before starting any member, supervises monotonic
container and group deadlines, and kills and reaps members on cancellation
or a hard output limit. Startup is coordinated, not atomic. Setup and
cleanup calls have separate transport deadlines; cancellation is checked
between setup calls. A failed create with an unknown outcome still needs
external reconciliation.

The engine uses binary Libpod attach with stdin half-close and independent
stdout/stderr demultiplexing. It supports `none`, `once`, `realtime` and
stdout-to-stdin `pipe`. Realtime callbacks must not block. The engine keeps
4 KiB per pipe in userspace and stops reading from a producer when its queue
is full. Cycles are supported; the default policy closes only the affected
edge on peer exit. History records only enabled streams, retains the exact
prefix at a per-stream, per-container or group cap, and is available for
handoff after container removal. The caller owns the private spool directory.

Host-side cgroup v2 reads sample `cpu.stat`, `memory.events` and `memory.peak`.
Results retain the last available sample after removal; a short-lived
container may exit before a sample can be taken. OOM also uses Podman
inspect. This is not a guarantee of exact final CPU accounting on every exit.

The same `test-podman` command exercises live binary stdin/stdout/stderr,
realtime callbacks, output limits, wall timeout, a slow pipe consumer, a
cyclic pipe, peer exit, cancellation and partial setup rollback. The engine
is not wired to the judging daemon; `execution_ready` remains false.
