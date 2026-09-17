# The reboot gate: exits 0 only when the production worker has nothing in flight.
# (a) no ffmpeg; (b) the worker's node process burns < 2 s CPU over 30 s; (c) the worker log has no
# "Processing ..." line without its matching finish, and the last job event is not an unfinished agent run.
$ErrorActionPreference = 'Continue'
$ff = @(Get-Process ffmpeg -ErrorAction SilentlyContinue).Count
$svc = Get-CimInstance Win32_Service -Filter "Name='CoFounderWorker'"
$node = $null
if ($svc.ProcessId -gt 0) { $child = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $svc.ProcessId) | Where-Object { $_.Name -eq 'node.exe' } | Select-Object -First 1; if ($child) { $node = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue } }
$cpuDelta = -1
if ($node) { $c1 = $node.TotalProcessorTime.TotalSeconds; Start-Sleep -Seconds 30; $n2 = Get-Process -Id $node.Id -ErrorAction SilentlyContinue; if ($n2) { $cpuDelta = [math]::Round($n2.TotalProcessorTime.TotalSeconds - $c1, 2) } }
$logPath = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CoFounderWorker\Parameters').AppStdout
$lines = Get-Content $logPath -Tail 400 -ErrorAction SilentlyContinue
$open = 0; $lastEvent = ''
foreach ($l in $lines) {
  if ($l -match '"msg":"Processing ([^"]+)"') { $open++; $lastEvent = 'Processing ' + $Matches[1] }
  elseif ($l -match '"msg":"[^"]*(finished|answered|completed|failed)[^"]*"') { if ($open -gt 0) { $open-- }; $lastEvent = 'finished' }
}
"ffmpeg=$ff nodePid=$(if ($node) { $node.Id } else { 'none' }) cpuDelta30s=$cpuDelta openJobs=$open lastEvent=$lastEvent"
$idle = ($ff -eq 0) -and ($cpuDelta -ge 0) -and ($cpuDelta -lt 2) -and ($open -le 0) -and ($lastEvent -notlike 'Processing*')
if ($idle) { "WORKER IDLE: safe to reboot"; exit 0 } else { "WORKER BUSY: do not reboot"; exit 1 }
