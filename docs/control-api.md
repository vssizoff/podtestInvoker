# Backend Control API

Source of truth: `proto/control.proto` (`podtest.invoker.v1`, `podtest/internal/invokerpb`). Existing methods are Heartbeat, Claim, Report. Field numbers and Kind numeric values are documented in `docs/architecture.md` and must remain stable.

The canonical schema includes artifact grant, renewal, completion and download refresh, plus fence and descriptor fields. The opt-in Backend artifact listener handles those methods and Claim for already-assigned attempts. Production lease renewal, cancellation, event ingestion and Invoker wiring remain open. `source_url` is the solution artifact URL and `bundle_url` is the immutable task revision bundle URL. Event score is an exact canonical decimal string, not a floating-point number.

For Backend task-bundle production, see [Bundle Format v1 integration guide](bundle-format.md). Backend generates `manifest.json` and the USTAR archive for new `scripted_lua` publications, copying the validated `runner_api_version` into the v1 manifest. `ClaimResponse` includes the descriptors of the pinned source and bundle. Lua runtime capability negotiation and the Standard task schema remain separate acceptance items.

`spikes/grpc/run.sh` builds a loopback Go test server and exercises all three existing RPCs from Zig through gRPC C core. The diagnostic executable has no remote control-plane connection. See `proto/control-v2-proposal.proto` for the review draft. Before integration, agree on claim status mapping, command replay after reconnect, renewal deadlines and the server's upload confirmation semantics.

The spike requires Go, `protoc-gen-go` v1.36.10, `protoc-gen-go-grpc` v1.5.1, `protoc-gen-c` and the gRPC C core and protobuf-c headers and shared libraries. Set `PODTEST_GRPC_PREFIX` if the gRPC SDK is installed outside the system search path. The script builds everything else in a temporary directory and binds its test server to loopback.

The Report test runs three client processes against one Go server. The first assigns a UUID and a per-run sequence, persists the event, and sees `UNAVAILABLE` after the server records receipt. The second replays the stored message, persists the duplicate ACK, and compacts the WAL. The third reopens the WAL and confirms it sends no Report. The server checks equality of the original and replayed protobuf messages.

A separate test-only `LeaseFixture` service uses the proposed message definitions without changing the canonical `Control` service. The client applies a successful renewal, verifies that the fixture rejects a wrong fencing token, and passes a `CancelRun` from a one-message gRPC stream to the local lease guard. A later renewal cannot reopen the guard. This is not a long-lived watcher and does not test reconnect or replay of commands.

The Phase 2 delivery handler depends on an injected Claim transport. The JetStream integration test uses a real broker, with Claim and start supplied by a local test fixture. The fixture fsyncs a lease record to `event-outbox.wal` and verifies that the broker confirms the ACK before start is called. If ACK confirmation fails or the lease expires before start, execution does not start. Production Claim status mapping and lease/fencing tokens require Backend adoption of the additive protocol proposal.
