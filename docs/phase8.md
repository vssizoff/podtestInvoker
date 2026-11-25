# Phase 8 hardening

The local diagnostics acceptance checks passed. Full Phase 8 acceptance is still open: production dispatch and end-to-end recovery have not been verified. All service commands keep `execution_ready: false`.

## Crash recovery

The resource journal lives in the locked state directory. It fsyncs an intent before creating a container, an internal network, or a temporary tagged image. The Standard executor acceptance uses it for builds and test containers. The network path is exercised by the recovery fixture. The journal is independent of the lease, workspace and event spool.

`serve-diagnostics` checks the journal at startup and every 30 seconds. `sweep-resources CONFIG` is the one-shot operator command; stop the service first. Both take the same directory inode lock. Recovery checks for rootless Podman, skips the current epoch, and requires a matching local intent, name or tag, and all ownership labels. It removes containers first, then networks, then temporary image tags. It never prunes by label or forcibly deletes shared images. It does not touch volumes or published workspaces. Keep the state directory private and stable, and dedicate the rootless account and Podman socket to the instance. A lock protects only users of the same directory inode; a shared socket is not a security boundary.

A missing resource leaves an unconfirmed intent unresolved: an interrupted client does not prove the server stopped processing create. Before recovery deletes a resource, it persists the verified ID so a subsequent 404 can clear the intent if the delete response was lost. The one-shot command exits nonzero for rejected or unresolved records. Investigate while the service is stopped; clear unresolved records only after verifying that the original request cannot complete and that no owned resource remains. The journal caps reservations at 256 records. Individual Libpod calls have timeouts; an entire sweep may span several calls. The service checks for shutdown between records.

## Acceptance and calibration

Set `PODTEST_PODMAN_SOCKET`, `PODTEST_LIBPOD_API_VERSION` (the exact `_ping` response version), and `PODTEST_TEST_IMAGE_ID` (a local Alpine-compatible image ID), then run:

```sh
zig build test-janitor -Doptimize=Debug
zig build test-janitor -Doptimize=ReleaseSafe
zig build test-janitor-load -Doptimize=ReleaseSafe
zig build test-outbox-crash -Doptimize=ReleaseSafe
zig build install-diagnostics -Doptimize=ReleaseSafe --prefix ./zig-out/diagnostics
```

The Podman crash fixture verifies lock contention, rejects a mismatched Invoker ID, recovers resources after SIGKILL while the peer stays live, and checks that a repeat sweep is a no-op and the shared base image survives. Eight rounds passed with two simultaneous owners per round and 48 recovered resources. A separate outbox fixture verifies byte-for-byte replay after SIGKILL before ACK and confirms the local ACK survives reopen; it uses a fixture reporter, not Backend Report. The standalone JetStream gate, redelivery and persist-before-ACK fixture passed against NATS Server 2.11.14. These are component tests, not a production scheduler load test.

`podtest-invoker calibrate-cpu CONFIG REFERENCE_CPU_NS` runs only in ReleaseSafe and takes the instance lock. Benchmark `podtest-mix64-v1` warms up and takes the median of seven thread CPU-time samples pinned to one permitted logical CPU. The factor is `reference_cpu_ns / median_cpu_ns`. To establish a fleet reference, record the median on the reference host using the same binary and use it for subsequent measurements. Record compiler/build, CPU model and policy separately. Run on an idle node; measurements are estimates, not a cross-architecture guarantee. The command emits JSON and does not apply, persist or advertise the factor. Raw execution metrics are unchanged.

## Dev deployment check

The single-slot `serve-standard` worker ran on the persistent `podtest-dev` Compose stack with rootless Podman, local mTLS artifact control and HTTPS MinIO. The Backend's `python3 deploy/smoke-authoring.py --standard` signed in through Dex, published a normalized Standard ZIP through HTTP, and verified `accepted` and `1.000000` through the attempts API and PostgreSQL. A submission queued before the worker started was also accepted. The resource journal was empty after execution. This checks one local deployment, not production readiness or fleet behavior.

## Remaining release gates

The opt-in Standard worker passed a real submission on disposable PostgreSQL, HTTPS MinIO, JetStream and rootless Podman. The test publishes a normalized Standard ZIP through the Backend manager and submits `exec cat` through the regular submission service. It kills the Invoker after the final database commit while the Report response is withheld. The restarted Invoker receives an exact duplicate ACK, the database retains `accepted` and `1.000000`, and a new event with the stale fence is rejected. The test also expires a separate lease and checks that Backend queues exactly one replacement with a new run ID. `serve-standard` executes that replacement and shuts down on SIGTERM. See `spikes/standard-e2e.sh` to rerun the check.

- Reconcile interrupted builds that leave untagged Podman/Buildah resources. Adopt a retention policy for unresolved intents and retained workspaces.
- Exercise real JetStream/Backend multi-Invoker scheduling and crash points during Claim, build and active execution. Run bounded fleet load and soak tests.
- Complete cgroup, quota, certificate and artifact checks in the target deployment. Standard detects an invalid lease through renewal. The explicit cancellation command stream, Lua dispatch and calibration reporting remain separate work.
