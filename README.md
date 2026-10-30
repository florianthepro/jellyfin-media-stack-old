# [Jellyfin Media Stack](README.md)

Docker-Compose-Stack für Jellyfin, Seerr, Sonarr, Radarr, qBittorrent und optional Tailscale. [Dienste && Voraussetzungen](INSTALLATION/Dienste_&&_Voraussetzungen.md)


# Installation

```
curl -fsSL https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack-old/main/installation/bash/v2-setup.sh | sudo bash
```
```
sudo docker exec tailscale tailscale funnel --bg --https=443 http://127.0.0.1:8096
sudo docker exec tailscale tailscale funnel --bg --https=8443 http://127.0.0.1:5055
```
