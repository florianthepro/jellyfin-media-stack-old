#!/usr/bin/env bash
##!/bin/sh     #start with: curl -sSL https://raw.githubusercontent.com/florianthepro/public/main/jellyfin-enhanced-setup/tst00.sh | bash
curl -sSL https://raw.githubusercontent.com/florianthepro/public/main/jellyfin-enhanced-setup/reset.sh | sudo bash
clear
set -euo pipefail
cd /home/$(whoami)
ask() {
printf "%s" "$1" >/dev/tty
IFS= read -r REPLY </dev/tty
}
name=$(hostname)
addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
username="$(whoami)"

echo ">go to https://login.tailscale.com/admin/settings/keys"
echo ">press Generate auth key..."
echo ">press Pre-approved"
echo ">press Generate Key"
ask "Enter your Auth Key: "
tsauthkey="$REPLY"

sudo apt update -y -qq
sudo apt upgrade -y -qq

mkdir -p ~/media/{music,videos,books}
mkdir -p ~/docker/{jellyfin,seerr,sonarr,radarr,qbittorrent}
mkdir -p ~/docker/seerr/config

sudo curl -L https://raw.githubusercontent.com/florianthepro/public/main/jellyfin-enhanced-setup/compose.yaml -o ~/docker/compose.yaml

sudo sed -i "s/fill-usr/$username/g" ~/docker/compose.yaml
sudo sed -i "s/fill-key/$tsauthkey/g" ~/docker/compose.yaml
sudo sed -i "s/fill-hostname/$name/g" ~/docker/compose.yaml


#test it
#mkdir -p ~/docker/filebrowser
#touch ~/docker/filebrowser/filebrowser.db
#[ -f ~/docker/filebrowser/.filebrowser.json ] || echo '{}' > ~/docker/filebrowser/.filebrowser.json

echo "===== set docker ====="
sudo apt update -qq -y
sudo apt install -qq -y ca-certificates curl gnupg jq
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update -qq -y
sudo apt install -qq -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$username"
#newgrp docker
sleep 5
clear
sudo docker compose -f /home/$username/docker/compose.yaml up -d
clear
echo ""
sleep 15
# ===== set docker ===== #

# ===== set qBittorrent password =====
HASH=$(echo -n "adminadmin" | sha256sum | awk '{print "{SHA256}"$1}')
CONFIG_FILE="/home/$username/docker/qbittorrent/config/qBittorrent/qBittorrent.conf"
sleep 5
sudo sed -i "s/WebUI\\\\Username=.*/WebUI\\\\Username=admin/" "$CONFIG_FILE" 2>/dev/null || true
sudo sed -i "s/WebUI\\\\Password_ha=.*/WebUI\\\\Password_ha=$HASH/" "$CONFIG_FILE" 2>/dev/null || true
grep -q "WebUI\\\\Username=" "$CONFIG_FILE" || sudo sh -c "echo 'WebUI\\Username=admin' >> '$CONFIG_FILE'"
grep -q "WebUI\\\\Password_ha=" "$CONFIG_FILE" || sudo sh -c "echo 'WebUI\\Password_ha=$HASH' >> '$CONFIG_FILE'"
sudo docker restart qbittorrent
# ===== set qBittorrent password ===== #

sudo docker exec tailscale tailscale funnel --bg 8096
sudo docker exec tailscale tailscale funnel --bg --https=8443 8091

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

clear
echo "Step 1/4"
echo "go to http://$addr:8096/"
echo "Servername: >jellyfin"
echo "Language: >"
echo ">Next"
echo ""
echo "Username: >admin"
echo "Password: >"
echo ">Next"
echo ""
echo ">Add Mediathek"
echo "Type: >Movies and Series"
echo "Name: >videos"
echo "Folder: >/media/videos"
echo ">Ok"
echo ">Next"
echo ""
echo "Language: >"
echo "Region: >"
echo ">Next"
echo ""
echo "allow external connection: >yes"
echo ">Next"
echo ""
echo ">Fertig"
echo ""
echo ""
echo "Username: >admin"
echo "Password: >"
echo ">Login"
echo ">User icon"
echo ">administration"
echo ">overview"
echo ">Branding"
echo "Costum CSS: >@import url('https://cdn.jsdelivr.net/gh/florianthepro/public@main/jellyfin-enhanced-setup/jellyfin.css');"
ask "done?"
#api keys to 
#echo "Step 03/11"
#echo "go to http://$addr:8096/"
#echo ">login     >user icon      >admin dashbourd     >press Left Side API-Keys     >create and copy key"
#ask "Enter your API Key: "
#jfapi="$REPLY"


#Nutzer‑Login via Jellyfin
#Library‑Sync
#jellyfin enhanced plugin
#jellyfin webhook plugin

clear
echo "Step 2/4"
echo "go to http://$addr:8989/"
echo "Authentication Method: >Forms"
echo "Authentication Required: >Disabled"
echo "Username: >admin"
echo "Password: >"
echo ">Save"
echo ""
echo ">Settings"
echo ">Media Managment"
echo ">Add Root Folder"
echo "Folder: >/videos/"
echo ">Ok"
echo ""
echo ">Settings"
echo ">General"
echo ">Security"
ask "Enter your API Key: "
sonarrapi="$REPLY"
echo ""
echo ">Settings"
echo ">download Clients"
echo ">+"
echo ">qBittorrent"
echo "host: >qbittorrent"
echo "Username: >admin"
echo "Password: >adminadmin"
echo ">Save"
ask "done?"

clear
echo "Step 3/4"
echo "go to http://$addr:7878/"
echo "Authentication Method: >Forms"
echo "Authentication Required: >Disabled"
echo "Username: >admin"
echo "Password: >"
echo ">Save"
echo ""
echo ">Settings"
echo ">Media Managment"
echo ">Add Root Folder"
echo "Folder: >/videos/"
echo ">Ok"
echo ""
echo ">Settings"
echo ">General"
echo ">Security"
ask "Enter your API Key: "
radarrapi="$REPLY"
echo ""
echo ">Settings"
echo ">download Clients"
echo ">+"
echo ">qBittorrent"
echo "host: >qbittorrent"
echo "Username: >admin"
echo "Password: >adminadmin"
echo ">Save"
ask "done?"

clear
echo "Step 4/4"
echo "go to http://$addr:7878/"
echo ">Configure Jellyfin"
echo "Url: >jellyfin"
echo "email adress: >"
echo "Username(von jellyfin): >admin"
echo "Password(von jellyfin): >"
echo ">Sign in"
echo ""
echo ">Sync Libaries"
echo "videos: >yes"
echo ">Start Scan"
echo ">Continue"
echo ""
echo ">Add Radarr Server"
echo ""
echo "Default Server: >yes"
echo "Name: >radarr"
echo "url: >radarr"
echo "api key: >$radarrapi"
echo ">Test"
echo "Quality Profile: >Any"
echo "Root Folder: >/videos"
echo ">Add Server"
echo ""
echo ">Add Sonarr Server"
echo ""
echo "Default Server: >yes"
echo "Name: >sonarr"
echo "url: >sonarr"
echo "api key: >$sonarrapi"
echo ">Test"
echo "Quality Profile: >Any"
echo "Root Folder: >/videos"
echo ">Add Server"
echo ""
echo ">Finish Setup"
echo ""
echo ">Settings"
echo "Streaming Region: >"
echo ">Save Changes"
ask "done?"

: <<'EOF'
echo "Step 11/11"
echo "go to http://$addr:5055/"
echo ">login     >Settings      >Connect     >Add     >Emby"
echo "URL: http://jellyfin:8096"
echo "API‑Key: $jfapi"
echo "Events: Enable On Download/On Upgrade"
ask "done?"



: <<'TEST01OLD'
tcaddr="$(sudo docker exec tailscale tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
sudo docker exec tailscale tailscale funnel --bg 8091 http 127.0.0.1:8091
sudo docker exec tailscale tailscale funnel --bg 8096 # test it

sudo docker exec tailscale tailscale funnel --https=443 8096
sudo docker exec tailscale tailscale funnel --https=8443 8091

sudo docker exec tailscale tailscale funnel --bg --https=443 8096
sudo docker exec tailscale tailscale funnel --bg --https=8443 8091

tcaddr=$(docker exec tailscale tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
TEST01OLD

#=====testing=====

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
EOF
