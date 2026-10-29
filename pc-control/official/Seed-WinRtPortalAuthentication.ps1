# Windows PowerShell 5.1 is used only for its built-in WinRT projection.
# Configuration, including credentials, arrives only through private stdin.
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$line=[Console]::ReadLine()
if(-not $line -or $line.Length -gt 16384){exit 2}
$configuration=$line|ConvertFrom-Json;$line=$null
$uri=[uri]$configuration.BaseUri
if($uri.Scheme -cne 'https' -or $uri.Host -notmatch '^169\.254\.\d+\.\d+$' -or $uri.UserInfo){exit 2}
$filter=$null;$client=$null;$response=$null
$stage='filter_create'
try{
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null=[Windows.Web.Http.HttpClient,Windows.Web.Http,ContentType=WindowsRuntime]
    Add-Type -Path $configuration.PinHelper
    $stage='credential_create'
    $client=[NativePinnedHttpSeed]::Create($uri.AbsoluteUri,$configuration.CertificateSha256,$configuration.UserName,$configuration.Password)
    $configuration.Password=$null;$configuration.UserName=$null
    $stage='http_get'
    $operation=$client.GetAsync([uri]($uri.AbsoluteUri.TrimEnd('/')+'/api/os/info'))
    $stage='await_response'
    $asTask=[System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 2 -and $_.GetParameters().Count -eq 1}|Select-Object -First 1
    $task=$asTask.MakeGenericMethod([Windows.Web.Http.HttpResponseMessage,Windows.Web.Http,ContentType=WindowsRuntime],[Windows.Web.Http.HttpProgress,Windows.Web.Http,ContentType=WindowsRuntime]).Invoke($null,@($operation))
    if(-not $task.Wait(12000)){$operation.Cancel();throw [TimeoutException]::new()}
    $response=$task.GetAwaiter().GetResult()
    $status=[int]$response.StatusCode
    [Console]::WriteLine((@{At=[DateTimeOffset]::Now.ToString('o');Status=$status;AllowUI=$false;Direct=$true;Device=$configuration.Device;NativeWinRtAuthentication=($status -eq 200);OfficialGuiVerified=$false}|ConvertTo-Json -Compress))
    [Console]::Out.Flush()
    if($status -ne 200){exit 2}
    $deadline=[DateTimeOffset]::Parse($configuration.ExpiresAt)
    while([DateTimeOffset]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 250}
}catch{
    $root=$_.Exception;while($root.InnerException){$root=$root.InnerException}
    [Console]::WriteLine((@{Stage=$stage;ErrorType=$_.Exception.GetType().Name;Hresult=('0x'+$_.Exception.HResult.ToString('X8'));RootErrorType=$root.GetType().Name;RootHresult=('0x'+$root.HResult.ToString('X8'));OfficialGuiVerified=$false}|ConvertTo-Json -Compress))
    exit 2
}finally{
    if($response){$response.Dispose()};if($client){$client.Dispose()};if($filter){$filter.Dispose()}
}
