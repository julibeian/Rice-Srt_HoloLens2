param(
 [Parameter(Mandatory)][ValidateSet('List','Launch','Status')][string]$Action,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
 [string]$Aumid,[string]$PackageFullName
)
$ErrorActionPreference='Stop'
if($Action -eq 'Launch' -and (-not $Aumid -or -not $PackageFullName)){throw 'Launch requires an exact enumerated application and package version.'}
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('apps/pc-control\.state\application-operations\'+$RunId)
$invocationPath=Join-Path $folder 'invocation.json';$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $invocationPath){
 $prior=Get-Content -LiteralPath $invocationPath -Raw|ConvertFrom-Json
 $expectedAction=if($Action -eq 'Status'){'Launch'}else{$Action}
 if($prior.action -cne $expectedAction -or $prior.aumid -cne $Aumid -or $prior.package_full_name -cne $PackageFullName){throw 'This operation ID belongs to another application request.'}
 if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw}else{@{ok=$false;State='outcome_unknown';OperationId=$RunId;ReplayAttempted=$false;Evidence=$folder}|ConvertTo-Json}
 exit
}
if($Action -eq 'Status'){@{ok=$false;State='not_submitted';OperationId=$RunId;ReplayAttempted=$false;Evidence=$folder}|ConvertTo-Json;exit}
. (Join-Path $workspace 'apps/holographic-control\ops\Holographic.Common.ps1')
. (Join-Path $PSScriptRoot 'Application.Model.ps1')
. (Join-Path $PSScriptRoot 'Phase2.Results.ps1')
$context=New-HoloAuthenticatedPortalContext
[IO.Directory]::CreateDirectory((Join-Path $folder 'source'))|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
function Save($Name,$Value){[IO.File]::WriteAllText((Join-Path $folder $Name),($Value|ConvertTo-Json -Depth 12),$utf8)}
$started=[DateTimeOffset]::Now.ToString('o');$submitted=$false;$responseStatus=$null;$outcome=$null
try{
 $manifest=@(foreach($relative in @('apps/pc-control/ops/Invoke-Applications.ps1','apps/pc-control/ops/Application.Model.ps1','apps/pc-control/ops/Phase2.Results.ps1','apps/pc-control/contracts/operation-result.schema.json','apps/holographic-control/ops/Holographic.Common.ps1','usb-terminal/HoloLens.Common.ps1')){$source=Join-Path $workspace $relative;$copy=Join-Path $folder ('source\'+[IO.Path]::GetFileName($source));Copy-Item -LiteralPath $source -Destination $copy;@{path=$relative;sha256=(Get-FileHash -LiteralPath $copy).Hash}})
 Save 'source-manifest.json' $manifest
 Save 'device.json' @{name=$context.Device.DeviceName;ssh_fingerprint=$context.Device.HostFingerprint;certificate_sha256=$context.CertificateSha256;server_public_key_sha256=$context.PublicKeySha256}
 Save 'invocation.json' @{action=$Action;operation_id=$RunId;aumid=$Aumid;package_full_name=$PackageFullName;started_at=$started;replay_allowed=$false}
 $response=$context.Client.GetAsync($context.BaseUri+'/api/app/packagemanager/packages').GetAwaiter().GetResult()
 try{if([int]$response.StatusCode -ne 200){throw ('Application inventory HTTP '+[int]$response.StatusCode)};$inventory=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json;if(-not $inventory.PSObject.Properties['InstalledPackages']){throw 'Application inventory omitted InstalledPackages.'};Save 'inventory.json' $inventory}finally{$response.Dispose()}
 $applications=[Collections.Generic.List[object]]::new();$errors=[Collections.Generic.List[object]]::new()
 foreach($package in $inventory.InstalledPackages){try{$applications.Add((ConvertTo-Phase2Application $package))}catch{$errors.Add(@{package_full_name=[string]$package.PackageFullName;aumid=[string]$package.PackageRelativeId;error=$_.Exception.Message})}}
 $outcome=[ordered]@{ok=$true;OperationId=$RunId;State='inventory_observed';Device=$context.Device.DeviceName;InventoryVerified=$true;InventoryComplete=($errors.Count -eq 0);Applications=@($applications.ToArray()|Sort-Object DisplayName,Aumid);EnumerationErrors=@($errors.ToArray());ActivationAccepted=$false;RuntimeVerified=$false;VisibleEffectVerified=$false;ReplayAttempted=$false;Evidence=$folder}
 if($Action -eq 'Launch'){
  if(-not $Aumid -or -not $PackageFullName){throw 'Launch requires an exact enumerated application and package version.'}
  $target=Resolve-Phase2Application -Applications $applications.ToArray() -Aumid $Aumid -PackageFullName $PackageFullName
  $page=$context.Client.GetAsync($context.BaseUri+'/default.htm').GetAwaiter().GetResult();try{if([int]$page.StatusCode -ne 200){throw 'Portal CSRF session unavailable.'}}finally{$page.Dispose()}
  $uri=[uri]($context.BaseUri+'/api/taskmanager/app?appid='+[uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($target.Aumid)))+'&package='+[uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($target.PackageFullName))))
  $csrf=$context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token'];if(-not $csrf){throw 'Missing authenticated CSRF session.'}
  $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$uri)
  try{$request.Headers.Add('X-CSRF-Token',$csrf.Value);$request.Content=[Net.Http.ByteArrayContent]::new([byte[]]::new(0));$submitted=$true;$response=$context.Client.SendAsync($request).GetAwaiter().GetResult();try{$responseStatus=[int]$response.StatusCode;Save 'activation-response.json' @{http_status=$responseStatus;target=$target;observed_at=[DateTimeOffset]::Now.ToString('o')}}finally{$response.Dispose()}}finally{$request.Dispose()}
  $outcome.HttpStatus=$responseStatus;$outcome.Target=$target;$outcome.ActivationAccepted=$responseStatus -eq 200;$outcome.ok=$outcome.ActivationAccepted;$outcome.State=if($outcome.ActivationAccepted){'activation_accepted'}else{'activation_rejected'}
 }
}catch{$outcome=[ordered]@{ok=$false;OperationId=$RunId;State=if($submitted -and $null -eq $responseStatus){'outcome_unknown'}else{'request_failed'};InventoryVerified=$false;ActivationAccepted=$false;RuntimeVerified=$false;VisibleEffectVerified=$false;ReplayAttempted=$false;ErrorType=$_.Exception.GetType().Name;Error=$_.Exception.Message;Evidence=$folder}}
finally{$context.Client.Dispose()}
$reference=[IO.Path]::GetRelativePath($workspace,$folder).Replace('\','/')
$layers=@{request=@{status=if($outcome.ok){'passed'}else{'unknown'};evidence=@($reference+'/invocation.json')};transport=@{status=if($outcome.ok){'passed'}else{'unknown'};evidence=@()};device_state=@{status='not_observed';evidence=@()};visible_effect=@{status='not_applicable';evidence=@()}}
$verification=[ordered]@{schema_version=1;operation_id=$RunId;session_id='application-management';device_identity_ref=($reference+'/device.json');source_manifest_ref=($reference+'/source-manifest.json');kind=if($Action -eq 'List'){'read'}else{'management'};target=@{type=if($Action -eq 'List'){'device'}else{'application'};identity=if($Action -eq 'List'){$context.Device.DeviceName}else{$Aumid}};parameters_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes(($Action+'|'+$Aumid+'|'+$PackageFullName))));started_at=$started;ended_at=[DateTimeOffset]::Now.ToString('o');status=if($outcome.State -eq 'outcome_unknown'){'unknown'}else{'failed'};layers=$layers;readback_evidence=@();error=@{code=$outcome.State;message=if($outcome.Contains('Error')){$outcome.Error}else{'Visible runtime has not been verified.'}};cleanup=@{status='not_required';evidence=@()}}
if($outcome.ok){
 if($Action -eq 'List'){$verification.status='completed';$verification.error=$null;$verification.layers.transport.evidence=@($reference+'/inventory.json');$verification.layers.device_state=@{status='passed';evidence=@($reference+'/inventory.json')};$verification.readback_evidence=@($reference+'/inventory.json')}
 else{$verification.status='accepted';$verification.error=$null;$verification.layers.transport.evidence=@($reference+'/activation-response.json');$verification.layers.device_state.status='unknown';$verification.layers.visible_effect.status='not_observed'}
}
Write-Phase2Result $verification (Join-Path $folder 'verification.json') -EvidenceRoot $workspace
Save 'result.json' $outcome
$outcome|ConvertTo-Json -Depth 12
