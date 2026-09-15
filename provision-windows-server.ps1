<#
.SYNOPSIS
  Turn a fresh Windows 10/11 PC into the always-on CoFounder server.

.DESCRIPTION
  One elevated run does all of it, and every step is idempotent, so run it again after filling
  in .env, after a reboot, or with different parameters:

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
    access   - OpenSSH Server (PowerShell as the shell), Tailscale, optional Remote Desktop,
               inbound allowed only from the tailnet and the local subnet
    watch    - a heartbeat task that pings healthchecks.io every minute WHILE the service runs
    agents   - only with -InstallClaude: Claude Code on the box. By default nothing of Claude is
               installed here; the laptop's Claude Code session drives the box over SSH
    tools    - <InstallRoot>\tools\update-worker.ps1 for pull -> build -> restart

  The script never prints a secret. Nothing here touches the database.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\provision-windows-server.ps1 `
    -EnvFile D:\usb\.env -TailscaleAuthKey tskey-auth-xxxx -HeartbeatUrl https://hc-ping.com/<uuid> `
    -SshPublicKey "ssh-ed25519 AAAA... you@laptop" -EnableRdp -ComputerName cofounder-srv

  Run it with no parameters first if you like: it installs everything, writes a .env template
  with REPLACE_ME markers, refuses to start the service until they are gone, and lists what is
  still pending at the end.

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
  Your public key, added to administrators_authorized_keys. Optional.
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
  [string]$SshPublicKey = '',
  [string]$HeartbeatUrl = '',
  [switch]$EnableRdp,
  [switch]$InstallClaude,
  [string]$ClaudeUserDirFrom = '',
  [string]$GitHubToken = '',
  [switch]$NoStart
)

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
  if ($OkExitCodes -notcontains $code) { throw "$File $($ArgumentList -join ' ') exited with $code" }
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

function Install-WingetPackage([string]$Id, [string]$Name) {
  $listed = Invoke-Capture 'winget' @('list', '--id', $Id, '--exact', '--accept-source-agreements')
  if ($listed.Output -match [regex]::Escape($Id)) { Skip "$Name already installed"; Refresh-Path; return }
  $r = Invoke-Capture 'winget' @('install', '--id', $Id, '--exact', '--silent',
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

$EnvTemplate = @'
# CoFounder worker --- production env for this box. Never commit it (.gitignore covers .env).
# Every value comes from the Vercel "api" project (Settings -> Environment Variables); it is the
# same list docs/deploy-fly.md step 2 sets on the Fly machine. Any REPLACE_ME left in this
# file stops the service from being started by the provisioning script.

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
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw 'winget is missing. Install "App Installer" from the Microsoft Store, then re-run.'
}
$os = Get-CimInstance Win32_OperatingSystem
$isHome = $os.Caption -match 'Home'
Write-Host "   $($os.Caption), PowerShell $($PSVersionTable.PSVersion), user $env:USERNAME"
foreach ($d in @($InstallRoot, $LogDir, $ToolsDir, $TmpDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
Done "layout under $InstallRoot"

# ------ 1. system ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'System: scripts, long paths, power, updates, time' {
  Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
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

# ------ 2. tooling ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Tooling: Git, Node, corepack' {
  Install-WingetPackage 'Git.Git' 'Git for Windows'
  Invoke-Native 'git' @('config', '--global', 'core.longpaths', 'true')
  Invoke-Native 'git' @('config', '--global', 'core.autocrlf', 'true')   # what the laptop checkout uses
  Install-Node $NodeMajor
  Invoke-Native 'corepack' @('enable')
  Done 'corepack enabled (pnpm version comes from package.json after the clone)'
}

# ------ 3. repo ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Repo: GitHub auth and clone' {
  Install-WingetPackage 'GitHub.cli' 'GitHub CLI'
  $status = Invoke-Capture 'gh' @('auth', 'status', '--hostname', 'github.com')
  if ($status.ExitCode -ne 0) {
    if ($GitHubToken) {
      $tokenFile = Join-Path $env:TEMP ('gh-token-' + [guid]::NewGuid().ToString('N'))
      Write-Utf8NoBom $tokenFile $GitHubToken
      try { Invoke-Native 'cmd.exe' @('/c', "gh auth login --hostname github.com --with-token < `"$tokenFile`"") }
      finally { Remove-Item $tokenFile -Force -ErrorAction SilentlyContinue }
    } else {
      Write-Host '   GitHub login (a browser window / device code follows):'
      Invoke-Native 'gh' @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web')
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

# ------ 4. env ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

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
  Invoke-Native 'icacls' @($EnvPath, '/inheritance:r', '/grant:r', 'SYSTEM:F', 'Administrators:F', "${me}:F") | Out-Null
  Done '.env ACL locked to SYSTEM, Administrators and you'
}

# ------ 5. defender ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Defender: exclude the video scratch dir and node_modules' {
  try {
    Add-MpPreference -ExclusionPath $TmpDir, (Join-Path $RepoDir 'node_modules') -ErrorAction Stop
    Done 'exclusions added'
  } catch { Skip "Defender not managing this machine ($($_.Exception.Message))" }
}

# ------ 6. build ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Build: install, prisma generate, worker bundle' {
  Invoke-Native 'pnpm' @('install', '--frozen-lockfile') $RepoDir
  # prisma.config.ts reads DATABASE_URL from the root .env; generation never connects, so the
  # template's well-formed placeholder is enough (docs/deploy-fly.md, "At db:generate").
  Invoke-Native 'pnpm' @('--filter', '@vra/adapters', 'db:generate') $RepoDir
  Invoke-Native 'pnpm' @('--filter', '@vra/worker', 'build') $RepoDir
  if (-not (Test-Path (Join-Path $RepoDir 'apps\worker\dist\main.js'))) { throw 'apps/worker/dist/main.js missing after build' }
  Done 'apps/worker/dist/main.js built'
}

# ------ 7. service ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step "Service: $ServiceName via NSSM" {
  $nssm = Install-Nssm
  $nodeExe = (Get-Command node).Source
  $workerDir = Join-Path $RepoDir 'apps\worker'   # cwd matters: main.ts loads ../../.env from here

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
  Set-NssmValue $nssm 'Start' @('SERVICE_DELAYED_AUTO_START')
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
  if ($NoStart) { Pending "service left stopped (-NoStart). Start-Service $ServiceName when the Fly machine / laptop worker is off" }
  elseif ($envText -match 'REPLACE_ME') { Pending 'service left stopped: .env still has REPLACE_ME values' }
  else {
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

# ------ 8. remote access ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Access: OpenSSH Server' {
  $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
  if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
  Set-Service -Name sshd -StartupType Automatic
  Start-Service sshd
  Set-RegistryValue 'HKLM:\SOFTWARE\OpenSSH' 'DefaultShell' "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" 'String'
  if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Direction Inbound `
      -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
  }
  Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -RemoteAddress $TailnetRanges
  Done 'sshd running, PowerShell as the shell, port 22 open to the tailnet and the LAN only'

  if ($SshPublicKey) {
    $akf = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    $existing = ''
    if (Test-Path $akf) { $existing = [IO.File]::ReadAllText($akf) }
    if ($existing -notmatch [regex]::Escape($SshPublicKey.Trim())) {
      Write-Utf8NoBom $akf (($existing.TrimEnd() + "`n" + $SshPublicKey.Trim() + "`n").TrimStart())
    }
    Invoke-Native 'icacls' @($akf, '/inheritance:r', '/grant:r', 'Administrators:F', 'SYSTEM:F') | Out-Null
    Done 'your public key authorised for administrators'
  } else { Pending 'no -SshPublicKey given: SSH will ask for your Windows password' }
}

Invoke-Step 'Access: Tailscale' {
  Install-WingetPackage 'Tailscale.Tailscale' 'Tailscale'
  $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  if (-not (Test-Path $ts)) { throw "tailscale.exe not found at $ts" }
  $state = ''
  try { $state = ((Invoke-Capture $ts @('status', '--json')).Output | ConvertFrom-Json).BackendState } catch { }
  if ($state -eq 'Running') { Skip 'already joined the tailnet' }
  elseif ($TailscaleAuthKey) {
    $hn = $env:COMPUTERNAME.ToLower()
    if ($ComputerName) { $hn = $ComputerName.ToLower() }
    Invoke-Native $ts @('up', "--auth-key=$TailscaleAuthKey", "--hostname=$hn", '--accept-dns=true')
    Done 'joined the tailnet'
  } else { Pending 'join the tailnet: run  & "C:\Program Files\Tailscale\tailscale.exe" up  and finish the login in the browser (or re-run with -TailscaleAuthKey)' }
}

Invoke-Step 'Access: Remote Desktop' {
  if (-not $EnableRdp) { Skip 'not requested (-EnableRdp)'; return }
  if ($isHome) { Pending 'Remote Desktop cannot be hosted on Windows Home; use SSH (Claude sessions over SSH end when you disconnect)'; return }
  Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
  Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
  $group = '@FirewallAPI.dll,-28752'   # "Remote Desktop", language-neutral
  Enable-NetFirewallRule -Group $group
  Get-NetFirewallRule -Group $group | Set-NetFirewallRule -RemoteAddress $TailnetRanges
  Done 'Remote Desktop on, reachable from the tailnet and the LAN only'
}

# ------ 9. heartbeat ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

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

# ------ 10. agents ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

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

# ------ 11. tools ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Invoke-Step 'Tools: update-worker.ps1' {
  $upd = Join-Path $ToolsDir 'update-worker.ps1'
  $body = @"
# Pull the current branch, rebuild the worker, restart the service, show the tail of the log.
`$ErrorActionPreference = 'Stop'
`$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
Set-Location '$RepoDir'
if ((git status --porcelain | Out-String).Trim()) { throw 'repo has local changes; commit or stash them first' }
git pull --ff-only
pnpm install --frozen-lockfile
pnpm --filter @vra/adapters db:generate
pnpm --filter @vra/worker build
Restart-Service -Name '$ServiceName'
Start-Sleep -Seconds 10
Get-Content '$WorkerLog' -Tail 20
"@
  Write-Utf8NoBom $upd $body
  Done "$upd (run it elevated after a push to $Branch)"
}

# ------ summary ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Write-Host "`n------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ' Done' -ForegroundColor Green
foreach ($l in $script:Report) { Write-Host "  - $l" }
if ($script:Pending.Count -gt 0) {
  Write-Host "`n Still to do" -ForegroundColor Yellow
  foreach ($l in $script:Pending) { Write-Host "  - $l" }
}
$tsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$dns = ''
if (Test-Path $tsExe) { try { $dns = ((Invoke-Capture $tsExe @('status', '--json')).Output | ConvertFrom-Json).Self.DNSName.TrimEnd('.') } catch { } }
Write-Host "`n Reach it" -ForegroundColor Cyan
if ($dns) { Write-Host "  ssh $env:USERNAME@$dns" } else { Write-Host "  ssh $env:USERNAME@<tailscale name>   (after tailscale up)" }
Write-Host "  Get-Service $ServiceName ; Get-Content '$WorkerLog' -Tail 50 -Wait"
Write-Host "  $ToolsDir\update-worker.ps1   after a push"
Write-Host "  Stop the Fly machine and the laptop worker once this one logs 'Processing agent run': one owner of the queue."
if ($script:RebootNeeded) { Write-Host "`n A reboot is needed (rename / Node install). The service starts on its own afterwards." -ForegroundColor Yellow }
