#!/bin/bash
# Step 12: the stack convention under /srv/stacks, Uptime Kuma as the first app, the alive + prune timers,
# tailnet exposure with tailscale serve, and /srv/stacks as a git repo.
set -euo pipefail
mkdir -p /srv/stacks/uptime-kuma /etc/apps
cp /home/ops/stage/stacks/gitignore /srv/stacks/.gitignore
cp /home/ops/stage/stacks/README.md /srv/stacks/README.md
cp /home/ops/stage/stacks/uptime-kuma/compose.yml /srv/stacks/uptime-kuma/compose.yml
install -m 0755 /home/ops/stage/stacks/uptime-kuma/pre-backup.sh /srv/stacks/uptime-kuma/pre-backup.sh
install -m 0755 /home/ops/stage/apps-status.sh /usr/local/bin/apps-status
install -m 0755 /home/ops/stage/apps-alive.sh /usr/local/bin/apps-alive
install -m 0644 /home/ops/stage/units/apps-alive.service /home/ops/stage/units/apps-alive.timer /home/ops/stage/units/docker-prune.service /home/ops/stage/units/docker-prune.timer /etc/systemd/system/
systemctl daemon-reload; systemctl enable --now apps-alive.timer docker-prune.timer
cd /srv/stacks/uptime-kuma && docker compose up -d && sleep 15 && docker compose ps
tailscale serve --bg --https=8443 http://127.0.0.1:3001
tailscale serve status
cd /srv/stacks && ([ -d .git ] || git init -q) && git add -A && git -c user.name=ops -c user.email=ops@apps commit -qm 'uptime-kuma stack' && git log --oneline | head -1
chown -R ops:ops /srv/stacks/.git /srv/stacks/.gitignore /srv/stacks/README.md /srv/stacks/uptime-kuma/compose.yml /srv/stacks/uptime-kuma/pre-backup.sh 2>/dev/null || true
echo STACKS-DONE
