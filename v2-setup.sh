#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
TIMEZONE="Europe/Berlin"
REPO_URL="https://github.com/florianthepro/jellyfin-media-stack"
DEFAULT_INSTALL_DIR="/opt/${APP_NAME}"
DEFAULT_MEDIA_DIR="/srv/media"
LOG_FILE="/var/log/${APP_NAME}-setup-v5.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
log(){ printf '%b[%s] %s%b\n' "$BLUE" "$(date '+%F %T')" "$*" "$RESET" | tee -a "$LOG_FILE"; }
ok(){ printf '%b[OK] %s%b\n' "$GREEN" "$*" "$RESET" | tee -a "$LOG_FILE"; }
warn(){ printf '%b[WARNUNG] %s%b\n' "$YELLOW" "$*" "$RESET" | tee -a "$LOG_FILE" >&2; }
die(){ printf '%b[FEHLER] %s%b\n' "$RED" "$*" "$RESET" | tee -a "$LOG_FILE" >&2; exit 1; }
trap 'rc=$?; printf "%b[FEHLER] Abbruch in Zeile %s, Status %s. Log: %s%b\n" "$RED" "$LINENO" "$rc" "$LOG_FILE" "$RESET" >&2; exit "$rc"' ERR

ask(){ local prompt="$1" default="$2" value; read -r -p "$prompt [$default]: " value; printf '%s' "${value:-$default}"; }
ask_yes_no(){ local prompt="$1" default="$2" value; while true; do read -r -p "$prompt [$default]: " value; value="${value:-$default}"; case "${value,,}" in j|ja|y|yes) return 0;; n|nein|no) return 1;; *) echo "Bitte ja oder nein eingeben." >&2;; esac; done; }
ask_choice(){ local p="$1" d="$2" a="$3" v; while true; do read -r -p "$p [$d]: " v; v="${v:-$d}"; case " $a " in *" ${v,,} "*) printf '%s' "${v,,}"; return;; esac; echo "Auswahl: $a" >&2; done; }
valid_name(){ [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
port_free(){ ! ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }
udp_port_free(){ ! ss -H -lnu "sport = :$1" 2>/dev/null | grep -q .; }
next_free_peer_port(){ local p="$1"; if port_free "$p" && udp_port_free "$p"; then printf '%s' "$p"; return; fi; warn "Peer-Port $p ist für TCP oder UDP belegt."; ask_yes_no "Nächsten für TCP und UDP freien Peer-Port verwenden?" 'ja' || die "Peer-Portkonflikt; sicherer Abbruch."; while ! port_free "$p" || ! udp_port_free "$p"; do ((p++)); [[ $p -le 65535 ]] || die "Kein freier Peer-Port gefunden."; done; warn "Verwende stattdessen Peer-Port $p."; printf '%s' "$p"; }
next_free_port(){
  local preferred="$1" p="$1"
  if port_free "$preferred"; then printf '%s' "$preferred"; return; fi
  warn "Port $preferred ist bereits belegt."
  ask_yes_no "Nächsten freien Port ab $preferred automatisch verwenden?" 'ja' || die "Port $preferred ist belegt; sicherer Abbruch."
  while ! port_free "$p"; do ((p++)); [[ $p -le 65535 ]] || die "Kein freier Port gefunden."; done
  warn "Verwende stattdessen Host-Port $p."
  printf '%s' "$p"
}
fs_type(){ findmnt -n -o FSTYPE -T "$1" 2>/dev/null || true; }

[[ $EUID -eq 0 ]] || die "Als root starten: sudo ./v5-setup.sh"
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
apt-get install -y ca-certificates curl gnupg jq openssl util-linux iproute2

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

printf '\nInstallations- und Medienverzeichnis werden wie bisher getrennt abgefragt.\nSQLite-Konfigurationen dürfen nicht auf einem FUSE-/Rclone-Mount liegen.\n\n'
INSTALL_DIR="$(ask 'Installationsverzeichnis' "$DEFAULT_INSTALL_DIR")"
MEDIA_DIR="$(ask 'Medienverzeichnis' "$DEFAULT_MEDIA_DIR")"
DATA_DIR="$INSTALL_DIR/data"

JELLYFIN_USER="admin"
JELLYFIN_PASSWORD="$(openssl rand -base64 30 | tr -d '=+/\n' | cut -c1-24)"
QBIT_USER="admin"
QBIT_PASSWORD="$(openssl rand -base64 30 | tr -d '=+/\n' | cut -c1-24)"

TAILSCALE_ENABLED=0; TAILSCALE_FUNNEL=0; TAILSCALE_AUTHKEY=""; TAILSCALE_HOSTNAME="media-server"; TAILSCALE_IMAGE="tailscale/tailscale:stable"
if ask_yes_no 'Tailscale-Container aktivieren?' 'nein'; then
  TAILSCALE_ENABLED=1
  TAILSCALE_HOSTNAME="$(ask 'Tailscale-Hostname' 'media-server')"
  valid_name "$TAILSCALE_HOSTNAME" || die "Ungültiger Tailscale-Hostname."
  read -r -s -p 'Tailscale Auth Key: ' TAILSCALE_AUTHKEY; echo
  [[ "$TAILSCALE_AUTHKEY" == tskey-* ]] || die "Der Tailscale Auth Key hat kein erwartetes tskey-Format."
  echo "Funnel macht Jellyfin öffentlich im Internet."
  ask_yes_no 'Tailscale Funnel für Jellyfin aktivieren?' 'nein' && TAILSCALE_FUNNEL=1
fi

DATA_DIR="$INSTALL_DIR/data"
INSTALL_PROBE="$INSTALL_DIR"; [[ -e "$INSTALL_PROBE" ]] || INSTALL_PROBE="$(dirname "$INSTALL_DIR")"
MEDIA_PROBE="$MEDIA_DIR"; [[ -e "$MEDIA_PROBE" ]] || MEDIA_PROBE="$(dirname "$MEDIA_DIR")"
[[ -e "$INSTALL_PROBE" ]] || die "Übergeordnetes Installationsverzeichnis fehlt: $INSTALL_PROBE"
[[ -e "$MEDIA_PROBE" ]] || die "Übergeordnetes Medienverzeichnis fehlt: $MEDIA_PROBE"
INSTALL_FS="$(fs_type "$INSTALL_PROBE")"
MEDIA_FS="$(fs_type "$MEDIA_PROBE")"
[[ "$INSTALL_FS" != fuse && "$INSTALL_FS" != fuse.* ]] || die "$INSTALL_DIR liegt auf FUSE. SQLite-Datenbanken müssen lokal liegen."
if [[ "$MEDIA_FS" == fuse.* || "$MEDIA_FS" == fuse ]]; then
  findmnt -n -o OPTIONS -T "$MEDIA_PROBE" | grep -qw allow_other || die "Der FUSE-Mount für $MEDIA_DIR hat kein allow_other."
  ok "FUSE-Medienpfad mit allow_other erkannt."
fi

OLD_INSTALL="/mnt/internxt/jellyfin-media-stack/opt"
if [[ -f "$OLD_INSTALL/compose.yaml" && "$OLD_INSTALL" != "$INSTALL_DIR" ]]; then
  warn "Weitere Installation erkannt: $OLD_INSTALL. Sie wird nicht automatisch verändert."
fi

ACTION="installieren"
BACKUP_REQUESTED=0
BACKUP_ONLY=0
EXISTING=0
if [[ -f "$INSTALL_DIR/compose.yaml" || -f "$INSTALL_DIR/.env" || -d "$DATA_DIR" ]]; then
  EXISTING=1
  printf '
Vorhandene Installation erkannt: %s
' "$INSTALL_DIR"
  ACTION="$(ask_choice 'Aktion? (weiterverwenden/reinstallieren/deinstallieren/backup/abbrechen)' 'weiterverwenden' 'weiterverwenden reinstallieren deinstallieren backup abbrechen')"
  case "$ACTION" in
    weiterverwenden) ok "Vorhandene Daten und Zugänge bleiben erhalten.";;
    reinstallieren)
      ask_yes_no 'Vor der Reinstallation ein Backup erstellen?' 'ja' && BACKUP_REQUESTED=1 || true
      ;;
    deinstallieren)
      ask_yes_no 'Vor der Deinstallation ein Backup erstellen?' 'ja' && BACKUP_REQUESTED=1 || true
      ;;
    backup) BACKUP_REQUESTED=1; BACKUP_ONLY=1;;
    abbrechen) die 'Abbruch auf Nutzerwunsch. Es wurde nichts verändert.';;
  esac
fi
BACKUP_PATH="${INSTALL_DIR}.backup-$(date +%Y%m%d-%H%M%S).tar.gz"
JELLYFIN_PORT="$(next_free_port 8096)"
SEERR_PORT="$(next_free_port 5055)"
SONARR_PORT="$(next_free_port 8989)"
RADARR_PORT="$(next_free_port 7878)"
QBIT_PORT="$(next_free_port 8080)"
QBIT_PEER_PORT="$(next_free_peer_port 6881)"

printf '
Geplanter Ablauf:
  Aktion:       %s
  Installation: %s
  Medien:       %s
  Backup:       %s
  Tailscale:    %s
  Funnel:       %s
  Peer-Port:    %s

' "$ACTION" "$INSTALL_DIR" "$MEDIA_DIR" "$([[ $BACKUP_REQUESTED -eq 1 ]] && echo "$BACKUP_PATH" || echo nein)" "$([[ $TAILSCALE_ENABLED -eq 1 ]] && echo ja || echo nein)" "$([[ $TAILSCALE_FUNNEL -eq 1 ]] && echo ja || echo nein)" "$QBIT_PEER_PORT"
ask_yes_no 'Diesen Plan anwenden?' 'ja' || die 'Abbruch auf Nutzerwunsch. Es wurde nichts verändert.'

if [[ $BACKUP_REQUESTED -eq 1 && -d "$INSTALL_DIR" ]]; then
  log "Erstelle Backup: $BACKUP_PATH"
  tar -C "$(dirname "$INSTALL_DIR")" -czf "$BACKUP_PATH" "$(basename "$INSTALL_DIR")"
  ok "Backup erstellt."
fi
if [[ $BACKUP_ONLY -eq 1 ]]; then ok "Backup abgeschlossen; keine weiteren Änderungen."; exit 0; fi

if [[ "$ACTION" == deinstallieren ]]; then
  if [[ -f "$INSTALL_DIR/compose.yaml" ]]; then (cd "$INSTALL_DIR" && docker compose --profile tailscale down --remove-orphans) || true; fi
  ask_yes_no 'Lokale Konfiguration und Zugangsdaten ebenfalls löschen? Medien bleiben erhalten.' 'nein' && rm -rf --one-file-system "$INSTALL_DIR" || true
  ok "Deinstallation abgeschlossen. Medien unter $MEDIA_DIR wurden nicht gelöscht."
  exit 0
fi
if [[ "$ACTION" == reinstallieren ]]; then
  if [[ -f "$INSTALL_DIR/compose.yaml" ]]; then (cd "$INSTALL_DIR" && docker compose --profile tailscale down --remove-orphans) || true; fi
  rm -rf --one-file-system "$DATA_DIR"
fi

install -d -m 0755 "$INSTALL_DIR" "$DATA_DIR"
install -d -m 0775 "$MEDIA_DIR"/{movies,series,downloads}
install -d -m 0775 "$DATA_DIR"/{jellyfin/config,jellyfin/cache,seerr/config,sonarr/config,radarr/config,qbittorrent/config,tailscale/state}
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
    ports: ["${QBIT_PORT}:8080", "${QBIT_PEER_PORT}:6881/tcp", "${QBIT_PEER_PORT}:6881/udp"]
    volumes:
      - "${DATA_DIR}/qbittorrent/config:/config"
      - "${MEDIA_DIR}/downloads:/downloads"
    restart: unless-stopped
  tailscale:
    profiles: [tailscale]
    image: "${TAILSCALE_IMAGE}"
    container_name: tailscale
    hostname: "${TAILSCALE_HOSTNAME}"
    environment:
      TS_AUTHKEY: "${TAILSCALE_AUTHKEY}"
      TS_AUTH_ONCE: "true"
      TS_HOSTNAME: "${TAILSCALE_HOSTNAME}"
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
QBIT_PEER_PORT=$QBIT_PEER_PORT
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
cat > "$INSTALL_DIR/stop.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
docker compose stop
SH
chmod 0755 "$INSTALL_DIR/status.sh" "$INSTALL_DIR/update.sh" "$INSTALL_DIR/stop.sh"

cd "$INSTALL_DIR"
docker compose config -q
CONFLICTS=()
for c in jellyfin seerr sonarr radarr qbittorrent tailscale; do
  if docker inspect "$c" >/dev/null 2>&1; then
    d="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$c" 2>/dev/null || true)"
    [[ "$d" == "$INSTALL_DIR" ]] || CONFLICTS+=("$c|${d:-unbekannt}")
  fi
done
if (( ${#CONFLICTS[@]} )); then
  echo 'Konfliktierende Container:'
  for e in "${CONFLICTS[@]}"; do printf '  - %s aus %s
' "${e%%|*}" "${e#*|}"; done
  if ask_yes_no 'Nur diese Container stoppen und entfernen? Daten bleiben erhalten.' 'nein'; then
    for e in "${CONFLICTS[@]}"; do docker rm -f "${e%%|*}" >/dev/null; done
  else
    echo 'Keine Container wurden verändert.'
    die 'Sicherer Abbruch wegen Containerkonflikten.'
  fi
fi
log "Lade Images und starte den Stack."
docker compose pull
docker compose up -d --remove-orphans

wait_http(){ local url="$1"; for _ in {1..90}; do curl -fsS "$url" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

jellyfin_post(){
  local endpoint="$1" payload="${2:-}" code body
  body="$(mktemp)"
  if [[ -n "$payload" ]]; then
    code="$(curl -sS -o "$body" -w '%{http_code}' -X POST "http://127.0.0.1:$JELLYFIN_PORT$endpoint" -H 'Content-Type: application/json' --data "$payload" || printf '000')"
  else
    code="$(curl -sS -o "$body" -w '%{http_code}' -X POST "http://127.0.0.1:$JELLYFIN_PORT$endpoint" || printf '000')"
  fi
  if [[ "$code" =~ ^2 ]]; then rm -f "$body"; return 0; fi
  JELLYFIN_API_ERROR="$endpoint lieferte HTTP $code: $(tr '\n' ' ' <"$body" | head -c 300)"
  rm -f "$body"
  return 1
}

configure_jellyfin(){
  wait_http "http://127.0.0.1:$JELLYFIN_PORT/Startup/Configuration" || { warn "Jellyfin ist noch nicht bereit; Setup im Browser abschließen."; return 1; }
  local public_info
  public_info="$(curl -sS "http://127.0.0.1:$JELLYFIN_PORT/System/Info/Public" 2>/dev/null || printf '{}')"
  if jq -e '.StartupWizardCompleted == true' >/dev/null 2>&1 <<<"$public_info"; then
    warn "Jellyfin war bereits eingerichtet; vorhandener Login bleibt unverändert."
    JELLYFIN_USER="bestehend"
    JELLYFIN_PASSWORD="unverändert"
    return 0
  fi
  JELLYFIN_API_ERROR=""
  jellyfin_post '/Startup/Configuration' '{"UICulture":"de-DE","MetadataCountryCode":"DE","PreferredMetadataLanguage":"de"}' || { warn "Jellyfin-Konfiguration nicht automatisch möglich: $JELLYFIN_API_ERROR"; JELLYFIN_USER="manuell einrichten"; JELLYFIN_PASSWORD="nicht gesetzt"; return 1; }
  jellyfin_post '/Startup/User' "$(jq -nc --arg n "$JELLYFIN_USER" --arg p "$JELLYFIN_PASSWORD" '{Name:$n,Password:$p}')" || { warn "Jellyfin-Benutzer nicht automatisch anlegbar: $JELLYFIN_API_ERROR"; JELLYFIN_USER="manuell einrichten"; JELLYFIN_PASSWORD="nicht gesetzt"; return 1; }
  jellyfin_post '/Startup/RemoteAccess' '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' || { warn "Jellyfin-Remotezugriff nicht automatisch konfiguriert: $JELLYFIN_API_ERROR"; return 1; }
  jellyfin_post '/Startup/Complete' || { warn "Jellyfin-Assistent nicht automatisch abschließbar: $JELLYFIN_API_ERROR"; return 1; }
  ok "Jellyfin automatisch auf Deutsch eingerichtet."
}

configure_qbittorrent(){
  wait_http "http://127.0.0.1:$QBIT_PORT/" || { warn "qBittorrent ist noch nicht bereit."; return 1; }
  local temporary cookie
  temporary="$(docker logs qbittorrent 2>&1 | sed -n 's/.*temporary password is provided for this session: //p' | tail -n1)"
  if [[ -z "$temporary" ]]; then
    QBIT_USER="bestehend"
    QBIT_PASSWORD="unverändert"
    warn "qBittorrent ist bereits eingerichtet oder das temporäre Kennwort ist nicht mehr verfügbar. Zugang bleibt unverändert."
    return 0
  fi
  cookie="$(mktemp)"
  if ! curl -fsS -c "$cookie" --data-urlencode "username=admin" --data-urlencode "password=$temporary" "http://127.0.0.1:$QBIT_PORT/api/v2/auth/login" | grep -q 'Ok.'; then
    rm -f "$cookie"
    QBIT_USER="bestehend"
    QBIT_PASSWORD="unverändert"
    warn "qBittorrent-Anmeldung mit temporärem Kennwort fehlgeschlagen. Zugang bleibt unverändert."
    return 0
  fi
  curl -fsS -b "$cookie" --data-urlencode "json=$(jq -nc --arg u "$QBIT_USER" --arg p "$QBIT_PASSWORD" '{web_ui_username:$u,web_ui_password:$p,save_path:"/downloads"}')" "http://127.0.0.1:$QBIT_PORT/api/v2/app/setPreferences" >/dev/null
  rm -f "$cookie"
  ok "qBittorrent-Zugang und Downloadpfad automatisch eingerichtet."
}

configure_tailscale(){
  [[ $TAILSCALE_ENABLED -eq 1 ]] || return 0
  for _ in {1..60}; do docker exec tailscale tailscale status --json >/dev/null 2>&1 && break; sleep 2; done
  docker exec tailscale tailscale status --json >/dev/null 2>&1 || { warn 'Tailscale nicht bereit.'; return 1; }
  if [[ $TAILSCALE_FUNNEL -eq 1 ]]; then
    local out dns
    if out="$(docker exec tailscale tailscale funnel --bg --yes --https=443 "http://127.0.0.1:$JELLYFIN_PORT" 2>&1)"; then
      dns="$(docker exec tailscale tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"; FUNNEL_URL="https://$dns"; ok "Funnel: $FUNNEL_URL"
    else warn "Funnel nicht aktiviert: $out"; fi
  fi
}
WARNINGS=()
configure_jellyfin || WARNINGS+=("Jellyfin muss manuell abgeschlossen werden")
configure_qbittorrent || WARNINGS+=("qBittorrent muss manuell geprüft werden")
FUNNEL_URL='nicht aktiviert'
configure_tailscale || WARNINGS+=("Tailscale/Funnel muss manuell geprüft werden")

for c in jellyfin seerr sonarr radarr qbittorrent; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  [[ "$state" == running ]] || WARNINGS+=("Container $c ist $state")
done
if [[ $TAILSCALE_ENABLED -eq 1 ]]; then
  state="$(docker inspect -f '{{.State.Status}}' tailscale 2>/dev/null || echo missing)"
  [[ "$state" == running ]] || WARNINGS+=("Container tailscale ist $state")
fi

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [[ -n "$SERVER_IP" ]] || SERVER_IP="SERVER-IP"
cat > "$INSTALL_DIR/credentials.txt" <<CREDS
Jellyfin
URL: http://$SERVER_IP:$JELLYFIN_PORT
Benutzer: $JELLYFIN_USER
Kennwort: $JELLYFIN_PASSWORD

qBittorrent
URL: http://$SERVER_IP:$QBIT_PORT
Benutzer: $QBIT_USER
Kennwort: $QBIT_PASSWORD

Seerr:   http://$SERVER_IP:$SEERR_PORT
Sonarr:  http://$SERVER_IP:$SONARR_PORT
Radarr:  http://$SERVER_IP:$RADARR_PORT
Tailscale Funnel: $FUNNEL_URL
CREDS
chmod 600 "$INSTALL_DIR/credentials.txt"

if (( ${#WARNINGS[@]} )); then
  warn "Installation mit Hinweisen abgeschlossen:"
  printf '  - %s\n' "${WARNINGS[@]}"
else
  ok "Installation und automatische Einrichtung vollständig abgeschlossen."
fi
printf '\nInstallationsverzeichnis: %s\nMedienverzeichnis: %s\n\n' "$INSTALL_DIR" "$MEDIA_DIR"
printf '%s\n' '================ ZUGANGSDATEN ================'
cat "$INSTALL_DIR/credentials.txt"
printf '%s\n' '================================================'
docker compose ps
printf '\nStatus: cd %s && ./status.sh\nUpdate: cd %s && ./update.sh\nLog: %s\n\n' "$INSTALL_DIR" "$INSTALL_DIR" "$LOG_FILE"
if ask_yes_no 'Sind die Zugangsdaten jetzt sicher gespeichert?' 'nein'; then
  rm -f "$INSTALL_DIR/credentials.txt"
  ok "credentials.txt wurde sicher entfernt."
else
  warn "credentials.txt bleibt unter $INSTALL_DIR/credentials.txt gespeichert (nur root lesbar)."
fi
