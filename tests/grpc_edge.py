#!/usr/bin/env python3
"""Protocol and edge-case tests for a running podtest-invoker.

Usage:
    python3 tests/grpc_edge.py --url http://127.0.0.1:50071 \
        [--chunk-url http://127.0.0.1:50072] [--work-root DIR]

The harness only needs curl; no Python gRPC libraries are required.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import grpc_client as gc  # noqa: E402

TOKEN = os.environ.get("PODTEST_TOKEN", "test-token")

# Unique-ish prefix so repeated harness runs against the same server do not
# collide on run ids.
PREFIX = f"edge-{int(time.time())}-{os.getpid()}"
_counter = 0


def new_run_id(tag: str) -> str:
    global _counter
    _counter += 1
    return f"{PREFIX}-{tag}-{_counter}"


def body(start: bytes, archive: bytes | None = None, stop: bytes | None = None) -> bytes:
    out = gc.grpc_frame(start)
    if archive is not None:
        out += gc.grpc_frame(gc.archive_chunk_request(archive))
        out += gc.grpc_frame(gc.archive_end_request())
    if stop is not None:
        out += gc.grpc_frame(stop)
    return out


def run_script(
    url: str,
    script: str,
    *,
    tag: str,
    timeout_ms: int = 5000,
    runner: str = "runner.lua",
    stop: bytes | None = None,
    **kwargs,
) -> gc.Result:
    archive = gc.tar_bytes({"runner.lua": script.encode()})
    return gc.call(
        url,
        body(gc.start_request(new_run_id(tag), runner=runner, timeout_ms=timeout_ms), archive, stop),
        token=TOKEN,
        **kwargs,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=os.environ.get("PODTEST_URL", "http://127.0.0.1:50071"))
    parser.add_argument("--chunk-url", default=os.environ.get("PODTEST_CHUNK_URL"))
    parser.add_argument("--work-root", default=os.environ.get("PODTEST_WORK_ROOT"))
    args = parser.parse_args()

    h = gc.Harness("gRPC edge cases")
    url = args.url

    # ------------------------------------------------------------------
    # authentication and routing
    # ------------------------------------------------------------------
    archive = gc.tar_bytes({"runner.lua": b'report.build_log("hi")\n'})
    payload = body(gc.start_request(new_run_id("auth")), archive)

    res = gc.call(url, payload, token=None)
    h.equal("missing token -> UNAUTHENTICATED", res.status, "16")

    res = gc.call(url, payload, token="wrong")
    h.equal("wrong token -> UNAUTHENTICATED", res.status, "16")

    res = gc.call(
        url,
        payload,
        token=None,
        extra_headers=[("x-invoker-token", TOKEN)],
    )
    h.equal("x-invoker-token header is accepted", res.status, "0")

    res = gc.call(url, payload, token=TOKEN, path="/nope")
    h.equal("unknown method -> UNIMPLEMENTED", res.status, "12")

    res = gc.call(url, payload, token=TOKEN, content_type="text/plain")
    h.equal("wrong content-type -> INVALID_ARGUMENT", res.status, "3")

    # ------------------------------------------------------------------
    # framing and request validation
    # ------------------------------------------------------------------
    res = gc.call(url, gc.grpc_frame(b"\xff\xff\xff"), token=TOKEN)
    h.equal("malformed protobuf -> INVALID_ARGUMENT", res.status, "3")

    compressed = b"\x01" + gc.grpc_frame(gc.start_request(new_run_id("gz")))[1:]
    res = gc.call(url, compressed, token=TOKEN)
    h.equal("compressed gRPC frame -> INVALID_ARGUMENT", res.status, "3")

    run_id = new_run_id("dup")
    dup = gc.grpc_frame(gc.start_request(run_id)) + gc.grpc_frame(gc.start_request(run_id))
    res = gc.call(url, dup, token=TOKEN)
    h.equal("duplicate RunStart -> INVALID_ARGUMENT", res.status, "3")

    res = gc.call(url, gc.grpc_frame(gc.archive_chunk_request(b"junk")), token=TOKEN)
    h.equal("chunk before RunStart -> INVALID_ARGUMENT", res.status, "3")

    res = gc.call(url, gc.grpc_frame(gc.start_request(new_run_id("noend"))), token=TOKEN)
    h.equal("missing archive -> INVALID_ARGUMENT", res.status, "3")

    res = gc.call(
        url,
        gc.grpc_frame(gc.start_request(new_run_id("incomplete")))
        + gc.grpc_frame(gc.archive_chunk_request(archive[:10])),
        token=TOKEN,
    )
    h.equal("incomplete archive -> INVALID_ARGUMENT", res.status, "3")

    for bad_id in ("has/slash", ".hidden", "..", ""):
        res = gc.call(
            url,
            body(gc.start_request(bad_id), archive),
            token=TOKEN,
        )
        h.equal(f"invalid run_id {bad_id!r} -> INVALID_ARGUMENT", res.status, "3")

    # ------------------------------------------------------------------
    # archive sandboxing
    # ------------------------------------------------------------------
    escape_cases = {
        "parent escape": {"../escape.txt": b"owned"},
        "absolute path": {"/etc/passwd": b"owned"},
        "absolute symlink": {"link": ("/etc", "symlink")},
        "relative symlink escape": {"link": ("../../outside", "symlink")},
    }
    for name, files in escape_cases.items():
        archive = gc.tar_bytes(files)
        res = gc.call(
            url,
            body(gc.start_request(new_run_id("escape")), archive),
            token=TOKEN,
        )
        h.equal(f"archive {name} -> INVALID_ARGUMENT", res.status, "3")

    res = gc.call(
        url,
        body(gc.start_request(new_run_id("badtar")), b"this is not a tar archive"),
        token=TOKEN,
    )
    h.equal("non-tar archive -> INVALID_ARGUMENT", res.status, "3")

    # ------------------------------------------------------------------
    # cancellation
    # ------------------------------------------------------------------
    res = gc.call(
        url,
        gc.grpc_frame(gc.start_request(new_run_id("stop-early")))
        + gc.grpc_frame(gc.archive_chunk_request(archive[:10]))
        + gc.grpc_frame(gc.stop_request("cancel me")),
        token=TOKEN,
    )
    h.equal("stop before archive end -> CANCELLED", res.status, "1")

    res = run_script(
        url,
        'report.build_log("before stop")\nsleep(5)\nreport.test_started(1)\n',
        tag="stop",
        timeout_ms=30_000,
        stop=gc.stop_request("enough"),
    )
    h.equal("stop after start -> RPC ok", res.status, "0")
    finished = res.last("run_finished")
    h.check(
        "stop after start -> run_finished{stopped}",
        finished is not None and finished["status"] == "stopped",
        repr(finished),
    )
    h.check(
        "stop after start -> no test_started event",
        res.count("test_started") == 0,
        str(res.kinds()),
    )

    # ------------------------------------------------------------------
    # runner errors are events, not RPC errors
    # ------------------------------------------------------------------
    res = run_script(url, 'report.build_log("x")\n', tag="missing", runner="missing.lua")
    h.equal("missing runner -> RPC ok", res.status, "0")
    h.check("missing runner -> runner_error event", res.first("runner_error") is not None, str(res.kinds()))
    finished = res.last("run_finished")
    h.check(
        "missing runner -> status runner_error",
        finished is not None and finished["status"] == "runner_error",
        repr(finished),
    )

    res = run_script(url, "this is not lua !!!", tag="badlua")
    h.equal("invalid Lua -> RPC ok", res.status, "0")
    h.check("invalid Lua -> runner_error event", res.first("runner_error") is not None, str(res.kinds()))

    # ------------------------------------------------------------------
    # event forwarding
    # ------------------------------------------------------------------
    script = r"""
print("hello from the runner")
report.build_log("build says hi")
report.test_started(1)
report.test_verdict(1, "OK", 1.0, "grader-bytes")
report.subgroup_score("sub1", 0.5, "sub-grader")
report.problem_score(0.99, "problem-grader")
report.test_stdio(1, "in-bytes", "out-bytes", "err-bytes")
local h = spawn(function()
  sleep(0.01)
  return "child"
end)
assert(h:join() == "child")
"""
    res = run_script(url, script, tag="events")
    h.equal("normal run -> RPC ok", res.status, "0")
    kinds = res.kinds()
    h.check(
        "normal run -> run_started first",
        kinds[:1] == ["run_started"],
        str(kinds),
    )
    h.check(
        "normal run -> run_finished last",
        kinds[-1:] == ["run_finished"],
        str(kinds),
    )
    started = res.first("run_started")
    h.check("run_started carries run_id", started is not None and started["run_id"].startswith(PREFIX), repr(started))
    h.check("run_started carries instance_id", started is not None and len(started["instance_id"]) > 0, repr(started))

    verdict = res.first("test_verdict")
    h.check(
        "test_verdict fields are forwarded",
        verdict is not None
        and verdict["n"] == 1
        and verdict["verdict"] == "OK"
        and abs(verdict["score"] - 1.0) < 1e-9
        and verdict.get("grader_data") == b"grader-bytes",
        repr(verdict),
    )
    subgroup = res.first("subgroup_score")
    h.check(
        "subgroup_score fields are forwarded",
        subgroup is not None
        and subgroup["id"] == "sub1"
        and abs(subgroup["score"] - 0.5) < 1e-9
        and subgroup.get("grader_data") == b"sub-grader",
        repr(subgroup),
    )
    problem = res.first("problem_score")
    h.check(
        "problem_score fields are forwarded",
        problem is not None
        and abs(problem["score"] - 0.99) < 1e-9
        and problem.get("grader_data") == b"problem-grader",
        repr(problem),
    )
    stdio = res.first("test_stdio")
    h.check(
        "test_stdio bytes are forwarded",
        stdio is not None
        and stdio["stdin"] == b"in-bytes"
        and stdio["stdout"] == b"out-bytes"
        and stdio["stderr"] == b"err-bytes",
        repr(stdio),
    )
    finished = res.last("run_finished")
    h.check(
        "normal run -> run_finished{ok}",
        finished is not None and finished["ok"] is True and finished["status"] == "ok",
        repr(finished),
    )

    # ------------------------------------------------------------------
    # global timeout
    # ------------------------------------------------------------------
    res = run_script(url, "sleep(10)\n", tag="timeout", timeout_ms=200)
    h.equal("timeout -> RPC ok", res.status, "0")
    h.check("timeout -> run_timeout event", res.first("run_timeout") is not None, str(res.kinds()))
    finished = res.last("run_finished")
    h.check(
        "timeout -> status timeout",
        finished is not None and finished["ok"] is False and finished["status"] == "timeout",
        repr(finished),
    )

    # ------------------------------------------------------------------
    # duplicate run id while the first run is still active
    # ------------------------------------------------------------------
    run_id = new_run_id("active")
    active_archive = gc.tar_bytes({"runner.lua": b"sleep(3)\n"})
    results: list[gc.Result] = []

    def first_run() -> None:
        results.append(
            gc.call(
                url,
                body(gc.start_request(run_id, timeout_ms=30_000), active_archive),
                token=TOKEN,
            )
        )

    t = threading.Thread(target=first_run)
    t.start()
    try:
        if args.work_root:
            deadline = time.time() + 5
            while time.time() < deadline and not os.path.isdir(os.path.join(args.work_root, run_id)):
                time.sleep(0.02)
        else:
            time.sleep(0.5)
        res = gc.call(
            url,
            body(gc.start_request(run_id, timeout_ms=30_000), active_archive),
            token=TOKEN,
        )
        h.equal("duplicate active run_id -> INVALID_ARGUMENT", res.status, "3")
    finally:
        t.join(timeout=30)
    h.check("first run of duplicate id completed", len(results) == 1 and results[0].status == "0")

    # ------------------------------------------------------------------
    # event chunking (second server with a tiny event_chunk_bytes)
    # ------------------------------------------------------------------
    if args.chunk_url:
        big = "x" * 500
        res = run_script(
            args.chunk_url,
            f'report.build_log("{big}")\n',
            tag="chunk",
            timeout_ms=10_000,
        )
        h.equal("chunked server -> RPC ok", res.status, "0")
        h.check("large event is split into chunks", res.chunks > 1, f"chunks={res.chunks}")
        log = res.first("build_log")
        h.check(
            "chunked event reassembles exactly",
            log is not None and log["text"] == big,
            f"len={len(log['text']) if log else -1}",
        )
        finished = res.last("run_finished")
        h.check(
            "chunked server -> run_finished ok",
            finished is not None and finished["ok"] is True,
            repr(finished),
        )

    return h.summary()


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
