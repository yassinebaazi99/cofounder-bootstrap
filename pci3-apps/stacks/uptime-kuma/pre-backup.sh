#!/bin/bash
# Online, consistent copy of Kuma's SQLite database before restic runs (a raw copy of a live db can be torn).
set -euo pipefail
cd "$(dirname "$0")"
[ -f data/kuma.db ] || exit 0
docker run --rm -v "$(pwd)/data:/data" keinos/sqlite3 sqlite3 /data/kuma.db ".backup '/data/kuma-backup.db'"
