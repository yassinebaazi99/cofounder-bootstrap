#!/bin/bash
set -euo pipefail
export RESTIC_REPOSITORY=/backup/restic RESTIC_PASSWORD_FILE=/etc/restic/password
for pre in /srv/stacks/*/pre-backup.sh; do [ -x "$pre" ] && "$pre" || true; done
restic backup /srv/stacks --exclude '/srv/stacks/*/data/cache' --tag nightly
restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 6 --prune
restic check --read-data-subset=5%
[ -s /etc/apps/healthchecks-url-backup ] && curl -fsS -m 10 "$(cat /etc/apps/healthchecks-url-backup)" >/dev/null || true
