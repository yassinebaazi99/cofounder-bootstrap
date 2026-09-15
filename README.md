# cofounder-bootstrap

Turn a Windows 10/11 PC you own into the always-on CoFounder server, and drive it from the
laptop the way you would a rented VPS: over SSH, from anywhere, with nothing of Claude installed
on the box. Two scripts, no secrets in either:

| Script                         | Runs on    | Does                                                                                                                         |
| ------------------------------ | ---------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `provision-windows-server.ps1` | the server | OpenSSH Server + the laptop's key, never sleep, Tailscale; then tooling, repo, `.env`, build, the worker as a Windows service |
| `connect-cofounder-srv.ps1`    | the laptop | Tailscale here, a `Host cofounder-srv` block in `~/.ssh/config`, a connection test                                           |

## 1. On the new PC, two minutes: make it reachable

Open PowerShell **as administrator** and paste:

```powershell
$env:COFOUNDER_ACCESS_ONLY = '1'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
iex (irm https://raw.githubusercontent.com/yassinebaazi99/cofounder-bootstrap/main/provision-windows-server.ps1)
```

That installs OpenSSH Server with PowerShell as the remote shell, authorises the laptop's public
key, opens port 22 to the local network and the tailnet only, turns off sleep, hibernate and fast
startup, installs Tailscale and runs `tailscale up`. A login link is printed: open it on any
device signed in to your Tailscale account. The script ends with two lines:

```
USER: <windows username>
NAME: <name>.<tailnet>.ts.net
```

Give those two values to Claude on the laptop, or run step 2 yourself.

Options for the one-line form are environment variables set before the `iex`:
`COFOUNDER_COMPUTER_NAME=cofounder-srv` (rename, needs a reboot), `COFOUNDER_TAILSCALE_AUTHKEY`
(no browser login), `COFOUNDER_SSH_PUBLIC_KEY` (another laptop's key), `COFOUNDER_ENABLE_RDP=1`
(Pro only). `Get-Help .\provision-windows-server.ps1 -Full` lists everything.

## 2. On the laptop: connect

```powershell
.\connect-cofounder-srv.ps1 -User <USER> -HostName <NAME>
```

Installs Tailscale on the laptop if it is missing (one UAC prompt), joins the same tailnet
(browser login), writes the `Host cofounder-srv` block into `~/.ssh/config`, and proves the
connection by reading the server's hostname, user, Windows edition and sshd state over SSH.
Same Wi-Fi only, no Tailscale: `-HostName <LAN ip> -SkipTailscale`.

From then on, every shell and every Claude Code session on the laptop has the box one command
away, and the remote shell is PowerShell:

```powershell
ssh cofounder-srv "Get-Service CoFounderWorker"
ssh cofounder-srv "Get-Content C:\srv\cofounder\logs\worker.log -Tail 50"
ssh cofounder-srv                       # interactive PowerShell on the server
scp .\file cofounder-srv:C:\srv\cofounder\
```

## 3. From the laptop: install the worker

The rest of the provisioning runs over that SSH connection, so nothing more is typed at the PC.
Copy the worker env file over (it is the same list `docs/deploy-fly.md` step 2 sets on Fly; the
session pooler `:5432` URL, not the API's `:6543` one), then run the full script remotely:

```powershell
scp C:\path\to\.env.cloud cofounder-srv:C:\srv\cofounder\.env.cloud
ssh cofounder-srv "`$env:COFOUNDER_ENV_FILE='C:\srv\cofounder\.env.cloud'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm https://raw.githubusercontent.com/yassinebaazi99/cofounder-bootstrap/main/provision-windows-server.ps1)"
```

The private application repo needs a GitHub login on the box. Over SSH there is no browser, so
either run `gh auth login --web` once at the PC, or set `COFOUNDER_GITHUB_TOKEN` on that line to a
fine-grained token with read access to the repo (it lands in the remote shell's history; prefer
the one-time web login).

Every step is idempotent: run the script again after a reboot, after changing `.env`, or with
different options. It refuses to start the service while `.env` still has `REPLACE_ME` markers.

## After it runs

1. Watch the worker: `ssh cofounder-srv "Get-Content C:\srv\cofounder\logs\worker.log -Tail 50 -Wait"`
   The proof is `Processing agent run` followed by `Agent run answered`, not `Worker ready`.
2. Then stop the Fly machine and the laptop worker. One owner of the agent queue.
3. After a push to `main`: `ssh cofounder-srv "C:\srv\cofounder\tools\update-worker.ps1"`
   (pull fast-forward, rebuild, restart the service, show the log tail).

## What is on the box

- The BullMQ worker (`WORKER_ROLES=media,agent`, never `scoreboard` while the Vercel cron drives
  the tick) as the `CoFounderWorker` Windows service via NSSM: starts at boot with nobody logged
  in, restarts on crash, 300 s graceful stop, rotating logs under `C:\srv\cofounder\logs`.
- OpenSSH Server, PowerShell as the shell, key-only login for administrators, port 22 scoped to
  the tailnet and the local subnet. Tailscale for reachability from anywhere. Remote Desktop only
  with `-EnableRdp` on Windows Pro.
- Sleep, hibernate, fast startup and NIC power saving off; Windows Update pinned to Sunday 04:00
  (Pro; Home only honours active hours); time sync on.
- No Claude Code, unless you pass `-InstallClaude`. The laptop's session is the operator.

To pin a reviewed version instead of `main`, replace `main` in the URL with a commit SHA.
