#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref>}"
CID=""
NOLICENSE_LOG="$(mktemp)"

cleanup() {
    if [ -n "$CID" ]; then
        docker rm -f "$CID" >/dev/null 2>&1 || true
    fi
    rm -f "$NOLICENSE_LOG"
}
trap cleanup EXIT

echo "--- refuses to start without license acceptance"
if docker run --rm "$IMAGE" >"$NOLICENSE_LOG" 2>&1; then
    echo "FAIL: container started without TS3SERVER_LICENSE=accept"
    exit 1
fi
grep -q "TS3SERVER_LICENSE=accept" "$NOLICENSE_LOG"

echo "--- runs as uid 9987"
uid="$(docker run --rm --entrypoint /usr/bin/id "$IMAGE" -u)"
[ "$uid" = "9987" ]

echo "--- boots with a read-only root filesystem and binds voice + query"
CID="$(docker run -d --read-only \
    --tmpfs /var/ts3server:rw,mode=1777 \
    --tmpfs /tmp:rw,mode=1777 \
    -e TS3SERVER_LICENSE=accept "$IMAGE")"
for _ in $(seq 1 60); do
    if docker logs "$CID" 2>&1 | grep -q "listening on 0.0.0.0:9987"; then
        break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$CID")" != "true" ]; then
        docker logs "$CID"
        echo "FAIL: container exited during startup"
        exit 1
    fi
    sleep 2
done
# Snapshot the logs once: piping `docker logs` straight into `grep -q` races
# grep's early exit against the log stream (SIGPIPE -> exit 141 under pipefail).
boot_logs="$(docker logs "$CID" 2>&1)"
grep -q "listening on 0.0.0.0:9987" <<<"$boot_logs"
grep -q "listening for query on 0.0.0.0:10011" <<<"$boot_logs"
grep -q "token=" <<<"$boot_logs"

echo "smoke OK"
