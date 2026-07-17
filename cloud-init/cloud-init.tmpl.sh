#!/bin/bash
# Rendered by scripts/02-launch.sh (@@TOKENS@@ are substituted from config.env)
# and passed to the instance as user-data. Runs once on first boot.
set -eux
export DEBIAN_FRONTEND=noninteractive

# --- Host firewall: OCI Ubuntu images ship a restrictive iptables INPUT chain
#     with a catch-all REJECT. Insert our ACCEPTs ABOVE it (find its line #). ---
RJ=$(iptables -L INPUT --line-numbers -n | awk '/REJECT/{print $1; exit}'); RJ=${RJ:-6}
iptables -I INPUT "$RJ" -m state --state NEW -p udp --dport 8211 -j ACCEPT
iptables -I INPUT "$RJ" -m state --state NEW -p tcp --dport 27015 -j ACCEPT
netfilter-persistent save || true

# --- Wait for the boot-time apt/dpkg lock to release before installing ---
for i in $(seq 1 60); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || break
  sleep 5
done

# --- Install Docker (bundles the compose v2 plugin) ---
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
usermod -aG docker ubuntu

# --- Deploy Palworld ---
mkdir -p /home/ubuntu/palworld/data
cat > /home/ubuntu/palworld/docker-compose.yml <<'COMPOSE'
services:
  palworld:
    image: thijsvanloef/palworld-server-docker:latest
    restart: unless-stopped
    container_name: palworld-server
    stop_grace_period: 30s
    ports:
      - "8211:8211/udp"
      - "27015:27015/tcp"
    environment:
      TZ: "@@TZ@@"
@@ARM64_DEVICE_LINE@@
      PLAYERS: "@@PLAYERS@@"
      SERVER_NAME: "@@SERVER_NAME@@"
      SERVER_DESCRIPTION: "@@SERVER_DESCRIPTION@@"
      ADMIN_PASSWORD: "@@ADMIN_PASSWORD@@"
      SERVER_PASSWORD: "@@SERVER_PASSWORD@@"
      PORT: "8211"
      COMMUNITY_SERVER: "@@COMMUNITY_SERVER@@"
      MULTITHREADING: "true"
      RCON_ENABLED: "true"
      RCON_PORT: "25575"
      ADMIN_PASSWORD_RCON: "@@RCON_PASSWORD@@"
      UPDATE_ON_BOOT: "true"
      BACKUP_ENABLED: "true"
      BACKUP_CRON_EXPRESSION: "0 * * * *"
      DELETE_OLD_BACKUPS: "true"
      OLD_BACKUP_DAYS: "7"
    volumes:
      - ./data:/palworld
COMPOSE
chown -R ubuntu:ubuntu /home/ubuntu/palworld
cd /home/ubuntu/palworld && docker compose up -d
