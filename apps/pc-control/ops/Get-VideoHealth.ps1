$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
. (Join-Path $PSScriptRoot 'Video.Health.Model.ps1')
$context=New-HoloAuthenticatedPortalContext
try {
    $response=$null;$state=$null;$status=0;$readError=$null
    try {
        $response=$context.Client.GetAsync($context.BaseUri+'/api/power/state').GetAwaiter().GetResult()
        $status=[int]$response.StatusCode
        if($status -eq 200){$state=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json}
    }catch{$readError=$_.Exception.GetType().Name}
    finally{if($response){$response.Dispose()}}
    # Identity/authentication failures above still fail closed. An unsupported
    # or incomplete power observation must not disable bounded video recovery.
    $observation=ConvertTo-VideoPowerObservation -State $state -HttpStatus $status -ReadError $readError
    $observation|Add-Member -NotePropertyMembers @{ObservedAt=[DateTimeOffset]::Now.ToString('o');Device=$context.Device.DeviceName;IdentityVerified=$true;PowerHttpStatus=$status}
    $observation|ConvertTo-Json -Compress
} finally {$context.Client.Dispose()}
