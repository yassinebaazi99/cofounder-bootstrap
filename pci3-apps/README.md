# pci3-apps: the self-hosting platform on the CoFounder desktop

The desktop `pci3` (DESKTOP-UDO7568, Windows 10 Pro, i3-9100F, 8 GB, C: 120 GB SSD, D: 1 TB HDD) runs
two things: the production `CoFounderWorker` service natively on Windows, and a Hyper-V virtual machine
called **`apps`** (Ubuntu 24.04 + Docker Compose) that hosts everything else: databases, dashboards,
small services. The VM is the "server"; the Windows host is left alone apart from the worker.

Built 2026-09-16/17. Everything here was executed on the real box; the fixes it needed are folded in.

## Topology

```
laptop --tailnet--> pci3.tailfde19f.ts.net  (Windows host, worker, Hyper-V)
                    |  internal switch AppsNAT 10.28.0.0/24  (host 10.28.0.1, NAT to the Wi-Fi uplink)
                    +- VM apps  10.28.0.10  -- tailnet node apps.tailfde19f.ts.net (100.119.99.116)
                         /srv     250 GB  D:\hyperv\disks\apps-data.vhdx    docker data-root + /srv/stacks
                         /backup  120 GB  D:\hyperv\disks\apps-backup.vhdx  restic repository
                         /        40 GB   D:\hyperv\disks\apps-os.vhdx      Ubuntu cloud image
```

Laptop `~/.ssh/config` names: `cofounder-srv-ts` (host over the tailnet), `cofounder-srv` (host over the
home LAN only), `apps` (VM over the tailnet, user `ops`), `apps-nat` (VM at 10.28.0.10 jumping through the
host, for when the VM's Tailscale is down).

## VM shape and why

| Setting | Value | Reason |
| --- | --- | --- |
| Generation | 2, Secure Boot **on**, template Microsoft UEFI CA | Ubuntu's shim is signed by that CA; proven booting |
| vCPU | 2 of 4, cap 75 % | the worker's ffmpeg keeps two cores |
| Memory | dynamic 768 MB min / 1024 start / **2048 max**, buffer 10 % | 8 GB host; the worker peaks at ~305 MB idle, unmeasured busy. Raise the ceiling only after `D:\hyperv\logs\node-peak.txt` shows a busy-period peak |
| Disks | dynamic VHDX, 1 MB blocks, IOPS cap 1500 each | one HDD shared with the worker's temp files |
| Autostart | start after 90 s, stop = guest shutdown | the host reboots Sundays 04:00 for updates |
| Checkpoints | production type, automatic off | never snapshot a database from the host |
| Network | static 10.28.0.10/24 via 10.28.0.1, DNS 1.1.1.1 / 9.9.9.9 | no DHCP inside the NAT |
| Console | COM1 on `\\.\pipe\apps-com1` | last resort only; `serial-read.ps1` hangs over ssh |

## Daily check (read-only)

```
ssh cofounder-srv-ts 'powershell -NoProfile -ExecutionPolicy Bypass -File D:\hyperv\scripts\apps-host-status.ps1'
ssh apps 'sudo apps-status'
```

The host view prints services, hypervisor, VM state, heartbeat, NAT, free memory and disk, the worker peak
and the last telemetry line. The guest view prints mounts, Docker, the stacks, timers and Tailscale.
`https://apps.tailfde19f.ts.net:8443` is Uptime Kuma once Tailscale Serve is enabled (see Owner items).

## Adding an app

1. `ssh apps`, then `mkdir /srv/stacks/<name>` and write `compose.yml`. Bind ports to **127.0.0.1 only**
   (`127.0.0.1:PORT:PORT`), set `mem_limit`, and use a bind mount under the stack directory for data so
   restic sees it. Register the port in `/srv/stacks/README.md`.
2. `docker compose up -d` in that directory.
3. Expose it on the tailnet: `sudo tailscale serve --bg --https=<PORT> http://127.0.0.1:<PORT>` (one
   HTTPS port per app; MagicDNS + HTTPS certificates must be on in the admin console). Only for a public
   app: `tailscale funnel` on 443/8443/10000 after adding the Funnel node attribute in the policy.
4. If the app has a database, add an executable `pre-backup.sh` in the stack directory that writes a
   consistent dump into the data directory (the Kuma one uses `sqlite3 .backup`); the nightly backup runs
   every `/srv/stacks/*/pre-backup.sh` first.
5. `cd /srv/stacks && git add -A && git commit -m "<name> stack"`.

Memory budget: the VM has 2 GB. Postgres or a Node app fits; several at once need the ceiling raised in
`Set-VM apps -MemoryMaximumBytes` on the host, and that is only safe once the worker's busy peak is known.

## Backups and restore

- restic repository `/backup/restic`, password `/etc/restic/password` (root, 0600). **Losing that file
  loses every backup.** Copy it somewhere safe outside the box.
- `apps-backup.timer` nightly around 02:30 UTC: pre-backup hooks, `restic backup /srv/stacks`
  (excluding `*/data/cache`), keep 14 daily / 8 weekly / 6 monthly, 5 % read check. Log:
  `journalctl -u apps-backup.service`.
- Restore one stack: `sudo restic -r /backup/restic -p /etc/restic/password restore latest --target /tmp/r --include /srv/stacks/<name>`
  then copy files back and `docker compose up -d`.
- Whole-VM export: scheduled task `HyperV-Export-apps` every fourth Sunday 06:00 to `D:\hyperv\exports\<date>`
  (keeps one; refuses if D: would drop under 250 GB; waits while ffmpeg runs). Rebuild from it with
  `Import-VM -Path <export>\apps\Virtual Machines\<id>.vmcx -Copy -GenerateNewId`.

## Reboots and updates

- Host: Windows Update policy Sunday 04:00; the VM shuts down cleanly (`AutomaticStopAction ShutDown`,
  `WaitToKillServiceTimeout` 120 s) and restarts 90 s after boot. Before any manual host reboot run
  `D:\hyperv\scripts\worker-idle.ps1` (exit 0 = no ffmpeg, node idle, no open jobs), then
  `Restart-Computer -Force` (without `-Force` Windows refuses because of logged-on users).
- Guest: `unattended-upgrades` installs security updates without rebooting; the Sunday host reboot
  restarts it. A kernel update needs `sudo systemctl reboot` from `ssh apps`.
- Docker: `docker-prune.timer` Saturdays 03:00 prunes unused images.

Proof runs: host forced reboot with the VM autostarting and Kuma healthy again without a hand on the
keyboard (2026-09-17); guest reboot keeps `/srv` and `/backup` mounted and the Hyper-V daemons active.

## Rebuilding from scratch (host side, in order)

All scripts live in `host/` here and in `D:\hyperv\scripts\` on the box. Run each with
`powershell -NoProfile -ExecutionPolicy Bypass -File <script>` over ssh.

1. `preflight.ps1` (folders, ACL on `D:\hyperv\secrets`, baseline facts) and `install-telemetry.ps1`.
2. Enable Hyper-V: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart`, then
   reboot through the idle gate.
3. `net-setup.ps1` (AppsNAT internal switch, 10.28.0.1/24, NetNat). **Never an External switch on the
   USB Wi-Fi dongle**: it takes the box off the network.
4. On the laptop: download `noble-server-cloudimg-amd64.img`, verify the SHA256SUMS line,
   `qemu-img resize` to 40G, `qemu-img convert -O vhdx -o subformat=dynamic` to `noble-raw.vhdx`;
   build the seed with `seed/make-seed-iso.ps1` (edit `seed/cidata/user-data` for the ssh key).
   `scp` both to `D:\hyperv\images\` and `D:\hyperv\seed\` (rate-limit with `scp -l 40000` while the
   worker is live) and compare `Get-FileHash` with the laptop's hash.
5. `make-disks.ps1` (Convert-VHD to 1 MB blocks, data 250 GB, backup 120 GB), then `new-vm.ps1`,
   then `wait-vm.ps1` until `SSH UP`.
6. Guest, in order, each as a systemd unit so an ssh drop cannot kill apt:
   `scp` the `vm/` and `stacks/` folders to `/home/ops/stage` (flatten `vm/*` into `stage/`), then
   `sudo systemd-run --unit=step --property=StandardOutput=append:/home/ops/step.log --property=StandardError=append:/home/ops/step.log /bin/bash /home/ops/stage/10-baseline.sh`
   and the same for `20-tailscale.sh`, `30-docker.sh`, `40-stacks.sh`, `50-backup.sh`. Reboot the guest
   after 10; run `host/secureboot-test.ps1` after that reboot; `sudo tailscale up --hostname apps` after 20
   and approve the printed URL.
7. `register-export.ps1` on the host.

## Quirks that cost time

- **The host is French Windows: Hyper-V integration service names are localized** ("Pulsation" is
  Heartbeat, "Interface de services d'invite" is Guest Service Interface). Every script matches them by ID
  (`Where-Object Id -like '*84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47*'` for Heartbeat). `-Name Heartbeat` throws.
- A PowerShell command sent over ssh must not contain escaped double quotes; ship a `.ps1` and run it
  with `-File`.
- `tailscale serve` blocks forever until Serve is enabled for the tailnet (a one-time admin console click);
  run it by hand after that, not inside a script.
- Under `set -o pipefail`, `tr </dev/urandom | head -c N` exits 1 (SIGPIPE); generate secrets from a bounded
  read (`head -c 64 /dev/urandom | base64 | tr -dc A-Za-z0-9`).
- Uptime Kuma 2 has no database until its first-visit setup wizard; the backup is tiny until then.
- The LAN alias only works from the home network; the tailnet aliases work from anywhere.

## Owner items (admin console and hardware)

- Tailscale: enable Serve for the tailnet (URL printed by `tailscale serve`), DNS -> HTTPS Certificates,
  Machines -> `apps` and `pci3` -> Disable key expiry.
- First visit to Kuma: choose SQLite, create the admin account; then add a push monitor and paste its URL
  into `D:\hyperv\secrets\kuma-push.txt` on the host so the telemetry service reports the worker.
- BIOS: Restore after AC power loss = Power On, ErP off; an Ethernet cable instead of the USB Wi-Fi dongle;
  a UPS; a DHCP reservation for the host.
- Copy `/etc/restic/password` off the box.
