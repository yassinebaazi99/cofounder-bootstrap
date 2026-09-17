#!/bin/bash
# Step 10: Tailscale in the VM (its own tailnet node "apps").
set -euo pipefail
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL --retry 10 https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL --retry 10 https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
apt-get update; DEBIAN_FRONTEND=noninteractive apt-get -y install tailscale
systemctl enable --now tailscaled
tailscale version
