# [Automatische Installation](../README.md)

## Repository laden && Setup ausführen

```bash
git clone https://github.com/florianthepro/jellyfin-media-stack.git
cd jellyfin-media-stack
chmod +x setup.sh
sudo ./setup.sh
```
```bash
cd ~ && git clone https://github.com/florianthepro/jellyfin-media-stack.git && cd jellyfin-media-stack && git pull https://github.com/florianthepro/jellyfin-media-stack.git && chmod +x v2-setup.sh && sudo ./v2-setup.sh
```

---

Anzupassende Werte:

- Jellyfin-Administratorname
- Jellyfin-Administratorkennwort
- Aktivierung von Tailscale
- Tailscale-Hostname und Auth Key bei aktivierter Tailscale-Option

Optional Anzupassende Werte:

- Installationsverzeichnis, Standard: `/opt/jellyfin-media-stack`
- Medienverzeichnis, Standard: `/srv/media`

---

Installationsstatus:

```bash
cd /opt/jellyfin-media-stack
sudo ./status.sh
```

---

Initiale Zugangsdaten:

```text
/opt/jellyfin-media-stack/credentials.txt
```

Die Datei wird mit Berechtigung `600` erstellt.

---

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
