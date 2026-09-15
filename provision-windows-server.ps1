<#
.SYNOPSIS
  Turn a fresh Windows 10/11 PC into the always-on CoFounder server.

.DESCRIPTION
  One elevated run does all of it. The one-line form runs straight from memory, so there is no
  downloaded file for PowerShell's execution policy to refuse:

    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
    iex (irm https://raw.githubusercontent.com/yassinebaazi99/cofounder-bootstrap/main/provision-windows-server.ps1)

  Options for that form are environment variables set on the line before (COFOUNDER_ENV_FILE,
  COFOUNDER_SSH_PUBLIC_KEY, COFOUNDER_TAILSCALE_AUTHKEY, COFOUNDER_HEARTBEAT_URL,
  COFOUNDER_COMPUTER_NAME, COFOUNDER_GITHUB_TOKEN, COFOUNDER_WORKER_ROLES, and the flags
  COFOUNDER_ACCESS_ONLY=1, COFOUNDER_ENABLE_RDP=1, COFOUNDER_INSTALL_CLAUDE=1,
  COFOUNDER_NO_START=1). The parameters below are the same options for the file form. Every
  step is idempotent: run it again after a reboot, after filling in .env, or with different
  options.

  THE TWO-MINUTE FORM (-AccessOnly / COFOUNDER_ACCESS_ONLY=1) runs only the access, system and
  tailnet steps below and stops: the PC becomes reachable over SSH from anywhere, never sleeps,
  and prints the USER and tailnet NAME the laptop needs. Everything else (tooling, repo, env,
  build, service) is then done from the laptop over SSH, which is the point: the box is a VPS
  you happen to own.

    $env:COFOUNDER_ACCESS_ONLY = '1'
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
    iex (irm https://raw.githubusercontent.com/yassinebaazi99/cofounder-bootstrap/main/provision-windows-server.ps1)

    access   - FIRST: OpenSSH Server with PowerShell as the shell, port 22 open to the LAN and
               the tailnet only, the laptop's public key authorised, and the USER / HOST / IP the
               laptop needs printed. From here on the laptop's Claude session can drive the box
               over SSH even if a later step stalls.
    system   - execution policy, long paths, never sleep, no fast startup, NIC power saving off,
               Windows Update pinned to Sunday 04:00, time sync, optional rename
    tooling  - Git, GitHub CLI, Node <NodeMajor> (official MSI, latest patch), pnpm via corepack
               at the version package.json pins
    repo     - clone (or fast-forward) the CoFounder repo, which carries .claude/ (skills,
               agents, rules, workflows) with it
    env      - copy your .env (or write a template), enforce the worker keys, lock the file ACL
    build    - pnpm install --frozen-lockfile, prisma generate, tsup build of apps/worker
    service  - "CoFounderWorker" Windows service via NSSM: starts at boot with nobody logged
               in, restarts on crash, 300 s graceful stop (Fly's kill_timeout), rotating logs
    tailnet  - Tailscale (auth key or a browser login), optional Remote Desktop, both scoped to
               the tailnet and the local subnet
    watch    - a heartbeat task that pings healthchecks.io every minute WHILE the service runs
    agents   - only with -InstallClaude: Claude Code on the box. By default nothing of Claude is
               installed here; the laptop's Claude Code session drives the box over SSH
    tools    - <InstallRoot>\tools\update-worker.ps1 for pull -> build -> restart

  The script never prints a secret. Nothing here touches the database.

.EXAMPLE
  # one line, everything, defaults (elevated PowerShell on the new PC)
  [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; iex (irm https://raw.githubusercontent.com/yassinebaazi99/cofounder-bootstrap/main/provision-windows-server.ps1)

.EXAMPLE
  # one line with options
  $env:COFOUNDER_ENV_FILE = 'D:\.env.cloud'; $env:COFOUNDER_ENABLE_RDP = '1'; $env:COFOUNDER_COMPUTER_NAME = 'cofounder-srv'
  [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; iex (irm https://raw.githubusercontent.com/yassinebaazi99/cofounder-bootstrap/main/provision-windows-server.ps1)

.EXAMPLE
  # file form
  powershell -ExecutionPolicy Bypass -File .\provision-windows-server.ps1 `
    -EnvFile D:\usb\.env -TailscaleAuthKey tskey-auth-xxxx -HeartbeatUrl https://hc-ping.com/<uuid> `
    -EnableRdp -ComputerName cofounder-srv

  A bare run installs everything, writes a .env template with REPLACE_ME markers, refuses to
  start the service until they are gone, and lists what is still pending at the end.

.PARAMETER RepoUrl
  Git remote to clone. Default: the CoFounder GitHub repo.
.PARAMETER Branch
  Branch to check out. Default: main.
.PARAMETER InstallRoot
  Where everything lives (repo, logs, tools, tmp). Default: C:\srv\cofounder.
.PARAMETER EnvFile
  A ready .env to copy in (for example the laptop's .env.cloud). Overwrites.
.PARAMETER WorkerRoles
  WORKER_ROLES appended if the .env lacks it. Default: media,agent ---
  NOT scoreboard, because the Vercel cron drives the tick (docs/deploy-fly.md).
.PARAMETER NodeMajor
  Node major to install. Default: 22 (the repo needs >= 22.12).
.PARAMETER ComputerName
  Rename the PC (needs a reboot).
.PARAMETER TailscaleAuthKey
  A tailscale.com auth key so `tailscale up` needs no browser. Optional.
.PARAMETER SshPublicKey
  Public key authorised for administrators over SSH. Default: the key of the laptop that runs
  Claude Code for this project, so a bare run lets that laptop in. Pass '' to authorise nothing.
.PARAMETER HeartbeatUrl
  A healthchecks.io (or compatible) ping URL. Optional.
.PARAMETER EnableRdp
  Enable Remote Desktop (Pro/Enterprise only), scoped to tailnet + LAN.
.PARAMETER InstallClaude
  Also install Claude Code on the box. Off by default: the box is driven over SSH from the
  laptop, where Claude Code already runs.
.PARAMETER ClaudeUserDirFrom
  A copied ~/.claude folder; settings.json, CLAUDE.md, skills, agents,
  commands are copied, .credentials.json never is.
.PARAMETER GitHubToken
  A GitHub token for a non-interactive `gh auth login`. Prefer the
  interactive login (this value lands in your PowerShell history).
.PARAMETER NoStart
  Configure the service but do not start it (for example while the Fly
  machine or the laptop worker still owns the queue).
.PARAMETER AccessOnly
  Stop after the access, system and tailnet steps: SSH in, never sleep, on the tailnet. The
  rest is done later over SSH from the laptop (re-run without the switch, or step by step).
#>
[CmdletBinding()]
param(
  [string]$RepoUrl = 'https://github.com/yassinebaazi99/videoratingsystem.git',
  [string]$Branch = 'main',
  [string]$InstallRoot = 'C:\srv\cofounder',
  [string]$EnvFile = '',
  [string]$WorkerRoles = 'media,agent',
  [int]$NodeMajor = 22,
  [string]$ComputerName = '',
  [string]$TailscaleAuthKey = '',
  [string]$SshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKhdoS9uKKZ/4PQmOt579LeuMrCqRnszc7zftGt9gxj3 claude-code@msi-laptop',
  [string]$HeartbeatUrl = '',
  [switch]$EnableRdp,
  [switch]$InstallClaude,
  [string]$ClaudeUserDirFrom = '',
  [string]$GitHubToken = '',
  [switch]$NoStart,
  [switch]$AccessOnly
)

# The one-line form (iex) cannot pass parameters, so every option also reads an env var.
if (-not $EnvFile -and $env:COFOUNDER_ENV_FILE) { $EnvFile = $env:COFOUNDER_ENV_FILE }
# Absolute from here on: Test-Path follows PowerShell's location, [IO.File] the process cwd.
if ($EnvFile) { $EnvFile = (Resolve-Path -LiteralPath $EnvFile -ErrorAction Stop).ProviderPath }
if ($env:COFOUNDER_SSH_PUBLIC_KEY) { $SshPublicKey = $env:COFOUNDER_SSH_PUBLIC_KEY }
if (-not $TailscaleAuthKey -and $env:COFOUNDER_TAILSCALE_AUTHKEY) { $TailscaleAuthKey = $env:COFOUNDER_TAILSCALE_AUTHKEY }
if (-not $HeartbeatUrl -and $env:COFOUNDER_HEARTBEAT_URL) { $HeartbeatUrl = $env:COFOUNDER_HEARTBEAT_URL }
if (-not $ComputerName -and $env:COFOUNDER_COMPUTER_NAME) { $ComputerName = $env:COFOUNDER_COMPUTER_NAME }
if (-not $GitHubToken -and $env:COFOUNDER_GITHUB_TOKEN) { $GitHubToken = $env:COFOUNDER_GITHUB_TOKEN }
if ($env:COFOUNDER_WORKER_ROLES) { $WorkerRoles = $env:COFOUNDER_WORKER_ROLES }
if ($env:COFOUNDER_ENABLE_RDP -eq '1') { $EnableRdp = $true }
if ($env:COFOUNDER_INSTALL_CLAUDE -eq '1') { $InstallClaude = $true }
if ($env:COFOUNDER_NO_START -eq '1') { $NoStart = $true }
if ($env:COFOUNDER_ACCESS_ONLY -eq '1') { $AccessOnly = $true }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'

$ServiceName = 'CoFounderWorker'
$RepoDir = Join-Path $InstallRoot 'repo'
$LogDir = Join-Path $InstallRoot 'logs'
$ToolsDir = Join-Path $InstallRoot 'tools'
$TmpDir = Join-Path $InstallRoot 'tmp\worker'
$WorkerLog = Join-Path $LogDir 'worker.log'
$TailnetRanges = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48', 'LocalSubnet')

$script:Report = New-Object 'System.Collections.Generic.List[string]'
$script:Pending = New-Object 'System.Collections.Generic.List[string]'
$script:RebootNeeded = $false

# ------ helpers ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Done([string]$Text) { Write-Host "   ok    $Text" -ForegroundColor Green; $script:Report.Add($Text) }
function Pending([string]$Text) { Write-Host "   TODO  $Text" -ForegroundColor Yellow; $script:Pending.Add($Text) }
function Skip([string]$Text) { Write-Host "   skip  $Text" -ForegroundColor DarkGray }

function Invoke-Step([string]$Name, [scriptblock]$Body) {
  Write-Step $Name
  try { & $Body }
  catch {
    Write-Host "   FAIL  $($_.Exception.Message)" -ForegroundColor Red
    $script:Pending.Add("$Name failed: $($_.Exception.Message)")
  }
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

# Secret-looking arguments (--auth-key=..., --token=...) never reach a failure message.
function Hide-SecretArgs([string[]]$ArgumentList) {
  foreach ($a in $ArgumentList) {
    if ($a -match '^(--?(auth-?key|token|password|secret)=).+$') { $Matches[1] + '***' } else { $a }
  }
}

# Runs a native command, streams its output to the console, throws on a bad exit code.
function Invoke-Native([string]$File, [string[]]$ArgumentList, [string]$WorkingDirectory = '', [int[]]$OkExitCodes = @(0)) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $pushed = $false
  try {
    if ($WorkingDirectory) { Push-Location $WorkingDirectory; $pushed = $true }
    & $File @ArgumentList
    $code = $LASTEXITCODE
  } finally {
    if ($pushed) { Pop-Location }
    $ErrorActionPreference = $prev
  }
  if ($OkExitCodes -notcontains $code) { throw "$File $(@(Hide-SecretArgs $ArgumentList) -join ' ') exited with $code" }
}

# Runs a native command quietly and returns @{ Output; ExitCode }.
function Invoke-Capture([string]$File, [string[]]$ArgumentList) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = (& $File @ArgumentList 2>&1 | Out-String)
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  return @{ Output = $out; ExitCode = $code }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-RegistryValue([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
  if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
  New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# winget is an App Execution Alias; in a key-authenticated SSH session the alias can fail to
# launch while Get-Command still finds it. Resolve the real binary from the App Installer
# package first, fall back to the alias, and throw (inside a step, so the run goes on and the
# access step is never skipped) when neither exists: App Installer comes from the Store.
function Get-WingetExe {
  try {
    $pkg = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction Stop | Select-Object -First 1
    if ($pkg) { $exe = Join-Path $pkg.InstallLocation 'winget.exe'; if (Test-Path $exe) { return $exe } }
  } catch { }
  $cmd = Get-Command winget -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw 'winget is missing. Install "App Installer" from the Microsoft Store, then re-run.'
}

# $Present: true when the tool is already on the box; then winget is not touched at all.
function Install-WingetPackage([string]$Id, [string]$Name, [scriptblock]$Present = $null) {
  if ($Present -and (& $Present)) { Skip "$Name already installed"; Refresh-Path; return }
  $winget = Get-WingetExe
  $listed = Invoke-Capture $winget @('list', '--id', $Id, '--exact', '--accept-source-agreements')
  if ($listed.Output -match [regex]::Escape($Id)) { Skip "$Name already installed"; Refresh-Path; return }
  $r = Invoke-Capture $winget @('install', '--id', $Id, '--exact', '--silent',
    '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
  # -1978335189 = APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
  if ($r.ExitCode -ne 0 -and $r.ExitCode -ne -1978335189) { throw "winget install $Id exited with $($r.ExitCode): $($r.Output)" }
  Refresh-Path
  Done "$Name installed"
}

function Get-NodeVersion {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return $null }
  $raw = (Invoke-Capture $node.Source @('-v')).Output.Trim().TrimStart('v')
  try { return [version]$raw } catch { return $null }
}

function Install-Node([int]$Major) {
  $current = Get-NodeVersion
  if ($current -and $current.Major -eq $Major -and $current -ge [version]'22.12.0') { Skip "Node $current already installed"; return }
  $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing
  $pick = $index | Where-Object { $_.version -like "v$Major.*" } | Select-Object -First 1   # index is newest-first
  if (-not $pick) { throw "No Node $Major release in the nodejs.org index" }
  $ver = $pick.version
  $msi = Join-Path $env:TEMP "node-$ver-x64.msi"
  Invoke-WebRequest -Uri "https://nodejs.org/dist/$ver/node-$ver-x64.msi" -OutFile $msi -UseBasicParsing
  $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
  if ($p.ExitCode -eq 3010) { $script:RebootNeeded = $true }
  elseif ($p.ExitCode -ne 0) { throw "Node MSI exited with $($p.ExitCode)" }
  Refresh-Path
  Done "Node $ver installed"
}

function Install-Nssm {
  $cmd = Get-Command nssm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  try { Install-WingetPackage 'NSSM.NSSM' 'NSSM' } catch { Write-Host "   winget could not install NSSM, downloading it instead" }
  $cmd = Get-Command nssm -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $zip = Join-Path $env:TEMP 'nssm-2.24.zip'
  Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $ToolsDir -Force
  $exe = Join-Path $ToolsDir 'nssm-2.24\win64\nssm.exe'
  if (-not (Test-Path $exe)) { throw 'nssm.exe missing after extraction' }
  return $exe
}

function Set-NssmValue([string]$Nssm, [string]$Name, [string[]]$Values) {
  # NSSM prints UTF-16, which the console renders with gaps; the exit code is what matters.
  $r = Invoke-Capture $Nssm (@('set', $ServiceName, $Name) + $Values)
  if ($r.ExitCode -ne 0) { throw "nssm set $Name failed (exit $($r.ExitCode))" }
}

function Ensure-EnvKey([string]$Path, [string]$Key, [string]$Value) {
  $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
  $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
  if (@($lines | Where-Object { $_ -match $pattern }).Count -gt 0) { return $false }
  $lines += "$Key=$Value"
  Write-Utf8NoBom $Path (($lines -join "`n") + "`n")
  return $true
}

function Test-EnvHasKey([string]$Path, [string]$Key) {
  $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*\S'
  return (@(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match $pattern }).Count -gt 0)
}

# Tailscale's own view of this node: @{ State; DnsName; Ip4 }, empty strings when not joined.
function Get-TailnetSelf {
  $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  $self = @{ State = ''; DnsName = ''; Ip4 = '' }
  if (-not (Test-Path $ts)) { return $self }
  try {
    $st = (Invoke-Capture $ts @('status', '--json')).Output | ConvertFrom-Json
    $self.State = [string]$st.BackendState
    if ($st.Self) {
      $self.DnsName = ([string]$st.Self.DNSName).TrimEnd('.')
      $self.Ip4 = [string]($st.Self.TailscaleIPs | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)
    }
  } catch { }
  return $self
}

# The tailnet step is a function because it runs in two places: after the service in the full
# run, and right after the system step in the access-only run.
function Invoke-TailnetStep {
  Invoke-Step 'Access: Tailscale' {
    $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    Install-WingetPackage 'Tailscale.Tailscale' 'Tailscale' { Test-Path $ts }
    if (-not (Test-Path $ts)) { throw "tailscale.exe not found at $ts" }
    $hn = $env:COMPUTERNAME.ToLower()
    if ($ComputerName) { $hn = $ComputerName.ToLower() }
    $self = Get-TailnetSelf
    if ($self.State -eq 'Running') { Skip "already on the tailnet as $($self.DnsName)" }
    elseif ($TailscaleAuthKey) {
      # The key goes through a temp file (`--auth-key=file:...`), never through the argument
      # list, so neither a process listing nor a failure message can show it.
      $keyFile = Join-Path $env:TEMP ('ts-authkey-' + [guid]::NewGuid().ToString('N'))
      Write-Utf8NoBom $keyFile $TailscaleAuthKey
      try {
        Invoke-Native $ts @('up', "--auth-key=file:$keyFile", "--hostname=$hn", '--accept-dns=true', '--timeout=5m')
        Done 'joined the tailnet with the auth key'
      } catch {
        throw 'tailscale up with the auth key failed; check the key (expiry, reusable, tags) at login.tailscale.com/admin/settings/keys'
      } finally { Remove-Item $keyFile -Force -ErrorAction SilentlyContinue }
    } else {
      # No key: `tailscale up` prints a login URL and waits. Open it from ANY device signed in
      # to the Tailscale account (this PC, your phone, the laptop); it authorises this node.
      Write-Host '   A Tailscale login link follows. Open it on any device signed in to your Tailscale account.' -ForegroundColor Magenta
      try {
        Invoke-Native $ts @('up', "--hostname=$hn", '--accept-dns=true', '--timeout=10m')
        Done 'joined the tailnet (browser login)'
      } catch {
        Pending 'tailnet login not completed within 10 min: run  & "C:\Program Files\Tailscale\tailscale.exe" up  and open the link (or re-run with -TailscaleAuthKey)'
      }
    }
    $self = Get-TailnetSelf
    if ($self.State -eq 'Running') {
      Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
      Write-Host "   tailnet name: $($self.DnsName)   ip: $($self.Ip4)"
    }
  }
}

function Write-Summary {
  Write-Host "`n------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------" -ForegroundColor Cyan
  Write-Host ' Done' -ForegroundColor Green
  foreach ($l in $script:Report) { Write-Host "  - $l" }
  if ($script:Pending.Count -gt 0) {
    Write-Host "`n Still to do" -ForegroundColor Yellow
    foreach ($l in $script:Pending) { Write-Host "  - $l" }
  }
  $self = Get-TailnetSelf
  $lanIps = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress)
  Write-Host "`n Reach it" -ForegroundColor Cyan
  foreach ($ip in $lanIps) { Write-Host "  ssh $env:USERNAME@$ip   (same network)" }
  if ($self.DnsName) {
    Write-Host "  ssh $env:USERNAME@$($self.DnsName)   (from anywhere, over Tailscale; ip $($self.Ip4))"
  } else { Write-Host "  ssh $env:USERNAME@<tailscale name>   (from anywhere, after tailscale up)" }
  Write-Host ''
  Write-Host ' >>> On the laptop, hand the box to Claude with these two values:' -ForegroundColor Magenta
  Write-Host "     USER: $env:USERNAME"
  if ($self.DnsName) { Write-Host "     NAME: $($self.DnsName)" } else { Write-Host "     NAME: <tailscale name, or the LAN ip above>" }
  Write-Host "     i.e.  scripts\connect-cofounder-srv.ps1 -User $env:USERNAME -HostName $(if ($self.DnsName) { $self.DnsName } else { '<name>' })"
  if (-not $AccessOnly) {
    Write-Host ''
    Write-Host "  Get-Service $ServiceName ; Get-Content '$WorkerLog' -Tail 50 -Wait"
    Write-Host "  $ToolsDir\update-worker.ps1   after a push"
    Write-Host "  Stop the Fly machine and the laptop worker once this one logs 'Processing agent run': one owner of the queue."
  }
  if ($script:RebootNeeded) { Write-Host "`n A reboot is needed (rename / Node install). Everything above starts on its own afterwards." -ForegroundColor Yellow }
}

$EnvTemplate = @'
# CoFounder worker --- production env for this box. Never commit it (.gitignore covers .env).
# Every value comes from the Vercel "api" project (Settings -> Environment Variables); it is the
# same list docs/deploy-fly.md step 2 sets on the Fly machine. The provisioning script refuses
# to start the service while any VALUE below still holds the placeholder it was written with.

NODE_ENV=production
DEMO_MODE=false
LOG_LEVEL=info
# media + agent. NOT scoreboard: the Vercel cron drives the tick and the rule is one driver.
WORKER_ROLES=__ROLES__
WORKER_TMP_DIR=__TMP__

# The Supabase SESSION pooler (port 5432) --- a long-lived process holds a real pool. Not the
# API's transaction-pooler URL with pgbouncer=true.
DATABASE_URL=postgresql://REPLACE_ME:REPLACE_ME@REPLACE_ME:5432/postgres
# The API's Upstash URL verbatim (rediss://...). Producer and consumer must share one Redis.
REDIS_URL=rediss://REPLACE_ME
SUPABASE_URL=https://REPLACE_ME.supabase.co
SUPABASE_ANON_KEY=REPLACE_ME
SUPABASE_SERVICE_ROLE_KEY=REPLACE_ME
SUPABASE_JWT_ISSUER=https://REPLACE_ME.supabase.co/auth/v1

# Assistant (agent role). Must match the API exactly: same LLM_ROUTES, same CREDENTIAL_ENC
# pair (both or neither), and the key the agent seat resolves to.
AGENT_ENABLED=true
LLM_ROUTES=
OPENROUTER_API_KEY=
ANTHROPIC_API_KEY=
CREDENTIAL_ENC_KEYS=
CREDENTIAL_ENC_ACTIVE_VERSION=

# Media role: production refuses a media worker with no real provider.
ENABLED_AI_PROVIDERS=twelvelabs
TWELVE_LABS_API_KEY=REPLACE_ME
AD_VIDEO_PIPELINE_ENABLED=false
AD_PIPELINE_ENGINE=legacy
FRAMEIO_ENABLED=false
'@

# ------ 0. preflight ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Write-Step 'Preflight'
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this from an elevated PowerShell (right-click -> Run as administrator).'
}
$os = Get-CimInstance Win32_OperatingSystem
# Home editions by SKU / EditionID, never by caption: the caption is localised ("Famille").
$isHome = ([int]$os.OperatingSystemSKU -in 98, 99, 100, 101) -or
  (((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID) -match '^Core')
Write-Host "   $($os.Caption), PowerShell $($PSVersionTable.PSVersion), user $env:USERNAME"
foreach ($d in @($InstallRoot, $LogDir, $ToolsDir, $TmpDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
Done "layout under $InstallRoot"

# ------ 1. access, before anything else: from here on the laptop can drive the box over SSH ------

Invoke-Step 'Access: OpenSSH Server' {
  $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
  if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
  Set-Service -Name sshd -StartupType Automatic
  Start-Service sshd   # no-op when already running; never Restart-Service here, a re-run over SSH would cut its own session
  Set-RegistryValue 'HKLM:\SOFTWARE\OpenSSH' 'DefaultShell' "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" 'String'
  Done 'sshd running with PowerShell as the remote shell'

  # The key goes in BEFORE the firewall is narrowed: sshd reads the file on every login, so no
  # restart is needed, and a scoping failure below can never leave the box without key logins.
  if ($SshPublicKey) {
    $akf = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    $existing = ''
    if (Test-Path $akf) { $existing = [IO.File]::ReadAllText($akf) }
    if ($existing -notmatch [regex]::Escape($SshPublicKey.Trim())) {
      Write-Utf8NoBom $akf (($existing.TrimEnd() + "`n" + $SshPublicKey.Trim() + "`n").TrimStart())
    }
    # The well-known SIDs, not group names: on a French Windows the group is "Administrateurs".
    Invoke-Native 'icacls' @($akf, '/inheritance:r', '/grant:r', '*S-1-5-32-544:F', '*S-1-5-18:F') | Out-Null
    Done 'the laptop''s public key is authorised for administrators (no password needed)'
  } else { Pending 'no SSH public key given: SSH will ask for your Windows password' }

  if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound `
      -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
  }
  try {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -RemoteAddress $TailnetRanges
    Done 'port 22 open to the local network and the tailnet only'
  } catch {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True
    Pending "port 22 is open to any address: scoping it failed ($($_.Exception.Message))"
  }

  $lanIps = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress)
  Write-Host ''
  Write-Host '   >>> Give these three lines to Claude on the laptop; it takes over from here:' -ForegroundColor Magenta
  Write-Host "   USER: $env:USERNAME"
  Write-Host "   HOST: $env:COMPUTERNAME"
  Write-Host "   IP:   $($lanIps -join ', ')"
  Write-Host ''
}

# ------ 2. system ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'System: scripts, long paths, power, updates, time' {
  # The policy IS set even when PowerShell reports that a more specific scope (the -ExecutionPolicy
  # Bypass this console may run under) overrides it; under Stop that report is a terminating
  # error, and it would take sleep/hibernate/update/time below down with it. Swallow only that.
  try { Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop }
  catch { if ($_.FullyQualifiedErrorId -notlike 'ExecutionPolicyOverride*') { throw } }
  Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1
  Done 'RemoteSigned execution policy, long paths enabled'

  # Never sleep, never hibernate, on mains or on the UPS "battery".
  foreach ($a in @('standby-timeout-ac 0', 'standby-timeout-dc 0', 'hibernate-timeout-ac 0',
                   'hibernate-timeout-dc 0', 'disk-timeout-ac 0', 'disk-timeout-dc 0')) {
    Invoke-Native 'powercfg' (@('/change') + $a.Split(' '))
  }
  Invoke-Native 'powercfg' @('/hibernate', 'off')
  try {
    Invoke-Native 'powercfg' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')
    Invoke-Native 'powercfg' @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0')
    Invoke-Native 'powercfg' @('/setactive', 'SCHEME_CURRENT')
  } catch { Skip 'no lid on this machine' }
  Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
  try { Get-NetAdapter -Physical | Disable-NetAdapterPowerManagement -NoRestart -ErrorAction Stop } catch { }
  Done 'sleep, hibernate, fast startup and NIC power saving off'

  # Windows Update: download automatically, install and reboot Sunday 04:00, active hours 05-23.
  $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  Set-RegistryValue $au 'NoAutoUpdate' 0
  Set-RegistryValue $au 'AUOptions' 4
  Set-RegistryValue $au 'ScheduledInstallDay' 1
  Set-RegistryValue $au 'ScheduledInstallTime' 4
  Set-RegistryValue $au 'AlwaysAutoRebootAtScheduledTime' 1
  Set-RegistryValue $au 'AlwaysAutoRebootAtScheduledTimeMinutes' 15
  $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
  Set-RegistryValue $ux 'ActiveHoursStart' 5
  Set-RegistryValue $ux 'ActiveHoursEnd' 23
  Set-RegistryValue $ux 'SmartActiveHoursState' 0
  if ($isHome) { Pending 'Windows Home ignores the update-schedule policy; only active hours apply. The service restarts the worker after any forced reboot.' }
  else { Done 'Windows Update pinned to Sunday 04:00' }

  Set-Service -Name w32time -StartupType Automatic
  try { Start-Service w32time; Invoke-Native 'w32tm' @('/resync', '/nowait') } catch { }
  Done 'time sync on'

  if ($ComputerName -and $env:COMPUTERNAME -ne $ComputerName) {
    Rename-Computer -NewName $ComputerName -Force
    $script:RebootNeeded = $true
    Done "renamed to $ComputerName (after reboot)"
  }
}

# ------ access-only: reachable from anywhere, never asleep, and stop here ------------------------------------------------------------------------------------------------------------------------------------

if ($AccessOnly) {
  Invoke-TailnetStep
  Write-Summary
  return
}

# ------ 3. tooling ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Tooling: Git, Node, corepack' {
  Install-WingetPackage 'Git.Git' 'Git for Windows' { [bool](Get-Command git -ErrorAction SilentlyContinue) }
  Invoke-Native 'git' @('config', '--global', 'core.longpaths', 'true')
  Invoke-Native 'git' @('config', '--global', 'core.autocrlf', 'true')   # what the laptop checkout uses
  Install-Node $NodeMajor
  Invoke-Native 'corepack' @('enable')
  Done 'corepack enabled (pnpm version comes from package.json after the clone)'
}

# ------ 4. repo ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Repo: GitHub auth and clone' {
  Install-WingetPackage 'GitHub.cli' 'GitHub CLI' { [bool](Get-Command gh -ErrorAction SilentlyContinue) }
  $status = Invoke-Capture 'gh' @('auth', 'status', '--hostname', 'github.com')
  if ($status.ExitCode -ne 0) {
    # --insecure-storage: the token lives in gh's hosts.yml under this profile instead of the
    # Windows Credential Manager, which a key-authenticated SSH logon cannot unlock -- and every
    # later update-worker.ps1 run over SSH needs it for git pull.
    if ($GitHubToken) {
      $tokenFile = Join-Path $env:TEMP ('gh-token-' + [guid]::NewGuid().ToString('N'))
      Write-Utf8NoBom $tokenFile $GitHubToken
      try { Invoke-Native 'cmd.exe' @('/c', "gh auth login --hostname github.com --insecure-storage --with-token < `"$tokenFile`"") }
      finally { Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue }
    } elseif ($env:SSH_CONNECTION) {
      throw 'gh cannot prompt inside an SSH session: re-run with COFOUNDER_GITHUB_TOKEN (a fine-grained token with read access to the repo), or run this script once at the console'
    } else {
      Write-Host '   GitHub login (a browser window / device code follows):'
      Invoke-Native 'gh' @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web', '--insecure-storage')
    }
  } else { Skip 'gh already logged in' }
  Invoke-Native 'gh' @('auth', 'setup-git')

  if (Test-Path (Join-Path $RepoDir '.git')) {
    $dirty = (Invoke-Capture 'git' @('-C', $RepoDir, 'status', '--porcelain')).Output.Trim()
    if ($dirty) { Pending "repo has local changes; not pulling ($RepoDir)" }
    else {
      Invoke-Native 'git' @('-C', $RepoDir, 'fetch', 'origin', $Branch)
      Invoke-Native 'git' @('-C', $RepoDir, 'pull', '--ff-only', 'origin', $Branch)
      Done "repo fast-forwarded to origin/$Branch"
    }
  } else {
    Invoke-Native 'git' @('clone', '--branch', $Branch, $RepoUrl, $RepoDir)
    Done "cloned $Branch into $RepoDir (.claude/ skills, agents and rules included)"
  }

  $pkg = Get-Content (Join-Path $RepoDir 'package.json') -Raw | ConvertFrom-Json
  $pm = $pkg.packageManager
  if (-not $pm) { $pm = 'pnpm@11.21.0' }
  $r = Invoke-Capture 'corepack' @('install', '-g', $pm)
  if ($r.ExitCode -ne 0) { Invoke-Native 'corepack' @('prepare', $pm, '--activate') }
  Refresh-Path
  Done "$pm active via corepack"
}

# ------ 5. env ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

$EnvPath = Join-Path $RepoDir '.env'
Invoke-Step 'Env: .env for the worker' {
  if ($EnvFile) {
    if (-not (Test-Path $EnvFile)) { throw "EnvFile not found: $EnvFile" }
    Write-Utf8NoBom $EnvPath ([IO.File]::ReadAllText($EnvFile))   # ReadAllText drops a BOM if there is one
    Done "copied $EnvFile -> $EnvPath (BOM-free)"
  } elseif (-not (Test-Path $EnvPath)) {
    Write-Utf8NoBom $EnvPath ($EnvTemplate.Replace('__ROLES__', $WorkerRoles).Replace('__TMP__', $TmpDir))
    Pending "fill in $EnvPath (REPLACE_ME markers), then re-run this script"
  } else { Skip '.env already present' }

  $added = @()
  foreach ($kv in @(@('NODE_ENV', 'production'), @('DEMO_MODE', 'false'), @('LOG_LEVEL', 'info'),
                    @('WORKER_ROLES', $WorkerRoles), @('WORKER_TMP_DIR', $TmpDir),
                    @('AGENT_ENABLED', 'true'), @('AD_VIDEO_PIPELINE_ENABLED', 'false'))) {
    if (Ensure-EnvKey $EnvPath $kv[0] $kv[1]) { $added += $kv[0] }
  }
  if ($added.Count -gt 0) { Done "appended missing keys: $($added -join ', ')" }

  $required = @('DATABASE_URL', 'REDIS_URL', 'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_JWT_ISSUER')
  if ($WorkerRoles -match 'media') { $required += @('ENABLED_AI_PROVIDERS', 'TWELVE_LABS_API_KEY') }
  $missing = @($required | Where-Object { -not (Test-EnvHasKey $EnvPath $_) })
  if ($missing.Count -gt 0) { Pending "keys empty or missing in .env: $($missing -join ', ')" }

  # Only SYSTEM (the service), Administrators and you can read the secrets.
  $me = "$env:USERDOMAIN\$env:USERNAME"
  # Well-known SIDs (SYSTEM, Administrators) so the grant works on a French or any other Windows.
  Invoke-Native 'icacls' @($EnvPath, '/inheritance:r', '/grant:r', '*S-1-5-18:F', '*S-1-5-32-544:F', "${me}:F") | Out-Null
  Done '.env ACL locked to SYSTEM, Administrators and you'
}

# ------ 6. defender ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Defender: exclude the video scratch dir and node_modules' {
  try {
    Add-MpPreference -ExclusionPath $TmpDir, (Join-Path $RepoDir 'node_modules') -ErrorAction Stop
    Done 'exclusions added'
  } catch { Skip "Defender not managing this machine ($($_.Exception.Message))" }
}

# ------ 7. build ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Build: install, prisma generate, worker bundle' {
  Invoke-Native 'pnpm' @('install', '--frozen-lockfile') $RepoDir
  # prisma.config.ts reads DATABASE_URL from the root .env; generation never connects, so the
  # template's well-formed placeholder is enough (docs/deploy-fly.md, "At db:generate").
  Invoke-Native 'pnpm' @('--filter', '@vra/adapters', 'db:generate') $RepoDir
  Invoke-Native 'pnpm' @('--filter', '@vra/worker', 'build') $RepoDir
  if (-not (Test-Path (Join-Path $RepoDir 'apps\worker\dist\main.js'))) { throw 'apps/worker/dist/main.js missing after build' }
  Done 'apps/worker/dist/main.js built'
}

# ------ 8. service ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step "Service: $ServiceName via NSSM" {
  $nssm = Install-Nssm
  $nodeExe = (Get-Command node).Source
  $workerDir = Join-Path $RepoDir 'apps\worker'   # cwd matters: main.ts loads ../../.env from here
  if (-not (Test-Path (Join-Path $workerDir 'dist\main.js'))) {
    throw 'apps\worker\dist\main.js is missing (the build step failed): the service is not registered, so a reboot cannot launch a broken worker'
  }

  if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Invoke-Capture $nssm @('stop', $ServiceName) | Out-Null
    Skip 'service exists, reconfiguring'
  } else {
    $r = Invoke-Capture $nssm @('install', $ServiceName, $nodeExe, 'dist\main.js')
    if ($r.ExitCode -ne 0) { throw "nssm install failed (exit $($r.ExitCode))" }
  }
  Set-NssmValue $nssm 'Application' @($nodeExe)
  Set-NssmValue $nssm 'AppParameters' @('dist\main.js')
  Set-NssmValue $nssm 'AppDirectory' @($workerDir)
  Set-NssmValue $nssm 'DisplayName' @('CoFounder worker')
  Set-NssmValue $nssm 'Description' @("CoFounder BullMQ worker, roles $WorkerRoles. Log: $WorkerLog")
  Set-NssmValue $nssm 'AppEnvironmentExtra' @('NODE_ENV=production')
  Set-NssmValue $nssm 'AppStdout' @($WorkerLog)
  Set-NssmValue $nssm 'AppStderr' @($WorkerLog)
  Set-NssmValue $nssm 'AppRotateFiles' @('1')
  Set-NssmValue $nssm 'AppRotateOnline' @('1')
  Set-NssmValue $nssm 'AppRotateBytes' @('52428800')
  # Ctrl+C first (the worker's SIGINT handler drains the job in flight), up to 300 s like Fly's
  # kill_timeout, then the harder methods.
  Set-NssmValue $nssm 'AppStopMethodSkip' @('0')
  Set-NssmValue $nssm 'AppStopMethodConsole' @('300000')
  # Restart on any exit, 15 s apart: a boot-time ConfigError therefore shows up as a slow loop
  # in the log rather than a silent one (fly.toml chose on-failure for the same reason).
  Set-NssmValue $nssm 'AppExit' @('Default', 'Restart')
  Set-NssmValue $nssm 'AppRestartDelay' @('15000')
  Done "service configured (node $nodeExe, cwd $workerDir)"

  $envText = Get-Content -LiteralPath $EnvPath -Raw
  # Values only: the template's comments must never trip this gate.
  $placeholders = [bool]($envText -match '(?m)^\s*[A-Za-z0-9_]+\s*=.*REPLACE_ME')
  if ($NoStart -or $placeholders) {
    # Manual start only: a reboot must not launch a worker with placeholder secrets, nor a second
    # consumer of the queue while the Fly machine / laptop worker still owns it.
    Set-NssmValue $nssm 'Start' @('SERVICE_DEMAND_START')
    if ($NoStart) { Pending "service left stopped (-NoStart). Start-Service $ServiceName when the Fly machine / laptop worker is off, then re-run this script so it starts at boot" }
    else { Pending 'service left stopped: .env still has placeholder values; fill them in and re-run this script' }
  } else {
    Set-NssmValue $nssm 'Start' @('SERVICE_DELAYED_AUTO_START')
    Start-Service -Name $ServiceName
    $ready = $false
    for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
      Start-Sleep -Seconds 2
      if (Test-Path $WorkerLog) {
        $tail = Get-Content $WorkerLog -Tail 80 | Out-String
        if ($tail -match 'Worker ready') { $ready = $true }
        elseif ($tail -match 'Worker failed to start') { break }
      }
    }
    if ($ready) { Done "service running, log says Worker ready ($WorkerLog)" }
    else { Pending "service started but no 'Worker ready' within 60 s; read $WorkerLog" }
  }
}

# ------ 9. tailnet ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-TailnetStep

Invoke-Step 'Access: Remote Desktop' {
  if (-not $EnableRdp) { Skip 'not requested (-EnableRdp)'; return }
  if ($isHome) { Pending 'Remote Desktop cannot be hosted on Windows Home; use SSH (Claude sessions over SSH end when you disconnect)'; return }
  Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
  Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
  $group = '@FirewallAPI.dll,-28752'   # "Remote Desktop", language-neutral
  Enable-NetFirewallRule -Group $group
  try {
    Get-NetFirewallRule -Group $group | Set-NetFirewallRule -RemoteAddress $TailnetRanges
    Done 'Remote Desktop on, reachable from the tailnet and the LAN only'
  } catch {
    Pending "Remote Desktop is on but open to any address: scoping it failed ($($_.Exception.Message))"
  }
}

# ------ 10. heartbeat ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Watch: heartbeat every minute while the service runs' {
  if (-not $HeartbeatUrl) { Pending 'create a check at healthchecks.io (period 1 min, grace 5 min) and re-run with -HeartbeatUrl'; return }
  $hb = Join-Path $ToolsDir 'heartbeat.ps1'
  $body = @"
`$svc = Get-Service -Name '$ServiceName' -ErrorAction SilentlyContinue
if (`$svc -and `$svc.Status -eq 'Running') {
  & "`$env:SystemRoot\System32\curl.exe" -fsS -m 10 --retry 2 -o NUL '$HeartbeatUrl' | Out-Null
}
"@
  Write-Utf8NoBom $hb $body
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$hb`""
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable
  Register-ScheduledTask -TaskName 'CoFounder heartbeat' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Done 'heartbeat task registered (stops pinging the moment the service is not Running)'
}

# ------ 11. agents ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Agents: Claude Code' {
  if (-not $InstallClaude) { Skip 'not requested (-InstallClaude): the box is driven over SSH from the laptop'; return }
  $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
  if (Test-Path $bash) { [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bash, 'Machine') }
  if (Get-Command claude -ErrorAction SilentlyContinue) { Skip 'Claude Code already installed' }
  else {
    Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -UseBasicParsing | Invoke-Expression
    Refresh-Path
    Done 'Claude Code installed (native installer)'
  }
  if ($ClaudeUserDirFrom) {
    $dest = Join-Path $env:USERPROFILE '.claude'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($item in @('settings.json', 'CLAUDE.md', 'skills', 'agents', 'commands')) {
      $src = Join-Path $ClaudeUserDirFrom $item
      if (Test-Path $src) { Copy-Item -Path $src -Destination $dest -Recurse -Force }
    }
    Done "copied settings/skills/agents/commands from $ClaudeUserDirFrom (credentials never copied)"
  }
  Pending "log Claude in once:  cd $RepoDir ; claude   (the repo's .claude/ carries the skills, agents, rules and workflows)"
}

# ------ 12. tools ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Tools: update-worker.ps1' {
  $upd = Join-Path $ToolsDir 'update-worker.ps1'
  $body = @"
# Pull the current branch, rebuild the worker, restart the service, show the tail of the log.
# Native commands run through Run: under ErrorAction Stop, git's ordinary stderr ("From
# https://...") becomes a terminating error when stderr is redirected (as it is over ssh), and a
# non-zero pnpm exit would NOT stop the script, so a failed build would restart a stale dist.
`$ErrorActionPreference = 'Stop'
`$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
function Run([string]`$File, [string[]]`$ArgumentList) {
  `$prev = `$ErrorActionPreference
  `$ErrorActionPreference = 'Continue'
  try { & `$File @ArgumentList 2>&1 | ForEach-Object { "`$_" }; `$code = `$LASTEXITCODE }
  finally { `$ErrorActionPreference = `$prev }
  if (`$code -ne 0) { throw "`$File `$(`$ArgumentList -join ' ') exited with `$code" }
}
Set-Location '$RepoDir'
`$dirty = (Run 'git' @('status', '--porcelain') | Out-String).Trim()
if (`$dirty) { throw 'repo has local changes; commit or stash them first' }
Run 'git' @('pull', '--ff-only')
Run 'pnpm' @('install', '--frozen-lockfile')
Run 'pnpm' @('--filter', '@vra/adapters', 'db:generate')
Run 'pnpm' @('--filter', '@vra/worker', 'build')
if (-not (Test-Path 'apps\worker\dist\main.js')) { throw 'apps\worker\dist\main.js missing after build; service not restarted' }
Restart-Service -Name '$ServiceName'
Start-Sleep -Seconds 10
Get-Content '$WorkerLog' -Tail 20
"@
  Write-Utf8NoBom $upd $body
  Done "$upd (run it elevated after a push to $Branch)"
}

# ------ summary ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Write-Summary
