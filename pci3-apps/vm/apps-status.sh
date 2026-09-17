#!/bin/bash
echo "== $(hostname) $(uptime -p) secureboot=$(mokutil --sb-state 2>/dev/null | tr -d '\n' || echo n/a) =="
free -m | sed -n '1,2p'
df -h / /srv /backup | tail -n +2
echo '-- docker'; docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}'
echo '-- serve'; tailscale serve status 2>/dev/null
echo '-- timers'; systemctl list-timers --no-pager apps-backup.timer apps-alive.timer docker-prune.timer 2>/dev/null | head -5
echo '-- probes'; while read -r p s u; do case "$p" in \#*|'') continue;; esac; printf '%s %s -> %s\n' "$s" "$p" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/")"; done < /srv/stacks/README.md
echo '-- last snapshot'; [ -s /etc/restic/password ] && restic -r /backup/restic --password-file /etc/restic/password snapshots --latest 1 2>/dev/null | tail -2
