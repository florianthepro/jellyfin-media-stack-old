#!/usr/bin/env bash
##!/bin/sh
#start with: curl -sSL https://raw.githubusercontent.com/florianthepro/jellyfin-enhanced-setup/main/setup.sh | bash
set -euo pipefail
cd /home/$(whoami)

ask() {
printf "%s" "$1" >/dev/tty
IFS= read -r REPLY </dev/tty
}

name=$(hostname)
addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
username="$(whoami)"

clear

echo "     goto https://login.tailscale.com/admin/settings/keys     >press Generate auth key...     >press Pre-approved      >press Generate Key"

ask "Enter your Auth Key: "
tsauthkey="$REPLY"

sudo apt update -y
sudo apt upgrade -y

sudo mkdir -p ~/media/{music,video,books}
sudo mkdir -p ~/docker/{jellyfin,seerr,sonarr,radarr,qbittorrent}
sudo mkdir -p ~/docker/seerr/config

sudo curl -L https://raw.githubusercontent.com/florianthepro/jellyfin-enhanced-setup/main/compose.yaml -o ~/docker/compose.yaml

sudo sed -i "s/fill-usr/$username/g" ~/docker/compose.yaml
sudo sed -i "s/fill-key/$tsauthkey/g" ~/docker/compose.yaml
sudo sed -i "s/fill-hostname/$name/g" ~/docker/compose.yaml

#test it
mkdir -p ~/docker/filebrowser
touch ~/docker/filebrowser/filebrowser.db
[ -f ~/docker/filebrowser/.filebrowser.json ] || echo '{}' > ~/docker/filebrowser/.filebrowser.json

#===== docker =====
# Voraussetzungen
sudo apt update -qq -y
sudo apt install -qq -y ca-certificates curl gnupg jq
# Keyring-Verzeichnis
sudo install -m 0755 -d /etc/apt/keyrings
# GPG-Key (mit Pipe!)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
# Leserechte für APT
sudo chmod a+r /etc/apt/keyrings/docker.gpg
# Repo (mit Pipe!)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
# Docker installieren
sudo apt update -qq -y
sudo apt install -qq -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# User der docker-Gruppe hinzufügen (kein newgrp im Skript)
sudo usermod -aG docker "$username"
#newgrp docker
#solved by compose test it
#sudo chown -R 1000:1000 /home/$username/docker/seerr/config
clear
sudo docker compose -f /home/$username/docker/compose.yaml up -d
#===== docker =====

echo ""

until sudo docker exec tailscale tailscale status --json >/dev/null 2>&1; do
  sleep 2
done

#Tailcale Version: V1.96.4

# Funnel korrekt

# Jellyfin öffentlich über 443 (kein Port in der URL), lokales Ziel ist HTTP:8096
sudo docker exec tailscale tailscale funnel --bg --https=443  http://127.0.0.1:8096

# Filebrowser öffentlich über 8443 (Port sichtbar), lokales Ziel ist HTTP:8091
sudo docker exec tailscale tailscale funnel --bg --https=8443 http://127.0.0.1:8091
tcaddr="$(sudo docker exec tailscale tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"

: <<'TEST01OLD'
sudo docker exec tailscale tailscale funnel --bg 8091 http 127.0.0.1:8091
sudo docker exec tailscale tailscale funnel -bg 8096 # test it
tcaddr=$(docker exec tailscale tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
TEST01OLD

echo ""
sleep 5

: <<'LINKS'
nur interne notiz
jellyfin via tailscale: https://$tcaddr
jellyfin: http://$addr:8096/
seerr: http://$addr:5055/
sonarr: http://$addr:8989/
radarr: http://$addr:7878/
qbittorrent: http://$addr:8080/
filebrowser: http://$addr:8091/
LINKS

#wizard
clear
echo "go to https://$tcaddr"
echo "complete setup wizard"
ask "done?"

#css
clear
echo "go to https://$tcaddr"
echo ">login     >user icon      >admin dashbourd     >press Left Side Branding     >add costum css"
echo "CSS:"
cat <<'END'
@import url('https://cdn.jsdelivr.net/gh/florianthepro/jellyfin-enhanced-setup@main/jellyfin.css');
END
ask "done?"

clear
#Nutzer‑Login via Jellyfin
#Library‑Sync
#jellyfin enhanced plugin
#jellyfin webhook plugin

#get jellyfin api key
clear
echo "go to https://$tcaddr"
echo ">login     >user icon      >admin dashbourd     >press Left Side API-Keys     >create and copy key"
ask "Enter your API Key: "
jfapi="$REPLY"

#get sonarr api key
clear
echo "go to http://$addr:8989/"
echo ">login     >Settings      >General     >Security     >API Key"
ask "Enter your API Key: "
sonarrapi="$REPLY"

#get radarr api key
clear
echo "go to http://$addr:7878/"
echo ">login     >Settings      >General     >Security     >API Key"
ask "Enter your API Key: "
radarrapi="$REPLY"

#link jellyfin in seerr
clear
echo "go to http://$addr:5055/"
echo ">login     >Settings      >Media server     >Jellyfin"
echo "url: http://jellyfin:8096"
echo "api key: $jfapi"
ask "done?"

#link sonarr in seerr
clear
echo "go to http://$addr:5055/"
echo ">login     >Settings      >Dienste(Services)     >Sonarr"
echo "url: http://sonarr:8989"
echo "api key: $sonarrapi"
echo "Standard‑Qualitätsprofil, Root‑Folder"
ask "done?"

#link radarr in seerr
clear
echo "go to http://$addr:5055/"
echo ">login     >Settings      >Dienste(Services)     >Radarr"
echo "url: http://radarr:7878"
echo "api key: $radarrapi"
echo "Standard‑Qualitätsprofil, Root‑Folder"
ask "done?"

#link qbittorrent in sonarr
clear
echo "go to http://$addr:8989/"
echo ">login     >Settings      >Download Clients     >Add"
echo "Type: qBittorrent"
echo "Host: qbittorrent"
echo "Port: 8080"
echo "User/Pass: admin / adminadmin"
echo "Category: tv / sonarr"
ask "done?"

#link qbittorrent in radarr
clear
echo "go to http://$addr:7878/"
echo ">login     >Settings      >Download Clients     >Add"
echo "Type: qBittorrent"
echo "Host: qbittorrent"
echo "Port: 8080"
echo "User/Pass: admin / adminadmin"
echo "Category: movies / sonarr"
ask "done?"

#link jellyfin in seerr
clear
echo "go to http://$addr:5055/"
echo ">login     >Settings      >Connect     >Add     >Emby"
echo "URL: http://jellyfin:8096"
echo "API‑Key: $jfapi"
echo "Events: Enable On Download/On Upgrade"
ask "done?"

cat <<'TESTIT'

# 1) Docker-Stack steht?
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 2) Tailscale bereit & Funnel aktiv?
sudo docker exec tailscale tailscale status
sudo docker exec tailscale tailscale funnel status

# 3) Öffentliche URL(s)
tcaddr="$(sudo docker exec tailscale tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
echo "Jellyfin:    https://${tcaddr}/"
echo "Filebrowser: https://${tcaddr}:8443/"
TESTIT
