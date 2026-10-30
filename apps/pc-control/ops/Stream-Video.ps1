param([ValidateSet('Interactive','Detail')][string]$VideoProfile='Interactive')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $workspace 'apps/holographic-control\ops\Holographic.Common.ps1')
$context=$null;$response=$null;$stream=$null
try {
    $context=New-HoloAuthenticatedPortalContext
    # Only holograms: no independent PV camera or either audio source.
    $endpoint=if($VideoProfile -eq 'Detail'){'live_high.mp4'}else{'live_med.mp4'}
    $url=$context.BaseUri+'/api/holographic/stream/'+$endpoint+'?holo=true&pv=false&mic=false&loopback=false&RenderFromCamera=false'
    $response=$context.Client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if([int]$response.StatusCode -ne 200){throw ('Holographic stream HTTP '+[int]$response.StatusCode)}
    $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $destination=[Console]::OpenStandardOutput()
    $buffer=[byte[]]::new(65536)
    while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0){$destination.Write($buffer,0,$count);$destination.Flush()}
} catch {
    [Console]::Error.WriteLine('Official holographic stream ended: '+$_.Exception.GetType().Name)
    exit 2
} finally {
    if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($context){$context.Client.Dispose()}
}
