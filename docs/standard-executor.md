# Standard Executor v1

Deploy the Backend that accepts progress reports before updating Standard
workers. Workers report `RUN_STARTED`, `BUILD_STARTED`, `BUILD_FINISHED`,
and `TEST_STARTED` through the same durable, ordered outbox as results.
Test results are still published together at the end of the run. When a
worker restarts execution before the result is durable, it reuses the
progress ordinals for the pinned task and replays any unacknowledged report.

An active run receives a cancellation request in `RenewLease`. The worker
stops execution, verifies removal of its owned Podman resources, and records
`RUN_CANCELLED` in the outbox. A lost acknowledgement is replayed after a
restart. A run that already entered final reporting may commit its result
before its lease expires. A pending cancellation prevents further lease
extension and prevents automatic retry after expiry.

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

- Languages `posix_sh`, `javascript`, `cpp23`, and `python314`, selected
  by operator-configured immutable local image IDs. Imported Polygon
  bundles declare a `languages` allowlist; the selected submission
  language must be on that list. Single-language bundles use `language`.
- Build `package_source`: the submitted `solution/source` is copied into
  a fixed recipe over the selected local base image. Only `FROM` and `COPY`
  are used; network is disabled and the image must have no `OnBuild` triggers.
- C++ submissions compile once in a supervised container using
  `/usr/local/bin/g++ -std=c++23 -O2` (`PODTEST_STANDARD_CPP23_IMAGE_ID`).
  Only the resulting binary is copied into the run image. A failed
  compilation yields `compilation_error` and zero points. Python uses
  `/usr/local/bin/python3.14` in isolated mode (`PODTEST_STANDARD_PYTHON314_IMAGE_ID`).
- Sequential independent tests, each with a fresh isolated container and
  the Phase 5 CPU, memory, PID, wall and bounded-stdio controls.
- Checkers `exact_bytes`, ASCII-whitespace-delimited `ascii_tokens`, and
  `testlib`. A `testlib` task supplies `checker/checker.cpp` and
  `checker/testlib.h` (1 MiB each). Set `PODTEST_TESTLIB_IMAGE_ID` to a
  trusted local GCC image with `/usr/local/bin/g++`. The compiler runs in
  a supervised container; only the compiled executable is copied into the
  checker image. The checker runs separately from the submission and
  gets the input, contestant output, and jury answer. Input and answer
  files may each be up to 32 MiB, subject to a 64 MiB combined budget
  across the task. `testset` defaults to `tests`.
- Group scoring `sum` or `all_or_nothing`; points are integer milli-points.
- Testlib `_points` is a fraction from 0 to 1; `_pc` is an integer
  percentage. `sum` includes earned partial points, whereas
  `all_or_nothing` requires every test to be accepted. Checker failures and
  invalid reports are testing errors rather than contestant verdicts.
- Result JSON is published atomically after tests and image cleanup, or as
  a terminal infrastructure error. An interrupted run has no `result.json`.

Unknown fields/features, unsafe paths, duplicate identifiers, missing
groups, unconfigured language images, non-rootless Podman and images with
build triggers are rejected. Validators, custom languages/templates,
arbitrary Containerfiles/commands, interactors, subtasks/dependencies, and
nontrivial Polygon scoring are not implemented. The producer must normalize into this
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
