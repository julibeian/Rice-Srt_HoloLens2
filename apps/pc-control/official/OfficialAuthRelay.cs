// A temporary authentication/transport adapter for the UNMODIFIED Microsoft GUI.
// It never generates simulation packets, video frames or synthetic API responses.
// Secrets arrive via the private stdin pipe and never enter command-line arguments.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Authentication;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web;
using System.Web.Script.Serialization;

sealed class RelayConfig {
    public int OfficialProcessId { get; set; }
    public long OfficialStartTicks { get; set; }
    public int Port { get; set; }
    public string Address { get; set; }
    public string CertificateSha256 { get; set; }
    public string Authorization { get; set; }
    public string Cookie { get; set; }
    public string CsrfToken { get; set; }
    public string ExpiresAt { get; set; }
    public string Folder { get; set; }
}

static class OfficialAuthRelay {
    const string ExpectedGuiHash = "B31AA8177BE97AF20D0B3C97E59BB3AD169082920C86CB6BFF0BC0B2F8DDA09D";
    const string Control = "/api/holographic/simulation/control/";
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static readonly object LogGate = new object(), StreamGate = new object();
    static readonly HashSet<string> OwnedStreams = new HashSet<string>(StringComparer.Ordinal);
    static readonly HashSet<string> HopHeaders = new HashSet<string>(new [] { "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade" }, StringComparer.OrdinalIgnoreCase);
    static readonly List<TcpClient> OpenClients = new List<TcpClient>();
    static readonly CancellationTokenSource Stop = new CancellationTokenSource();
    static RelayConfig Config;
    static HttpClient Backend;
    static TcpListener Listener;
    static DateTimeOffset Expiry;
    static string GuiPath;
    static int Port, CreateCount, ActiveRequests;
    const int MaxCreates = 6;
    static long Requests, Rejected, InputBytes, VideoBytes;
    static string EndReason = "expired", Stage = "configuration";

    [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int kind, uint reserved);
    [StructLayout(LayoutKind.Sequential)] struct TcpRow { public uint State, LocalAddress, LocalPort, RemoteAddress, RemotePort, Pid; }
    static int HostPort(uint port) { return (ushort)IPAddress.NetworkToHostOrder((short)(port & 65535)); }
    static int OwnerPid(int clientPort, int serverPort) {
        int size = 0; uint first = GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 5, 0);
        if(first != 122 || size < 4 || size > 16 * 1024 * 1024) return -1;
        IntPtr table = Marshal.AllocHGlobal(size);
        try {
            if(GetExtendedTcpTable(table, ref size, false, 2, 5, 0) != 0) return -1;
            int rows = Marshal.ReadInt32(table), stride = Marshal.SizeOf(typeof(TcpRow));
            if(rows < 0 || 4L + rows * (long)stride > size) return -1;
            for(int i=0;i<rows;i++) {
                var row = (TcpRow)Marshal.PtrToStructure(IntPtr.Add(table, 4+i*stride), typeof(TcpRow));
                if(row.State == 5 && new IPAddress(row.LocalAddress).Equals(IPAddress.Loopback) && new IPAddress(row.RemoteAddress).Equals(IPAddress.Loopback)
                    && HostPort(row.LocalPort) == clientPort && HostPort(row.RemotePort) == serverPort) return checked((int)row.Pid);
            }
        } finally { Marshal.FreeHGlobal(table); }
        return -1;
    }
    static string Hash(byte[] bytes) { using(var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", ""); }
    static bool TrustedGui() {
        try { using(var p=Process.GetProcessById(Config.OfficialProcessId)) return !p.HasExited && p.StartTime.ToUniversalTime().Ticks == Config.OfficialStartTicks && String.Equals(p.MainModule.FileName,GuiPath,StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }
    static bool Unexpired() { return DateTimeOffset.UtcNow < Expiry && !Stop.IsCancellationRequested; }
    static void Log(object value) { lock(LogGate) File.AppendAllText(Path.Combine(Config.Folder,"requests.jsonl"),Json.Serialize(value)+Environment.NewLine,new UTF8Encoding(false)); }
    static void WriteJson(string name,object value) { File.WriteAllText(Path.Combine(Config.Folder,name),Json.Serialize(value),new UTF8Encoding(false)); }
    static void WriteStatus() {
        try {
            string[] ids; lock(StreamGate) ids=OwnedStreams.Select(id=>Hash(Encoding.UTF8.GetBytes(id)).Substring(0,12)).ToArray();
            WriteJson("status.json",new{at=DateTimeOffset.Now.ToString("o"),requests=Interlocked.Read(ref Requests),rejected=Interlocked.Read(ref Rejected),inputBytes=Interlocked.Read(ref InputBytes),videoBytes=Interlocked.Read(ref VideoBytes),activeRequests=Volatile.Read(ref ActiveRequests),creates=Volatile.Read(ref CreateCount),streams=ids,stage=Stage});
        } catch {}
    }
    static async Task<string> Line(Stream stream) { return await Line(stream, Stop.Token); }
    static async Task<string> Line(Stream stream, CancellationToken token) {
        var bytes = new List<byte>(); int previous=-1;
        while(bytes.Count <= 16384) {
            byte[] one=new byte[1]; int n=await stream.ReadAsync(one,0,1,token);
            if(n==0) { if(bytes.Count==0)return null; throw new IOException("Incomplete header"); }
            if(one[0]==10 && previous==13) { bytes.RemoveAt(bytes.Count-1); return Encoding.ASCII.GetString(bytes.ToArray()); }
            if(one[0]==0)throw new IOException("Invalid header"); bytes.Add(one[0]); previous=one[0];
        }
        throw new IOException("Header limit");
    }
    static async Task<byte[]> ReadExactly(Stream source,int length) {
        byte[] data=new byte[length];int position=0;
        while(position<length) { int n=await source.ReadAsync(data,position,length-position,Stop.Token);if(n==0)throw new IOException("Incomplete body");position+=n; }
        return data;
    }
    static async Task Error(Stream output,int code) {
        byte[] bytes=Encoding.ASCII.GetBytes("HTTP/1.1 "+code+" Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        await output.WriteAsync(bytes,0,bytes.Length);
    }
    static bool Allowed(string method,Uri uri,byte[] body,out bool isCreate,out bool video) {
        isCreate=false; video=false;
        string path=uri.AbsolutePath;
        var q=HttpUtility.ParseQueryString(uri.Query);
        if(path=="/api/os/info" || path=="/default.htm" || path=="/") return method=="GET" && q.Count==0;
        if(path==Control+"mode") {
            if(method=="GET")return q.Count==0;
            if(method!="POST" || body.Length>128)return false;
            if(q.AllKeys.Any(k=>k!="mode"))return false;
            string mode=q["mode"];
            if(mode=="0" || mode=="1")return body.Length==0;
            // Some SDK versions send the mode as a small JSON object.
            if(q.Count!=0)return false;
            try { var value=Json.Deserialize<Dictionary<string,int>>(Encoding.UTF8.GetString(body));return value.Count==1&&value.ContainsKey("mode")&&(value["mode"]==0||value["mode"]==1); } catch { return false; }
        }
        if(path==Control+"stream") {
            if(q.AllKeys.Any(k=>!String.Equals(k,"streamId",StringComparison.OrdinalIgnoreCase) && !String.Equals(k,"priority",StringComparison.OrdinalIgnoreCase)))return false;
            string id=q["streamId"];
            if(id==null) {
                isCreate=method=="POST" && body.Length==0 && (q["priority"]=="normal" || q["priority"]=="1" || q.Count==0);
                return isCreate;
            }
            Guid unused;if(!Guid.TryParse(id,out unused))return false;
            lock(StreamGate) if(!OwnedStreams.Contains(id))return false;
            return (method=="POST" && body.Length>0 && body.Length<=1048576) || (method=="DELETE" && body.Length==0);
        }
        if(path=="/api/holographic/stream/live.mp4" || path=="/api/holographic/stream/live_low.mp4" || path=="/api/holographic/stream/live_high.mp4") {
            video=method=="GET";
            return video && q.AllKeys.All(k=>new []{"holo","pv","mic","loopback","RenderFromCamera"}.Contains(k));
        }
        return false;
    }
    static bool AllowedWebSocket(string method,Uri uri) {
        if(method!="GET")return false;
        var q=HttpUtility.ParseQueryString(uri.Query);
        if(uri.AbsolutePath=="/api/holographic/simulation/display/stream")return q.Count==0 || (q.Count==1 && q.AllKeys[0]=="additionalView" && q["additionalView"]=="false");
        if(uri.AbsolutePath!=Control+"stream" || q.Count<1 || q.Count>2 || q.AllKeys.Any(k=>!String.Equals(k,"streamId",StringComparison.OrdinalIgnoreCase)&&!String.Equals(k,"deleteStreamOnDisconnect",StringComparison.OrdinalIgnoreCase)))return false;
        string delete=q["deleteStreamOnDisconnect"];
        if(delete!=null && delete!="1" && !delete.Equals("true",StringComparison.OrdinalIgnoreCase))return false;
        lock(StreamGate)return OwnedStreams.Contains(q["streamId"]);
    }
    static async Task Pump(Stream source,Stream destination,bool input,bool video) {
        byte[] buffer=new byte[65536];int n;
        while((n=await source.ReadAsync(buffer,0,buffer.Length,Stop.Token))>0) {
            await destination.WriteAsync(buffer,0,n,Stop.Token);
            if(input)Interlocked.Add(ref InputBytes,n);if(video)Interlocked.Add(ref VideoBytes,n);
        }
    }
    static async Task RelayWebSocket(Stream wire,Uri url,Dictionary<string,string> headers) {
        string key,version;
        if(!headers.TryGetValue("Sec-WebSocket-Key",out key)||!headers.TryGetValue("Sec-WebSocket-Version",out version)||version!="13"||Convert.FromBase64String(key).Length!=16)throw new IOException("Invalid WebSocket handshake");
        string clientOrigin;headers.TryGetValue("Origin",out clientOrigin);
        Log(new{at=DateTimeOffset.Now.ToString("o"),route=url.AbsolutePath,phase="ws_start",deleteOnDisconnect=HttpUtility.ParseQueryString(url.Query)["deleteStreamOnDisconnect"],clientOrigin=clientOrigin,originAdapted=true});
        using(var upstream=new TcpClient()) using(var handshake=new CancellationTokenSource(TimeSpan.FromSeconds(20))) using(handshake.Token.Register(()=>upstream.Close())) using(Stop.Token.Register(()=>upstream.Close())) {
            await upstream.ConnectAsync(Config.Address,443);
            Log(new{at=DateTimeOffset.Now.ToString("o"),route=url.AbsolutePath,phase="ws_tcp_connected"});
            using(var tls=new SslStream(upstream.GetStream(),false,(sender,certificate,chain,errors)=>certificate!=null&&Hash(certificate.GetRawCertData())==Config.CertificateSha256)) {
                await tls.AuthenticateAsClientAsync(Config.Address,null,SslProtocols.Tls12,false);
                Log(new{at=DateTimeOffset.Now.ToString("o"),route=url.AbsolutePath,phase="ws_tls_ready"});
                // The device portal stalls an unauthenticated-origin upgrade request; the unmodified
                // GUI believes it is talking to 127.0.0.1, so the relay presents the device origin.
                var head=new StringBuilder("GET "+url.PathAndQuery+" HTTP/1.1\r\nHost: "+Config.Address+"\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: https://"+Config.Address+"\r\nAuthorization: "+Config.Authorization+"\r\nCookie: "+Config.Cookie+"\r\nX-CSRF-Token: "+Config.CsrfToken+"\r\n");
                foreach(var entry in headers)if(entry.Key.StartsWith("Sec-WebSocket-",StringComparison.OrdinalIgnoreCase))head.Append(entry.Key).Append(": ").Append(entry.Value).Append("\r\n");
                head.Append("\r\n");byte[] request=Encoding.ASCII.GetBytes(head.ToString());await tls.WriteAsync(request,0,request.Length,handshake.Token);
                Log(new{at=DateTimeOffset.Now.ToString("o"),route=url.AbsolutePath,phase="ws_upgrade_sent"});
                string line=await Line(tls,handshake.Token);if(line==null)throw new IOException("Missing upgrade response");
                var response=new StringBuilder(line+"\r\n");bool switched=line.StartsWith("HTTP/1.1 101 ",StringComparison.Ordinal);int total=0;
                while(!String.IsNullOrEmpty(line=await Line(tls,handshake.Token))) {total+=line.Length;if(total>32768)throw new IOException("Upgrade header limit");if(!line.StartsWith("Set-Cookie:",StringComparison.OrdinalIgnoreCase))response.Append(line).Append("\r\n");}
                if(!switched) {
                    string[] first=line==null?new string[0]:response.ToString().Split(' ');int code;
                    Log(new{at=DateTimeOffset.Now.ToString("o"),route=url.AbsolutePath,websocket=true,backendStatus=first.Length>1&&Int32.TryParse(first[1],out code)?code:0,statusLine=response.ToString().Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()});
                    throw new IOException("Backend rejected WebSocket upgrade");
                }
                handshake.CancelAfter(Timeout.Infinite);
                response.Append("\r\n");byte[] reply=Encoding.ASCII.GetBytes(response.ToString());await wire.WriteAsync(reply,0,reply.Length,Stop.Token);
                Log(new{at=DateTimeOffset.Now.ToString("o"),route=url.AbsolutePath,method="GET",status=101,websocket=true,authorized=true});
                Task send=Pump(wire,tls,url.AbsolutePath==Control+"stream",false),receive=Pump(tls,wire,false,url.AbsolutePath=="/api/holographic/simulation/display/stream");
                await Task.WhenAny(send,receive);
                Log(new{at=DateTimeOffset.Now.ToString("o"),route=url.AbsolutePath,phase="ws_ended"});
            }
        }
    }
    static async Task Serve(TcpClient incoming) {
        Interlocked.Increment(ref ActiveRequests);lock(OpenClients)OpenClients.Add(incoming);
        string route="unparsed", method="unknown";int status=0; long transferred=0; bool authorized=false,video=false,isCreate=false;
        try {
            incoming.NoDelay=true;incoming.ReceiveTimeout=10000;incoming.SendTimeout=10000;
            var remote=(IPEndPoint)incoming.Client.RemoteEndPoint;
            if(!remote.Address.Equals(IPAddress.Loopback) || !TrustedGui() || OwnerPid(remote.Port,Port)!=Config.OfficialProcessId || !Unexpired()) {
                Interlocked.Increment(ref Rejected);status=403;await Error(incoming.GetStream(),403);return;
            }
            authorized=true;
            Stream wire=incoming.GetStream();string requestLine=await Line(wire);
            if(requestLine==null)return;
            string[] first=requestLine.Split(' ');
            if(first.Length!=3 || first[2]!="HTTP/1.1" || !first[1].StartsWith("/") || first[1].StartsWith("//")) { await Error(wire,400);return; }
            method=first[0];Uri url=new Uri("https://"+Config.Address+first[1]);route=url.AbsolutePath;
            if(url.Host!=Config.Address||url.Port!=443||url.Scheme!="https"||url.UserInfo!=""){status=403;await Error(wire,403);return;}
            var headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);int total=0;
            for(int i=0;i<80;i++) {
                string line=await Line(wire);if(line==null)throw new IOException("Missing headers");if(line.Length==0)break;
                total+=line.Length;if(total>32768)throw new IOException("Header size");int sep=line.IndexOf(':');
                if(sep<=0 || headers.ContainsKey(line.Substring(0,sep)))throw new IOException("Invalid headers");
                headers.Add(line.Substring(0,sep),line.Substring(sep+1).Trim());if(i==79)throw new IOException("Header count");
            }
            string host;if(!headers.TryGetValue("Host",out host) || (host!="127.0.0.1:"+Port && host!="localhost:"+Port)) {await Error(wire,403);return;}
            string upgrade;
            if(headers.TryGetValue("Upgrade",out upgrade)) {
                if(upgrade.Equals("websocket",StringComparison.OrdinalIgnoreCase)&&AllowedWebSocket(method,url)&&Unexpired()) {await RelayWebSocket(wire,url,headers);status=101;}
                else {
                    var q=HttpUtility.ParseQueryString(url.Query);bool own;lock(StreamGate)own=OwnedStreams.Contains(q["streamId"]??"");
                    Log(new{at=DateTimeOffset.Now.ToString("o"),route=route,rejection="websocket_format",queryKeys=q.AllKeys,ownStream=own});
                    status=403;Interlocked.Increment(ref Rejected);await Error(wire,403);
                }
                return;
            }
            if(headers.ContainsKey("Transfer-Encoding")) {await Error(wire,501);return;}
            int length=0;string lengthText;
            if(headers.TryGetValue("Content-Length",out lengthText) && (!Int32.TryParse(lengthText,out length)||length<0||length>1048576)){await Error(wire,413);return;}
            string expect;if(headers.TryGetValue("Expect",out expect) && expect.Equals("100-continue",StringComparison.OrdinalIgnoreCase)) {
                byte[] continued=Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");await wire.WriteAsync(continued,0,continued.Length,Stop.Token);
            }
            byte[] body=await ReadExactly(wire,length);
            if(!Allowed(method,url,body,out isCreate,out video) || !Unexpired()) {
                var query=HttpUtility.ParseQueryString(url.Query);
                var safeQuery=query.AllKeys.Select(k=>new{key=k,value=k=="priority"?query[k]:"redacted"}).ToArray();
                Log(new{at=DateTimeOffset.Now.ToString("o"),route=route,rejection="route_format",query=safeQuery,bodyLength=body.Length});
                Interlocked.Increment(ref Rejected);status=403;await Error(wire,403);return;
            }
            if(isCreate) {
                int createIndex=Interlocked.Increment(ref CreateCount);
                if(createIndex>MaxCreates){status=429;Interlocked.Increment(ref Rejected);await Error(wire,429);return;}
                Log(new{at=DateTimeOffset.Now.ToString("o"),route=route,phase="create",index=createIndex});
            }
            // No independent PV or audio sources are requested by this adapter.
            if(video)url=new Uri("https://"+Config.Address+url.AbsolutePath+"?holo=true&pv=false&mic=false&loopback=false&RenderFromCamera=false");
            using(var request=new HttpRequestMessage(new HttpMethod(method),url)) {
                request.Headers.TryAddWithoutValidation("Authorization",Config.Authorization);
                request.Headers.TryAddWithoutValidation("Cookie",Config.Cookie);
                request.Headers.TryAddWithoutValidation("X-CSRF-Token",Config.CsrfToken);
                request.Headers.ConnectionClose=true;
                if(body.Length>0 || method=="POST" || method=="DELETE")request.Content=new ByteArrayContent(body);
                foreach(var entry in headers) {
                    if(HopHeaders.Contains(entry.Key) || new []{"Host","Authorization","Cookie","X-CSRF-Token","Content-Length","Expect","Accept-Encoding"}.Contains(entry.Key,StringComparer.OrdinalIgnoreCase))continue;
                    if(entry.Key.Equals("Origin",StringComparison.OrdinalIgnoreCase) || entry.Key.Equals("Referer",StringComparison.OrdinalIgnoreCase))continue;
                    if(!request.Headers.TryAddWithoutValidation(entry.Key,entry.Value) && request.Content!=null)request.Content.Headers.TryAddWithoutValidation(entry.Key,entry.Value);
                }
                Interlocked.Increment(ref Requests);
                Log(new{at=DateTimeOffset.Now.ToString("o"),route=route,method=method,phase="start",video=video,create=isCreate,bodyLength=body.Length,queryKeys=HttpUtility.ParseQueryString(url.Query).AllKeys});
                using(var responseTimeout=new CancellationTokenSource(TimeSpan.FromSeconds(20)))
                using(var response=await Backend.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,responseTimeout.Token)) {
                    responseTimeout.CancelAfter(Timeout.Infinite);
                    status=(int)response.StatusCode;
                    if(status>=300 && status<400) {await Error(wire,502);return;}
                    byte[] captured=null;
                    if(isCreate && response.IsSuccessStatusCode) {
                        captured=await response.Content.ReadAsByteArrayAsync();if(captured.Length>65536)throw new IOException("Stream identity too large");
                        var data=Json.Deserialize<Dictionary<string,string>>(Encoding.UTF8.GetString(captured));string id;Guid parsed;
                        if(!data.TryGetValue("streamId",out id) || !Guid.TryParse(id,out parsed))throw new IOException("Missing stream identity");
                        lock(StreamGate)OwnedStreams.Add(id);
                        WriteJson("own-streams.json",OwnedStreams.ToArray());
                    }
                    if(method=="DELETE" && response.IsSuccessStatusCode) { lock(StreamGate)OwnedStreams.Remove(HttpUtility.ParseQueryString(url.Query)["streamId"]); }
                    var head=new StringBuilder("HTTP/1.1 "+status+" "+response.ReasonPhrase+"\r\n");
                    foreach(var h in response.Headers.Concat(response.Content.Headers)) {
                        if(HopHeaders.Contains(h.Key)||h.Key.Equals("Set-Cookie",StringComparison.OrdinalIgnoreCase)||h.Key.Equals("WWW-Authenticate",StringComparison.OrdinalIgnoreCase))continue;
                        head.Append(h.Key).Append(": ").Append(String.Join(", ",h.Value)).Append("\r\n");
                    }
                    head.Append("Connection: close\r\n\r\n");byte[] bytes=Encoding.ASCII.GetBytes(head.ToString());await wire.WriteAsync(bytes,0,bytes.Length,Stop.Token);
                    if(captured!=null) {await wire.WriteAsync(captured,0,captured.Length,Stop.Token);transferred=captured.Length;}
                    else using(var source=await response.Content.ReadAsStreamAsync()) {
                        byte[] buffer=new byte[65536];int n;
                        while((n=await source.ReadAsync(buffer,0,buffer.Length,Stop.Token))>0) {await wire.WriteAsync(buffer,0,n,Stop.Token);transferred+=n;if(video)Interlocked.Add(ref VideoBytes,n);}
                    }
                    if(method=="POST" && url.AbsolutePath==Control+"stream" && !isCreate)Interlocked.Add(ref InputBytes,body.Length);
                }
            }
        } catch(Exception ex) { Log(new{at=DateTimeOffset.Now.ToString("o"),route=route,method=method,error=ex.GetType().Name,authorized=authorized}); }
        finally {
            Log(new{at=DateTimeOffset.Now.ToString("o"),route=route,method=method,status=status,bytes=transferred,authorized=authorized,video=video,create=isCreate});
            incoming.Close();lock(OpenClients)OpenClients.Remove(incoming);Interlocked.Decrement(ref ActiveRequests);
        }
    }
    static void CloseAll() {
        Stop.Cancel();try{Listener.Stop();}catch{}
        lock(OpenClients)foreach(var connection in OpenClients.ToArray())try{connection.Close();}catch{}
    }
    static void CloseOwnStreams() {
        string[] ids;lock(StreamGate)ids=OwnedStreams.ToArray();
        foreach(string id in ids) {
            try {
                using(var request=new HttpRequestMessage(HttpMethod.Delete,"https://"+Config.Address+Control+"stream?streamId="+Uri.EscapeDataString(id)))
                using(var timeout=new CancellationTokenSource(4000)) {
                    request.Headers.TryAddWithoutValidation("Authorization",Config.Authorization);request.Headers.TryAddWithoutValidation("Cookie",Config.Cookie);request.Headers.TryAddWithoutValidation("X-CSRF-Token",Config.CsrfToken);
                    using(var response=Backend.SendAsync(request,timeout.Token).GetAwaiter().GetResult()) {
                        Log(new{at=DateTimeOffset.Now.ToString("o"),route=Control+"stream",method="DELETE",cleanup=true,status=(int)response.StatusCode});
                        if(response.IsSuccessStatusCode)lock(StreamGate)OwnedStreams.Remove(id);
                    }
                }
            }catch(Exception ex){Log(new{at=DateTimeOffset.Now.ToString("o"),cleanup=true,error=ex.GetType().Name});}
        }
    }
    static int SelfTest() {
        var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();int port=((IPEndPoint)listener.LocalEndpoint).Port;
        using(var client=new TcpClient()) {
            client.Connect(IPAddress.Loopback,port);using(var server=listener.AcceptTcpClient()) {
                int owner=OwnerPid(((IPEndPoint)server.Client.RemoteEndPoint).Port,port);
                bool ownPid=owner==Process.GetCurrentProcess().Id;
                bool wrongPort=OwnerPid(((IPEndPoint)server.Client.RemoteEndPoint).Port,port==65535?65534:port+1)==-1;
                string id="ABCDEF12-3456-4789-ABCD-123456789ABC";OwnedStreams.Add(id);bool create,video;
                bool foreignStream=!Allowed("POST",new Uri("https://169.254.1.2"+Control+"stream?streamId=11111111-2222-4333-8444-555555555555"),new byte[]{1},out create,out video);
                bool opaqueCase=!Allowed("POST",new Uri("https://169.254.1.2"+Control+"stream?streamId="+id.ToLowerInvariant()),new byte[]{1},out create,out video);
                bool ownSocket=AllowedWebSocket("GET",new Uri("https://169.254.1.2"+Control+"stream?streamId="+id+"&deleteStreamOnDisconnect=true"));
                bool administrativeRoute=!Allowed("POST",new Uri("https://169.254.1.2/api/control/restart"),new byte[0],out create,out video);
                Expiry=DateTimeOffset.UtcNow.AddSeconds(-1);bool expired=!Unexpired();OwnedStreams.Clear();
                listener.Stop();
                bool ok=ownPid&&wrongPort&&foreignStream&&opaqueCase&&ownSocket&&administrativeRoute&&expired;
                Console.WriteLine(Json.Serialize(new{test="relay_access_boundaries",passed=ok,ownPidMatched=ownPid,wrongPortRejected=wrongPort,foreignStreamRejected=foreignStream,opaqueIdCasePreserved=opaqueCase,ownSocketAccepted=ownSocket,administrativeRouteRejected=administrativeRoute,expiredSessionRejected=expired,deviceContacted=false}));return ok?0:2;
            }
        }
    }
    static int Main(string[] args) {
        if(args.Length==1 && args[0]=="--self-test")return SelfTest();
        try {
            Console.InputEncoding=new UTF8Encoding(false);
            string input=Console.ReadLine();if(input==null||input.Length>32768)throw new ArgumentException("Missing private configuration");
            Config=Json.Deserialize<RelayConfig>(input);input=null;Expiry=DateTimeOffset.Parse(Config.ExpiresAt);
            IPAddress address;GuiPath=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"Microsoft Perception Simulation","Control","PerceptionSimulationControl.exe");
            Stage="device_address";
            if(!IPAddress.TryParse(Config.Address,out address)||!Config.Address.StartsWith("169.254.",StringComparison.Ordinal)||Config.CertificateSha256.Length!=64)throw new ArgumentException("Untrusted device");
            Stage="expiry";
            if(Expiry<=DateTimeOffset.UtcNow||Expiry>DateTimeOffset.UtcNow.AddSeconds(290))throw new ArgumentException("Untrusted expiry");
            Stage="official_identity";
            if(!TrustedGui())throw new ArgumentException("Untrusted official identity");
            Stage="official_hash";
            if(Hash(File.ReadAllBytes(GuiPath))!=ExpectedGuiHash)throw new ArgumentException("Unexpected official program");
            Stage="authentication_headers";
            foreach(string secret in new[]{Config.Authorization,Config.Cookie,Config.CsrfToken})if(String.IsNullOrEmpty(secret)||secret.IndexOfAny(new[]{'\r','\n'})>=0)throw new ArgumentException("Invalid private authentication");
            if(!Config.Authorization.StartsWith("Basic ",StringComparison.Ordinal))throw new ArgumentException("Unexpected auth scheme");
            Stage="listener";ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
            ServicePointManager.ServerCertificateValidationCallback=(sender,certificate,chain,errors)=>certificate!=null&&Hash(certificate.GetRawCertData())==Config.CertificateSha256;
            Backend=new HttpClient(new HttpClientHandler{UseProxy=false,UseCookies=false,AllowAutoRedirect=false,AutomaticDecompression=DecompressionMethods.None});Backend.Timeout=Timeout.InfiniteTimeSpan;
            Listener=new TcpListener(IPAddress.Loopback,Config.Port);Listener.Start(16);Port=((IPEndPoint)Listener.LocalEndpoint).Port;
            new Thread(()=>{
                while(Unexpired()) { if(File.Exists(Path.Combine(Config.Folder,"stop"))) {EndReason="requested";break;}if(!TrustedGui()){EndReason="official_process_ended";break;}Thread.Sleep(100); }
                CloseAll();
            }){IsBackground=true}.Start();
            new Thread(()=>{while(Unexpired()){WriteStatus();Thread.Sleep(1000);}WriteStatus();}){IsBackground=true}.Start();
            Console.WriteLine(Json.Serialize(new{state="ready",port=Port,processId=Process.GetCurrentProcess().Id,officialProcessId=Config.OfficialProcessId,expiresAt=Expiry.ToString("o"),loopbackOnly=true,processRestricted=true,backendCertificatePinned=true}));Console.Out.Flush();
            while(Unexpired()) {TcpClient connection;try{connection=Listener.AcceptTcpClient();}catch(SocketException){break;}Task.Run(()=>Serve(connection));}
            CloseAll();for(int i=0;i<30&&Volatile.Read(ref ActiveRequests)>0;i++)Thread.Sleep(100);
            CloseOwnStreams();
            string[] ids;lock(StreamGate)ids=OwnedStreams.Select(id=>Hash(Encoding.UTF8.GetBytes(id))).ToArray();
            WriteJson("ended.json",new{at=DateTimeOffset.Now.ToString("o"),reason=EndReason,requests=Requests,rejected=Rejected,inputBytes=InputBytes,videoBytes=VideoBytes,unclosedOwnStreamHashes=ids,deviceModeRecovery="verify_same_named_lease"});
            return 0;
        } catch(Exception ex) {Console.WriteLine(Json.Serialize(new{state="failed",error=ex.GetType().Name,stage=Stage}));return 2;}
        finally {if(Listener!=null)CloseAll();if(Backend!=null)Backend.Dispose();}
    }
}
