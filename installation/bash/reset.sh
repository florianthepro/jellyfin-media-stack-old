#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
INSTALL_DIR="/opt/${APP_NAME}"
MEDIA_DIR="/srv/media"
LOG_FILE="/var/log/${APP_NAME}-reset.log"
KNOWN_CONTAINERS=(jellyfin seerr sonarr radarr prowlarr qbittorrent tailscale)
KNOWN_IMAGES=(jellyfin/jellyfin:latest ghcr.io/seerr-team/seerr:latest lscr.io/linuxserver/sonarr:latest lscr.io/linuxserver/radarr:latest lscr.io/linuxserver/prowlarr:latest lscr.io/linuxserver/qbittorrent:latest tailscale/tailscale:stable)

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

info() { printf '%b[i]%b %s: %s\n' "$BLUE" "$RESET" "$1" "$2"; }
ok() { printf '%b[✓]%b %s: %s\n' "$GREEN" "$RESET" "$1" "$2"; }
warn() { printf '%b[!]%b %s: %s\n' "$YELLOW" "$RESET" "$1" "$2"; }
fail() { printf '%b[✗]%b %s: %s\n' "$RED" "$RESET" "$1" "$2"; }

read_tty() {
  local name="$1" value
  [[ -r /dev/tty ]] || { fail "Fehler" "Keine interaktive Eingabe möglich"; exit 1; }
  IFS= read -r value </dev/tty || value=""
  printf -v "$name" '%s' "$value"
}

run_quiet() {
  "$@" >>"$LOG_FILE" 2>&1
}

finish_user() {
  printf 'User beendet.\n'
  info "Log" "$LOG_FILE"
  exit "${1:-0}"
}

trap 'rc=$?; fail "Reset" "fehlgeschlagen" >&2; info "Log" "$LOG_FILE" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || { fail "Fehler" "Aufruf mit sudo erforderlich"; exit 1; }
install -m 0600 /dev/null "$LOG_FILE"

if [[ -f "$INSTALL_DIR/.env" ]]; then
  DETECTED_MEDIA="$(sed -nE 's/^(MEDIA|MEDIA_DIR)=(.*)$/\2/p' "$INSTALL_DIR/.env" | tail -n1)"
  [[ -n "$DETECTED_MEDIA" ]] && MEDIA_DIR="$DETECTED_MEDIA"
fi

[[ "$INSTALL_DIR" == /opt/* && "$INSTALL_DIR" != /opt ]] || { fail "Pfad" "$INSTALL_DIR ist unsicher"; finish_user 1; }
[[ "$MEDIA_DIR" == /* && "$MEDIA_DIR" != / ]] || { fail "Pfad" "$MEDIA_DIR ist unsicher"; finish_user 1; }
[[ "$INSTALL_DIR" != "$MEDIA_DIR" ]] || { fail "Pfad" "Installation und Medien sind identisch"; finish_user 1; }

printf '%bJellyfin Media Stack - Reset%b\n' "$BLUE" "$RESET"
info "Medien" "$MEDIA_DIR bleibt erhalten"
warn "Reset" "alle übrigen Projektdaten werden gelöscht"
printf '[?] Projekt vollständig zurücksetzen [n]: '
read_tty ANSWER
case "${ANSWER,,}" in
  y|yes|j|ja) ;;
  *) finish_user 0 ;;
esac

if command -v docker >/dev/null 2>&1; then
  mapfile -t PROJECT_CONTAINERS < <(docker ps -aq --filter "label=com.docker.compose.project=${APP_NAME}" 2>/dev/null || true)
  for name in "${KNOWN_CONTAINERS[@]}"; do
    ID="$(docker ps -aq --filter "name=^/${name}$" 2>/dev/null || true)"
    [[ -n "$ID" ]] && PROJECT_CONTAINERS+=("$ID")
  done
  mapfile -t PROJECT_CONTAINERS < <(printf '%s\n' "${PROJECT_CONTAINERS[@]:-}" | sed '/^$/d' | sort -u)

  PROJECT_IMAGES=()
  for id in "${PROJECT_CONTAINERS[@]:-}"; do
    IMAGE="$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || true)"
    [[ -n "$IMAGE" ]] && PROJECT_IMAGES+=("$IMAGE")
  done
  PROJECT_IMAGES+=("${KNOWN_IMAGES[@]}")
  mapfile -t PROJECT_IMAGES < <(printf '%s\n' "${PROJECT_IMAGES[@]}" | sed '/^$/d' | sort -u)

  if [[ -f "$INSTALL_DIR/compose.yaml" ]]; then
    (cd "$INSTALL_DIR" && run_quiet docker compose --profile tailscale down --remove-orphans --volumes) || true
  fi

  if ((${#PROJECT_CONTAINERS[@]})); then
    run_quiet docker rm -f -v "${PROJECT_CONTAINERS[@]}" || true
  fi

  mapfile -t PROJECT_NETWORKS < <(docker network ls -q --filter "label=com.docker.compose.project=${APP_NAME}" 2>/dev/null || true)
  LEGACY_NETWORK="$(docker network ls -q --filter "name=^${APP_NAME}_default$" 2>/dev/null || true)"
  [[ -n "$LEGACY_NETWORK" ]] && PROJECT_NETWORKS+=("$LEGACY_NETWORK")
  if ((${#PROJECT_NETWORKS[@]})); then
    run_quiet docker network rm "${PROJECT_NETWORKS[@]}" || true
  fi

  mapfile -t PROJECT_VOLUMES < <(docker volume ls -q --filter "label=com.docker.compose.project=${APP_NAME}" 2>/dev/null || true)
  if ((${#PROJECT_VOLUMES[@]})); then
    run_quiet docker volume rm -f "${PROJECT_VOLUMES[@]}" || true
  fi

  for image in "${PROJECT_IMAGES[@]}"; do
    docker image inspect "$image" >/dev/null 2>&1 && run_quiet docker image rm -f "$image" || true
  done

  run_quiet docker builder prune -f --filter "until=24h" || true
fi

if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf --one-file-system -- "$INSTALL_DIR"
fi

rm -f -- "/etc/systemd/system/${APP_NAME}.service" "/etc/systemd/system/${APP_NAME}.timer"
rm -f -- "/usr/local/bin/${APP_NAME}" "/usr/local/bin/${APP_NAME}-status" "/usr/local/bin/${APP_NAME}-update"
systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

if [[ -d "$MEDIA_DIR" ]]; then
  ok "Medien" "erhalten"
else
  warn "Medien" "Verzeichnis war nicht vorhanden"
fi
ok "Reset" "abgeschlossen"
info "Log" "$LOG_FILE"
