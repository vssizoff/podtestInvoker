# Calibration benchmark

`bench.zig` is a deterministic, CPU-bound loop (fixed `N = 100_000_000`).  The
invoker builds a `FROM scratch` image containing the static binary and runs it
several times at startup.  The median **raw CPU time** reported by the cgroup
(`cpu.stat: usage_usec`) is used to derive a normalisation factor:

```text
k = 1 / median_seconds
```

`container:cpu_time()` returns `raw_cpu_time * k`, so a runner can compare CPU
consumption across machines with different speeds.  The factor is only a
convenience for grading; it does not enforce any limit.

The image is built through the Podman HTTP API (no CLI calls), labelled with the
invoker instance id and removed on shutdown.  `build.sh` builds the same image
manually for debugging:

```bash
./assets/benchmark/build.sh localhost/podtest-benchmark:latest
```

The Dockerfile here and the inline Dockerfile in `src/calibration.zig` must stay
in sync:

```dockerfile
FROM scratch
COPY bench /bench
ENTRYPOINT ["/bench"]
```
