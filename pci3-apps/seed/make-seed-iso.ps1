param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Dest, [string]$Label = 'cidata')
# Builds a cloud-init NoCloud seed ISO (ISO9660 + Joliet, label cidata) with the built-in IMAPI2 COM API.
# Windows PowerShell 5.1 only (the /unsafe Add-Type needs the .NET Framework compiler).
$ErrorActionPreference = 'Stop'
$cp = New-Object CodeDom.Compiler.CompilerParameters
$cp.CompilerOptions = '/unsafe'
Add-Type -CompilerParameters $cp -TypeDefinition @'
public class ISOFile {
  public unsafe static void Create(string Path, object Stream, int BlockSize, int TotalBlocks) {
    int bytes = 0; byte[] buf = new byte[BlockSize];
    var ptr = (System.IntPtr)(&bytes);
    var o = System.IO.File.OpenWrite(Path);
    var i = Stream as System.Runtime.InteropServices.ComTypes.IStream;
    while (TotalBlocks-- > 0) { i.Read(buf, BlockSize, ptr); o.Write(buf, 0, bytes); }
    o.Flush(); o.Close();
  }
}
'@
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3      # ISO9660 + Joliet (keeps lowercase names)
$fsi.VolumeName = $Label
$fsi.Root.AddTree($Source, $false)
$img = $fsi.CreateResultImage()
if (Test-Path $Dest) { Remove-Item $Dest -Force }
[ISOFile]::Create($Dest, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
Get-Item $Dest | Select-Object FullName, Length
