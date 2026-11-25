#!/usr/bin/env bash
set -euo pipefail
# protobuf-c 1.5 does not yet accept proto3 optional; preserve tag and presence.
sed 's/optional string score = 11;/oneof score_presence { string score = 11; }/' "$1" > "$2/control.proto"
protoc -I "$2" --c_out="$2" "$2/control.proto"
