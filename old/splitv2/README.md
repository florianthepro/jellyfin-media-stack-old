# Jellyfin Media Stack

Dieses Repository stellt denselben Stack auf zwei Wegen bereit:

1. **Automatisch:** `setup.sh` übernimmt Systemprüfung, Docker-Installation, Verzeichnisse, `.env`, Containerstart und soweit zuverlässig möglich die Ersteinrichtung.
2. **Manuell:** Diese README enthält alle erforderlichen Befehle. Sie funktioniert auch dann, wenn `setup.sh` nicht vorhanden ist.

Beide Wege führen zur gleichen Verzeichnisstruktur und derselben `compose.yaml`.

## Enthaltene Dienste

- Jellyfin auf Port `8096`
- Seerr auf Port `5055`
- Sonarr auf Port `8989`
- Radarr auf Port `7878`
- qBittorrent auf Port `8080`, Peer-Port `6881/tcp+udp`
- File Browser auf Port `8091`
- Tailscale optional über das Compose-Profil `tailscale`

## Repository-Struktur

```text
.
├── .env.example
├── .gitignore
├── README.md
├── compose.yaml
├── jellyfin.css
├── reset.sh
├── setup.sh
├── status.sh
└── update.sh
```

Geheimnisse und Laufzeitdaten werden nicht eingecheckt. `.env`, `data/`, Logs und ZIP-Dateien stehen in `.gitignore`.

## Voraussetzungen

- Debian oder Ubuntu
- Root- oder sudo-Zugriff
- Internetzugang für APT und Container-Images
- freie Ports `5055`, `7878`, `8080`, `8091`, `8096`, `8989` und `6881/tcp+udp`
- optional ein Tailscale Auth Key

> Docker-publizierte Ports können bestehende Host-Firewall-Regeln umgehen. Prüfe die Erreichbarkeit der Weboberflächen und veröffentliche besonders qBittorrent, Sonarr und Radarr nicht ungefiltert im Internet.

# Weg A: automatische Installation

## 1. Repository laden

```bash
git clone https://github.com/florianthepro/jellyfin-media-stack.git
cd jellyfin-media-stack
```

Alternativ das ZIP herunterladen, entpacken und in den Ordner wechseln.

## 2. Setup starten

```bash
chmod +x setup.sh
sudo ./setup.sh
```

Das Skript fragt nur nach Angaben, die nicht sinnvoll statisch festgelegt werden können:

- Installationsverzeichnis, Standard `/opt/jellyfin-media-stack`
- Medienverzeichnis, Standard `/srv/media`
- Administratorname
- Administratorkennwort, verdeckte Eingabe mit Wiederholung
- ob Tailscale aktiviert werden soll
- bei Tailscale: Hostname und Auth Key

Im Skript statisch definiert sind:

```bash
TIMEZONE="Europe/Berlin"
REPO_URL="https://github.com/florianthepro/jellyfin-media-stack"
RAW_BASE_URL="https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main"
```

Docker und das Compose-Plugin werden bei Bedarf aus dem offiziellen Docker-APT-Repository installiert. Das Skript kopiert die lokalen Repository-Dateien. Wird nur `setup.sh` bereitgestellt, lädt es die übrigen Dateien über `RAW_BASE_URL`.

Nach der Installation:

```bash
cd /opt/jellyfin-media-stack
./status.sh
```

Die initialen Zugangsdaten stehen ausschließlich root-lesbar in:

```text
/opt/jellyfin-media-stack/credentials.txt
```

# Weg B: vollständige manuelle Installation

Die folgenden Schritte ersetzen `setup.sh` vollständig.

## 1. Variablen festlegen

```bash
export APP_NAME="jellyfin-media-stack"
export INSTALL_DIR="/opt/${APP_NAME}"
export MEDIA_DIR="/srv/media"
export DATA_DIR="${INSTALL_DIR}/data"
export TZ="Europe/Berlin"
export PUID="$(id -u)"
export PGID="$(id -g)"
```

Wenn du als root arbeitest, aber die Mediendateien einem normalen Benutzer gehören sollen, PUID und PGID ausdrücklich setzen, zum Beispiel:

```bash
export PUID=1000
export PGID=1000
```

## 2. Grundpakete installieren

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg jq openssl git
```

## 3. Konfliktpakete entfernen

```bash
for pkg in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" 2>/dev/null || true
done
```

Vorher bestehende Docker-Installationen und deren Daten prüfen. Dieser Schritt ist für einen frischen Host gedacht.

## 4. Offizielles Docker-Repository einrichten

```bash
. /etc/os-release
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
  "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
```

## 5. Docker Engine und Compose installieren

```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
docker --version
sudo docker compose version
```

## 6. Repository installieren

```bash
sudo install -d -m 0755 "$INSTALL_DIR"
sudo cp compose.yaml jellyfin.css status.sh update.sh reset.sh "$INSTALL_DIR/"
sudo chmod 0755 "$INSTALL_DIR"/*.sh
```

Wenn die Dateien noch nicht lokal vorliegen:

```bash
git clone https://github.com/florianthepro/jellyfin-media-stack.git
cd jellyfin-media-stack
sudo install -d -m 0755 "$INSTALL_DIR"
sudo cp compose.yaml jellyfin.css status.sh update.sh reset.sh "$INSTALL_DIR/"
sudo chmod 0755 "$INSTALL_DIR"/*.sh
```

## 7. Medien- und Datenverzeichnisse anlegen

```bash
sudo install -d -m 0755 "$MEDIA_DIR"/{movies,series,downloads}
sudo install -d -m 0755 \
  "$DATA_DIR"/jellyfin/{config,cache} \
  "$DATA_DIR"/seerr/config \
  "$DATA_DIR"/sonarr/config \
  "$DATA_DIR"/radarr/config \
  "$DATA_DIR"/qbittorrent/config \
  "$DATA_DIR"/filebrowser/{database,config} \
  "$DATA_DIR"/tailscale/state
sudo chown -R "$PUID:$PGID" "$MEDIA_DIR" "$DATA_DIR"
```

## 8. `.env` ohne Tailscale erstellen

```bash
sudo tee "$INSTALL_DIR/.env" >/dev/null <<EOF_ENV
TZ=$TZ
PUID=$PUID
PGID=$PGID
MEDIA_DIR=$MEDIA_DIR
DATA_DIR=$DATA_DIR
TAILSCALE_HOSTNAME=media-server
TAILSCALE_AUTHKEY=
COMPOSE_PROFILES=
EOF_ENV
sudo chmod 600 "$INSTALL_DIR/.env"
```

## 9. `.env` mit Tailscale erstellen

Nur verwenden, wenn Tailscale gewünscht ist. Den Auth Key nicht in Git speichern.

```bash
read -r -s -p "Tailscale Auth Key: " TAILSCALE_AUTHKEY
echo
sudo tee "$INSTALL_DIR/.env" >/dev/null <<EOF_ENV
TZ=$TZ
PUID=$PUID
PGID=$PGID
MEDIA_DIR=$MEDIA_DIR
DATA_DIR=$DATA_DIR
TAILSCALE_HOSTNAME=media-server
TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY
COMPOSE_PROFILES=tailscale
EOF_ENV
sudo chmod 600 "$INSTALL_DIR/.env"
unset TAILSCALE_AUTHKEY
```

Für einen einzelnen Server ist ein einmal verwendbarer Tailscale Auth Key sinnvoller als ein wiederverwendbarer Schlüssel. Wiederverwendbare Schlüssel müssen besonders geschützt werden.

## 10. Compose prüfen und starten

```bash
cd "$INSTALL_DIR"
sudo docker compose config -q
sudo docker compose pull
sudo docker compose up -d --remove-orphans
sudo docker compose ps
```

## 11. File Browser initialisieren

Ersetze `ADMIN_NAME` und gib das Kennwort interaktiv in der Shell ein:

```bash
read -r -p "Administratorname: " ADMIN_NAME
read -r -s -p "Administratorkennwort: " ADMIN_PASSWORD
echo
sudo docker exec filebrowser filebrowser config init \
  -d /database/filebrowser.db -r /srv -a 0.0.0.0 -p 80 || true
sudo docker exec filebrowser filebrowser users add \
  "$ADMIN_NAME" "$ADMIN_PASSWORD" --perm.admin \
  -d /database/filebrowser.db
unset ADMIN_PASSWORD
```

## 12. Jellyfin einrichten

Öffne:

```text
http://SERVER-IP:8096
```

Im Assistenten:

1. Administratorkonto anlegen.
2. Bibliothek `Filme` mit `/media/movies` anlegen.
3. Bibliothek `Serien` mit `/media/series` anlegen.
4. Sprache und Metadatenland auf Deutsch/Deutschland setzen.
5. Automatische Router-Portfreigaben deaktiviert lassen.
6. Optional `jellyfin.css` unter Dashboard, Allgemein, Benutzerdefiniertes CSS einfügen.

## 13. qBittorrent einrichten

Öffne:

```text
http://SERVER-IP:8080
```

Das temporäre Kennwort steht beim ersten Start in den Logs:

```bash
cd "$INSTALL_DIR"
sudo docker compose logs qbittorrent | grep -i -A3 password
```

Danach sofort:

1. eigenes starkes Kennwort setzen
2. Standard-Speicherpfad `/downloads` setzen
3. unfertige Downloads bei Bedarf unter `/downloads/incomplete` ablegen
4. Weboberfläche nicht öffentlich freigeben

## 14. Sonarr konfigurieren

Öffne `http://SERVER-IP:8989`.

1. Root Folder `/tv` hinzufügen.
2. qBittorrent als Download Client ergänzen.
3. Host `qbittorrent`, Port `8080` verwenden.
4. Kategorie zum Beispiel `sonarr` wählen.
5. Authentifizierung der Sonarr-Weboberfläche aktivieren.

## 15. Radarr konfigurieren

Öffne `http://SERVER-IP:7878`.

1. Root Folder `/movies` hinzufügen.
2. qBittorrent als Download Client ergänzen.
3. Host `qbittorrent`, Port `8080` verwenden.
4. Kategorie zum Beispiel `radarr` wählen.
5. Authentifizierung der Radarr-Weboberfläche aktivieren.

## 16. Seerr konfigurieren

Öffne `http://SERVER-IP:5055`.

1. Mit Jellyfin verbinden.
2. Jellyfin intern über `http://jellyfin:8096` ansprechen.
3. Sonarr über `http://sonarr:8989` verbinden.
4. Radarr über `http://radarr:7878` verbinden.
5. Bibliotheken und Qualitätsprofile auswählen.

# Bedienung

## Status und Logs

```bash
cd /opt/jellyfin-media-stack
sudo ./status.sh
```

Gezielte Logs:

```bash
sudo docker compose logs -f jellyfin
sudo docker compose logs -f seerr
sudo docker compose logs -f sonarr
sudo docker compose logs -f radarr
sudo docker compose logs -f qbittorrent
sudo docker compose logs -f filebrowser
sudo docker compose logs -f tailscale
```

## Aktualisieren

```bash
cd /opt/jellyfin-media-stack
sudo ./update.sh
```

Das lädt neue Images, startet geänderte Container neu und entfernt ungenutzte Images. Konfigurationen und Medien bleiben bestehen.

## Stoppen und starten

```bash
cd /opt/jellyfin-media-stack
sudo docker compose stop
sudo docker compose start
```

## Reset

```bash
cd /opt/jellyfin-media-stack
sudo ./reset.sh
```

`reset.sh` löscht die Container-Konfiguration unter `data/`, aber nicht die Medien unter `/srv/media`. Es verlangt bewusst die Eingabe `RESET`.

# Weboberflächen

- Jellyfin: `http://SERVER-IP:8096`
- Seerr: `http://SERVER-IP:5055`
- Sonarr: `http://SERVER-IP:8989`
- Radarr: `http://SERVER-IP:7878`
- qBittorrent: `http://SERVER-IP:8080`
- File Browser: `http://SERVER-IP:8091`

# Backup

Vor Änderungen oder Updates:

```bash
cd /opt/jellyfin-media-stack
sudo docker compose stop
sudo tar -C /opt -czf "/root/jellyfin-media-stack-$(date +%F).tar.gz" jellyfin-media-stack
sudo docker compose start
```

Die Medien liegen standardmäßig separat unter `/srv/media` und brauchen eine eigene Backup-Strategie.

# Sicherheitshinweise

- `.env` und `credentials.txt` müssen Modus `600` behalten.
- Tailscale Auth Keys nie committen oder in Screenshots veröffentlichen.
- Keine Administrationsoberfläche ungefiltert aus dem Internet erreichbar machen.
- Für öffentlichen Zugriff Reverse Proxy, HTTPS und zusätzliche Zugriffskontrolle verwenden.
- Tailscale Funnel veröffentlicht einen Dienst im Internet. Für privaten Zugriff stattdessen Tailscale Serve oder den direkten Tailnet-Zugriff verwenden.
- Regelmäßig `./update.sh` ausführen und Logs prüfen.
- Das Docker-Daemon-Socket wird bewusst in keinen Container eingebunden.

# Fehlerbehebung

## Port bereits belegt

```bash
sudo ss -lntup | grep -E ':(5055|7878|8080|8091|8096|8989|6881)\b'
```

## Rechteproblem

```bash
cd /opt/jellyfin-media-stack
set -a
. ./.env
set +a
sudo chown -R "$PUID:$PGID" "$DATA_DIR" "$MEDIA_DIR"
sudo docker compose restart
```

## Compose-Datei prüfen

```bash
cd /opt/jellyfin-media-stack
sudo docker compose config
```

## Container neu erstellen

```bash
cd /opt/jellyfin-media-stack
sudo docker compose up -d --force-recreate
```

## Tailscale prüfen

```bash
cd /opt/jellyfin-media-stack
sudo docker compose logs tailscale
sudo docker exec tailscale tailscale status
```
