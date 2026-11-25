# podtestInvoker chat recap

This recap covers the documented Phase 2–3 integration gaps and the acceptance results for the resource and I/O engine, the sandboxed Lua runner, and the first Standard Executor. Production execution remains disabled with `execution_ready=false`.

## Phase 2 · Control plane

- JetStream and mTLS Claim fixtures verified redelivery, persistence before ACK, and reuse of the pinned lease fence on retry. Production job consumption, scheduling, and Claim status handling still need to be connected. The artifact service sends liveness heartbeats with zero advertised capacity. [Control API](docs/control-api.md) · [Artifact upload](docs/artifact-upload.md)
- Lease renewal and cancellation were exercised in fixtures. Executing jobs still need background renewal and a cancel stream that handles ordering and replay after reconnect and reaches the execution supervisor. [Architecture](docs/architecture.md#phase-2-spike-status)
- The durable event log can replay stored events after a restart. Production Report still needs replay that checks the current lease fence, scheduled retries, and a retention policy for run cursors and lease records. WAL v2 requires a separate migration plan for v1 data. [Architecture](docs/architecture.md#phase-2-spike-status)

## Phase 3 · Workspace and artifacts

- Integration tests with PostgreSQL, mTLS, and HTTPS MinIO covered pinned downloads, SHA-256 verification, atomic USTAR workspace publication, and upload recovery after lost completion or Report responses. The tested flow prepares already-assigned runs. Acceptance on the deployed services with their actual certificates and object storage remains open. [Artifact upload](docs/artifact-upload.md) · [Bundle format](docs/bundle-format.md#9-remaining-integration-gates)
- The result outbox can require finalized artifact receipts before terminal success. Production execution still needs to connect that API to its result encoder and Report path. Artifact recovery currently delivers `ARTIFACT_CREATED` events. [Artifact upload](docs/artifact-upload.md#remaining-gates)
- Deployment still needs filesystem quotas for retained workspaces and spool state, expiration for abandoned staging objects, and a retention policy for stale local records. Backend integration still needs stable failure and URL-refresh status handling, Lua capability negotiation, and a live check with a Backend-produced Standard v1 bundle. [Artifact upload](docs/artifact-upload.md#remaining-gates) · [Bundle format](docs/bundle-format.md#9-remaining-integration-gates)

## Phase 5 · Resource and I/O Engine

- Closed after Debug and ReleaseSafe acceptance on rootless Podman. Tests covered CPU, memory, swap and PID limits, four stdio modes, bounded disk-backed history, pipe backpressure, cancellation and rollback. [Podman adapter](docs/podman-adapter.md)

## Phase 6 · Lua process

- Closed for runner acceptance. The opt-in Lua 5.5 runner uses Bubblewrap, resource limits and a private authenticated Unix RPC channel. Tests exercise the same request validator used by the supervisor.
- Debug and ReleaseSafe live tests showed that one Lua coroutine could drain a container’s stdout while another waited on a different container. The test harness supplied and verified the cgroup limits.
- Invoker-owned job dispatch and cgroups, workspace operations, and the full Lua API v1 remain open. [Lua runner](docs/lua-runner.md)

## Phase 7 · Standard Executor

- Closed for the documented v1 subset. A verified USTAR bundle and pinned submission feed an offline build for POSIX shell or JavaScript. The executor runs sequential tests on rootless Podman, checks exact bytes or ASCII tokens, and scores groups in integer thousandths of a point.
- A live run exposed a Podman timeout when killing a container with a backed-up attach stream. Closing the stream before killing the container fixed the regression. Debug and ReleaseSafe unit tests, Standard acceptance, and Podman regressions passed. Cancellation left no `result.json`, and no Phase 7 containers, image tags, or fixture directories remained.
- Backend Polygon normalization and production job dispatch remain outstanding. Custom languages, `testlib` checkers, and interactors are outside the v1 subset. [Standard Executor](docs/standard-executor.md)

## Phase 8 · Hardening (partial)

- Added a locked ownership journal, periodic recovery, and `sweep-resources`. Eight live rootless Podman rounds recovered 48 containers, internal networks, and temporary image tags in total, with cross-instance and shared base image checks.
- Verified SIGKILL outbox replay and the standalone JetStream fixture. Added a ReleaseSafe CPU calibration command and the `install-diagnostics` staging target. Untagged build leftovers, fleet load and production dispatch/reporting remain open. [Phase 8 runbook](docs/phase8.md)
- Connected the opt-in one-slot Standard worker to the Backend durable queue, pinned claims, rootless execution, artifact staging and fixed-ordinal reporting. Verified a real shell submission and replay after SIGKILL between terminal commit and ACK. Verified one replacement after an expired lease, execution in `serve-standard` and shutdown via SIGTERM. The target deployment still needs configuration and validation. [Phase 8 runbook](docs/phase8.md)
