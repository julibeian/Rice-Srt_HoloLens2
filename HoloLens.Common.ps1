Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:HlRoot = $PSScriptRoot
$script:HlConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$script:HlStateDirectory = Join-Path $PSScriptRoot '.state'
[IO.Directory]::CreateDirectory($script:HlStateDirectory) | Out-Null
$script:HlUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:HlPipeName = 'HoloLensUsbBridge-' + $script:HlUserSid.Replace('-', '_')

function Get-HlErrorMessage($Exception) {
    $message = $Exception.Message
    while ($Exception.InnerException) { $Exception = $Exception.InnerException; $message = $Exception.Message }
    return $message
}

function Import-HlSdk {
    [Reflection.Assembly]::LoadFrom((Join-Path $script:HlConfig.SdkDirectory 'Microsoft.Tools.Deploy.dll')) | Out-Null
}

function Get-HlScheduledTask {
    $service=New-Object -ComObject Schedule.Service
    $service.Connect()
    try { return $service.GetFolder('\').GetTask($script:HlConfig.ScheduledTaskName) } catch { return $null }
}

function Set-HlTaskAutostart([bool]$Enabled) {
    $service=New-Object -ComObject Schedule.Service
    $service.Connect()
    $folder=$service.GetFolder('\')
    $existing=$folder.GetTask($script:HlConfig.ScheduledTaskName)
    $definition=$existing.Definition
    $expected=Join-Path $script:HlRoot 'HoloLens.Watchdog.ps1'
    if($definition.Actions.Item(1).Arguments -notmatch [regex]::Escape($expected)){throw 'Unexpected scheduled task owner.'}
    foreach($trigger in $definition.Triggers){$trigger.Enabled=$Enabled}
    $definition.Settings.Enabled=$true
    $registered=$folder.RegisterTaskDefinition($existing.Name,$definition,6,$script:HlUserSid,$null,3,$null)
    return @{TaskName=$registered.Name;Autostart=$Enabled}
}

function ConvertFrom-HlDiscoveryOutput([string[]]$Lines) {
    $candidates = foreach ($line in $Lines) {
        if ($line -match '^\s*(?<ip>169\.254\.\d+\.\d+)\s+(?<id>[0-9a-fA-F-]{36})\s+(?<name>.+?)\s*$') {
            $parsedAddress = $null
            if ($Matches.name -eq $script:HlConfig.DeviceName -and [Net.IPAddress]::TryParse($Matches.ip, [ref]$parsedAddress)) {
                [pscustomobject]@{ Address=$parsedAddress.ToString(); DiscoveryGuid=$Matches.id }
            }
        }
    }
    $candidates | Sort-Object @{Expression={ $_.DiscoveryGuid -ne $script:HlConfig.DiscoveryGuid }}, Address -Unique
}

function Get-HlDiscoveredDevices {
    param([ValidateRange(1,30000)][int]$TimeoutMilliseconds=12000)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $script:HlConfig.SdkDirectory 'WinAppDeployCmd.exe'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add('devices')
    $start.ArgumentList.Add('3')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Windows SDK discovery process did not start.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $ownedPid = $process.Id
            try { $process.Kill(); $null = $process.WaitForExit(2000) } catch {}
            $failure = [TimeoutException]::new('Windows SDK discovery timed out; its own child process was stopped. The bridge can retry without replaying a device command.')
            $failure.Data['DiscoveryProcessId'] = $ownedPid
            throw $failure
        }
        $stdout = $output.GetAwaiter().GetResult()
        $stderr = $errors.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw ('Windows SDK discovery failed (exit ' + $process.ExitCode + '): ' + $stderr.Trim()) }
        ConvertFrom-HlDiscoveryOutput ($stdout -split '\r?\n')
    } finally { $process.Dispose() }
}

function Close-HlDeviceConnection($Client) {
    if ($null -eq $Client) { return }
    # Release the SDK object even if disconnecting a lost device fails.
    try { $Client.Disconnect() } catch {}
    try { $Client.Dispose() } catch {}
}

function Write-HlBridgeStatus($Status, [string]$StateDirectory=$script:HlStateDirectory) {
    $Status.UpdatedAt=[DateTimeOffset]::Now.ToString('o')
    $temporary=Join-Path $StateDirectory 'status.tmp'
    $destination=Join-Path $StateDirectory 'status.json'
    [IO.File]::WriteAllText($temporary,($Status|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    try {
        for($attempt=0;;$attempt++) {
            try { [IO.File]::Move($temporary,$destination,$true); return }
            catch [IO.IOException] { if($attempt -ge 39){throw} }
            catch [UnauthorizedAccessException] { if($attempt -ge 39){throw} }
            # Windows readers may briefly omit FILE_SHARE_DELETE. Do not tear
            # down an authenticated device session for this local file race.
            Start-Sleep -Milliseconds 25
        }
    } finally { if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue} }
}

function Find-HlDevice {
    param([switch]$KeepConnection)
    $candidates = @(Get-HlDiscoveredDevices)
    if (-not $candidates.Count) { throw 'Target HoloLens USB network is unavailable; waiting for the same device to reconnect.' }
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        $probe = $null
        try {
            # A USB/MAC-derived discovery GUID can change after reconnecting.
            # Only the existing authenticated SSH host fingerprint establishes identity.
            $probe = Connect-HlDevice $candidate.Address
            $script:HlDiscoveredGuid = $candidate.DiscoveryGuid
            if ($KeepConnection) {
                $connection = [pscustomobject]@{ Address=$candidate.Address; Client=$probe }
                $probe = $null
                return $connection
            }
            return $candidate.Address
        } catch { $errors.Add($candidate.Address + ': ' + (Get-HlErrorMessage $_.Exception)) }
        finally { Close-HlDeviceConnection $probe }
    }
    throw ('No discovered candidate authenticated as the paired HoloLens. ' + ($errors -join '; '))
}

function Test-HlWorkerStalled($SavedStatus, [int]$WorkerId, [DateTimeOffset]$Now, [int]$LimitSeconds=120) {
    if ($null -eq $SavedStatus -or $SavedStatus.ProcessId -ne $WorkerId) { return $false }
    $updated = $SavedStatus.PSObject.Properties['UpdatedAt']
    if (-not $updated -or -not $updated.Value) { return $false }
    $at = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$updated.Value, [ref]$at)) { return $false }
    return ($Now - $at).TotalSeconds -gt $LimitSeconds
}

function Connect-HlDevice([string]$Address) {
    $client = [Microsoft.Tools.Deploy.RemoteDeployClient]::CreateRemoteDeployClient()
    $options = [Microsoft.Tools.Deploy.ConnectionOptions]::new()
    $options.IPAddress = [Net.IPAddress]::Parse($Address)
    $options.Credentials = [Net.NetworkCredential]::new('DevToolsUser', '')
    $options.ConnectTimeout = [TimeSpan]::FromSeconds(8)
    try {
        $client.Connect($options)
        if ($client.RemoteDevice.Sha1Fingerprint -ne $script:HlConfig.ExpectedFingerprint) {
            throw 'SSH host identity differs from the paired HoloLens. Automatic trust is refused.'
        }
        $client.RemoteDevice.Timeout = [TimeSpan]::FromSeconds(8)
        if (-not $client.RemoteDevice.Directory($script:HlConfig.RemoteWorkingDirectory).Exists) {
            $client.RemoteDevice.CreateDirectory($script:HlConfig.RemoteWorkingDirectory)
        }
        return $client
    } catch {
        Close-HlDeviceConnection $client
        throw
    }
}

function Get-HlDeviceInfo($Client, [string]$Address) {
    if ($Client.RemoteDevice.Sha1Fingerprint -cne $script:HlConfig.ExpectedFingerprint) {
        throw 'SSH host identity differs from the paired HoloLens. Device metadata cannot establish trust.'
    }
    $target = [ordered]@{}
    $metadataErrors = [Collections.Generic.List[string]]::new()
    $targetInfo = $null
    try { $targetInfo = $Client.TargetInfo } catch { $metadataErrors.Add('TargetInfo: ' + (Get-HlErrorMessage $_.Exception)) }
    if ($null -eq $targetInfo) {
        $metadataErrors.Add('SDK target metadata is unavailable; authenticated SSH identity remains independently checked.')
    } else {
        foreach ($property in $targetInfo.PSObject.Properties) {
            try {
                $value = $property.Value
                $target[$property.Name] = if ($null -eq $value) { $null } elseif ($value -is [bool] -or $value -is [string]) { $value } else { $value.ToString() }
            } catch { $metadataErrors.Add($property.Name + ': ' + (Get-HlErrorMessage $_.Exception)) }
        }
    }
    $architecture = $null
    try {
        if ($null -ne $Client.EffectiveProcessorArchitecture) { $architecture = $Client.EffectiveProcessorArchitecture.ToString() }
    } catch { $metadataErrors.Add('Architecture: ' + (Get-HlErrorMessage $_.Exception)) }
    return [ordered]@{
        DeviceName = $script:HlConfig.DeviceName
        DiscoveryGuid = if (Get-Variable HlDiscoveredGuid -Scope Script -ErrorAction SilentlyContinue) { $script:HlDiscoveredGuid } else { $script:HlConfig.DiscoveryGuid }
        Address = $Address
        Transport = if ($Address -match '^169\.254\.') { 'USB NCM / authenticated SSH' } else { 'Network / authenticated SSH' }
        User = $Client.RemoteDevice.UserName
        HostFingerprint = $Client.RemoteDevice.Sha1Fingerprint
        Architecture = $architecture
        WorkingDirectory = $script:HlConfig.RemoteWorkingDirectory
        Target = $target
        MetadataAvailable = $null -ne $targetInfo
        MetadataErrors = $metadataErrors.ToArray()
    }
}

function Resolve-HlPath([string]$Path, [string]$WorkingDirectory) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $WorkingDirectory }
    return [IO.Path]::GetFullPath($Path, $WorkingDirectory)
}

function Invoke-HlOperation($Client, $Request, [string]$Address) {
    $workingDirectory = if ($Request.Contains('cwd') -and $Request.cwd) { [string]$Request.cwd } else { $script:HlConfig.RemoteWorkingDirectory }
    switch ([string]$Request.action) {
        'info' { return Get-HlDeviceInfo $Client $Address }
        'ls' {
            $path = Resolve-HlPath $Request.path $workingDirectory
            $directory = $Client.RemoteDevice.Directory($path)
            if (-not $directory.Exists) { throw "Remote directory does not exist: $path" }
            $entries = [Collections.Generic.List[object]]::new()
            foreach ($item in $Client.RemoteDevice.GetDirectories($path)) { $entries.Add(@{ Type='Directory'; Name=[IO.Path]::GetFileName($item); Path=$item }) }
            foreach ($item in $Client.RemoteDevice.GetFiles($path)) { $entries.Add(@{ Type='File'; Name=[IO.Path]::GetFileName($item); Path=$item }) }
            return @{ Path=$path; Entries=$entries.ToArray() }
        }
        'cd' {
            $path = Resolve-HlPath $Request.path $workingDirectory
            if (-not $Client.RemoteDevice.Directory($path).Exists) { throw "Remote directory does not exist: $path" }
            return @{ WorkingDirectory=$path }
        }
        'mkdir' {
            $path = Resolve-HlPath $Request.path $workingDirectory
            if (-not $Client.RemoteDevice.Directory($path).Exists) { $Client.RemoteDevice.CreateDirectory($path) }
            return @{ Created=$path }
        }
        'stat' {
            $path = Resolve-HlPath $Request.path $workingDirectory
            $file = $Client.RemoteDevice.File($path)
            return @{ Path=$path; Exists=$file.Exists; Length=if($file.Exists){$file.Length}else{$null}; LastWriteTime=if($file.Exists){$file.LastWriteTime.ToString('o')}else{$null} }
        }
        'get' {
            $path = Resolve-HlPath $Request.path $workingDirectory
            $destination = [IO.Path]::GetFullPath([string]$Request.local)
            $Client.RemoteDevice.GetFile($path,$destination,$false)
            return @{ RemotePath=$path; LocalPath=$destination; Length=(Get-Item -LiteralPath $destination).Length }
        }
        'put' {
            $source = (Get-Item -LiteralPath ([string]$Request.local) -ErrorAction Stop).FullName
            $path = Resolve-HlPath $Request.path $workingDirectory
            $Client.RemoteDevice.PutFile($path,$source,$false)
            return @{ LocalPath=$source; RemotePath=$path; Length=(Get-Item -LiteralPath $source).Length }
        }
        'cat' {
            $path = Resolve-HlPath $Request.path $workingDirectory
            $file = $Client.RemoteDevice.File($path)
            if (-not $file.Exists) { throw "Remote file does not exist: $path" }
            if ($file.Length -gt 4MB) { throw 'Use get to download files larger than 4 MiB.' }
            $temporary = Join-Path $script:HlStateDirectory ([Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                $Client.RemoteDevice.GetFile($path,$temporary,$false)
                return @{ Path=$path; Text=[IO.File]::ReadAllText($temporary) }
            } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
        }
        'exec' {
            $executable = [string]$Request.executable
            if ($executable -notmatch '[\\/:]') {
                if (-not [IO.Path]::GetExtension($executable)) { $executable += '.exe' }
                $found = $false
                foreach ($folder in @($workingDirectory,'C:\Windows\System32','C:\Windows\System32\OpenSSH')) {
                    $candidate = [IO.Path]::Combine($folder,$executable)
                    if ($Client.RemoteDevice.File($candidate).Exists) { $executable=$candidate; $found=$true; break }
                }
                if (-not $found) { throw "Remote executable not found: $executable. This HoloLens has no installed CMD/PowerShell." }
            } else { $executable = Resolve-HlPath $executable $workingDirectory }
            $command = $Client.RemoteDevice.Command($executable,[string]$Request.arguments)
            $command.WorkingFolder = $workingDirectory
            $command.CaptureOutput = $true
            $command.Timeout = [TimeSpan]::FromSeconds($script:HlConfig.CommandTimeoutSeconds)
            $exitCode = $command.Execute()
            return @{ Executable=$executable; Arguments=[string]$Request.arguments; ExitCode=$exitCode; Output=$command.Output }
        }
        default { throw "Unsupported operation: $($Request.action)" }
    }
}

function Invoke-HlBridge([hashtable]$Request, [int]$ConnectTimeoutMilliseconds=15000) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $script:HlPipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect($ConnectTimeoutMilliseconds)
        $reader = [IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,4096,$true)
        $writer = [IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),4096,$true)
        $writer.AutoFlush = $true
        $writer.WriteLine(($Request | ConvertTo-Json -Depth 8 -Compress))
        $read = $reader.ReadLineAsync()
        if (-not $read.Wait(45000)) { throw 'The bridge response timed out. Execution outcome may be unknown; commands are never automatically repeated.' }
        if (-not $read.Result) { throw 'Bridge closed the connection without a response.' }
        $response = $read.Result | ConvertFrom-Json -AsHashtable
        if (-not $response.ok) { throw $response.error }
        return $response.data
    } finally { $pipe.Dispose() }
}
