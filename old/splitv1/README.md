# Jellyfin Enhanced Setup

Docker-Compose-Stack für Jellyfin, Seerr, Sonarr, Radarr, qBittorrent und File Browser. Tailscale ist optional.

## Start

```bash
cp .env.example .env
nano .env
mkdir -p runtime/{jellyfin/{config,cache},seerr/config,sonarr/config,radarr/config,qbittorrent/config,filebrowser/{database,config}}
sudo mkdir -p /srv/media/{movies,series,downloads}
sudo chown -R "$(id -u):$(id -g)" runtime /srv/media
docker compose config
docker compose pull
docker compose up -d
```

## Öffnen

- Jellyfin: `http://SERVER-IP:8096`
- Seerr: `http://SERVER-IP:5055`
- Sonarr: `http://SERVER-IP:8989`
- Radarr: `http://SERVER-IP:7878`
- qBittorrent: `http://SERVER-IP:8080`
- File Browser: `http://SERVER-IP:8091`

## Einrichten

1. Jellyfin: Bibliotheken `/media/movies` und `/media/series` anlegen.
2. Jellyfin: Inhalt aus `jellyfin.css` unter **Dashboard → Allgemein → Benutzerdefiniertes CSS** einfügen.
3. qBittorrent: Downloadpfad `/downloads` setzen und ein eigenes Kennwort vergeben.
4. Sonarr: Root-Ordner `/media/series`; Download-Client `qbittorrent:8080`.
5. Radarr: Root-Ordner `/media/movies`; Download-Client `qbittorrent:8080`.
6. Seerr: Jellyfin über `http://jellyfin:8096`, Sonarr über `http://sonarr:8989`, Radarr über `http://radarr:7878` verbinden.
7. Nur rechtmäßig verfügbare Medien und Quellen verwenden.

## Tailscale optional

`TAILSCALE_AUTHKEY` in `.env` setzen, dann:

```bash
docker compose --profile remote up -d
```

## Betrieb

```bash
docker compose ps
docker compose logs -f --tail=100
docker compose pull && docker compose up -d
docker compose down
```

## Repository ersetzen

Den Inhalt dieses Ordners in das Ziel-Repository kopieren. Es ist keine fest eingebaute GitHub-Adresse vorhanden.
