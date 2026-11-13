#!/usr/bin/env bash
# Build the calibration benchmark image.
#
#   ./assets/benchmark/build.sh [TAG]
#
# The default tag is localhost/podtest-benchmark:latest.  The invoker builds
# its own copy at startup (see src/calibration.zig); this script is useful for
# pre-seeding the image or for checking the benchmark on a host.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
tag=${1:-localhost/podtest-benchmark:latest}

cd "$root"
echo "== building static benchmark binary =="
zig build

ctx=$(mktemp -d "${TMPDIR:-/tmp}/podtest-bench.XXXXXX")
trap 'rm -rf "$ctx"' EXIT
cp "$root/zig-out/bin/bench" "$ctx/bench"
chmod 0755 "$ctx/bench"

echo "== building $tag =="
podman build -t "$tag" -f "$here/Dockerfile" "$ctx"

echo "== running one sample =="
podman run --rm --network none --memory 1g "$tag"
echo "image ready: $tag"
