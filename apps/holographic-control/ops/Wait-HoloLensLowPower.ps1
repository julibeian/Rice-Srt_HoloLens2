param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId=('power-wait-'+(Get-Date -Format 'yyyyMMdd-HHmmss')),
    [ValidateRange(30,1800)][int]$TimeoutSeconds=420,
    [ValidateRange(5,120)][int]$IntervalSeconds=20
)
# Read-only poll of the original device's portal power state. Used to prove the
# device actually reached low power before a wake test; never sends input.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Holographic.Common.ps1')
$folder=Join-Path $script:HolographicRoot ('.state\wake\'+$RunId)
[IO.Directory]::CreateDirectory($folder)|Out-Null
$resultPath=Join-Path $folder 'result.json'
if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw;return}
$started=[DateTimeOffset]::Now
$samples=[Collections.Generic.List[object]]::new()
$low=$false;$observed=$false
while((([DateTimeOffset]::Now)-$started).TotalSeconds -lt $TimeoutSeconds){
    $context=$null
    try{
        $context=New-HoloAuthenticatedPortalContext
        $response=$context.Client.GetAsync($context.BaseUri+'/api/power/state').GetAwaiter().GetResult()
        $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
        $response.Dispose()
        if($null -ne $body.LowPowerState){
            $observed=$true;$low=[bool]$body.LowPowerState
            $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');low=$low})
        } else {
            $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');low=$null;error='LowPowerState missing'})
        }
    }catch{
        $samples.Add([ordered]@{at=[DateTimeOffset]::Now.ToString('o');low=$null;error=$_.Exception.GetType().Name})
    }finally{if($context){$context.Client.Dispose()}}
    if($low){break}
    Start-Sleep -Seconds $IntervalSeconds
}
$result=[ordered]@{
    runId=$RunId;at=[DateTimeOffset]::Now.ToString('o');state=if($low){'low_power'}elseif($observed){'still_awake'}else{'unreachable'}
    lowPower=$low;elapsedSeconds=[math]::Round((([DateTimeOffset]::Now)-$started).TotalSeconds,1)
    timeoutSeconds=$TimeoutSeconds;intervalSeconds=$IntervalSeconds;samples=$samples;evidence=$folder
}
[IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$result|ConvertTo-Json -Depth 8
