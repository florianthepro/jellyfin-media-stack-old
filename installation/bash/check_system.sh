#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
LOG_FILE="/var/log/${APP_NAME}-setup.log"
SUPPORTED_SYSTEMS="debian ubuntu"
REQUIRED_PACKAGES="ca-certificates curl gnupg jq"
MIN_FREE_GB=15

BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
RESET='\033[0m'

phase() { printf '%b%s%b\n' "$BLUE" "$1" "$RESET"; }
ok() { printf '%bOK%b  %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '%bFEHLER%b  %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

trap 'rc=$?; printf "%bFEHLER%b  Systempruefung fehlgeschlagen. Log: sudo cat %s\n" "$RED" "$RESET" "$LOG_FILE" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || fail "Aufruf: curl -fsSL https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main/installation/bash/check_systems.sh | sudo bash"

install -m 0600 /dev/null "$LOG_FILE"
exec 3>&1 4>&2
exec >>"$LOG_FILE" 2>&1

exec 1>&3 2>&4
phase "System wird geprueft ..."
exec >>"$LOG_FILE" 2>&1

[[ -r /etc/os-release ]] || fail "/etc/os-release fehlt oder ist nicht lesbar."
. /etc/os-release

case " $SUPPORTED_SYSTEMS " in
  *" ${ID:-} "*) ;;
  *) fail "Unterstuetzt werden Debian und Ubuntu. Erkannt: ${ID:-unbekannt}" ;;
esac

command -v apt-get >/dev/null 2>&1 || fail "apt-get wurde nicht gefunden."
command -v dpkg >/dev/null 2>&1 || fail "dpkg wurde nicht gefunden."
command -v systemctl >/dev/null 2>&1 || fail "systemd wird benoetigt."
[[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]] || fail "systemd ist nicht als Init-System aktiv."

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) fail "Nicht unterstuetzte Architektur: $ARCH" ;;
esac

ROOT_FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
REQUIRED_FREE_KB=$((MIN_FREE_GB * 1024 * 1024))
[[ "$ROOT_FREE_KB" -ge "$REQUIRED_FREE_KB" ]] || fail "Mindestens ${MIN_FREE_GB} GB freier Speicherplatz auf / erforderlich."

MISSING_PACKAGES=()
for package in $REQUIRED_PACKAGES; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' || MISSING_PACKAGES+=("$package")
done

if ((${#MISSING_PACKAGES[@]})); then
  apt-get update -y
  apt-get install -y "${MISSING_PACKAGES[@]}"
fi

for command_name in curl gpg jq findmnt awk sed grep; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Benoetigter Befehl fehlt: $command_name"
done

curl -fsS --connect-timeout 10 --max-time 20 https://download.docker.com/ >/dev/null
curl -fsS --connect-timeout 10 --max-time 20 https://raw.githubusercontent.com/ >/dev/null

exec 1>&3 2>&4
ok "${PRETTY_NAME:-$ID} auf $ARCH"
ok "Grundpakete sind vorhanden"
ok "Mindestens ${MIN_FREE_GB} GB freier Speicherplatz ist vorhanden"
ok "Docker- und GitHub-Downloadziele sind erreichbar"
printf '\nSystempruefung abgeschlossen.\nLog: %s\n\n' "$LOG_FILE"
