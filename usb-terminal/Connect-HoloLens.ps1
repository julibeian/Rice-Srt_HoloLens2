param([string[]]$Command)
. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
try { $null=Invoke-HlBridge @{action='status'} 1000 } catch { & (Join-Path $PSScriptRoot 'Start-HoloLensBridge.ps1') | Out-Host }
$channel=Invoke-HlBridge @{action='status'}
$script:HlWorkingDirectory=$script:HlConfig.RemoteWorkingDirectory
$script:HlExitCode=0

function Split-HlArguments([string]$Text) {
    foreach ($match in [regex]::Matches($Text,'"([^"]*)"|''([^'']*)''|(\S+)')) {
        foreach ($index in 1..3) { if ($match.Groups[$index].Success) { $match.Groups[$index].Value; break } }
    }
}

function Invoke-HlLine([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $match=[regex]::Match($Line,'^\s*(\S+)(?:\s+(.*))?$')
    $verb=$match.Groups[1].Value.ToLowerInvariant()
    $rest=$match.Groups[2].Value
    $parts=@(Split-HlArguments $rest)
    $request=@{action=$verb;cwd=$script:HlWorkingDirectory}
    switch ($verb) {
        'help' {
            @'
info                         Device identity and SSH capabilities
status                       Background channel and heartbeat status
pwd                          Remote working directory
ls [path] / dir [path]        List a remote directory
cd path                      Change remote working directory
cat path / type path         Read a remote text file
stat path                    Remote file size and modification time
mkdir path                   Create a remote directory
get "remote" "local"         Download a file (existing files are not replaced)
put "local" "remote"         Upload a file (existing files are not replaced)
exec executable [arguments]  Execute a program on the HoloLens; print its output
tzutil /g                    Example: execute the remote system timezone tool
reconnect                    Rebuild SSH automatically without a new PIN
exit                         Close this terminal; background channel stays active
stop-bridge                  Stop the background channel until its next start

This is an authenticated standard-user (DevToolsUser) management terminal.
Administrator/SYSTEM privileges are unavailable. The HoloLens firmware
does not include CMD or PowerShell. Shell operators/pipelines are unavailable.
File operations run through the SDK's SSH connection; programs execute remotely.
'@ | Write-Output
            return
        }
        'pwd' { $script:HlWorkingDirectory; return }
        {$_ -in @('ls','dir','cd','cat','type','stat','mkdir')} {
            $request.action=switch($verb){'dir'{'ls'}'type'{'cat'}default{$verb}}
            if ($parts.Count -gt 1) { throw 'Quote paths containing spaces.' }
            $request.path=if($parts.Count){$parts[0]}else{''}
            if ($request.action -ne 'ls' -and -not $request.path) { throw 'A remote path is required.' }
        }
        {$_ -in @('get','put')} {
            if ($parts.Count -ne 2) { throw 'Supply both paths; quote paths containing spaces.' }
            if ($verb -eq 'get') { $request.path=$parts[0];$request.local=[IO.Path]::GetFullPath($parts[1],$PWD.Path) }
            else { $request.local=[IO.Path]::GetFullPath($parts[0],$PWD.Path);$request.path=$parts[1] }
        }
        {$_ -in @('info','status','reconnect')} {}
        'stop-bridge' { & (Join-Path $PSScriptRoot 'Stop-HoloLensBridge.ps1'); return }
        default {
            $execution=if($verb -eq 'exec'){$rest}else{$Line}
            $parsed=[regex]::Match($execution,'^\s*(?:"(?<program>[^"]+)"|(?<program>\S+))(?:\s+(?<arguments>.*))?$')
            if (-not $parsed.Success) { throw 'An executable is required.' }
            $request.action='exec';$request.executable=$parsed.Groups['program'].Value;$request.arguments=$parsed.Groups['arguments'].Value
        }
    }
    $data=Invoke-HlBridge $request
    switch ($request.action) {
        'ls' { $data.Entries | Sort-Object Type,Name | ForEach-Object { $(if($_.Type -eq 'Directory'){'[D] '}else{'    '}) + $_.Name } }
        'cd' { $script:HlWorkingDirectory=$data.WorkingDirectory; $script:HlWorkingDirectory }
        'cat' { $data.Text }
        'exec' { $data.Output; $script:HlExitCode=[int]$data.ExitCode; if($data.ExitCode){Write-Warning ('Remote exit code: '+$data.ExitCode)} }
        default { $data | ConvertTo-Json -Depth 10 }
    }
}

if ($PSBoundParameters.ContainsKey('Command')) {
    foreach ($line in $Command) { Invoke-HlLine $line }
    exit $script:HlExitCode
}
Write-Host ($script:HlConfig.DeviceName+' / '+$channel.Address+' / USB NCM + SSH / '+$channel.State)
Write-Host 'Permission: standard DevToolsUser; no administrator or SYSTEM token.'
Write-Host 'Type help for commands; exit closes only this terminal.'
while ($true) {
    Write-Host ('HL ['+$script:HlWorkingDirectory+']> ') -NoNewline
    $line=[Console]::ReadLine()
    if ($null -eq $line -or $line.Trim() -in @('exit','quit')) { break }
    try { Invoke-HlLine $line | Out-Host } catch { Write-Host (Get-HlErrorMessage $_.Exception) -ForegroundColor Red }
}
