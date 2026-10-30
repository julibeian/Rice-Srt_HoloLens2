# The device's own /js/devicepair.js uses these exact two POST endpoints.
# PINs and passwords stay out of checkpoints, process arguments and output.
function Save-HoloPairingState($State,[string]$Path) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($State|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$Path,$true)
}

function Test-HoloPairingIdentity($Saved,$Context) {
    $sameCertificate=if($Saved.PSObject.Properties['PublicKeySha256']){$Saved.PublicKeySha256 -ceq $Context.PublicKeySha256}else{$Saved.CertificateSha256 -ceq $Context.CertificateSha256}
    if($Saved.DeviceName -cne $Context.Device.DeviceName -or $Saved.SshFingerprint -cne $Context.Device.HostFingerprint -or -not $sameCertificate){throw 'Pairing state belongs to a different device or server key.'}
}

function Test-HoloPairingAuthentication($Context,[Management.Automation.PSCredential]$Credential) {
    $network=$Credential.GetNetworkCredential()
    $basic=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($network.UserName+':'+$network.Password))
    try {
        $Context.Client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',$basic)
        return (Invoke-HoloPortalRequest $Context GET '/api/os/info').Status -eq 200
    } catch { return $false }
    finally {$Context.Client.DefaultRequestHeaders.Authorization=$null;$network=$null;$basic=$null}
}

function Invoke-HoloPairingPost($Context,[Management.Automation.PSCredential]$Credential,[Security.SecureString]$Pin) {
    $request=$null;$response=$null;$network=$null;$pinText=$null;$query=$null;$uri=$null
    try {
        $network=$Credential.GetNetworkCredential()
        $pinText=[Net.NetworkCredential]::new('',$Pin).Password.Trim()
        if($pinText -notmatch '^[0-9]{4,12}$'){throw 'Invalid PIN format.'}
        # This query format is required by Microsoft's on-device pairing page.
        # The complete URI must never be returned, logged or exposed in errors.
        $query='pin='+[uri]::EscapeDataString($pinText)+'&username='+[uri]::EscapeDataString($network.UserName)+'&password='+[uri]::EscapeDataString($network.Password)
        $uri=[uri]($Context.BaseUri+'/api/authorize/pair?'+$query)
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$uri)
        $request.Content=[Net.Http.ByteArrayContent]::new([byte[]]::new(0))
        $csrf=$Context.Handler.CookieContainer.GetCookies($uri)['CSRF-Token']
        if($csrf){$request.Headers.Add('X-CSRF-Token',$csrf.Value)}
        $response=$Context.Client.SendAsync($request).GetAwaiter().GetResult()
        return [pscustomobject]@{Known=$true;Status=[int]$response.StatusCode}
    } catch {
        # A timeout may occur after the server has applied the new credentials.
        # Do not expose an exception containing the secret-bearing request URI.
        return [pscustomobject]@{Known=$false;Status=$null}
    } finally {
        if($response){$response.Dispose()};if($request){$request.Dispose()}
        $network=$null;$pinText=$null;$query=$null;$uri=$null
    }
}

function Invoke-HoloPortalPairing {
    param(
        [ValidateSet('Status','Start','Complete')][string]$Mode='Status',
        [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
        [Security.SecureString]$Pin
    )
    if(-not $IsWindows){throw 'Portal credentials must be protected by Windows current-user DPAPI.'}
    if($Mode -eq 'Complete'){
        if(-not $Pin){throw 'Complete requires the one-time PIN displayed by this headset.'}
        $pinText=[Net.NetworkCredential]::new('',$Pin).Password.Trim()
        $valid=$pinText -match '^[0-9]{4,12}$';$pinText=$null
        if(-not $valid){throw 'The device PIN must contain 4 to 12 decimal digits.'}
    }
    $base=Join-Path $script:HolographicRoot '.state\portal-pairing'
    [IO.Directory]::CreateDirectory($base)|Out-Null
    $lease=[IO.File]::Open((Join-Path $base 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $context=$null
    try {
        $folder=Join-Path $base $RunId
        $statePath=Join-Path $folder 'state.json'
        $draftPath=Join-Path $folder 'pending-credential.clixml'
        $credentialPath=Join-Path $script:HolographicRoot '.state\portal-credential.clixml'
        $context=New-HoloPortalContext
        if(Test-Path -LiteralPath $statePath){
            $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
            Test-HoloPairingIdentity $state $context
            $saved=Import-Clixml -LiteralPath $draftPath
            Test-HoloPairingIdentity $saved $context
            $credential=$saved.Credential
        } else {
            if($Mode -ne 'Start'){return [pscustomobject]@{State='not_started';RunId=$RunId;PortalAuthenticated=$false;CredentialsChangedOnDevice=$false}}
            if(Test-Path -LiteralPath $credentialPath){
                $existing=Import-Clixml -LiteralPath $credentialPath
                Test-HoloPairingIdentity $existing $context
                if(Test-HoloPairingAuthentication $context $existing.Credential){return [pscustomobject]@{State='authenticated';RunId=$RunId;Saved=$true;PortalAuthenticated=$true;CredentialsChangedOnDevice=$false}}
            }
            [IO.Directory]::CreateDirectory($folder)|Out-Null
            # Password generation and DPAPI persistence precede the PIN request.
            $password='R!'+[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))+'a7'
            $credential=[Management.Automation.PSCredential]::new('RiceFieldUsb',(ConvertTo-SecureString $password -AsPlainText -Force));$password=$null
            $saved=[pscustomobject]@{DeviceName=$context.Device.DeviceName;SshFingerprint=$context.Device.HostFingerprint;CertificateSha256=$context.CertificateSha256;PublicKeySha256=$context.PublicKeySha256;Credential=$credential;SavedAt=[DateTimeOffset]::Now.ToString('o')}
            $saved|Export-Clixml -LiteralPath $draftPath
            $state=[pscustomobject]@{RunId=$RunId;DeviceName=$context.Device.DeviceName;SshFingerprint=$context.Device.HostFingerprint;CertificateSha256=$context.CertificateSha256;PublicKeySha256=$context.PublicKeySha256;CreatedAt=[DateTimeOffset]::Now.ToString('o');Phase='prepared';PinRequestAttempted=$false;PinRequestedAt=$null;PairSubmissionAttempted=$false;PairHttpStatus=$null;CredentialsChangedOnDevice=$false;Saved=$false}
            Save-HoloPairingState $state $statePath
        }
        if($Mode -eq 'Start' -and -not $state.PinRequestAttempted){
            $page=Invoke-HoloPortalRequest $context GET '/devicepair.htm'
            if($page.Status -ne 200){throw 'The official device pairing page is unavailable.'}
            $state.PinRequestAttempted=$true;$state.Phase='pin_request_unconfirmed'
            Save-HoloPairingState $state $statePath
            try {
                $reply=Invoke-HoloPortalRequest $context POST '/api/authorize/startpair'
                if($reply.Status -eq 200){$state.Phase='awaiting_device_pin';$state.PinRequestedAt=[DateTimeOffset]::Now.ToString('o')}
                else {$state.Phase='pin_request_rejected'}
            } catch {$state.Phase='pin_request_unconfirmed'}
            Save-HoloPairingState $state $statePath
        }
        if($Mode -eq 'Complete' -and -not $state.PairSubmissionAttempted){
            if($state.Phase -ne 'awaiting_device_pin'){throw 'This run has no confirmed PIN request. Start a new explicit run before pairing.'}
            # Persist before POST: retries inspect authentication without repeating
            # a possibly completed account change, even after a transport failure.
            $state.PairSubmissionAttempted=$true;$state.Phase='pair_result_unconfirmed';$state.CredentialsChangedOnDevice=$null
            Save-HoloPairingState $state $statePath
            $reply=Invoke-HoloPairingPost $context $credential $Pin
            if($reply.Known){
                $state.PairHttpStatus=$reply.Status
                if($reply.Status -eq 200){$state.Phase='pair_accepted';$state.CredentialsChangedOnDevice=$true}
                else {$state.Phase='pair_rejected'}
            }
            Save-HoloPairingState $state $statePath
        }
        $authenticated=$false
        if($state.PairSubmissionAttempted){$authenticated=Test-HoloPairingAuthentication $context $credential}
        if($authenticated -and -not $state.Saved){
            if(Test-Path -LiteralPath $credentialPath){Copy-Item -LiteralPath $credentialPath -Destination (Join-Path $folder 'previous-credential.clixml')}
            $saved.CertificateSha256=$context.CertificateSha256;$saved.PublicKeySha256=$context.PublicKeySha256
            $saved.SavedAt=[DateTimeOffset]::Now.ToString('o')
            $temporary=$credentialPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
            $saved|Export-Clixml -LiteralPath $temporary
            [IO.File]::Move($temporary,$credentialPath,$true)
            $state.Phase='authenticated';$state.Saved=$true;$state.CredentialsChangedOnDevice=$true
            Save-HoloPairingState $state $statePath
        }
        $displayState=if($state.Saved -and -not $authenticated){'saved_authentication_unverified'}else{$state.Phase}
        $reportedPin=if($state.PSObject.Properties['UserReportedPinVisible']){$state.UserReportedPinVisible}else{$null}
        $reportedScreen=if($state.PSObject.Properties['UserReportedScreen']){$state.UserReportedScreen}else{$null}
        [pscustomobject]@{State=$displayState;RunId=$RunId;Device=$state.DeviceName;PinRequestedAt=$state.PinRequestedAt;PinRequestAttempted=$state.PinRequestAttempted;PairSubmissionAttempted=$state.PairSubmissionAttempted;PairHttpStatus=$state.PairHttpStatus;Saved=$state.Saved;PortalAuthenticated=[bool]$authenticated;CredentialsChangedOnDevice=$state.CredentialsChangedOnDevice;UserReportedPinVisible=$reportedPin;UserReportedScreen=$reportedScreen;PasswordProtection='Windows current-user DPAPI';ExistingPortalCredentialsMayBeReplaced=$true;ReplaySafe=$true;Evidence=$folder}
    } finally {if($context){$context.Client.Dispose()};$lease.Dispose()}
}
