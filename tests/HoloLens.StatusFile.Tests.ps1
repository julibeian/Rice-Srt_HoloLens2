$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'HoloLens.Common.ps1')
$directory=Join-Path $script:HlStateDirectory ('status-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory)|Out-Null
$statusPath=Join-Path $directory 'status.json'
$readyPath=Join-Path $directory 'reader-ready'
$holder=$null
try {
    [IO.File]::WriteAllText($statusPath,'{"State":"old"}')
    $scriptPath=Join-Path $directory 'Hold-Reader.ps1'
    [IO.File]::WriteAllText($scriptPath,@'
param($StatusPath,$ReadyPath)
$handle=[IO.File]::Open($StatusPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try{[IO.File]::WriteAllText($ReadyPath,'ready');Start-Sleep -Milliseconds 400}finally{$handle.Dispose()}
'@)
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($arg in @('-NoProfile','-File',$scriptPath,$statusPath,$readyPath)){$start.ArgumentList.Add($arg)}
    $holder=[Diagnostics.Process]::Start($start)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not(Test-Path $readyPath) -and $clock.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 10}
    if(-not(Test-Path $readyPath)){throw 'Reader did not establish its real Windows file lock.'}
    $value=[ordered]@{State='connected';UpdatedAt=$null;ActiveOperation=$null}
    Write-HlBridgeStatus $value $directory
    $saved=Get-Content $statusPath -Raw|ConvertFrom-Json
    if($saved.State -ne 'connected' -or -not $saved.UpdatedAt){throw 'The status update did not survive the competing reader.'}
    if(Test-Path (Join-Path $directory 'status.tmp')){throw 'The atomic status temporary file was not consumed.'}
    'Status-file regression passed: a real reader without delete sharing cannot drop the bridge session.'
} finally {
    if($holder){if(-not $holder.WaitForExit(2000)){$holder.Kill();$holder.WaitForExit()};$holder.Dispose()}
    # Only the explicitly enumerated files in this unique test folder are removed.
    foreach($name in @('status.json','status.tmp','Hold-Reader.ps1','reader-ready')){
        $path=Join-Path $directory $name
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
    }
    Remove-Item -LiteralPath $directory
}
