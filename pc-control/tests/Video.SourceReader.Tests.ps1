$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../ops/Video.SourceReader.ps1')
. (Join-Path $PSScriptRoot '../ops/Video.RawTransport.ps1')
if(-not ('FragmentedVideoFixture' -as [type])){
    Add-Type -TypeDefinition @'
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class FragmentedVideoFixture : MemoryStream {
    public FragmentedVideoFixture(byte[] bytes):base(bytes) { }
    public override Task<int> ReadAsync(byte[] bytes,int offset,int count,CancellationToken cancellation) {
        return base.ReadAsync(bytes,offset,System.Math.Min(count,3),cancellation);
    }
}
'@
}
$cases=@(
    @{name='chunked_extensions_trailers';head="Transfer-Encoding: chunked`r`n";body="3;label=a`r`nabc`r`n2`r`nde`r`n0`r`nX-Test: yes`r`n`r`n";want='abcde';reject=$false},
    @{name='content_length';head="Content-Length: 5`r`n";body='abcde';want='abcde';reject=$false},
    @{name='close_delimited';head='';body='abcde';want='abcde';reject=$false},
    @{name='truncated_chunk';head="Transfer-Encoding: chunked`r`n";body="5`r`nabc";reject=$true},
    @{name='ambiguous_framing';head="Transfer-Encoding: chunked`r`nContent-Length: 5`r`n";body='';reject=$true},
    @{name='invalid_chunk_crlf';head="Transfer-Encoding: chunked`r`n";body="3`r`nabcX`r`n0`r`n`r`n";reject=$true},
    @{name='unsupported_encoding';head="Transfer-Encoding: gzip`r`n";body='';reject=$true},
    @{name='oversized_chunk';head="Transfer-Encoding: chunked`r`n";body="4000001`r`n";reject=$true}
)
$results=@(foreach($case in $cases){
    $source=[FragmentedVideoFixture]::new([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`n"+$case.head+"`r`n"+$case.body))
    $output=[IO.MemoryStream]::new();$rejected=$false;$errorType=$null;$capture=$null
    try{
        try{$capture=[HoloVideoRawTransport]::ReadResponseAsync($source,$output,1,[Threading.CancellationToken]::None).GetAwaiter().GetResult()}
        catch{$rejected=$true;$errorType=$_.Exception.GetBaseException().GetType().Name}
        $actual=[Text.Encoding]::ASCII.GetString($output.ToArray())
        $ok=if($case.reject){$rejected -and $errorType -in @('InvalidDataException','EndOfStreamException')}
            else{-not $rejected -and $actual -ceq $case.want -and $capture.Bytes -eq 5 -and $capture.Chunks[-1].byte_end -eq 5}
        [pscustomobject]@{name=$case.name;pass=[bool]$ok;rejected=$rejected;error_type=$errorType}
    }finally{$source.Dispose();$output.Dispose()}
})
$source=[FragmentedVideoFixture]::new([Text.Encoding]::ASCII.GetBytes('abcdefghijklmnop'))
$output=[IO.MemoryStream]::new()
try{
    $capture=[HoloVideoSourceReader]::CopyAsync($source,$output,[Diagnostics.Stopwatch]::StartNew(),[Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $actual=[Text.Encoding]::ASCII.GetString($output.ToArray())
    $results+=[pscustomobject]@{name='native_partial_reads_preserve_bytes';pass=($actual -ceq 'abcdefghijklmnop' -and $capture.Bytes -eq 16 -and $capture.Chunks.Count -eq 6 -and $capture.Chunks[-1].byte_end -eq 16);rejected=$false;error_type=$null}
}finally{$source.Dispose();$output.Dispose()}
$results|ConvertTo-Json -Depth 4
if(@($results|Where-Object {-not $_.pass}).Count){throw 'Video source reader checks failed'}
