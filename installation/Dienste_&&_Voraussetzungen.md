# [Dienste && Voraussetzungen](../README.md)

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
