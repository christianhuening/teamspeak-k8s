# teamspeak-k8s

Production-grade [TeamSpeak 3](https://teamspeak.com) server for Kubernetes:
a hardened non-root container image, a Helm chart, and a CI pipeline that
e2e-tests every change on [kind](https://kind.sigs.k8s.io).

- **Image:** `ghcr.io/christianhuening/teamspeak-k8s/ts3server` (TS3 3.13.8,
  checksum-pinned, Wolfi-based with zero known CVEs at build time, runs as
  UID 9987, read-only root filesystem, linux/amd64)
- **Chart:** `oci://ghcr.io/christianhuening/charts/teamspeak3`
- Single virtual server, ≤32 slots (TS3 free license), SQLite on a PVC.
  Restricted Pod-Security-Standard compliant (runs on Talos without
  exemptions).

## Install

```sh
helm install ts3 oci://ghcr.io/christianhuening/charts/teamspeak3 \
  --namespace teamspeak --create-namespace \
  --set acceptLicense=true
```

`acceptLicense=true` is mandatory: it confirms you accept the
[TeamSpeak license](https://www.teamspeak.com/en/privacy-and-terms/).

First install only — grab the admin privilege key and serveradmin password
from the logs (printed once):

```sh
kubectl logs -n teamspeak ts3-teamspeak3-0 | grep -E 'token=|password'
```

## First release

GHCR packages created by `GITHUB_TOKEN` default to **private**. After cutting
the first `v*` tag, flip both packages — `teamspeak-k8s/ts3server` and
`charts/teamspeak3` — to public in the GitHub package settings, or anonymous
`helm install` and kubelet image pulls will fail with 403/unauthorized.
Alternative: configure `imagePullSecrets`.

## Connecting

By default the chart exposes a NodePort service:

| Traffic | Port on node | Protocol |
| --- | --- | --- |
| Voice | 30987 | UDP |
| File transfer | 30033 | TCP |

Point an A record at a node's public IP and connect to `host:30987`, or add
an SRV record so clients can omit the port:

```text
_ts3._udp.ts.example.com. 3600 IN SRV 0 5 30987 ts.example.com.
```

With the default `service.external.externalTrafficPolicy: Local`, traffic
hitting a node that isn't running the pod gets dropped — so the A record must
point at the node actually running the pod. Pin the pod to a node with
`nodeSelector`, or set `service.external.externalTrafficPolicy=Cluster` (this
loses client source IPs).

The file-transfer port must stay 30033 — the server advertises it to clients.

## Key values

| Value | Default | Purpose |
| --- | --- | --- |
| `acceptLicense` | `false` | Must be `true` to install |
| `service.external.type` | `NodePort` | `LoadBalancer` if your cluster has one (e.g. Cilium LB-IPAM) |
| `service.external.voice.nodePort` | `30987` | Voice UDP entry port |
| `persistence.size` | `5Gi` | PVC for DB, logs, uploads |
| `persistence.storageClassName` | `""` | Cluster default when empty |
| `serverQuery.existingSecret` | `""` | Secret (key `serveradmin-password`) to pin the admin password |
| `networkPolicy.enabled` | `false` | Restrict ServerQuery to the namespace |

ServerQuery (TCP 10011) is never exposed outside the cluster by default; use
`kubectl port-forward` for admin work.

## Operations

- **Upgrade:** bump the chart/image version; the server migrates its SQLite
  schema automatically. Expect a ~30s voice drop (single replica). The
  `3.13.8` tag is re-pushed on CVE rebuilds, so with the default
  `pullPolicy: IfNotPresent` a node that already pulled it never gets the
  fix — production should pin the immutable `3.13.8-<git-sha>` tag published
  by each release.
- **Backup:** snapshot the PVC (CSI snapshots / Velero). The SQLite DB holds
  all identities, permissions, and channels.
- **Scale:** don't. TS3 is a single-process server; the chart pins 1 replica.

## Development

```sh
docker build -t ts3server:dev image/     # build the image
./tests/image/smoke.sh ts3server:dev     # container smoke test
helm unittest charts/teamspeak3          # chart unit tests
./tests/e2e/run.sh ts3server:dev         # full e2e on kind
```

Design docs live in `docs/superpowers/specs/`.
