#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP="jellyfin-media-stack"
INSTALL="/opt/$APP"
MEDIA_DEFAULT="/srv/media"
LOG="/var/log/$APP-setup.log"
TZ="Europe/Berlin"
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; N='\033[0m'
phase(){ printf '%b%s%b\n' "$B" "$1" "$N"; }
fail(){ printf '%bFEHLER%b  %s\n' "$R" "$N" "$1" >&2; exit 1; }
trap 'rc=$?; printf "%bFEHLER%b  Installation fehlgeschlagen. Log: sudo cat %s\n" "$R" "$N" "$LOG" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || fail "Start: sudo ./setup.sh"
install -m 0600 /dev/null "$LOG"
exec 3>&1 4>&2
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) fail "Unterstützt werden Debian und Ubuntu.";; esac
USER_NAME="${SUDO_USER:-root}"
if [[ "$USER_NAME" != root ]] && id "$USER_NAME" >/dev/null 2>&1; then PUID="$(id -u "$USER_NAME")"; PGID="$(id -g "$USER_NAME")"; else PUID=1000; PGID=1000; fi

printf '\n%bJellyfin Media Stack%b\n\n' "$B" "$N"
read -r -p "Medienverzeichnis [$MEDIA_DEFAULT]: " MEDIA
MEDIA="${MEDIA:-$MEDIA_DEFAULT}"; MEDIA="${MEDIA%/}"
[[ "$MEDIA" == /* && "$MEDIA" != / ]] || fail "Bitte einen absoluten Medienpfad außer / angeben."

TS=0; TS_KEY=""; TS_HOST="media-server"
read -r -p "Tailscale aktivieren? [nein]: " A
case "${A,,}" in j|ja|y|yes)
  TS=1
  read -r -p "Tailscale-Hostname [$TS_HOST]: " H; TS_HOST="${H:-$TS_HOST}"
  read -r -s -p "Tailscale Auth Key: " TS_KEY; printf '\n'
  [[ "$TS_KEY" == tskey-* ]] || fail "Ungültiger Tailscale Auth Key."
esac

PROBE="$MEDIA"; while [[ ! -e "$PROBE" && "$PROBE" != / ]]; do PROBE="$(dirname "$PROBE")"; done
[[ -d "$PROBE" ]] || fail "Medienpfad ist nicht erreichbar."
FS="$(findmnt -n -o FSTYPE -T "$PROBE" 2>/dev/null || true)"
if [[ "$FS" == fuse || "$FS" == fuse.* ]]; then findmnt -n -o OPTIONS -T "$PROBE" | grep -qw allow_other || fail "FUSE benötigt allow_other."; fi

exec >>"$LOG" 2>&1
exec 1>&3 2>&4; phase "System wird vorbereitet ..."; exec >>"$LOG" 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

exec 1>&3 2>&4; phase "Vorhandene Installation wird bereinigt ..."; exec >>"$LOG" 2>&1
[[ -f "$INSTALL/compose.yaml" ]] && (cd "$INSTALL" && docker compose --profile tailscale down --remove-orphans --volumes) || true
for c in jellyfin seerr sonarr radarr prowlarr qbittorrent tailscale; do docker rm -f "$c" >/dev/null 2>&1 || true; done
docker network rm "${APP}_default" >/dev/null 2>&1 || true
if [[ -d "$MEDIA" ]]; then find "$MEDIA" -mindepth 1 -maxdepth 1 ! -name movies ! -name series -exec rm -rf --one-file-system {} +; fi
rm -rf --one-file-system "$INSTALL"
install -d -m 0755 "$INSTALL"
install -d -m 0775 "$MEDIA"/{movies,series,downloads} "$INSTALL/data"/{jellyfin/config,jellyfin/cache,seerr/config,sonarr/config,radarr/config,prowlarr/config,qbittorrent/config,tailscale/state}
chown -R "$PUID:$PGID" "$INSTALL/data"
chown "$PUID:$PGID" "$MEDIA" "$MEDIA"/{movies,series,downloads} 2>/dev/null || true

cat > "$INSTALL/compose.yaml" <<'YAML'
name: jellyfin-media-stack
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    environment: { TZ: "${TZ}" }
    ports: ["8096:8096"]
    volumes: ["${DATA}/jellyfin/config:/config", "${DATA}/jellyfin/cache:/cache", "${MEDIA}/movies:/media/movies:ro", "${MEDIA}/series:/media/series:ro"]
    restart: unless-stopped
  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    init: true
    environment: { TZ: "${TZ}", LOG_LEVEL: info }
    ports: ["5055:5055"]
    volumes: ["${DATA}/seerr/config:/app/config"]
    restart: unless-stopped
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["8989:8989"]
    volumes: ["${DATA}/sonarr/config:/config", "${MEDIA}/series:/tv", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["7878:7878"]
    volumes: ["${DATA}/radarr/config:/config", "${MEDIA}/movies:/movies", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["9696:9696"]
    volumes: ["${DATA}/prowlarr/config:/config"]
    restart: unless-stopped
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}", WEBUI_PORT: "8080", TORRENTING_PORT: "6881" }
    ports: ["8080:8080", "6881:6881/tcp", "6881:6881/udp"]
    volumes: ["${DATA}/qbittorrent/config:/config", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
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
cat > "$INSTALL/.env" <<ENV
TZ=$TZ
PUID=$PUID
PGID=$PGID
DATA=$INSTALL/data
MEDIA=$MEDIA
TS_HOST=$TS_HOST
TS_KEY=$TS_KEY
COMPOSE_PROFILES=$([[ $TS -eq 1 ]] && printf tailscale)
ENV
chmod 600 "$INSTALL/.env"
cat > "$INSTALL/status.sh" <<'SH'
#!/usr/bin/env bash
cd "$(dirname "$(readlink -f "$0")")" && docker compose ps
SH
cat > "$INSTALL/update.sh" <<'SH'
#!/usr/bin/env bash
set -e
cd "$(dirname "$(readlink -f "$0")")"
docker compose pull && docker compose up -d --remove-orphans && docker image prune -f && docker compose ps
SH
chmod 755 "$INSTALL"/{status,update}.sh
cd "$INSTALL"; docker compose config -q
exec 1>&3 2>&4; phase "Container werden gestartet ..."; exec >>"$LOG" 2>&1
docker compose pull --quiet
docker compose up -d --remove-orphans --quiet-pull
EXPECTED=$((6+TS))
for _ in {1..90}; do [[ "$(docker compose ps --status running --services | wc -l)" -eq "$EXPECTED" ]] && break; sleep 2; done
[[ "$(docker compose ps --status running --services | wc -l)" -eq "$EXPECTED" ]] || { exec 1>&3 2>&4; fail "Nicht alle Container laufen. Status: sudo bash $INSTALL/status.sh"; }
SERVER_IP="$(hostname -I | awk '{print $1}')"
QBIT_PASS="$(docker logs qbittorrent 2>&1 | sed -nE 's/.*temporary password[^:]*:[[:space:]]*//Ip' | tail -n1 | tr -d '\r')"
TS_IP=""; TS_DNS=""
if [[ $TS -eq 1 ]]; then
  for _ in {1..60}; do
    J="$(docker exec tailscale tailscale status --json 2>/dev/null || true)"
    TS_IP="$(jq -r '.Self.TailscaleIPs[0] // empty' <<<"$J" 2>/dev/null || true)"
    TS_DNS="$(jq -r '.Self.DNSName // empty' <<<"$J" 2>/dev/null | sed 's/\.$//' || true)"
    [[ -n "$TS_IP" ]] && break; sleep 2
  done
fi

exec 1>&3 2>&4
printf '\n%bInstallation abgeschlossen%b\n' "$G" "$N"
printf '\nJellyfin\nAdresse:  http://%s:8096\nAktion:   Assistent öffnen; Filme=/media/movies, Serien=/media/series\n' "$SERVER_IP"
printf '\nSeerr\nAdresse:  http://%s:5055\nAktion:   Jellyfin=http://jellyfin:8096, Sonarr=http://sonarr:8989, Radarr=http://radarr:7878\n' "$SERVER_IP"
printf '\nProwlarr\nAdresse:  http://%s:9696\nAktion:   Indexer hinzufügen; danach Settings > Apps öffnen.\n' "$SERVER_IP"
printf 'Sonarr:   Name=Sonarr, URL=http://sonarr:8989, API-Key aus Sonarr > Settings > General\n'
printf 'Radarr:   Name=Radarr, URL=http://radarr:7878, API-Key aus Radarr > Settings > General\n'
printf '\nSonarr\nAdresse:  http://%s:8989\nAktion:   Root Folder=/tv, Download Client=qbittorrent:8080\n' "$SERVER_IP"
printf '\nRadarr\nAdresse:  http://%s:7878\nAktion:   Root Folder=/movies, Download Client=qbittorrent:8080\n' "$SERVER_IP"
printf '\nqBittorrent\nAdresse:  http://%s:8080\nBenutzer: admin\nKennwort: %s\nAktion:   Tools > Options > Web UI öffnen und dauerhaftes Kennwort setzen\n' "$SERVER_IP" "$(docker logs qbittorrent 2>&1 | sed -nE 's/.*temporary password[^:]*:[[:space:]]*//Ip' | tail -n 1)"
if [[ $TS -eq 1 ]]; then
  printf '\nTailscale\n'
  [[ -n "$TS_DNS" ]] && printf 'Adresse:  https://%s\n' "$TS_DNS" || printf 'Adresse:  http://%s\n' "${TS_IP:-noch-nicht-verfügbar}"
  printf 'Status:   sudo docker exec tailscale tailscale status\n'
fi
printf '\nVerwaltung\nAdresse:  %s\nStatus:   sudo bash %s/status.sh\nUpdate:   sudo bash %s/update.sh\nLog:      sudo cat %s\n\n' "$INSTALL" "$INSTALL" "$INSTALL" "$LOG"
