# Step 7: create the Gen2 VM "apps". Secure Boot OFF for the first boot (serial console usable); ceiling 2048 MB
# until node-peak.txt holds a measured busy-period value (budget rule); IOPS cap 1500 per disk (the real protection
# for the worker's shared spindle is scheduling, not the number). Idempotent for re-runs: refuses if the VM exists.
param([int]$VmMaxMB = 2048, [string]$Switch = 'AppsNAT')
$ErrorActionPreference = 'Stop'
if (Get-VM -Name apps -ErrorAction SilentlyContinue) { throw 'VM apps already exists; remove it first (Remove-VM apps -Force) if you mean to recreate it' }
New-VM -Name apps -Generation 2 -MemoryStartupBytes 1024MB -Path D:\hyperv\vms -VHDPath D:\hyperv\disks\apps-os.vhdx -SwitchName $Switch | Out-Null
Set-VM -Name apps -ProcessorCount 2 -DynamicMemory -MemoryMinimumBytes 768MB -MemoryStartupBytes 1024MB -MemoryMaximumBytes ($VmMaxMB * 1MB) -AutomaticStartAction Start -AutomaticStartDelay 90 -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false -CheckpointType Production -Notes 'apps: Ubuntu 24.04 + Docker Compose. Seed D:\hyperv\seed\apps-seed.iso. Runbook: cofounder-bootstrap/pci3-apps/README.md'
Set-VMMemory -VMName apps -Buffer 10
Set-VMProcessor -VMName apps -Count 2 -Reserve 0 -Maximum 75 -RelativeWeight 100
Set-VMFirmware -VMName apps -EnableSecureBoot Off
Set-VMNetworkAdapter -VMName apps -StaticMacAddress 00155D2800AA
Add-VMHardDiskDrive -VMName apps -Path D:\hyperv\disks\apps-data.vhdx
Add-VMHardDiskDrive -VMName apps -Path D:\hyperv\disks\apps-backup.vhdx
Add-VMDvdDrive -VMName apps -Path D:\hyperv\seed\apps-seed.iso
$os = Get-VMHardDiskDrive -VMName apps | Where-Object Path -like '*apps-os.vhdx'
Set-VMFirmware -VMName apps -FirstBootDevice $os
Set-VMComPort -VMName apps -Number 1 -Path \\.\pipe\apps-com1
# Integration service names are localized (French host), so the Guest Service Interface is matched by its ID.
Get-VMIntegrationService -VMName apps | Where-Object Id -like '*6C09BB55-D683-4DA0-8931-C9BF705F6480*' | Enable-VMIntegrationService
try { Get-VMHardDiskDrive -VMName apps | Set-VMHardDiskDrive -MaximumIOPS 1500; 'IOPS cap 1500 set on every disk' } catch { "IOPS cap not supported on this host: $($_.Exception.Message)" }
Get-VM apps | Format-List Name, State, Generation, ProcessorCount, DynamicMemoryEnabled, MemoryMinimum, MemoryStartup, MemoryMaximum, AutomaticStartAction, AutomaticStartDelay, AutomaticStopAction, AutomaticCheckpointsEnabled, CheckpointType | Out-String
Get-VMFirmware apps | Format-List SecureBoot, SecureBootTemplate | Out-String
(Get-VMFirmware apps).BootOrder | ForEach-Object { "$($_.BootType) $($_.Device.Path)$($_.Device.Name)" }
Get-VMHardDiskDrive apps | Format-Table ControllerLocation, Path, MaximumIOPS | Out-String
Get-VMDvdDrive apps | Format-Table Path | Out-String
Get-VMNetworkAdapter apps | Format-Table SwitchName, MacAddress | Out-String
