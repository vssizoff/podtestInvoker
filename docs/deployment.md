# Deployment

Run the host check with the pinned Zig toolchain and the libcurl development package installed. Set `PODTEST_LIBPOD_API_VERSION` to the exact version advertised by the local socket if it differs from the example config.

```sh
systemctl --user enable --now podman.socket
zig build -Doptimize=Debug
zig build test
bash spikes/host-check.sh
```

Provision a dedicated `podtest-invoker` account, private state directory owned by it with mode 0700, configuration under `/etc/podtest-invoker` readable by that account, and a rootless Podman socket under the same account. Give only that account access to its Unix socket. Verify cgroup v2 delegation of `cpu`, `memory` and `pids` for the eventual execution service before enabling workloads.

## Opt-in Standard worker

Build with `-Dartifact-control=true -Dstandard-worker=true`. Run `podtest-invoker serve-standard CONFIG` to consume the Backend-owned durable Standard queue with one slot. `work-standard-once CONFIG` processes one run or resumes one previously pinned run. The diagnostics unit still uses `serve-diagnostics`.

Set `PODTEST_NATS_URL`, `PODTEST_CONTROL_ENDPOINT`, `PODTEST_CONTROL_CA`, `PODTEST_CONTROL_CERT`, `PODTEST_CONTROL_KEY`, `PODTEST_ARTIFACT_ORIGIN` and `PODTEST_ARTIFACT_CA` as applicable. The client certificate common name must match the Invoker UUID. Standard requires pinned local image IDs in `PODTEST_STANDARD_SH_IMAGE_ID` and `PODTEST_STANDARD_JS_IMAGE_ID` for continuous service. Set the exact Podman API version in config or `PODTEST_LIBPOD_API_VERSION`. The worker checks for at least 2 GiB available on the state filesystem before it pulls work. It also requires 16,384 free inodes, except on Btrfs when inode counts are not reported. Apply deployment filesystem quotas separately.

Backend needs its regular API, `worker` and `invoker-artifacts` processes. `invoker-artifacts` needs an HTTPS `S3_URL`, `INVOKER_ARTIFACTS_ADDR`, `INVOKER_TLS_CERT`, `INVOKER_TLS_KEY` and `INVOKER_CLIENT_CA`. The revision package upload accepts normalized Standard v1 ZIPs with `standard.json` and its referenced `tests/` files. Enable only the language declared in `standard.json` and set the contest task maximum score to cover the total points. Polygon import remains diagnostic.

Install `deploy/podtest-invoker.service` in the dedicated account's user service manager (or system-wide under `/etc/systemd/user`). The unit uses that manager's state directory (`%S`) and `podman.socket`. Enable linger for unattended startup. It runs `serve-diagnostics` with `Type=simple` and handles SIGTERM/SIGINT. `check` is a preflight command and takes the same exclusive lock as the service. It returns nonzero on invalid config, unsafe or unavailable state directory, lock contention, socket failure, ping timeout, or API version mismatch. Production execution remains disabled. See [Phase 8](phase8.md) for packaging, recovery, and calibration.
