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
MIN_FREE_GB=20
MIN_RAM_GB=2
WAIT_SECONDS=180
LOG_FILE="/var/log/${APP_NAME}-initial.log"
DEBUG_LOG_FILE="/var/log/${APP_NAME}-interfaces.log"
REQUIRED_PACKAGES=(ca-certificates curl gnupg jq)

BLUE='\033[1;34m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'
info(){ printf '%b[i]%b %s: %s\n' "$BLUE" "$RESET" "$1" "$2"; }
ok(){ printf '%b[✓]%b %s: %s\n' "$GREEN" "$RESET" "$1" "$2"; }
warn(){ printf '%b[!]%b %s: %s\n' "$YELLOW" "$RESET" "$1" "$2"; }
fail(){ printf '%b[✗]%b %s: %s\n' "$RED" "$RESET" "$1" "$2"; }
run_quiet(){ "$@" >>"$LOG_FILE" 2>&1; }
read_tty(){ local n="$1" v; IFS= read -r v </dev/tty || v=""; printf -v "$n" '%s' "$v"; }
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
ask_value(){ local t="$1" d="$2" a; printf '[?] %s [%s]: ' "$t" "$d" >/dev/tty; read_tty a; printf '%s' "${a:-$d}"; }
show_header(){ clear; printf '%bJellyfin Media Stack - Initialisierung%b\n' "$BLUE" "$RESET"; }
next_phase(){
  local text="$1" answer
  while true; do
    printf '[?] %s [y]: ' "$text" >/dev/tty
    read_tty answer
    answer="${answer:-y}"
    case "${answer,,}" in
      y|yes|j|ja) return 0 ;;
      n|no|nein) printf 'User beendet.\n'; info "Log" "sudo cat $LOG_FILE"; exit 0 ;;
      *) warn "Eingabe" "nur y oder n" ;;
    esac
  done
}
die(){ fail "Fehler" "$1"; info "Log" "sudo cat $LOG_FILE"; exit 1; }
trap 'rc=$?; fail "Initialisierung" "fehlgeschlagen" >&2; info "Log" "sudo cat $LOG_FILE" >&2; exit "$rc"' ERR

check_phase(){
  show_header
  . /etc/os-release
  case "${ID:-}" in debian|ubuntu);; *) die "Debian oder Ubuntu erforderlich";; esac
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in amd64|arm64);; *) die "Architektur $ARCH nicht unterstützt";; esac
  FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"; FREE_GB="$(awk -v v="$FREE_KB" 'BEGIN{printf "%.1f",v/1048576}')"
  RAM_KB="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"; RAM_GB="$(awk -v v="$RAM_KB" 'BEGIN{printf "%.1f",v/1048576}')"
  INTERNET_CODE="$(curl -Lso /dev/null --connect-timeout 5 --max-time 10 -w '%{http_code}' https://www.debian.org/ || true)"
  MISSING=(); for p in "${REQUIRED_PACKAGES[@]}"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$' || MISSING+=("$p"); done
  run_quiet apt-get update -qq
  mapfile -t UPDATES < <(apt list --upgradable 2>/dev/null | tail -n +2)
  info "System" "${PRETTY_NAME:-$ID} $ARCH"
  (( FREE_KB >= MIN_FREE_GB*1048576 )) && ok "Speicher" "${FREE_GB}GB/${MIN_FREE_GB}GB" || fail "Speicher" "${FREE_GB}GB/${MIN_FREE_GB}GB"
  (( RAM_KB >= MIN_RAM_GB*1048576 )) && ok "RAM" "${RAM_GB}GB/${MIN_RAM_GB}GB" || fail "RAM" "${RAM_GB}GB/${MIN_RAM_GB}GB"
  [[ "$INTERNET_CODE" =~ ^(200|301|302)$ ]] && ok "Netzwerk" "verfügbar" || fail "Netzwerk" "nicht verfügbar"
  ((${#MISSING[@]})) && warn "Pakete" "${MISSING[*]} fehlen" || ok "Pakete" "vollständig"
  ((${#UPDATES[@]})) && warn "Updates" "${#UPDATES[@]} verfügbar" || ok "Updates" "aktuell"
  if ((${#MISSING[@]})) && ask_yes "Pakete installieren" y; then run_quiet apt-get install -y "${MISSING[@]}"; info "Pakete" "installiert"; fi
  if ((${#UPDATES[@]})) && ask_yes "Updates installieren" y; then run_quiet apt-get full-upgrade -y; info "Updates" "installiert"; fi
  command -v docker >/dev/null 2>&1 || die "Docker fehlt"
  docker compose version >/dev/null 2>&1 || die "Docker Compose fehlt"
  systemctl enable --now docker >>"$LOG_FILE" 2>&1
}

reset_phase(){
  show_header
  MEDIA_FOUND=""
  [[ -f "$INSTALL_DIR/.env" ]] && MEDIA_FOUND="$(sed -nE 's/^(MEDIA|MEDIA_DIR)=(.*)$/\2/p' "$INSTALL_DIR/.env" | tail -n1)"
  if [[ -z "$MEDIA_FOUND" ]]; then
    for c in jellyfin sonarr radarr qbittorrent; do
      docker inspect "$c" >/dev/null 2>&1 || continue
      MEDIA_FOUND="$(docker inspect "$c" --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' | awk -F' \| ' '$2~/^\/(media|movies|tv|downloads)/{print $1}' | sed -E 's#/(movies|series|downloads)$##' | head -n1)"
      [[ -n "$MEDIA_FOUND" ]] && break
    done
  fi
  if [[ -n "$MEDIA_FOUND" ]]; then MEDIA_DIR="$MEDIA_FOUND"; info "Medien" "$MEDIA_DIR erkannt"; else MEDIA_DIR="$(ask_value "Medienverzeichnis" "$MEDIA_DEFAULT")"; fi
  [[ "$MEDIA_DIR" == /* && "$MEDIA_DIR" != / && "$MEDIA_DIR" != "$INSTALL_DIR" ]] || die "Medienpfad ungültig"
  ask_yes "Seerr anlegen" y && SEERR=1 || SEERR=0
  ask_yes "Sonarr anlegen" y && SONARR=1 || SONARR=0
  ask_yes "Radarr anlegen" y && RADARR=1 || RADARR=0
  ask_yes "Prowlarr anlegen" y && PROWLARR=1 || PROWLARR=0
  ask_yes "qBittorrent anlegen" y && QBIT=1 || QBIT=0
  ask_yes "Tailscale anlegen" n && TS=1 || TS=0
  TS_HOST="jellystack"; TS_KEY=""
  if ((TS)); then
    info "Tailscale" "Auth-Key: https://console.tailscale.com/admin/settings/keys"
    printf '[?] Tailscale Auth-Key: ' >/dev/tty
    IFS= read -r -s TS_KEY </dev/tty || TS_KEY=""
    printf '\n' >/dev/tty
    [[ "$TS_KEY" == tskey-* ]] || warn "Tailscale" "Key-Format nicht erkannt"
  fi
  [[ -f "$INSTALL_DIR/compose.yaml" ]] && (cd "$INSTALL_DIR" && run_quiet docker compose --profile tailscale down --remove-orphans --volumes) || true
  mapfile -t IDS < <(docker ps -aq --filter "label=com.docker.compose.project=$APP_NAME"); ((${#IDS[@]})) && run_quiet docker rm -f -v "${IDS[@]}" || true
  rm -rf --one-file-system "$INSTALL_DIR"; install -d -m 0755 "$INSTALL_DIR"
  U="${SUDO_USER:-root}"; if [[ "$U" != root ]] && id "$U" >/dev/null 2>&1; then PUID="$(id -u "$U")"; PGID="$(id -g "$U")"; else PUID=1000; PGID=1000; fi
  cat >"$INSTALL_DIR/.env" <<ENV
TZ=$TIMEZONE
PUID=$PUID
PGID=$PGID
DATA=$INSTALL_DIR/data
MEDIA=$MEDIA_DIR
TS_HOST=$TS_HOST
TS_KEY=$TS_KEY
COMPOSE_PROFILES=$([[ $TS -eq 1 ]] && printf tailscale)
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
    ((SEERR)) && cat <<'YAML'
  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    environment: { TZ: "${TZ}" }
    ports: ["5055:5055"]
    volumes: ["${DATA}/seerr/config:/app/config"]
    restart: unless-stopped
YAML
    ((SONARR)) && cat <<'YAML'
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["8989:8989"]
    volumes: ["${DATA}/sonarr/config:/config", "${MEDIA}/series:/tv", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
YAML
    ((RADARR)) && cat <<'YAML'
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["7878:7878"]
    volumes: ["${DATA}/radarr/config:/config", "${MEDIA}/movies:/movies", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
YAML
    ((PROWLARR)) && cat <<'YAML'
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}" }
    ports: ["9696:9696"]
    volumes: ["${DATA}/prowlarr/config:/config"]
    restart: unless-stopped
YAML
    ((QBIT)) && cat <<'YAML'
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment: { PUID: "${PUID}", PGID: "${PGID}", TZ: "${TZ}", WEBUI_PORT: "8080", TORRENTING_PORT: "6881" }
    ports: ["8080:8080", "6881:6881/tcp", "6881:6881/udp"]
    volumes: ["${DATA}/qbittorrent/config:/config", "${MEDIA}/downloads:/downloads"]
    restart: unless-stopped
YAML
    ((TS)) && cat <<'YAML'
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
  ok "Dateien" ".env und compose.yaml erstellt"
}

probe(){ local n="$1" u="$2" f c; f="$(mktemp)"; c="$(curl -sS --connect-timeout 3 --max-time 10 -o "$f" -w '%{http_code}' "$u" 2>/dev/null || true)"; printf '\n[%s] %s HTTP=%s\n' "$(date -Is)" "$n" "$c" >>"$DEBUG_LOG_FILE"; head -c 65536 "$f" | sed -E 's/(tskey-[A-Za-z0-9_-]+)/<redacted>/g' >>"$DEBUG_LOG_FILE"; rm -f "$f"; [[ "$c" =~ ^2 ]]; }
start_phase(){
  show_header
  cd "$INSTALL_DIR"; set -a; . ./.env; set +a
  mapfile -t SERVICES < <(docker compose config --services)
  SERVICE_LIST="$(printf '%s ' "${SERVICES[@]}")"
  info "Dienste" "${SERVICE_LIST% }"
  install -d -m 0755 "$DATA"; install -d -m 0775 "$MEDIA"/{movies,series,downloads}
  for s in "${SERVICES[@]}"; do case "$s" in jellyfin) install -d -m 0775 "$DATA/jellyfin"/{config,cache};; seerr|sonarr|radarr|prowlarr|qbittorrent) install -d -m 0775 "$DATA/$s/config";; tailscale) install -d -m 0775 "$DATA/tailscale/state";; esac; done
  chown -R "$PUID:$PGID" "$DATA"; run_quiet docker compose pull; run_quiet docker compose up -d --remove-orphans
  deadline=$((SECONDS+WAIT_SECONDS)); while ((SECONDS<deadline)); do running="$(docker compose ps --status running --services | wc -l)"; ((running==${#SERVICES[@]})) && break; sleep 2; done
  ok "Container" "$running/${#SERVICES[@]} laufen"
  if ((DEBUG)); then
    install -m 0600 /dev/null "$DEBUG_LOG_FILE"
    for s in "${SERVICES[@]}"; do
      case "$s" in jellyfin) url=http://127.0.0.1:8096/health;; seerr) url=http://127.0.0.1:5055/api/v1/status;; sonarr) url=http://127.0.0.1:8989/ping;; radarr) url=http://127.0.0.1:7878/ping;; prowlarr) url=http://127.0.0.1:9696/ping;; qbittorrent) url=http://127.0.0.1:8080/api/v2/app/version;; tailscale) docker exec tailscale tailscale status --json | jq 'del(.User,.Self.CapMap,.Self.Capabilities)' >>"$DEBUG_LOG_FILE" 2>&1; ok "$s" "Schnittstelle erfasst"; continue;; esac
      ready=0; for _ in {1..60}; do probe "$s" "$url" && { ready=1; break; }; sleep 2; done
      ((ready)) && ok "$s" "Schnittstelle erfasst" || warn "$s" "noch nicht bereit"
    done
  fi
  ok "Start" "abgeschlossen"
  info "Log" "sudo cat $LOG_FILE"
  if (( DEBUG )); then
    info "Debug" "sudo cat $DEBUG_LOG_FILE"
  fi
  return 0
}

create_manual(){
  local ip services total=0 n=0
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; [[ -n "$ip" ]] || ip="SERVER-IP"
  services="$(cd "$INSTALL_DIR" && docker compose config --services 2>/dev/null || true)"
  has(){ grep -qx "$1" <<<"$services"; }
  for x in jellyfin qbittorrent sonarr radarr prowlarr seerr tailscale; do
    if has "$x"; then total=$((total+1)); fi
  done
  {
    printf 'JELLYFIN MEDIA STACK - MANUELLE RESTEINRICHTUNG\n'
    printf '================================================\n'
    printf 'Aufgaben: %s\n' "$total"
    printf 'Die Weboberflächen dürfen parallel geöffnet werden. Die Tätigkeiten sind in notwendiger Reihenfolge sortiert.\n\n'
    if has jellyfin; then n=$((n+1)); printf '%s. Jellyfin: http://%s:8096\n' "$n" "$ip"; printf '   Administrator anlegen; Filme=/media/movies; Serien=/media/series; Deutsch/Deutschland; automatische Portfreigabe aus.\n\n'; fi
    if has qbittorrent; then n=$((n+1)); printf '%s. qBittorrent: http://%s:8080\n' "$n" "$ip"; printf '   Benutzer=admin; temporäres Kennwort:\n'; printf "   sudo docker logs qbittorrent 2>&1 | sed -nE 's/.*temporary password[^:]*:[[:space:]]*//Ip' | tail -n1\n"; printf '   Dauerhaftes Kennwort setzen; Downloadpfad=/downloads.\n\n'; fi
    if has sonarr; then n=$((n+1)); printf '%s. Sonarr: http://%s:8989\n' "$n" "$ip"; printf '   Root Folder=/tv'; has qbittorrent && printf '; qBittorrent=qbittorrent:8080; Kategorie=sonarr'; printf '; API-Key unter Settings > General notieren.\n\n'; fi
    if has radarr; then n=$((n+1)); printf '%s. Radarr: http://%s:7878\n' "$n" "$ip"; printf '   Root Folder=/movies'; has qbittorrent && printf '; qBittorrent=qbittorrent:8080; Kategorie=radarr'; printf '; API-Key unter Settings > General notieren.\n\n'; fi
    if has prowlarr; then n=$((n+1)); printf '%s. Prowlarr: http://%s:9696\n' "$n" "$ip"; printf '   Indexer hinzufügen.'; has sonarr && printf ' Sonarr=http://sonarr:8989 plus API-Key.'; has radarr && printf ' Radarr=http://radarr:7878 plus API-Key.'; printf '\n\n'; fi
    if has seerr; then n=$((n+1)); printf '%s. Seerr: http://%s:5055\n' "$n" "$ip"; printf '   Jellyfin=http://jellyfin:8096.'; has sonarr && printf ' Sonarr=sonarr:8989, /tv, API-Key.'; has radarr && printf ' Radarr=radarr:7878, /movies, API-Key.'; printf ' Bibliotheken und Rechte synchronisieren.\n\n'; fi
    if has tailscale; then n=$((n+1)); printf '%s. Tailscale\n' "$n"; printf '   Status: sudo docker exec tailscale tailscale status\n'; printf '   IP: sudo docker exec tailscale tailscale ip -4\n'; printf '   Geräte: https://console.tailscale.com/admin/machines\n'; printf '   Keys: https://console.tailscale.com/admin/settings/keys\n\n'; fi
    printf 'Kontrolle: cd %s && sudo docker compose ps\n' "$INSTALL_DIR"
    printf 'Logs: cd %s && sudo docker compose logs --tail=100\n' "$INSTALL_DIR"
  } >"$INSTALL_DIR/MANUAL.txt"
  chmod 0644 "$INSTALL_DIR/MANUAL.txt"
  return 0
}

final_interface(){
  local answer
  create_manual
  clear
  printf '%bJellyfin Media Stack - Bereit%b\n' "$BLUE" "$RESET"
  ok "Stack" "gestartet"
  info "Manual" "$INSTALL_DIR/MANUAL.txt"
  info "Anzeigen" "cat $INSTALL_DIR/MANUAL.txt"
  info "Automatisch" "curl -fsSL $SETUP_URL | sudo bash"
  info "Log" "sudo cat $LOG_FILE"
  if (( DEBUG )); then info "Debug" "sudo cat $DEBUG_LOG_FILE"; fi
  case "$SETUP_MODE" in
    m) clear; printf '%bJellyfin Media Stack - Manuell%b\n' "$BLUE" "$RESET"; cat "$INSTALL_DIR/MANUAL.txt"; return 0 ;;
    a) curl -fsSL "$SETUP_URL" | bash; return 0 ;;
    w)
      while true; do
        printf '[?] Manuell oder automatisch [m/a]: ' >/dev/tty
        read_tty answer
        case "${answer,,}" in
          m|manuell) clear; printf '%bJellyfin Media Stack - Manuell%b\n' "$BLUE" "$RESET"; cat "$INSTALL_DIR/MANUAL.txt"; break ;;
          a|automatisch) curl -fsSL "$SETUP_URL" | bash; break ;;
          *) warn "Eingabe" "nur m oder a" ;;
        esac
      done
      ;;
    *) fail "Modus" "SETUP_MODE muss w, m oder a sein" ;;
  esac
  return 0
}

[[ $EUID -eq 0 ]] || die "Aufruf mit sudo erforderlich"
[[ -r /dev/tty ]] || die "Interaktives Terminal erforderlich"
install -m 0600 /dev/null "$LOG_FILE"
check_phase
next_phase "Mit Cleanup und Konfiguration fortfahren"
reset_phase
next_phase "jellystack starten"
start_phase
final_interface
