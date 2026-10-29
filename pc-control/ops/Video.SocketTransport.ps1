$ErrorActionPreference='Stop'
if(-not ('HoloVideoSocketTransport' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

// Diagnostic transport: change only this socket, preserving the already
// verified device address and exact current leaf-certificate pin.
public sealed class HoloVideoSocketTransport {
    public int ConnectedSockets;
    public int AckFrequencyApplied;
    public readonly HttpClient Client;
    public HoloVideoSocketTransport(string address,string leafSha256,byte ackFrequency) {
        if(ackFrequency!=1)throw new ArgumentOutOfRangeException("ackFrequency");
        var handler=new SocketsHttpHandler {UseProxy=false,AllowAutoRedirect=false};
        handler.SslOptions.RemoteCertificateValidationCallback=(sender,cert,chain,errors)=>
            cert!=null && cert.GetCertHashString(HashAlgorithmName.SHA256)==leafSha256;
        handler.ConnectCallback=async (context,cancellation)=> {
            if(context.DnsEndPoint.Host!=address || context.DnsEndPoint.Port!=443)
                throw new InvalidOperationException("Video socket target differs from verified device");
            var socket=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp) {NoDelay=true};
            try {
                await socket.ConnectAsync(context.DnsEndPoint,cancellation).ConfigureAwait(false);
                // Windows SDK mstcpip.h: _WSAIOW(IOC_VENDOR,23), with a
                // TCP_ACK_FREQUENCY_PARAMETERS containing one UCHAR.
                socket.IOControl(unchecked((int)0x98000017),new byte[]{ackFrequency},null);
                Interlocked.Increment(ref ConnectedSockets);
                Volatile.Write(ref AckFrequencyApplied,ackFrequency);
                return (Stream)new NetworkStream(socket,true);
            } catch {socket.Dispose();throw;}
        };
        Client=new HttpClient(handler,true);
    }
}
'@
}
