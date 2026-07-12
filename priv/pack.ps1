#requires -version 3.0
param(
    [string]$In  = 'simp.ps1',
    [string]$Out = 'simp.packed.ps1'
)
$ErrorActionPreference = 'Stop'
$base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$src  = Join-Path $base $In
$dst  = Join-Path $base $Out

$text  = Get-Content -Raw -Encoding UTF8 $src
$bytes = [Text.Encoding]::UTF8.GetBytes($text)
$ms = New-Object System.IO.MemoryStream
$gz = New-Object System.IO.Compression.GzipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
$gz.Write($bytes, 0, $bytes.Length); $gz.Close()
$b64 = [Convert]::ToBase64String($ms.ToArray())

$tpl = @'
$b='__B64__'
$ms=New-Object System.IO.MemoryStream(,[Convert]::FromBase64String($b))
$gz=New-Object System.IO.Compression.GzipStream($ms,[System.IO.Compression.CompressionMode]::Decompress)
$sr=New-Object System.IO.StreamReader($gz,[Text.Encoding]::UTF8)
$code=$sr.ReadToEnd();$sr.Close()
& ([scriptblock]::Create($code)) @args
'@
$loader = $tpl -replace '__B64__', $b64
Set-Content -Path $dst -Value $loader -Encoding ASCII
Write-Host ("已生成 {0}（{1} KB）" -f $Out, [math]::Round((Get-Item $dst).Length / 1KB, 1)) -ForegroundColor Green
