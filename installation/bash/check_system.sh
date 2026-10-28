#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
LOG_FILE="/var/log/${APP_NAME}-setup.log"
MIN_FREE_GB=20
REQUIRED_PACKAGES=(ca-certificates curl gnupg jq)

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

line_info() { printf '%b[i]%b %s: %s\n' "$BLUE" "$RESET" "$1" "$2"; }
line_ok() { printf '%b[✓]%b %s: %s\n' "$GREEN" "$RESET" "$1" "$2"; }
line_warn() { printf '%b[!]%b %s: %s\n' "$YELLOW" "$RESET" "$1" "$2"; }
line_fail() { printf '%b[✗]%b %s: %s\n' "$RED" "$RESET" "$1" "$2"; }
die() { line_fail "Fehler" "$1" >&2; exit 1; }

trap 'rc=$?; line_fail "Fehler" "Systemprüfung fehlgeschlagen. Log: sudo cat $LOG_FILE" >&2; exit "$rc"' ERR

read_tty() {
  local __name="$1" value
  [[ -r /dev/tty ]] || die "Keine interaktive Eingabe möglich."
  IFS= read -r value </dev/tty || value=""
  printf -v "$__name" '%s' "$value"
}

run_quiet() {
  "$@" >>"$LOG_FILE" 2>&1
}

refresh_checks() {
  MISSING_PACKAGES=()
  for package in "${REQUIRED_PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' || MISSING_PACKAGES+=("$package")
  done

  run_quiet apt-get update -qq
  mapfile -t AVAILABLE_UPDATES < <(apt list --upgradable 2>/dev/null | tail -n +2)
  UPDATE_COUNT="${#AVAILABLE_UPDATES[@]}"
}

show_status() {
  clear 2>/dev/null || true
  printf '%bJellyfin Media Stack - Systemprüfung%b\n\n' "$BLUE" "$RESET"
  line_info "System" "${PRETTY_NAME:-$ID} $ARCH"

  if (( FREE_KB >= REQUIRED_KB )); then
    line_ok "Speicher" "${FREE_GB} GB frei / ${MIN_FREE_GB} GB benötigt"
  else
    line_fail "Speicher" "${FREE_GB} GB frei / ${MIN_FREE_GB} GB benötigt"
  fi

  if [[ "$GITHUB_CODE" == "200" ]]; then
    line_ok "GitHub" "erreichbar (${GITHUB_TIME}s)"
  else
    line_fail "GitHub" "nicht erreichbar (HTTP ${GITHUB_CODE:-unbekannt})"
  fi

  if [[ "$DOCKER_CODE" =~ ^(200|301|302)$ ]]; then
    line_ok "Docker" "erreichbar (${DOCKER_TIME}s)"
  else
    line_fail "Docker" "nicht erreichbar (HTTP ${DOCKER_CODE:-unbekannt})"
  fi

  if ((${#MISSING_PACKAGES[@]})); then
    line_warn "Pakete" "fehlen: ${MISSING_PACKAGES[*]}"
  else
    line_ok "Pakete" "vollständig"
  fi

  if (( UPDATE_COUNT > 0 )); then
    line_warn "Updates" "${UPDATE_COUNT} verfügbar"
  else
    line_ok "Updates" "keine verfügbar"
  fi
}

next_action() {
  ACTION=""
  ACTION_TEXT=""

  if ((${#MISSING_PACKAGES[@]})); then
    ACTION="packages"
    ACTION_TEXT="Fehlende Pakete installieren"
    return
  fi

  if (( UPDATE_COUNT > 0 )); then
    ACTION="updates"
    ACTION_TEXT="Verfügbare Updates installieren"
  fi
}

handle_decline() {
  local answer
  printf '\nÜberspringen oder Prüfung abbrechen? [ü/A]: '
  read_tty answer
  case "${answer,,}" in
    ü|ue|u|überspringen|ueberspringen)
      SKIPPED_ACTIONS+=("$ACTION")
      ;;
    *)
      printf '\nPrüfung abgebrochen.\n'
      exit 1
      ;;
  esac
}

install_action() {
  case "$ACTION" in
    packages)
      printf '\nFehlende Pakete werden installiert ... '
      if run_quiet apt-get install -y "${MISSING_PACKAGES[@]}"; then
        printf '%bOK%b\n' "$GREEN" "$RESET"
      else
        printf '%bFEHLER%b\n' "$RED" "$RESET"
        die "Paketinstallation fehlgeschlagen. Log: sudo cat $LOG_FILE"
      fi
      ;;
    updates)
      printf '\nUpdates werden installiert ... '
      if run_quiet apt-get upgrade -y; then
        printf '%bOK%b\n' "$GREEN" "$RESET"
      else
        printf '%bFEHLER%b\n' "$RED" "$RESET"
        die "Updateinstallation fehlgeschlagen. Log: sudo cat $LOG_FILE"
      fi
      ;;
  esac
}

[[ $EUID -eq 0 ]] || die "Aufruf mit sudo erforderlich."
install -m 0600 /dev/null "$LOG_FILE"

[[ -r /etc/os-release ]] || die "/etc/os-release fehlt oder ist nicht lesbar."
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "Unterstützt werden Debian und Ubuntu. Erkannt: ${ID:-unbekannt}" ;;
esac

command -v apt-get >/dev/null 2>&1 || die "apt-get wurde nicht gefunden."
command -v dpkg >/dev/null 2>&1 || die "dpkg wurde nicht gefunden."
command -v systemctl >/dev/null 2>&1 || die "systemd wird benötigt."
[[ "$(ps -p 1 -o comm= 2>/dev/null | xargs)" == "systemd" ]] || die "systemd ist nicht aktiv."

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "Nicht unterstützte Architektur: $ARCH" ;;
esac

TOTAL_KB="$(df -Pk / | awk 'NR==2 {print $2}')"
FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
TOTAL_GB="$(awk -v value="$TOTAL_KB" 'BEGIN {printf "%.1f", value/1024/1024}')"
FREE_GB="$(awk -v value="$FREE_KB" 'BEGIN {printf "%.1f", value/1024/1024}')"
REQUIRED_KB=$((MIN_FREE_GB * 1024 * 1024))

command -v curl >/dev/null 2>&1 || die "curl wird für die Netzwerkprüfung benötigt."
GITHUB_CODE="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{http_code}' https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main/README.md || true)"
GITHUB_TIME="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{time_total}' https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main/README.md || true)"
DOCKER_CODE="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{http_code}' https://download.docker.com/linux/ || true)"
DOCKER_TIME="$(curl -L -o /dev/null -sS --connect-timeout 10 --max-time 30 -w '%{time_total}' https://download.docker.com/linux/ || true)"

(( FREE_KB >= REQUIRED_KB )) || die "Mindestens ${MIN_FREE_GB} GB freier Speicher erforderlich."
[[ "$GITHUB_CODE" == "200" ]] || die "GitHub Raw ist nicht erreichbar."
[[ "$DOCKER_CODE" =~ ^(200|301|302)$ ]] || die "Docker ist nicht erreichbar."

SKIPPED_ACTIONS=()

while true; do
  refresh_checks
  show_status
  next_action

  if [[ -z "$ACTION" ]]; then
    printf '\n[Enter] Beenden: '
    read_tty answer
    printf '\nSystemprüfung abgeschlossen.\nLog: %s\n\n' "$LOG_FILE"
    exit 0
  fi

  if printf '%s\n' "${SKIPPED_ACTIONS[@]:-}" | grep -qx "$ACTION"; then
    line_warn "Übersprungen" "$ACTION_TEXT"
    printf '\nKeine weiteren Aktionen verfügbar. [Enter] Beenden: '
    read_tty answer
    printf '\nSystemprüfung mit übersprungenen Aktionen beendet.\nLog: %s\n\n' "$LOG_FILE"
    exit 0
  fi

  printf '\n[Enter] %s | [n] Nicht ausführen: ' "$ACTION_TEXT"
  read_tty answer
  case "${answer,,}" in
    "") install_action ;;
    n|nein|no) handle_decline ;;
    *) continue ;;
  esac
done
