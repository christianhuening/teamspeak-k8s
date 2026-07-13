# TeamSpeak 3 on Kubernetes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Production-grade self-hosted TeamSpeak 3 server on Kubernetes: hardened container image, Helm chart, GitHub Actions CI/release pipeline, and a kind e2e test.

**Architecture:** A non-root container image wrapping the checksum-pinned TS3 3.13.8 tarball; a Helm chart running it as a single-replica StatefulSet with SQLite on a PVC, NodePort exposure for voice/file-transfer, and a cluster-internal headless ServerQuery service used for probes; CI lints, builds, scans, and e2e-tests every PR on kind, and releases push image + chart (OCI) to GHCR.

**Tech Stack:** Docker (debian:bookworm-slim), Helm chart (apiVersion v2), helm-unittest, kind, GitHub Actions, Trivy, hadolint, shellcheck, actionlint.

**Spec:** `docs/superpowers/specs/2026-07-13-teamspeak3-k8s-design.md`

## Global Constraints

- **ONLY THE USER COMMITS AND PUSHES.** Never run `git commit` or `git push`. Where a task says "Stage for commit", run only `git add <files>`, print the suggested commit message, and continue. The user commits.
- TS3 version: **3.13.8**; tarball SHA-256: `a3c4658e09892d3dbd8ea752d0de42dc7d111bf44d09721927f0f4782496eb2d` (verified 2026-07-13 against `files.teamspeak-services.com`).
- Container runs as UID/GID **9987**, must work with `readOnlyRootFilesystem: true`; only `/var/ts3server` (volume) and `/tmp` (emptyDir) are writable.
- StatefulSet `replicas` is hardcoded to `1` — never a value.
- File-transfer port is **30033** everywhere (containerPort, service port, nodePort) — the server advertises 30033 to clients.
- Voice NodePort default: **30987/udp**. ServerQuery (10011/tcp) never gets external exposure by default.
- linux/amd64 only.
- Image: `ghcr.io/christianhuening/teamspeak-k8s/ts3server`. Chart OCI repo: `oci://ghcr.io/christianhuening/charts`.
- All GitHub Actions pinned to commit SHAs (given in Tasks 5–6). Tool versions: kind v0.32.0, trivy 0.72.0, hadolint v2.14.0, actionlint 1.7.12, helm-unittest 1.1.1.
- **Prerequisite for Tasks 1, 4:** Docker must be reachable from this WSL distro. As of planning, Docker Desktop's WSL integration is OFF here (`docker version` fails). The user must enable it (Docker Desktop → Settings → Resources → WSL integration) before those tasks run. If `docker version` fails, stop and ask the user.

---

### Task 1: Container image + smoke test

**Files:**

- Create: `tests/image/smoke.sh`
- Create: `image/entrypoint.sh`
- Create: `image/Dockerfile`

**Interfaces:**

- Produces: image (local ref `ts3server:dev`) whose entrypoint requires env `TS3SERVER_LICENSE=accept`, honors optional env `TS3SERVER_SERVERADMIN_PASSWORD`, appends any container `args` as extra `ts3server` parameters, stores all state in `/var/ts3server` (SQLite DB at `/var/ts3server/ts3server.sqlitedb`), listens on 9987/udp, 10011/tcp, 30033/tcp. Build args `TS3_VERSION`, `TS3_SHA256`. Tasks 2 and 4 rely on exactly these paths/ports/envs.

- [ ] **Step 1: Verify docker works**

Run: `docker version --format '{{.Server.Version}}'`
Expected: a version string. If this errors, STOP — tell the user to enable Docker Desktop WSL integration.

- [ ] **Step 2: Write the failing smoke test**

Create `tests/image/smoke.sh` (mode 0755):

```bash
#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref>}"
CID=""

cleanup() {
    if [ -n "$CID" ]; then
        docker rm -f "$CID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "--- refuses to start without license acceptance"
if docker run --rm "$IMAGE" >/tmp/ts3-nolicense.log 2>&1; then
    echo "FAIL: container started without TS3SERVER_LICENSE=accept"
    exit 1
fi
grep -q "TS3SERVER_LICENSE=accept" /tmp/ts3-nolicense.log

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
docker logs "$CID" 2>&1 | grep -q "listening on 0.0.0.0:9987"
docker logs "$CID" 2>&1 | grep -q "listening for query on 0.0.0.0:10011"
docker logs "$CID" 2>&1 | grep -q "token="

echo "smoke OK"
```

Then run: `shellcheck tests/image/smoke.sh`
Expected: no output (clean).

- [ ] **Step 3: Run smoke test to verify it fails**

Run: `./tests/image/smoke.sh ts3server:dev`
Expected: FAIL — `Unable to find image 'ts3server:dev'` (image doesn't exist yet).

- [ ] **Step 4: Write the entrypoint**

Create `image/entrypoint.sh` (mode 0755):

```sh
#!/bin/sh
set -eu

if [ "${TS3SERVER_LICENSE:-}" != "accept" ]; then
    echo >&2 "ERROR: you must accept the TeamSpeak 3 server license to run this container."
    echo >&2 "Review https://www.teamspeak.com/en/privacy-and-terms/ and set TS3SERVER_LICENSE=accept"
    exit 1
fi

mkdir -p /var/ts3server/logs

set -- /opt/ts3server/ts3server \
    license_accepted=1 \
    dbsqlpath=/opt/ts3server/sql/ \
    serverquerydocs_path=/opt/ts3server/serverquerydocs/ \
    logpath=/var/ts3server/logs \
    licensepath=/var/ts3server/ \
    query_ip_allowlist=/var/ts3server/query_ip_allowlist.txt \
    query_ip_denylist=/var/ts3server/query_ip_denylist.txt \
    "$@"

if [ -n "${TS3SERVER_SERVERADMIN_PASSWORD:-}" ]; then
    set -- "$@" serveradmin_password="$TS3SERVER_SERVERADMIN_PASSWORD"
fi

exec "$@"
```

Parameter names (`dbsqlpath`, `serverquerydocs_path`, `query_ip_allowlist`, `query_ip_denylist`, `serveradmin_password`, `license_accepted`) match what the TS3 3.13.8 binary accepts (verified against its startup output — it rejects `query_ip_blocklist` with an "Unknown command line parameter" warning).

Run: `shellcheck image/entrypoint.sh`
Expected: no output (clean).

- [ ] **Step 5: Write the Dockerfile**

Create `image/Dockerfile`:

```dockerfile
# Single source of truth for the version: release.yaml extracts it by matching
# the one "ARG TS3_VERSION=" line. Stages re-declare it bare to inherit this.
ARG TS3_VERSION=3.13.8

FROM cgr.dev/chainguard/wolfi-base:latest@sha256:02dab76bd852a70556b5b2002195c8a5fdab77d323c433bf6642aab080489795 AS download

ARG TS3_VERSION
ARG TS3_SHA256=a3c4658e09892d3dbd8ea752d0de42dc7d111bf44d09721927f0f4782496eb2d

SHELL ["/bin/sh", "-o", "pipefail", "-c"]

# hadolint ignore=DL3018
RUN apk add --no-cache curl bzip2 tar \
 && curl -fsSL "https://files.teamspeak-services.com/releases/server/${TS3_VERSION}/teamspeak3-server_linux_amd64-${TS3_VERSION}.tar.bz2" \
      -o /tmp/ts3server.tar.bz2 \
 && echo "${TS3_SHA256}  /tmp/ts3server.tar.bz2" | sha256sum -c - \
 && mkdir -p /opt/ts3server \
 && tar -xjf /tmp/ts3server.tar.bz2 --strip-components=1 -C /opt/ts3server \
 && rm -rf /opt/ts3server/tsdns /opt/ts3server/redist

FROM cgr.dev/chainguard/wolfi-base:latest@sha256:02dab76bd852a70556b5b2002195c8a5fdab77d323c433bf6642aab080489795

ARG TS3_VERSION

LABEL org.opencontainers.image.title="TeamSpeak 3 Server" \
      org.opencontainers.image.description="TeamSpeak ${TS3_VERSION} voice server, non-root, for Kubernetes" \
      org.opencontainers.image.source="https://github.com/christianhuening/teamspeak-k8s" \
      org.opencontainers.image.version="${TS3_VERSION}"

# hadolint ignore=DL3018
RUN apk add --no-cache libstdc++ \
 && addgroup -g 9987 ts3 \
 && adduser -u 9987 -G ts3 -h /var/ts3server -H -D -s /sbin/nologin ts3 \
 && mkdir -p /var/ts3server \
 && chown 9987:9987 /var/ts3server

COPY --from=download /opt/ts3server /opt/ts3server
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENV LD_LIBRARY_PATH=/opt/ts3server

WORKDIR /var/ts3server
USER 9987:9987

EXPOSE 9987/udp 10011/tcp 30033/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Notes: `tsdns` and `redist` (MariaDB lib) are removed — SQLite only per spec. Base is Wolfi (glibc, near-zero CVEs), digest-pinned since Chainguard's versioned tags are paid-only; Dependabot bumps the digest. `libstdc++` is the binary's only non-glibc library need (verified via readelf); wolfi-base already ships the CA bundle ts3server uses for TLS to TeamSpeak's accounting server. If busybox `tar -xjf` balks despite the `tar` package, use `bzcat /tmp/ts3server.tar.bz2 | tar -x --strip-components=1 -C /opt/ts3server`.

Run: `docker run --rm -i hadolint/hadolint:v2.14.0 < image/Dockerfile`
Expected: no output (clean). Fix any findings before proceeding.

- [ ] **Step 6: Build the image**

Run: `docker build -t ts3server:dev image/`
Expected: successful build ending `naming to docker.io/library/ts3server:dev`.

- [ ] **Step 7: Run smoke test to verify it passes**

Run: `./tests/image/smoke.sh ts3server:dev`
Expected: prints the three `---` sections then `smoke OK`, exit 0. First boot takes ~10–30s.

- [ ] **Step 8: Stage for commit**

```bash
git add image/ tests/image/
```

Suggested commit message: `feat: non-root TeamSpeak 3.13.8 container image with smoke test`. Tell the user it's staged; do not commit.

---

### Task 2: Helm chart core (StatefulSet, services, values, license gate)

**Files:**

- Create: `charts/teamspeak3/Chart.yaml`
- Create: `charts/teamspeak3/values.yaml`
- Create: `charts/teamspeak3/.helmignore`
- Create: `charts/teamspeak3/templates/_helpers.tpl`
- Create: `charts/teamspeak3/templates/statefulset.yaml`
- Create: `charts/teamspeak3/templates/service-external.yaml`
- Create: `charts/teamspeak3/templates/service-query.yaml`
- Test: `charts/teamspeak3/tests/statefulset_test.yaml`
- Test: `charts/teamspeak3/tests/services_test.yaml`

**Interfaces:**

- Consumes: image contract from Task 1 (env `TS3SERVER_LICENSE=accept`, optional `TS3SERVER_SERVERADMIN_PASSWORD`, state in `/var/ts3server`, `/tmp` writable, ports 9987/udp, 10011/tcp, 30033/tcp).
- Produces: chart `charts/teamspeak3`; for a release named `ts3`, the StatefulSet is `ts3-teamspeak3`, pod `ts3-teamspeak3-0`, services `ts3-teamspeak3-external` and `ts3-teamspeak3-query`. Values keys used by later tasks: `acceptLicense`, `image.repository`, `image.tag`, `persistence.size`. Task 3 adds `networkPolicy.enabled` and NOTES.txt to the same chart.

- [ ] **Step 1: Install helm-unittest plugin (if missing)**

Run: `helm plugin list | grep -q unittest || helm plugin install https://github.com/helm-unittest/helm-unittest.git --version 1.1.1`
Expected: plugin listed or installed. (Local helm is v4.x; helm-unittest ≥1.0 supports it.)

- [ ] **Step 2: Write the failing chart tests**

Create `charts/teamspeak3/tests/statefulset_test.yaml`:

```yaml
suite: statefulset
templates:
  - statefulset.yaml
tests:
  - it: refuses to render without license acceptance
    asserts:
      - failedTemplate:
          errorPattern: acceptLicense
  - it: renders exactly one replica
    set:
      acceptLicense: true
    asserts:
      - equal:
          path: spec.replicas
          value: 1
  - it: defaults the image tag to appVersion
    set:
      acceptLicense: true
    asserts:
      - equal:
          path: spec.template.spec.containers[0].image
          value: ghcr.io/christianhuening/teamspeak-k8s/ts3server:3.13.8
  - it: is restricted-PSA compliant
    set:
      acceptLicense: true
    asserts:
      - equal:
          path: spec.template.spec.securityContext.runAsNonRoot
          value: true
      - equal:
          path: spec.template.spec.securityContext.runAsUser
          value: 9987
      - equal:
          path: spec.template.spec.securityContext.seccompProfile.type
          value: RuntimeDefault
      - equal:
          path: spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem
          value: true
      - equal:
          path: spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation
          value: false
      - equal:
          path: spec.template.spec.containers[0].securityContext.capabilities.drop[0]
          value: ALL
  - it: wires the serveradmin password secret when configured
    set:
      acceptLicense: true
      serverQuery:
        existingSecret: ts3-admin
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content:
            name: TS3SERVER_SERVERADMIN_PASSWORD
            valueFrom:
              secretKeyRef:
                name: ts3-admin
                key: serveradmin-password
  - it: mounts data and tmp writable volumes
    set:
      acceptLicense: true
    asserts:
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: data
            mountPath: /var/ts3server
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: tmp
            mountPath: /tmp
```

Create `charts/teamspeak3/tests/services_test.yaml`:

```yaml
suite: services
templates:
  - service-external.yaml
  - service-query.yaml
tests:
  - it: external service defaults to NodePort with pinned ports
    template: service-external.yaml
    asserts:
      - equal:
          path: spec.type
          value: NodePort
      - equal:
          path: spec.externalTrafficPolicy
          value: Local
      - contains:
          path: spec.ports
          content:
            name: voice
            port: 9987
            targetPort: voice
            protocol: UDP
            nodePort: 30987
      - contains:
          path: spec.ports
          content:
            name: filetransfer
            port: 30033
            targetPort: filetransfer
            protocol: TCP
            nodePort: 30033
  - it: external service omits nodePorts and traffic policy as ClusterIP
    template: service-external.yaml
    set:
      service:
        external:
          type: ClusterIP
    asserts:
      - equal:
          path: spec.type
          value: ClusterIP
      - notExists:
          path: spec.externalTrafficPolicy
      - notExists:
          path: spec.ports[0].nodePort
  - it: query service is headless and internal
    template: service-query.yaml
    asserts:
      - equal:
          path: spec.clusterIP
          value: None
      - contains:
          path: spec.ports
          content:
            name: query
            port: 10011
            targetPort: query
            protocol: TCP
```

- [ ] **Step 3: Run chart tests to verify they fail**

Run: `helm unittest charts/teamspeak3`
Expected: FAIL — chart metadata/templates don't exist yet (`Chart.yaml file is missing` or similar).

- [ ] **Step 4: Write chart metadata and values**

Create `charts/teamspeak3/Chart.yaml`:

```yaml
apiVersion: v2
name: teamspeak3
description: TeamSpeak 3 voice server — single replica, SQLite on a PVC, restricted-PSA compliant
type: application
version: 0.1.0
appVersion: "3.13.8"
home: https://github.com/christianhuening/teamspeak-k8s
sources:
  - https://github.com/christianhuening/teamspeak-k8s
```

Create `charts/teamspeak3/values.yaml`:

```yaml
# You must explicitly accept the TeamSpeak 3 server license to install this chart.
# https://www.teamspeak.com/en/privacy-and-terms/
acceptLicense: false

image:
  repository: ghcr.io/christianhuening/teamspeak-k8s/ts3server
  # Defaults to the chart's appVersion.
  tag: ""
  pullPolicy: IfNotPresent

imagePullSecrets: []
nameOverride: ""
fullnameOverride: ""

service:
  external:
    # NodePort (default) | LoadBalancer | ClusterIP
    type: NodePort
    annotations: {}
    # Only rendered for LoadBalancer type; requires an LB implementation (e.g. Cilium LB-IPAM).
    loadBalancerIP: ""
    externalTrafficPolicy: Local
    voice:
      port: 9987
      nodePort: 30987
    filetransfer:
      # Must stay 30033: the server advertises this port to clients.
      port: 30033
      nodePort: 30033
  query:
    port: 10011

serverQuery:
  # Name of an existing Secret with key "serveradmin-password" to pin the
  # serveradmin password. Empty: credentials appear in first-boot logs.
  existingSecret: ""

persistence:
  size: 5Gi
  storageClassName: ""

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 512Mi

networkPolicy:
  enabled: false

# Extra ts3server command-line parameters, e.g. ["voice_ip=0.0.0.0"].
extraArgs: []
# Extra environment variables (Kubernetes EnvVar objects).
extraEnv: []

podAnnotations: {}
podLabels: {}
nodeSelector: {}
tolerations: []
affinity: {}
priorityClassName: ""
```

Create `charts/teamspeak3/.helmignore`:

```text
.DS_Store
*.tgz
tests/
```

- [ ] **Step 5: Write the helpers template**

Create `charts/teamspeak3/templates/_helpers.tpl`:

```yaml
{{- define "teamspeak3.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "teamspeak3.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "teamspeak3.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "teamspeak3.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "teamspeak3.selectorLabels" -}}
app.kubernetes.io/name: {{ include "teamspeak3.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

- [ ] **Step 6: Write the StatefulSet template**

Create `charts/teamspeak3/templates/statefulset.yaml`:

```yaml
{{- if not .Values.acceptLicense }}
{{- fail "TeamSpeak requires accepting its license. Review https://www.teamspeak.com/en/privacy-and-terms/ and install with --set acceptLicense=true" }}
{{- end }}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "teamspeak3.fullname" . }}
  labels:
    {{- include "teamspeak3.labels" . | nindent 4 }}
spec:
  # TS3 cannot scale horizontally; a second pod would corrupt the SQLite DB.
  replicas: 1
  serviceName: {{ include "teamspeak3.fullname" . }}-query
  selector:
    matchLabels:
      {{- include "teamspeak3.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      labels:
        {{- include "teamspeak3.selectorLabels" . | nindent 8 }}
        {{- with .Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 9987
        runAsGroup: 9987
        fsGroup: 9987
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: ts3server
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          {{- with .Values.extraArgs }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          env:
            - name: TS3SERVER_LICENSE
              value: accept
            {{- if .Values.serverQuery.existingSecret }}
            - name: TS3SERVER_SERVERADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.serverQuery.existingSecret }}
                  key: serveradmin-password
            {{- end }}
            {{- with .Values.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          ports:
            - name: voice
              containerPort: 9987
              protocol: UDP
            - name: filetransfer
              containerPort: 30033
              protocol: TCP
            - name: query
              containerPort: 10011
              protocol: TCP
          startupProbe:
            tcpSocket:
              port: query
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:
            tcpSocket:
              port: query
            periodSeconds: 10
          readinessProbe:
            tcpSocket:
              port: query
            periodSeconds: 10
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: data
              mountPath: /var/ts3server
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- with .Values.persistence.storageClassName }}
        storageClassName: {{ . }}
        {{- end }}
        resources:
          requests:
            storage: {{ .Values.persistence.size }}
```

- [ ] **Step 7: Write the service templates**

Create `charts/teamspeak3/templates/service-external.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "teamspeak3.fullname" . }}-external
  labels:
    {{- include "teamspeak3.labels" . | nindent 4 }}
  {{- with .Values.service.external.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ .Values.service.external.type }}
  {{- if ne .Values.service.external.type "ClusterIP" }}
  externalTrafficPolicy: {{ .Values.service.external.externalTrafficPolicy }}
  {{- end }}
  {{- if eq .Values.service.external.type "LoadBalancer" }}
  {{- with .Values.service.external.loadBalancerIP }}
  loadBalancerIP: {{ . }}
  {{- end }}
  {{- end }}
  selector:
    {{- include "teamspeak3.selectorLabels" . | nindent 4 }}
  ports:
    - name: voice
      port: {{ .Values.service.external.voice.port }}
      targetPort: voice
      protocol: UDP
      {{- if and (ne .Values.service.external.type "ClusterIP") .Values.service.external.voice.nodePort }}
      nodePort: {{ .Values.service.external.voice.nodePort }}
      {{- end }}
    - name: filetransfer
      port: {{ .Values.service.external.filetransfer.port }}
      targetPort: filetransfer
      protocol: TCP
      {{- if and (ne .Values.service.external.type "ClusterIP") .Values.service.external.filetransfer.nodePort }}
      nodePort: {{ .Values.service.external.filetransfer.nodePort }}
      {{- end }}
```

Create `charts/teamspeak3/templates/service-query.yaml`:

```yaml
# Headless: doubles as the StatefulSet's governing service. ServerQuery stays cluster-internal.
apiVersion: v1
kind: Service
metadata:
  name: {{ include "teamspeak3.fullname" . }}-query
  labels:
    {{- include "teamspeak3.labels" . | nindent 4 }}
spec:
  clusterIP: None
  selector:
    {{- include "teamspeak3.selectorLabels" . | nindent 4 }}
  ports:
    - name: query
      port: {{ .Values.service.query.port }}
      targetPort: query
      protocol: TCP
```

- [ ] **Step 8: Run chart tests to verify they pass**

Run: `helm unittest charts/teamspeak3`
Expected: all tests in both suites PASS.

- [ ] **Step 9: Run helm lint**

Run: `helm lint charts/teamspeak3 --set acceptLicense=true`
Expected: `1 chart(s) linted, 0 chart(s) failed`. Note: `helm lint` without the flag does NOT fail — Helm suppresses `fail` errors in lint by design (helm/helm#8973). The negative gate check is `helm template ts3 charts/teamspeak3` → must error mentioning `acceptLicense`.

- [ ] **Step 10: Stage for commit**

```bash
git add charts/teamspeak3/
```

Suggested commit message: `feat: teamspeak3 helm chart — single-replica statefulset, nodeport services, license gate`. Tell the user it's staged; do not commit.

---

### Task 3: Chart extras — NetworkPolicy and NOTES.txt

**Files:**

- Create: `charts/teamspeak3/templates/networkpolicy.yaml`
- Create: `charts/teamspeak3/templates/NOTES.txt`
- Test: `charts/teamspeak3/tests/networkpolicy_test.yaml`

**Interfaces:**

- Consumes: chart from Task 2 (helpers `teamspeak3.fullname`, `teamspeak3.labels`, `teamspeak3.selectorLabels`; values key `networkPolicy.enabled` already defined in values.yaml).
- Produces: optional NetworkPolicy (default off); NOTES.txt printed on install.

- [ ] **Step 1: Write the failing NetworkPolicy tests**

Create `charts/teamspeak3/tests/networkpolicy_test.yaml`:

```yaml
suite: networkpolicy
templates:
  - networkpolicy.yaml
tests:
  - it: renders nothing by default
    asserts:
      - hasDocuments:
          count: 0
  - it: allows public voice/filetransfer and namespace-local query when enabled
    set:
      networkPolicy:
        enabled: true
    asserts:
      - hasDocuments:
          count: 1
      - equal:
          path: spec.policyTypes[0]
          value: Ingress
      - contains:
          path: spec.ingress[0].ports
          content:
            protocol: UDP
            port: 9987
      - contains:
          path: spec.ingress[0].ports
          content:
            protocol: TCP
            port: 30033
      - contains:
          path: spec.ingress[1].ports
          content:
            protocol: TCP
            port: 10011
      - equal:
          path: spec.ingress[1].from[0].podSelector
          value: {}
```

Run: `helm unittest charts/teamspeak3`
Expected: FAIL — `networkpolicy.yaml` template not found.

- [ ] **Step 2: Write the NetworkPolicy template**

Create `charts/teamspeak3/templates/networkpolicy.yaml`:

```yaml
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "teamspeak3.fullname" . }}
  labels:
    {{- include "teamspeak3.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "teamspeak3.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
  ingress:
    # Voice and file transfer: open to the world.
    - ports:
        - protocol: UDP
          port: 9987
        - protocol: TCP
          port: 30033
    # ServerQuery: same namespace only (also covers kubelet probes on most CNIs;
    # if probes fail on your CNI, keep this policy disabled).
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 10011
{{- end }}
```

- [ ] **Step 3: Run chart tests to verify they pass**

Run: `helm unittest charts/teamspeak3`
Expected: all suites PASS (statefulset, services, networkpolicy).

- [ ] **Step 4: Write NOTES.txt**

Create `charts/teamspeak3/templates/NOTES.txt`:

```text
TeamSpeak 3 server deployed as {{ include "teamspeak3.fullname" . }} in namespace {{ .Release.Namespace }}.

1. First install only — retrieve the admin privilege key (token) and the
   serveradmin ServerQuery password from the logs:

   kubectl logs -n {{ .Release.Namespace }} {{ include "teamspeak3.fullname" . }}-0 | grep -E 'token=|password'

   Save both somewhere safe: they are only printed on first boot.

2. Connect a TeamSpeak client:
{{- if eq .Values.service.external.type "NodePort" }}

   Voice:         <node-public-ip>:{{ .Values.service.external.voice.nodePort }}  (UDP)
   File transfer: <node-public-ip>:{{ .Values.service.external.filetransfer.nodePort }}  (TCP)

   DNS setup: create an A record for your TeamSpeak hostname pointing at the
   node's public IP. Optionally add an SRV record so clients can omit the port:

     _ts3._udp.<hostname>.  3600 IN SRV 0 5 {{ .Values.service.external.voice.nodePort }} <hostname>.
{{- else if eq .Values.service.external.type "LoadBalancer" }}

   Voice:         <load-balancer-ip>:{{ .Values.service.external.voice.port }}  (UDP)
   File transfer: <load-balancer-ip>:{{ .Values.service.external.filetransfer.port }}  (TCP)

   Find the IP: kubectl get svc -n {{ .Release.Namespace }} {{ include "teamspeak3.fullname" . }}-external
{{- else }}

   The external service is ClusterIP — clients outside the cluster cannot
   connect. Switch service.external.type to NodePort or LoadBalancer.
{{- end }}

3. ServerQuery (admin CLI) is cluster-internal only. To use it:

   kubectl port-forward -n {{ .Release.Namespace }} {{ include "teamspeak3.fullname" . }}-0 10011:10011
   Then: telnet 127.0.0.1 10011
```

- [ ] **Step 5: Verify NOTES render for all three service types**

Run:

```bash
helm template ts3 charts/teamspeak3 --set acceptLicense=true | tail -5
helm template ts3 charts/teamspeak3 --set acceptLicense=true --set service.external.type=LoadBalancer >/dev/null && echo LB-OK
helm template ts3 charts/teamspeak3 --set acceptLicense=true --set service.external.type=ClusterIP >/dev/null && echo CIP-OK
helm lint charts/teamspeak3 --set acceptLicense=true
```

Expected: no template errors, `LB-OK`, `CIP-OK`, lint passes.

- [ ] **Step 6: Stage for commit**

```bash
git add charts/teamspeak3/
```

Suggested commit message: `feat: chart networkpolicy toggle and install NOTES`. Tell the user it's staged; do not commit.

---

### Task 4: kind e2e test

**Files:**

- Create: `tests/e2e/kind-config.yaml`
- Create: `tests/e2e/run.sh`

**Interfaces:**

- Consumes: image `ts3server:dev` (Task 1 contract: SQLite DB at `/var/ts3server/ts3server.sqlitedb`, token in first-boot logs, query on 10011) and chart naming from Task 2 (release `ts3` → pod `ts3-teamspeak3-0`).
- Produces: `tests/e2e/run.sh <image-ref>` — exits 0 on success. CI (Task 5) calls it with `ts3server:ci`.

- [ ] **Step 1: Write the kind config**

Create `tests/e2e/kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    # Host mappings so a real TeamSpeak client can connect to a local kind
    # cluster for manual testing. CI assertions don't depend on these.
    extraPortMappings:
      - containerPort: 30987
        hostPort: 30987
        protocol: UDP
      - containerPort: 30033
        hostPort: 30033
        protocol: TCP
```

- [ ] **Step 2: Write the e2e script**

Create `tests/e2e/run.sh` (mode 0755):

```bash
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
# Snapshot logs once and grep the variable: a bare `kubectl logs | grep -q`
# races SIGPIPE under pipefail (grep -q exits on first match).
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
```

Run: `shellcheck tests/e2e/run.sh`
Expected: no output (clean).

- [ ] **Step 3: Run the e2e end-to-end**

Run: `./tests/e2e/run.sh ts3server:dev`
Expected: each `==>` stage prints, ends with `e2e OK`, exit 0, and the kind cluster is deleted afterwards (check with `kind get clusters` — no `ts3-e2e`). Takes ~3–6 minutes. If the image is missing, rebuild it first: `docker build -t ts3server:dev image/`.

- [ ] **Step 4: Stage for commit**

```bash
git add tests/e2e/
```

Suggested commit message: `test: kind e2e — install chart, verify query handshake and persistence`. Tell the user it's staged; do not commit.

---

### Task 5: CI workflow

**Files:**

- Create: `.github/workflows/ci.yaml`
- Create: `.github/dependabot.yml`
- Create: `.trivyignore`

**Interfaces:**

- Consumes: `image/Dockerfile` (Task 1), `tests/image/smoke.sh` (Task 1), chart + unittest suites (Tasks 2–3), `tests/e2e/run.sh` (Task 4).
- Produces: CI on PRs and main; pushes `edge` + `sha-<7>` image tags to GHCR on main. Task 6's release workflow reuses the same login/build patterns.

- [ ] **Step 1: Write the Trivy ignore file**

Create `.trivyignore`:

```text
# CVEs accepted after review go here, one ID per line, with a comment on why.
```

- [ ] **Step 2: Write the CI workflow**

Create `.github/workflows/ci.yaml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - name: hadolint
        run: docker run --rm -i hadolint/hadolint:v2.14.0 < image/Dockerfile
      - name: shellcheck
        run: shellcheck image/entrypoint.sh tests/image/smoke.sh tests/e2e/run.sh
      - name: actionlint
        run: docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -color
      - name: helm lint
        run: helm lint charts/teamspeak3 --set acceptLicense=true
      - name: license gate blocks rendering
        # helm lint suppresses `fail` errors by design (helm/helm#8973), so the
        # negative check must use `helm template`.
        run: |
          if helm template ts3 charts/teamspeak3 >/dev/null 2>&1; then
            echo "license gate did not block rendering" && exit 1
          fi
      - name: helm unittest
        run: |
          helm plugin install https://github.com/helm-unittest/helm-unittest.git --version 1.1.1
          helm unittest charts/teamspeak3

  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - name: Build image
        run: docker build -t ts3server:ci image/
      - name: Smoke test (license gate, non-root, read-only boot)
        run: ./tests/image/smoke.sh ts3server:ci
      - name: Trivy scan
        run: |
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v "$PWD/.trivyignore:/.trivyignore:ro" \
            aquasec/trivy:0.72.0 image \
            --severity HIGH,CRITICAL --exit-code 1 \
            --ignorefile /.trivyignore \
            ts3server:ci
      - name: Save image artifact
        run: docker save ts3server:ci -o /tmp/ts3server-ci.tar
      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: image
          path: /tmp/ts3server-ci.tar
          retention-days: 1

  e2e:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          name: image
          path: /tmp
      - name: Load image
        run: docker load -i /tmp/ts3server-ci.tar
      - name: Install kind
        run: |
          curl -fsSLO "https://github.com/kubernetes-sigs/kind/releases/download/v0.32.0/kind-linux-amd64"
          curl -fsSLO "https://github.com/kubernetes-sigs/kind/releases/download/v0.32.0/kind-linux-amd64.sha256sum"
          sha256sum -c kind-linux-amd64.sha256sum
          sudo install -m 0755 kind-linux-amd64 /usr/local/bin/kind
      - name: Run e2e
        run: ./tests/e2e/run.sh ts3server:ci

  push-edge:
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    needs: [lint, build, e2e]
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          name: image
          path: /tmp
      - name: Load image
        run: docker load -i /tmp/ts3server-ci.tar
      - name: Login to GHCR
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
      - name: Push edge tags
        run: |
          IMAGE="ghcr.io/${{ github.repository }}/ts3server"
          docker tag ts3server:ci "$IMAGE:edge"
          docker tag ts3server:ci "$IMAGE:sha-${GITHUB_SHA::7}"
          docker push "$IMAGE:edge"
          docker push "$IMAGE:sha-${GITHUB_SHA::7}"
```

- [ ] **Step 3: Write the Dependabot config**

Create `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
  - package-ecosystem: docker
    directory: /image
    schedule:
      interval: weekly
```

- [ ] **Step 4: Validate the workflow**

Run: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -color`
Expected: no output (clean). Fix any findings.

- [ ] **Step 5: Stage for commit**

```bash
git add .github/ .trivyignore
```

Suggested commit message: `ci: lint, build, scan, and kind e2e on every PR; edge image push on main`. Tell the user it's staged; do not commit. Note to user: full CI verification requires pushing a branch/PR to GitHub.

---

### Task 6: Release workflow

**Files:**

- Create: `.github/workflows/release.yaml`

**Interfaces:**

- Consumes: `image/Dockerfile` (reads `ARG TS3_VERSION` as the image tag base), chart from Task 2.
- Produces: on tags `v*`: image `ghcr.io/christianhuening/teamspeak-k8s/ts3server:{3.13.8, 3.13.8-<sha7>}` with SBOM/provenance, chart at `oci://ghcr.io/christianhuening/charts/teamspeak3` versioned from the tag, and a GitHub Release.

- [ ] **Step 1: Write the release workflow**

Create `.github/workflows/release.yaml`:

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: write
  packages: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - name: Extract versions
        id: ver
        run: |
          TS3_VERSION="$(sed -n 's/^ARG TS3_VERSION=//p' image/Dockerfile | head -n1)"
          {
            echo "ts3=$TS3_VERSION"
            echo "chart=${GITHUB_REF_NAME#v}"
            echo "sha7=${GITHUB_SHA::7}"
          } >> "$GITHUB_OUTPUT"
      - name: Login to GHCR
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
      - name: Build and push image with SBOM and provenance
        run: |
          IMAGE="ghcr.io/${{ github.repository }}/ts3server"
          docker buildx create --use
          docker buildx build image/ \
            --platform linux/amd64 \
            --sbom=true --provenance=mode=max \
            --label "org.opencontainers.image.revision=$GITHUB_SHA" \
            --tag "$IMAGE:${{ steps.ver.outputs.ts3 }}" \
            --tag "$IMAGE:${{ steps.ver.outputs.ts3 }}-${{ steps.ver.outputs.sha7 }}" \
            --push
      - name: Package and push chart
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | helm registry login ghcr.io -u "${{ github.actor }}" --password-stdin
          helm package charts/teamspeak3 \
            --version "${{ steps.ver.outputs.chart }}" \
            --app-version "${{ steps.ver.outputs.ts3 }}"
          helm push "teamspeak3-${{ steps.ver.outputs.chart }}.tgz" \
            "oci://ghcr.io/${{ github.repository_owner }}/charts"
      - name: Create GitHub release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh release create "$GITHUB_REF_NAME" --generate-notes
```

- [ ] **Step 2: Validate the workflow**

Run: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -color`
Expected: no output (clean).

- [ ] **Step 3: Stage for commit**

```bash
git add .github/workflows/release.yaml
```

Suggested commit message: `ci: release workflow — push image (sbom/provenance) and OCI chart to ghcr on tags`. Tell the user it's staged; do not commit. Note to user: cutting `v0.1.0` after merge exercises this workflow.

---

### Task 7: README and final verification

**Files:**

- Modify: `README.md` (currently a one-line stub)

**Interfaces:**

- Consumes: everything above (install commands, values, e2e usage).
- Produces: user-facing documentation.

- [ ] **Step 1: Write the README**

Replace `README.md` content with:

````markdown
# teamspeak-k8s

Production-grade [TeamSpeak 3](https://teamspeak.com) server for Kubernetes:
a hardened non-root container image, a Helm chart, and a CI pipeline that
e2e-tests every change on [kind](https://kind.sigs.k8s.io).

- **Image:** `ghcr.io/christianhuening/teamspeak-k8s/ts3server` (TS3 3.13.8,
  checksum-pinned, runs as UID 9987, read-only root filesystem, linux/amd64)
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
  schema automatically. Expect a ~30s voice drop (single replica).
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
````

- [ ] **Step 2: Full local verification sweep**

Run:

```bash
shellcheck image/entrypoint.sh tests/image/smoke.sh tests/e2e/run.sh
docker run --rm -i hadolint/hadolint:v2.14.0 < image/Dockerfile
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -color
helm lint charts/teamspeak3 --set acceptLicense=true
helm unittest charts/teamspeak3
docker build -t ts3server:dev image/
./tests/image/smoke.sh ts3server:dev
./tests/e2e/run.sh ts3server:dev
```

Expected: every command exits 0; e2e ends `e2e OK`.

- [ ] **Step 3: Stage for commit**

```bash
git add README.md
```

Suggested commit message: `docs: usage, connection, and operations README`. Tell the user everything is staged and the plan is complete; the user commits and pushes, then opens a PR to watch CI run.
