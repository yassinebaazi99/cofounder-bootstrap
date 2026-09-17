# Step 4: Hyper-V default paths on D:, Defender exclusion, and the AppsNAT internal switch + NAT (10.28.0.0/24).
# Never an External switch: the only uplink is a USB Wi-Fi dongle. Idempotent.
$ErrorActionPreference = 'Stop'
Set-VMHost -VirtualHardDiskPath D:\hyperv\disks -VirtualMachinePath D:\hyperv\vms -EnableEnhancedSessionMode $false
Add-MpPreference -ExclusionPath D:\hyperv -ErrorAction SilentlyContinue
'-- existing NATs:'; Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix, Active | Out-String
if (-not (Get-VMSwitch -Name AppsNAT -ErrorAction SilentlyContinue)) { New-VMSwitch -SwitchName AppsNAT -SwitchType Internal | Out-Null; 'switch AppsNAT created' }
# the vEthernet adapter appears asynchronously after the switch: poll up to 30 s
$ad = $null
for ($i = 0; $i -lt 30 -and -not $ad; $i++) { $ad = Get-NetAdapter -Name 'vEthernet (AppsNAT)' -ErrorAction SilentlyContinue; if (-not $ad) { Start-Sleep 1 } }
if (-not $ad) { throw 'vEthernet (AppsNAT) never appeared' }
$ifIndex = $ad.ifIndex
if (-not (Get-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.28.0.1 -ErrorAction SilentlyContinue)) { New-NetIPAddress -IPAddress 10.28.0.1 -PrefixLength 24 -InterfaceIndex $ifIndex | Out-Null; 'host address 10.28.0.1/24 set' }
if (-not (Get-NetNat -Name AppsNAT -ErrorAction SilentlyContinue)) { New-NetNat -Name AppsNAT -InternalIPInterfaceAddressPrefix 10.28.0.0/24 | Out-Null; 'NAT AppsNAT created' }
'-- result:'
Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix, Active | Out-String
Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Format-Table IPAddress, PrefixLength | Out-String
Get-VMHost | Format-List VirtualHardDiskPath, VirtualMachinePath | Out-String
"exclusions: $((Get-MpPreference).ExclusionPath -join ';')"
