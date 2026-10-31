param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
 [Parameter(Mandatory)][string[]]$PackageFullName
)
$ErrorActionPreference='Stop'
# pwsh -File passes comma-separated values as one literal argument, so accept
# both real arrays and a single comma-separated list.
$PackageFullName=@($PackageFullName|ForEach-Object {$_ -split ','}|ForEach-Object {$_.Trim()}|Where-Object {$_})
# Only developer test packages this project installed may be removed. The field
# apps and every system or store package stay outside this allowlist so a typo
# cannot uninstall the business app.
$allowed=@('Rice.HoloLens.SurfaceProbe','Rice.HoloLens.NativeSurface','Rice.HoloLens.InputProbe','Rice.HoloLens.ScreenProbe')
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('apps/pc-control\.state\application-operations\'+$RunId)
$invocationPath=Join-Path $folder 'invocation.json';$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $invocationPath){
 $prior=Get-Content -LiteralPath $invocationPath -Raw|ConvertFrom-Json
 $requested=@($PackageFullName|Sort-Object)
 if((@($prior.packages|Sort-Object) -join '|') -cne ($requested -join '|')){throw 'This operation ID belongs to another removal request.'}
 if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw}else{@{ok=$false;State='outcome_unknown';OperationId=$RunId;ReplayAttempted=$false;Evidence=$folder}|ConvertTo-Json}
 exit
}
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
. (Join-Path $PSScriptRoot 'Phase2.Results.ps1')
[IO.Directory]::CreateDirectory((Join-Path $folder 'source'))|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$steps=[Collections.Generic.List[string]]::new()
function Save($Name,$Value){[IO.File]::WriteAllText((Join-Path $folder $Name),($Value|ConvertTo-Json -Depth 12),$utf8)}
function Step($Text){$steps.Add(([DateTimeOffset]::Now.ToString('o')+' '+$Text));Save 'steps.json' @($steps)}
$context=$null;$started=[DateTimeOffset]::Now.ToString('o');$submitted=$false;$errorText=$null
try{
 Step 'portal context'
 $context=New-HoloAuthenticatedPortalContext
 $manifest=@(foreach($relative in @('apps/pc-control/ops/Remove-Applications.ps1','apps/pc-control/ops/Phase2.Results.ps1','apps/pc-control/contracts/operation-result.schema.json','apps/holographic-control/ops/Holographic.Common.ps1','usb-terminal/HoloLens.Common.ps1')){$source=Join-Path $workspace $relative;$copy=Join-Path $folder ('source\'+[IO.Path]::GetFileName($source));Copy-Item -LiteralPath $source -Destination $copy -Force;@{path=$relative;sha256=(Get-FileHash -LiteralPath $copy).Hash}})
 Save 'source-manifest.json' $manifest
 Save 'device.json' @{name=$context.Device.DeviceName;ssh_fingerprint=$context.Device.HostFingerprint;certificate_sha256=$context.CertificateSha256;server_public_key_sha256=$context.PublicKeySha256}
 Save 'invocation.json' @{action='Remove';operation_id=$RunId;packages=@($PackageFullName);started_at=$started;replay_allowed=$false}
 Step 'read inventory before'
 $response=$context.Client.GetAsync($context.BaseUri+'/api/app/packagemanager/packages').GetAwaiter().GetResult()
 try{
  if([int]$response.StatusCode -ne 200){throw ('Application inventory HTTP '+[int]$response.StatusCode)}
  $before=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
  if(-not $before.PSObject.Properties['InstalledPackages']){throw 'Application inventory omitted InstalledPackages.'}
  Save 'inventory-before.json' $before
 } finally {$response.Dispose()}
 Step 'verify targets'
 $targets=@()
 foreach($fullName in $PackageFullName){
  $found=@($before.InstalledPackages|Where-Object {$_.PackageFullName -ceq $fullName})
  if($found.Count -ne 1){throw ('Package is absent or ambiguous in the current inventory: '+$fullName)}
  $package=$found[0]
  if([string]$package.PackageFamilyName -notin $allowed){throw ('Package is outside the removable developer set: '+$fullName)}
  if($package.CanUninstall -ne $true){throw ('The device does not allow uninstalling: '+$fullName+' / '+[string]$package.UninstallDeniedReason)}
  $targets+=@{
   PackageFullName=[string]$package.PackageFullName
   PackageFamilyName=[string]$package.PackageFamilyName
   PackageDisplayName=[string]$package.PackageDisplayName
   Version=(([string]$package.Version.Major)+'.'+([string]$package.Version.Minor)+'.'+([string]$package.Version.Build)+'.'+([string]$package.Version.Revision))
   PackageRelativeId=[string]$package.PackageRelativeId
  }
 }
 Step 'portal csrf page'
 $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult()
 try{if([int]$page.StatusCode -ne 200){throw 'Portal CSRF session unavailable.'}}finally{$page.Dispose()}
 $responses=@()
 foreach($target in $targets){
  Step ('delete '+$target.PackageFamilyName)
  $uri=[uri]($context.BaseUri+'/api/app/packagemanager/package?package='+[uri]::EscapeDataString($target.PackageFullName))
  $csrf=$context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token']
  if(-not $csrf){$csrf=$context.Handler.CookieContainer.GetCookies([uri]$context.BaseUri)['CSRF-Token']}
  if(-not $csrf){
   $names=@($context.Handler.CookieContainer.GetCookies([uri]$context.BaseUri)|ForEach-Object {$_.Name})
   throw ('Missing authenticated CSRF session. Cookies: '+($names -join ','))
  }
  $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Delete,$uri)
  try{
   $request.Headers.Add('X-CSRF-Token',$csrf.Value)
   $submitted=$true
   $reply=$context.Client.SendAsync($request).GetAwaiter().GetResult()
   try{
    $body=$reply.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $responses+=@{package_full_name=$target.PackageFullName;http_status=[int]$reply.StatusCode;body=$body;observed_at=[DateTimeOffset]::Now.ToString('o')}
   }finally{$reply.Dispose()}
  }finally{$request.Dispose()}
 }
 Save 'removal-responses.json' $responses
 Step 'read inventory after'
 $response=$context.Client.GetAsync($context.BaseUri+'/api/app/packagemanager/packages').GetAwaiter().GetResult()
 try{
  if([int]$response.StatusCode -ne 200){throw ('Application inventory HTTP '+[int]$response.StatusCode)}
  $after=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
  if(-not $after.PSObject.Properties['InstalledPackages']){throw 'Application inventory omitted InstalledPackages.'}
  Save 'inventory-after.json' $after
 } finally {$response.Dispose()}
 $remaining=@($after.InstalledPackages|Where-Object {$_.PackageFullName -in $PackageFullName}|ForEach-Object {$_.PackageFullName})
 $rejected=@($responses|Where-Object {$_.http_status -ne 200})
 $outcome=[ordered]@{
  ok=($rejected.Count -eq 0 -and $remaining.Count -eq 0)
  OperationId=$RunId
  State=if($rejected.Count){'removal_rejected'}elseif($remaining.Count){'still_present'}else{'removed'}
  Device=$context.Device.DeviceName
  Targets=$targets
  HttpStatuses=@($responses|ForEach-Object {@{package_full_name=$_.package_full_name;http_status=$_.http_status}})
  Remaining=@($remaining)
  ReplayAttempted=$false
  Evidence=$folder
 }
 Step ('outcome '+$outcome.State)
}catch{
 $errorText=$_.Exception.GetType().Name+': '+$_.Exception.Message
 Step ('error '+$errorText)
 Save 'error.json' @{at=[DateTimeOffset]::Now.ToString('o');type=$_.Exception.GetType().Name;message=$_.Exception.Message;submitted=$submitted}
 $remaining=if(Test-Path -LiteralPath (Join-Path $folder 'inventory-after.json')){@((Get-Content -LiteralPath (Join-Path $folder 'inventory-after.json') -Raw|ConvertFrom-Json).InstalledPackages|Where-Object {$_.PackageFullName -in $PackageFullName}|ForEach-Object {$_.PackageFullName})}else{@()}
 $outcome=[ordered]@{ok=$false;OperationId=$RunId;State=if($submitted){'outcome_unknown'}else{'request_failed'};ErrorType=$_.Exception.GetType().Name;Error=$_.Exception.Message;Remaining=@($remaining);ReplayAttempted=$false;Evidence=$folder}
}finally{if($context){$context.Client.Dispose()}}
Save 'result.json' $outcome
$reference=[IO.Path]::GetRelativePath($workspace,$folder).Replace('\','/')
function Ref($Name){if(Test-Path -LiteralPath (Join-Path $folder $Name)){$reference+'/'+$Name}else{$null}}
$removed=($outcome.State -eq 'removed')
$layers=@{
 request=@{status=if($removed){'passed'}else{'unknown'};evidence=@(Ref 'invocation.json'|Where-Object {$_})}
 transport=@{status=if($removed){'passed'}elseif($null -eq (Ref 'removal-responses.json')){'unknown'}else{'unknown'};evidence=@(Ref 'removal-responses.json'|Where-Object {$_})}
 device_state=@{status=if($removed){'passed'}else{'not_observed'};evidence=@(Ref 'inventory-after.json'|Where-Object {$_})}
 visible_effect=@{status='not_observed';evidence=@()}
}
$verification=[ordered]@{
 schema_version=1;operation_id=$RunId;session_id='application-management';device_identity_ref=(Ref 'device.json');source_manifest_ref=(Ref 'source-manifest.json')
 kind='management';target=@{type='application';identity=($PackageFullName -join ',')}
 parameters_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes('Remove|'+($PackageFullName -join '|'))))
 started_at=$started;ended_at=[DateTimeOffset]::Now.ToString('o');status=if($removed){'completed'}elseif($outcome.State -eq 'outcome_unknown'){'unknown'}else{'failed'}
 layers=$layers;readback_evidence=@(@(Ref 'inventory-before.json')+@(Ref 'inventory-after.json')|Where-Object {$_})
 error=if($removed){$null}else{@{code=$outcome.State;message=if($errorText){$errorText}else{'The device inventory still lists a target package.'}}}
 cleanup=@{status='not_required';evidence=@()}
}
try{Write-Phase2Result $verification (Join-Path $folder 'verification.json') -EvidenceRoot $workspace}catch{$_.Exception.Message|Out-Host}
$outcome|ConvertTo-Json -Depth 8
