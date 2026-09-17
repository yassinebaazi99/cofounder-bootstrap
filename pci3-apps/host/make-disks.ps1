# Step 5 (box half): turn the shipped noble-raw.vhdx into apps-os.vhdx and create the data + backup disks.
# 1 MB block size everywhere (ext4 on dynamic VHDX; 32 MB blocks balloon the file). Data 250 GB, backup 120 GB:
# resize later with Resize-VHD when a measured need exists, so D: keeps its 250 GB floor for the worker's scratch.
$ErrorActionPreference = 'Stop'
$raw = 'D:\hyperv\images\noble-raw.vhdx'
"raw sha256: $((Get-FileHash $raw -Algorithm SHA256).Hash.ToLower())"
"raw test-vhd: $(Test-VHD -Path $raw)"
if (Test-Path D:\hyperv\disks\apps-os.vhdx) { Remove-Item D:\hyperv\disks\apps-os.vhdx }
Convert-VHD -Path $raw -DestinationPath D:\hyperv\disks\apps-os.vhdx -VHDType Dynamic -BlockSizeBytes 1MB
"os test-vhd: $(Test-VHD -Path D:\hyperv\disks\apps-os.vhdx)"
Get-VHD -Path D:\hyperv\disks\apps-os.vhdx | Format-List VhdFormat, VhdType, @{n = 'SizeGB'; e = { $_.Size / 1GB } }, @{n = 'FileGB'; e = { [math]::Round($_.FileSize / 1GB, 2) } }, BlockSize | Out-String
if (-not (Test-Path D:\hyperv\disks\apps-data.vhdx)) { New-VHD -Path D:\hyperv\disks\apps-data.vhdx -SizeBytes 250GB -Dynamic -BlockSizeBytes 1MB | Out-Null; 'apps-data.vhdx created (250 GB dynamic)' }
if (-not (Test-Path D:\hyperv\disks\apps-backup.vhdx)) { New-VHD -Path D:\hyperv\disks\apps-backup.vhdx -SizeBytes 120GB -Dynamic -BlockSizeBytes 1MB | Out-Null; 'apps-backup.vhdx created (120 GB dynamic)' }
Get-ChildItem D:\hyperv\disks | Format-Table Name, @{n = 'MB'; e = { [int]($_.Length / 1MB) } } | Out-String
"D free GB: $([int]((Get-PSDrive D).Free / 1GB))"
