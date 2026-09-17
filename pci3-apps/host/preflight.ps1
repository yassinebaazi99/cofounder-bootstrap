# Step 1: preflight + baseline for the apps platform on the CoFounder box. Read-only except for the D:\hyperv tree.
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force D:\hyperv\vms, D:\hyperv\disks, D:\hyperv\images, D:\hyperv\seed, D:\hyperv\scripts, D:\hyperv\exports, D:\hyperv\logs, D:\hyperv\secrets | Out-Null
# well-known SIDs: SYSTEM and Administrators (French Windows: "Administrateurs")
icacls D:\hyperv\secrets /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" /grant:r "*S-1-5-32-544:(OI)(CI)F"
"icacls exit: $LASTEXITCODE"
$params = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CoFounderWorker\Parameters'
$out = @()
$out += "== preflight $(Get-Date -Format s) =="
$out += "user=$(whoami) admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
$out += (Get-Service CoFounderWorker | Format-List Name, Status, StartType | Out-String)
$out += "worker Application=$($params.Application)"
$out += "worker AppDirectory=$($params.AppDirectory)"
$out += "worker AppStopMethodConsole=$($params.AppStopMethodConsole)"
$out += (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, @{n = 'FreeMB'; e = { [int]($_.FreePhysicalMemory / 1KB) } }, @{n = 'TotalMB'; e = { [int]($_.TotalVisibleMemorySize / 1KB) } } | Format-List | Out-String)
$out += (Get-Process node, ffmpeg -ErrorAction SilentlyContinue | Select-Object Name, Id, @{n = 'WS_MB'; e = { [int]($_.WorkingSet64 / 1MB) } }, @{n = 'PeakWS_MB'; e = { [int]($_.PeakWorkingSet64 / 1MB) } } | Format-Table | Out-String)
$out += (Get-PSDrive C, D | Select-Object Name, @{n = 'FreeGB'; e = { [int]($_.Free / 1GB) } } | Format-Table | Out-String)
$out += (Get-PhysicalDisk | Select-Object FriendlyName, MediaType, BusType, @{n = 'GB'; e = { [int]($_.Size / 1GB) } } | Format-Table | Out-String)
$out += (Get-WindowsOptionalFeature -Online | Where-Object FeatureName -in 'Microsoft-Hyper-V', 'Microsoft-Hyper-V-All', 'Microsoft-Hyper-V-Management-PowerShell', 'VirtualMachinePlatform', 'HypervisorPlatform' | Format-Table FeatureName, State | Out-String)
$out += "HypervisorPresent=$((Get-CimInstance Win32_ComputerSystem).HypervisorPresent)"
$out += (Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, LinkSpeed | Out-String)
$out += "curl=$((curl.exe --version | Select-Object -First 1))"
$out += "hiberboot=$((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled)"
$out += "defender exclusions=$((Get-MpPreference).ExclusionPath -join ';')"
$out += (netsh int ipv4 show dynamicport tcp | Out-String)
$out += (netsh int ipv4 show excludedportrange protocol=tcp | Out-String)
$out | Set-Content -Encoding utf8 D:\hyperv\baseline.txt
Get-Content D:\hyperv\baseline.txt
