# Phase 6: Lua runner acceptance

The standalone Linux x86-64 runner is opt-in and links against Lua 5.5.
Standalone mode takes a text script on stdin. Supervised mode receives the
script over a private Unix socketpair. Stdout is a bounded runner log and
stderr carries setup failures or Lua errors with a bounded traceback. Run
the fixture from a non-root account with Bubblewrap and a systemd user
manager with cgroup v2 CPU, memory and PID controllers:

```sh
zig build test-lua-runner -Dlua-runner=true
PODTEST_PODMAN_SOCKET="$XDG_RUNTIME_DIR/podman/podman.sock" \
PODTEST_TEST_IMAGE_ID="$(podman image inspect --format '{{.Id}}' docker.io/library/alpine:3.20)" \
zig build test-lua-podman -Dlua-runner=true -Doptimize=ReleaseSafe
```

The acceptance supervisor starts Bubblewrap with separate user, mount,
PID, network, IPC and UTS namespaces and a non-root UID/GID inside the
sandbox. It mounts only the runner and the required runtime libraries,
read-only, and passes no workspace or Podman socket. The test verifies
the CPU, memory, swap and PID limits on its enclosing systemd scope.
Before Lua evaluation the runner clears its environment, closes extra
descriptors, applies rlimits and installs a default-deny seccomp filter.
The host supervisor tests cancellation, a monotonic wall deadline and
process-group cleanup.

Lua is limited to a 256 KiB text script, an 8 MiB Lua heap, one million
counted VM instructions, 64 KiB of stdout, and 32 scheduled tasks including
the entry point. Only the base, string, table, math, UTF-8 and coroutine
libraries are loaded; file and code loaders are removed. `require` serves
only `judge.runtime`. Its `spawn`, `join` and `sleep` functions support
cooperative scheduling. The fixture checks interleaving, join deadlock,
child error propagation and a wall-time cutoff enforced by the test harness.

RPC validates kernel sender credentials, a random run ID and token,
increasing request IDs, deadlines, method and payload bounds. The fixture
exposes only `fixture_echo` and yieldable `stdout_read(handle)`. In the
live test the first coroutine waits for container 1 while the second
drains container 2 to EOF. Only then does the host release container 1.
The live target fails when the rootless Podman socket or image ID is missing.

This is acceptance for the Phase 6 runner fixture, not a production
`scripted_lua` executor. The installed Invoker does not dispatch assigned
runs to this supervisor. The scope is owned by the test harness, and the
fixture has no workspace operations, task-provided modules, general
container lifecycle RPC, or complete Lua API v1. `execution_ready` stays
false.
