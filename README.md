# cofounder-bootstrap

One PowerShell script that turns a fresh Windows 10/11 PC into the always-on CoFounder server:
the BullMQ worker as a Windows service, remote access over OpenSSH + Tailscale (+ Remote Desktop
on Pro), a heartbeat, and power and update settings that keep it up. Nothing of Claude is installed
on the box: the laptop's Claude Code session drives it over SSH. The script holds no secrets; the
private application repo is cloned by the script after `gh auth login`.

## Run it on the new PC

Open PowerShell **as administrator** and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
irm https://raw.githubusercontent.com/yassinebaazi99/cofounder-bootstrap/main/provision-windows-server.ps1 -OutFile $env:TEMP\provision.ps1
& $env:TEMP\provision.ps1
```

That first run installs everything, writes `C:\srv\cofounder\repo\.env` as a template with
`REPLACE_ME` markers, and refuses to start the service until they are gone. Then either fill the
template in, or copy the laptop's worker env file onto a USB stick and re-run with it:

```powershell
& $env:TEMP\provision.ps1 -EnvFile D:\.env.cloud -EnableRdp -ComputerName cofounder-srv `
  -TailscaleAuthKey tskey-auth-... -HeartbeatUrl https://hc-ping.com/<uuid> `
  -SshPublicKey "ssh-ed25519 AAAA... you@laptop"
```

Every parameter is optional and every step is idempotent. Re-run after a reboot or after
changing anything. `Get-Help .\provision-windows-server.ps1 -Full` lists the parameters.

To pin a reviewed version instead of `main`, replace `main` in the URL with a commit SHA.

## After it runs

1. Join the tailnet if you did not pass an auth key: `& "C:\Program Files\Tailscale\tailscale.exe" up`
2. Watch the worker: `Get-Content C:\srv\cofounder\logs\worker.log -Tail 50 -Wait`
   The proof is `Processing agent run` followed by `Agent run finished`, not `Worker ready`.
3. Then stop the Fly machine and the laptop worker. One owner of the agent queue.

## Let the laptop's Claude session drive it over SSH

Pass the laptop's public key as `-SshPublicKey` when you run the script; it lands in
`administrators_authorized_keys`. The script prints the exact `ssh <user>@<host>` line at the
end. Paste that line to Claude on the laptop.

- Same Wi-Fi / LAN: works at once, port 22 is open to the local subnet.
- From anywhere else: install Tailscale on the laptop too (`winget install Tailscale.Tailscale`),
  log both machines into the same tailnet, and the same `ssh` line works over the tailnet name.

The remote shell is PowerShell, so Claude runs `Get-Service`, `Get-Content -Tail`, the update
script and anything else the way it would locally. Remote Desktop (Pro only, `-EnableRdp`) is
there for you, not for Claude. Claude Code goes on the box only if you pass `-InstallClaude`.

## Update after a push to main

```powershell
C:\srv\cofounder\tools\update-worker.ps1
```

Pulls fast-forward, rebuilds the worker, restarts the service, shows the log tail.
