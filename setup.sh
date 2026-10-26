#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
TIMEZONE="Europe/Berlin"
REPO_URL="https://github.com/florianthepro/jellyfin-media-stack"
RAW_BASE_URL="https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main"
DEFAULT_INSTALL_DIR="/opt/${APP_NAME}"
DEFAULT_MEDIA_DIR="/srv/media"
LOG_FILE="/var/log/${APP_NAME}-setup.log"

c_red='\033[0;31m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_blue='\033[0;34m'; c_reset='\033[0m'
log(){ printf '%b[%s] %s%b\n' "$c_blue" "$(date '+%F %T')" "$*" "$c_reset" | tee -a "$LOG_FILE"; }
ok(){ printf '%b[OK] %s%b\n' "$c_green" "$*" "$c_reset" | tee -a "$LOG_FILE"; }
warn(){ printf '%b[WARNUNG] %s%b\n' "$c_yellow" "$*" "$c_reset" | tee -a "$LOG_FILE" >&2; }
die(){ printf '%b[FEHLER] %s%b\n' "$c_red" "$*" "$c_reset" | tee -a "$LOG_FILE" >&2; exit 1; }
trap 'die "Abbruch in Zeile $LINENO. Details: $LOG_FILE"' ERR

ask(){ local prompt="$1" default="$2" value; read -r -p "$prompt [$default]: " value; printf '%s' "${value:-$default}"; }
ask_yes_no(){ local prompt="$1" default="$2" value; while true; do read -r -p "$prompt [$default]: " value; value="${value:-$default}"; case "${value,,}" in j|ja|y|yes) return 0;; n|nein|no) return 1;; *) echo "Bitte ja oder nein eingeben." >&2;; esac; done; }
ask_secret(){ local prompt="$1" first second; while true; do read -r -s -p "$prompt: " first; echo >&2; [[ ${#first} -ge 12 ]] || { echo "Mindestens 12 Zeichen erforderlich." >&2; continue; }; read -r -s -p "Kennwort wiederholen: " second; echo >&2; [[ "$first" == "$second" ]] || { echo "Die Eingaben stimmen nicht überein." >&2; continue; }; printf '%s' "$first"; return; done; }

[[ $EUID -eq 0 ]] || die "Als root starten: sudo bash setup.sh"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
[[ -r /etc/os-release ]] || die "/etc/os-release fehlt."
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "Unterstützt werden Debian und Ubuntu. Erkannt: ${ID:-unbekannt}";; esac

export DEBIAN_FRONTEND=noninteractive
log "Installiere Grundvoraussetzungen."
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq openssl

install_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker
    ok "Docker Engine und Compose sind vorhanden."
    return
  fi
  log "Installiere Docker Engine und Compose aus dem offiziellen Docker-Repository."
  for pkg in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do apt-get remove -y "$pkg" 2>/dev/null || true; done
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

printf '\nNur Pfade, Benutzerkonto und Geheimnisse werden abgefragt.\nZeitzone und Repository-Quellen sind bewusst statisch im Skript definiert.\n\n'
INSTALL_DIR="$(ask 'Installationsverzeichnis' "$DEFAULT_INSTALL_DIR")"
MEDIA_DIR="$(ask 'Medienverzeichnis' "$DEFAULT_MEDIA_DIR")"
ADMIN_USER="$(ask 'Administrator-Benutzername für Jellyfin und File Browser' 'admin')"
ADMIN_PASSWORD="$(ask_secret 'Sicheres Administratorkennwort')"
TAILSCALE_ENABLED=0
TAILSCALE_AUTHKEY=""
TAILSCALE_HOSTNAME="media-server"
if ask_yes_no 'Tailscale-Container aktivieren?' 'nein'; then
  TAILSCALE_ENABLED=1
  TAILSCALE_HOSTNAME="$(ask 'Tailscale-Hostname' 'media-server')"
  read -r -s -p 'Tailscale Auth Key: ' TAILSCALE_AUTHKEY
  echo
  [[ "$TAILSCALE_AUTHKEY" == tskey-* ]] || die "Der Tailscale Auth Key hat kein erwartetes tskey-Format."
fi

SOURCE_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
install -d -m 0755 "$INSTALL_DIR"
copy_or_download(){
  local file="$1" mode="$2"
  if [[ -f "$SOURCE_DIR/$file" ]]; then install -m "$mode" "$SOURCE_DIR/$file" "$INSTALL_DIR/$file"; else curl -fsSL "$RAW_BASE_URL/$file" -o "$INSTALL_DIR/$file"; chmod "$mode" "$INSTALL_DIR/$file"; fi
}
for file in compose.yaml jellyfin.css status.sh update.sh reset.sh; do
  mode=0644; [[ "$file" == *.sh ]] && mode=0755
  copy_or_download "$file" "$mode"
done

TARGET_USER="${SUDO_USER:-root}"
if [[ "$TARGET_USER" == root ]]; then PUID=0; PGID=0; else PUID="$(id -u "$TARGET_USER")"; PGID="$(id -g "$TARGET_USER")"; fi
DATA_DIR="$INSTALL_DIR/data"
install -d -m 0755 "$MEDIA_DIR"/{movies,series,downloads}
install -d -m 0755 "$DATA_DIR"/{jellyfin/config,jellyfin/cache,seerr/config,sonarr/config,radarr/config,qbittorrent/config,filebrowser/database,filebrowser/config,tailscale/state}
chown -R "$PUID:$PGID" "$MEDIA_DIR" "$DATA_DIR"

umask 077
cat > "$INSTALL_DIR/.env" <<ENV
TZ=$TIMEZONE
PUID=$PUID
PGID=$PGID
MEDIA_DIR=$MEDIA_DIR
DATA_DIR=$DATA_DIR
TAILSCALE_HOSTNAME=$TAILSCALE_HOSTNAME
TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY
COMPOSE_PROFILES=$([[ $TAILSCALE_ENABLED -eq 1 ]] && echo tailscale)
ENV
chmod 600 "$INSTALL_DIR/.env"

cd "$INSTALL_DIR"
docker compose config -q
log "Lade Container-Images."
docker compose pull
log "Starte den Stack."
docker compose up -d --remove-orphans

wait_http(){ local url="$1" tries="${2:-60}"; for ((i=1;i<=tries;i++)); do curl -fsS "$url" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

configure_jellyfin(){
  wait_http http://127.0.0.1:8096/health 90 || { warn "Jellyfin ist noch nicht bereit. Ersteinrichtung bitte im Browser abschließen."; return; }
  local startup
  startup="$(curl -fsS http://127.0.0.1:8096/Startup/Configuration 2>/dev/null || true)"
  if jq -e '.IsStartupWizardCompleted == true' >/dev/null 2>&1 <<<"$startup"; then ok "Jellyfin war bereits eingerichtet."; return; fi
  curl -fsS -X POST http://127.0.0.1:8096/Startup/Configuration -H 'Content-Type: application/json' --data '{"UICulture":"de-DE","MetadataCountryCode":"DE","PreferredMetadataLanguage":"de"}' >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/User -H 'Content-Type: application/json' --data "$(jq -n --arg n "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Name:$n,Password:$p}')" >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/RemoteAccess -H 'Content-Type: application/json' --data '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
  curl -fsS -X POST http://127.0.0.1:8096/Startup/Complete >/dev/null
  ok "Jellyfin-Grundeinrichtung abgeschlossen. Bibliotheken werden später in der Weboberfläche ergänzt."
}
configure_jellyfin || warn "Automatische Jellyfin-Konfiguration fehlgeschlagen; der Stack läuft trotzdem."

configure_filebrowser(){
  sleep 3
  docker exec filebrowser filebrowser config init -d /database/filebrowser.db -r /srv -a 0.0.0.0 -p 80 >/dev/null 2>&1 || true
  docker exec filebrowser filebrowser users add "$ADMIN_USER" "$ADMIN_PASSWORD" --perm.admin -d /database/filebrowser.db >/dev/null 2>&1 || \
  docker exec filebrowser filebrowser users update "$ADMIN_USER" --password "$ADMIN_PASSWORD" --perm.admin -d /database/filebrowser.db >/dev/null 2>&1 || true
  ok "File Browser wurde initialisiert."
}
configure_filebrowser

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$SERVER_IP" ]] || SERVER_IP="SERVER-IP"
cat > "$INSTALL_DIR/credentials.txt" <<CREDS
Initiale Zugangsdaten
Benutzer: $ADMIN_USER
Kennwort: $ADMIN_PASSWORD

Jellyfin:     http://$SERVER_IP:8096
Seerr:        http://$SERVER_IP:5055
Sonarr:       http://$SERVER_IP:8989
Radarr:       http://$SERVER_IP:7878
qBittorrent:  http://$SERVER_IP:8080
File Browser: http://$SERVER_IP:8091
CREDS
chmod 600 "$INSTALL_DIR/credentials.txt"

printf '\n%bInstallation abgeschlossen.%b\n' "$c_green" "$c_reset"
printf 'Verzeichnis: %s\nZugangsdaten: %s/credentials.txt\nStatus: cd %s && ./status.sh\n\n' "$INSTALL_DIR" "$INSTALL_DIR" "$INSTALL_DIR"
docker compose ps
