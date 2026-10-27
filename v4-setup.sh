#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP="jellyfin-media-stack"
INSTALL_DIR="/opt/$APP"
DEFAULT_MEDIA_DIR="/srv/media"
TZ="Europe/Berlin"
LOG="/var/log/$APP-setup.log"

C0='\033[0m'; C1='\033[1;34m'; C2='\033[1;32m'; C3='\033[1;33m'; C4='\033[1;31m'
msg(){ printf '%b%s%b\n' "$C1" "$1" "$C0"; }
ok(){ printf '%bOK%b  %s\n' "$C2" "$C0" "$1"; }
warn(){ printf '%bHINWEIS%b  %s\n' "$C3" "$C0" "$1"; }
fail(){ printf '%bFEHLER%b  %s\n' "$C4" "$C0" "$1" >&2; exit 1; }
trap 'rc=$?; printf "%bFEHLER%b  Installation fehlgeschlagen. Details: sudo cat %s\n" "$C4" "$C0" "$LOG" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || fail "Start mit: sudo ./setup.sh"
install -m 0600 /dev/null "$LOG"
exec 3>&1 4>&2
exec >>"$LOG" 2>&1

. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) exec 1>&3 2>&4; fail "Unterstützt werden Debian und Ubuntu.";; esac

CALLER="${SUDO_USER:-root}"
if [[ "$CALLER" != root ]] && id "$CALLER" >/dev/null 2>&1; then
  PUID="$(id -u "$CALLER")"
  PGID="$(id -g "$CALLER")"
else
  PUID=1000
  PGID=1000
fi

exec 1>&3 2>&4
printf '\n%b%s%b\n' "$C1" "Jellyfin Media Stack" "$C0"
printf 'Saubere Installation mit Jellyfin, Seerr, Sonarr, Radarr und qBittorrent.\n\n'
read -r -p "Medienverzeichnis [$DEFAULT_MEDIA_DIR]: " MEDIA_DIR
MEDIA_DIR="${MEDIA_DIR:-$DEFAULT_MEDIA_DIR}"
[[ "$MEDIA_DIR" == /* ]] || fail "Das Medienverzeichnis muss ein absoluter Pfad sein."
MEDIA_DIR="${MEDIA_DIR%/}"
[[ -n "$MEDIA_DIR" && "$MEDIA_DIR" != / ]] || fail "Das Wurzelverzeichnis / ist nicht erlaubt."

PROBE="$MEDIA_DIR"
while [[ ! -e "$PROBE" && "$PROBE" != / ]]; do PROBE="$(dirname "$PROBE")"; done
[[ -d "$PROBE" ]] || fail "Der übergeordnete Medienpfad ist nicht verfügbar."
FSTYPE="$(findmnt -n -o FSTYPE -T "$PROBE" 2>/dev/null || true)"
if [[ "$FSTYPE" == fuse || "$FSTYPE" == fuse.* ]]; then
  findmnt -n -o OPTIONS -T "$PROBE" | grep -qw allow_other || fail "Der FUSE-Mount benötigt allow_other für Docker."
fi

msg "System wird vorbereitet ..."
exec >>"$LOG" 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

exec 1>&3 2>&4
msg "Vorhandene Installation wird bereinigt ..."
exec >>"$LOG" 2>&1

if [[ -f "$INSTALL_DIR/compose.yaml" ]]; then
  (cd "$INSTALL_DIR" && docker compose down --remove-orphans --volumes) || true
fi
for c in jellyfin seerr sonarr radarr qbittorrent tailscale; do
  docker rm -f "$c" >/dev/null 2>&1 || true
done
docker network rm "${APP}_default" >/dev/null 2>&1 || true

if [[ -d "$MEDIA_DIR" ]]; then
  find "$MEDIA_DIR" -mindepth 1 -maxdepth 1 \
    ! -name movies ! -name series \
    -exec rm -rf --one-file-system {} +
fi
rm -rf --one-file-system "$INSTALL_DIR"

install -d -m 0755 "$INSTALL_DIR"
install -d -m 0775 \
  "$MEDIA_DIR/movies" \
  "$MEDIA_DIR/series" \
  "$MEDIA_DIR/downloads" \
  "$INSTALL_DIR/data/jellyfin/config" \
  "$INSTALL_DIR/data/jellyfin/cache" \
  "$INSTALL_DIR/data/seerr/config" \
  "$INSTALL_DIR/data/sonarr/config" \
  "$INSTALL_DIR/data/radarr/config" \
  "$INSTALL_DIR/data/qbittorrent/config"
chown -R "$PUID:$PGID" "$INSTALL_DIR/data"
chown "$PUID:$PGID" "$MEDIA_DIR" "$MEDIA_DIR/movies" "$MEDIA_DIR/series" "$MEDIA_DIR/downloads" 2>/dev/null || true

cat > "$INSTALL_DIR/compose.yaml" <<'YAML'
name: jellyfin-media-stack
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    environment:
      TZ: ${TZ}
    ports:
      - "8096:8096"
    volumes:
      - ${DATA_DIR}/jellyfin/config:/config
      - ${DATA_DIR}/jellyfin/cache:/cache
      - ${MEDIA_DIR}/movies:/media/movies:ro
      - ${MEDIA_DIR}/series:/media/series:ro
    restart: unless-stopped

  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    init: true
    environment:
      TZ: ${TZ}
      LOG_LEVEL: info
    ports:
      - "5055:5055"
    volumes:
      - ${DATA_DIR}/seerr/config:/app/config
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
    ports:
      - "8989:8989"
    volumes:
      - ${DATA_DIR}/sonarr/config:/config
      - ${MEDIA_DIR}/series:/tv
      - ${MEDIA_DIR}/downloads:/downloads
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
    ports:
      - "7878:7878"
    volumes:
      - ${DATA_DIR}/radarr/config:/config
      - ${MEDIA_DIR}/movies:/movies
      - ${MEDIA_DIR}/downloads:/downloads
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      WEBUI_PORT: 8080
      TORRENTING_PORT: 6881
    ports:
      - "8080:8080"
      - "6881:6881/tcp"
      - "6881:6881/udp"
    volumes:
      - ${DATA_DIR}/qbittorrent/config:/config
      - ${MEDIA_DIR}/downloads:/downloads
    restart: unless-stopped
YAML

cat > "$INSTALL_DIR/.env" <<ENV
TZ=$TZ
PUID=$PUID
PGID=$PGID
DATA_DIR=$INSTALL_DIR/data
MEDIA_DIR=$MEDIA_DIR
ENV
chmod 600 "$INSTALL_DIR/.env"

cat > "$INSTALL_DIR/status.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
docker compose ps
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

exec 1>&3 2>&4
msg "Container werden gestartet ..."
exec >>"$LOG" 2>&1
docker compose pull --quiet
docker compose up -d --remove-orphans --quiet-pull

for _ in {1..90}; do
  running="$(docker compose ps --status running --services | wc -l)"
  [[ "$running" -eq 5 ]] && break
  sleep 2
done
[[ "$(docker compose ps --status running --services | wc -l)" -eq 5 ]] || { exec 1>&3 2>&4; fail "Nicht alle Container laufen. Details: sudo bash $INSTALL_DIR/status.sh"; }

QBIT_PASSWORD="$(docker logs qbittorrent 2>&1 | sed -nE 's/.*temporary password[^:]*:[[:space:]]*//Ip' | tail -n1 | tr -d '\r')"
SERVER_IP="$(hostname -I | awk '{print $1}')"

exec 1>&3 2>&4
printf '\n%bInstallation abgeschlossen%b\n\n' "$C2" "$C0"
printf 'Jellyfin     http://%s:8096\n' "$SERVER_IP"
printf 'Seerr        http://%s:5055\n' "$SERVER_IP"
printf 'Sonarr       http://%s:8989\n' "$SERVER_IP"
printf 'Radarr       http://%s:7878\n' "$SERVER_IP"
printf 'qBittorrent  http://%s:8080\n' "$SERVER_IP"
[[ -n "$QBIT_PASSWORD" ]] && printf 'qBittorrent  Benutzer admin | Temporäres Kennwort %s\n' "$QBIT_PASSWORD"

printf '\nEinrichtung\n'
printf '1. Jellyfin öffnen und den Assistenten abschließen.\n'
printf '   Filme: /media/movies | Serien: /media/series\n'
printf '2. qBittorrent öffnen und unter Tools > Options > Web UI ein dauerhaftes Kennwort setzen.\n'
printf '3. Sonarr: Root Folder /tv, Download Client qbittorrent:8080.\n'
printf '4. Radarr: Root Folder /movies, Download Client qbittorrent:8080.\n'
printf '5. Seerr verbinden: Jellyfin http://jellyfin:8096, Sonarr http://sonarr:8989, Radarr http://radarr:7878.\n'
printf '\nStatus  sudo bash %s/status.sh\n' "$INSTALL_DIR"
printf 'Update  sudo bash %s/update.sh\n' "$INSTALL_DIR"
printf 'Log     sudo cat %s\n\n' "$LOG"
