# Step 2: host telemetry, runs forever as the NSSM service HostTelemetry (below-normal priority).
# Records free RAM, CPU, D: free, the worker's working set and its LIFETIME peak (PeakWorkingSet64 of the
# node process owned by the CoFounderWorker service, plus any ffmpeg), the VM state once one exists.
$log = 'D:\hyperv\logs\telemetry.csv'; $peakFile = 'D:\hyperv\logs\node-peak.txt'; $pushFile = 'D:\hyperv\secrets\kuma-push.txt'
$header = 'ts,freeMB,cpuPct,dFreeGB,workerWsMB,workerPeakMB,ffmpegProcs,ffmpegWsMB,vmState,vmMemMB'
$peak = 0; if (Test-Path $peakFile) { try { $peak = [int](Get-Content $peakFile | Select-Object -First 1) } catch { $peak = 0 } }
$ffPeak = 0; $tick = 0
while ($true) {
  try {
    $tick++
    # ffmpeg is short-lived: sample it every 10 s, write a CSV row every 60 s
    $ff = @(Get-Process ffmpeg -ErrorAction SilentlyContinue)
    $ffWs = [int](($ff | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    if ($ffWs -gt $ffPeak) { $ffPeak = $ffWs }
    if ($tick % 6 -eq 0) {
      if (-not (Test-Path $log)) { $header | Set-Content -Encoding ascii $log }
      $os = Get-CimInstance Win32_OperatingSystem
      $free = [int]($os.FreePhysicalMemory / 1KB)
      $cpu = [int](Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
      $dfree = [int]((Get-PSDrive D).Free / 1GB)
      $svc = Get-CimInstance Win32_Service -Filter "Name='CoFounderWorker'"
      $node = $null
      if ($svc.ProcessId -gt 0) { $child = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $svc.ProcessId) | Where-Object { $_.Name -eq 'node.exe' } | Select-Object -First 1; if ($child) { $node = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue } }
      $ws = 0; $lifetimePeak = 0
      if ($node) { $ws = [int]($node.WorkingSet64 / 1MB); $lifetimePeak = [int]($node.PeakWorkingSet64 / 1MB) }
      $combined = $lifetimePeak + $ffPeak
      if ($combined -gt $peak) { $peak = $combined; "$peak`n$(Get-Date -Format s)`nnode_lifetime_peak=$lifetimePeak ffmpeg_peak=$ffPeak" | Set-Content -Encoding ascii $peakFile }
      $vmState = ''; $vmMem = 0
      if (Get-Command Get-VM -ErrorAction SilentlyContinue) { $vm = Get-VM apps -ErrorAction SilentlyContinue; if ($vm) { $vmState = $vm.State; $vmMem = [int]($vm.MemoryAssigned / 1MB) } }
      "$(Get-Date -Format s),$free,$cpu,$dfree,$ws,$peak,$($ff.Count),$ffWs,$vmState,$vmMem" | Add-Content -Encoding ascii $log
      if ((Get-Item $log).Length -gt 20MB) { Move-Item $log "$log.1" -Force }
      if (Test-Path $pushFile) {
        $u = (Get-Content $pushFile -First 1).Trim().Split('?')[0]
        $status = if ($dfree -lt 250) { 'down' } else { 'up' }
        if ($u) { Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 "$u`?status=$status&msg=free${free}MB_worker${ws}MB_vm${vmMem}MB_d${dfree}GB&ping=$free" | Out-Null }
      }
    }
  } catch { Add-Content D:\hyperv\logs\telemetry.err "$(Get-Date -Format s) $_" }
  Start-Sleep 10
}
