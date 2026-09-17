# Step 8: start the VM if needed and wait for its heartbeat + SSH on the NAT address.
param([string]$Ip = '10.28.0.10', [int]$Tries = 40)
if ((Get-VM apps).State -ne 'Running') { Start-VM -Name apps; 'VM started' }
for ($i = 0; $i -lt $Tries; $i++) {
  # Integration service names are localized (French host: 'Pulsation'), so match the Heartbeat service by its ID.
  $vm = Get-VM apps; $hb = (Get-VMIntegrationService -VMName apps | Where-Object Id -like '*84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47*').PrimaryStatusDescription
  "$(Get-Date -Format T) state=$($vm.State) hb=$hb memMB=$([int]($vm.MemoryAssigned/1MB)) cpu=$($vm.CPUUsage)%"
  if ($hb -eq 'OK' -and (Test-NetConnection $Ip -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)) { 'SSH UP'; break }
  Start-Sleep 10
}
