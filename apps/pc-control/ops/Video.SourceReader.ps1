$ErrorActionPreference='Stop'
if(-not ('HoloVideoSourceReader' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

// Diagnostic comparison: the authenticated, pinned HTTP stream is unchanged.
// Keep its bounded copy and timestamp collection outside the PowerShell loop.
public static class HoloVideoSourceReader {
    public sealed class Chunk {
        public long byte_end;
        public double received_ms;
        public int bytes;
    }
    public sealed class Capture {
        public long Bytes;
        public double Seconds;
        public Chunk[] Chunks;
    }
    public static async Task<Capture> CopyAsync(Stream source,Stream destination,
            Stopwatch clock,CancellationToken cancellation) {
        var chunks=new List<Chunk>();
        var buffer=new byte[65536];
        long bytes=0;
        try {
            while(bytes<67108864) {
                int count=await source.ReadAsync(buffer,0,buffer.Length,cancellation).ConfigureAwait(false);
                double received=clock.Elapsed.TotalMilliseconds;
                if(count==0)break;
                bytes+=count;
                chunks.Add(new Chunk {byte_end=bytes,received_ms=received,bytes=count});
                destination.Write(buffer,0,count);
            }
        } catch(OperationCanceledException) when(cancellation.IsCancellationRequested) { }
        return new Capture {Bytes=bytes,Seconds=clock.Elapsed.TotalSeconds,Chunks=chunks.ToArray()};
    }
}
'@
}
