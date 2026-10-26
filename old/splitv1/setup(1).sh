#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-enhanced-setup"
INSTALL_DIR="${INSTALL_DIR:-/opt/$APP_NAME}"
MEDIA_DIR="${MEDIA_DIR:-/srv/media}"
TIMEZONE="${TZ:-Europe/Berlin}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Password123!}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-media-server}"
ENABLE_TAILSCALE="${ENABLE_TAILSCALE:-0}"
ENABLE_FUNNEL="${ENABLE_FUNNEL:-0}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
LOG_FILE="/var/log/${APP_NAME}.log"

C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
log(){ printf '%b[%s] %s%b\n' "$C_BLUE" "$(date '+%F %T')" "$*" "$C_RESET" | tee -a "$LOG_FILE"; }
ok(){ printf '%b[OK] %s%b\n' "$C_GREEN" "$*" "$C_RESET" | tee -a "$LOG_FILE"; }
warn(){ printf '%b[WARNUNG] %s%b\n' "$C_YELLOW" "$*" "$C_RESET" | tee -a "$LOG_FILE" >&2; }
die(){ printf '%b[FEHLER] %s%b\n' "$C_RED" "$*" "$C_RESET" | tee -a "$LOG_FILE" >&2; exit 1; }
trap 'die "Abbruch in Zeile $LINENO. Details: $LOG_FILE"' ERR

[[ $EUID -eq 0 ]] || die "Bitte als root starten: sudo bash setup.sh"
[[ -r /etc/os-release ]] || die "Nicht unterstütztes System: /etc/os-release fehlt."
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "Unterstützt werden Debian und Ubuntu. Erkannt: ${ID:-unbekannt}";; esac
case "${VERSION_CODENAME:-}" in '') die "VERSION_CODENAME konnte nicht bestimmt werden.";; esac
install -m 0644 /dev/null "$LOG_FILE"

export DEBIAN_FRONTEND=noninteractive
log "Aktualisiere das Betriebssystem und installiere Voraussetzungen."
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl jq openssl gnupg

install_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then ok "Docker inklusive Compose ist vorhanden."; return; fi
  log "Installiere Docker Engine und Compose aus dem offiziellen Repository."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}
install_docker

docker info >/dev/null

if [[ "$PUID" == 1000 && "$PGID" == 1000 ]]; then
  first_user="$(getent passwd 1000 | cut -d: -f1 || true)"
  [[ -z "$first_user" ]] || usermod -aG docker "$first_user"
fi

log "Erstelle Verzeichnisstruktur und sichere Berechtigungen."
install -d -m 0750 "$INSTALL_DIR" "$INSTALL_DIR/runtime" "$MEDIA_DIR" "$MEDIA_DIR/series" "$MEDIA_DIR/movies" "$MEDIA_DIR/downloads"
for service in jellyfin seerr sonarr radarr qbittorrent filebrowser; do install -d -m 0750 "$INSTALL_DIR/runtime/$service/config"; done
install -d -m 0750 "$INSTALL_DIR/runtime/filebrowser/database" "$INSTALL_DIR/runtime/tailscale/state"
chown -R "$PUID:$PGID" "$INSTALL_DIR/runtime" "$MEDIA_DIR"

cat > "$INSTALL_DIR/.env" <<EOF
PUID=$PUID
PGID=$PGID
TZ=$TIMEZONE
MEDIA_DIR=$MEDIA_DIR
ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY
TAILSCALE_HOSTNAME=$TAILSCALE_HOSTNAME
EOF
chmod 0600 "$INSTALL_DIR/.env"

cat > "$INSTALL_DIR/compose.yaml" <<'YAML'
name: jellyfin-enhanced
x-common: &common
  restart: unless-stopped
  networks: [media]
  security_opt: [no-new-privileges:true]
services:
  jellyfin:
    <<: *common
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    user: "${PUID}:${PGID}"
    ports: ["8096:8096"]
    environment: {TZ: "${TZ}"}
    volumes:
      - ./runtime/jellyfin/config:/config
      - ${MEDIA_DIR}:/media:ro
  seerr:
    <<: *common
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    ports: ["5055:5055"]
    environment: {LOG_LEVEL: info, TZ: "${TZ}", PORT: "5055"}
    volumes: ["./runtime/seerr/config:/app/config"]
  sonarr:
    <<: *common
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    ports: ["8989:8989"]
    environment: {PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}"}
    volumes: ["./runtime/sonarr/config:/config", "${MEDIA_DIR}:/media"]
  radarr:
    <<: *common
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    ports: ["7878:7878"]
    environment: {PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}"}
    volumes: ["./runtime/radarr/config:/config", "${MEDIA_DIR}:/media"]
  qbittorrent:
    <<: *common
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    ports: ["8080:8080", "6881:6881/tcp", "6881:6881/udp"]
    environment: {PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}", WEBUI_PORT: "8080"}
    volumes: ["./runtime/qbittorrent/config:/config", "${MEDIA_DIR}/downloads:/downloads"]
  filebrowser:
    <<: *common
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    user: "${PUID}:${PGID}"
    ports: ["8091:80"]
    volumes: ["${MEDIA_DIR}:/srv", "./runtime/filebrowser/database:/database", "./runtime/filebrowser/config:/config"]
    command: ["--database", "/database/filebrowser.db", "--root", "/srv", "--address", "0.0.0.0", "--port", "80"]
  tailscale:
    image: tailscale/tailscale:stable
    container_name: tailscale
    profiles: [remote]
    network_mode: host
    hostname: "${TAILSCALE_HOSTNAME}"
    environment: {TS_AUTHKEY: "${TAILSCALE_AUTHKEY}", TS_STATE_DIR: /var/lib/tailscale, TS_AUTH_ONCE: "true"}
    volumes: ["./runtime/tailscale/state:/var/lib/tailscale", "/dev/net/tun:/dev/net/tun"]
    cap_add: [NET_ADMIN, NET_RAW]
    restart: unless-stopped
networks:
  media: {name: jellyfin-enhanced}
YAML

cd "$INSTALL_DIR"
log "Lade Images und starte Dienste."
docker compose pull
if [[ "$ENABLE_TAILSCALE" == 1 ]]; then
  [[ -n "$TAILSCALE_AUTHKEY" ]] || die "ENABLE_TAILSCALE=1, aber TAILSCALE_AUTHKEY ist leer."
  docker compose --profile remote up -d
else
  docker compose up -d
fi

wait_http(){
  local name="$1" url="$2" tries="${3:-90}"
  for ((i=1;i<=tries;i++)); do curl -fsS --max-time 3 "$url" >/dev/null 2>&1 && { ok "$name ist erreichbar."; return 0; }; sleep 2; done
  die "$name wurde nicht rechtzeitig erreichbar: $url"
}
wait_http Jellyfin http://127.0.0.1:8096/health
wait_http Seerr http://127.0.0.1:5055/api/v1/status
wait_http Sonarr http://127.0.0.1:8989/ping
wait_http Radarr http://127.0.0.1:7878/ping
wait_http qBittorrent http://127.0.0.1:8080
wait_http Filebrowser http://127.0.0.1:8091

configure_jellyfin(){
  local pub users token user_id
  pub="$(curl -fsS http://127.0.0.1:8096/System/Info/Public)"
  if [[ "$(jq -r '.StartupWizardCompleted' <<<"$pub")" == true ]]; then warn "Jellyfin ist bereits eingerichtet; bestehende Konfiguration bleibt erhalten."; return; fi
  log "Konfiguriere Jellyfin vollständig."
  curl -fsS -X POST http://127.0.0.1:8096/Startup/Configuration -H 'Content-Type: application/json' -d "{\"UICulture\":\"de-DE\",\"MetadataCountryCode\":\"DE\",\"PreferredMetadataLanguage\":\"de\"}" >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/User -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Name:$n,Password:$p}')" >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/RemoteAccess -H 'Content-Type: application/json' -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/Complete >/dev/null
  token="$(curl -fsS -X POST http://127.0.0.1:8096/Users/AuthenticateByName -H 'Content-Type: application/json' -H 'X-Emby-Authorization: MediaBrowser Client="setup", Device="setup", DeviceId="setup", Version="1.0"' -d "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Username:$u,Pw:$p}')" | jq -r '.AccessToken')"
  [[ -n "$token" && "$token" != null ]] || die "Jellyfin-Anmeldung nach Einrichtung fehlgeschlagen."
  curl -fsS -X POST "http://127.0.0.1:8096/Library/VirtualFolders?name=Serien&collectionType=tvshows&refreshLibrary=true" -H "X-Emby-Token: $token" -H 'Content-Type: application/json' -d '{"LibraryOptions":{"PathInfos":[{"Path":"/media/series"}]}}' >/dev/null
  curl -fsS -X POST "http://127.0.0.1:8096/Library/VirtualFolders?name=Filme&collectionType=movies&refreshLibrary=true" -H "X-Emby-Token: $token" -H 'Content-Type: application/json' -d '{"LibraryOptions":{"PathInfos":[{"Path":"/media/movies"}]}}' >/dev/null
  ok "Jellyfin-Benutzer und Bibliotheken wurden eingerichtet."
}
configure_jellyfin

arr_key(){ grep -oPm1 '(?<=<ApiKey>)[^<]+' "$INSTALL_DIR/runtime/$1/config/config.xml"; }
SONARR_KEY="$(arr_key sonarr)"; RADARR_KEY="$(arr_key radarr)"
[[ -n "$SONARR_KEY" && -n "$RADARR_KEY" ]] || die "Sonarr/Radarr API-Schlüssel konnten nicht gelesen werden."

ensure_root(){
  local port="$1" key="$2" path="$3"
  curl -fsS "http://127.0.0.1:$port/api/v3/rootfolder" -H "X-Api-Key: $key" | jq -e --arg p "$path" '.[]|select(.path==$p)' >/dev/null || \
  curl -fsS -X POST "http://127.0.0.1:$port/api/v3/rootfolder" -H "X-Api-Key: $key" -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$path" '{path:$p}')" >/dev/null
}
ensure_root 8989 "$SONARR_KEY" /media/series
ensure_root 7878 "$RADARR_KEY" /media/movies

configure_qbit(){
  local cookie tmp body
  cookie="$(mktemp)"; trap 'rm -f "$cookie"' RETURN
  if curl -fsS -c "$cookie" --data-urlencode "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASSWORD" http://127.0.0.1:8080/api/v2/auth/login | grep -q Ok; then ok "qBittorrent ist bereits mit dem gewünschten Konto konfiguriert."; return; fi
  tmp="$(docker logs qbittorrent 2>&1 | sed -n 's/.*temporary password is provided for this session: //p' | tail -n1 | tr -d '\r')"
  [[ -n "$tmp" ]] || { warn "Temporäres qBittorrent-Passwort nicht gefunden; WebUI bleibt auf Erststartzustand."; return; }
  curl -fsS -c "$cookie" --data-urlencode 'username=admin' --data-urlencode "password=$tmp" http://127.0.0.1:8080/api/v2/auth/login | grep -q Ok || { warn "qBittorrent-Erstanmeldung fehlgeschlagen."; return; }
  body="$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{web_ui_username:$u,web_ui_password:$p,save_path:"/downloads",temp_path_enabled:false}')"
  curl -fsS -b "$cookie" --data-urlencode "json=$body" http://127.0.0.1:8080/api/v2/app/setPreferences >/dev/null
  ok "qBittorrent-Zugang und Downloadpfad wurden gesetzt."
}
configure_qbit

configure_filebrowser(){
  if [[ -s "$INSTALL_DIR/runtime/filebrowser/database/filebrowser.db" ]]; then warn "Filebrowser-Datenbank existiert; Benutzer wird nicht überschrieben."; return; fi
  docker stop filebrowser >/dev/null
  docker run --rm --user "$PUID:$PGID" -v "$INSTALL_DIR/runtime/filebrowser/database:/database" filebrowser/filebrowser:latest config init -d /database/filebrowser.db >/dev/null
  docker run --rm --user "$PUID:$PGID" -v "$INSTALL_DIR/runtime/filebrowser/database:/database" filebrowser/filebrowser:latest users add "$ADMIN_USER" "$ADMIN_PASSWORD" --perm.admin -d /database/filebrowser.db >/dev/null
  docker start filebrowser >/dev/null
  ok "Filebrowser-Administrator wurde eingerichtet."
}
configure_filebrowser

cat > "$INSTALL_DIR/status.sh" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")" && docker compose ps
EOF
cat > "$INSTALL_DIR/update.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
EOF
cat > "$INSTALL_DIR/reset.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == --yes ]] || { echo "ACHTUNG: Löscht Konfiguration und Datenbank, nicht die Medien. Aufruf: sudo ./reset.sh --yes"; exit 2; }
cd "$(dirname "$0")"
docker compose --profile remote down
rm -rf runtime
EOF
chmod 0750 "$INSTALL_DIR/status.sh" "$INSTALL_DIR/update.sh" "$INSTALL_DIR/reset.sh"

if [[ "$ENABLE_TAILSCALE" == 1 && "$ENABLE_FUNNEL" == 1 ]]; then
  docker exec tailscale tailscale funnel --bg 8096 || warn "Tailscale Funnel für Jellyfin konnte nicht aktiviert werden."
fi

HOST_IP="$(hostname -I | awk '{print $1}')"
printf '\n%bInstallation abgeschlossen.%b\n' "$C_GREEN" "$C_RESET"
printf 'Jellyfin:    http://%s:8096\nSeerr:        http://%s:5055\nSonarr:       http://%s:8989\nRadarr:       http://%s:7878\nqBittorrent:  http://%s:8080\nFilebrowser:  http://%s:8091\n' "$HOST_IP" "$HOST_IP" "$HOST_IP" "$HOST_IP" "$HOST_IP" "$HOST_IP"
printf 'Benutzer: %s\nInstallationspfad: %s\nMedienpfad: %s\n' "$ADMIN_USER" "$INSTALL_DIR" "$MEDIA_DIR"
printf '%bWichtig: Seerr muss abhängig von der eingesetzten Version eventuell einmalig im Browser mit Jellyfin verknüpft werden; das Skript erfindet keine instabile, versionsabhängige interne API.%b\n' "$C_YELLOW" "$C_RESET"
