# /srv/stacks - one folder per app; ports bind 127.0.0.1 only; exposed by tailscale serve/funnel on the VM node "apps"
# port  stack         url
3001    uptime-kuma   https://apps.tailfde19f.ts.net:8443
# reserved: 443 main/landing (Caddy later), 8443 uptime-kuma, 10000 free - the three Funnel-capable ports; 8444+ tailnet-only apps
