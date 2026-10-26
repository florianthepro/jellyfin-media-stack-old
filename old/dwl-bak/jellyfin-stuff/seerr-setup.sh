#!/bin/bash
# curl -sSL https://raw.githubusercontent.com/florianthepro/public/main/seerr-setup.sh | sudo bash
# wget -qO- https://raw.githubusercontent.com/florianthepro/public/main/seerr-setup.sh | sudo bash
set -euo pipefail

# ===== Konfigurierbare Defaults =====
TZ_DEFAULT="Asia/Tashkent"
PORT_DEFAULT="5055"
SEERR_CONFIG_DEFAULT="/var/lib/seerr/config"
SEERR_STACK_DIR_DEFAULT="/opt/seerr"

# ===== Argument-Parsing =====
TZ="$TZ_DEFAULT"
PORT="$PORT_DEFAULT"
SEERR_CONFIG="$SEERR_CONFIG_DEFAULT"
SEERR_STACK_DIR="$SEERR_STACK_DIR_DEFAULT"

usage() {
  cat <<EOF
Usage: sudo bash $0 [--tz <TZ>] [--port <PORT>] [--config-dir <PATH>] [--stack-dir <PATH>]

Defaults:
  --tz          $TZ_DEFAULT
  --port        $PORT_DEFAULT
  --config-dir  $SEERR_CONFIG_DEFAULT
  --stack-dir   $SEERR_STACK_DIR_DEFAULT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tz) TZ="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --config-dir) SEERR_CONFIG="$2"; shift 2 ;;
    --stack-dir) SEERR_STACK_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo/root ausführen."
    exit 1
  fi
}

install_docker_compose() {
  echo ">>> Entferne evtl. konflik­tierende Docker-Pakete (falls vorhanden)…"
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc >/dev/null 2>&1 || true

  echo ">>> Systempakete aktualisieren & Voraussetzungen installieren…"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  echo ">>> Docker GPG-Key & Repository hinzufügen…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list >/dev/null

  echo ">>> Docker Engine + Buildx + Compose Plugin installieren…"
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo ">>> Docker-Dienst aktivieren…"
  systemctl enable --now docker

  # Aktuellen Benutzer zur docker-Gruppe hinzufügen (wirkt nach Re-Login)
  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER" || true
  fi

  echo ">>> Docker Version:"
  docker --version || true
  echo ">>> Compose Version:"
  docker compose version || true
}

prepare_dirs_and_compose() {
  echo ">>> Verzeichnisse anlegen…"
  mkdir -p "$SEERR_CONFIG"
  mkdir -p "$SEERR_STACK_DIR"

  echo ">>> Besitz für Config auf UID 1000 setzen (Container-User 'node')…"
  chown -R 1000:1000 "$SEERR_CONFIG"

  echo ">>> .env für Compose schreiben…"
  cat > "$SEERR_STACK_DIR/.env" <<ENV
TZ=$TZ
PORT=$PORT
ENV

  echo ">>> compose.yaml schreiben…"
  cat > "$SEERR_STACK_DIR/compose.yaml" <<'YAML'
services:
  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    init: true
    container_name: seerr
    environment:
      - LOG_LEVEL=debug
      - TZ=${TZ}
      - PORT=${PORT} # optional
    ports:
      - "${PORT}:${PORT}"
    volumes:
      - /var/lib/seerr/config:/app/config
    healthcheck:
      test: wget --no-verbose --tries=1 --spider http://localhost:${PORT}/api/v1/status || exit 1
      start_period: 20s
      timeout: 3s
      interval: 15s
      retries: 3
    restart: unless-stopped
YAML

  # Falls Pfad abweicht, in compose.yaml ersetzen
  if [[ "$SEERR_CONFIG" != "/var/lib/seerr/config" ]]; then
    sed -i "s|/var/lib/seerr/config|$SEERR_CONFIG|g" "$SEERR_STACK_DIR/compose.yaml"
  fi
}

start_stack() {
  echo ">>> Seerr Container-Image ziehen…"
  (cd "$SEERR_STACK_DIR" && docker compose pull)

  echo ">>> Stack starten…"
  (cd "$SEERR_STACK_DIR" && docker compose up -d)

  echo ">>> Laufstatus:"
  (cd "$SEERR_STACK_DIR" && docker compose ps)

  echo ">>> Fertig. Öffne: http://<deine-host-ip>:$PORT"
  echo "Hinweis: Gruppenmitgliedschaft 'docker' wirkt nach Re-Login/Neustart der Shell."
}

main() {
  require_root
  install_docker_compose
  prepare_dirs_and_compose
  start_stack
}

main
