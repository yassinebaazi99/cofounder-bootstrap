# The daily "is everything fine?" view of the host + VM. Read-only.
Get-Service CoFounderWorker, HostTelemetry, vmms, vmcompute -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize | Out-String
"hypervisor=$((Get-CimInstance Win32_ComputerSystem).HypervisorPresent) uptimeMin=$([int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes) hiberboot=$((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled)"
Get-VM apps -ErrorAction SilentlyContinue | Format-Table State, Uptime, @{n = 'MemMB'; e = { [int]($_.MemoryAssigned / 1MB) } }, CPUUsage -AutoSize | Out-String
# Integration service names are localized (French host), so Heartbeat is matched by its ID.
"heartbeat=$((Get-VMIntegrationService -VMName apps -ErrorAction SilentlyContinue | Where-Object Id -like '*84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47*').PrimaryStatusDescription) ips=$((Get-VMNetworkAdapter -VMName apps -ErrorAction SilentlyContinue).IPAddresses -join ',')"
Get-VMFirmware apps -ErrorAction SilentlyContinue | Format-Table SecureBoot -AutoSize | Out-String
Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix, Active -AutoSize | Out-String
Get-NetIPAddress -InterfaceAlias 'vEthernet (AppsNAT)' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-Table IPAddress, PrefixLength -AutoSize | Out-String
Get-CimInstance Win32_OperatingSystem | Select-Object @{n = 'FreeMB'; e = { [int]($_.FreePhysicalMemory / 1KB) } } | Format-Table -AutoSize | Out-String
Get-PSDrive C, D | Select-Object Name, @{n = 'FreeGB'; e = { [int]($_.Free / 1GB) } } | Format-Table -AutoSize | Out-String
"worker peak (node+ffmpeg): $((Get-Content D:\hyperv\logs\node-peak.txt -ErrorAction SilentlyContinue) -join ' @ ')"
Get-Content D:\hyperv\logs\telemetry.csv -Tail 1 -ErrorAction SilentlyContinue
Get-ChildItem D:\hyperv\exports -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
