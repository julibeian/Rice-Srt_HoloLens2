. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
. (Join-Path $PSScriptRoot 'HoloLens.UsbPower.ps1')
$mutex = [Threading.Mutex]::new($false, ('Local\' + $script:HlPipeName))
$ownsMutex = $false
try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
if (-not $ownsMutex) { $mutex.Dispose(); exit 0 }
$client = $null
$address = $null
$pipe = $null
$stopping = $false
$newConnection = $false
$nextCheck = [DateTime]::MinValue
$lastLoggedState = ''
$status = [ordered]@{ State='starting'; Device=$script:HlConfig.DeviceName; Address=$null; ConnectionMethod=$null; LastConnectMs=$null; ProcessId=$PID; StartedAt=[DateTimeOffset]::Now.ToString('o'); UpdatedAt=$null; ActiveOperation=$null; LastHeartbeat=$null; LastError=$null; Connections=0; Pipe=$script:HlPipeName; SourceHashes=@{}; UsbPower=$null }
foreach ($sourceName in @('HoloLens.Common.ps1','HoloLens.Bridge.ps1','HoloLens.UsbPower.ps1')) {
    $status.SourceHashes[$sourceName]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $sourceName) -Algorithm SHA256).Hash
}

function Save-HlStatus {
    Write-HlBridgeStatus $status
}

function Write-HlLog([string]$Message) {
    $path = Join-Path $script:HlStateDirectory 'bridge.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) { [IO.File]::Move($path,($path+'.1'),$true) }
    [IO.File]::AppendAllText($path,([DateTimeOffset]::Now.ToString('o') + ' ' + $Message + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

try {
    Import-HlSdk
    Save-HlStatus
    Write-HlLog 'Bridge started; local current-user named pipe only.'
    # Keep one availability supervisor alive per session. It runs as a separate
    # process so that bridge restarts (including its own recovery restarts) do
    # not stop wake attempts; a local mutex prevents duplicates.
    try{
        $supervisor=Join-Path $script:HlRoot 'apps/holographic-control\ops\Start-WakeSupervisor.ps1'
        if(Test-Path -LiteralPath $supervisor){
            Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo','-NoProfile','-WindowStyle','Hidden','-File',('"'+$supervisor+'"')) -WindowStyle Hidden | Out-Null
        }
    }catch{Write-HlLog ('Supervisor start failed: '+$_.Exception.Message)}
    while (-not $stopping) {
        if ($null -eq $pipe) {
            $options = [IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly
            $pipe = [IO.Pipes.NamedPipeServerStream]::new($script:HlPipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,$options)
            $pendingConnection = $pipe.WaitForConnectionAsync()
        }
        if ($pendingConnection.IsCompleted) {
            try {
                $pendingConnection.GetAwaiter().GetResult()
                $reader = [IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,4096,$true)
                $writer = [IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),4096,$true)
                $writer.AutoFlush = $true
                $pendingRequest = $reader.ReadLineAsync()
                if (-not $pendingRequest.Wait(5000)) { throw 'Client request timeout.' }
                $request = $pendingRequest.Result | ConvertFrom-Json -AsHashtable
                try {
                    switch ([string]$request.action) {
                        'status' { $data=$status }
                        'stop' { $stopping=$true; $data=@{ Stopping=$true } }
                        'reconnect' {
                            Close-HlDeviceConnection $client; $client=$null
                            $status.State='reconnecting'; $status.LastError=$null; $nextCheck=[DateTime]::MinValue
                            Save-HlStatus
                            $data=$status
                        }
                        default {
                            if ($null -eq $client -or $status.State -ne 'connected') { throw "HoloLens is $($status.State). The bridge is retrying automatically." }
                            $status.ActiveOperation=[string]$request.action; Save-HlStatus
                            try { $data=Invoke-HlOperation $client $request $address }
                            finally { $status.ActiveOperation=$null; Save-HlStatus }
                        }
                    }
                    $response=@{ ok=$true; data=$data }
                } catch { $response=@{ ok=$false; error=([string]$request.action+': '+(Get-HlErrorMessage $_.Exception)) } }
                $writer.WriteLine(($response | ConvertTo-Json -Depth 12 -Compress))
            } catch { Write-HlLog ('Pipe error: ' + (Get-HlErrorMessage $_.Exception)) }
            finally { $pipe.Dispose(); $pipe=$null }
        }
        if (-not $stopping -and [DateTime]::UtcNow -ge $nextCheck) {
            try {
                if ($null -eq $client) {
                    $status.State='discovering'; Save-HlStatus
                    $connectClock=[Diagnostics.Stopwatch]::StartNew()
                    $connection=Find-HlDevice -KeepConnection
                    $connectClock.Stop()
                    $address=$connection.Address
                    $client=$connection.Client
                    $status.Address=$address
                    $status.ConnectionMethod=[string]$connection.Method
                    $status.LastConnectMs=[int]$connectClock.ElapsedMilliseconds
                    $status.Connections++
                    $newConnection=$true
                    Write-HlLog ('Authenticated SSH connected to ' + $address + ' via ' + $status.ConnectionMethod + ' in ' + $status.LastConnectMs + ' ms')
                }
                if (-not $client.RemoteDevice.Ping()) { throw 'SSH keepalive failed.' }
                $status.State='connected'
                $status.LastError=$null
                $status.LastHeartbeat=[DateTimeOffset]::Now.ToString('o')
                # Publish the authenticated session before optional power I/O.
                # The device keeps its last 45-second lease, so renewing it on
                # the next keepalive tick is safe and keeps status responsive.
                if ($newConnection) {
                    $status.UsbPower=@{State='pending_next_tick';Reason='USB power lease renews on the next keepalive tick';LastVerifiedHeartbeat=$status.LastHeartbeat;DeviceLeaseMs=45000}
                }
                Save-HlStatus
                if (-not $newConnection) {
                    try{$status.UsbPower=Invoke-HlUsbPowerTick $client $address}
                    catch{$status.UsbPower=@{State='error';Error=(Get-HlErrorMessage $_.Exception)}}
                }
                $newConnection=$false
                $nextCheck=[DateTime]::UtcNow.AddSeconds($script:HlConfig.KeepAliveSeconds)
            } catch {
                $status.State='waiting_for_device'
                $status.LastError=Get-HlErrorMessage $_.Exception
                $status.UsbPower=@{State='not_renewed';Reason='USB identity is not currently connected';LastVerifiedHeartbeat=$status.LastHeartbeat;DeviceLeaseMs=45000;CurrentDeviceStateVerified=$false}
                Close-HlDeviceConnection $client; $client=$null
                # With a verified cached endpoint the retry is one cheap TCP probe,
                # so poll quickly; without one the SDK discovery interval applies.
                $retrySeconds=if(Get-HlEndpoint){$script:HlFastReconnectSeconds}else{$script:HlConfig.ReconnectSeconds}
                $nextCheck=[DateTime]::UtcNow.AddSeconds($retrySeconds)
            }
            if ($status.State -ne $lastLoggedState) { Write-HlLog ($status.State + $(if($status.LastError){': '+$status.LastError}else{''})); $lastLoggedState=$status.State }
            Save-HlStatus
        }
        if (-not $stopping) { $null=$pendingConnection.Wait(250) }
    }
} catch {
    $status.State='failed'; $status.LastError=Get-HlErrorMessage $_.Exception
    try { Save-HlStatus; Write-HlLog ('Fatal: '+$status.LastError) } catch {}
    exit 1
} finally {
    if ($pipe) { $pipe.Dispose() }
    Close-HlDeviceConnection $client
    if ($status.State -ne 'failed') { $status.State='stopped'; try { Save-HlStatus; Write-HlLog 'Bridge stopped.' } catch {} }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
