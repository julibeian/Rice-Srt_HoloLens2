$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$pair=$null;$device=$null;$session=$null
try{
 $issued=ssh -o BatchMode=yes -o ConnectTimeout=10 aliyun 'sudo -n -u admin python3 /opt/rice-hololens-app/current/server.py pair-code --data-dir /var/lib/rice-hololens-app'
 if($LASTEXITCODE -ne 0){throw 'Could not issue deployment test code.'}
 $pair=($issued|ConvertFrom-Json).pair_code
 $device=Invoke-RestMethod -Method Post -Uri 'https://rice-srt.cn/hololens-app/api/register' -ContentType 'application/json' -Body (@{pair_code=$pair;device_label='deployment-api-smoke-test'}|ConvertTo-Json -Compress) -TimeoutSec 15
 $session=Invoke-RestMethod -Method Post -Uri 'https://rice-srt.cn/hololens-app/api/session' -ContentType 'application/json' -Body ($device|ConvertTo-Json -Compress) -TimeoutSec 15
 $photo=Join-Path $root '.state\preview\assets\symptoms\blast-leaf.jpg'
 $hash=(Get-FileHash -LiteralPath $photo).Hash.ToLowerInvariant()
 $id='cloud-smoke-'+[Guid]::NewGuid().ToString('N')
 $headers=@{Authorization=('Bearer '+$session.access_token);'X-Request-ID'=$id;'X-Image-SHA256'=$hash}
 $result=Invoke-RestMethod -Method Post -Uri 'https://rice-srt.cn/hololens-app/api/predict' -Headers $headers -Form @{file=[IO.FileInfo]::new($photo)} -TimeoutSec 55
 if($result.capture_evidence.request_id -ne $id -or $result.capture_evidence.image_sha256 -ne $hash -or $result.capture_evidence.channel -ne 'hololens-app'){throw 'Live image/result binding did not match.'}
 $again=Invoke-RestMethod -Method Post -Uri 'https://rice-srt.cn/hololens-app/api/predict' -Headers $headers -Form @{file=[IO.FileInfo]::new($photo)} -TimeoutSec 15
 if($again.capture_evidence.prediction_id -ne $result.capture_evidence.prediction_id){throw 'Live idempotency did not match.'}
 $proof=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Scope='PC to cloud deployment verification with a bundled reference photo; no HoloLens UI or camera claim';ImageSha256=$hash;RequestId=$id;IdempotentRetry=$true;Result=$result}
 $path=Join-Path $root ('.state\cloud-smoke-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'.json')
 [IO.File]::WriteAllText($path,($proof|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
 [ordered]@{Evidence=$path;Channel=$result.capture_evidence.channel;PredictionId=$result.capture_evidence.prediction_id;PredictedClass=$result.predicted_class;IsValid=$result.is_valid;ElapsedMs=$result.capture_evidence.upstream_elapsed_ms}|ConvertTo-Json -Compress
}finally{$headers=$null;$session=$null;$device=$null;$pair=$null;$issued=$null}
