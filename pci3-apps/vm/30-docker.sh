#!/bin/bash
# Step 11: Docker Engine + Compose, data-root on /srv, address pool 10.200.0.0/16 (never the host's 10.28.0.0/24),
# and dockerd refuses to start until /srv is mounted (RequiresMountsFor) so a missing data disk cannot shadow /srv.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update; apt-get -y install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 10 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
mountpoint -q /srv
mkdir -p /srv/docker /etc/docker /etc/systemd/system/docker.service.d
install -m 0644 /home/ops/stage/daemon.json /etc/docker/daemon.json
printf '[Unit]\nRequiresMountsFor=/srv\n' > /etc/systemd/system/docker.service.d/mounts.conf
apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker ops
systemctl daemon-reload
systemctl enable --now docker
docker info --format '{{.ServerVersion}} root={{.DockerRootDir}} live-restore={{.LiveRestoreEnabled}}'
docker compose version
echo "bridge subnet: $(docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}')"
docker run --rm hello-world | head -2
echo DOCKER-DONE
