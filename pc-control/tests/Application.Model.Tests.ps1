$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\ops\Application.Model.ps1')
$count=0
function Check($Condition,$Label){if(-not $Condition){throw $Label};$script:count++}
$raw=@{Name='独立应用';PackageFullName='Rice.HoloLens.InputProbe_1.0.0.0_neutral__r5420n6798s24';PackageRelativeId='Rice.HoloLens.InputProbe_r5420n6798s24!Probe'}
$app=ConvertTo-Phase2Application $raw
Check ($app.Version -ceq '1.0.0.0' -and -not $app.ActivationVerified) 'Inventory derives exact version without claiming activation'
Check ((Resolve-Phase2Application @($app) $app.Aumid $app.PackageFullName).Aumid -ceq $raw.PackageRelativeId) 'Exact enumerated identity resolved'
$failed=$false;try{Resolve-Phase2Application @($app) $app.Aumid 'Rice.HoloLens.InputProbe_1.0.0.1_neutral__r5420n6798s24'|Out-Null}catch{$failed=$true};Check $failed 'Stale package version rejected'
$failed=$false;try{Resolve-Phase2Application @($app,$app) $app.Aumid $app.PackageFullName|Out-Null}catch{$failed=$true};Check $failed 'Ambiguous identity rejected'
$raw.PackageRelativeId='Other.App_r5420n6798s24!Probe';$failed=$false;try{ConvertTo-Phase2Application $raw|Out-Null}catch{$failed=$true};Check $failed 'Cross-package identity rejected'
$raw.PackageRelativeId='Rice.HoloLens.InputProbe_r5420n6798s24!Probe';$raw.Name='';Check ((ConvertTo-Phase2Application $raw).DisplayName -ceq $raw.PackageRelativeId) 'Unnamed entries retain real identity'
$raw.PackageFullName='missing';$failed=$false;try{ConvertTo-Phase2Application $raw|Out-Null}catch{$failed=$true};Check $failed 'Malformed package cannot be launched'
@{passed=$count;device_operations=0}|ConvertTo-Json
