#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
clear
DEBUG=1

APP_NAME="jellyfin-media-stack"
INSTALL_DIR="/opt/${APP_NAME}"
LOG_FILE="/var/log/${APP_NAME}-start.log"
DEBUG_LOG_FILE="/var/log/${APP_NAME}-interfaces.log"
WAIT_SECONDS=180

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

info() { printf '%b[i]%b %s: %s\n' "$BLUE" "$RESET" "$1" "$2"; }
ok() { printf '%b[✓]%b %s: %s\n' "$GREEN" "$RESET" "$1" "$2"; }
warn() { printf '%b[!]%b %s: %s\n' "$YELLOW" "$RESET" "$1" "$2"; }
fail() { printf '%b[✗]%b %s: %s\n' "$RED" "$RESET" "$1" "$2"; }
run_quiet() { "$@" >>"$LOG_FILE" 2>&1; }

finish_error() {
  fail "Start" "$1"
  info "Log" "sudo cat $LOG_FILE"
  (( DEBUG )) && info "Debug" "sudo cat $DEBUG_LOG_FILE"
  exit 1
}

trap 'rc=$?; fail "Start" "fehlgeschlagen" >&2; info "Log" "sudo cat $LOG_FILE" >&2; (( DEBUG )) && info "Debug" "sudo cat $DEBUG_LOG_FILE" >&2; exit "$rc"' ERR

write_debug_header() {
  printf '\n===== %s | %s =====\n' "$(date -Is)" "$1" >>"$DEBUG_LOG_FILE"
}

probe_http() {
  local service="$1" url="$2" body_file code content_type
  body_file="$(mktemp)"
  code="$(curl -sS -L --connect-timeout 3 --max-time 15 -o "$body_file" -w '%{http_code}' "$url" 2>>"$DEBUG_LOG_FILE" || true)"
  content_type="$(file -b --mime-type "$body_file" 2>/dev/null || printf unknown)"
  write_debug_header "$service | GET $url"
  printf 'HTTP_STATUS=%s\nCONTENT_TYPE=%s\n' "${code:-000}" "$content_type" >>"$DEBUG_LOG_FILE"
  if [[ -s "$body_file" ]]; then
    if jq -e . "$body_file" >/dev/null 2>&1; then
      jq . "$body_file" >>"$DEBUG_LOG_FILE" 2>&1
    else
      head -c 131072 "$body_file" >>"$DEBUG_LOG_FILE"
      printf '\n' >>"$DEBUG_LOG_FILE"
    fi
  else
    printf '<empty body>\n' >>"$DEBUG_LOG_FILE"
  fi
  rm -f "$body_file"
  printf '%s' "${code:-000}"
}

probe_service() {
  local service="$1" successful=0 code endpoint
  case "$service" in
    jellyfin)
      for endpoint in \
        http://127.0.0.1:8096/health \
        http://127.0.0.1:8096/System/Info/Public \
        http://127.0.0.1:8096/Startup/Configuration \
        http://127.0.0.1:8096/openapi.json \
        http://127.0.0.1:8096/swagger/v1/swagger.json; do
        code="$(probe_http Jellyfin "$endpoint")"
        [[ "$code" =~ ^2 ]] && successful=1
      done
      ;;
    seerr)
      for endpoint in \
        http://127.0.0.1:5055/api/v1/status \
        http://127.0.0.1:5055/api/v1/settings/public \
        http://127.0.0.1:5055/api-docs \
        http://127.0.0.1:5055/swagger.json; do
        code="$(probe_http Seerr "$endpoint")"
        [[ "$code" =~ ^2 ]] && successful=1
      done
      ;;
    sonarr)
      for endpoint in \
        http://127.0.0.1:8989/ping \
        http://127.0.0.1:8989/api/v3/system/status \
        http://127.0.0.1:8989/swagger/v1/swagger.json; do
        code="$(probe_http Sonarr "$endpoint")"
        [[ "$code" =~ ^2 ]] && successful=1
      done
      ;;
    radarr)
      for endpoint in \
        http://127.0.0.1:7878/ping \
        http://127.0.0.1:7878/api/v3/system/status \
        http://127.0.0.1:7878/swagger/v1/swagger.json; do
        code="$(probe_http Radarr "$endpoint")"
        [[ "$code" =~ ^2 ]] && successful=1
      done
      ;;
    prowlarr)
      for endpoint in \
        http://127.0.0.1:9696/ping \
        http://127.0.0.1:9696/api/v1/system/status \
        http://127.0.0.1:9696/swagger/v1/swagger.json; do
        code="$(probe_http Prowlarr "$endpoint")"
        [[ "$code" =~ ^2 ]] && successful=1
      done
      ;;
    qbittorrent)
      for endpoint in \
        http://127.0.0.1:8080/api/v2/app/version \
        http://127.0.0.1:8080/api/v2/app/webapiVersion \
        http://127.0.0.1:8080/api/v2/app/preferences; do
        code="$(probe_http qBittorrent "$endpoint")"
        [[ "$code" =~ ^2 ]] && successful=1
      done
      write_debug_header "qBittorrent | startup log hints"
      docker logs --tail 100 qbittorrent 2>&1 | sed -E 's/(temporary password[^:]*:).*/\1 <redacted>/I' >>"$DEBUG_LOG_FILE" || true
      ;;
    tailscale)
      write_debug_header "Tailscale | status --json"
      if docker exec tailscale tailscale status --json >>"$DEBUG_LOG_FILE" 2>&1; then
        successful=1
      fi
      write_debug_header "Tailscale | version"
      docker exec tailscale tailscale version >>"$DEBUG_LOG_FILE" 2>&1 || true
      ;;
  esac
  (( successful ))
}

[[ $EUID -eq 0 ]] || finish_error "Aufruf mit sudo erforderlich"
[[ -d "$INSTALL_DIR" ]] || finish_error "$INSTALL_DIR fehlt"
[[ -f "$INSTALL_DIR/compose.yaml" ]] || finish_error "compose.yaml fehlt"
[[ -f "$INSTALL_DIR/.env" ]] || finish_error ".env fehlt"
command -v docker >/dev/null 2>&1 || finish_error "Docker ist nicht installiert"
docker compose version >/dev/null 2>&1 || finish_error "Docker Compose fehlt"
systemctl is-active --quiet docker || finish_error "Docker ist nicht aktiv"
command -v curl >/dev/null 2>&1 || finish_error "curl fehlt"
command -v jq >/dev/null 2>&1 || finish_error "jq fehlt"

install -m 0600 /dev/null "$LOG_FILE"
install -m 0600 /dev/null "$DEBUG_LOG_FILE"
printf 'start: %s\n' "$(date -Is)" >>"$LOG_FILE"
printf 'DEBUG=%s\n' "$DEBUG" >>"$DEBUG_LOG_FILE"

printf '%bJellyfin Media Stack - Start%b\n' "$BLUE" "$RESET"

cd "$INSTALL_DIR"
run_quiet docker compose config -q
mapfile -t SERVICES < <(docker compose config --services)
((${#SERVICES[@]})) || finish_error "Keine Dienste konfiguriert"
info "Dienste" "${SERVICES[*]}"

run_quiet docker compose pull
run_quiet docker compose up -d --remove-orphans

DEADLINE=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < DEADLINE )); do
  RUNNING="$(docker compose ps --status running --services 2>/dev/null | wc -l)"
  (( RUNNING == ${#SERVICES[@]} )) && break
  sleep 2
done

RUNNING="$(docker compose ps --status running --services 2>/dev/null | wc -l)"
if (( RUNNING == ${#SERVICES[@]} )); then
  ok "Container" "${RUNNING}/${#SERVICES[@]} laufen"
else
  fail "Container" "${RUNNING}/${#SERVICES[@]} laufen"
  write_debug_header "docker compose ps"
  docker compose ps --all >>"$DEBUG_LOG_FILE" 2>&1 || true
fi

if (( DEBUG )); then
  info "Debug" "Schnittstellen werden geprüft"
  write_debug_header "Docker and Compose"
  docker version >>"$DEBUG_LOG_FILE" 2>&1 || true
  docker compose version >>"$DEBUG_LOG_FILE" 2>&1 || true
  docker compose config >>"$DEBUG_LOG_FILE" 2>&1 || true
  docker compose ps --all >>"$DEBUG_LOG_FILE" 2>&1 || true

  for service in "${SERVICES[@]}"; do
    if probe_service "$service"; then
      ok "$service" "Schnittstellen erfasst"
    else
      warn "$service" "keine öffentliche Schnittstelle bestätigt"
    fi
  done

  write_debug_header "Container inspect"
  for service in "${SERVICES[@]}"; do
    docker inspect "$service" >>"$DEBUG_LOG_FILE" 2>&1 || true
  done
fi

if (( RUNNING == ${#SERVICES[@]} )); then
  ok "Start" "abgeschlossen"
else
  warn "Start" "nicht alle Container laufen"
fi
info "Log" "sudo cat $LOG_FILE"
(( DEBUG )) && info "Debug" "sudo cat $DEBUG_LOG_FILE"
