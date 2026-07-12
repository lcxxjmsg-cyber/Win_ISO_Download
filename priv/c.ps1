#requires -version 3.0
[CmdletBinding()]
param(
    [int]$Count      = 10,
    [string]$OutFile = ''
)

$SECRET = 'WISO-6dae1d0c95c84821-2026'

$ErrorActionPreference = 'Stop'
$alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
$sha = [System.Security.Cryptography.SHA256]::Create()
$rng = New-Object System.Random

function New-Serial {
    -join (1..8 | ForEach-Object { $alphabet[$rng.Next($alphabet.Length)] })
}
function New-Code {
    param([string]$Serial)
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($SECRET + '|' + $Serial.ToUpper()))
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return ($Serial.ToUpper() + '-' + $hex.Substring(0, 6).ToUpper())
}

$seen = @{}
$codes = New-Object System.Collections.Generic.List[string]
while ($codes.Count -lt $Count) {
    $s = New-Serial
    if ($seen.ContainsKey($s)) { continue }
    $seen[$s] = $true
    $codes.Add((New-Code $s))
}

$codes | ForEach-Object { Write-Host $_ }
if ($OutFile) {
    Set-Content -Path $OutFile -Value $codes -Encoding UTF8
    Write-Host ("`n已保存 {0} 个下载码到：{1}" -f $codes.Count, $OutFile) -ForegroundColor Green
}
