#requires -version 3.0
[CmdletBinding()]
param(
    [string]$OutDir      = '',
    [string]$ToolsDir    = '',
    [int]$Connections    = 1,
    [string]$Key         = 'free',
    [switch]$KeepArchive
)

$ErrorActionPreference = 'Stop'

$InMemory = [string]::IsNullOrEmpty($PSCommandPath) -and [string]::IsNullOrEmpty($MyInvocation.MyCommand.Path)

if ($InMemory) {
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    if ($desktop -and (Test-Path $desktop)) { $BaseDir = $desktop }
    elseif (Test-Path 'D:\')                { $BaseDir = 'D:\' }
    else                                    { $BaseDir = "$env:SystemDrive\" }
    $BaseDir = Join-Path $BaseDir 'WinISO'
} else {
    $BaseDir = if ($PSScriptRoot) { $PSScriptRoot }
               elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
               elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
               else { (Get-Location).Path }
}
if (-not $OutDir)   { $OutDir   = Join-Path $BaseDir 'downloads' }
if (-not $ToolsDir) { $ToolsDir = Join-Path $BaseDir 'bin' }

$Server = 'https://files.rg-adguard.net'
$UA     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

function Write-Info  { param($m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host $m -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host $m -ForegroundColor Yellow }
function Write-Err2  { param($m) Write-Host $m -ForegroundColor Red }

function Get-Html {
    param([string]$Url)
    for ($i = 1; $i -le 3; $i++) {
        try {
            return (Invoke-WebRequest -Uri $Url -UserAgent $UA -Headers @{ 'Accept-Language' = 'en-US,en;q=0.9' } -UseBasicParsing -TimeoutSec 60).Content
        } catch {
            if ($i -eq 3) { throw }
            Start-Sleep -Seconds ($i * 2)
        }
    }
}

function Get-ChildNodes {
    param([string]$Html, [string[]]$AncestorUrls)
    $rx = [regex]'href="(https://files\.rg-adguard\.net/(category|version|language|files|file)/[0-9a-f-]{36})">([^<]+)</a>'
    $seen = @{}
    $out  = New-Object System.Collections.Generic.List[object]
    foreach ($m in $rx.Matches($Html)) {
        $url  = $m.Groups[1].Value
        $type = $m.Groups[2].Value
        $name = [System.Net.WebUtility]::HtmlDecode($m.Groups[3].Value).Trim()
        if ($AncestorUrls -contains $url) { continue }
        if ($seen.ContainsKey($url))      { continue }
        $seen[$url] = $true
        $out.Add([pscustomobject]@{ Name = $name; Url = $url; Type = $type })
    }
    return $out
}

function Get-FileMeta {
    param([string]$Html)
    $get = {
        param($label)
        $m = [regex]::Match($Html, "<b>$label</b>:</td><td class=""desc"">\s*([^<]+)</td>")
        if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim() }
        return $null
    }
    [pscustomobject]@{
        File   = (& $get 'File')
        Size   = (& $get 'Size')
        SHA1   = (& $get 'SHA-1')
        SHA256 = (& $get 'SHA-256')
    }
}

function Get-DownloadEntries {
    param([string]$Uuid)
    $raw = (Invoke-WebRequest -Uri "$Server/dl/$Key/$Uuid" -UserAgent $UA -UseBasicParsing -TimeoutSec 60).Content
    $entries = New-Object System.Collections.Generic.List[object]
    $blocks  = $raw -split "(?=https://)"
    foreach ($b in $blocks) {
        $b = $b.Trim()
        if (-not $b) { continue }
        $url = ([regex]::Match($b, '^(https://\S+)')).Groups[1].Value
        if (-not $url) { continue }
        $out  = ([regex]::Match($b, 'out=(\S+)')).Groups[1].Value
        $sha1 = ([regex]::Match($b, 'checksum=sha-1=(\S+)')).Groups[1].Value
        $fu   = ([regex]::Match($url, '/files/([0-9a-f-]{36})')).Groups[1].Value
        $entries.Add([pscustomobject]@{ Url = $url; Out = $out; Sha1 = $sha1; Uuid = $fu })
    }
    return $entries
}

function Convert-ToGB {
    param([string]$s)
    if (-not $s) { return 0 }
    $m = [regex]::Match($s, '([\d.]+)\s*(TB|GB|MB|KB|B)')
    if (-not $m.Success) { return 0 }
    $v = [double]$m.Groups[1].Value
    switch ($m.Groups[2].Value.ToUpper()) {
        'TB' { $v * 1024 }
        'GB' { $v }
        'MB' { $v / 1024 }
        'KB' { $v / 1024 / 1024 }
        'B'  { $v / 1GB }
        default { 0 }
    }
}

function Get-BundleList {
    param([string]$Uuid)
    $raw = (Invoke-WebRequest -Uri "$Server/file/$Uuid/list" -UserAgent $UA -UseBasicParsing -TimeoutSec 40).Content
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($raw -split "`n")) {
        $p = $line.Trim() -split '\|'
        if ($p.Count -ge 2 -and $p[0]) {
            $sz = if ($p.Count -ge 3) { $p[2].Trim() } else { '' }
            $list.Add([pscustomobject]@{ Uuid = $p[0].Trim(); Name = $p[1].Trim(); Size = $sz; SizeGB = (Convert-ToGB $sz) })
        }
    }
    return $list
}

function Get-RemoteSha1 {
    param([string]$Uuid)
    try {
        return ((Invoke-WebRequest -Uri "$Server/file/$Uuid/sha1" -UserAgent $UA -UseBasicParsing -TimeoutSec 40).Content).Trim()
    } catch { return $null }
}

function Resolve-Tools {
    $aria = $null; $sevenzip = $null
    $c = Get-Command aria2c -ErrorAction SilentlyContinue; if ($c) { $aria = $c.Source }
    if (-not $aria -and (Test-Path (Join-Path $ToolsDir 'aria2c.exe'))) { $aria = Join-Path $ToolsDir 'aria2c.exe' }
    foreach ($p in @((Join-Path $ToolsDir '7z.exe'), "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path $p) { $sevenzip = $p; break }
    }
    if (-not $sevenzip) { $c = Get-Command 7z -ErrorAction SilentlyContinue; if ($c) { $sevenzip = $c.Source } }
    $smv = if (Test-Path (Join-Path $ToolsDir 'smv.exe')) { Join-Path $ToolsDir 'smv.exe' } else { $null }
    $dvp = if (Test-Path (Join-Path $ToolsDir 'dvp.exe')) { Join-Path $ToolsDir 'dvp.exe' } else { $null }

    if (-not $aria -or -not $sevenzip -or -not $smv -or -not $dvp) {
        Write-Warn2 "缺少工具，正在从 $Server/tools 下载工具集（aria2c + 7z）..."
        if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }
        $cab = Join-Path $ToolsDir 'tools.cab'
        Invoke-WebRequest -Uri "$Server/tools" -UserAgent $UA -OutFile $cab -UseBasicParsing -TimeoutSec 120
        $tmpEx = Join-Path $ToolsDir ('_extract_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpEx -Force | Out-Null
        & expand.exe -F:* $cab $tmpEx | Out-Null
        Get-ChildItem -Path $tmpEx -File -Recurse | ForEach-Object {
            Copy-Item $_.FullName -Destination (Join-Path $ToolsDir $_.Name) -Force
        }
        Remove-Item $tmpEx -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $cab -Force -ErrorAction SilentlyContinue
        if (Test-Path (Join-Path $ToolsDir 'aria2c.exe')) { $aria = Join-Path $ToolsDir 'aria2c.exe' }
        if (Test-Path (Join-Path $ToolsDir '7z.exe'))     { $sevenzip = Join-Path $ToolsDir '7z.exe' }
        if (Test-Path (Join-Path $ToolsDir 'smv.exe'))    { $smv = Join-Path $ToolsDir 'smv.exe' }
        if (Test-Path (Join-Path $ToolsDir 'dvp.exe'))    { $dvp = Join-Path $ToolsDir 'dvp.exe' }
    }
    if (-not $aria)     { throw 'aria2c 不可用。' }
    if (-not $sevenzip) { throw '7z 不可用。' }
    [pscustomobject]@{ Aria = $aria; SevenZip = $sevenzip; Smv = $smv; Dvp = $dvp }
}

function Invoke-Download {
    param([object[]]$Entries, [hashtable]$Names, [object]$Tools)
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $total = $Entries.Count
    for ($idx = 0; $idx -lt $total; $idx++) {
        $e = $Entries[$idx]
        $label = if ($Names -and $Names.ContainsKey($e.Uuid)) { $Names[$e.Uuid] } else { $e.Uuid }
        $sizeLabel = ''
        if ($Names -and $Names.ContainsKey(($e.Uuid + '_size'))) { $sizeLabel = ' (' + $Names[$e.Uuid + '_size'] + ')' }
        Write-Info ("[{0}/{1}] {2}{3}" -f ($idx + 1), $total, $label, $sizeLabel)
        $arc = Join-Path $OutDir "$($e.Uuid).7z"
        if (Test-Path $arc) {
            if (Test-Path "$arc.aria2") {
                Write-Host ('  检测到未完成的下载，继续续传 ...' ) -ForegroundColor DarkGray
            } else {
                Write-Host ('  已有文件且已完成，跳过下载' ) -ForegroundColor DarkGray; continue
            }
        }
        $inputFile = Join-Path $env:TEMP ("rgiso_{0}.txt" -f ([guid]::NewGuid().ToString('N')))
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine($e.Url)
        [void]$sb.AppendLine("  out=$($e.Uuid).7z")
        if ($e.Sha1) { [void]$sb.AppendLine("  checksum=sha-1=$($e.Sha1)") }
        Set-Content -Path $inputFile -Value $sb.ToString() -Encoding ASCII
        $aria2Args = @(
            '--input-file', ('"{0}"' -f $inputFile),
            '--dir', ('"{0}"' -f $OutDir),
            '-x', $Connections, '-s', $Connections, '-j', 1,
            '-c', '-R', '--auto-file-renaming=false', '--allow-overwrite=true',
            '--disable-ipv6', '--check-integrity=true',
            '--summary-interval=0', '--console-log-level=warn'
        )
        $proc = Start-Process -FilePath $Tools.Aria -ArgumentList $aria2Args -NoNewWindow -Wait -PassThru
        Remove-Item $inputFile -Force -ErrorAction SilentlyContinue
        if ($proc.ExitCode -ne 0) {
            Write-Err2 ("  aria2c 退出码 $($proc.ExitCode)（403 = 数据中心/VPN 出口 IP，请关代理或用家用宽带；22 = HTTP 响应异常）。")
            return $false
        }
    }
    return $true
}

function Download-WithRetry {
    param([string]$SrcUuid, [string[]]$WantUuids, [hashtable]$Names, [object]$Tools)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1) { Write-Warn2 "重试 $attempt/3：正在刷新下载链接 ..." }
        $fresh = @(Get-DownloadEntries $SrcUuid)
        $set = @($fresh | Where-Object { $WantUuids -contains $_.Uuid })
        if ($set.Count -eq 0) { $set = $fresh }
        if (Invoke-Download -Entries $set -Names $Names -Tools $Tools) { return $true }
    }
    return $false
}

function Extract-Entries {
    param([object[]]$Entries, [string]$Shared, [object]$Tools)
    $pw = 'ms_by_rgadguard'
    foreach ($e in $Entries) {
        $arc = Join-Path $OutDir "$($e.Uuid).7z"
        if (-not (Test-Path $arc)) { Write-Warn2 "未找到压缩包：$arc"; continue }
        Write-Info "`n正在解压 $($e.Uuid).7z ..."
        $p7 = Start-Process -FilePath $Tools.SevenZip -ArgumentList @('x', ('"{0}"' -f $arc), ('"-o{0}"' -f $Shared), ('-p{0}' -f $pw), '-y', '-bsp1') -NoNewWindow -Wait -PassThru
        if ($p7.ExitCode -ne 0) { Write-Err2 "7z 解压失败（码 $($p7.ExitCode)）：$arc" }
    }
}

function Rebuild-Shared {
    param([string]$Shared, [object]$Tools)
    for ($pass = 1; $pass -le 8; $pass++) {
        $pending = @(Get-ChildItem $Shared -Recurse -File -Include *.svf, *.dvp -ErrorAction SilentlyContinue)
        if ($pending.Count -eq 0) { break }
        $progressed = $false
        foreach ($f in $pending) {
            $target = Join-Path $f.DirectoryName $f.BaseName
            if (Test-Path $target) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; $progressed = $true; continue }
            Write-Info "正在重建 $($f.BaseName) ..."
            if ($f.Extension -eq '.svf') {
                if (-not $Tools.Smv) { continue }
                $r = Start-Process -FilePath $Tools.Smv -ArgumentList @('x', ('"{0}"' -f $f.Name), '-br', '.') -WorkingDirectory $f.DirectoryName -NoNewWindow -Wait -PassThru
            } else {
                if (-not $Tools.Dvp) { continue }
                $r = Start-Process -FilePath $Tools.Dvp -ArgumentList @('-o', ('"{0}"' -f $target), ('"{0}"' -f $f.FullName)) -NoNewWindow -Wait -PassThru
            }
            if ($r.ExitCode -eq 0 -and (Test-Path $target)) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; $progressed = $true }
        }
        if (-not $progressed) { break }
    }
}

function Test-Built {
    param([string]$Shared, [string]$Name)
    return [bool](Get-ChildItem $Shared -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
}

function Finalize-Bundle {
    param([object[]]$Entries, [string[]]$KeepNames, [object[]]$Bundle, [string]$Shared, [object]$Tools)
    $images = @(Get-ChildItem $Shared -Recurse -File | Where-Object { $_.Extension -notin '.svf', '.dvp', '.hash' })
    $kept = 0
    $verifyFail = $false
    foreach ($img in $images) {
        if ($KeepNames -contains $img.Name) {
            $dest = Join-Path $OutDir $img.Name
            if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $img.FullName -Destination $dest -Force
            $gb = [math]::Round((Get-Item $dest).Length / 1GB, 2)
            Write-Ok ("=> {0}  ({1} GB)" -f $img.Name, $gb)

            $bu = ($Bundle | Where-Object { $_.Name -eq $img.Name } | Select-Object -First 1)
            if ($bu) {
                $remote = Get-RemoteSha1 $bu.Uuid
                if ($remote) {
                    Write-Info "正在校验 SHA-1 ..."
                    $hashOut = & certutil -hashfile $dest SHA1 2>&1
                    $local = ($hashOut | Select-String -Pattern '^[0-9a-fA-F]{40}$').Line
                    if (-not $local) { Write-Warn2 "   （无法计算本地 SHA-1）" }
                    elseif ($local -ieq $remote) { Write-Ok ("   SHA-1 校验通过  {0}" -f $local.ToLower()) }
                    else { Write-Err2 ("   SHA-1 不匹配！本地={0} 期望={1}" -f $local.ToLower(), $remote.ToLower()); $verifyFail = $true }
                } else { Write-Warn2 "   （无法获取参考 SHA-1，跳过校验）" }
            }
            $kept++
        }
    }

    $leftover = @(Get-ChildItem $Shared -Recurse -File -Include *.svf, *.dvp -ErrorAction SilentlyContinue)
    if ($kept -ge $KeepNames.Count -and $leftover.Count -eq 0 -and -not $verifyFail) {
        Remove-Item $Shared -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $KeepArchive) { foreach ($e in $Entries) { Remove-Item (Join-Path $OutDir "$($e.Uuid).7z") -Force -ErrorAction SilentlyContinue } }
    } else {
        if ($verifyFail) { Write-Err2 "校验失败，已保留压缩包以便重试。" }
        else { Write-Err2 "重建不完整（已保留 $kept / 需要 $($KeepNames.Count)）。未删除任何文件，请手动检查：" }
        Write-Warn2 "  组目录：$Shared"
        Get-ChildItem $Shared -Recurse -File | ForEach-Object { Write-Host ("    " + $_.FullName) -ForegroundColor DarkGray }
    }
}

function Show-Leaf {
    param([string]$Url, [object]$Tools)
    $uuid = ($Url -split '/')[-1]
    $html = Get-Html $Url
    $meta = Get-FileMeta $html
    Write-Host ''
    Write-Host '========================================================' -ForegroundColor DarkGray
    Write-Ok    ("文件   ：" + $meta.File)
    Write-Host  ("大小   ：" + $meta.Size)
    Write-Host  ("SHA-256：" + $meta.SHA256) -ForegroundColor DarkGray
    Write-Host '========================================================' -ForegroundColor DarkGray

    Write-Info "正在解析下载链接 ..."
    $all = Get-DownloadEntries $uuid
    if ($all.Count -eq 0) { Write-Err2 "未返回可下载链接（该文件可能只有信息、无法下载）。"; Read-Host '按回车返回' | Out-Null; return }
    $bundle = @(Get-BundleList $uuid)
    $requestedName = ($bundle | Where-Object { $_.Uuid -eq $uuid } | Select-Object -First 1).Name
    if (-not $requestedName) { $requestedName = $meta.File }
    $allNames = @($bundle | ForEach-Object { $_.Name })
    if ($allNames.Count -eq 0) { $allNames = @($requestedName) }

    Write-Host ''
    if ($all.Count -gt 1) {
        Write-Warn2 "提示：rg-adguard 把它打包成一个差分组，共 $($all.Count) 个文件。"
        Write-Warn2 "选 D 会先只下这一个；若它是差分包缺基准，才自动补下同组其它文件。"
    }
    Write-Host ''
    $totalGB = 0
    $totalGB = ($bundle | Measure-Object -Property SizeGB -Sum).Sum
    Write-Host ("组内文件数：{0}    整组镜像总大小：{1:F2} GB（选 D 通常远小于此）" -f $bundle.Count, $totalGB) -ForegroundColor DarkGray
    Write-Host ''
    for ($i = 0; $i -lt $bundle.Count; $i++) {
        $tag = if ($bundle[$i].Uuid -eq $uuid) { '  <= 你选择的' } else { '' }
        Write-Host ("   [{0}] {1}{2}" -f ($i + 1), $bundle[$i].Name, $tag)
    }
    Write-Host ''
    Write-Host '  [D] 只要你选择的文件（按需下载，尽量省流量）'
    Write-Host '  [A] 保留组内全部文件（下载整组）'
    Write-Host '  [B] 返回'
    $choice = (Read-Host '请选择').Trim().ToUpper()
    if ($choice -ne 'A' -and $choice -ne 'D') { return }

    $namesMap = @{}
    foreach ($b in $bundle) {
        $namesMap[$b.Uuid] = $b.Name
        if ($b.Size) { $namesMap[($b.Uuid + '_size')] = $b.Size }
    }
    $allUuids = @($all | ForEach-Object { $_.Uuid })
    $reqUuid  = if (@($all | Where-Object { $_.Uuid -eq $uuid }).Count -gt 0) { $uuid } else { $all[0].Uuid }

    $shared = Join-Path $OutDir ("_bundle_" + $uuid)
    if (Test-Path $shared) { Remove-Item $shared -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $shared | Out-Null

    if ($choice -eq 'A') {
        if (-not (Download-WithRetry -SrcUuid $uuid -WantUuids $allUuids -Names $namesMap -Tools $Tools)) { Read-Host '按回车继续' | Out-Null; return }
        Extract-Entries -Entries $all -Shared $shared -Tools $Tools
        Rebuild-Shared -Shared $shared -Tools $Tools
        Finalize-Bundle -Entries $all -KeepNames $allNames -Bundle $bundle -Shared $shared -Tools $Tools
    } else {
        if (-not (Download-WithRetry -SrcUuid $uuid -WantUuids @($reqUuid) -Names $namesMap -Tools $Tools)) { Read-Host '按回车继续' | Out-Null; return }
        $reqEntry = @($all | Where-Object { $_.Uuid -eq $reqUuid })
        Extract-Entries -Entries $reqEntry -Shared $shared -Tools $Tools
        Rebuild-Shared -Shared $shared -Tools $Tools
        if (-not (Test-Built -Shared $shared -Name $requestedName) -and $all.Count -gt 1) {
            Write-Warn2 "`n所选文件是差分包，需要同组其它文件作为基准，正在补充下载其余 $($all.Count - 1) 个 ..."
            $restUuids = @($allUuids | Where-Object { $_ -ne $reqUuid })
            if (-not (Download-WithRetry -SrcUuid $uuid -WantUuids $restUuids -Names $namesMap -Tools $Tools)) { Read-Host '按回车继续' | Out-Null; return }
            $restEntries = @($all | Where-Object { $_.Uuid -ne $reqUuid })
            Extract-Entries -Entries $restEntries -Shared $shared -Tools $Tools
            Rebuild-Shared -Shared $shared -Tools $Tools
        }
        Finalize-Bundle -Entries $all -KeepNames @($requestedName) -Bundle $bundle -Shared $shared -Tools $Tools
    }
    Write-Ok "`n完成。输出目录：$OutDir"
    Read-Host '按回车继续' | Out-Null
}

function Start-Browser {
    param([object]$Tools)
    $stack = New-Object System.Collections.Generic.List[object]
    $stack.Add([pscustomobject]@{ Url = "$Server/category"; Title = '文件列表（根目录）' })

    while ($stack.Count -gt 0) {
        $node = $stack[$stack.Count - 1]

        if ($node.Url -match '/file/[0-9a-f-]{36}$') {
            Show-Leaf -Url $node.Url -Tools $Tools
            $stack.RemoveAt($stack.Count - 1)
            continue
        }

        $ancestors = @($stack | ForEach-Object { $_.Url })
        $html    = Get-Html $node.Url
        $children = @(Get-ChildNodes -Html $html -AncestorUrls $ancestors)

        Clear-Host
        Write-Host ("路径：" + (($stack | ForEach-Object { $_.Title }) -join '  >  ')) -ForegroundColor DarkGray
        Write-Host ''
        if ($children.Count -eq 0) { Write-Warn2 '此处没有条目。'; $stack.RemoveAt($stack.Count - 1); Start-Sleep 1; continue }

        $filter = ''
        while ($true) {
            $view = if ($filter) { @($children | Where-Object { $_.Name -match [regex]::Escape($filter) }) } else { $children }
            Clear-Host
            Write-Host ("路径：" + (($stack | ForEach-Object { $_.Title }) -join '  >  ')) -ForegroundColor DarkGray
            if ($filter) { Write-Host ("过滤：/$filter  （匹配 $($view.Count) 项）") -ForegroundColor Yellow }
            Write-Host ''
            for ($i = 0; $i -lt $view.Count; $i++) {
                $mark = switch ($view[$i].Type) { 'file' { '[文件] ' } default { '[目录] ' } }
                Write-Host ("  {0,3}. {1}{2}" -f ($i+1), $mark, $view[$i].Name)
            }
            Write-Host ''
            Write-Host '  输入序号进入  |  /文字 过滤  |  . 清除过滤  |  b 返回  |  q 退出' -ForegroundColor DarkGray
            $in = (Read-Host '请选择').Trim()

            if ($in -eq 'q') { return }
            if ($in -eq 'b') { $stack.RemoveAt($stack.Count - 1); break }
            if ($in -eq '.') { $filter = ''; continue }
            if ($in.StartsWith('/')) { $filter = $in.Substring(1); continue }
            $n = 0
            if ([int]::TryParse($in, [ref]$n) -and $n -ge 1 -and $n -le $view.Count) {
                $picked = $view[$n - 1]
                $stack.Add([pscustomobject]@{ Url = $picked.Url; Title = $picked.Name })
                break
            }
            Write-Warn2 '无效的选择。'; Start-Sleep 1
        }
    }
}

Write-Info "rg-adguard 镜像下载器"

$psv = $PSVersionTable.PSVersion
if ($psv.Major -lt 3) {
    Write-Err2 "PowerShell 版本 $psv 过低，需要 3.0 或更高。"
    Write-Err2 "Win7 SP1：请安装 WMF 5.1 → https://www.microsoft.com/en-us/download/details.aspx?id=54616"
    Write-Err2 "（这是 Windows 系统更新，安装后需重启，非本脚本能自动完成。）"
    exit 1
}

Write-Host ("输出目录：{0}" -f $OutDir) -ForegroundColor DarkGray
Write-Host ("工具目录：{0}" -f $ToolsDir) -ForegroundColor DarkGray
$tools = Resolve-Tools
Write-Ok ("aria2c：{0}" -f $tools.Aria)
Write-Ok ("7z    ：{0}" -f $tools.SevenZip)
Start-Sleep 1
Start-Browser -Tools $tools
Write-Ok '已退出，再见。'
