#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: run.sh <image-ref>}"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-ts3-e2e}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAMESPACE=teamspeak
RELEASE=ts3
POD="$RELEASE-teamspeak3-0"
STS="$RELEASE-teamspeak3"
PF_PID=""

cleanup() {
    if [ -n "$PF_PID" ]; then
        kill "$PF_PID" 2>/dev/null || true
    fi
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> creating kind cluster $CLUSTER_NAME"
kind create cluster --name "$CLUSTER_NAME" \
    --config "$SCRIPT_DIR/kind-config.yaml" --wait 120s

echo "==> loading image $IMAGE"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

echo "==> installing chart"
helm install "$RELEASE" "$REPO_ROOT/charts/teamspeak3" \
    --namespace "$NAMESPACE" --create-namespace \
    --set acceptLicense=true \
    --set image.repository="${IMAGE%%:*}" \
    --set image.tag="${IMAGE##*:}" \
    --set image.pullPolicy=Never \
    --set persistence.size=1Gi \
    --wait --timeout 5m

echo "==> waiting for rollout"
kubectl rollout status -n "$NAMESPACE" "statefulset/$STS" --timeout=300s

echo "==> assert: voice port bound"
POD_LOGS="$(kubectl logs -n "$NAMESPACE" "$POD")"
echo "$POD_LOGS" | grep -q "listening on 0.0.0.0:9987"

echo "==> assert: first boot printed an admin token"
echo "$POD_LOGS" | grep -q "token="

echo "==> assert: ServerQuery answers version query"
kubectl port-forward -n "$NAMESPACE" "pod/$POD" 10011:10011 >/dev/null 2>&1 &
PF_PID=$!
PF_CONNECTED=false
for _ in $(seq 1 15); do
    if (exec 3<>/dev/tcp/127.0.0.1/10011) 2>/dev/null; then
        PF_CONNECTED=true
        break
    fi
    sleep 1
done
if [ "$PF_CONNECTED" != true ]; then
    echo "FAIL: port-forward to ServerQuery did not become reachable within 15s"
    exit 1
fi
QUERY_OUT="$( (exec 3<>/dev/tcp/127.0.0.1/10011 \
    && printf 'version\nquit\n' >&3 \
    && timeout 5 cat <&3) || true)"
kill "$PF_PID" 2>/dev/null || true
PF_PID=""
echo "$QUERY_OUT" | grep -q "TS3"
echo "$QUERY_OUT" | grep -q "version=3.13.8"

echo "==> assert: state survives pod deletion"
kubectl delete pod -n "$NAMESPACE" "$POD" --wait=true
kubectl rollout status -n "$NAMESPACE" "statefulset/$STS" --timeout=300s
kubectl exec -n "$NAMESPACE" "$POD" -- test -f /var/ts3server/ts3server.sqlitedb
NEW_POD_LOGS="$(kubectl logs -n "$NAMESPACE" "$POD")"
if [ -z "$NEW_POD_LOGS" ]; then
    echo "FAIL: could not retrieve logs from recreated pod"
    exit 1
fi
# Every boot prints this ServerLibPriv banner; requiring it proves the logs
# cover a full startup before the negative token check below can be trusted.
if ! echo "$NEW_POD_LOGS" | grep -q "TeamSpeak 3 Server"; then
    echo "FAIL: recreated pod logs are missing the server startup banner"
    exit 1
fi
if echo "$NEW_POD_LOGS" | grep -q "token="; then
    echo "FAIL: new pod re-initialized the database (token printed again)"
    exit 1
fi

echo "e2e OK"
