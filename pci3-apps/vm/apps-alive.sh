#!/bin/bash
f=/etc/apps/healthchecks-url
[ -s "$f" ] || exit 0
curl -fsS -m 10 --retry 3 "$(cat "$f")" >/dev/null
