using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.PerceptionSimulation;

[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class OfficialCountingSink : ISimulationStreamSink {
    public long Packets, Bytes;
    public void OnPacketReceived(uint length, byte[] packet) {
        Interlocked.Increment(ref Packets);
        Interlocked.Add(ref Bytes, length);
    }
}

[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class OfficialCountingFactory : ISimulationStreamSinkFactory {
    public readonly OfficialCountingSink Sink=new OfficialCountingSink();
    public ISimulationStreamSink CreateSimulationStreamSink() { return Sink; }
}

public static class OfficialSdkProbe {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetDllDirectory(string directory);
    [DllImport("ole32.dll")]
    static extern int CoInitializeEx(IntPtr reserved, uint coInit);
    [DllImport("ole32.dll")]
    static extern void CoUninitialize();
    [DllImport("ole32.dll", PreserveSig=true)]
    static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint context, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static void Release(object value) { if (value != null && Marshal.IsComObject(value)) Marshal.FinalReleaseComObject(value); }
    static object Failure(Exception error) { return new { error=error.GetType().Name, hresult="0x"+error.HResult.ToString("X8"), message=error.Message }; }
    public static int Main(string[] args) {
        Console.OutputEncoding=new System.Text.UTF8Encoding(false);
        bool service=Array.IndexOf(args,"--service")>=0;
        bool localDevice=Array.IndexOf(args,"--exercise-local")>=0;
        bool recording=Array.IndexOf(args,"--recording")>=0;
        var result=new Dictionary<string,object>();
        result["at"]=DateTimeOffset.Now.ToString("o");
        result["processBits"]=IntPtr.Size*8;
        result["isAdministrator"]=new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent()).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        result["physicalHeadsetContacted"]=false;
        result["physicalHeadsetInputVerified"]=false;
        result["localDeviceRequested"]=localDevice;
        bool ok=true;
        try {
            if (IntPtr.Size!=8 || !SetDllDirectory(AppDomain.CurrentDomain.BaseDirectory)) throw new InvalidOperationException("A matching x64 SDK runtime is required.");
            var platforms=PerceptionSimulationManager.GetAvailablePlatforms();
            result["platforms"]=platforms;
            var sink=new OfficialCountingSink();
            IPerceptionSimulationManager manager=null;
            try {
                manager=PerceptionSimulationManager.CreatePerceptionSimulationManager(sink);
                manager.Device.HandTracker.FrustumIgnored=true;
                manager.Human.Head.Rotate(new Rotation3 { Pitch=.05f, Yaw=.08f, Roll=0 });
                ((ISimulatedHead2)manager.Human.Head).Eyes.Rotate(new Rotation3 { Pitch=.02f, Yaw=.03f, Roll=0 });
                manager.Human.LeftHand.Activated=true;
                manager.Human.RightHand.Activated=true;
                manager.Human.LeftHand.PerformGesture(SimulatedGesture.FingerPressed);
                manager.Human.RightHand.PerformGesture(SimulatedGesture.FingerPressed);
                Thread.Sleep(100);
                manager.Human.LeftHand.PerformGesture(SimulatedGesture.FingerReleased);
                manager.Human.RightHand.PerformGesture(SimulatedGesture.FingerReleased);
                Thread.Sleep(200);
                bool packetOk=sink.Packets>0 && sink.Bytes>0 && manager.Human.LeftHand.Visible && manager.Human.RightHand.Visible;
                result["packetGeneration"]=new { ok=packetOk, packets=sink.Packets, bytes=sink.Bytes, leftHandVisible=manager.Human.LeftHand.Visible, rightHandVisible=manager.Human.RightHand.Visible };
                ok &= packetOk;
            } finally { Release(manager); GC.KeepAlive(sink); }
            if(recording) {
                string path=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"official-recording-"+DateTime.UtcNow.Ticks+".xef");
                ISimulationStreamSink recordSink=null;
                IPerceptionSimulationManager recordManager=null;
                ISimulatedDevice recordDevice=null;
                ISimulatedHandTracker recordTracker=null;
                ISimulatedHuman recordHuman=null;
                ISimulatedHead recordHead=null;
                ISimulatedHand recordHand=null;
                try {
                    recordSink=PerceptionSimulationManager.CreatePerceptionSimulationRecording(path);
                    recordManager=PerceptionSimulationManager.CreatePerceptionSimulationManager(recordSink);
                    recordDevice=recordManager.Device;
                    recordTracker=recordDevice.HandTracker;
                    recordTracker.FrustumIgnored=true;
                    recordHuman=recordManager.Human;
                    recordHead=recordHuman.Head;
                    recordHead.Rotate(new Rotation3 {Pitch=.04f,Yaw=.06f,Roll=0});
                    recordHand=recordHuman.RightHand;
                    recordHand.Activated=true;
                    recordHand.PerformGesture(SimulatedGesture.FingerPressed);
                    Thread.Sleep(100);
                    recordHand.PerformGesture(SimulatedGesture.FingerReleased);
                    Thread.Sleep(150);
                } finally {
                    Release(recordHand); Release(recordHead); Release(recordHuman);
                    Release(recordTracker); Release(recordDevice); Release(recordManager); Release(recordSink);
                }
                GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
                var factory=new OfficialCountingFactory();
                ISimulationRecording playback=null;
                try {
                    playback=PerceptionSimulationManager.LoadPerceptionSimulationRecording(path,factory,null);
                    playback.Play();
                    DateTime until=DateTime.UtcNow.AddSeconds(3);
                    while(factory.Sink.Packets==0 && DateTime.UtcNow<until) Thread.Sleep(20);
                    Thread.Sleep(350);
                    string state=playback.State.ToString();
                    playback.Stop();
                    bool recordingOk=new FileInfo(path).Length>0 && factory.Sink.Packets>0;
                    result["recordingRoundTrip"]=new {ok=recordingOk,path=path,fileBytes=new FileInfo(path).Length,replayedPackets=factory.Sink.Packets,replayedBytes=factory.Sink.Bytes,stateBeforeStop=state};
                    ok &= recordingOk;
                } finally { if(playback!=null) { try {playback.Stop();} catch {} } Release(playback); GC.KeepAlive(factory); }
            }
            if(service) {
                object server=null;
                bool initialized=false;
                try {
                    Marshal.ThrowExceptionForHR(CoInitializeEx(IntPtr.Zero,0));
                    initialized=true;
                    Guid clsid=new Guid("20F986F0-B5C9-4EE1-BFA2-DA4CBF1B56B3");
                    Guid iid=new Guid("00000000-0000-0000-C000-000000000046");
                    Marshal.ThrowExceptionForHR(CoCreateInstance(ref clsid,IntPtr.Zero,4,ref iid,out server));
                    result["serviceComActivation"]=new {ok=server!=null,context="CLSCTX_LOCAL_SERVER"};
                    ok &= server!=null;
                } catch(Exception e) { result["serviceComActivation"]=Failure(e); ok=false; }
                finally { Release(server); if(initialized) CoUninitialize(); }
            }
            if(localDevice) {
                string headsetId=null;
                ISimulationStreamSink control=null;
                bool removed=false;
                try {
                    headsetId=PerceptionSimulationManager.InstallSimulatedHeadset("B1DE8CAA-898F-474F-811A-F041FE3FD40D",null);
                    result["localDeviceCreated"]=!String.IsNullOrEmpty(headsetId);
                    result["localDeviceId"]=headsetId;
                    control=PerceptionSimulationManager.CreateControlStreamForDevice(headsetId);
                    result["localControlStreamCreated"]=control!=null;
                    ok &= control!=null;
                } catch(Exception e) { result["localDeviceError"]=Failure(e); ok=false; }
                finally {
                    Release(control);
                    if(!String.IsNullOrEmpty(headsetId)) {
                        try { PerceptionSimulationManager.RemoveSimulatedHeadset(headsetId); removed=true; }
                        catch(Exception e) { result["localDeviceCleanupError"]=Failure(e); ok=false; }
                    }
                    result["localDeviceRemoved"]=removed;
                }
            }
        } catch(Exception e) { result["error"]=Failure(e); ok=false; }
        result["ok"]=ok;
        Console.WriteLine(Json.Serialize(result));
        return ok ? 0 : 2;
    }
}
