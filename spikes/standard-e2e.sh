#!/usr/bin/env bash
set -euo pipefail

: "${PODTEST_STANDARD_WORKER:?absolute path to the Standard worker binary}"
: "${PODTEST_PODMAN_SOCKET:?rootless Podman socket}"
: "${PODTEST_LIBPOD_API_VERSION:?version advertised by the Podman socket}"
: "${PODTEST_STANDARD_SH_IMAGE_ID:?local shell image ID}"
backend=${PODTEST_BACKEND_DIR:-$(dirname "$(realpath "$0")")/../../podtest}
work=$(mktemp -d "${TMPDIR:-/tmp/opencode}/standard-e2e.XXXXXX")
pg=podtest-e2e-pg-$BASHPID
s3=podtest-e2e-s3-$BASHPID
nats_pid=
cleanup() {
    if [[ -n $nats_pid ]]; then
        kill "$nats_pid" 2>/dev/null || true
        wait "$nats_pid" 2>/dev/null || true
    fi
    podman rm -f -v "$pg" "$s3" >/dev/null 2>&1 || true
    rm -rf -- "$work"
}
trap cleanup EXIT

mkdir "$work/certs"
openssl req -x509 -newkey rsa:2048 -noenc -days 1 -subj /CN=podtest-fixture \
    -addext subjectAltName=IP:127.0.0.1 -keyout "$work/certs/private.key" -out "$work/certs/public.crt" 2>/dev/null
podman run -d --pull=never --name "$pg" -p 127.0.0.1::5432 -e POSTGRES_PASSWORD=fixture-password docker.io/library/postgres:17-alpine >/dev/null
podman run -d --pull=never --name "$s3" -p 127.0.0.1::9000 -v "$work/certs:/certs:ro" \
    -e MINIO_ROOT_USER=fixture-access -e MINIO_ROOT_PASSWORD=fixture-secret docker.io/minio/minio:latest --certs-dir /certs server /data >/dev/null
"${PODTEST_NATS_SERVER:-nats-server}" -a 127.0.0.1 -p -1 -js -sd "$work/js" >"$work/nats.log" 2>&1 &
nats_pid=$!
pg_addr=$(podman port "$pg" 5432/tcp)
s3_addr=$(podman port "$s3" 9000/tcp)
ready=0
for i in {1..60}; do
    port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$work/nats.log")
    if [[ -n $port ]] && podman exec "$pg" pg_isready -h 127.0.0.1 -U postgres >/dev/null &&
        curl --cacert "$work/certs/public.crt" -fsS "https://$s3_addr/minio/health/ready" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep .25
done
if [[ $ready == 0 ]]; then
    cat "$work/nats.log" >&2
    exit 1
fi

export PODTEST_ARTIFACT_ACCEPTANCE=1 PODTEST_NATS_URL="nats://127.0.0.1:$port"
export DATABASE_URL="postgres://postgres:fixture-password@$pg_addr/postgres?sslmode=disable"
export S3_URL="https://$s3_addr" S3_BUCKET=standard-e2e S3_ACCESS_KEY=fixture-access S3_SECRET_KEY=fixture-secret
export SSL_CERT_FILE="$work/certs/public.crt"
cd "$backend"
go test ./internal/judging -run '^TestStandardSubmissionExecution$' -count=1 -v
