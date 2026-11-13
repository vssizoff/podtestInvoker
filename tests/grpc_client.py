"""Minimal dependency-free gRPC client helpers for the invoker tests.

The transport is curl (HTTP/2 prior knowledge), because the test environment
does not ship the Python ``h2`` package.  Everything else -- protobuf
encoding/decoding, gRPC framing, chunk reassembly -- is implemented here by
hand so the harness also serves as executable protocol documentation.

Only the messages defined in ``proto/invoker.proto`` are handled.
"""

from __future__ import annotations

import io
import os
import struct
import subprocess
import tarfile
import tempfile
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# protobuf primitives
# ---------------------------------------------------------------------------


def varint(n: int) -> bytes:
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def ld(field: int, data: bytes) -> bytes:
    """Encode a length-delimited field."""
    return varint((field << 3) | 2) + varint(len(data)) + data


def vint(field: int, value: int) -> bytes:
    """Encode a varint field."""
    return varint((field << 3) | 0) + varint(value)


def read_varint(data: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(data):
            raise ValueError("truncated varint")
        b = data[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def fields(data: bytes) -> list[tuple[int, int, object]]:
    """Decode a protobuf message into ``(field_number, wire_type, value)``."""
    pos = 0
    out: list[tuple[int, int, object]] = []
    while pos < len(data):
        key, pos = read_varint(data, pos)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, pos = read_varint(data, pos)
        elif wire == 1:
            value = data[pos:pos + 8]
            pos += 8
        elif wire == 2:
            length, pos = read_varint(data, pos)
            value = data[pos:pos + length]
            pos += length
        elif wire == 5:
            value = data[pos:pos + 4]
            pos += 4
        else:
            raise ValueError(f"unsupported wire type {wire}")
        out.append((number, wire, value))
    return out


def grpc_frame(message: bytes) -> bytes:
    """Wrap one protobuf message in a gRPC frame."""
    return b"\x00" + struct.pack(">I", len(message)) + message


# ---------------------------------------------------------------------------
# RunRequest encoding
# ---------------------------------------------------------------------------


def start_request(run_id: str, runner: str = "runner.lua", timeout_ms: int = 0) -> bytes:
    inner = ld(1, run_id.encode()) + ld(2, runner.encode())
    if timeout_ms:
        inner += vint(3, timeout_ms)
    return ld(1, inner)


def archive_chunk_request(data: bytes) -> bytes:
    return ld(2, data)


def archive_end_request() -> bytes:
    return ld(3, b"")


def stop_request(reason: str = "stop") -> bytes:
    return ld(4, ld(1, reason.encode()))


# ---------------------------------------------------------------------------
# Event decoding
# ---------------------------------------------------------------------------

EVENT_NAMES = {
    1: "run_started",
    2: "test_started",
    3: "test_verdict",
    4: "subgroup_score",
    5: "problem_score",
    6: "build_log",
    7: "test_stdio",
    8: "runner_error",
    9: "run_finished",
    10: "run_timeout",
}


def _decode_double(raw: bytes) -> float:
    return struct.unpack("<d", raw)[0]


def _sub(data: bytes) -> dict[int, list[tuple[int, object]]]:
    out: dict[int, list[tuple[int, object]]] = {}
    for number, wire, value in fields(data):
        out.setdefault(number, []).append((wire, value))
    return out


def _first(sub: dict, number: int, default=None):
    items = sub.get(number)
    return items[0][1] if items else default


def decode_event(data: bytes) -> dict:
    """Decode a serialised ``Event`` oneof into a plain dict."""
    outer = _sub(data)
    for number, name in EVENT_NAMES.items():
        if number not in outer:
            continue
        payload = _first(outer, number)
        event: dict = {"kind": name}
        if name == "run_timeout":
            return event
        inner = _sub(payload if isinstance(payload, (bytes, bytearray)) else b"")
        if name == "run_started":
            event["run_id"] = _first(inner, 1, b"").decode(errors="replace")
            event["instance_id"] = _first(inner, 2, b"").decode(errors="replace")
        elif name == "test_started":
            event["n"] = _first(inner, 1, 0)
        elif name == "test_verdict":
            event["n"] = _first(inner, 1, 0)
            event["verdict"] = _first(inner, 2, b"").decode(errors="replace")
            if 3 in inner:
                event["score"] = _decode_double(_first(inner, 3))
            if 4 in inner:
                event["grader_data"] = bytes(_first(inner, 4))
        elif name == "subgroup_score":
            event["id"] = _first(inner, 1, b"").decode(errors="replace")
            event["score"] = _decode_double(_first(inner, 2, b"\x00" * 8))
            if 3 in inner:
                event["grader_data"] = bytes(_first(inner, 3))
        elif name == "problem_score":
            event["score"] = _decode_double(_first(inner, 1, b"\x00" * 8))
            if 2 in inner:
                event["grader_data"] = bytes(_first(inner, 2))
        elif name == "build_log":
            event["text"] = _first(inner, 1, b"").decode(errors="replace")
        elif name == "test_stdio":
            event["n"] = _first(inner, 1, 0)
            event["stdin"] = bytes(_first(inner, 2, b""))
            event["stdout"] = bytes(_first(inner, 3, b""))
            event["stderr"] = bytes(_first(inner, 4, b""))
        elif name == "runner_error":
            event["message"] = _first(inner, 1, b"").decode(errors="replace")
            event["traceback"] = _first(inner, 2, b"").decode(errors="replace")
        elif name == "run_finished":
            event["ok"] = bool(_first(inner, 1, 0))
            event["status"] = _first(inner, 2, b"").decode(errors="replace")
        return event
    return {"kind": "unknown", "raw": data}


# ---------------------------------------------------------------------------
# archives
# ---------------------------------------------------------------------------


def tar_bytes(files: dict[str, bytes | None]) -> bytes:
    """Build a gzip-compressed tar.

    A ``None`` value creates a directory entry.  A ``(target, "symlink")``
    tuple creates a symlink.
    """
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            if isinstance(data, tuple) and data[1] == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = data[0]
                tf.addfile(info)
            elif data is None:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tf.addfile(info)
            else:
                info.size = len(data)
                info.mode = 0o644
                tf.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def tar_from_directory(path: str) -> bytes:
    """Pack a directory (relative names) into a gzip tar."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for root, dirs, names in os.walk(path):
            dirs.sort()
            names.sort()
            rel_root = os.path.relpath(root, path)
            if rel_root != ".":
                info = tarfile.TarInfo(rel_root)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tf.addfile(info)
            for name in names:
                full = os.path.join(root, name)
                rel = os.path.relpath(full, path)
                info = tarfile.TarInfo(rel)
                info.size = os.path.getsize(full)
                info.mode = 0o644
                with open(full, "rb") as fh:
                    tf.addfile(info, fh)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------


@dataclass
class Result:
    returncode: int
    headers: dict[str, str] = field(default_factory=dict)
    events: list[dict] = field(default_factory=list)
    chunks: int = 0
    raw_events: list[bytes] = field(default_factory=list)
    stderr: str = ""

    @property
    def status(self) -> str | None:
        return self.headers.get("grpc-status")

    @property
    def message(self) -> str:
        return self.headers.get("grpc-message", "")

    def kinds(self) -> list[str]:
        return [e["kind"] for e in self.events]

    def first(self, kind: str) -> dict | None:
        for event in self.events:
            if event["kind"] == kind:
                return event
        return None

    def last(self, kind: str) -> dict | None:
        for event in reversed(self.events):
            if event["kind"] == kind:
                return event
        return None

    def count(self, kind: str) -> int:
        return sum(1 for e in self.events if e["kind"] == kind)


def _parse_headers(text: str) -> dict[str, str]:
    # Later occurrences win: gRPC trailers are the authoritative status.
    headers: dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return headers


def _parse_frames(raw: bytes) -> tuple[list[dict], int]:
    events: list[dict] = []
    pending: dict[int, tuple[int, bytes]] = {}
    chunk_count = 0
    pos = 0
    while pos + 5 <= len(raw):
        if raw[pos] != 0:
            raise ValueError(f"unexpected compression flag {raw[pos]}")
        length = struct.unpack(">I", raw[pos + 1:pos + 5])[0]
        payload = raw[pos + 5:pos + 5 + length]
        pos += 5 + length
        for number, _wire, value in fields(payload):
            if number == 1:  # RunEvent.event
                events.append(decode_event(value))
            elif number == 2:  # RunEvent.chunk
                chunk_count += 1
                sequence = total = None
                data = b""
                for n2, _w2, v2 in fields(value):
                    if n2 == 1:
                        sequence = v2
                    elif n2 == 2:
                        total = v2
                    elif n2 == 3:
                        data = v2
                if sequence is None or total is None:
                    raise ValueError("malformed EventChunk")
                pending[sequence] = (total, data)
                if sequence == total - 1:
                    whole = b"".join(pending[i][1] for i in range(total))
                    pending.clear()
                    events.append(decode_event(whole))
    return events, chunk_count


def call(
    base_url: str,
    body: bytes,
    *,
    path: str = "/invoker.v1.Invoker/Run",
    token: str | None = None,
    content_type: str = "application/grpc",
    timeout: float = 60.0,
    tmp_dir: str | None = None,
    extra_headers: list[tuple[str, str]] | None = None,
) -> Result:
    """Send a pre-framed request body and decode the response stream."""
    url = base_url.rstrip("/") + path
    with tempfile.TemporaryDirectory(dir=tmp_dir) as td:
        header_path = os.path.join(td, "headers")
        body_path = os.path.join(td, "body")
        cmd = [
            "curl", "-sS", "--http2-prior-knowledge",
            "-H", f"content-type: {content_type}",
            "-H", "te: trailers",
            "-D", header_path,
            "--data-binary", "@-",
            "-o", body_path,
            "--max-time", f"{timeout:g}",
        ]
        if token is not None:
            cmd += ["-H", f"authorization: Bearer {token}"]
        for key, value in extra_headers or []:
            cmd += ["-H", f"{key}: {value}"]
        cmd.append(url)
        proc = subprocess.run(cmd, input=body, capture_output=True)

        try:
            with open(header_path, "r", encoding="utf-8", errors="replace") as fh:
                headers = _parse_headers(fh.read())
        except FileNotFoundError:
            headers = {}
        try:
            with open(body_path, "rb") as fh:
                raw = fh.read()
        except FileNotFoundError:
            raw = b""

    events, chunks = _parse_frames(raw)
    return Result(
        returncode=proc.returncode,
        headers=headers,
        events=events,
        chunks=chunks,
        stderr=proc.stderr.decode(errors="replace"),
    )


# ---------------------------------------------------------------------------
# tiny assertion harness
# ---------------------------------------------------------------------------


class Harness:
    def __init__(self, title: str) -> None:
        self.title = title
        self.passed = 0
        self.failed = 0
        print(f"== {title} ==")

    def check(self, name: str, condition: bool, detail: str = "") -> None:
        if condition:
            self.passed += 1
            print(f"  ok   {name}")
        else:
            self.failed += 1
            suffix = f"  [{detail}]" if detail else ""
            print(f"  FAIL {name}{suffix}")

    def equal(self, name: str, actual, expected) -> None:
        self.check(name, actual == expected, f"got {actual!r}, want {expected!r}")

    def summary(self) -> int:
        total = self.passed + self.failed
        print(f"-- {self.title}: {self.passed}/{total} passed, {self.failed} failed")
        return self.failed
