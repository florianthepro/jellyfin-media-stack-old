# Jellyfin Media Stack

Docker-Compose-Stack für Jellyfin, Seerr, Sonarr, Radarr, qBittorrent und optional Tailscale.

<details>

<summary>Dienste && Voraussetzungen</summary>

## Voraussetzungen

- Debian oder Ubuntu
- Root- oder sudo-Zugriff
- Internetzugang
- freie Ports `5055`, `7878`, `8080`, `8096`, `8989` und `6881/tcp+udp`
- optional ein Tailscale Auth Key

## Dienste

- Jellyfin: Port `8096`
- Seerr: Port `5055`
- Sonarr: Port `8989`
- Radarr: Port `7878`
- qBittorrent: Port `8080`
- BitTorrent-Peer-Port: `6881/tcp` und `6881/udp`
- Tailscale: optionales Compose-Profil `tailscale`

Laufzeitdaten werden unter `/opt/jellyfin-media-stack/data` gespeichert.
Medien liegen standardmäßig unter `/srv/media`. `.env`.
Laufzeitdaten, Protokolle und ZIP-Dateien werden durch `.gitignore` ausgeschlossen.

</details>

<details>

<summary>Automatische Installation</summary>

# Automatische Installation

## Repository laden && Setup ausführen

```bash
git clone https://github.com/florianthepro/jellyfin-media-stack.git
cd jellyfin-media-stack
chmod +x setup.sh
sudo ./setup.sh
```

Anzupassende Werte:

Jellyfin-Administratorname
Jellyfin-Administratorkennwort
Aktivierung von Tailscale
Tailscale-Hostname und Auth Key bei aktivierter Tailscale-Option


Installationsstatus:

```bash
cd /opt/jellyfin-media-stack
sudo ./status.sh
```

Initiale Zugangsdaten:

```text
/opt/jellyfin-media-stack/credentials.txt
```

Die Datei wird mit Berechtigung `600` erstellt.

Schritte && Statisch `setup.sh` Werte:

1. Prüfung auf Debian oder Ubuntu.
2. Installation der Grundpakete.
3. Installation von Docker Engine und Docker Compose, falls erforderlich.
4. Erstellung der Medien- und Datenverzeichnisse.
5. Erstellung der Datei `.env`.
6. Prüfung der Compose-Konfiguration.
7. Download und Start der Container.
8. Grundkonfiguration von Jellyfin, soweit über die Startup-API möglich.
9. Erstellung der Dateien `credentials.txt`, `status.sh`, `update.sh` und `reset.sh`.

```bash
TIMEZONE="Europe/Berlin"
REPO_URL="https://github.com/florianthepro/jellyfin-media-stack"
RAW_BASE_URL="https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack/main"
```
```txt
Installationsverzeichnis, Standard: `/opt/jellyfin-media-stack`
Medienverzeichnis, Standard: `/srv/media`
```

</details>

<details>

<summary>Manuelle Installation</summary>

# Manuelle Installation

Die folgenden Schritte führen zur gleichen Verzeichnis- und Compose-Struktur wie `setup.sh`.

## Variablen

```bash
export APP_NAME="jellyfin-media-stack"
export INSTALL_DIR="/opt/${APP_NAME}"
export MEDIA_DIR="/srv/media"
export DATA_DIR="${INSTALL_DIR}/data"
export TZ="Europe/Berlin"
export PUID=1000
export PGID=1000
```

`PUID` und `PGID` müssen dem Benutzer entsprechen, dem die Konfigurations- und Mediendateien gehören sollen.

## Grundpakete

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg jq openssl git
```

## Konfliktpakete entfernen

Dieser Schritt ist für eine Neuinstallation vorgesehen. Bei einer vorhandenen Docker-Installation müssen bestehende Container und Daten vorher geprüft werden.

```bash
for pkg in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" 2>/dev/null || true
done
```

## Docker-Repository einrichten

```bash
. /etc/os-release
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
  "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
```

## Docker installieren

```bash
sudo apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
sudo systemctl enable --now docker
sudo docker compose version
```

## Repository-Dateien installieren

```bash
sudo install -d -m 0755 "$INSTALL_DIR"
sudo cp compose.yaml jellyfin.css status.sh update.sh reset.sh "$INSTALL_DIR/"
sudo chmod 0755 "$INSTALL_DIR"/*.sh
```

## Verzeichnisse anlegen

```bash
sudo install -d -m 0755 "$MEDIA_DIR"/{movies,series,downloads}
sudo install -d -m 0755 \
  "$DATA_DIR"/jellyfin/{config,cache} \
  "$DATA_DIR"/seerr/config \
  "$DATA_DIR"/sonarr/config \
  "$DATA_DIR"/radarr/config \
  "$DATA_DIR"/qbittorrent/config \
  "$DATA_DIR"/tailscale/state
sudo chown -R "$PUID:$PGID" "$MEDIA_DIR" "$DATA_DIR"
```

## `.env` ohne Tailscale

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

## `.env` mit Tailscale

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

Der Tailscale Auth Key darf nicht im Repository gespeichert werden.

## Compose prüfen und starten

```bash
cd "$INSTALL_DIR"
sudo docker compose config -q
sudo docker compose pull
sudo docker compose up -d --remove-orphans
sudo docker compose ps
```

# Dienstkonfiguration

## Jellyfin

Adresse:

```text
http://SERVER-IP:8096
```

Konfiguration:

1. Administratorkonto anlegen.
2. Bibliothek `Filme` mit dem Pfad `/media/movies` anlegen.
3. Bibliothek `Serien` mit dem Pfad `/media/series` anlegen.
4. Sprache und Metadatenland festlegen.
5. Automatische Router-Portfreigaben deaktiviert lassen.
6. Optional den Inhalt von `jellyfin.css` unter `Dashboard > Allgemein > Benutzerdefiniertes CSS` einfügen.

## qBittorrent

Adresse:

```text
http://SERVER-IP:8080
```

Temporäres Kennwort auslesen:

```bash
cd /opt/jellyfin-media-stack
sudo docker compose logs qbittorrent | grep -i -A3 password
```

Konfiguration:

1. Administratorkennwort ändern.
2. Downloadpfad auf `/downloads` setzen.
3. Optional `/downloads/incomplete` für unvollständige Downloads verwenden.

## Sonarr

Adresse:

```text
http://SERVER-IP:8989
```

Konfiguration:

1. Root Folder `/tv` hinzufügen.
2. qBittorrent als Download Client hinzufügen.
3. Host `qbittorrent` und Port `8080` verwenden.
4. Kategorie `sonarr` festlegen.
5. Authentifizierung für die Weboberfläche aktivieren.

## Radarr

Adresse:

```text
http://SERVER-IP:7878
```

Konfiguration:

1. Root Folder `/movies` hinzufügen.
2. qBittorrent als Download Client hinzufügen.
3. Host `qbittorrent` und Port `8080` verwenden.
4. Kategorie `radarr` festlegen.
5. Authentifizierung für die Weboberfläche aktivieren.

## Seerr

Adresse:

```text
http://SERVER-IP:5055
```

Interne Adressen:

```text
Jellyfin: http://jellyfin:8096
Sonarr:   http://sonarr:8989
Radarr:   http://radarr:7878
```

Jellyfin, Sonarr und Radarr werden anschließend mit ihren jeweiligen Zugangsdaten beziehungsweise API-Schlüsseln verbunden.

</details>

<details>

<summary>Betrieb</summary>

# Betrieb

## Status und Logs

```bash
cd /opt/jellyfin-media-stack
sudo ./status.sh
```

Dienstepezifische Logs:

```bash
sudo docker compose logs -f jellyfin
sudo docker compose logs -f seerr
sudo docker compose logs -f sonarr
sudo docker compose logs -f radarr
sudo docker compose logs -f qbittorrent
sudo docker compose logs -f tailscale
```

## Aktualisierung

```bash
cd /opt/jellyfin-media-stack
sudo ./update.sh
```

`update.sh` lädt aktuelle Images, aktualisiert die Container und entfernt nicht mehr verwendete Images.

## Stoppen und starten

```bash
cd /opt/jellyfin-media-stack
sudo docker compose stop
sudo docker compose start
```

## Zurücksetzen

```bash
cd /opt/jellyfin-media-stack
sudo ./reset.sh
```

`reset.sh` entfernt Container-Konfigurationen unter `data/`. Mediendateien unter `/srv/media` bleiben erhalten. Die Ausführung erfordert die Eingabe `RESET`.

</details>

<details>

<summary>Backup</summary>

# Backup

```bash
cd /opt/jellyfin-media-stack
sudo docker compose stop
sudo tar -C /opt \
  -czf "/root/jellyfin-media-stack-$(date +%F).tar.gz" \
  jellyfin-media-stack
sudo docker compose start
```

Die Medien unter `/srv/media` sind nicht Bestandteil dieses Backups.

</details>

<details>

<summary>Sicherheit</summary>

# Sicherheit

- `.env` und `credentials.txt` mit Berechtigung `600` speichern.
- Tailscale Auth Keys nicht committen oder protokollieren.
- Verwaltungsoberflächen nicht direkt im Internet veröffentlichen.
- Für externen Zugriff HTTPS und Zugriffskontrolle verwenden.
- Container-Images regelmäßig aktualisieren.
- Das Docker-Socket wird nicht in Container eingebunden.

</details>

<details>

<summary>Fehlerbehebung</summary>

# Fehlerbehebung

## Belegte Ports prüfen

```bash
sudo ss -lntup | grep -E ':(5055|7878|8080|8096|8989|6881)\b'
```

## Rechte korrigieren

```bash
cd /opt/jellyfin-media-stack
set -a
. ./.env
set +a
sudo chown -R "$PUID:$PGID" "$DATA_DIR" "$MEDIA_DIR"
sudo docker compose restart
```

## Compose-Konfiguration prüfen

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

</details>
