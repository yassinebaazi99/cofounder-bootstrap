<#
.SYNOPSIS
  Point this laptop at the CoFounder server so a Claude Code session here can drive it over SSH.

.DESCRIPTION
  Run on the LAPTOP, after the server ran provision-windows-server.ps1 (at least its access-only
  form) and printed its USER and tailnet NAME. Four steps, each idempotent:

    1. Tailscale on this laptop (winget, one UAC prompt) and `tailscale up` if it is not joined:
       the same tailnet as the server, so the box is reachable from any network.
    2. An ed25519 key at ~/.ssh/id_ed25519 if there is none. The server script authorises the
       laptop key it was given; a different laptop passes its own key as -SshPublicKey there.
    3. A `Host <Alias>` block in ~/.ssh/config (HostName, User, key, keepalives, accept-new host
       keys). Any older block with the same alias is replaced, everything else is kept.
    4. A connection test: hostname, user, Windows edition and the sshd state, read over SSH.
       The remote shell is PowerShell, so the same commands work there as here.

  From then on, every shell and every Claude session on this laptop has the box one command
  away:

    ssh cofounder-srv "Get-Service CoFounderWorker"
    ssh cofounder-srv "Get-Content C:\srv\cofounder\logs\worker.log -Tail 50"
    ssh cofounder-srv "C:\srv\cofounder\tools\update-worker.ps1"
    scp .\some-file cofounder-srv:C:\srv\cofounder\

  Nothing here reads or prints a secret. The private key never leaves ~/.ssh.

.EXAMPLE
  .\scripts\connect-cofounder-srv.ps1 -User yassine -HostName cofounder-srv.tail1234.ts.net

.EXAMPLE
  # Same Wi-Fi only, no Tailscale on the laptop
  .\scripts\connect-cofounder-srv.ps1 -User yassine -HostName 192.168.1.50 -SkipTailscale

.PARAMETER User
  The Windows username on the server (the USER line the server script printed).
.PARAMETER HostName
  Where the server answers: its tailnet name (name.tailXXXX.ts.net), its Tailscale IP (100.x.y.z)
  or a LAN IP (the NAME / IP lines the server script printed).
.PARAMETER Alias
  The SSH alias to write. Default: cofounder-srv (what the docs and the memory notes use).
.PARAMETER SkipTailscale
  Do not install or join Tailscale on this laptop (LAN-only use).
.PARAMETER ConfigPath
  The ssh config to edit. Default: ~/.ssh/config. Another path is for testing the edit.
.PARAMETER NoTest
  Write the config but do not open a connection.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$User,
  [Parameter(Mandatory = $true)][string]$HostName,
  [string]$Alias = 'cofounder-srv',
  [switch]$SkipTailscale,
  [string]$ConfigPath = (Join-Path $env:USERPROFILE '.ssh\config'),
  [switch]$NoTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Done([string]$Text) { Write-Host "   ok    $Text" -ForegroundColor Green }
function Todo([string]$Text) { Write-Host "   TODO  $Text" -ForegroundColor Yellow }
function Skip([string]$Text) { Write-Host "   skip  $Text" -ForegroundColor DarkGray }

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

$sshDir = Split-Path -Parent $ConfigPath
$keyPath = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
$tsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$looksTailnet = ($HostName -match '\.ts\.net$') -or ($HostName -match '^100\.') -or ($HostName -match '^fd7a:')

# ------ 1. tailscale on the laptop ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Write-Step 'Tailscale on this laptop'
if ($SkipTailscale) { Skip 'not requested (-SkipTailscale)' }
else {
  if (-not (Test-Path $tsExe)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget is missing: install "App Installer" from the Microsoft Store, or pass -SkipTailscale' }
    Write-Host '   installing Tailscale (a UAC prompt may appear)'
    $r = Invoke-Capture 'winget' @('install', '--id', 'Tailscale.Tailscale', '--exact', '--silent',
      '--accept-package-agreements', '--accept-source-agreements')
    if ($r.ExitCode -ne 0 -and $r.ExitCode -ne -1978335189 -and -not (Test-Path $tsExe)) { throw "winget install Tailscale exited with $($r.ExitCode): $($r.Output)" }
    Done 'Tailscale installed'
  } else { Skip 'Tailscale already installed' }

  $state = ''
  try { $state = ((Invoke-Capture $tsExe @('status', '--json')).Output | ConvertFrom-Json).BackendState } catch { }
  if ($state -ne 'Running') {
    Write-Host '   joining the tailnet: a browser login follows (same Tailscale account as the server)' -ForegroundColor Magenta
    $r = Invoke-Capture $tsExe @('up', '--accept-dns=true', '--timeout=10m')
    if ($r.ExitCode -ne 0) { Todo "tailscale up did not finish: $($r.Output.Trim())" }
    try { $state = ((Invoke-Capture $tsExe @('status', '--json')).Output | ConvertFrom-Json).BackendState } catch { }
  }
  if ($state -eq 'Running') {
    Done 'this laptop is on the tailnet'
    # Is the server visible from here?
    try {
      $st = (Invoke-Capture $tsExe @('status', '--json')).Output | ConvertFrom-Json
      $peer = $null
      foreach ($p in $st.Peer.PSObject.Properties) {
        $v = $p.Value
        $dns = ([string]$v.DNSName).TrimEnd('.')
        if ($dns -ieq $HostName -or (@($v.TailscaleIPs) -contains $HostName) -or ($HostName -notmatch '\.' -and $dns -like "$HostName.*")) { $peer = $v; break }
      }
      if ($peer) {
        $online = if ($peer.Online) { 'online' } else { 'OFFLINE' }
        Write-Host "   server on the tailnet: $(([string]$peer.DNSName).TrimEnd('.'))  ($online)"
      } elseif ($looksTailnet) { Todo "no tailnet peer named $HostName yet: check the server finished `tailscale up` on the same account" }
    } catch { }
  } elseif ($looksTailnet) { Todo 'not on the tailnet: the tailnet name/IP will not resolve until you are' }
}

# ------ 2. key ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Write-Step 'SSH key'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
if (Test-Path $keyPath) { Skip "using $keyPath" }
else {
  $r = Invoke-Capture 'ssh-keygen' @('-t', 'ed25519', '-N', '', '-f', $keyPath, '-C', "claude-code@$($env:COMPUTERNAME.ToLower())")
  if ($r.ExitCode -ne 0) { throw "ssh-keygen failed: $($r.Output)" }
  Done "new key $keyPath"
  Todo "authorise it on the server: re-run the server script with -SshPublicKey `"$(Get-Content "$keyPath.pub" -Raw | ForEach-Object { $_.Trim() })`""
}

# ------ 3. ~/.ssh/config --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Write-Step "Host $Alias in $ConfigPath"
$existing = ''
if (Test-Path $ConfigPath) { $existing = [IO.File]::ReadAllText($ConfigPath) }
# Split into blocks at every "Host"/"Match" keyword line; drop the block(s) whose Host tokens
# include the alias; keep the rest byte for byte.
$lines = @($existing -split "`r?`n")
$blocks = New-Object 'System.Collections.Generic.List[object]'
$current = New-Object 'System.Collections.Generic.List[string]'
foreach ($line in $lines) {
  if ($line -match '^\s*(Host|Match)\s' -and $current.Count -gt 0) { $blocks.Add($current.ToArray()); $current = New-Object 'System.Collections.Generic.List[string]' }
  $current.Add($line)
}
if ($current.Count -gt 0) { $blocks.Add($current.ToArray()) }
$kept = New-Object 'System.Collections.Generic.List[string]'
$replaced = $false
foreach ($b in $blocks) {
  $head = [string]$b[0]
  if ($head -match '^\s*Host\s+(.+)$') {
    $names = @($Matches[1].Trim() -split '\s+')
    if ($names -contains $Alias) { $replaced = $true; continue }
  }
  foreach ($l in $b) { $kept.Add($l) }
}
while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }
$block = @(
  "Host $Alias",
  "  HostName $HostName",
  "  User $User",
  "  IdentityFile ~/.ssh/id_ed25519",
  "  IdentitiesOnly yes",
  "  ServerAliveInterval 30",
  "  ServerAliveCountMax 4",
  "  StrictHostKeyChecking accept-new"
)
$text = (($kept + @('') + $block) -join "`n").TrimStart("`n") + "`n"
Write-Utf8NoBom $ConfigPath $text
if ($replaced) { Done "replaced the Host $Alias block (user $User, host $HostName)" } else { Done "added Host $Alias (user $User, host $HostName)" }

# ------ 4. test ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Write-Step 'Connection test'
if ($NoTest) { Skip 'not requested (-NoTest)' }
else {
  # The remote shell is PowerShell (the server script set OpenSSH's DefaultShell). No double
  # quotes in the remote command: they would be eaten between ssh.exe and sshd on Windows.
  $remote = 'hostname; whoami; (Get-CimInstance Win32_OperatingSystem).Caption; (Get-Service sshd).Status'
  $sshArgs = @('-F', $ConfigPath, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $Alias, $remote)
  $r = Invoke-Capture 'ssh' $sshArgs
  $out = $r.Output.Trim()
  if ($r.ExitCode -eq 0) {
    $parts = @($out -split "`r?`n" | Where-Object { $_.Trim() })
    Write-Host "   host: $($parts[0])"
    if ($parts.Count -gt 1) { Write-Host "   user: $($parts[1])" }
    if ($parts.Count -gt 2) { Write-Host "   os:   $($parts[2])" }
    if ($parts.Count -gt 3) { Write-Host "   sshd: $($parts[3])" }
    Done "ssh $Alias works with the key, no password"
  } else {
    Write-Host "   $out" -ForegroundColor Red
    if ($out -match 'Permission denied') { Todo "the server does not have this laptop's key: on the server, re-run the provisioning script (its default key is the msi laptop's; another laptop passes -SshPublicKey)" }
    elseif ($out -match 'Could not resolve|Connection timed out|No route|Connection refused') { Todo "cannot reach $HostName from here: same tailnet (tailscale status) or same LAN, and sshd running on the server" }
    else { Todo "ssh exited with $($r.ExitCode)" }
  }
}

Write-Host ''
Write-Host ' From here on' -ForegroundColor Cyan
Write-Host "  ssh $Alias `"<any PowerShell>`"          run one command on the server"
Write-Host "  ssh $Alias                               interactive PowerShell on the server"
Write-Host "  scp <file> ${Alias}:C:\srv\cofounder\     copy a file over"
Write-Host "  ssh $Alias `"Get-Content C:\srv\cofounder\logs\worker.log -Tail 50`""
