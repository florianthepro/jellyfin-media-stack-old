# [Jellyfin Media Stack](README.md)

Docker-Compose-Stack für Jellyfin, Seerr, Sonarr, Radarr, qBittorrent und optional Tailscale. [Dienste && Voraussetzungen](INSTALLATION/Dienste_&&_Voraussetzungen.md)


# Installation

```
curl -fsSL https://raw.githubusercontent.com/florianthepro/jellyfin-media-stack-old/main/installation/bash/v2-setup.sh | sudo bash
```
---
# Funnel
```
sudo docker exec tailscale tailscale funnel --bg --https=443 http://127.0.0.1:8096
sudo docker exec tailscale tailscale funnel --bg --https=8443 http://127.0.0.1:5055
```
---
# Cloudflare zusätzlich bei bedarf:

```
Im Cloudflare-Dashboard:

Zero Trust öffnen
Networks → Tunnels
Create a tunnel
Typ Cloudflared
beispielsweise debian-matrix als Namen vergeben
Bei der Installationsart Docker auswählen
Den angezeigten Tunnel-Token kopieren
```
auf dem host:
```
cd /opt/jellyfin-media-stack/
```
```
sudo micro compose.yaml
```
darunter ergänzen
```
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
```
dann env setzen
```
sudo micro .env
```
darunter ergänzen:
```
CLOUDFLARE_TUNNEL_TOKEN=#DEIN_TUNNEL_TOKEN
```
dann
```
sudo chmod 600 .env && sudo docker compose up -d cloudflared
```
test:
```
sudo docker logs cloudflared --tail 50
```
Subdomains im Cloudflare-Dashboard zuordnen

Beim Tunnel unter Public Hostnames beziehungsweise Routes → Published applications:
```
Subdomain: jellyfin
Domain: deinedomain.de
Type: HTTP
URL: jellyfin:8096

und

Subdomain: seerr
Domain: deinedomain.de
Type: HTTP
URL: seerr:5055
```
