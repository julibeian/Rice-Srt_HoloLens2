param(
    [ValidateSet('GET','POST')][string]$Method='GET',
    [ValidateSet('http','https')][string]$Scheme='http',
    [ValidateSet('wifi.njau.edu.cn','aaa.njau.edu.cn','172.16.0.3','10.64.0.129','10.64.0.129:801')][string]$PortalHost='wifi.njau.edu.cn',
    [string]$RequestPath='/',
    [string]$BodyFile,
    [switch]$AsAppUser,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Name
)
$ErrorActionPreference='Stop'
$captureRoot=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent (Split-Path -Parent $captureRoot)
. (Join-Path $root 'usb-terminal/HoloLens.Common.ps1')
if(-not $RequestPath.StartsWith('/') -or $RequestPath.Contains("`r") -or $RequestPath.Contains("`n")){throw 'Invalid portal request path.'}
$EvidenceDirectory=(Resolve-Path -LiteralPath $EvidenceDirectory).Path
$utf8=[Text.UTF8Encoding]::new($false)
$exe=Join-Path $captureRoot 'device-research\bin\arm64\hl-campus-http.exe'
$hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.Substring(0,12)
$remoteBase=if($AsAppUser){'U:\Users\DefaultAccount\AppData\Local\DevelopmentFiles\RiceHoloLensCaptureV1\'}else{'C:\Data\Users\DevToolsUser\HoloLensTerminal\'}
$remoteExe=$remoteBase+'hl-campus-'+$hash+'.exe'
if(-not (Invoke-HlBridge @{action='stat';path=$remoteExe}).Exists){Invoke-HlBridge @{action='put';local=$exe;path=$remoteExe}|Out-Null}
$id=[Guid]::NewGuid().ToString('N')
$requestLocal=Join-Path $EvidenceDirectory ($id+'.request')
$requestRemote=$remoteBase+'campus-'+$id+'.request'
$responseRemote=$remoteBase+'campus-'+$id+'.json'
$responseLocal=Join-Path $EvidenceDirectory ($Name+'.json')
if(Test-Path -LiteralPath $responseLocal){throw 'Evidence file already exists.'}
try{
    $body=if($BodyFile){[IO.File]::ReadAllText((Resolve-Path -LiteralPath $BodyFile).Path)}else{''}
    [IO.File]::WriteAllText($requestLocal,($Method+"`n"+$Scheme+"`n"+$PortalHost+"`n"+$RequestPath+"`n"+$body),$utf8)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $acl=[Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($identity.User)
    $acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,'FullControl','Allow'))
    Set-Acl -LiteralPath $requestLocal -AclObject $acl
    Invoke-HlBridge @{action='put';local=$requestLocal;path=$requestRemote}|Out-Null
    if($AsAppUser){
        $launchArguments='LaunchForDebug '+$remoteExe+' "'+$requestRemote+' '+$responseRemote+'" Rice.HoloLens.Capture_r5420n6798s24!Capture'
        $launch=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\DevToolsLauncher.exe';arguments=$launchArguments}
        if($launch.ExitCode -ne 0){throw ('App-user launch failed: '+$launch.ExitCode)}
        $json=$null
        for($i=0;$i -lt 80;$i++){
            $stat=Invoke-HlBridge @{action='stat';path=$responseRemote}
            if($stat.Exists -and $stat.Length -gt 0){$json=(Invoke-HlBridge @{action='cat';path=$responseRemote}).Text;break}
            Start-Sleep -Milliseconds 250
        }
        if(-not $json){throw 'App-user request has not produced its evidence file.'}
    }else{
        $reply=Invoke-HlBridge @{action='exec';executable=$remoteExe;arguments=($requestRemote+' '+$responseRemote)}
        $json=$reply.Output
    }
    $p=$json|ConvertFrom-Json
    if($p.PSObject.Properties.Name -contains 'responseGzipBase64'){
        $compressed=[IO.MemoryStream]::new([Convert]::FromBase64String($p.responseGzipBase64))
        $gzip=[IO.Compression.GZipStream]::new($compressed,[IO.Compression.CompressionMode]::Decompress)
        $reader=[IO.StreamReader]::new($gzip,$utf8)
        try{$p.responseBody=$reader.ReadToEnd()}finally{$reader.Dispose();$compressed.Dispose()}
        $p.PSObject.Properties.Remove('responseGzipBase64')
        $json=$p|ConvertTo-Json -Depth 8
    }
    [IO.File]::WriteAllText($responseLocal,$json,$utf8)
    [ordered]@{Name=$Name;User=$p.user;HttpStatus=$p.httpStatus;Error=$p.error;Stage=$p.stage;Location=$p.location;ContentType=$p.contentType;ResponseBytes=$p.responseBytes;Evidence=$responseLocal}|ConvertTo-Json -Compress
}finally{
    if(Test-Path -LiteralPath $requestLocal){Remove-Item -LiteralPath $requestLocal}
    $body=$null
}
