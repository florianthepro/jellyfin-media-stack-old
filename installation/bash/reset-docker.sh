#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
INSTALL_DIR="/opt/${APP_NAME}"
MEDIA_DEFAULT="/srv/media"
LOG_FILE="/var/log/${APP_NAME}-setup_files.log"
TIMEZONE="Europe/Berlin"

BLUE='\033[1;34m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'
info(){ printf '%b[i]%b %s: %s\n' "$BLUE" "$RESET" "$1" "$2"; }
ok(){ printf '%b[✓]%b %s: %s\n' "$GREEN" "$RESET" "$1" "$2"; }
warn(){ printf '%b[!]%b %s: %s\n' "$YELLOW" "$RESET" "$1" "$2"; }
fail(){ printf '%b[✗]%b %s: %s\n' "$RED" "$RESET" "$1" "$2"; }
run_quiet(){ "$@" >>"$LOG_FILE" 2>&1; }
read_tty(){ local n="$1" v; IFS= read -r v </dev/tty || v=""; printf -v "$n" '%s' "$v"; }
ask(){ local text="$1" default="$2" answer; printf '[?] %s [%s]: ' "$text" "$default"; read_tty answer; printf '%s' "${answer:-$default}"; }
ask_yes(){ local text="$1" default="$2" answer; printf '[?] %s [%s]: ' "$text" "$default"; read_tty answer; answer="${answer:-$default}"; case "${answer,,}" in y|yes|j|ja) return 0;; *) return 1;; esac; }
finish(){ printf 'User beendet.\n'; info "Log" "$LOG_FILE"; exit "${1:-0}"; }
trap 'rc=$?; fail "Setup" "fehlgeschlagen" >&2; info "Log" "$LOG_FILE" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || { fail "Fehler" "Aufruf mit sudo erforderlich"; exit 1; }
[[ -r /dev/tty ]] || { fail "Fehler" "Interaktives Terminal erforderlich"; exit 1; }
install -m 0600 /dev/null "$LOG_FILE"

printf '%bJellyfin Media Stack - Dateien vorbereiten%b\n' "$BLUE" "$RESET"

MEDIA_FOUND=""
if [[ -f "$INSTALL_DIR/.env" ]]; then
  MEDIA_FOUND="$(sed -nE 's/^(MEDIA|MEDIA_DIR)=(.*)$/\2/p' "$INSTALL_DIR/.env" | tail -n1)"
fi

if [[ -z "$MEDIA_FOUND" ]] && command -v docker >/dev/null 2>&1; then
  for container in jellyfin sonarr radarr qbittorrent; do
    docker container inspect "$container" >/dev/null 2>&1 || continue
    MEDIA_FOUND="$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source "|" .Destination}}{{end}}{{end}}' 2>/dev/null \
      | awk -F' \| ' '$2 ~ /^\/(media|movies|tv|downloads)/ {print $1}' \
      | sed -E 's#/(movies|series|downloads)$##' | head -n1)"
    [[ -n "$MEDIA_FOUND" ]] && break
  done
fi

if [[ -n "$MEDIA_FOUND" ]]; then
  MEDIA_DIR="$MEDIA_FOUND"
  info "Medien" "$MEDIA_DIR erkannt"
else
  MEDIA_DIR="$(ask "Medienverzeichnis" "$MEDIA_DEFAULT")"
fi

MEDIA_DIR="${MEDIA_DIR%/}"
[[ "$MEDIA_DIR" == /* && "$MEDIA_DIR" != / ]] || { fail "Medien" "absoluter Pfad außer / erforderlich"; finish 1; }
[[ "$INSTALL_DIR" != "$MEDIA_DIR" ]] || { fail "Medien" "darf nicht dem Installationspfad entsprechen"; finish 1; }

ENABLE_JELLYFIN=1
ask_yes "Seerr anlegen" y && ENABLE_SEERR=1 || ENABLE_SEERR=0
ask_yes "Sonarr anlegen" y && ENABLE_SONARR=1 || ENABLE_SONARR=0
ask_yes "Radarr anlegen" y && ENABLE_RADARR=1 || ENABLE_RADARR=0
ask_yes "Prowlarr anlegen" y && ENABLE_PROWLARR=1 || ENABLE_PROWLARR=0
ask_yes "qBittorrent anlegen" y && ENABLE_QBITTORRENT=1 || ENABLE_QBITTORRENT=0
ask_yes "Tailscale anlegen" n && ENABLE_TAILSCALE=1 || ENABLE_TAILSCALE=0

TAILSCALE_HOSTNAME="media-server"
TAILSCALE_AUTHKEY=""
if (( ENABLE_TAILSCALE )); then
  TAILSCALE_HOSTNAME="$(ask "Tailscale-Hostname" media-server)"
  info "Tailscale" "Auth-Key in der Tailscale-Admin-Konsole unter Settings > Keys erstellen"
  printf '[?] Tailscale Auth-Key: '
  read_tty TAILSCALE_AUTHKEY
  [[ "$TAILSCALE_AUTHKEY" == tskey-* ]] || warn "Tailscale" "Key-Format nicht erkannt"
fi

TARGET_USER="${SUDO_USER:-root}"
if [[ "$TARGET_USER" != root ]] && id "$TARGET_USER" >/dev/null 2>&1; then
  PUID="$(id -u "$TARGET_USER")"; PGID="$(id -g "$TARGET_USER")"
else
  PUID=1000; PGID=1000
fi

warn "Cleanup" "vorhandene Projektkonfiguration wird ersetzt"
printf '[?] Fortfahren [n]: '
read_tty ANSWER
case "${ANSWER,,}" in y|yes|j|ja) ;; *) finish 0;; esac

if command -v docker >/dev/null 2>&1; then
  if [[ -f "$INSTALL_DIR/compose.yaml" ]]; then
    (cd "$INSTALL_DIR" && run_quiet docker compose --profile tailscale down --remove-orphans --volumes) || true
  fi
  mapfile -t IDS < <(docker ps -aq --filter "label=com.docker.compose.project=${APP_NAME}" 2>/dev/null || true)
  for name in jellyfin seerr sonarr radarr prowlarr qbittorrent tailscale; do
    id="$(docker ps -aq --filter "name=^/${name}$" 2>/dev/null || true)"; [[ -n "$id" ]] && IDS+=("$id")
  done
  mapfile -t IDS < <(printf '%s\n' "${IDS[@]:-}" | sed '/^$/d' | sort -u)
  ((${#IDS[@]})) && run_quiet docker rm -f -v "${IDS[@]}" || true
  mapfile -t NETS < <(docker network ls -q --filter "label=com.docker.compose.project=${APP_NAME}" 2>/dev/null || true)
  ((${#NETS[@]})) && run_quiet docker network rm "${NETS[@]}" || true
  mapfile -t VOLS < <(docker volume ls -q --filter "label=com.docker.compose.project=${APP_NAME}" 2>/dev/null || true)
  ((${#VOLS[@]})) && run_quiet docker volume rm -f "${VOLS[@]}" || true
  info "Cleanup" "Projektressourcen entfernt"
else
  info "Docker" "nicht vorhanden, übersprungen"
fi

rm -rf --one-file-system "$INSTALL_DIR"
install -d -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/data"
install -d -m 0775 "$MEDIA_DIR" "$MEDIA_DIR/movies" "$MEDIA_DIR/series" "$MEDIA_DIR/downloads"
install -d -m 0775 "$INSTALL_DIR/data/jellyfin/config" "$INSTALL_DIR/data/jellyfin/cache"
(( ENABLE_SEERR )) && install -d -m 0775 "$INSTALL_DIR/data/seerr/config"
(( ENABLE_SONARR )) && install -d -m 0775 "$INSTALL_DIR/data/sonarr/config"
(( ENABLE_RADARR )) && install -d -m 0775 "$INSTALL_DIR/data/radarr/config"
(( ENABLE_PROWLARR )) && install -d -m 0775 "$INSTALL_DIR/data/prowlarr/config"
(( ENABLE_QBITTORRENT )) && install -d -m 0775 "$INSTALL_DIR/data/qbittorrent/config"
(( ENABLE_TAILSCALE )) && install -d -m 0775 "$INSTALL_DIR/data/tailscale/state"
chown -R "$PUID:$PGID" "$INSTALL_DIR/data"
chown "$PUID:$PGID" "$MEDIA_DIR" "$MEDIA_DIR/movies" "$MEDIA_DIR/series" "$MEDIA_DIR/downloads" 2>/dev/null || true

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

cat >"$INSTALL_DIR/status.sh" <<'SH'
#!/usr/bin/env bash
cd "$(dirname "$(readlink -f "$0")")" && docker compose ps
SH
cat >"$INSTALL_DIR/start.sh" <<'SH'
#!/usr/bin/env bash
set -e
cd "$(dirname "$(readlink -f "$0")")"
docker compose pull
docker compose up -d --remove-orphans
SH
chmod 755 "$INSTALL_DIR/status.sh" "$INSTALL_DIR/start.sh"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  (cd "$INSTALL_DIR" && docker compose config -q) >>"$LOG_FILE" 2>&1 || { fail "Compose" "Konfiguration ungültig"; finish 1; }
  ok "Compose" "vorbereitet"
else
  warn "Docker" "nicht installiert; Dateien wurden trotzdem angelegt"
fi
ok "Verzeichnisse" "angelegt"
info "Start" "sudo bash $INSTALL_DIR/start.sh"
info "Log" "$LOG_FILE"
