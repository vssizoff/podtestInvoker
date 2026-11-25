#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
work=$(mktemp -d "${TMPDIR:-/tmp}/podtest-grpc-test.XXXXXX")
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
cd "$work"
protoc -I "$root/proto" --go_out=. --go_opt=module=podtest \
    --go-grpc_out=. --go-grpc_opt=module=podtest "$root/proto/control.proto"
mkdir proposal
cp "$root/proto/control-v2-proposal.proto" proposal/
protoc -I proposal -I "$root/proto" --go_out=. --go_opt=module=podtest proposal/control-v2-proposal.proto
cp "$root/spikes/grpc/lease-fixture.proto" proposal/
protoc -I proposal -I "$root/proto" --go_out=. --go_opt=module=podtest \
    --go-grpc_out=. --go-grpc_opt=module=podtest proposal/lease-fixture.proto
# protobuf-c 1.5.2 needs a wire-compatible oneof for the optional field.
mkdir c
sed 's/optional string score = 11;/oneof score_presence { string score = 11; }/' "$root/proto/control.proto" > c/control.proto
protoc -I c --c_out=c c/control.proto
protoc -I proposal -I c --c_out=c proposal/control-v2-proposal.proto
cp "$root/spikes/grpc/client.zig" "$root/spikes/grpc/server.go" .
cp "$root/src/control/outbox.zig" "$root/src/control/lease.zig" .
zig translate-c -lc c/control.pb-c.h > control-pb.zig
zig translate-c -lc c/control-v2-proposal.pb-c.h > lease-pb.zig
go mod init podtest
go get google.golang.org/grpc@v1.76.0 google.golang.org/protobuf@v1.36.10
go build -o server .
grpc_flags=()
if [[ -n ${PODTEST_GRPC_PREFIX:-} ]]; then
    grpc_flags=(-I "$PODTEST_GRPC_PREFIX/include" -L "$PODTEST_GRPC_PREFIX/lib")
    export LD_LIBRARY_PATH="$PODTEST_GRPC_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
zig build-exe client.zig "$root/spikes/grpc/transport.c" c/control.pb-c.c c/control-v2-proposal.pb-c.c \
    -I c "${grpc_flags[@]}" -lc -lgrpc -lgpr -lprotobuf-c -femit-bin=client
./server endpoint &
server_pid=$!
for ((i=0; i<50; i++)); do
    [[ -s endpoint ]] && break
    kill -0 "$server_pid"
    sleep 0.1
done
test -s endpoint
mkdir -m 0700 state
./client "$(<endpoint)" "$work/state" enqueue
./client "$(<endpoint)" "$work/state" replay
./client "$(<endpoint)" "$work/state" verify-empty
./client "$(<endpoint)" "$work/state" lease-fixture
printf '%s\n' 'Canonical Control RPCs, Report restart/compaction, and proposed renewal/cancel messages verified'
