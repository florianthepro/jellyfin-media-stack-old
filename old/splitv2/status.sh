#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
docker compose ps
echo
echo "Letzte Logs:"
docker compose logs --tail=40
