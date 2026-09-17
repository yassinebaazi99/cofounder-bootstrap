# Step 9 (host half): try Secure Boot ON with the Microsoft UEFI CA template; revert to OFF if the guest does not heartbeat in 3 min.
$ErrorActionPreference = 'Stop'
Stop-VM -Name apps; Start-Sleep 5
Set-VMFirmware -VMName apps -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
Start-VM -Name apps
$ok = $false
# Integration service names are localized (French host), so Heartbeat is matched by its ID.
for ($i = 0; $i -lt 18; $i++) { Start-Sleep 10; if ((Get-VMIntegrationService -VMName apps | Where-Object Id -like '*84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47*').PrimaryStatusDescription -eq 'OK') { $ok = $true; break } }
if ($ok) { 'SECUREBOOT ON: guest booted' } else {
  'SECUREBOOT ON: no heartbeat in 3 min -> reverting to Off'
  Stop-VM -Name apps -TurnOff; Start-Sleep 3
  Set-VMFirmware -VMName apps -EnableSecureBoot Off
  Start-VM -Name apps
}
Get-VMFirmware apps | Format-List SecureBoot, SecureBootTemplate | Out-String
