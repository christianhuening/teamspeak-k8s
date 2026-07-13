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
