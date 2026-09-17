#!/bin/bash
# Step 9: guest baseline. Hyper-V daemons, data (250 GB) + backup (120 GB) disks on ext4, unattended security
# upgrades (no automatic reboot: the host's Sunday reboot restarts the guest), full upgrade once.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
printf 'Acquire::Retries "10";\nAcquire::http::Timeout "60";\n' > /etc/apt/apt.conf.d/80-retries
apt-get update
apt-get -y install linux-cloud-tools-virtual linux-tools-virtual git unattended-upgrades restic curl ca-certificates
systemctl enable --now hv-kvp-daemon.service hv-vss-daemon.service || true
D=$(lsblk -dnb -o NAME,SIZE | awk '$2==268435456000{print $1}')
B=$(lsblk -dnb -o NAME,SIZE | awk '$2==128849018880{print $1}')
echo "data=$D backup=$B"; [ -n "$D" ] && [ -n "$B" ]
blkid "/dev/$D" >/dev/null 2>&1 || mkfs.ext4 -q -L appsdata "/dev/$D"
blkid "/dev/$B" >/dev/null 2>&1 || mkfs.ext4 -q -L appsbackup "/dev/$B"
mkdir -p /srv /backup
grep -q appsdata /etc/fstab || printf 'LABEL=appsdata /srv ext4 defaults,nofail 0 2\nLABEL=appsbackup /backup ext4 defaults,nofail 0 2\n' >> /etc/fstab
systemctl daemon-reload; mount -a
df -h /srv /backup
cat /etc/apt/apt.conf.d/20auto-upgrades
grep -E '^Unattended-Upgrade::Automatic-Reboot ' /etc/apt/apt.conf.d/50unattended-upgrades || echo 'Automatic-Reboot: default (false)'
apt-get -y full-upgrade; apt-get -y autoremove
echo BASELINE-DONE
