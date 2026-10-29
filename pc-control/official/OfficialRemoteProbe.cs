using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.PerceptionSimulation;

public sealed class OfficialRemoteConfiguration {
    public string Address {get;set;}
    public string UserName {get;set;}
    public string Password {get;set;}
    public string ExpiresAt {get;set;}
    public string ClientKind {get;set;}
    public string CertificateSha256 {get;set;}
    public bool Direct {get;set;}
}
[ComVisible(true),ClassInterface(ClassInterfaceType.None)]
public sealed class OfficialRemoteCallback : ISimulationRestClientCallback {
    public int Disconnects;
    public void Invoke(SimulationRestClientCallbackReason reason) {
        if(reason==SimulationRestClientCallbackReason.Disconnected) Interlocked.Increment(ref Disconnects);
    }
}
public static class OfficialRemoteProbe {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool SetDllDirectory(string directory);
    [DllImport("combase.dll")] static extern int RoInitialize(uint initType);
    [DllImport("combase.dll")] static extern void RoUninitialize();
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static string stage="configuration";
    static void Release(object value){if(value!=null&&Marshal.IsComObject(value))Marshal.FinalReleaseComObject(value);}
    static void Event(string name){Console.WriteLine(Json.Serialize(new {at=DateTimeOffset.Now.ToString("o"),stage=name}));Console.Out.Flush();}
    public static int Main(){
        Console.InputEncoding=new UTF8Encoding(false);Console.OutputEncoding=new UTF8Encoding(false);
        var result=new Dictionary<string,object>();
        result["tool"]="Microsoft 3.0.24.0 native REST client";
        result["guiTest"]=false;result["visualInputVerified"]=false;result["gestureSent"]=false;
        result["processBits"]=IntPtr.Size*8;
        ISimulationRestClient client=null;ISimulationStreamSink sink=null;
        RestSimulationStreamSink legacy=null;
        IPerceptionSimulationManager manager=null;ISimulatedHuman human=null;ISimulatedHead head=null;
        var callback=new OfficialRemoteCallback();bool ok=false,connected=false,winrtInitialized=false;
        try {
            string line=Console.ReadLine();if(line==null||line.Length>16384)throw new InvalidOperationException();
            var cfg=Json.Deserialize<OfficialRemoteConfiguration>(line);line=null;
            Uri uri;DateTimeOffset expiry;
            if(cfg==null||!Uri.TryCreate(cfg.Address,UriKind.Absolute,out uri)||
               (uri.Scheme!="https"&&uri.Scheme!="http")||!uri.Host.StartsWith("169.254.")||
               !String.IsNullOrEmpty(uri.UserInfo)||String.IsNullOrEmpty(cfg.UserName)||String.IsNullOrEmpty(cfg.Password)||
               !DateTimeOffset.TryParse(cfg.ExpiresAt,out expiry)||expiry<=DateTimeOffset.UtcNow||expiry>DateTimeOffset.UtcNow.AddSeconds(300))throw new InvalidOperationException();
            if(IntPtr.Size!=8||!SetDllDirectory(AppDomain.CurrentDomain.BaseDirectory))throw new InvalidOperationException();
            Marshal.ThrowExceptionForHR(RoInitialize(1));winrtInitialized=true;
            result["address"]=cfg.Address;
            result["clientKind"]=cfg.ClientKind;
            if(cfg.ClientKind=="Legacy"){
                if(cfg.CertificateSha256==null||cfg.CertificateSha256.Length!=64)throw new InvalidOperationException();
                string pin=cfg.CertificateSha256;
                if(cfg.Direct)WebRequest.DefaultWebProxy=null;
                result["proxyMode"]=cfg.Direct?"direct_in_this_probe_process":"system_default";
                ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
                ServicePointManager.ServerCertificateValidationCallback=(sender,cert,chain,errors)=>{
                    if(cert==null)return false;
                    using(var hash=SHA256.Create())return BitConverter.ToString(hash.ComputeHash(cert.GetRawCertData())).Replace("-","")==pin;
                };
                stage="official_legacy_connect";Event(stage);
                using(var cancel=new CancellationTokenSource(20000)){
                    legacy=RestSimulationStreamSink.Create(uri,new NetworkCredential(cfg.UserName,cfg.Password),true,cancel.Token,StreamDataTypes.All).GetAwaiter().GetResult();
                }
                sink=legacy;connected=legacy.IsValid;result["certificatePinned"]=true;
                if(!connected)throw legacy.Exception??new InvalidOperationException();
            }else{
                stage="official_client_create";Event(stage);
                var forms=new string[]{cfg.Address,uri.Host,cfg.Address+"/",uri.Host+":"+uri.Port};
                var attempts=new List<object>();Exception last=null;
                foreach(string address in forms){
                    try {
                        client=PerceptionSimulationManager.CreatePerceptionSimulationRestClient(address,cfg.UserName,cfg.Password,StreamDataTypes.All,null);
                        attempts.Add(new {address=address,created=true,hresult="0x00000000"});
                        result["nativeAddress"]=address;break;
                    } catch(Exception e){last=e;attempts.Add(new {address=address,created=false,hresult="0x"+e.HResult.ToString("X8")});}
                }
                result["constructorAttempts"]=attempts;
                if(client==null)throw last??new InvalidOperationException();
                stage="official_connect";Event(stage);client.Connect();connected=true;
            }
            cfg.Password=null;cfg.UserName=null;
            result["connectCompleted"]=true;Event("official_connected");
            if(DateTimeOffset.UtcNow>=expiry)throw new TimeoutException();
            stage="official_stream_create";Event(stage);
            if(sink==null)sink=((ISimulationStreamSinkFactory)client).CreateSimulationStreamSink();
            result["streamCreated"]=sink!=null;
            manager=PerceptionSimulationManager.CreatePerceptionSimulationManager(sink);
            human=manager.Human;head=human.Head;
            result["managerCreated"]=manager!=null;
            result["headRotation"]=head.Rotation;
            Thread.Sleep(1000);
            result["disconnectsBeforeCleanup"]=callback.Disconnects;
            ok=connected&&sink!=null&&manager!=null&&callback.Disconnects==0;
        } catch(Exception error){
            result["failedStage"]=stage;result["errorType"]=error.GetType().Name;
            result["hresult"]="0x"+error.HResult.ToString("X8");
            result["errorSite"]=error.TargetSite==null?null:error.TargetSite.Name;
            result["errorStack"]=error.StackTrace;
            Exception root=error;while(root.InnerException!=null)root=root.InnerException;
            result["rootErrorType"]=root.GetType().Name;result["rootHresult"]="0x"+root.HResult.ToString("X8");
            var web=root as WebException;if(web!=null){result["webStatus"]=web.Status.ToString();var response=web.Response as HttpWebResponse;if(response!=null)result["httpStatus"]=(int)response.StatusCode;}
            var perception=root as PerceptionRequestException;
            if(perception!=null){result["httpStatus"]=(int)perception.StatusCode;result["serverHresult"]="0x"+perception.ServerHResult.ToString("X8");}
        } finally {
            Release(head);Release(human);Release(manager);Release(sink);
            if(legacy!=null){try{using(var cancel=new CancellationTokenSource(5000))legacy.Close(cancel.Token).GetAwaiter().GetResult();result["disconnectCompleted"]=true;}catch(Exception e){result["disconnectHresult"]="0x"+e.HResult.ToString("X8");ok=false;}}
            if(client!=null){
                try{client.Disconnect();result["disconnectCompleted"]=true;}
                catch(Exception e){result["disconnectHresult"]="0x"+e.HResult.ToString("X8");ok=false;}
                Release(client);
            }
            GC.KeepAlive(callback);
            if(winrtInitialized)RoUninitialize();
        }
        result["ok"]=ok;result["at"]=DateTimeOffset.Now.ToString("o");
        Console.WriteLine(Json.Serialize(result));return ok?0:2;
    }
}
