#!/usr/bin/env bash
set -euo pipefail
aggressive=false
user_data=false
while [ $# -gt 0 ]; do
case "$1" in
  --aggressive)
    aggressive=true
    shift
  ;;
  --user-data)
    user_data=true
    shift
  ;;
  *)
    exit 1
  ;;
esac
done
if [ "$(id -u)" -ne 0 ]; then
  exit 1
fi
if command -v docker >/dev/null 2>&1; then
  docker ps -q | xargs -r docker stop
  docker ps -aq | xargs -r docker rm
  docker images -q | xargs -r docker rmi
  if [ "$aggressive" = true ]; then
    docker volume ls -q | xargs -r docker volume rm
    docker network ls --filter "type=custom" -q | xargs -r docker network rm
  fi
fi
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-doc docker-compose podman-docker containerd runc || true
apt-get autoremove -y
apt-get autoclean
rm -rf /var/lib/docker
rm -rf /var/lib/containerd
if [ "$user_data" = true ]; then
  if [ -n "${SUDO_USER-}" ]; then
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  else
    user_home="$HOME"
  fi
  if [ -n "$user_home" ] && [ "$user_home" != "/" ]; then
    rm -rf "$user_home/docker"
    rm -rf "$user_home/media"
  fi
fi
sudo rm -rf *
