#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

clear

APP_NAME="jellyfin-media-stack"
LOG_FILE="/var/log/${APP_NAME}-setup.log"
MIN_FREE_GB=20
REQUIRED_PACKAGES=(ca-certificates curl gnupg jq)

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

info() { printf '%b[i]%b %s: %s\n' "$BLUE" "$RESET" "$1" "$2"; }
ok() { printf '%b[✓]%b %s: %s\n' "$GREEN" "$RESET" "$1" "$2"; }
warn() { printf '%b[!]%b %s: %s\n' "$YELLOW" "$RESET" "$1" "$2"; }
fail() { printf '%b[✗]%b %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

ask_yes_no() {
  local prompt="$1" answer
  [[ -r /dev/tty ]] || fail "Keine interaktive Eingabe möglich. Bitte direkt in einem Terminal ausführen."
  while true; do
    printf '%s [j/N]: ' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
    case "${answer,,}" in
      j|ja|y|yes) return 0 ;;
      ""|n|nein|no) return 1 ;;
      *) printf 'Bitte ja oder nein eingeben.\n' > /dev/tty ;;
    esac
  done
}

trap 'rc=$?; printf "%b%-12s%b Systemprüfung fehlgeschlagen. Log: sudo cat %s\n" "$RED" "FEHLER" "$RESET" "$LOG_FILE" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || fail "Aufruf mit sudo erforderlich."
install -m 0600 /dev/null "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

printf '\n%bJellyfin Media Stack - Systemprüfung%b\n\n' "$BLUE" "$RESET"

[[ -r /etc/os-release ]] || fail "/etc/os-release fehlt oder ist nicht lesbar."
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) info "System" "${PRETTY_NAME:-$ID} $(dpkg --print-architecture)" ;;
  *) fail "Unterstützt werden Debian und Ubuntu. Erkannt: ${ID:-unbekannt}" ;;
esac

command -v apt-get >/dev/null 2>&1 || fail "apt-get wurde nicht gefunden."
command -v dpkg >/dev/null 2>&1 || fail "dpkg wurde nicht gefunden."
command -v systemctl >/dev/null 2>&1 || fail "systemd wird benötigt."
[[ "$(ps -p 1 -o comm= 2>/dev/null | xargs)" == "systemd" ]] || fail "systemd ist nicht als Init-System aktiv."

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) fail "Nicht unterstützte Architektur: $ARCH" ;;
esac

TOTAL_KB="$(df -Pk / | awk 'NR==2 {print $2}')"
USED_KB="$(df -Pk / | awk 'NR==2 {print $3}')"
FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
TOTAL_GB="$(awk -v value="$TOTAL_KB" 'BEGIN {printf "%.1f", value/1024/1024}')"
USED_GB="$(awk -v value="$USED_KB" 'BEGIN {printf "%.1f", value/1024/1024}')"
FREE_GB="$(awk -v value="$FREE_KB" 'BEGIN {printf "%.1f", value/1024/1024}')"
REQUIRED_KB=$((MIN_FREE_GB * 1024 * 1024))

if (( FREE_KB >= REQUIRED_KB )); then
  ok "Speicher" "${FREE_GB} GB frei / ${MIN_FREE_GB} GB benötigt (gesamt ${TOTAL_GB} GB)"
else
  fail "Speicher: ${FREE_GB} GB frei / ${MIN_FREE_GB} GB benötigt"
fi

if command -v curl >/dev/null 2>&1; then
  GITHUB_CODE="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{http_code}' https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main/README.md || true)"
  GITHUB_TIME="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{time_total}' https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main/README.md || true)"
  GITHUB_SPEED="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{speed_download}' https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main/README.md || true)"
  if [[ "$GITHUB_CODE" == "200" ]]; then
    GITHUB_KBIT="$(awk -v value="${GITHUB_SPEED:-0}" 'BEGIN {printf "%.0f", value*8/1000}')"
    ok "Netzwerk" "GitHub erreichbar (${GITHUB_TIME}s, ${GITHUB_KBIT} kbit/s)"
  else
    fail "GitHub Raw ist nicht erreichbar. HTTP-Status: ${GITHUB_CODE:-unbekannt}"
  fi

  DOCKER_CODE="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{http_code}' https://download.docker.com/linux/ || true)"
  DOCKER_TIME="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{time_total}' https://download.docker.com/linux/ || true)"
  if [[ "$DOCKER_CODE" =~ ^(200|301|302)$ ]]; then
    ok "Netzwerk" "Docker erreichbar (${DOCKER_TIME}s)"
  else
    fail "Docker-Downloadserver ist nicht erreichbar. HTTP-Status: ${DOCKER_CODE:-unbekannt}"
  fi
else
  warn "Netzwerk" "curl fehlt; Downloadziele werden nach der Paketinstallation geprüft."
fi

MISSING_PACKAGES=()
for package in "${REQUIRED_PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' || MISSING_PACKAGES+=("$package")
done

if ((${#MISSING_PACKAGES[@]} == 0)); then
  ok "Pakete" "Alle Grundpakete sind installiert"
else
  warn "Pakete" "Fehlend: ${MISSING_PACKAGES[*]}"
  if ask_yes_no "Fehlende Pakete jetzt installieren?"; then
    apt-get update
    apt-get install -y "${MISSING_PACKAGES[@]}"
    ok "Pakete" "Fehlende Grundpakete wurden installiert"
  else
    fail "Die benötigten Grundpakete wurden nicht installiert."
  fi
fi

info "Updates" "Verfügbare Paketaktualisierungen werden geprüft ..."
apt-get update -qq
mapfile -t UPDATES < <(apt list --upgradable 2>/dev/null | tail -n +2)
UPDATE_COUNT="${#UPDATES[@]}"

if (( UPDATE_COUNT == 0 )); then
  ok "Updates" "Das System ist aktuell"
else
  warn "Updates" "${UPDATE_COUNT} Paketaktualisierung(en) verfügbar"
  printf '%s\n' "${UPDATES[@]:0:10}"
  (( UPDATE_COUNT > 10 )) && printf '... und %d weitere\n' "$((UPDATE_COUNT - 10))"
  if ask_yes_no "Verfügbare Updates jetzt installieren?"; then
    apt-get upgrade -y
    ok "Updates" "Paketaktualisierungen wurden installiert"
  else
    warn "Updates" "Paketaktualisierungen wurden übersprungen"
  fi
fi

for command_name in curl gpg jq findmnt awk sed grep; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Benötigter Befehl fehlt: $command_name"
done

printf '\n%bSystemprüfung abgeschlossen.%b\n' "$GREEN" "$RESET"
printf 'Log: %s\n\n' "$LOG_FILE"
