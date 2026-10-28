#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
docker compose ps
