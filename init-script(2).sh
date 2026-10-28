#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

DEBUG=0
SETUP_MODE="m"
SETUP_URL="https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main/installation/bash/setup.sh"
APP_NAME="jellyfin-media-stack"
INSTALL_DIR="/opt/${APP_NAME}"
MEDIA_DEFAULT="/srv/media"
TIMEZONE="Europe/Berlin"
TAILSCALE_HOSTNAME="jellystack"
MIN_FREE_GB=20
MIN_RAM_GB=2
WAIT_SECONDS=180
LOG_FILE="/var/log/${APP_NAME}-init.log"
DEBUG_LOG_FILE="/var/log/${APP_NAME}-interfaces.log"
REQUIRED_PACKAGES=(ca-certificates curl gnupg jq)

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

info(){ printf '%b[i]%b %s: %s\n' "$BLUE" "$RESET" "$1" "$2"; }
ok(){ printf '%b[✓]%b %s: %s\n' "$GREEN" "$RESET" "$1" "$2"; }
warn(){ printf '%b[!]%b %s: %s\n' "$YELLOW" "$RESET" "$1" "$2"; }
fail(){ printf '%b[✗]%b %s: %s\n' "$RED" "$RESET" "$1" "$2"; }
run_quiet(){ "$@" >>"$LOG_FILE" 2>&1; }

read_tty(){
  local name="$1" value
  [[ -r /dev/tty ]] || { fail "Fehler" "interaktives Terminal erforderlich"; exit 1; }
  IFS= read -r value </dev/tty || value=""
  printf -v "$name" '%s' "$value"
}

ask_yes(){
  local text="$1" default="$2" answer
  while true; do
    printf '[?] %s [%s]: ' "$text" "$default" >/dev/tty
    read_tty answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes|j|ja) return 0 ;;
      n|no|nein) return 1 ;;
      *) warn "Eingabe" "nur y oder n" ;;
    esac
  done
}

ask_value(){
  local text="$1" default="$2" answer
  printf '[?] %s [%s]: ' "$text" "$default" >/dev/tty
  read_tty answer
  printf '%s' "${answer:-$default}"
}

finish(){
  printf 'User beendet.\n'
  info "Log" "sudo cat $LOG_FILE"
  exit "${1:-0}"
}

trap 'rc=$?; fail "Initialisierung" "fehlgeschlagen" >&2; info "Log" "sudo cat $LOG_FILE" >&2; exit "$rc"' ERR

check_system(){
  [[ -r /etc/os-release ]] || { fail "System" "/etc/os-release fehlt"; finish 1; }
  . /etc/os-release
  ARCH="$(dpkg --print-architecture 2>/dev/null || printf unbekannt)"
  CHECK_ERRORS=0

  case "${ID:-}" in debian|ubuntu) ;; *) CHECK_ERRORS=$((CHECK_ERRORS+1)) ;; esac
  case "$ARCH" in amd64|arm64) ;; *) CHECK_ERRORS=$((CHECK_ERRORS+1)) ;; esac

  FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
  FREE_GB="$(awk -v v="$FREE_KB" 'BEGIN{printf "%.1f",v/1048576}')"
  RAM_KB="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
  RAM_GB="$(awk -v v="$RAM_KB" 'BEGIN{printf "%.1f",v/1048576}')"
  INTERNET_CODE="$(curl -Lso /dev/null --connect-timeout 5 --max-time 10 -w '%{http_code}' https://www.debian.org/ 2>/dev/null || true)"

  MISSING_PACKAGES=()
  for package in "${REQUIRED_PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' || MISSING_PACKAGES+=("$package")
  done

  run_quiet apt-get update -qq
  mapfile -t AVAILABLE_UPDATES < <(apt list --upgradable 2>/dev/null | tail -n +2)

  info "System" "${PRETTY_NAME:-${ID:-unbekannt}} $ARCH"
  if (( FREE_KB >= MIN_FREE_GB*1048576 )); then ok "Speicher" "${FREE_GB}GB/${MIN_FREE_GB}GB"; else fail "Speicher" "${FREE_GB}GB/${MIN_FREE_GB}GB"; CHECK_ERRORS=$((CHECK_ERRORS+1)); fi
  if (( RAM_KB >= MIN_RAM_GB*1048576 )); then ok "RAM" "${RAM_GB}GB/${MIN_RAM_GB}GB"; else fail "RAM" "${RAM_GB}GB/${MIN_RAM_GB}GB"; CHECK_ERRORS=$((CHECK_ERRORS+1)); fi
  if [[ "$INTERNET_CODE" =~ ^(200|301|302)$ ]]; then ok "Netzwerk" "verfügbar"; else fail "Netzwerk" "nicht verfügbar"; CHECK_ERRORS=$((CHECK_ERRORS+1)); fi

  if ((${#MISSING_PACKAGES[@]})); then
    warn "Pakete" "${MISSING_PACKAGES[*]} fehlen"
    if ask_yes "Pakete installieren" y; then
      run_quiet apt-get install -y "${MISSING_PACKAGES[@]}"
      ok "Pakete" "installiert"
    else
      CHECK_ERRORS=$((CHECK_ERRORS+1))
    fi
  else
    ok "Pakete" "vollständig"
  fi

  if ((${#AVAILABLE_UPDATES[@]})); then
    warn "Updates" "${#AVAILABLE_UPDATES[@]} verfügbar"
    if ask_yes "Updates installieren" y; then
      run_quiet apt-get full-upgrade -y
      ok "Updates" "installiert"
    fi
  else
    ok "Updates" "aktuell"
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker" "verfügbar"
  else
    fail "Docker" "fehlt"
    CHECK_ERRORS=$((CHECK_ERRORS+1))
  fi

  if (( CHECK_ERRORS > 0 )); then
    ask_yes "Fehler ignorieren" n || finish 1
  fi

  command -v docker >/dev/null 2>&1 || { fail "Docker" "für den Stack erforderlich"; finish 1; }
  docker compose version >/dev/null 2>&1 || { fail "Compose" "für den Stack erforderlich"; finish 1; }
  run_quiet systemctl enable --now docker
}

find_media(){
  MEDIA_DIR=""
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    MEDIA_DIR="$(sed -nE 's/^(MEDIA|MEDIA_DIR)=(.*)$/\2/p' "$INSTALL_DIR/.env" | tail -n1)"
  fi

  if [[ -z "$MEDIA_DIR" ]]; then
    for container in jellyfin sonarr radarr qbittorrent; do
      docker inspect "$container" >/dev/null 2>&1 || continue
      MEDIA_DIR="$(docker inspect "$container" --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' 2>/dev/null | awk -F' \| ' '$2~/^\/(media|movies|tv|downloads)/{print $1}' | sed -E 's#/(movies|series|downloads)$##' | head -n1)"
      [[ -n "$MEDIA_DIR" ]] && break
    done
  fi

  if [[ -n "$MEDIA_DIR" ]]; then
    info "Medien" "$MEDIA_DIR erkannt"
  else
    MEDIA_DIR="$(ask_value "Medienverzeichnis" "$MEDIA_DEFAULT")"
  fi

  MEDIA_DIR="${MEDIA_DIR%/}"
  [[ "$MEDIA_DIR" == /* && "$MEDIA_DIR" != / && "$MEDIA_DIR" != "$INSTALL_DIR" ]] || { fail "Medien" "Pfad ungültig"; finish 1; }
}

choose_services(){
  ENABLE_JELLYFIN=1
  ask_yes "Seerr" y && ENABLE_SEERR=1 || ENABLE_SEERR=0
  ask_yes "Sonarr" y && ENABLE_SONARR=1 || ENABLE_SONARR=0
  ask_yes "Radarr" y && ENABLE_RADARR=1 || ENABLE_RADARR=0
  ask_yes "Prowlarr" y && ENABLE_PROWLARR=1 || ENABLE_PROWLARR=0
  ask_yes "qBittorrent" y && ENABLE_QBITTORRENT=1 || ENABLE_QBITTORRENT=0
  ask_yes "Tailscale" n && ENABLE_TAILSCALE=1 || ENABLE_TAILSCALE=0

  TAILSCALE_AUTHKEY=""
  if (( ENABLE_TAILSCALE )); then
    info "Tailscale" "Key: https://console.tailscale.com/admin/settings/keys"
    printf '[?] Tailscale Auth-Key: ' >/dev/tty
    IFS= read -r -s TAILSCALE_AUTHKEY </dev/tty || TAILSCALE_AUTHKEY=""
    printf '\n' >/dev/tty
    [[ "$TAILSCALE_AUTHKEY" == tskey-* ]] || warn "Tailscale" "Key-Format nicht erkannt"
  fi
}

cleanup_project(){
  if [[ -f "$INSTALL_DIR/compose.yaml" ]]; then
    (cd "$INSTALL_DIR" && run_quiet docker compose --profile tailscale down --remove-orphans --volumes) || true
  fi

  mapfile -t PROJECT_IDS < <(docker ps -aq --filter "label=com.docker.compose.project=$APP_NAME" 2>/dev/null || true)
  if ((${#PROJECT_IDS[@]})); then run_quiet docker rm -f -v "${PROJECT_IDS[@]}" || true; fi

  mapfile -t PROJECT_NETWORKS < <(docker network ls -q --filter "label=com.docker.compose.project=$APP_NAME" 2>/dev/null || true)
  if ((${#PROJECT_NETWORKS[@]})); then run_quiet docker network rm "${PROJECT_NETWORKS[@]}" || true; fi

  mapfile -t PROJECT_VOLUMES < <(docker volume ls -q --filter "label=com.docker.compose.project=$APP_NAME" 2>/dev/null || true)
  if ((${#PROJECT_VOLUMES[@]})); then run_quiet docker volume rm -f "${PROJECT_VOLUMES[@]}" || true; fi

  rm -rf --one-file-system "$INSTALL_DIR"
  install -d -m 0755 "$INSTALL_DIR"
  ok "Cleanup" "abgeschlossen"
}

write_configuration(){
  TARGET_USER="${SUDO_USER:-root}"
  if [[ "$TARGET_USER" != root ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    PUID="$(id -u "$TARGET_USER")"
    PGID="$(id -g "$TARGET_USER")"
  else
    PUID=1000
    PGID=1000
  fi

  cat >"$INSTALL_DIR/.env" <<ENV
TZ=$TIMEZONE
PUID=$PUID
PGID=$PGID
DATA=$INSTALL_DIR/data
MEDIA=$MEDIA_DIR
TS_HOST=$TAILSCALE_HOSTNAME
TS_KEY=$TAILSCALE_AUTHKEY
COMPOSE_PROFILES=$([[ $ENABLE_TAILSCALE -eq 1 ]] && printf tailscale)
ENV
  chmod 600 "$INSTALL_DIR/.env"

  {
    cat <<'YAML'
name: jellyfin-media-stack
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    environment: { TZ: "${TZ}" }
    ports: ["8096:8096"]
    volumes: ["${DATA}/jellyfin/config:/config", "${DATA}/jellyfin/cache:/cache", "${MEDIA}/movies:/media/movies:ro", "${MEDIA}/series:/media/series:ro"]
    restart: unless-stopped
YAML
    (( ENABLE_SEERR )) && cat <<'YAML'
  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    environment: { TZ: "${TZ}" }
    ports: ["5055:5055"]
    volumes: ["${DATA}/seerr/config:/app/config"]
    restart: unless-stopped
YAML
    (( ENABLE_SONARR )) && cat <<'YAML'
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["8989:8989"]
    volumes: ["${DATA}/sonarr/config:/config", "${MEDIA}/series:/tv", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
YAML
    (( ENABLE_RADARR )) && cat <<'YAML'
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["7878:7878"]
    volumes: ["${DATA}/radarr/config:/config", "${MEDIA}/movies:/movies", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
YAML
    (( ENABLE_PROWLARR )) && cat <<'YAML'
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["9696:9696"]
    volumes: ["${DATA}/prowlarr/config:/config"]
    restart: unless-stopped
YAML
    (( ENABLE_QBITTORRENT )) && cat <<'YAML'
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}", WEBUI_PORT: "8080", TORRENTING_PORT: "6881" }
    ports: ["8080:8080", "6881:6881/tcp", "6881:6881/udp"]
    volumes: ["${DATA}/qbittorrent/config:/config", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
YAML
    (( ENABLE_TAILSCALE )) && cat <<'YAML'
  tailscale:
    profiles: [tailscale]
    image: tailscale/tailscale:stable
    container_name: tailscale
    hostname: ${TS_HOST}
    environment: { TS_AUTHKEY: "${TS_KEY}", TS_AUTH_ONCE: "true", TS_HOSTNAME: "${TS_HOST}", TS_STATE_DIR: /var/lib/tailscale, TS_USERSPACE: "false" }
    volumes: ["${DATA}/tailscale/state:/var/lib/tailscale", "/dev/net/tun:/dev/net/tun"]
    network_mode: host
    cap_add: [NET_ADMIN, NET_RAW]
    restart: unless-stopped
YAML
  } >"$INSTALL_DIR/compose.yaml"

  (cd "$INSTALL_DIR" && docker compose config -q) >>"$LOG_FILE" 2>&1
  ok "Konfiguration" "erstellt"
}

start_stack(){
  cd "$INSTALL_DIR"
  set -a
  . ./.env
  set +a
  mapfile -t SERVICES < <(docker compose config --services)
  SERVICE_LIST="$(printf '%s ' "${SERVICES[@]}")"
  info "Dienste" "${SERVICE_LIST% }"

  install -d -m 0755 "$DATA"
  install -d -m 0775 "$MEDIA"/movies "$MEDIA"/series "$MEDIA"/downloads
  for service in "${SERVICES[@]}"; do
    case "$service" in
      jellyfin) install -d -m 0775 "$DATA/jellyfin/config" "$DATA/jellyfin/cache" ;;
      seerr|sonarr|radarr|prowlarr|qbittorrent) install -d -m 0775 "$DATA/$service/config" ;;
      tailscale) install -d -m 0775 "$DATA/tailscale/state" ;;
    esac
  done
  chown -R "$PUID:$PGID" "$DATA"
  chown "$PUID:$PGID" "$MEDIA" "$MEDIA/movies" "$MEDIA/series" "$MEDIA/downloads" 2>/dev/null || true

  run_quiet docker compose pull
  run_quiet docker compose up -d --remove-orphans

  DEADLINE=$((SECONDS+WAIT_SECONDS))
  RUNNING=0
  while (( SECONDS < DEADLINE )); do
    RUNNING="$(docker compose ps --status running --services | wc -l)"
    (( RUNNING == ${#SERVICES[@]} )) && break
    sleep 2
  done

  if (( RUNNING == ${#SERVICES[@]} )); then ok "Container" "$RUNNING/${#SERVICES[@]}"; else fail "Container" "$RUNNING/${#SERVICES[@]}"; fi
  return 0
}

create_manual(){
  local ip services total=0 step=0
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="SERVER-IP"
  services="$(cd "$INSTALL_DIR" && docker compose config --services)"
  has(){ grep -qx "$1" <<<"$services"; }
  for service in jellyfin qbittorrent sonarr radarr prowlarr seerr tailscale; do if has "$service"; then total=$((total+1)); fi; done

  {
    printf 'JELLYFIN MEDIA STACK - MANUELLE EINRICHTUNG\n'
    printf '============================================\n'
    printf 'Schritte: %s\n\n' "$total"
    if has jellyfin; then step=$((step+1)); printf '%s. Jellyfin einrichten\n   URL: http://%s:8096\n   1. Administratorkonto anlegen.\n   2. Bibliothek Filme mit /media/movies anlegen.\n   3. Bibliothek Serien mit /media/series anlegen.\n   4. Sprache und Metadatenregion auf Deutsch/Deutschland setzen.\n   5. Automatische Portfreigabe deaktiviert lassen.\n\n' "$step" "$ip"; fi
    if has qbittorrent; then step=$((step+1)); printf '%s. qBittorrent einrichten\n   URL: http://%s:8080\n   Benutzer: admin\n   Temporäres Kennwort:\n   sudo docker logs qbittorrent 2>&1 | sed -nE '\''s/.*temporary password[^:]*:[[:space:]]*//Ip'\'' | tail -n1\n   1. Dauerhaftes Web-UI-Kennwort setzen.\n   2. Downloadpfad auf /downloads setzen.\n\n' "$step" "$ip"; fi
    if has sonarr; then step=$((step+1)); printf '%s. Sonarr einrichten\n   URL: http://%s:8989\n   1. Root Folder /tv anlegen.\n' "$step" "$ip"; has qbittorrent && printf '   2. qBittorrent eintragen: Host=qbittorrent, Port=8080, Kategorie=sonarr.\n'; printf '   3. API-Key unter Settings > General notieren.\n\n'; fi
    if has radarr; then step=$((step+1)); printf '%s. Radarr einrichten\n   URL: http://%s:7878\n   1. Root Folder /movies anlegen.\n' "$step" "$ip"; has qbittorrent && printf '   2. qBittorrent eintragen: Host=qbittorrent, Port=8080, Kategorie=radarr.\n'; printf '   3. API-Key unter Settings > General notieren.\n\n'; fi
    if has prowlarr; then step=$((step+1)); printf '%s. Prowlarr einrichten\n   URL: http://%s:9696\n   1. Gewünschte Indexer hinzufügen.\n' "$step" "$ip"; has sonarr && printf '   2. Sonarr eintragen: URL=http://sonarr:8989, API-Key aus Sonarr.\n'; has radarr && printf '   3. Radarr eintragen: URL=http://radarr:7878, API-Key aus Radarr.\n'; printf '\n'; fi
    if has seerr; then step=$((step+1)); printf '%s. Seerr einrichten\n   URL: http://%s:5055\n   1. Jellyfin verbinden: URL=http://jellyfin:8096.\n' "$step" "$ip"; has sonarr && printf '   2. Sonarr verbinden: Host=sonarr, Port=8989, Root=/tv, API-Key aus Sonarr.\n'; has radarr && printf '   3. Radarr verbinden: Host=radarr, Port=7878, Root=/movies, API-Key aus Radarr.\n'; printf '   4. Bibliotheken synchronisieren.\n   5. Rechte und Genehmigungen prüfen.\n\n'; fi
    if has tailscale; then step=$((step+1)); printf '%s. Tailscale prüfen\n   1. Status: sudo docker exec tailscale tailscale status\n   2. IP: sudo docker exec tailscale tailscale ip -4\n   3. Geräte: https://console.tailscale.com/admin/machines\n   4. Keys: https://console.tailscale.com/admin/settings/keys\n\n' "$step"; fi
    printf 'Abschlussprüfung\n   cd %s && sudo docker compose ps\n   cd %s && sudo docker compose logs --tail=100\n' "$INSTALL_DIR" "$INSTALL_DIR"
  } >"$INSTALL_DIR/MANUAL.txt"
  chmod 0644 "$INSTALL_DIR/MANUAL.txt"
  return 0
}

final_output(){
  create_manual
  ok "Stack" "gestartet"
  info "Manual" "$INSTALL_DIR/MANUAL.txt"
  info "Automatisch" "curl -fsSL $SETUP_URL | sudo bash"
  info "Log" "sudo cat $LOG_FILE"
  if (( DEBUG )); then info "Debug" "sudo cat $DEBUG_LOG_FILE"; fi

  case "$SETUP_MODE" in
    m) printf '\n'; cat "$INSTALL_DIR/MANUAL.txt" ;;
    a) curl -fsSL "$SETUP_URL" | bash ;;
    w) while true; do printf '[?] Manuell oder automatisch [m/a]: ' >/dev/tty; read_tty answer; case "${answer,,}" in m|manuell) printf '\n'; cat "$INSTALL_DIR/MANUAL.txt"; break;; a|automatisch) curl -fsSL "$SETUP_URL" | bash; break;; *) warn "Eingabe" "nur m oder a";; esac; done ;;
    *) fail "Modus" "SETUP_MODE muss w, m oder a sein"; return 1 ;;
  esac
  return 0
}

[[ $EUID -eq 0 ]] || { fail "Fehler" "Aufruf mit sudo erforderlich"; exit 1; }
[[ -r /dev/tty ]] || { fail "Fehler" "interaktives Terminal erforderlich"; exit 1; }
install -m 0600 /dev/null "$LOG_FILE"
printf '%bJellyfin Media Stack%b\n' "$BLUE" "$RESET"
check_system
find_media
choose_services
cleanup_project
write_configuration
start_stack
final_output
