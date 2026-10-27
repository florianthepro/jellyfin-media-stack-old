#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
TIMEZONE="Europe/Berlin"
REPO_URL="https://github.com/florianthepro/jellyfin-media-stack"
RAW_BASE_URL="https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main"
DEFAULT_INSTALL_DIR="/opt/${APP_NAME}"
DEFAULT_MEDIA_DIR="/srv/media"
TAILSCALE_IMAGE="tailscale/tailscale:stable"
LOG_FILE="/var/log/${APP_NAME}-setup.log"

C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
log(){ printf '%b[%s] %s%b\n' "$C_BLUE" "$(date '+%F %T')" "$*" "$C_RESET" | tee -a "$LOG_FILE"; }
ok(){ printf '%b[OK] %s%b\n' "$C_GREEN" "$*" "$C_RESET" | tee -a "$LOG_FILE"; }
warn(){ printf '%b[WARNUNG] %s%b\n' "$C_YELLOW" "$*" "$C_RESET" | tee -a "$LOG_FILE" >&2; }
die(){ printf '%b[FEHLER] %s%b\n' "$C_RED" "$*" "$C_RESET" | tee -a "$LOG_FILE" >&2; exit 1; }
on_error(){ local rc=$?; trap - ERR; printf '%b[FEHLER] Abbruch in Zeile %s, Status %s. Log: %s%b\n' "$C_RED" "$1" "$rc" "$LOG_FILE" "$C_RESET" | tee -a "$LOG_FILE" >&2; exit "$rc"; }
trap 'on_error "$LINENO"' ERR

ask(){ local prompt="$1" default="$2" value; read -r -p "$prompt [$default]: " value; printf '%s' "${value:-$default}"; }
ask_yes_no(){ local prompt="$1" default="$2" value; while true; do read -r -p "$prompt [$default]: " value; value="${value:-$default}"; case "${value,,}" in j|ja|y|yes) return 0;; n|nein|no) return 1;; *) printf 'Bitte ja oder nein eingeben.\n' >&2;; esac; done; }
valid_hostname(){ [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }
generate_password(){ openssl rand -hex 18; }
fs_type(){ findmnt -n -o FSTYPE -T "$1" 2>/dev/null || true; }
mount_options(){ findmnt -n -o OPTIONS -T "$1" 2>/dev/null || true; }
wait_url(){ local url="$1" attempts="${2:-90}"; for ((i=1;i<=attempts;i++)); do curl -fsS "$url" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

[[ $EUID -eq 0 ]] || die "Als root starten: sudo ./v2-setup.sh"
install -m 0600 /dev/null "$LOG_FILE"
[[ -r /etc/os-release ]] || die "/etc/os-release fehlt."
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "Unterstützt werden Debian und Ubuntu. Erkannt: ${ID:-unbekannt}";; esac

TARGET_USER="${SUDO_USER:-root}"
if [[ "$TARGET_USER" != root ]] && id "$TARGET_USER" >/dev/null 2>&1; then
  PUID="$(id -u "$TARGET_USER")"
  PGID="$(id -g "$TARGET_USER")"
else
  PUID=1000
  PGID=1000
  warn "Kein normaler Aufrufer erkannt. PUID und PGID werden auf 1000 gesetzt."
fi

export DEBIAN_FRONTEND=noninteractive
log "Installiere Grundvoraussetzungen."
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq openssl util-linux iproute2

install_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker
    ok "Docker Engine und Compose sind vorhanden."
    return
  fi
  log "Installiere Docker Engine und Compose aus dem offiziellen Docker-Repository."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker compose version >/dev/null
  ok "Docker wurde installiert."
}
install_docker

printf '\nDas Setup fragt nur notwendige Pfade und optionale Tailscale-Funktionen ab.\nAnwendungszugänge werden sicher erzeugt und automatisch eingerichtet.\n\n'
INSTALL_DIR="$(ask 'Installationsverzeichnis' "$DEFAULT_INSTALL_DIR")"
MEDIA_DIR="$(ask 'Medienverzeichnis' "$DEFAULT_MEDIA_DIR")"
[[ "$INSTALL_DIR" == /* && "$MEDIA_DIR" == /* ]] || die "Es sind absolute Pfade erforderlich."
[[ "$INSTALL_DIR" != "$MEDIA_DIR" ]] || die "Installations- und Medienverzeichnis müssen verschieden sein."

TAILSCALE_ENABLED=0
TAILSCALE_FUNNEL=0
TAILSCALE_AUTHKEY=""
TAILSCALE_HOSTNAME="media-server"
if ask_yes_no 'Tailscale aktivieren?' 'nein'; then
  TAILSCALE_ENABLED=1
  TAILSCALE_HOSTNAME="$(ask 'Tailscale-Hostname' 'media-server')"
  valid_hostname "$TAILSCALE_HOSTNAME" || die "Ungültiger Tailscale-Hostname."
  read -r -s -p 'Tailscale Auth Key: ' TAILSCALE_AUTHKEY; echo
  [[ "$TAILSCALE_AUTHKEY" == tskey-* ]] || die "Der Auth Key hat kein erwartetes tskey-Format."
  printf '\nTailscale Funnel veröffentlicht Jellyfin öffentlich im Internet.\n'
  if ask_yes_no 'Jellyfin mit Tailscale Funnel öffentlich bereitstellen?' 'nein'; then
    TAILSCALE_FUNNEL=1
  fi
fi

install -d -m 0755 "$INSTALL_DIR" "$MEDIA_DIR"
DATA_DIR="$INSTALL_DIR/data"
install -d -m 0755 "$DATA_DIR"

INSTALL_FS="$(fs_type "$INSTALL_DIR")"
if [[ "$INSTALL_FS" == fuse || "$INSTALL_FS" == fuse.* ]]; then
  die "Das Installationsverzeichnis liegt auf $INSTALL_FS. SQLite-Konfigurationen müssen auf einem lokalen Dateisystem liegen. Nutze z. B. $DEFAULT_INSTALL_DIR."
fi
MEDIA_FS="$(fs_type "$MEDIA_DIR")"
if [[ "$MEDIA_FS" == fuse || "$MEDIA_FS" == fuse.* ]]; then
  grep -qw allow_other <<<"$(mount_options "$MEDIA_DIR")" || die "Der FUSE-Mount von $MEDIA_DIR benötigt allow_other für Docker."
  [[ "$TARGET_USER" == root ]] || sudo -u "$TARGET_USER" test -w "$MEDIA_DIR" || die "$TARGET_USER kann nicht in $MEDIA_DIR schreiben."
  ok "FUSE-Medienverzeichnis mit allow_other erkannt."
fi

JELLYFIN_USER="admin"
JELLYFIN_PASSWORD="$(generate_password)"
QBIT_USER="admin"
QBIT_PASSWORD="$(generate_password)"

install -d -m 0775 "$MEDIA_DIR"/{movies,series,downloads}
install -d -m 0775 "$DATA_DIR"/{jellyfin/config,jellyfin/cache,seerr/config,sonarr/config,radarr/config,qbittorrent/config,tailscale/state}
chown -R "$PUID:$PGID" "$MEDIA_DIR" "$DATA_DIR"

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

  tailscale:
    profiles: [tailscale]
    image: ${TAILSCALE_IMAGE}
    container_name: tailscale
    hostname: ${TAILSCALE_HOSTNAME}
    environment:
      TS_AUTHKEY: ${TAILSCALE_AUTHKEY}
      TS_AUTH_ONCE: "true"
      TS_HOSTNAME: ${TAILSCALE_HOSTNAME}
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "false"
    volumes:
      - ${DATA_DIR}/tailscale/state:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    restart: unless-stopped
YAML

umask 077
cat > "$INSTALL_DIR/.env" <<ENV
TZ=$TIMEZONE
PUID=$PUID
PGID=$PGID
MEDIA_DIR=$MEDIA_DIR
DATA_DIR=$DATA_DIR
TAILSCALE_IMAGE=$TAILSCALE_IMAGE
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
docker compose logs --tail=50
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
cat > "$INSTALL_DIR/reset.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
printf 'Zum Löschen der lokalen Konfiguration RESET eingeben: '
read -r answer
[[ "$answer" == RESET ]] || { echo 'Abgebrochen.'; exit 0; }
docker compose --profile tailscale down --remove-orphans || true
rm -rf data
printf 'Lokale Konfiguration gelöscht. Medien wurden nicht verändert.\n'
SH
chmod 0755 "$INSTALL_DIR"/{status,update,reset}.sh

cd "$INSTALL_DIR"
docker compose config -q
for container in jellyfin seerr sonarr radarr qbittorrent tailscale; do
  if docker container inspect "$container" >/dev/null 2>&1; then
    old_dir="$(docker container inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container" 2>/dev/null || true)"
    if [[ -n "$old_dir" && "$old_dir" != "$INSTALL_DIR" ]]; then
      warn "Entferne alten Container $container aus $old_dir; dessen Daten bleiben erhalten."
      docker rm -f "$container" >/dev/null
    fi
  fi
done
log "Lade Images."
docker compose pull
log "Starte den Stack."
docker compose up -d --remove-orphans

configure_jellyfin(){
  wait_url http://127.0.0.1:8096/Startup/Configuration 120 || { warn "Jellyfin wurde nicht rechtzeitig bereit."; return 1; }
  local info
  info="$(curl -fsS http://127.0.0.1:8096/System/Info/Public 2>/dev/null || printf '{}')"
  if jq -e '.StartupWizardCompleted == true' >/dev/null 2>&1 <<<"$info"; then
    warn "Jellyfin ist bereits eingerichtet; vorhandener Zugang bleibt unverändert."
    JELLYFIN_USER="bereits eingerichtet"
    JELLYFIN_PASSWORD="nicht verändert"
    return 0
  fi
  curl -fsS -X POST http://127.0.0.1:8096/Startup/Configuration -H 'Content-Type: application/json' --data '{"UICulture":"de-DE","MetadataCountryCode":"DE","PreferredMetadataLanguage":"de"}' >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/User -H 'Content-Type: application/json' --data "$(jq -nc --arg n "$JELLYFIN_USER" --arg p "$JELLYFIN_PASSWORD" '{Name:$n,Password:$p}')" >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/RemoteAccess -H 'Content-Type: application/json' --data '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/Complete >/dev/null
  ok "Jellyfin wurde automatisch auf Deutsch eingerichtet."
}

configure_qbittorrent(){
  wait_url http://127.0.0.1:8080/ 90 || { warn "qBittorrent wurde nicht rechtzeitig bereit."; return 1; }
  local temporary cookie response
  temporary="$(docker logs qbittorrent 2>&1 | sed -nE 's/.*temporary password[^:]*:[[:space:]]*//Ip' | tail -n1 | tr -d '\r')"
  [[ -n "$temporary" ]] || { warn "Temporäres qBittorrent-Kennwort nicht gefunden."; return 1; }
  cookie="$(mktemp)"
  response="$(curl -fsS -c "$cookie" --data-urlencode 'username=admin' --data-urlencode "password=$temporary" http://127.0.0.1:8080/api/v2/auth/login || true)"
  [[ "$response" == "Ok." ]] || { rm -f "$cookie"; warn "qBittorrent-Anmeldung fehlgeschlagen."; return 1; }
  curl -fsS -b "$cookie" --data-urlencode "json=$(jq -nc --arg u "$QBIT_USER" --arg p "$QBIT_PASSWORD" '{web_ui_username:$u,web_ui_password:$p,save_path:"/downloads"}')" http://127.0.0.1:8080/api/v2/app/setPreferences >/dev/null
  rm -f "$cookie"
  ok "qBittorrent-Zugang und Downloadpfad wurden eingerichtet."
}

configure_tailscale(){
  [[ $TAILSCALE_ENABLED -eq 1 ]] || return 0
  for _ in {1..60}; do docker exec tailscale tailscale status --json >/dev/null 2>&1 && break; sleep 2; done
  docker exec tailscale tailscale status --json >/dev/null 2>&1 || { warn "Tailscale ist noch nicht angemeldet."; return 1; }
  if [[ $TAILSCALE_FUNNEL -eq 1 ]]; then
    if docker exec tailscale tailscale funnel --bg --yes --https=443 http://127.0.0.1:8096 >/tmp/tailscale-funnel.out 2>&1; then
      FUNNEL_URL="https://$(docker exec tailscale tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
      ok "Tailscale Funnel wurde für Jellyfin aktiviert: $FUNNEL_URL"
    else
      warn "Funnel benötigt möglicherweise einmalig eine Freigabe im Tailnet. Ausgabe: $(tr '\n' ' ' </tmp/tailscale-funnel.out)"
      FUNNEL_URL="nicht aktiviert; siehe Tailscale-Ausgabe"
    fi
    rm -f /tmp/tailscale-funnel.out
  fi
}

configure_jellyfin || true
configure_qbittorrent || true
FUNNEL_URL="nicht aktiviert"
configure_tailscale || true

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$SERVER_IP" ]] || SERVER_IP="SERVER-IP"
cat > "$INSTALL_DIR/credentials.txt" <<CREDS
Jellyfin
URL: http://$SERVER_IP:8096
Benutzer: $JELLYFIN_USER
Kennwort: $JELLYFIN_PASSWORD

qBittorrent
URL: http://$SERVER_IP:8080
Benutzer: $QBIT_USER
Kennwort: $QBIT_PASSWORD

Seerr: http://$SERVER_IP:5055
Sonarr: http://$SERVER_IP:8989
Radarr: http://$SERVER_IP:7878
Tailscale Funnel: $FUNNEL_URL
CREDS
chmod 600 "$INSTALL_DIR/credentials.txt"

printf '\n%bInstallation abgeschlossen.%b\n' "$C_GREEN" "$C_RESET"
printf 'Installationsverzeichnis: %s\nMedienverzeichnis: %s\n\n' "$INSTALL_DIR" "$MEDIA_DIR"
printf '%s\n' '================ ZUGANGSDATEN ================'
cat "$INSTALL_DIR/credentials.txt"
printf '%s\n' '================================================'
docker compose ps
printf '\n'
if ask_yes_no 'Sind die Zugangsdaten jetzt sicher gespeichert?' 'nein'; then
  rm -f "$INSTALL_DIR/credentials.txt"
  ok "credentials.txt wurde gelöscht."
else
  warn "credentials.txt bleibt mit Modus 600 unter $INSTALL_DIR/credentials.txt erhalten."
fi
