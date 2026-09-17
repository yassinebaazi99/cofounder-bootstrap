# Step 2: register host-telemetry.ps1 as the NSSM service HostTelemetry. Idempotent.
$ErrorActionPreference = 'Continue'
$nssm = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CoFounderWorker').ImagePath).Trim('"')
"nssm: $nssm"
$enc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::Unicode
if (-not (Get-Service HostTelemetry -ErrorAction SilentlyContinue)) {
  & $nssm install HostTelemetry 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' '-NoProfile -ExecutionPolicy Bypass -File D:\hyperv\scripts\host-telemetry.ps1'
}
& $nssm set HostTelemetry AppDirectory D:\hyperv\scripts
& $nssm set HostTelemetry Start SERVICE_AUTO_START
& $nssm set HostTelemetry AppPriority BELOW_NORMAL_PRIORITY_CLASS
& $nssm set HostTelemetry AppStdout D:\hyperv\logs\host-telemetry.out.log
& $nssm set HostTelemetry AppStderr D:\hyperv\logs\host-telemetry.out.log
& $nssm set HostTelemetry AppRotateFiles 1
& $nssm set HostTelemetry AppRotateBytes 5242880
& $nssm set HostTelemetry AppExit Default Restart
& $nssm set HostTelemetry AppRestartDelay 30000
[Console]::OutputEncoding = $enc
Restart-Service HostTelemetry -ErrorAction SilentlyContinue
if ((Get-Service HostTelemetry).Status -ne 'Running') { Start-Service HostTelemetry }
Start-Sleep 75
Get-Service HostTelemetry | Format-Table Name, Status, StartType | Out-String
"telemetry.csv tail:"; Get-Content D:\hyperv\logs\telemetry.csv -Tail 2 -ErrorAction SilentlyContinue
"node-peak.txt:"; Get-Content D:\hyperv\logs\node-peak.txt -ErrorAction SilentlyContinue
if (Test-Path D:\hyperv\logs\telemetry.err) { "telemetry.err tail:"; Get-Content D:\hyperv\logs\telemetry.err -Tail 3 }
