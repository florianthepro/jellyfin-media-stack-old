#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
TIMEZONE="Europe/Berlin"
REPO_URL="https://github.com/florianthepro/jellyfin-media-stack"
INSTALL_DIR="/opt/${APP_NAME}"
DATA_DIR="/var/lib/${APP_NAME}"
DEFAULT_MEDIA_DIR="/srv/media"
LOG_FILE="/var/log/${APP_NAME}-setup-v2.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
log(){ printf '%b[%s] %s%b\n' "$BLUE" "$(date '+%F %T')" "$*" "$RESET" | tee -a "$LOG_FILE"; }
ok(){ printf '%b[OK] %s%b\n' "$GREEN" "$*" "$RESET" | tee -a "$LOG_FILE"; }
warn(){ printf '%b[WARNUNG] %s%b\n' "$YELLOW" "$*" "$RESET" | tee -a "$LOG_FILE" >&2; }
die(){ printf '%b[FEHLER] %s%b\n' "$RED" "$*" "$RESET" | tee -a "$LOG_FILE" >&2; exit 1; }
trap 'rc=$?; printf "%b[FEHLER] Abbruch in Zeile %s, Status %s. Log: %s%b\n" "$RED" "$LINENO" "$rc" "$LOG_FILE" "$RESET" >&2; exit "$rc"' ERR

ask(){ local prompt="$1" default="$2" value; read -r -p "$prompt [$default]: " value; printf '%s' "${value:-$default}"; }
ask_yes_no(){ local prompt="$1" default="$2" value; while true; do read -r -p "$prompt [$default]: " value; value="${value:-$default}"; case "${value,,}" in j|ja|y|yes) return 0;; n|nein|no) return 1;; *) echo "Bitte ja oder nein eingeben." >&2;; esac; done; }
ask_secret(){ local prompt="$1" a b; while true; do read -r -s -p "$prompt: " a; echo >&2; [[ ${#a} -ge 12 ]] || { echo "Mindestens 12 Zeichen erforderlich." >&2; continue; }; read -r -s -p "Kennwort wiederholen: " b; echo >&2; [[ "$a" == "$b" ]] || { echo "Die Eingaben stimmen nicht überein." >&2; continue; }; printf '%s' "$a"; return; done; }
valid_name(){ [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
port_free(){ ! ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }
next_free_port(){ local p="$1"; while ! port_free "$p"; do ((p++)); [[ $p -le 65535 ]] || die "Kein freier Port gefunden."; done; printf '%s' "$p"; }
fs_type(){ findmnt -n -o FSTYPE -T "$1" 2>/dev/null || true; }

[[ $EUID -eq 0 ]] || die "Als root starten: sudo ./setup-v2.sh"
install -m 0600 /dev/null "$LOG_FILE"
[[ -r /etc/os-release ]] || die "/etc/os-release fehlt."
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "Unterstützt werden Debian und Ubuntu. Erkannt: ${ID:-unbekannt}";; esac

CALLING_USER="${SUDO_USER:-root}"
if [[ "$CALLING_USER" != root ]] && id "$CALLING_USER" >/dev/null 2>&1; then
  PUID="$(id -u "$CALLING_USER")"; PGID="$(id -g "$CALLING_USER")"
else
  PUID=1000; PGID=1000
  warn "Kein aufrufender Benutzer erkannt; PUID/PGID werden auf 1000 gesetzt."
fi

export DEBIAN_FRONTEND=noninteractive
log "Installiere und prüfe Grundvoraussetzungen."
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq openssl rsync util-linux iproute2

install_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker
    ok "Docker Engine und Compose sind vorhanden."
    return
  fi
  log "Installiere Docker Engine und Compose."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}
install_docker

printf '\nKonfiguration und Datenbanken bleiben bewusst lokal.\nDas Medienverzeichnis darf auf Internxt/rclone liegen.\n\n'
MEDIA_DIR="$(ask 'Medienverzeichnis' "$DEFAULT_MEDIA_DIR")"
ADMIN_USER="$(ask 'Administratorname für File Browser' 'admin')"
valid_name "$ADMIN_USER" || die "Ungültiger Administratorname. Erlaubt: Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich."
ADMIN_PASSWORD="$(ask_secret 'Sicheres File-Browser-Kennwort')"

TAILSCALE_ENABLED=0; TAILSCALE_AUTHKEY=""; TAILSCALE_HOSTNAME="media-server"
if ask_yes_no 'Tailscale-Container aktivieren?' 'nein'; then
  TAILSCALE_ENABLED=1
  TAILSCALE_HOSTNAME="$(ask 'Tailscale-Hostname' 'media-server')"
  valid_name "$TAILSCALE_HOSTNAME" || die "Ungültiger Tailscale-Hostname."
  read -r -s -p 'Tailscale Auth Key: ' TAILSCALE_AUTHKEY; echo
  [[ "$TAILSCALE_AUTHKEY" == tskey-* ]] || die "Der Tailscale Auth Key hat kein erwartetes tskey-Format."
fi

install -d -m 0755 "$INSTALL_DIR" "$DATA_DIR" "$MEDIA_DIR"
MEDIA_FS="$(fs_type "$MEDIA_DIR")"
if [[ "$MEDIA_FS" == fuse.* || "$MEDIA_FS" == fuse ]]; then
  findmnt -n -o OPTIONS -T "$MEDIA_DIR" | grep -qw allow_other || die "Der FUSE-Mount für $MEDIA_DIR hat kein allow_other. Docker kann nicht sicher darauf zugreifen."
  sudo -u "$CALLING_USER" test -w "$MEDIA_DIR" || die "$CALLING_USER kann nicht in $MEDIA_DIR schreiben."
  ok "FUSE-Medienpfad erkannt: $MEDIA_FS mit allow_other."
fi

for p in "$INSTALL_DIR" "$DATA_DIR"; do
  t="$(fs_type "$p")"
  [[ "$t" != fuse.* && "$t" != fuse ]] || die "$p liegt auf FUSE. Konfiguration und SQLite-Datenbanken müssen lokal liegen."
done

JELLYFIN_PORT="$(next_free_port 8096)"
SEERR_PORT="$(next_free_port 5055)"
SONARR_PORT="$(next_free_port 8989)"
RADARR_PORT="$(next_free_port 7878)"
QBIT_PORT="$(next_free_port 8080)"
FILEBROWSER_PORT="$(next_free_port 8091)"
[[ "$FILEBROWSER_PORT" == 8091 ]] || warn "Port 8091 ist belegt; File Browser verwendet Port $FILEBROWSER_PORT."

OLD_INSTALL="/mnt/internxt/jellyfin-media-stack/opt"
if [[ -f "$OLD_INSTALL/compose.yaml" && "$OLD_INSTALL" != "$INSTALL_DIR" ]]; then
  warn "Alte Installation auf Internxt erkannt."
  if ask_yes_no 'Container stoppen und vorhandene Konfigurationen lokal migrieren?' 'ja'; then
    (cd "$OLD_INSTALL" && docker compose --profile tailscale down --remove-orphans) || true
    if [[ -d "$OLD_INSTALL/data" ]]; then
      log "Migriere vorhandene Konfigurationen nach $DATA_DIR."
      rsync -a --info=progress2 "$OLD_INSTALL/data/" "$DATA_DIR/"
    fi
  fi
fi

install -d -m 0775 "$MEDIA_DIR"/{movies,series,downloads}
install -d -m 0775 "$DATA_DIR"/{jellyfin/config,jellyfin/cache,seerr/config,sonarr/config,radarr/config,qbittorrent/config,filebrowser/database,filebrowser/config,tailscale/state}
chown -R "$PUID:$PGID" "$DATA_DIR" "$MEDIA_DIR"

cat > "$INSTALL_DIR/compose.yaml" <<'YAML'
name: jellyfin-media-stack
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    environment: { TZ: "${TZ}" }
    ports: ["${JELLYFIN_PORT}:8096"]
    volumes:
      - "${DATA_DIR}/jellyfin/config:/config"
      - "${DATA_DIR}/jellyfin/cache:/cache"
      - "${MEDIA_DIR}/movies:/media/movies:ro"
      - "${MEDIA_DIR}/series:/media/series:ro"
    restart: unless-stopped
  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    init: true
    environment: { TZ: "${TZ}", LOG_LEVEL: info }
    ports: ["${SEERR_PORT}:5055"]
    volumes: ["${DATA_DIR}/seerr/config:/app/config"]
    restart: unless-stopped
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["${SONARR_PORT}:8989"]
    volumes:
      - "${DATA_DIR}/sonarr/config:/config"
      - "${MEDIA_DIR}/series:/tv"
      - "${MEDIA_DIR}/downloads:/downloads"
    restart: unless-stopped
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["${RADARR_PORT}:7878"]
    volumes:
      - "${DATA_DIR}/radarr/config:/config"
      - "${MEDIA_DIR}/movies:/movies"
      - "${MEDIA_DIR}/downloads:/downloads"
    restart: unless-stopped
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}", WEBUI_PORT: "8080", TORRENTING_PORT: "6881" }
    ports: ["${QBIT_PORT}:8080", "6881:6881/tcp", "6881:6881/udp"]
    volumes:
      - "${DATA_DIR}/qbittorrent/config:/config"
      - "${MEDIA_DIR}/downloads:/downloads"
    restart: unless-stopped
  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    user: "${PUID}:${PGID}"
    ports: ["${FILEBROWSER_PORT}:80"]
    volumes:
      - "${MEDIA_DIR}:/srv"
      - "${DATA_DIR}/filebrowser/database:/database"
      - "${DATA_DIR}/filebrowser/config:/config"
    restart: unless-stopped
  tailscale:
    profiles: [tailscale]
    image: tailscale/tailscale:latest
    container_name: tailscale
    hostname: "${TAILSCALE_HOSTNAME}"
    environment:
      TS_AUTHKEY: "${TAILSCALE_AUTHKEY}"
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "false"
    volumes:
      - "${DATA_DIR}/tailscale/state:/var/lib/tailscale"
      - /dev/net/tun:/dev/net/tun
    network_mode: host
    cap_add: [NET_ADMIN, NET_RAW]
    restart: unless-stopped
YAML

umask 077
cat > "$INSTALL_DIR/.env" <<ENV
TZ=$TIMEZONE
PUID=$PUID
PGID=$PGID
MEDIA_DIR=$MEDIA_DIR
DATA_DIR=$DATA_DIR
JELLYFIN_PORT=$JELLYFIN_PORT
SEERR_PORT=$SEERR_PORT
SONARR_PORT=$SONARR_PORT
RADARR_PORT=$RADARR_PORT
QBIT_PORT=$QBIT_PORT
FILEBROWSER_PORT=$FILEBROWSER_PORT
TAILSCALE_HOSTNAME=$TAILSCALE_HOSTNAME
TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY
COMPOSE_PROFILES=$([[ $TAILSCALE_ENABLED -eq 1 ]] && printf tailscale)
ENV
chmod 600 "$INSTALL_DIR/.env"

cat > "$INSTALL_DIR/status.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
docker compose ps
docker compose logs --tail=40
SH
cat > "$INSTALL_DIR/update.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
docker compose ps
SH
chmod 0755 "$INSTALL_DIR/status.sh" "$INSTALL_DIR/update.sh"

cd "$INSTALL_DIR"
docker compose config -q
log "Lade Images und starte den Stack."
docker compose pull
docker compose up -d --remove-orphans

wait_container(){ local n="$1"; for _ in {1..60}; do [[ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null || true)" == true ]] && return 0; sleep 2; done; return 1; }
if wait_container filebrowser; then
  docker exec filebrowser filebrowser config init -d /database/filebrowser.db -r /srv -a 0.0.0.0 -p 80 >/dev/null 2>&1 || true
  docker exec filebrowser filebrowser users add "$ADMIN_USER" "$ADMIN_PASSWORD" --perm.admin -d /database/filebrowser.db >/dev/null 2>&1 || \
  docker exec filebrowser filebrowser users update "$ADMIN_USER" --password "$ADMIN_PASSWORD" --perm.admin -d /database/filebrowser.db >/dev/null 2>&1 || warn "File-Browser-Benutzer muss manuell eingerichtet werden."
fi

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [[ -n "$SERVER_IP" ]] || SERVER_IP="SERVER-IP"
cat > "$INSTALL_DIR/credentials.txt" <<CREDS
File Browser Benutzer: $ADMIN_USER
File Browser Kennwort: $ADMIN_PASSWORD

Jellyfin:     http://$SERVER_IP:$JELLYFIN_PORT
Seerr:        http://$SERVER_IP:$SEERR_PORT
Sonarr:       http://$SERVER_IP:$SONARR_PORT
Radarr:       http://$SERVER_IP:$RADARR_PORT
qBittorrent:  http://$SERVER_IP:$QBIT_PORT
File Browser: http://$SERVER_IP:$FILEBROWSER_PORT

Jellyfin wird beim ersten Öffnen im Browser eingerichtet.
Das temporäre qBittorrent-Kennwort steht in: docker logs qbittorrent
CREDS
chmod 600 "$INSTALL_DIR/credentials.txt"

ok "Installation abgeschlossen."
printf '\nLokale Konfiguration: %s\nMedien: %s\nZugangsdaten: %s/credentials.txt\n\n' "$DATA_DIR" "$MEDIA_DIR" "$INSTALL_DIR"
docker compose ps
