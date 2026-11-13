#!/usr/bin/env bash
# Build examples/task.tar.gz from examples/task/.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/task"
tar --sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner \
    -czf "$here/task.tar.gz" runner.lua solution
echo "wrote $here/task.tar.gz"
