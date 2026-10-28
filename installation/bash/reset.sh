#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
printf 'WARNUNG: Container und lokale Konfigurationen werden gelöscht. Mediendateien bleiben erhalten.\nZum Fortfahren RESET eingeben: '
read -r answer
[[ "$answer" == "RESET" ]] || { echo "Abgebrochen."; exit 0; }
docker compose --profile tailscale down --remove-orphans || true
rm -rf data
mkdir -p data
printf 'Reset abgeschlossen. Erneut starten mit: sudo ./setup.sh\n'
