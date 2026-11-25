# Deployment

Run the Phase 1 host check with Zig 0.17.1 and the libcurl development package installed.

```sh
systemctl --user enable --now podman.socket
zig build -Doptimize=Debug
zig build test
bash spikes/host-check.sh
```

Provision a dedicated `podtest-invoker` account, private state directory owned by it with mode 0700, configuration under `/etc/podtest-invoker` readable by that account, and a rootless Podman socket under the same account. Give only that account access to its Unix socket. Verify cgroup v2 delegation of `cpu`, `memory` and `pids` for the eventual execution service before enabling workloads.

Install `deploy/podtest-invoker.service` in the dedicated account's user service manager (or system-wide under `/etc/systemd/user`). The unit uses that manager's state directory (`%S`) and `podman.socket`. Enable linger for unattended startup. It runs `serve-diagnostics` with `Type=simple` and handles SIGTERM/SIGINT. `check` is a preflight command and takes the same exclusive lock as the service. It returns nonzero on invalid config, unsafe or unavailable state directory, lock contention, socket failure, ping timeout, or API version mismatch. The `execution_ready` field remains false during Phase 1.
