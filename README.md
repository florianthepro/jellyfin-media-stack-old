# Jellyfin Media Stack

Docker-Compose-Stack für Jellyfin, Seerr, Sonarr, Radarr, qBittorrent und optional Tailscale. [AUTOMATIC INSTALLATION](INSTALLATION/Dienste_&&_Voraussetzungen.md)

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

# Automatische Installation

[AUTOMATIC INSTALLATION](INSTALLATION/AUTOMATIC.md)


# Manuelle Installation

[MANUAL INSTALLATION](INSTALLATION/MANUAL.md)

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
