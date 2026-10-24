// Console controller for the official SDK. Config is received over stdin;
// no credentials are accepted on the command line or printed in responses.
using System;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using Microsoft.PerceptionSimulation;

[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class CountingSink : ISimulationStreamSink {
    public long Packets,Bytes;
    public void OnPacketReceived(uint length,byte[] packet){Interlocked.Increment(ref Packets);Interlocked.Add(ref Bytes,length);}
}
public sealed class ConnectionConfig {
    public string Address {get;set;}
    public string UserName {get;set;}
    public string Password {get;set;}
    public string CertificateSha256 {get;set;}
    public string CsrfToken {get;set;}
    public string CookieHeader {get;set;}
}
// The legacy REST DLL does not provide the current portal's CSRF cookie/header.
// Keep Microsoft's packet encoder and use the documented authenticated POST API.
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class PortalPacketSink : ISimulationStreamSink {
    public static string Stage="not_started";
    public static int LastStatus;
    readonly HttpClient client;
    readonly Uri root;
    readonly object gate=new object();
    string streamId;
    public bool IsValid {get;private set;}
    public long Packets,Bytes;
    public int LastHttpStatus;
    PortalPacketSink(ConnectionConfig cfg){
        Stage="portal_page";
        root=new Uri("https://"+cfg.Address);
        var handler=new HttpClientHandler {UseProxy=false,AllowAutoRedirect=false,UseCookies=false};
        client=new HttpClient(handler);client.Timeout=TimeSpan.FromSeconds(8);
        client.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Basic",Convert.ToBase64String(Encoding.UTF8.GetBytes(cfg.UserName+":"+cfg.Password)));
        using(var page=client.GetAsync(new Uri(root,"/api/os/info")).GetAwaiter().GetResult()){
            LastStatus=LastHttpStatus=(int)page.StatusCode;page.EnsureSuccessStatusCode();
        }
        Stage="portal_csrf";
        // Reuse the cookie already parsed by the pinned PowerShell 7 client,
        // keeping the Cookie and X-CSRF-Token values in the same portal session.
        if(String.IsNullOrEmpty(cfg.CsrfToken)||String.IsNullOrEmpty(cfg.CookieHeader)||cfg.CookieHeader.IndexOfAny(new char[]{'\r','\n'})>=0)throw new InvalidOperationException("Portal CSRF cookie missing");
        client.DefaultRequestHeaders.Add("X-CSRF-Token",cfg.CsrfToken);
        client.DefaultRequestHeaders.TryAddWithoutValidation("Cookie",cfg.CookieHeader);
    }
    public static async Task<PortalPacketSink> Create(ConnectionConfig cfg){
        var sink=new PortalPacketSink(cfg);
        try {
            Stage="create_stream";
            using(var body=new ByteArrayContent(new byte[0]))
            using(var response=await sink.client.PostAsync(new Uri(sink.root,"/api/holographic/simulation/control/stream?priority=normal"),body)){
                LastStatus=sink.LastHttpStatus=(int)response.StatusCode;response.EnsureSuccessStatusCode();
                Stage="read_stream_identity";
                var payload=new JavaScriptSerializer().Deserialize<Dictionary<string,string>>(await response.Content.ReadAsStringAsync());
                Guid id;if(!payload.ContainsKey("streamId")||!Guid.TryParse(payload["streamId"],out id))throw new InvalidOperationException("Invalid stream identity");
                // The portal returns an opaque identifier; preserve its case.
                sink.streamId=payload["streamId"];sink.IsValid=true;
            }
            return sink;
        }catch{sink.client.Dispose();throw;}
    }
    Uri StreamUri(){return new Uri(root,"/api/holographic/simulation/control/stream?streamId="+Uri.EscapeDataString(streamId));}
    public void OnPacketReceived(uint length,byte[] packet){
        lock(gate){
            if(!IsValid)return;
            try {
                using(var body=new ByteArrayContent(packet,0,checked((int)length))){
                    body.Headers.ContentType=new MediaTypeHeaderValue("application/octet-stream");
                    using(var response=client.PostAsync(StreamUri(),body).GetAwaiter().GetResult()){
                        LastStatus=LastHttpStatus=(int)response.StatusCode;response.EnsureSuccessStatusCode();
                    }
                }
                Packets++;Bytes+=length;
            }catch{IsValid=false;throw;}
        }
    }
    public async Task Close(CancellationToken token){
        IsValid=false;
        try {
            if(streamId!=null)using(var request=new HttpRequestMessage(HttpMethod.Delete,StreamUri()))
            using(var response=await client.SendAsync(request,token)){
                LastStatus=LastHttpStatus=(int)response.StatusCode;response.EnsureSuccessStatusCode();streamId=null;
            }
        }finally{client.Dispose();}
    }
}
public static class PerceptionControl {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static void Reply(object value){Console.WriteLine(Json.Serialize(value));}
    static float Number(string value,float maximum){float n=float.Parse(value,CultureInfo.InvariantCulture);if(float.IsNaN(n)||float.IsInfinity(n)||Math.Abs(n)>maximum)throw new ArgumentOutOfRangeException("value");return n;}
    static string Hash(byte[] value){using(var sha=SHA256.Create()){return BitConverter.ToString(sha.ComputeHash(value)).Replace("-","");}}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool SetDllDirectory(string directory);
    public static int Main(string[] args){
        string own=AppDomain.CurrentDomain.BaseDirectory;
        if(!SetDllDirectory(own)){Reply(new {ok=false,error="native_library_path_unavailable"});return 2;}
        try {
            if(args.Length==1&&args[0]=="--self-test")return SelfTest();
            Run().GetAwaiter().GetResult();return 0;
        } catch(Exception e){Reply(new {ok=false,error=e.GetType().Name,hresult="0x"+e.HResult.ToString("X8"),stage=PortalPacketSink.Stage,httpStatus=PortalPacketSink.LastStatus,inputVerified=false});return 2;}
    }
    static int SelfTest(){
        var sink=new CountingSink();
        IPerceptionSimulationManager manager=PerceptionSimulationManager.CreatePerceptionSimulationManager(sink);
        manager.Human.Head.Rotate(new Rotation3{Pitch=0.05f,Yaw=0.1f,Roll=0});
        manager.Human.RightHand.Activated=true;
        manager.Human.RightHand.PerformGesture(SimulatedGesture.FingerPressed);
        manager.Human.RightHand.PerformGesture(SimulatedGesture.FingerReleased);
        Thread.Sleep(250);
        bool ok=sink.Packets>0&&sink.Bytes>0;
        Reply(new {ok=ok,test="offline_sdk_packet_generation",processBits=IntPtr.Size*8,packets=sink.Packets,bytes=sink.Bytes,deviceContacted=false,inputVerified=false});
        if(Marshal.IsComObject(manager))Marshal.FinalReleaseComObject(manager);
        GC.KeepAlive(sink);return ok?0:2;
    }
    static async Task Run(){
        string line=Console.ReadLine();
        if(line==null||line.Length>16384)throw new ArgumentException("Missing stdin configuration");
        ConnectionConfig cfg=Json.Deserialize<ConnectionConfig>(line);
        IPAddress parsed;
        if(cfg==null||!IPAddress.TryParse(cfg.Address,out parsed)||!cfg.Address.StartsWith("169.254.")||String.IsNullOrEmpty(cfg.UserName)||String.IsNullOrEmpty(cfg.Password)||cfg.CertificateSha256==null||cfg.CertificateSha256.Length!=64)throw new ArgumentException("Invalid pinned USB configuration");
        ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
        // USB is point-to-point. The SDK's legacy REST client otherwise inherits
        // the desktop proxy, unlike our pinned HttpClient diagnostics.
        WebRequest.DefaultWebProxy=null;
        ServicePointManager.ServerCertificateValidationCallback=(sender,certificate,chain,errors)=>certificate!=null&&Hash(certificate.GetRawCertData())==cfg.CertificateSha256;
        PortalPacketSink sink=null;IPerceptionSimulationManager manager=null;
        try {
            sink=await PortalPacketSink.Create(cfg);
            cfg.Password=null;
            PortalPacketSink.Stage="sdk_manager";
            manager=PerceptionSimulationManager.CreatePerceptionSimulationManager(sink);
            PortalPacketSink.Stage="connected";
            Reply(new {ok=true,state="connected",processBits=IntPtr.Size*8,certificatePinned=true,csrfProtected=true,packets=sink.Packets,httpStatus=sink.LastHttpStatus,inputVerified=false});
            while((line=Console.ReadLine())!=null){
                string[] words=line.Trim().Split(new char[]{' '},StringSplitOptions.RemoveEmptyEntries);
                if(words.Length==0)continue;
                if(words[0]=="exit")break;
                try {
                    if(words.Length==1&&words[0]=="status"){
                        Reply(new {ok=sink.IsValid,state=sink.IsValid?"connected":"disconnected",packets=sink.Packets,bytes=sink.Bytes,httpStatus=sink.LastHttpStatus,inputVerified=false});continue;
                    }
                    if(words.Length==1&&words[0]=="pose"){
                        Reply(new {ok=sink.IsValid,body=manager.Human.WorldPosition,head=manager.Human.Head.WorldPosition,headRotation=manager.Human.Head.Rotation,hand=manager.Human.RightHand.WorldPosition,handPosition=manager.Human.RightHand.Position,handRotation=((ISimulatedHand2)manager.Human.RightHand).Orientation,inputVerified=false});continue;
                    }
                    if(!sink.IsValid)throw new InvalidOperationException("Connection lost");
                    if(words.Length==1&&words[0]=="home"){
                        manager.Human.RightHand.Activated=true;manager.Human.RightHand.PerformGesture(SimulatedGesture.Home);
                    } else if(words.Length==1&&words[0]=="tap"){
                        manager.Human.RightHand.Activated=true;
                        manager.Human.RightHand.PerformGesture(SimulatedGesture.FingerPressed);
                        await Task.Delay(100);
                        manager.Human.RightHand.PerformGesture(SimulatedGesture.FingerReleased);
                    } else if(words.Length==4&&words[0]=="look"){
                        manager.Human.Head.Rotate(new Rotation3{Pitch=Number(words[1],1.0f),Yaw=Number(words[2],1.5f),Roll=Number(words[3],0.5f)});
                    } else if(words.Length==4&&words[0]=="look-absolute"){
                        manager.Human.Head.Rotation=new Rotation3{Pitch=Number(words[1],1.0f),Yaw=Number(words[2],1.5f),Roll=Number(words[3],0.5f)};
                    } else if(words.Length==1&&words[0]=="track-position"){
                        manager.Device.HeadTracker.HeadTrackerMode=HeadTrackerMode.Position;
                    } else if(words.Length==2&&words[0]=="presence"&&(words[1]=="on"||words[1]=="off")){
                        ((ISimulatedDevice2)manager.Device).IsUserPresent=words[1]=="on";
                    } else if(words.Length==2&&words[0]=="hand"&&(words[1]=="on"||words[1]=="off")){
                        manager.Human.RightHand.Activated=words[1]=="on";
                    } else if(words.Length==4&&words[0]=="hand-position"){
                        manager.Human.RightHand.Position=new Vector3{X=Number(words[1],1),Y=Number(words[2],2),Z=Number(words[3],1)};
                    } else if(words.Length==4&&words[0]=="hand-look"){
                        ((ISimulatedHand2)manager.Human.RightHand).Orientation=new Rotation3{Pitch=Number(words[1],1),Yaw=Number(words[2],1.5f),Roll=Number(words[3],0.5f)};
                    } else if(words.Length==4&&words[0]=="move"){
                        manager.Human.Move(new Vector3{X=Number(words[1],1),Y=Number(words[2],1),Z=Number(words[3],1)});
                    } else throw new ArgumentException("Unsupported explicit controller command");
                    Reply(new {ok=sink.IsValid,command=words[0],apiAccepted=sink.IsValid,packets=sink.Packets,httpStatus=sink.LastHttpStatus,inputVerified=false});
                }catch(Exception e){Reply(new {ok=false,command=words[0],error=e.GetType().Name,hresult="0x"+e.HResult.ToString("X8"),inputVerified=false});}
            }
        } finally {
            cfg.Password=null;
            if(sink!=null){using(var timeout=new CancellationTokenSource(5000)){try{sink.Close(timeout.Token).GetAwaiter().GetResult();Reply(new {ok=true,state="closed",httpStatus=sink.LastHttpStatus});}catch{Reply(new {ok=false,error="stream_close_failed",httpStatus=sink.LastHttpStatus});}}}
            if(manager!=null&&Marshal.IsComObject(manager))Marshal.FinalReleaseComObject(manager);
        }
    }
}
