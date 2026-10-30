$ErrorActionPreference='Stop'
if(-not ('HoloVideoRawTransport' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

// Read-only experiment. Independent HTTP/1.1 framing over pinned TLS; never
// changes the product transport or system TCP/certificate settings.
public static class HoloVideoRawTransport {
    public sealed class Chunk {public long byte_end;public double received_ms;public int bytes;}
    public sealed class Capture {
        public long Bytes;public double Seconds;public Chunk[] Chunks;
        public int HttpStatus;public string Framing;public bool CertificateVerified;
    }
    sealed class Reader {
        readonly Stream source;readonly byte[] buffer=new byte[65536];
        internal readonly Stopwatch Clock=new Stopwatch();
        internal CancellationToken Token;internal double Received;
        int position,count;
        internal Reader(Stream source,CancellationToken token){this.source=source;Token=token;}
        async Task<bool> Fill(){
            if(position<count)return true;
            count=await source.ReadAsync(buffer,0,buffer.Length,Token).ConfigureAwait(false);
            position=0;Received=Clock.Elapsed.TotalMilliseconds;return count!=0;
        }
        internal async Task<string> Line(int max){
            var line=new StringBuilder();
            while(await Fill().ConfigureAwait(false)){
                byte b=buffer[position++];
                if(b==10){if(line.Length==0||line[line.Length-1]!='\r')throw new InvalidDataException("HTTP line lacks CRLF");line.Length--;return line.ToString();}
                if(line.Length>=max)throw new InvalidDataException("HTTP line exceeds bound");
                line.Append((char)b);
            }
            throw new EndOfStreamException("Truncated HTTP framing");
        }
        internal async Task<long> Copy(long remaining,Stream output,List<Chunk> chunks,long total,bool eofAllowed){
            while(remaining>0){
                if(!await Fill().ConfigureAwait(false)){
                    if(eofAllowed)return total;
                    throw new EndOfStreamException("Truncated HTTP body");
                }
                int n=(int)Math.Min(remaining,count-position);
                output.Write(buffer,position,n);position+=n;total+=n;remaining-=n;
                chunks.Add(new Chunk {byte_end=total,received_ms=Received,bytes=n});
            }
            return total;
        }
    }
    public static async Task<Capture> ReadResponseAsync(Stream source,Stream output,int seconds,CancellationToken cancellation){
        using(var budget=CancellationTokenSource.CreateLinkedTokenSource(cancellation)){
            var reader=new Reader(source,budget.Token);
            string status=await reader.Line(8192).ConfigureAwait(false);
            if(!status.StartsWith("HTTP/1.1 200 ",StringComparison.Ordinal)&&!status.StartsWith("HTTP/1.0 200 ",StringComparison.Ordinal))
                throw new InvalidDataException("Raw stream did not return HTTP 200");
            string encoding=null;long length=-1;int headerBytes=status.Length+2;
            while(true){
                string line=await reader.Line(8192).ConfigureAwait(false);headerBytes+=line.Length+2;
                if(headerBytes>65536)throw new InvalidDataException("HTTP headers exceed bound");
                if(line.Length==0)break;
                int split=line.IndexOf(':');if(split<1)throw new InvalidDataException("Invalid HTTP header");
                string name=line.Substring(0,split),value=line.Substring(split+1).Trim();
                if(name.Equals("Transfer-Encoding",StringComparison.OrdinalIgnoreCase)){
                    if(encoding!=null)throw new InvalidDataException("Duplicate transfer encoding");encoding=value;
                }
                if(name.Equals("Content-Length",StringComparison.OrdinalIgnoreCase)){
                    long parsed;if(length>=0||!long.TryParse(value,NumberStyles.None,CultureInfo.InvariantCulture,out parsed)||parsed<0)
                        throw new InvalidDataException("Invalid content length");length=parsed;
                }
                if(name.Equals("Content-Encoding",StringComparison.OrdinalIgnoreCase)&&!value.Equals("identity",StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Unexpected compressed response");
            }
            bool chunked=encoding!=null;
            if(chunked&&(!encoding.Equals("chunked",StringComparison.OrdinalIgnoreCase)||length>=0))
                throw new InvalidDataException("Unsupported or ambiguous HTTP framing");
            var chunks=new List<Chunk>();long total=0;
            reader.Clock.Start();reader.Received=0;budget.CancelAfter(TimeSpan.FromSeconds(seconds));
            try{
                if(chunked){
                    while(total<67108864){
                        string line=await reader.Line(128).ConfigureAwait(false);int extension=line.IndexOf(';');
                        string size=extension<0?line:line.Substring(0,extension);
                        long n;if(size.Length==0||!long.TryParse(size,NumberStyles.AllowHexSpecifier,CultureInfo.InvariantCulture,out n)||n<0||n>67108864-total)
                            throw new InvalidDataException("Invalid or oversized HTTP chunk");
                        if(n==0){int trailers=0;while((line=await reader.Line(8192).ConfigureAwait(false)).Length!=0){trailers+=line.Length+2;if(trailers>65536)throw new InvalidDataException("HTTP trailers exceed bound");}break;}
                        total=await reader.Copy(n,output,chunks,total,false).ConfigureAwait(false);
                        if((await reader.Line(2).ConfigureAwait(false)).Length!=0)throw new InvalidDataException("Chunk lacks trailing CRLF");
                    }
                }else{
                    if(length>67108864)throw new InvalidDataException("HTTP body exceeds bound");
                    total=await reader.Copy(length<0?67108864:length,output,chunks,0,length<0).ConfigureAwait(false);
                }
            }catch(OperationCanceledException) when(budget.IsCancellationRequested){
                // Copy can be interrupted within a chunk; sum only bytes actually written.
                total=chunks.Count==0?0:chunks[chunks.Count-1].byte_end;
            }
            return new Capture {Bytes=total,Seconds=reader.Clock.Elapsed.TotalSeconds,Chunks=chunks.ToArray(),HttpStatus=200,Framing=chunked?"chunked":length>=0?"content-length":"close"};
        }
    }
    public static async Task<Capture> CaptureAsync(string address,string leafSha256,string authorization,string path,Stream output,int seconds){
        IPAddress ip;if(!IPAddress.TryParse(address,out ip)||!address.StartsWith("169.254.",StringComparison.Ordinal))
            throw new InvalidOperationException("Raw experiment requires verified USB IPv4");
        if(leafSha256==null||leafSha256.Length!=64||authorization==null||!authorization.StartsWith("Basic ",StringComparison.Ordinal)||authorization.IndexOfAny(new[]{'\r','\n'})>=0)
            throw new InvalidOperationException("Invalid private connection configuration");
        if(!path.StartsWith("/api/holographic/stream/",StringComparison.Ordinal)||path.IndexOfAny(new[]{'\r','\n',' '})>=0)
            throw new InvalidOperationException("Unexpected diagnostic request path");
        bool verified=false;
        using(var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(seconds+20)))
        using(var socket=new TcpClient(AddressFamily.InterNetwork)){
            socket.NoDelay=true;
            await socket.ConnectAsync(ip,443,timeout.Token).ConfigureAwait(false);
            using(var tls=new SslStream(socket.GetStream(),false,(sender,cert,chain,errors)=>{
                verified=cert!=null&&cert.GetCertHashString(HashAlgorithmName.SHA256)==leafSha256;return verified;
            })){
                await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions {TargetHost=address,EnabledSslProtocols=SslProtocols.Tls12|SslProtocols.Tls13},timeout.Token).ConfigureAwait(false);
                if(!verified)throw new AuthenticationException("Exact leaf pin was not verified");
                // Credentials are sent only after that same connection passed the leaf pin.
                byte[] request=Encoding.ASCII.GetBytes("GET "+path+" HTTP/1.1\r\nHost: "+address+"\r\nAuthorization: "+authorization+"\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n");
                try{await tls.WriteAsync(request,0,request.Length,timeout.Token).ConfigureAwait(false);await tls.FlushAsync(timeout.Token).ConfigureAwait(false);}
                finally{Array.Clear(request,0,request.Length);}
                var result=await ReadResponseAsync(tls,output,seconds,timeout.Token).ConfigureAwait(false);result.CertificateVerified=verified;return result;
            }
        }
    }
}
'@
}
