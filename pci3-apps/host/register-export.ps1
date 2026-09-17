# Registers the monthly export task (every fourth Sunday 06:00, after the update window), low priority.
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File D:\hyperv\scripts\export-apps.ps1'
$t = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At 06:00
$p = New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6) -Priority 7
Register-ScheduledTask -TaskName 'HyperV-Export-apps' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Select-Object TaskName, State
