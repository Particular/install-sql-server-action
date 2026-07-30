#!/usr/bin/env bash
# Installs the SQL Server Full-Text Search package inside an already-running SQL
# Server container started with `--entrypoint /bin/bash ... -lc "sleep infinity"`.
#
# The action substitutes __CHANNEL__ (mssql-server apt repo channel, e.g. "2022")
# and __ENGINE__ (SQL Server major version, e.g. "16") into a rendered copy
# before `docker cp`-ing it into the container, so this file never needs to be
# edited per SQL Server version.

set -euo pipefail

rm -f /etc/apt/sources.list.d/mssql-server.list

apt-get update

ACCEPT_EULA=Y apt-get install -y --no-install-recommends curl gnupg

. /etc/os-release

curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor > /usr/share/keyrings/microsoft-prod.gpg

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/${VERSION_ID}/mssql-server-__CHANNEL__ ${VERSION_CODENAME} main" \
    > /etc/apt/sources.list.d/mssql-server.list

apt-get update

fts_version=$(apt-cache madison mssql-server-fts \
    | awk '{print $3}' \
    | grep -E '^__ENGINE__\.' \
    | head -n 1)

if [ -z "${fts_version}" ]; then
    echo "No mssql-server-fts package found for SQL Server engine major __ENGINE__." >&2
    exit 1
fi

ACCEPT_EULA=Y apt-get install -y --no-install-recommends "mssql-server-fts=${fts_version}"

apt-get clean
rm -rf /var/lib/apt/lists/*
