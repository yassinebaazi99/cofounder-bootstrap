# cofounder-bootstrap

One PowerShell script that turns a fresh Windows 10/11 PC into the always-on CoFounder server:
the BullMQ worker as a Windows service, remote access over Tailscale + OpenSSH (+ Remote Desktop
on Pro), a heartbeat, power and update settings that keep it up, and Claude Code + GitHub CLI so
the box can run agents. The script holds no secrets; the private application repo is cloned by
the script after `gh auth login`.

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
2. Log Claude Code in once: `cd C:\srv\cofounder\repo; claude`
3. Watch the worker: `Get-Content C:\srv\cofounder\logs\worker.log -Tail 50 -Wait`
   The proof is `Processing agent run` followed by `Agent run finished`, not `Worker ready`.
4. Then stop the Fly machine and the laptop worker. One owner of the agent queue.

## Reach it from anywhere

Install Tailscale on the laptop (`winget install Tailscale.Tailscale`), log in to the same
tailnet, then:

```powershell
ssh <windows-user>@cofounder-srv
```

Remote Desktop (Pro only, `-EnableRdp`) works over the same tailnet address, and a Claude Code
session started inside a Remote Desktop session survives disconnects.

## Update after a push to main

```powershell
C:\srv\cofounder\tools\update-worker.ps1
```

Pulls fast-forward, rebuilds the worker, restarts the service, shows the log tail.
