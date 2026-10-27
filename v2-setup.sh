#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="jellyfin-media-stack"
TIMEZONE="Europe/Berlin"
DEFAULT_INSTALL_DIR="/opt/${APP_NAME}"
DEFAULT_MEDIA_DIR="/srv/media"
TAILSCALE_IMAGE="tailscale/tailscale:stable"
LOG_FILE="/var/log/${APP_NAME}-setup-v4.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
log(){ printf '%b[%s] %s%b\n' "$BLUE" "$(date '+%F %T')" "$*" "$RESET" | tee -a "$LOG_FILE"; }
ok(){ printf '%b[OK] %s%b\n' "$GREEN" "$*" "$RESET" | tee -a "$LOG_FILE"; }
warn(){ printf '%b[WARNUNG] %s%b\n' "$YELLOW" "$*" "$RESET" | tee -a "$LOG_FILE" >&2; }
die(){ printf '%b[FEHLER] %s%b\n' "$RED" "$*" "$RESET" | tee -a "$LOG_FILE" >&2; exit 1; }
trap 'rc=$?; trap - ERR; printf "%b[FEHLER] Abbruch in Zeile %s, Status %s. Log: %s%b\n" "$RED" "$LINENO" "$rc" "$LOG_FILE" "$RESET" >&2; exit "$rc"' ERR

ask(){ local p="$1" d="$2" v; read -r -p "$p [$d]: " v; printf '%s' "${v:-$d}"; }
yesno(){ local p="$1" d="$2" v; while true; do read -r -p "$p [$d]: " v; v="${v:-$d}"; case "${v,,}" in j|ja|y|yes) return 0;; n|nein|no) return 1;; *) echo "Bitte ja oder nein eingeben." >&2;; esac; done; }
choice(){ local p="$1" d="$2" allowed="$3" v; while true; do read -r -p "$p [$d]: " v; v="${v:-$d}"; case " $allowed " in *" ${v,,} "*) printf '%s' "${v,,}"; return;; esac; echo "Erlaubt: $allowed" >&2; done; }
password(){ openssl rand -hex 18; }
wait_url(){ local u="$1" n="${2:-90}"; for ((i=1;i<=n;i++)); do curl -fsS "$u" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
valid_host(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }

[[ $EUID -eq 0 ]] || die "Als root starten: sudo ./v4-setup.sh"
install -m 0600 /dev/null "$LOG_FILE"
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "Unterstützt werden Debian und Ubuntu.";; esac
CALLER="${SUDO_USER:-root}"
if [[ "$CALLER" != root ]] && id "$CALLER" >/dev/null 2>&1; then PUID="$(id -u "$CALLER")"; PGID="$(id -g "$CALLER")"; else PUID=1000; PGID=1000; fi

export DEBIAN_FRONTEND=noninteractive
log "Prüfe Grundvoraussetzungen."
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq openssl util-linux iproute2
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  log "Installiere Docker Engine und Compose."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
ok "Docker ist bereit."

printf '\nSystemübersicht\n'
printf '%-18s %-25s %-18s %s\n' CONTAINER STATUS COMPOSE-PROJEKT ARBEITSVERZEICHNIS
if docker ps -a --format '{{.Names}}' | grep -q .; then
  while read -r c; do
    status="$(docker inspect -f '{{.State.Status}}' "$c")"
    project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$c" 2>/dev/null || true)"
    workdir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$c" 2>/dev/null || true)"
    printf '%-18s %-25s %-18s %s\n' "$c" "$status" "${project:--}" "${workdir:--}"
  done < <(docker ps -a --format '{{.Names}}')
else
  echo "Keine Container vorhanden."
fi

printf '\nNur notwendige Entscheidungen werden abgefragt. Vor Änderungen folgt ein Gesamtplan.\n\n'
INSTALL_DIR="$(ask 'Installationsverzeichnis' "$DEFAULT_INSTALL_DIR")"
MEDIA_DIR="$(ask 'Medienverzeichnis' "$DEFAULT_MEDIA_DIR")"
[[ "$INSTALL_DIR" == /* && "$MEDIA_DIR" == /* && "$INSTALL_DIR" != "$MEDIA_DIR" ]] || die "Absolute, unterschiedliche Pfade erforderlich."

install_parent="$(dirname "$INSTALL_DIR")"; media_parent="$(dirname "$MEDIA_DIR")"
[[ -e "$install_parent" ]] || die "Übergeordnetes Installationsverzeichnis fehlt: $install_parent"
[[ -e "$media_parent" ]] || die "Übergeordnetes Medienverzeichnis fehlt: $media_parent"
INSTALL_FS="$(findmnt -n -o FSTYPE -T "$install_parent" 2>/dev/null || true)"
MEDIA_FS="$(findmnt -n -o FSTYPE -T "$media_parent" 2>/dev/null || true)"
[[ "$INSTALL_FS" != fuse && "$INSTALL_FS" != fuse.* ]] || die "Installationsdatenbanken dürfen nicht auf FUSE liegen."
if [[ "$MEDIA_FS" == fuse || "$MEDIA_FS" == fuse.* ]]; then
  findmnt -n -o OPTIONS -T "$media_parent" | grep -qw allow_other || die "FUSE-Mount benötigt allow_other."
fi
DATA_DIR="$INSTALL_DIR/data"

DATA_ACTION="create"
BACKUP_DIR=""
if [[ -f "$INSTALL_DIR/compose.yaml" || -f "$INSTALL_DIR/.env" || -d "$DATA_DIR" ]]; then
  echo "Vorhandene Installation erkannt: $INSTALL_DIR"
  while true; do
    DATA_ACTION="$(choice 'Vorhandene Daten verwenden, gesichert neu beginnen oder abbrechen? (verwenden/neu/abbrechen)' 'verwenden' 'verwenden neu abbrechen')"
    case "$DATA_ACTION" in
      verwenden) break;;
      neu)
        if yesno 'Vorhandene Daten bei Ausführung in ein Zeitstempel-Backup verschieben?' 'ja'; then
          BACKUP_DIR="${DATA_DIR}.backup-$(date +%Y%m%d-%H%M%S)"; break
        else
          warn "Kein Backup bestätigt. Bitte erneut auswählen.";
        fi;;
      abbrechen) die "Abbruch auf Nutzerwunsch. Es wurde nichts an der Installation verändert.";;
    esac
  done
fi

TS_ENABLED=0; FUNNEL=0; TS_KEY=""; TS_HOST="media-server"
if yesno 'Tailscale aktivieren?' 'nein'; then
  TS_ENABLED=1
  TS_HOST="$(ask 'Tailscale-Hostname' 'media-server')"; valid_host "$TS_HOST" || die "Ungültiger Hostname."
  read -r -s -p 'Tailscale Auth Key: ' TS_KEY; echo
  [[ "$TS_KEY" == tskey-* ]] || die "Ungültiges Auth-Key-Format."
  echo "Funnel veröffentlicht Jellyfin öffentlich im Internet."
  yesno 'Tailscale Funnel für Jellyfin aktivieren?' 'nein' && FUNNEL=1
fi

STACK_NAMES=(jellyfin seerr sonarr radarr qbittorrent tailscale)
CONFLICTS=()
for c in "${STACK_NAMES[@]}"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    wd="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$c" 2>/dev/null || true)"
    [[ "$wd" == "$INSTALL_DIR" ]] || CONFLICTS+=("$c|${wd:-unbekannt}")
  fi
done
REMOVE_CONFLICTS=0
if (( ${#CONFLICTS[@]} )); then
  echo; echo "Konfliktierende Container:"
  for e in "${CONFLICTS[@]}"; do printf '  - %s aus %s\n' "${e%%|*}" "${e#*|}"; done
  if yesno 'Diese Container bei Ausführung stoppen und entfernen? Datenverzeichnisse bleiben erhalten.' 'nein'; then REMOVE_CONFLICTS=1; else die "Sicherer Abbruch. Keine Container wurden verändert."; fi
fi

port_released_or_reused(){
  local port="$1" n wd e
  while read -r n; do
    [[ -z "$n" ]] && continue
    wd="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$n" 2>/dev/null || true)"
    [[ "$wd" == "$INSTALL_DIR" ]] && return 0
    if [[ $REMOVE_CONFLICTS -eq 1 ]]; then
      for e in "${CONFLICTS[@]}"; do [[ "$n" == "${e%%|*}" ]] && return 0; done
    fi
  done < <(docker ps --filter "publish=$port" --format '{{.Names}}')
  return 1
}
tcp_busy(){ ss -H -lnt "sport = :$1" | grep -q .; }
udp_busy(){ ss -H -lnu "sport = :$1" | grep -q .; }
select_tcp(){ local label="$1" p="$2"; if tcp_busy "$p" && ! port_released_or_reused "$p"; then warn "$label-Port $p ist belegt."; yesno 'Nächsten freien Port verwenden?' 'ja' || die "Portkonflikt."; while tcp_busy "$p"; do ((p++)); done; fi; printf '%s' "$p"; }
JELLYFIN_PORT="$(select_tcp Jellyfin 8096)"; SEERR_PORT="$(select_tcp Seerr 5055)"; SONARR_PORT="$(select_tcp Sonarr 8989)"; RADARR_PORT="$(select_tcp Radarr 7878)"; QBIT_PORT="$(select_tcp qBittorrent 8080)"
PEER_PORT=6881
if (tcp_busy "$PEER_PORT" || udp_busy "$PEER_PORT") && ! port_released_or_reused "$PEER_PORT"; then warn "Peer-Port 6881 ist belegt."; yesno 'Nächsten für TCP und UDP freien Peer-Port verwenden?' 'ja' || die "Peer-Portkonflikt."; while tcp_busy "$PEER_PORT" || udp_busy "$PEER_PORT"; do ((PEER_PORT++)); done; fi

printf '\nGeplanter Aufbau\n  Installation: %s\n  Medien:       %s\n  Datenmodus:   %s\n  Ports:        JF %s | Seerr %s | Sonarr %s | Radarr %s | qBit %s | Peer %s\n  Tailscale:    %s\n  Funnel:       %s\n' "$INSTALL_DIR" "$MEDIA_DIR" "$DATA_ACTION" "$JELLYFIN_PORT" "$SEERR_PORT" "$SONARR_PORT" "$RADARR_PORT" "$QBIT_PORT" "$PEER_PORT" "$([[ $TS_ENABLED -eq 1 ]] && echo ja || echo nein)" "$([[ $FUNNEL -eq 1 ]] && echo ja || echo nein)"
[[ -n "$BACKUP_DIR" ]] && printf '  Backup:       %s\n' "$BACKUP_DIR"
(( ${#CONFLICTS[@]} )) && printf '  Altcontainer: werden nach Bestätigung entfernt\n'
yesno 'Diesen Plan jetzt anwenden?' 'ja' || die "Abbruch auf Nutzerwunsch. Keine geplanten Änderungen ausgeführt."

log "Wende bestätigten Plan an."
if [[ "$DATA_ACTION" == neu && -d "$DATA_DIR" ]]; then mv "$DATA_DIR" "$BACKUP_DIR"; ok "Backup erstellt: $BACKUP_DIR"; fi
if [[ $REMOVE_CONFLICTS -eq 1 ]]; then for e in "${CONFLICTS[@]}"; do c="${e%%|*}"; log "Entferne bestätigten Altcontainer $c"; docker rm -f "$c" >/dev/null; done; fi
install -d -m 0755 "$INSTALL_DIR" "$DATA_DIR"
install -d -m 0775 "$MEDIA_DIR"/{movies,series,downloads} "$DATA_DIR"/{jellyfin/config,jellyfin/cache,seerr/config,sonarr/config,radarr/config,qbittorrent/config,tailscale/state}
chown -R "$PUID:$PGID" "$DATA_DIR"
chown "$PUID:$PGID" "$MEDIA_DIR" "$MEDIA_DIR"/{movies,series,downloads} 2>/dev/null || true

cat > "$INSTALL_DIR/compose.yaml.tmp" <<'YAML'
name: jellyfin-media-stack
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    environment: { TZ: "${TZ}" }
    ports: ["${JELLYFIN_PORT}:8096"]
    volumes: ["${DATA_DIR}/jellyfin/config:/config", "${DATA_DIR}/jellyfin/cache:/cache", "${MEDIA_DIR}/movies:/media/movies:ro", "${MEDIA_DIR}/series:/media/series:ro"]
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
    volumes: ["${DATA_DIR}/sonarr/config:/config", "${MEDIA_DIR}/series:/tv", "${MEDIA_DIR}/downloads:/downloads"]
    restart: unless-stopped
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["${RADARR_PORT}:7878"]
    volumes: ["${DATA_DIR}/radarr/config:/config", "${MEDIA_DIR}/movies:/movies", "${MEDIA_DIR}/downloads:/downloads"]
    restart: unless-stopped
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}", WEBUI_PORT: "8080", TORRENTING_PORT: "6881" }
    ports: ["${QBIT_PORT}:8080", "${PEER_PORT}:6881/tcp", "${PEER_PORT}:6881/udp"]
    volumes: ["${DATA_DIR}/qbittorrent/config:/config", "${MEDIA_DIR}/downloads:/downloads"]
    restart: unless-stopped
  tailscale:
    profiles: [tailscale]
    image: "${TAILSCALE_IMAGE}"
    container_name: tailscale
    hostname: "${TS_HOST}"
    environment: { TS_AUTHKEY: "${TS_KEY}", TS_AUTH_ONCE: "true", TS_HOSTNAME: "${TS_HOST}", TS_STATE_DIR: /var/lib/tailscale, TS_USERSPACE: "false" }
    volumes: ["${DATA_DIR}/tailscale/state:/var/lib/tailscale", "/dev/net/tun:/dev/net/tun"]
    network_mode: host
    cap_add: [NET_ADMIN, NET_RAW]
    restart: unless-stopped
YAML
umask 077
cat > "$INSTALL_DIR/.env.tmp" <<ENV
TZ=$TIMEZONE
PUID=$PUID
PGID=$PGID
DATA_DIR=$DATA_DIR
MEDIA_DIR=$MEDIA_DIR
JELLYFIN_PORT=$JELLYFIN_PORT
SEERR_PORT=$SEERR_PORT
SONARR_PORT=$SONARR_PORT
RADARR_PORT=$RADARR_PORT
QBIT_PORT=$QBIT_PORT
PEER_PORT=$PEER_PORT
TAILSCALE_IMAGE=$TAILSCALE_IMAGE
TS_HOST=$TS_HOST
TS_KEY=$TS_KEY
COMPOSE_PROFILES=$([[ $TS_ENABLED -eq 1 ]] && echo tailscale)
ENV
(cd "$INSTALL_DIR" && docker compose --env-file .env.tmp -f compose.yaml.tmp config -q)
mv "$INSTALL_DIR/compose.yaml.tmp" "$INSTALL_DIR/compose.yaml"; mv "$INSTALL_DIR/.env.tmp" "$INSTALL_DIR/.env"; chmod 600 "$INSTALL_DIR/.env"
cd "$INSTALL_DIR"; docker compose pull; docker compose up -d --remove-orphans

JF_USER="admin"; JF_PASS="$(password)"; QB_USER="admin"; QB_PASS="$(password)"; JF_CRED_STATE="generated"; QB_CRED_STATE="generated"; FUNNEL_URL="nicht aktiviert"; WARNINGS=()
if wait_url "http://127.0.0.1:$JELLYFIN_PORT/Startup/Configuration" 120; then
  info="$(curl -fsS "http://127.0.0.1:$JELLYFIN_PORT/System/Info/Public" || echo '{}')"
  if jq -e '.StartupWizardCompleted == true' >/dev/null <<<"$info"; then JF_USER="bestehend"; JF_PASS="unverändert"; JF_CRED_STATE="existing"; else
    curl -fsS -X POST "http://127.0.0.1:$JELLYFIN_PORT/Startup/Configuration" -H 'Content-Type: application/json' --data '{"UICulture":"de-DE","MetadataCountryCode":"DE","PreferredMetadataLanguage":"de"}' >/dev/null
    curl -fsS -X POST "http://127.0.0.1:$JELLYFIN_PORT/Startup/User" -H 'Content-Type: application/json' --data "$(jq -nc --arg n "$JF_USER" --arg p "$JF_PASS" '{Name:$n,Password:$p}')" >/dev/null
    curl -fsS -X POST "http://127.0.0.1:$JELLYFIN_PORT/Startup/RemoteAccess" -H 'Content-Type: application/json' --data '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
    curl -fsS -X POST "http://127.0.0.1:$JELLYFIN_PORT/Startup/Complete" >/dev/null
  fi
else WARNINGS+=("Jellyfin-Grundeinrichtung nicht abgeschlossen"); JF_USER="unbekannt"; JF_PASS="manuell prüfen"; fi

if wait_url "http://127.0.0.1:$QBIT_PORT/" 90; then
  tmp="$(docker logs qbittorrent 2>&1 | sed -nE 's/.*temporary password[^:]*:[[:space:]]*//Ip' | tail -n1 | tr -d '\r')"
  if [[ -n "$tmp" ]]; then
    jar="$(mktemp)"; response="$(curl -fsS -c "$jar" --data-urlencode username=admin --data-urlencode "password=$tmp" "http://127.0.0.1:$QBIT_PORT/api/v2/auth/login" || true)"
    if [[ "$response" == Ok. ]]; then curl -fsS -b "$jar" --data-urlencode "json=$(jq -nc --arg u "$QB_USER" --arg p "$QB_PASS" '{web_ui_username:$u,web_ui_password:$p,save_path:"/downloads"}')" "http://127.0.0.1:$QBIT_PORT/api/v2/app/setPreferences" >/dev/null; else QB_USER="bestehend"; QB_PASS="unverändert"; QB_CRED_STATE="existing"; WARNINGS+=("qBittorrent-Zugang nicht geändert"); fi; rm -f "$jar"
  else QB_USER="bestehend"; QB_PASS="unverändert"; QB_CRED_STATE="existing"; WARNINGS+=("qBittorrent war bereits eingerichtet"); fi
else QB_USER="unbekannt"; QB_PASS="manuell prüfen"; WARNINGS+=("qBittorrent nicht erreichbar"); fi

if [[ $TS_ENABLED -eq 1 ]]; then
  for _ in {1..60}; do docker exec tailscale tailscale status --json >/dev/null 2>&1 && break; sleep 2; done
  if docker exec tailscale tailscale status --json >/dev/null 2>&1; then
    if [[ $FUNNEL -eq 1 ]]; then
      if out="$(docker exec tailscale tailscale funnel --bg --yes --https=443 "http://127.0.0.1:$JELLYFIN_PORT" 2>&1)"; then dns="$(docker exec tailscale tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"; FUNNEL_URL="https://$dns"; else WARNINGS+=("Funnel nicht aktiviert: $out"); fi
    fi
  else WARNINGS+=("Tailscale nicht angemeldet"); fi
fi

SERVER_IP="$(hostname -I | awk '{print $1}')"
cat > "$INSTALL_DIR/credentials.txt" <<CREDS
Jellyfin: http://$SERVER_IP:$JELLYFIN_PORT
Benutzer: $JF_USER
Kennwort: $JF_PASS

qBittorrent: http://$SERVER_IP:$QBIT_PORT
Benutzer: $QB_USER
Kennwort: $QB_PASS

Seerr: http://$SERVER_IP:$SEERR_PORT
Sonarr: http://$SERVER_IP:$SONARR_PORT
Radarr: http://$SERVER_IP:$RADARR_PORT
Tailscale Funnel: $FUNNEL_URL
CREDS
chmod 600 "$INSTALL_DIR/credentials.txt"
printf '\n================ ZUGANGSDATEN ================\n'; cat "$INSTALL_DIR/credentials.txt"; printf '================================================\n'
docker compose ps
if (( ${#WARNINGS[@]} )); then echo; warn "Installation mit Hinweisen abgeschlossen:"; printf '  - %s\n' "${WARNINGS[@]}"; else ok "Installation und automatische Einrichtung vollständig abgeschlossen."; fi
if yesno 'Sind die Zugangsdaten sicher gespeichert?' 'nein'; then rm -f "$INSTALL_DIR/credentials.txt"; ok "credentials.txt gelöscht."; else warn "credentials.txt bleibt mit Modus 600 erhalten."; fi
