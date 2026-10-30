param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('reports\phase2-full-control\'+$RunId)
$path=Join-Path $folder 'environment.json'
if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path -Raw;exit}
[IO.Directory]::CreateDirectory($folder)|Out-Null
. (Join-Path $workspace 'apps/holographic-control\ops\Holographic.Common.ps1')
$errors=[Collections.Generic.List[object]]::new()
$os=Get-CimInstance Win32_OperatingSystem
$tools=@(foreach($item in @(
    @{id='powershell7';path=(Join-Path $workspace 'runtime\powershell\pwsh.exe');role='installed_required'},
    @{id='dotnet-framework-x86';path=(Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe');role='installed_required'},
    @{id='makeappx';path='C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\makeappx.exe';role='installed_build'},
    @{id='deployment-sdk';path=(Join-Path $script:HlConfig.SdkDirectory 'Microsoft.Tools.Deploy.dll');role='installed_required'},
    @{id='official-gui';path=(Join-Path $env:ProgramFiles 'Microsoft Perception Simulation\Control\PerceptionSimulationControl.exe');role='installed_comparison'},
    @{id='official-x64-manager';path=(Join-Path $env:ProgramFiles 'Microsoft Perception Simulation\Sdk\References\PerceptionSimulationManager.dll');role='installed_comparison'},
    @{id='legacy-x86-manager';path=(Join-Path $workspace 'tools\perception-simulation\portable-hololens\Windows Kits\10\Microsoft XDE\10.0.22621.0\PerceptionSimulationManager.dll');role='installed_input_adapter'}
)){
    $exists=Test-Path -LiteralPath $item.path -PathType Leaf
    [ordered]@{id=$item.id;path=$item.path;role=$item.role;present=$exists;version=if($exists){(Get-Item -LiteralPath $item.path).VersionInfo.FileVersion}else{$null};sha256=if($exists){(Get-FileHash -LiteralPath $item.path).Hash}else{$null}}
})
$commands=@(foreach($name in @('node','python','ffmpeg','git')){
    $command=Get-Command $name -ErrorAction SilentlyContinue
    [ordered]@{id=$name;path=if($command){$command.Source}else{$null};present=[bool]$command;role='installed_tool';sha256=if($command){(Get-FileHash -LiteralPath $command.Source).Hash}else{$null}}
})
$bridge=$null;$device=$null;$portal=$null;$readOnly=$null
try{
    $bridge=Invoke-HlBridge @{action='status'}
    $device=Invoke-HlBridge @{action='info'}
    $readOnly=Invoke-HlBridge @{action='exec';executable='C:\Windows\System32\tzutil.exe';arguments='/g'}
}catch{$errors.Add(@{stage='usb';type=$_.Exception.GetType().Name;message=$_.Exception.Message})}
$context=$null
try{
    $context=New-HoloAuthenticatedPortalContext
    $requests=@(foreach($endpoint in @('/api/os/info','/api/holographic/simulation/control/mode')){
        $response=$context.Client.GetAsync($context.BaseUri+$endpoint).GetAwaiter().GetResult()
        try{[ordered]@{path=$endpoint;http_status=[int]$response.StatusCode;body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json}}finally{$response.Dispose()}
    })
    $portal=[ordered]@{authenticated=$true;ssh_identity_verified=$true;certificate_pinned=$true;certificate_sha256=$context.CertificateSha256;public_key_sha256=$context.PublicKeySha256;requests=$requests}
}catch{$errors.Add(@{stage='portal';type=$_.Exception.GetType().Name;message=$_.Exception.Message})}finally{if($context){$context.Client.Dispose()}}
$result=[ordered]@{schema_version=1;run_id=$RunId;observed_at=[DateTimeOffset]::Now.ToString('o');host=@{caption=$os.Caption;version=$os.Version;build=$os.BuildNumber;architecture=$os.OSArchitecture;powershell=$PSVersionTable.PSVersion.ToString();clr=[Environment]::Version.ToString()};tools=$tools;commands=$commands;candidate_dependencies=@(@{id='independent-input-test-package';status='not_built';purpose='T04 isolated input observations'},@{id='3d-test-application';status='not_selected';purpose='T12 real 3D input'});second_workstation=@{status='not_available_in_current_workspace';verified=$false};bridge=$bridge;device=$device;read_only_command=$readOnly;portal=$portal;errors=@($errors.ToArray());complete=($errors.Count -eq 0);device_mutations=0;credentials_exported=$false;control_streams_created=0;cleanup=@{required=$false;reason='Read-only observations; HTTP client disposed.'}}
[IO.File]::WriteAllText($path,($result|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
$result|ConvertTo-Json -Depth 14
