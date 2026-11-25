# Standard Executor v1

`src/standard/contract.zig` owns the initial Backend/Invoker contract. The
outer bundle remains the common USTAR v1 format; it must declare
`execution_format: "standard"` and version 1. `standard.json` is a separate,
strict JSON object with unknown and duplicate fields rejected:

```json
{
  "version": 1,
  "language": "posix_sh",
  "build": "package_source",
  "checker": "exact_bytes",
  "limits": {
    "memory_bytes": 67108864,
    "swap_bytes": 0,
    "pids": 32,
    "cpu_quota_micros": 100000,
    "wall_ms": 1000,
    "output_bytes": 4096
  },
  "groups": [{"id": "samples", "scoring": "sum"}],
  "tests": [{
    "id": "sample-1",
    "group": "samples",
    "input": "tests/sample.in",
    "answer": "tests/sample.out",
    "points_milli": 1000
  }]
}
```

The only enabled feature set is:

- Languages `posix_sh` and `javascript`, selected by operator-configured
  immutable local image IDs. No image pull or language-defined recipe.
- Build `package_source`: the submitted `solution/source` is copied into
  a fixed recipe over the selected local base image. Only `FROM` and `COPY`
  are used; network is disabled and the image must have no `OnBuild` triggers.
- Sequential independent tests, each with a fresh isolated container and
  the Phase 5 CPU, memory, PID, wall and bounded-stdio controls.
- Checkers `exact_bytes` and ASCII-whitespace-delimited `ascii_tokens`.
- Group scoring `sum` or `all_or_nothing`; points are integer milli-points.
- Result JSON is published atomically only after every test finishes and
  image cleanup succeeds. A partial run has no `result.json`.

Unknown fields/features, unsafe paths, duplicate identifiers, missing
groups, unconfigured language images, non-rootless Podman and images with
build triggers are rejected. Validators, custom languages/templates,
arbitrary Containerfiles/commands, Polygon testlib checkers, interactors,
subtasks/dependencies, nontrivial Polygon scoring, and backend event/artifact
reporting are not implemented. The producer must normalize into this
explicit v1 subset or reject the task; it must not silently downgrade.

Live acceptance requires local Alpine and Node images, rootless Podman, and
uses both language paths. Run it in Debug and ReleaseSafe:

```sh
PODTEST_PODMAN_SOCKET="$XDG_RUNTIME_DIR/podman/podman.sock" \
PODTEST_TEST_IMAGE_ID="$(podman image inspect --format '{{.Id}}' docker.io/library/alpine:3.20)" \
PODTEST_TEST_NODE_IMAGE_ID="$(podman image inspect --format '{{.Id}}' docker.io/library/node:26-alpine3.23)" \
zig build test-standard
```

This target exercises extraction from USTAR, source pinning, trusted offline
build, both checkers, score calculation, timeout/output/runtime verdicts,
cleanup and result publication. It also verifies cancellation between tests
does not publish a result. It is an executor fixture, not production job dispatch; the
main daemon keeps `execution_ready=false` until the remaining execution and
reporting gates are implemented.
