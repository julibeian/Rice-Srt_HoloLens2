$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\ops\Holographic.Common.ps1')
. (Join-Path $PSScriptRoot '..\ops\PortalPairing.Common.ps1')
if(-not ('PortalPairingTestState' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class PortalPairingTestState {
 public int PinRequests,PairRequests,InfoRequests;
 public bool Paired,DropPairResponse,RejectPair,DropPinResponse,RejectAuthentication;
 public string LastPairUri;
}
public sealed class PortalPairingTestHandler:HttpMessageHandler {
 public CookieContainer CookieContainer=new CookieContainer();
 readonly PortalPairingTestState state;
 public PortalPairingTestHandler(PortalPairingTestState value){state=value;}
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r,CancellationToken c){
  int status=200;
  switch(r.RequestUri.AbsolutePath){
   case "/devicepair.htm": break;
   case "/api/authorize/startpair":
    state.PinRequests++;if(state.DropPinResponse)throw new HttpRequestException("simulated response loss");break;
   case "/api/authorize/pair":
    state.PairRequests++;state.LastPairUri=r.RequestUri.AbsoluteUri;
    if(state.RejectPair){status=400;break;}
    state.Paired=true;if(state.DropPairResponse)throw new HttpRequestException("simulated response loss");break;
   case "/api/os/info":
    state.InfoRequests++;status=state.Paired&&!state.RejectAuthentication&&r.Headers.Authorization!=null?200:401;break;
   default:throw new InvalidOperationException("unexpected test endpoint");
  }
  return Task.FromResult(new HttpResponseMessage((HttpStatusCode)status));
 }
}
'@
}
$realRoot=$script:HolographicRoot
$testRoot=Join-Path $realRoot ('.state\portal-pairing-tests\'+[Guid]::NewGuid().ToString('N'))
$script:testFixture=$null;$script:testKey='K1';$script:testSsh='saved-ssh'
function New-HoloPortalContext {
 $handler=[PortalPairingTestHandler]::new($script:testFixture)
 @{Device=[pscustomobject]@{DeviceName='test-hololens';HostFingerprint=$script:testSsh};BaseUri='https://169.254.1.2';CertificateSha256='leaf';PublicKeySha256=$script:testKey;Handler=$handler;Client=[Net.Http.HttpClient]::new($handler)}
}
function Start-Case([string]$Name){
 $script:HolographicRoot=Join-Path $testRoot $Name
 $script:testFixture=[PortalPairingTestState]::new();$script:testKey='K1';$script:testSsh='saved-ssh'
}
function Assert-Case([bool]$Condition,[string]$Name){if(-not $Condition){throw ('Pairing boundary failed: '+$Name)};$script:passed++}
$script:passed=0
$pin=ConvertTo-SecureString '0123456' -AsPlainText -Force
try {
 Start-Case 'normal'
 $first=Invoke-HoloPortalPairing -Mode Start -RunId test
 $again=Invoke-HoloPortalPairing -Mode Start -RunId test
 Assert-Case ($first.State -eq 'awaiting_device_pin' -and $script:testFixture.PinRequests -eq 1 -and $script:testFixture.PairRequests -eq 0) 'PIN request is sent once and does not alter the account'
 $result=Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin
 $repeat=Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin
 Assert-Case ($result.State -eq 'authenticated' -and $result.Saved -and $script:testFixture.PairRequests -eq 1) 'Pair submission is sent once and credentials are saved after authentication'
 $saved=Import-Clixml -LiteralPath (Join-Path $script:HolographicRoot '.state\portal-credential.clixml')
 $password=$saved.Credential.GetNetworkCredential().Password
 $plainFiles=@(Get-ChildItem -LiteralPath (Join-Path $script:HolographicRoot '.state') -File -Recurse|ForEach-Object{[IO.File]::ReadAllText($_.FullName)}) -join "`n"
 Assert-Case (-not $plainFiles.Contains($password) -and -not $plainFiles.Contains('0123456') -and $password.Length -ge 32) 'Checkpoints and DPAPI files contain no plaintext password or PIN'
 Assert-Case ($script:testFixture.LastPairUri.Contains('pin=0123456') -and $script:testFixture.LastPairUri.Contains('username=RiceFieldUsb') -and [uri]::UnescapeDataString($script:testFixture.LastPairUri).Contains($password)) 'Submission matches the official device pairing protocol and preserves leading zeroes'
 $existing=Invoke-HoloPortalPairing -Mode Start -RunId another
 Assert-Case ($existing.State -eq 'authenticated' -and $script:testFixture.PinRequests -eq 1) 'A valid saved account prevents unnecessary account replacement'
 $script:testFixture.RejectAuthentication=$true
 $current=Invoke-HoloPortalPairing -Mode Status -RunId test
 Assert-Case ($current.State -eq 'saved_authentication_unverified' -and -not $current.PortalAuthenticated -and $script:testFixture.PairRequests -eq 1) 'Historical authentication is not reported as currently verified'
 $password=$null;$saved=$null;$plainFiles=$null

 Start-Case 'lost-pair-response';$script:testFixture.DropPairResponse=$true
 Invoke-HoloPortalPairing -Mode Start -RunId test|Out-Null
 $result=Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin
 Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin|Out-Null
 Assert-Case ($result.State -eq 'authenticated' -and $result.Saved -and $script:testFixture.PairRequests -eq 1) 'Lost pairing response recovers by authentication without resubmitting'

 Start-Case 'unknown-pair-result';$script:testFixture.DropPairResponse=$true;$script:testFixture.RejectAuthentication=$true
 Invoke-HoloPortalPairing -Mode Start -RunId test|Out-Null
 $result=Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin
 Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin|Out-Null
 Assert-Case ($result.State -eq 'pair_result_unconfirmed' -and $null -eq $result.CredentialsChangedOnDevice -and -not $result.Saved -and $script:testFixture.PairRequests -eq 1) 'An ambiguous result preserves unknown account state and is never resubmitted'

 Start-Case 'rejected-pair';$script:testFixture.RejectPair=$true
 Invoke-HoloPortalPairing -Mode Start -RunId test|Out-Null
 $result=Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin
 Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin|Out-Null
 Assert-Case ($result.State -eq 'pair_rejected' -and -not $result.Saved -and $script:testFixture.PairRequests -eq 1) 'A rejected PIN is not retried automatically and cannot mark credentials saved'

 Start-Case 'lost-pin-response';$script:testFixture.DropPinResponse=$true
 $result=Invoke-HoloPortalPairing -Mode Start -RunId test
 Invoke-HoloPortalPairing -Mode Start -RunId test|Out-Null
 Assert-Case ($result.State -eq 'pin_request_unconfirmed' -and $script:testFixture.PinRequests -eq 1) 'An uncertain PIN request is not replayed'

 Start-Case 'pin-not-displayed'
 Invoke-HoloPortalPairing -Mode Start -RunId test|Out-Null
 $statePath=Join-Path $script:HolographicRoot '.state\portal-pairing\test\state.json'
 $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
 $state.Phase='pin_not_displayed'
 $state|Add-Member -NotePropertyName UserReportedPinVisible -NotePropertyValue $false
 $state|Add-Member -NotePropertyName UserReportedScreen -NotePropertyValue 'sign_in_or_unlock'
 Save-HoloPairingState $state $statePath
 $result=Invoke-HoloPortalPairing -Mode Start -RunId test
 $rejected=$false
 try{Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin|Out-Null}catch{$rejected=$true}
 Assert-Case ($result.State -eq 'pin_not_displayed' -and $result.UserReportedScreen -eq 'sign_in_or_unlock' -and $rejected -and $script:testFixture.PinRequests -eq 1 -and $script:testFixture.PairRequests -eq 0) 'An unseen PIN on a locked screen is not replayed or submitted'

 Start-Case 'changed-identity'
 Invoke-HoloPortalPairing -Mode Start -RunId test|Out-Null
 $script:testKey='unexpected-key';$rejected=$false
 try {Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin|Out-Null}catch{$rejected=$true}
 Assert-Case ($rejected -and $script:testFixture.PairRequests -eq 0) 'Changed device key blocks submission'
 $script:testKey='K1';$script:testSsh='unexpected-ssh';$rejected=$false
 try {Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin $pin|Out-Null}catch{$rejected=$true}
 Assert-Case ($rejected -and $script:testFixture.PairRequests -eq 0) 'Changed SSH identity blocks submission'

 Start-Case 'invalid-pin';$rejected=$false
 try {Invoke-HoloPortalPairing -Mode Complete -RunId test -Pin (ConvertTo-SecureString 'bad-input' -AsPlainText -Force)|Out-Null}catch{$rejected=$true}
 Assert-Case ($rejected -and $script:testFixture.PinRequests -eq 0 -and $script:testFixture.PairRequests -eq 0) 'Invalid PIN input performs no request'
 [pscustomobject]@{Cases=$script:passed;Passed=$script:passed;DeviceContacted=$false;CredentialStoresChanged=$false;Evidence=$testRoot}|ConvertTo-Json
}finally{$script:HolographicRoot=$realRoot;$pin.Dispose()}
