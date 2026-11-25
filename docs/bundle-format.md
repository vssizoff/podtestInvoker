# Backend Integration Guide: Immutable Task Bundles

**Status:** Backend uses `internal/artifact.BuildBundle` for new `scripted_lua` revision publications. The opt-in Backend artifact listener serves signed URLs and descriptors for pinned USTAR revisions of already-assigned attempts. Older ZIP and Polygon publications are not converted. A Zig integration client materialized a Backend-built Lua bundle and its pinned source from HTTPS MinIO after an mTLS Claim. See the [artifact upload contract](artifact-upload.md) for integration limits.

This document is intended to let Backend implement the producer side without requiring task authors to construct an Invoker bundle. The intended pipeline is:

```text
author input -> Backend import/validation -> immutable normalized revision
             -> manifest + USTAR bundle -> object storage + signed URL
             -> Claim returns URL and trusted size/SHA-256 -> Invoker verifies
```

Task authors continue using the existing task authoring/import format. They do not write `manifest.json`, calculate bundle file hashes, choose tar headers, or assemble the archive. Backend owns normalization, manifest generation, archive serialization, immutable storage, and the descriptor returned to Invoker.

## 1. Ownership and Version Fields

There are three different version concepts. Do not overload one field for another:

| Field | Set by | Meaning |
| --- | --- | --- |
| `format_version` | Backend bundle producer | Version of this container/manifest contract. Current value: `1`. |
| `execution_format` | Backend from normalized revision | `standard` or `scripted_lua`; must match the claimed job. |
| `execution_format_version` | Backend selects from the agreed Invoker capability contract | Version of normalized input semantics consumed by the Invoker. Current supported value: `1` for each format. |
| `runner_api_version` | Task author selects in task configuration; Backend validates and copies it from the immutable revision into the manifest | Version of the Lua runner API requested by `runner.lua`. Required for `scripted_lua`; currently only `1` is accepted. Omit for `standard`. |

`execution_format_version` is not the Lua API version. The author should not set bundle `format_version` or `execution_format_version` directly. Once API negotiation is implemented, Backend must reject unsupported author-requested API versions at publication and Invoker must independently check the version before running Lua.

## 2. Revision Build Pipeline

For each immutable task revision, Backend should:

1. Import the author-provided package using Backend's existing validation pipeline. For Polygon tasks, Backend performs Polygon import and normalization; Invoker does not.
2. Resolve task defaults, language definitions, tests, test groups, checkers, limits, scoring rules, and runner configuration into a deterministic Backend-owned normalized tree. Reject unsupported required task features instead of silently dropping them.
3. Select `execution_format` (`standard` or `scripted_lua`) and the currently supported `execution_format_version` (`1`). Confirm that this selection agrees with the task/job being scheduled.
4. For `scripted_lua`, require a normalized `runner.lua` at bundle root. Validate the author's requested API version, store it with the immutable revision, and emit it as `runner_api_version` in the manifest. Do not put secrets, signed URLs, Podman credentials, or infrastructure credentials in the bundle.
5. Generate `manifest.json` from the final normalized files. The author never supplies this generated inventory. Hash the exact bytes of every file after normalization.
6. Serialize the manifest first and then each listed regular file in manifest order as USTAR. Use the deterministic header rules below. Do not include the source solution/submission: that is a separate artifact supplied as `source_url`.
7. Compute SHA-256 and byte length over the complete final tar byte stream, including headers, file padding and the two end blocks. Store those values with the immutable revision and object key.
8. Upload the archive to private, immutable object storage. Mark the revision available for scheduling only after upload succeeds and the exact object reference and descriptor are persisted. An uploaded but unreferenced object can be collected later; never schedule a revision pointing at a pending upload.
9. After protocol adoption, resolve the pinned revision from the claimed run, sign a GET for that exact object, and return `bundle_url` and `bundle { size_bytes, sha256 }` in `ClaimResponse`. Do not resolve the latest revision or regenerate the archive in `Claim`. The URL may change across retries, but the object bytes and descriptor for the pinned revision must not.
10. Retain revision ID and bundle digest in run metadata and emitted event context for auditability. The current canonical Event does not carry the required digest field; negotiate an additive field or use the agreed existing metadata channel before relying on it.

Publish-time failures should be actionable and occur before an attempt is advertised: unsupported format/API version, missing `runner.lua`, invalid normalized schema, duplicate paths, path outside allowed limits, or inability to create/sign an immutable artifact.

## 3. Container Encoding (USTAR v1)

- Uncompressed POSIX USTAR. Block size is exactly 512 bytes. No gzip, zstd, other compression, concatenated archives, or trailing data.
- First entry is a regular file named exactly `manifest.json`. Its content is UTF-8 JSON and at most 1 MiB. It is not listed in its own `files` array.
- Then emit exactly one regular-file entry for each `manifest.files` item, in the same order. Do not emit directory entries; Invoker creates parent directories implicitly.
- End with exactly two all-zero 512-byte blocks, followed by EOF. File data padding to the next 512-byte boundary is all zero.
- Use USTAR `name` plus `prefix` fields when needed. Paths must fit USTAR representation. Do not emit PAX/GNU long-name records, GNU sparse entries, or extension headers.
- Only regular files are allowed. No symlink, hardlink, directory, device, FIFO, socket, sparse, or unknown type flags. An unsupported type rejects the whole bundle.
- Set typeflag to regular (`'0'` or NUL). Use valid octal header values and the standard USTAR checksum (checksum field treated as spaces during calculation). Avoid base-256 numeric encoding.
- The final 12 reserved bytes of each USTAR header (offsets 500 through 511) must be zero.
- Header UID/GID should be zero; uname/gname empty; mtime fixed (Unix epoch recommended); modes should be ordinary non-setuid file modes. Invoker does not trust or apply any ownership, timestamp, or permission metadata and creates files as `0600`, directories as `0700`.
- Archive paths are UTF-8, case-sensitive, relative, `/` separated, unique, and sorted by raw UTF-8 bytes in strictly increasing order. Reject absolute paths, empty components, `.`/`..`, backslashes, NUL, paths over configured byte/depth limits, and paths reserved below.
- USTAR paths use UTF-8 bytes in the name/prefix fields; initial Go interoperability tests use ASCII. If Backend needs non-ASCII names, add explicit cross-language tests; do not silently switch to PAX.
- The total archive byte length must be a multiple of 512 and include all headers, padding, manifest, and end blocks.

The initial Go implementation target is `archive/tar` with `Header.Format = tar.FormatUSTAR`, regular type flags, deterministic headers, and no directory entries. Backend must run the conformance fixture/test in Section 8 because standard library behavior around USTAR path splitting and trailing blocks is part of the contract.

Build the inventory from a stable snapshot. Use `sort.Slice` with `files[i].Path < files[j].Path` for Go byte ordering; use the same snapshot and ordered list when writing the tar. For a streaming producer, write to a private temporary file and hash/count the tar output as it is written. Check `tar.Writer.Close()` before finalizing the descriptor: that call writes the end blocks. Complete and check the file write before uploading. To check archive sizing independently, start with 1,024 bytes for the terminator, then add `512 + roundUp(size, 512)` for each file, including `manifest.json`; use checked arithmetic.

## 4. Manifest Schema v1

The complete JSON object has the four common fields shown below, plus `runner_api_version` for `scripted_lua` only. Unknown or duplicate fields are rejected. Producers must emit versions as unsigned JSON integers fitting `uint32`, and sizes as unsigned JSON integers fitting `uint64` (no strings, fractions or exponent notation). The decoder strictly checks the numeric encoding of `runner_api_version`; the Zig JSON parser may accept some equivalent encodings for the other numeric fields. `sha256` is lowercase hexadecimal encoding of exactly 32 bytes.

```json
{
  "format_version": 1,
  "execution_format": "standard",
  "execution_format_version": 1,
  "files": [
    {
      "path": "tests/sample/input.txt",
      "size": 3,
      "sha256": "084c799cd551dd1d8d5c5f9a5d593b2e931f5e36122ee5c793c1d08a19839cc0"
    }
  ]
}
```

Fields:

- `format_version`: integer `1` for both execution formats.
- `execution_format`: exact string `standard` or `scripted_lua`.
- `execution_format_version`: integer `1` for the current Invoker implementation. It is compared to the claimed job's expected version.
- `files`: ordered array. Each entry has exactly `path`, `size`, `sha256`. It describes every archive file after the manifest exactly once, and no other file.

Additional validation:

- Manifest must parse as UTF-8 JSON; reject duplicate keys, unknown fields, missing fields, unsupported format/version, and oversized content. Emit `[]`, not `null`, if the inventory is empty.
- `files` order must be strict raw UTF-8 byte order. This simultaneously disallows duplicate paths.
- Reject file/directory conflicts before serialization: for example, `tests/a` and `tests/a/input.txt` cannot both be regular files.
- Every path must satisfy the path policy above. Top-level `manifest.json` and `solution/` are reserved and cannot occur in bundle paths (including descendants of those roots).
- `size` equals the exact file data byte length, not padded tar length. `sha256` hashes only the file data bytes.
- `scripted_lua` must contain a root `runner.lua` and `"runner_api_version": 1` in `manifest.json`. Missing, `null`, non-integer, or unsupported values reject the bundle. There is no default. For `standard`, omit the key entirely. This check does not mean the Lua runtime is ready for production.
- `standard` bundles use a separate, versioned `standard.json` task descriptor. See [Standard v1 support matrix](standard-executor.md); it is backend-generated metadata, not an author-authored bundle manifest.
- The manifest itself counts toward the total unpacked-byte budget and file/entry budget. Implicit parent directories count toward the workspace entry limit. Archive byte budget includes tar overhead.

For `scripted_lua`, a minimal bundle with `runner.lua` containing the nine bytes `return 0\n` uses this manifest:

```json
{
  "format_version": 1,
  "execution_format": "scripted_lua",
  "execution_format_version": 1,
  "runner_api_version": 1,
  "files": [
    {
      "path": "runner.lua",
      "size": 9,
      "sha256": "88a5d86b8d00a468685ca2b8d7e93ef8f26389338f9fe96fa57b36fe8fe6e90d"
    }
  ]
}
```

## 5. Integrity, Signed URL, and Claim Contract

The canonical `ClaimResponse` includes additive trusted descriptors (existing URL fields are preserved):

```proto
message ArtifactDescriptor {
  bytes sha256 = 1;       // exactly 32 raw bytes
  uint64 size_bytes = 2;  // exact object length
}

// Inside ClaimResponse:
ArtifactDescriptor source = 5;
ArtifactDescriptor bundle = 6;
```

`source_url = 2` and `bundle_url = 3` remain alongside the descriptors. Field 4 is the fencing token. A missing or invalid descriptor must not be treated as permission to execute without verification. `RefreshArtifacts` uses the same lease and pinned descriptors to obtain replacement URLs; the diagnostic daemon does not yet call it.

Backend must return a 32-byte digest and exact size from trusted revision metadata, not values parsed from the downloaded manifest or an S3 ETag. Invoker validates HTTPS, URL origin and TLS, enforces a configured download-byte cap, downloads to a private spool, then validates the whole-object digest and exact size before extraction. Sign a direct GET on the configured origin, with no redirects, URL userinfo, mandatory custom request headers or content transformation. Treat query parameters as opaque and do not log them. URL expiry must cover the allowed download/retry window. An expired URL is not retried unchanged; the lease-aware refresh mechanism is not yet specified.

`source_url` is the solution/submission artifact and is never part of the task bundle. The canonical `source` descriptor provides its size and digest. The Invoker materializer validates it and writes it to `solution/source` in the same atomic publication as the bundle; both inputs count against the workspace byte and entry budgets.

## 6. Limits and Failure Behavior

Backend should enforce limits at revision publication and the Invoker enforces its own hard caps at claim/download/extraction. The two policies must be configured compatibly; the effective cap is the lower value. Proposed initial values are **deployment defaults, not yet ratified**:

| Limit | Suggested initial value |
| --- | ---: |
| Archive bytes (including tar overhead) | 256 MiB |
| Total payload bytes including manifest | 256 MiB, also bounded by the archive size |
| Manifest bytes | 1 MiB (fixed by the decoder) |
| Regular files plus implicit directories | 20,000 |
| Path bytes | At most 256 bytes and subject to a valid USTAR split: prefix ≤ 155 bytes, `/`, and name ≤ 100 bytes; without a prefix, name ≤ 100 bytes |
| Path components/depth | 32 |
| Individual path component | At most 255 bytes, further constrained by USTAR encoding |

Backend publish validation should reject over-limit revisions with a stable, user-visible error. Invoker must fail closed on unknown format/API versions, unknown fields, digest/size mismatch, missing/extra/reordered files, malformed tar header/checksum/padding/terminator, unsupported type flags, traversal, collision, quota overrun, or failed durable publication. It must not emit a successful run result after any bundle error. Report mapping should use the agreed stable error taxonomy; current protocol mapping remains open.

Workspace materialization occurs into a fresh private staging directory. It is published atomically without replacing an existing workspace only after all archive, manifest, inventory, and digest checks pass. Failed extraction is discarded; crash-recovery removes reserved `.extract-<random-id>` trees under the workspace lock. Bundle extraction and source artifact extraction must use equivalent path/size/type checks.

## 7. Backend Data Model and Storage Recommendations

Persist these values on the immutable revision/artifact record:

- revision ID and `execution_format`;
- `format_version`, `execution_format_version`, and (for Lua) `runner_api_version`;
- object key/version ID, exact archive byte length, SHA-256, creation time;
- normalized manifest bytes or a reproducible reference to the generated inventory;
- per-file path, size, digest (or enough immutable source metadata to reproduce and verify the archive);
- author-package provenance for audit, kept separate from the Invoker execution bundle.

Use content-addressed or versioned immutable object keys. Enable storage-side checksum verification if available, but still compute SHA-256 in Backend before publication and in Invoker after download. A reissued signed URL may change without changing the artifact descriptor. Garbage-collect an old bundle only after no active lease/revision retention policy references it.

Do not let the author set `bundle_url`, object key, archive digest, per-file inventory, execution format version, tar metadata, or generated manifest. These are Backend-controlled outputs. Author-selected language/task properties are inputs that Backend validates and normalizes.

## 8. Cross-Language Conformance and Rollout

Invoker implementation and fixtures live at:

- `src/workspace/extract.zig`: decoder, manifest checks, safe extraction and atomic publication.
- `spikes/bundle-fixture.go`: Go `archive/tar` producer fixture.
- `spikes/artifact-check.sh`: HTTPS download, signed-URL-like fixture, whole-object digest, spool, and end-to-end publication test.
- `docs/architecture.md`: evidence and current blockers.

Run from the Invoker repository:

```sh
zig fmt --check build.zig src/workspace
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
TMPDIR=/tmp/opencode bash spikes/artifact-check.sh
```

The Go fixture in `spikes/bundle-fixture.go` emits a Standard USTAR with a long ASCII path, plus two Lua bundles using `format_version: 1`. The end-to-end script checks the Standard golden digest and computes each Claim-like descriptor from the local file before serving it over HTTPS. Standard and Lua API 1 publish a workspace; the Lua bundle requesting unsupported API 2 downloads successfully but is rejected without publishing or leaving a staging directory. This is a local HTTPS fixture, not an S3 or Lua execution test. Malformed headers and paths are exercised separately in Zig unit tests.

The fixture has a pinned golden archive SHA-256 of `a94153c65bf4d0796ce75868d1c0db310ca86f5c9f26162d2d9251bdc4cd73db` and length 3,072 bytes. Regenerate/check it with `go run spikes/bundle-fixture.go /tmp/opencode/bundle-v1.tar verify` from the repository root. A different serialization can still conform; the pinned digest is for this fixture, not a requirement that every producer emit byte-identical JSON or headers. Review any change to the fixture before updating its expected digest.

Backend producer conformance tests assert:

1. first entry is `manifest.json`, body parses to the exact required schema;
2. listed entries are strict byte-sorted and have matching sizes/data SHA-256;
3. archive has exactly two zero end blocks and EOF, with zero data padding;
4. archive byte size and SHA-256 match the descriptor fields returned by Claim;
5. all emitted headers are USTAR regular entries and use deterministic metadata; use an ASCII golden path that exercises prefix/name splitting;
6. unsupported versions, invalid author paths, duplicate normalized paths, and unsupported required task features fail publication;
7. `scripted_lua` requires root `runner.lua`; unsupported `runner_api_version` fails publish or claim according to the agreed compatibility policy.

Recommended rollout:

1. Agree on this document's open items and additive protobuf field numbers.
2. Merge Backend producer + conformance tests behind a feature flag; do not schedule these bundles to production Invokers yet.
3. Run the checked-in golden fixture through both implementations, then run a bundle produced by the actual Backend producer through the Invoker decoder.
4. Add signed-URL and real object-store acceptance tests, including expiry, retry, checksum mismatch and immutable object replacement prevention.
5. Deploy Invoker in diagnostic/shadow mode and compare the Backend descriptor, downloaded hash, manifest execution format/version and revision IDs without starting containers.
6. Enable claims only after control-plane fencing/lease/cancel/upload contracts and execution readiness are separately accepted. Bundle support alone does not make the daemon execution-ready.

## 9. Remaining Integration Gates

The user authorized Backend and proto changes. Remaining operational decisions or tests:

1. Run the deployed services with their actual certificates and object store. The isolated integration test covers the same Backend handlers, real PostgreSQL, and HTTPS MinIO, but not the daemon's Claim/refresh loop.
2. Adopt the suggested hard limits above or provide production-specific values.
3. Adopt the [Standard v1 contract](standard-executor.md) in the Backend Polygon normalizer and verify a Backend-produced Standard bundle end to end. The Invoker acceptance currently generates its own normalized bundle.
4. Choose the author-facing configuration field from which Backend obtains `runner_api_version`, and define capability advertisement before scheduling Lua runs.
5. Agree stable Backend report/status mapping for bundle validation failures and signed URL refresh on expiry.

Keep both canonical proto copies synchronized. Do not advertise execution readiness: the daemon does not dispatch production executions.
