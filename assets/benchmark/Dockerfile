# Deterministic CPU benchmark image.
#
# The binary is a statically linked x86_64-musl build of assets/benchmark/bench.zig
# and is copied into the image by build.sh.  The same Dockerfile is embedded in
# src/calibration.zig, so the invoker can build the image without any external
# files.
FROM scratch
COPY bench /bench
ENTRYPOINT ["/bench"]
