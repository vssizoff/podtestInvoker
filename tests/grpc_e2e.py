#!/usr/bin/env python3
"""End-to-end container test for a running podtest-invoker.

Requires a working rootless Podman and network access to pull the test image
(or a locally cached image).  The test uploads the shipped example task
archive, runs it, and checks the reports produced by the runner.

Usage:
    python3 tests/grpc_e2e.py --url http://127.0.0.1:50071 \
        [--archive examples/task.tar.gz] [--image docker.io/library/alpine:3.20]
"""

from __future__ import annotations

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import grpc_client as gc  # noqa: E402

TOKEN = os.environ.get("PODTEST_TOKEN", "test-token")

EXIT_CODE_RUNNER = r"""
local IMAGE = "__E2E_IMAGE__"
local c = container.create{
  image = IMAGE,
  command = {"sh", "-c", "echo to-stdout; echo to-stderr >&2; exit 7"},
  stdin = false,
  stdout = true,
  stderr = true,
  network = "none",
  memory = "64m",
}
c:start()
local code, info = c:wait()
local out = c:stdout()
local errout = c:stderr()
report.test_started(1)
report.test_stdio(1, "", out, errout)
local ok = code == 7
  and out:find("to-stdout", 1, true) ~= nil
  and errout:find("to-stderr", 1, true) ~= nil
  and info.oom == false
report.test_verdict(1, ok and "OK" or "WA", ok and 1.0 or 0.0, tostring(code))
report.problem_score(ok and 1.0 or 0.0)
"""

CPU_RUNNER = r"""
local IMAGE = "__E2E_IMAGE__"
local c = container.create{
  image = IMAGE,
  command = {"sh", "-c", "i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done"},
  network = "none",
}
c:start()
local code = c:wait()
local raw = c:raw_cpu_time()
local normalised = c:cpu_time()
local peak = c:memory_peak()
report.build_log(string.format("cpu raw=%.6f normalised=%.6f peak=%d", raw, normalised, peak))
local ok = code == 0 and raw > 0 and normalised > 0 and peak > 0
report.problem_score(ok and 1.0 or 0.0)
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=os.environ.get("PODTEST_URL", "http://127.0.0.1:50071"))
    parser.add_argument(
        "--archive",
        default=os.path.join(ROOT, "examples", "task.tar.gz"),
    )
    parser.add_argument(
        "--image",
        default=os.environ.get("E2E_IMAGE", "docker.io/library/alpine:3.20"),
    )
    parser.add_argument("--timeout", type=float, default=180.0)
    args = parser.parse_args()

    h = gc.Harness("container end-to-end")

    archive_path = args.archive
    if not os.path.exists(archive_path):
        print(f"archive not found: {archive_path}", file=sys.stderr)
        print("run examples/make-task.sh first", file=sys.stderr)
        return 2

    with open(archive_path, "rb") as fh:
        example = fh.read()

    # ------------------------------------------------------------------
    # shipped example task: image pull, mount, stdin, stdout, stderr
    # ------------------------------------------------------------------
    run_id = f"e2e-example-{os.getpid()}"
    body = (
        gc.grpc_frame(gc.start_request(run_id, timeout_ms=120_000))
        + gc.grpc_frame(gc.archive_chunk_request(example))
        + gc.grpc_frame(gc.archive_end_request())
    )
    res = gc.call(args.url, body, token=TOKEN, timeout=args.timeout)
    h.equal("example task -> RPC ok", res.status, "0")
    h.check("example task -> no runner_error", res.first("runner_error") is None, str(res.kinds()))

    started = res.first("run_started")
    h.check("example task -> run_started", started is not None and started["run_id"] == run_id, repr(started))

    logs = [e["text"] for e in res.events if e["kind"] == "build_log"]
    h.check(
        "example task -> build log mentions image",
        any("example task" in line for line in logs),
        repr(logs),
    )

    stdio = res.first("test_stdio")
    h.check(
        "example task -> stdout contains mounted solution file",
        stdio is not None and b"solution-content" in stdio["stdout"],
        repr(stdio["stdout"][:200] if stdio else None),
    )
    h.check(
        "example task -> stdout contains stdin echo",
        stdio is not None and b"got:hello from stdin" in stdio["stdout"],
        repr(stdio["stdout"][:200] if stdio else None),
    )
    h.check(
        "example task -> stderr is captured",
        stdio is not None and b"this-goes-to-stderr" in stdio["stderr"],
        repr(stdio["stderr"][:200] if stdio else None),
    )

    verdict = res.first("test_verdict")
    h.check(
        "example task -> verdict OK",
        verdict is not None and verdict["verdict"] == "OK" and abs(verdict["score"] - 1.0) < 1e-9,
        repr(verdict),
    )
    problem = res.first("problem_score")
    h.check(
        "example task -> problem score 1.0",
        problem is not None and abs(problem["score"] - 1.0) < 1e-9,
        repr(problem),
    )
    finished = res.last("run_finished")
    h.check(
        "example task -> run_finished ok",
        finished is not None and finished["ok"] is True and finished["status"] == "ok",
        repr(finished),
    )

    # ------------------------------------------------------------------
    # explicit exit code / stderr / OOM flag
    # ------------------------------------------------------------------
    script = EXIT_CODE_RUNNER.replace("__E2E_IMAGE__", args.image)
    archive = gc.tar_bytes({"runner.lua": script.encode()})
    body = (
        gc.grpc_frame(gc.start_request(f"e2e-exit-{os.getpid()}", timeout_ms=120_000))
        + gc.grpc_frame(gc.archive_chunk_request(archive))
        + gc.grpc_frame(gc.archive_end_request())
    )
    res = gc.call(args.url, body, token=TOKEN, timeout=args.timeout)
    h.equal("exit-code task -> RPC ok", res.status, "0")
    h.check("exit-code task -> no runner_error", res.first("runner_error") is None, str(res.kinds()))
    stdio = res.first("test_stdio")
    h.check(
        "exit-code task -> stdout and stderr captured",
        stdio is not None
        and b"to-stdout" in stdio["stdout"]
        and b"to-stderr" in stdio["stderr"],
        repr(stdio),
    )
    verdict = res.first("test_verdict")
    h.check(
        "exit-code task -> exit code 7 reported",
        verdict is not None and verdict["verdict"] == "OK",
        repr(verdict),
    )
    finished = res.last("run_finished")
    h.check(
        "exit-code task -> run_finished ok",
        finished is not None and finished["ok"] is True,
        repr(finished),
    )

    # ------------------------------------------------------------------
    # cgroup CPU / memory accounting survives container exit
    # ------------------------------------------------------------------
    script = CPU_RUNNER.replace("__E2E_IMAGE__", args.image)
    archive = gc.tar_bytes({"runner.lua": script.encode()})
    body = (
        gc.grpc_frame(gc.start_request(f"e2e-cpu-{os.getpid()}", timeout_ms=120_000))
        + gc.grpc_frame(gc.archive_chunk_request(archive))
        + gc.grpc_frame(gc.archive_end_request())
    )
    res = gc.call(args.url, body, token=TOKEN, timeout=args.timeout)
    h.equal("cpu-accounting task -> RPC ok", res.status, "0")
    h.check("cpu-accounting task -> no runner_error", res.first("runner_error") is None, str(res.kinds()))
    logs = [e["text"] for e in res.events if e["kind"] == "build_log"]
    line = next((text for text in logs if "cpu raw=" in text), "")
    m = re.search(r"raw=([0-9.]+) normalised=([0-9.]+) peak=(\d+)", line)
    h.check(
        "cpu-accounting task -> cpu_time and memory_peak are non-zero",
        m is not None
        and float(m.group(1)) > 0
        and float(m.group(2)) > 0
        and int(m.group(3)) > 0,
        repr(line),
    )
    problem = res.first("problem_score")
    h.check(
        "cpu-accounting task -> score 1.0",
        problem is not None and abs(problem["score"] - 1.0) < 1e-9,
        repr(problem) + " logs=" + repr(logs),
    )

    return h.summary()


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
