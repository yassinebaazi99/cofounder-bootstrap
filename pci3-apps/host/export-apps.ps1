# Monthly whole-VM export to D:\hyperv\exports (keeps one). Refuses when D: would drop under the worker's 250 GB floor,
# waits (bounded) while the worker is decoding, and verifies the export where Export-VM actually writes it.
$ErrorActionPreference = 'Stop'
$root = 'D:\hyperv\exports'; New-Item -ItemType Directory -Force $root | Out-Null
$vhdxBytes = (Get-ChildItem D:\hyperv\disks -Filter *.vhdx | Measure-Object Length -Sum).Sum
$freeAfter = ((Get-PSDrive D).Free - $vhdxBytes) / 1GB
if ($freeAfter -lt 250) { Add-Content D:\hyperv\logs\export.log "$(Get-Date -Format s) export REFUSED: D: would fall to $([int]$freeAfter) GB"; throw "export refused: D: floor" }
$waited = 0
while ((Get-Process ffmpeg -ErrorAction SilentlyContinue) -and $waited -lt 5400) { Start-Sleep 60; $waited += 60 }
$dest = Join-Path $root (Get-Date -Format yyyyMMdd)
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Export-VM -Name apps -Path $dest
$disks = Get-ChildItem (Join-Path $dest 'apps\Virtual Hard Disks') -Filter *.vhdx -ErrorAction SilentlyContinue
if (@($disks).Count -lt 3) { throw "export incomplete: $(@($disks).Count) vhdx under $dest\apps\Virtual Hard Disks" }
Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -Skip 1 | Remove-Item -Recurse -Force
$gb = [math]::Round((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1GB, 2)
Add-Content D:\hyperv\logs\export.log "$(Get-Date -Format s) export ok $dest $gb GB (waited $waited s for ffmpeg)"
"export ok $dest $gb GB"
