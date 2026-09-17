# Emergency serial console reader for the VM (COM1 -> \\.\pipe\apps-com1). Reads with a timeout so it can never hang.
param([int]$Seconds = 60)
$p = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'apps-com1', [System.IO.Pipes.PipeDirection]::In)
$p.Connect(5000)
$sw = [Diagnostics.Stopwatch]::StartNew()
$buf = New-Object byte[] 4096
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
  $t = $p.ReadAsync($buf, 0, $buf.Length)
  if ($t.Wait(2000)) { if ($t.Result -le 0) { break }; [Console]::Out.Write([Text.Encoding]::ASCII.GetString($buf, 0, $t.Result)) }
}
$p.Dispose()
