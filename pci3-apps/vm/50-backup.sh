#!/bin/bash
# Step 13 (VM half): restic repository on /backup, nightly timer, first backup, restore drill.
set -euo pipefail
mkdir -p /backup/restic /etc/restic
# Password generation without an early-closing reader: the old "tr </dev/urandom | head -c 40" form
# dies under pipefail because head closes the pipe while tr is still writing (SIGPIPE -> exit 1).
if [ ! -s /etc/restic/password ]; then
  pw=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
  printf '%s' "${pw:0:40}" > /etc/restic/password
fi
chmod 600 /etc/restic/password
export RESTIC_REPOSITORY=/backup/restic RESTIC_PASSWORD_FILE=/etc/restic/password
[ -f /backup/restic/config ] || restic init
install -m 0755 /home/ops/stage/apps-backup.sh /usr/local/bin/apps-backup.sh
install -m 0644 /home/ops/stage/units/apps-backup.service /home/ops/stage/units/apps-backup.timer /etc/systemd/system/
systemctl daemon-reload; systemctl enable --now apps-backup.timer
systemctl start apps-backup.service
restic snapshots
systemctl list-timers --no-pager apps-backup.timer | head -3
rm -rf /tmp/restore-test
restic restore latest --target /tmp/restore-test --include /srv/stacks/uptime-kuma
ls /tmp/restore-test/srv/stacks/uptime-kuma && echo DRILL-OK
