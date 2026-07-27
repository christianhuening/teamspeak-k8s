# Single source of truth for the version: release.yaml extracts it by matching
# the one "ARG TS3_VERSION=" line. Stages re-declare it bare to inherit this.
ARG TS3_VERSION=3.13.8

FROM cgr.dev/chainguard/wolfi-base:latest@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e AS download

ARG TS3_VERSION
ARG TS3_SHA256=a3c4658e09892d3dbd8ea752d0de42dc7d111bf44d09721927f0f4782496eb2d

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3018
RUN apk add --no-cache curl bzip2 \
 && curl -fsSL "https://files.teamspeak-services.com/releases/server/${TS3_VERSION}/teamspeak3-server_linux_amd64-${TS3_VERSION}.tar.bz2" \
      -o /tmp/ts3server.tar.bz2 \
 && echo "${TS3_SHA256}  /tmp/ts3server.tar.bz2" | sha256sum -c - \
 && mkdir -p /opt/ts3server \
 && tar -xjf /tmp/ts3server.tar.bz2 --strip-components=1 -C /opt/ts3server \
 && rm -rf /opt/ts3server/tsdns /opt/ts3server/redist

FROM cgr.dev/chainguard/wolfi-base:latest@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e

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
