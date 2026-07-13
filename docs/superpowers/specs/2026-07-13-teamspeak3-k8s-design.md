# TeamSpeak 3 on Kubernetes — Design

**Date:** 2026-07-13
**Status:** Draft — pending review
**Repo:** github.com/christianhuening/teamspeak-k8s

## Goal

A production-grade, self-hosted TeamSpeak voice server on Kubernetes: our own
container image, our own Helm chart, a CI pipeline that builds and tests both,
and an end-to-end test on kind. Target production environment: bare-metal
Talos Linux cluster on Hetzner with Cilium CNI.

## Decisions and rationale

| Decision | Choice | Why |
| --- | --- | --- |
| TeamSpeak version | **TS3 server 3.13.8** | TS6 server is still beta as of July 2026 (v6.0.0-beta11), not feature-complete, and proper licenses aren't obtainable for it. TS3 is maintained (security fix TS-SA-2026-001, May 2026) and its default license runs to July 2027. |
| Scale | 1 virtual server, ≤32 slots | Free-license mode. No paid license handling. |
| Database | SQLite on a PVC | Right-sized for ≤32 users; avoids a MariaDB dependency. |
| Replicas | Exactly 1 (not configurable) | TS3 cannot scale horizontally; two pods on one SQLite DB means corruption. |
| Container image | Own image, pinned TS3 tarball | Full control, CVE rebuilds on our schedule, non-root for Talos PSA. |
| Voice exposure | NodePort (default), Service type configurable | Hetzner bare metal has no UDP LoadBalancer; Cilium BGP has no peer at Hetzner. A future vSwitch + Cilium LB-IPAM/L2 setup is a values-only change. |
| Registry | GHCR (`ghcr.io/christianhuening/...`) | Repo lives on GitHub; CI uses `GITHUB_TOKEN`, no extra credentials. |
| CI | GitHub Actions | Same reason. |

## Non-goals

- TS6 support (revisit when the server GAs and licensing exists).
- MariaDB backend, multiple virtual servers, paid-license mounting. The chart
  stays small; these are additive later if ever needed.
- Prometheus metrics (ts3exporter), backup CronJob — deferred. Backup story is
  PVC snapshots (e.g. Velero/CSI) at the cluster level.
- arm64 images — TeamSpeak ships no arm64 Linux server build.
- DNS management (external-dns) — SRV/A records are set up manually, documented
  in the chart's NOTES.

## Architecture overview

```text
                        Internet
                           │
        UDP 9987 ──────────┼────────── TCP 30033
   (voice, NodePort 30987) │   (file transfer, NodePort 30033)
                           ▼
                 ┌───────────────────┐
                 │ Service "external"│  type: NodePort (default)
                 └─────────┬─────────┘
                           ▼
                 ┌───────────────────┐     ┌──────────────────┐
                 │ StatefulSet (1)   │◄────│ Service "query"  │ ClusterIP
                 │  ts3server pod    │     │  TCP 10011       │ (internal only)
                 └─────────┬─────────┘     └──────────────────┘
                           ▼
                 ┌───────────────────┐
                 │ PVC /var/ts3server│  SQLite DB, logs, uploaded files
                 └───────────────────┘
```

## Repository layout

```text
teamspeak-k8s/
├── image/
│   ├── Dockerfile
│   └── entrypoint.sh
├── charts/teamspeak3/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── templates/
│   └── tests/                  # helm-unittest specs
├── tests/e2e/
│   ├── kind-config.yaml
│   └── run.sh                  # runs locally and in CI
├── .github/
│   ├── workflows/ci.yaml
│   ├── workflows/release.yaml
│   └── dependabot.yml
└── docs/superpowers/specs/
```

## Component 1: Container image

`ghcr.io/christianhuening/teamspeak-k8s/ts3server`

- **Multi-stage Dockerfile.** Stage 1 downloads
  `teamspeak3-server_linux_amd64-3.13.8.tar.bz2` from
  `files.teamspeak-services.com` and verifies a **pinned SHA-256** checksum.
  `TS3_VERSION` and `TS3_SHA256` are build `ARG`s — a TS3 bump is a two-line
  change. Both stages are `cgr.dev/chainguard/wolfi-base` (digest-pinned):
  Wolfi is glibc-based (which ts3server requires — verified via its ELF
  `NEEDED` entries) and carries a near-zero CVE surface, unlike
  `debian:bookworm-slim`, whose base packages light up scanners like grype.
  The final stage only adds `libstdc++` (the binary's one non-glibc library
  dependency); wolfi-base already ships the CA bundle ts3server needs for its
  TLS connection to TeamSpeak's accounting service.
- **Non-root:** dedicated user, UID/GID **9987**, `USER 9987:9987`. Binaries in
  `/opt/ts3server` (root-owned, read-only), all mutable state (SQLite DB, logs,
  file-transfer uploads) under `/var/ts3server`. The container runs with
  `readOnlyRootFilesystem: true` and a single volume mount.
- **entrypoint.sh:** refuses to start unless `TS3SERVER_LICENSE=accept` is set
  (same contract as the official image), then `exec`s `ts3server` with
  `license_accepted=1`, `dbsqlpath`/`logpath`/`licensepath` pointed at
  `/var/ts3server`, plus passthrough arguments from the chart
  (`$@`). `exec` keeps ts3server as PID 1 so SIGTERM reaches it directly.
- **Platform:** linux/amd64 only.
- **Tags:** `3.13.8` (latest build of that TS3 version) plus an immutable
  `3.13.8-<git-short-sha>` per build, so base-image CVE rebuilds don't require
  a fake version bump. OCI source/version/revision labels; SBOM + provenance
  attestations from buildx.

## Component 2: Helm chart (`charts/teamspeak3`)

**Workload.** A StatefulSet with `replicas: 1` hardcoded in the template (not a
value — see decision table). `volumeClaimTemplates` for `/var/ts3server`
(default 5Gi, `storageClassName` configurable). Update strategy
`RollingUpdate`: for a single-replica StatefulSet this is delete-then-create,
which guarantees no two pods ever share the SQLite file; a brief voice outage
during upgrades is accepted.

**Services.**

| Service | Type (default) | Ports | Notes |
| --- | --- | --- | --- |
| `<release>-external` | NodePort | UDP 9987 → nodePort **30987**; TCP 30033 → nodePort **30033** | Mixed-protocol Service. File-transfer nodePort **must** stay 30033: the server advertises port 30033 to clients, and 30033 happens to sit inside the default NodePort range. Voice nodePort is configurable; `externalTrafficPolicy: Local` by default (preserves client IPs; fine with 1 replica). Type switchable to `LoadBalancer`/`ClusterIP` via values, with annotations passthrough for a future Cilium LB-IPAM setup. |
| `<release>-query` | ClusterIP | TCP 10011 (raw ServerQuery) | Internal only by default. A values toggle can add it to the external Service if ever needed. |

**Probes.** ServerQuery's TCP port is the only probe-able signal (voice is UDP).

- `startupProbe`: TCP 10011, up to ~60s for first-boot DB creation.
- `livenessProbe` and `readinessProbe`: TCP 10011.

**Security (Talos restricted-PSA compliant).**

- `runAsNonRoot: true`, `runAsUser/runAsGroup: 9987`, `fsGroup: 9987`
- `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`
- `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`
- Optional NetworkPolicy (default **off**): allow UDP 9987 + TCP 30033 from
  anywhere, ServerQuery only from within the namespace.

**License gate.** `acceptLicense: false` in default values; templates `fail`
with a clear message unless the installer sets it to `true`. This makes
accepting the TS3 license an explicit user action, not a buried default.

**Admin access.** On first boot ts3server prints the serveradmin password and
the admin privilege key to its log. Default behavior keeps that; `NOTES.txt`
prints the exact `kubectl logs`/`grep` command to retrieve them. Optionally,
`serverQuery.existingSecret` provides a fixed serveradmin password, passed to
the binary as the documented `serveradmin_password=` parameter (exact wiring
verified during implementation; if TS3 rejects it at 3.13.8, the feature is
dropped and log-retrieval remains the only path).

**Other values.** `image.repository/tag` (tag defaults to `appVersion`),
`resources` (modest defaults: 100m/256Mi requests, 1 CPU/512Mi limits),
`extraArgs` (raw ts3server parameters), `extraEnv`, `nodeSelector`,
`tolerations`, `affinity`, `priorityClassName`, `persistence.size/storageClass`.

**NOTES.txt** tells the installer: how to fetch admin credentials, what DNS to
set up (A record + optional `_ts3._udp` SRV pointing at the voice nodePort so
clients don't need to type a port), and that file transfer requires TCP 30033
reachable on the same address.

**Chart tests:** helm-unittest specs covering: license gate fails without
acceptance, securityContext renders restricted-compliant, port/nodePort
plumbing, replicas is always 1.

**Versioning:** `Chart.yaml` `version` follows the repo's release tags
(`v0.1.0` → `0.1.0`); `appVersion: 3.13.8`.

## Component 3: CI pipeline (GitHub Actions)

**`ci.yaml`** — on pull requests and pushes to `main`:

1. **lint** — hadolint (Dockerfile), shellcheck (entrypoint + e2e script),
   `helm lint`, helm-unittest.
2. **build** — buildx build (linux/amd64), Trivy scan of the built image
   (gate on HIGH/CRITICAL, with a checked-in ignore file for accepted risks),
   a container smoke test (`docker run` without `TS3SERVER_LICENSE` must exit
   non-zero with a clear message — proves the entrypoint license gate), then
   export the image as a tar artifact for the e2e job.
3. **e2e** — needs build; downloads the image tar and runs
   `tests/e2e/run.sh` (details below).
4. On push to `main` only: push image to GHCR tagged `edge` + `<short-sha>`.

**`release.yaml`** — on tags `v*`:

1. Build and push the image with tags `3.13.8` and `3.13.8-<short-sha>`
   (+ SBOM/provenance).
2. `helm package` with version from the tag, `helm push` to
   `oci://ghcr.io/christianhuening/charts`.
3. Create a GitHub Release with generated notes.

**Hygiene:** all actions pinned to commit SHAs; workflow `permissions:` blocks
scoped minimally (`contents: read` default, `packages: write` only where
pushing); Dependabot keeps action SHAs current.

## Component 4: kind e2e test (`tests/e2e/run.sh`)

Runs identically in CI and locally (`./tests/e2e/run.sh [image-ref]`).

1. Create a single-node kind cluster from `kind-config.yaml`.
2. `kind load docker-image` the freshly built image.
3. `helm install` the chart with test values (`acceptLicense=true`, NodePort,
   1Gi PVC on kind's default local-path storage class).
4. Assert, with timeouts:
   - StatefulSet rolls out; pod becomes Ready (exercises the probes for real).
   - Server log contains the line reporting voice bound on `0.0.0.0:9987`.
   - ServerQuery answers: `kubectl port-forward` to 10011, send `version`,
     expect the `TS3` banner and `version=3.13.8` in the reply.
   - **Persistence:** `kubectl delete pod`, wait for recreation and Ready,
     assert the SQLite DB file survived (`kubectl exec -- test -f
     /var/ts3server/ts3server.sqlitedb`) and the log does not re-print a
     first-boot privilege key (proves it reused the DB, not recreated it).
5. Tear down the cluster (always, via trap).

UDP voice traffic itself is not protocol-tested in CI (no TS3 client exists
headless); the bound-port log line plus query liveness is the accepted proxy.
`kind-config.yaml` maps host port 30987/udp for optional manual testing with a
real TS3 client against a local kind cluster.

## Operational notes (production)

- **Connecting:** clients use `ts.example.com:30987`, or plain
  `ts.example.com` if the `_ts3._udp` SRV record is set. DNS A record points at
  the node's public IP (with `externalTrafficPolicy: Local`, at the node
  running the pod — pin with `nodeSelector` if the cluster has >1 worker).
- **Upgrades:** bump the image tag (chart or values); ts3server migrates the
  SQLite schema automatically on start. Single-replica delete-then-create means
  a ~30s voice drop.
- **Backups:** snapshot the PVC (CSI snapshots / Velero). Restore = restore
  PVC, reinstall chart. The SQLite DB holds all identities, permissions, and
  channel structure.
- **Talos:** the pod satisfies the `restricted` Pod Security Standard, so no
  namespace exemptions are needed.

## Testing summary

| Layer | Mechanism |
| --- | --- |
| Dockerfile | hadolint; e2e proves it boots |
| entrypoint.sh | shellcheck; container smoke test of the license gate in CI |
| Chart templates | helm lint + helm-unittest (render-level) |
| Whole system | kind e2e per PR: boot, probes, query handshake, persistence |
| Image security | Trivy gate per PR + release |
