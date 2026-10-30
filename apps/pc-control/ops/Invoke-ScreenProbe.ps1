param(
 [Parameter(Mandatory)][ValidateSet('List','Install','Launch','State')][string]$Action,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
 [string]$PackageDirectory
)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('reports\phase2-full-control\'+$RunId)
$resultPath=Join-Path $folder 'probe-operation.json'
if(Test-Path -LiteralPath $resultPath){$previous=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json;if($previous.action -cne $Action -or $previous.run_id -cne $RunId){throw 'Existing probe run belongs to a different action.'};$previous|ConvertTo-Json -Depth 12;exit}
if(Test-Path -LiteralPath (Join-Path $folder 'request.json')){throw 'Previous request outcome pending. Inspect the same run; do not replay.'}
. (Join-Path $workspace 'apps/holographic-control\ops\Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
[IO.Directory]::CreateDirectory($folder)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
function Save-Json($Name,$Value){[IO.File]::WriteAllText((Join-Path $folder $Name),($Value|ConvertTo-Json -Depth 12),$utf8)}
function Get-Packages {
 $response=$context.Client.GetAsync($context.BaseUri+'/api/app/packagemanager/packages').GetAwaiter().GetResult()
 try{if([int]$response.StatusCode -ne 200){throw ('Package inventory HTTP '+[int]$response.StatusCode)};$body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();[IO.File]::WriteAllText((Join-Path $folder 'packages.json'),$body,$utf8);return @((ConvertFrom-Json $body).InstalledPackages)}finally{$response.Dispose()}
}
$proof=[ordered]@{run_id=$RunId;action=$Action;at=[DateTimeOffset]::Now.ToString('o');device=$context.Device.DeviceName;ssh_fingerprint=$context.Device.HostFingerprint;certificate_sha256=$context.CertificateSha256;state='unknown';activation_accepted=$false;visible_effect_verified=$false;control_streams_created=0;errors=@();evidence=$folder}
try{
 $packages=@(Get-Packages)
 Save-Json 'request.json' @{action=$Action;run_id=$RunId;started_at=$proof.at;device=$proof.device;package_directory=$PackageDirectory;replay_allowed=$false}
 if($Action -eq 'Install'){
  if(-not $PackageDirectory){throw 'Provide the exact built screen-probe package directory.'}
  $package=Get-Content -LiteralPath (Join-Path $PackageDirectory 'package-evidence.json') -Raw|ConvertFrom-Json
  if($package.package_name -cne 'Rice.HoloLens.ScreenProbe' -or $package.application_id -cne 'Probe' -or (Get-FileHash -LiteralPath $package.package).Hash -cne $package.sha256){throw 'Unexpected test package or changed package hash.'}
  foreach($file in $package.files){if((Get-FileHash -LiteralPath (Join-Path $package.layout $file.path)).Hash -cne $file.sha256){throw 'Test package layout differs from build evidence.'}}
  $manifest=[xml](Get-Content -LiteralPath (Join-Path $package.layout 'AppxManifest.xml') -Raw)
  $identity=$manifest.Package.Identity;$capabilities=@($manifest.Package.Capabilities.ChildNodes|Where-Object NodeType -eq Element)
  if($identity.Name -cne 'Rice.HoloLens.ScreenProbe' -or $identity.Publisher -cne 'CN=RiceHoloLensCapture' -or $identity.ProcessorArchitecture -cne 'arm64' -or $identity.Version -cne $package.version -or $package.version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $capabilities.Count -ne 1 -or $capabilities[0].GetAttribute('Name') -cne 'graphicsCapture'){throw 'Unexpected capture-probe identity, version or capability.'}
  $remoteDirectory='HoloLensScreenProbeV'+$package.version.Replace('.','_')+'_'+$package.sha256.Substring(0,12)
  $proof.remote_directory=$remoteDirectory
  $sdk=Join-Path $script:HlConfig.SdkDirectory 'WinAppDeployCmd.exe'
  & $sdk deployfiles -file (Join-Path $package.layout 'AppxManifest.xml') -remotedeploydir $remoteDirectory -ip $context.Device.Address *> (Join-Path $folder 'deploy.txt')
  if($LASTEXITCODE -ne 0){throw 'Screen-probe file deployment failed; inspect original request.'}
  & $sdk registerfiles -remotedeploydir $remoteDirectory -ip $context.Device.Address *> (Join-Path $folder 'register.txt')
  if($LASTEXITCODE -ne 0){throw 'Screen-probe registration failed; inspect original request.'}
  $packages=@(Get-Packages);$proof.package_sha256=$package.sha256;$proof.expected_version=$package.version
 }
 if($Action -eq 'List'){$proof.state='read_completed';$proof.packages=@($packages|Select-Object Name,PackageFamilyName,PackageFullName,PackageRelativeId,Version)}
 else{
  $found=@($packages|Where-Object {$_.PackageFullName -cmatch '^Rice\.HoloLens\.ScreenProbe_\d+\.\d+\.\d+\.\d+_arm64__r5420n6798s24$' -and $_.PackageRelativeId -ceq 'Rice.HoloLens.ScreenProbe_r5420n6798s24!Probe'})
  if($found.Count -ne 1){throw 'Exactly one enumerated screen-probe package is required.'}
  $target=$found[0];$proof.package=$target
  if($Action -eq 'Install'){
   if($target.PackageFullName -cne ('Rice.HoloLens.ScreenProbe_'+$package.version+'_arm64__r5420n6798s24')){throw 'Installed version differs from the test build.'}
   $proof.state='installed_version_verified'
  }
  if($Action -eq 'Launch'){
   $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult();$page.Dispose()
   $uri=[uri]($context.BaseUri+'/api/taskmanager/app?appid='+[uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($target.PackageRelativeId)))+'&package='+[uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($target.PackageFullName))))
   $csrf=$context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token'];if(-not $csrf){throw 'Missing authenticated CSRF session.'}
   $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$uri)
   try{$request.Headers.Add('X-CSRF-Token',$csrf.Value);$request.Content=[Net.Http.ByteArrayContent]::new([byte[]]::new(0));$response=$context.Client.SendAsync($request).GetAwaiter().GetResult();try{$proof.http_status=[int]$response.StatusCode;$proof.activation_accepted=$proof.http_status -eq 200;$proof.state=if($proof.activation_accepted){'activation_accepted_runtime_not_verified'}else{'activation_rejected'}}finally{$response.Dispose()}}finally{$request.Dispose()}
  }
  if($Action -eq 'State'){
   $uri=$context.BaseUri+'/api/filesystem/apps/file?knownfolderid=LocalAppData&packagefullname='+[uri]::EscapeDataString($target.PackageFullName)+'&path='+[uri]::EscapeDataString('\LocalState')+'&filename=screen-probe-state.json'
   $response=$context.Client.GetAsync($uri).GetAwaiter().GetResult()
   try{$proof.http_status=[int]$response.StatusCode;if($proof.http_status -ne 200){throw ('Screen-probe state HTTP '+$proof.http_status)};$body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();[IO.File]::WriteAllText((Join-Path $folder 'screen-probe-state.json'),$body,$utf8);$state=$body|ConvertFrom-Json;if($state.schema_version -ne 1 -or -not $state.session_id -or $target.PackageFullName -cne ('Rice.HoloLens.ScreenProbe_'+$state.app_version+'_arm64__r5420n6798s24')){throw 'Unexpected or stale probe runtime version.'};$proof.state='runtime_state_observed';$proof.runtime_version=$state.app_version;$proof.runtime_session=$state.session_id;$proof.phase=$state.phase;$proof.capture_started=$state.capture_started;$proof.events=@($state.events|Select-Object -Last 8);$proof.runtime_error=$state.error;if($state.PSObject.Properties['summary']){$proof.summary=$state.summary};if($state.PSObject.Properties['source']){$proof.capture_source=$state.source}}finally{$response.Dispose()}
  }
 }
}catch{$proof.state='failed_or_unknown';$proof.errors+=@{type=$_.Exception.GetType().Name;message=$_.Exception.Message}}
finally{$context.Client.Dispose();Save-Json 'probe-operation.json' $proof}
$proof|ConvertTo-Json -Depth 12
if($proof.errors.Count){exit 2}
