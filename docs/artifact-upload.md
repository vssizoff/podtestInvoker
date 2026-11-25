# Artifact Upload Contract

**Status:** The opt-in Invoker prepares already-assigned runs, refreshes rejected download URLs without changing pinned inputs, resumes uploads from disk, and delivers `ARTIFACT_CREATED` from the WAL over mTLS. It does not consume JetStream jobs, execute submissions, or report execution results.

## Flow

1. Invoker stages a completed output in its private spool, obtains the exact size and raw SHA-256, and persists a stable client artifact ID plus run identity, kind and descriptor. Do not persist the signed URL or log it.
2. `CreateArtifactUpload` accepts the run lease, client artifact ID, kind and descriptor defined in `proto/control.proto`. Backend authenticates the Invoker, checks the active fence and quotas, and reserves a private object key. Repeating the same request returns the same artifact ID and key, with a fresh URL if needed. Reusing an ID with changed kind or descriptor is rejected.
3. Backend signs a short-lived, single-object PUT for the configured HTTPS origin. The initial profile sends exact `Content-Length` and `x-amz-checksum-sha256` (base64 of the raw digest); bind both to the signature. Do not require additional application headers for this transport. A refresh must not rebind the artifact to another object or descriptor. Reject unsupported grant profiles before starting PUT.
4. `CompleteArtifactUpload` takes the run lease and Backend artifact ID. Backend rechecks the fence, reads and hashes the exact stored bytes and copies them to a separate key that the PUT grant cannot modify. Repeated completion of the same upload is idempotent. Confirm first after an ambiguous PUT response; reissue/retry only for the same artifact and bytes if not yet present.
5. After Backend confirmation, Invoker durably records the artifact reference before releasing spool quota, then appends a stable-ID/sequence `ARTIFACT_CREATED` protobuf event containing the finalized Backend artifact ID and fence to the WAL. Neither HTTP 200 alone nor an expired or fenced grant authorizes final reporting.

## Reproduce the integration test

From Invoker, build the artifact-enabled binary (requires `protoc`, `protoc-gen-c`, gRPC C core and protobuf-c development libraries):

```sh
zig build -Dartifact-control=true -Doptimize=ReleaseSafe
```

In Backend, point `DATABASE_URL` and `S3_*` at disposable PostgreSQL and HTTPS S3-compatible storage, and set `SSL_CERT_FILE` to the S3 CA:

```sh
PODTEST_INVOKER_BINARY=/absolute/path/to/podtestInvoker/zig-out/bin/podtest-invoker \
PODTEST_ARTIFACT_ACCEPTANCE=1 PODTEST_S3_ACCEPTANCE=1 \
go test ./internal/artifact ./internal/judging -run 'TestS3SignedArtifact|TestArtifactControlIntegration' -count=1 -v
```

The standalone `invoker-artifacts` mode requires migration 003, an HTTPS `S3_URL`, `INVOKER_ARTIFACTS_ADDR`, `INVOKER_TLS_CERT`, `INVOKER_TLS_KEY`, and `INVOKER_CLIENT_CA`. Use a dedicated client CA; the verified client's certificate common name is the Invoker UUID. The service only handles already-assigned attempts and accepts `Report` only for `ARTIFACT_CREATED`. Backend commits before ACK; an exact replay can recover a lost ACK even after lease expiry, provided the stored fence still matches.

On Invoker, set `PODTEST_CONTROL_ENDPOINT` (`host:port`), `PODTEST_CONTROL_CA`, `PODTEST_CONTROL_CERT`, `PODTEST_CONTROL_KEY` (absolute PEM paths), `PODTEST_ARTIFACT_ORIGIN` (HTTPS origin), and optionally `PODTEST_ARTIFACT_CA`. Use one private state directory per instance. Commands share the exclusive instance lock; stop `serve-artifacts` before using the current operator handoff commands:

```sh
podtest-invoker prepare-assigned CONFIG JOB_JSON
podtest-invoker stage-artifact CONFIG RUN_UUID CLIENT_ARTIFACT_UUID runner_log TRUSTED_FILE
podtest-invoker serve-artifacts CONFIG
```

The integration test interrupts the process before upload completion, after completion commits but before its response, and after Report commits but before its ACK. It verifies exact WAL replay, one committed Backend event, and no new report after an acknowledged restart. It also checks that startup removes interrupted input staging and preserves the published workspace.

For the optional JetStream Claim acceptance, build with both `-Dartifact-control=true` and `-Dclaim-fixture=true`, and set `PODTEST_CLAIM_FIXTURE_PORT` to the port of a disposable loopback JetStream instance. The fixture uses an already-assigned run, forces a local persistence error before ACK, and verifies redelivery with the same pinned lease. The fixture does not execute jobs and is excluded from default builds.

`RenewLease` extends a live assigned or running lease to at least two minutes from the database clock. It authenticates the Invoker and checks the original epoch and fence. It does not revive expired or cancelled runs. `prepare-assigned` renews before an input-transfer attempt when at most 30 seconds remain; a response arriving after the local lease expires is rejected. There is no background renewal loop for executing jobs.

`serve-artifacts` sends an authenticated liveness heartbeat with zero capacity and load. The Backend updates existing Invoker records only; a liveness-only heartbeat does not register a new Invoker. Heartbeat failure is logged without skipping artifact recovery. The daemon does not consume jobs or advertise execution readiness.

## Remaining gates

- The future execution producer must use `src/result_outbox.zig` to verify all mandatory output receipts and encode the finalized references before appending terminal success. `serve-artifacts` delivers artifact events only. A known run's failure blocks only that run; a corrupt intent with unknown ownership blocks the drain. Retirement of stale WAL entries, intents, receipts and markers is not implemented.
- Configure expiration of abandoned `invoker/` staging objects without expiring `invoker-final/` objects. Provision a host filesystem quota for retained workspaces, intents and receipts. The tests cover renewal, signed PUT expiry, and rejection of completion on an expired run lease.
