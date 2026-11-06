/* Read-only WDDM telemetry. Keep NTSTATUS failures; zero is not an observed clock. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <d3dkmthk.h>
#include <tlhelp32.h>
#include <powrprof.h>
/* ProcessorInformation's documented six-ULONG buffer is not declared by the
   OneCore SDK headers, so keep its ABI layout local to this read-only probe. */
typedef struct{ULONG Number,MaxMhz,CurrentMhz,MhzLimit,MaxIdleState,CurrentIdleState;} RiceProcessorPowerInfo;
_Static_assert(sizeof(RiceProcessorPowerInfo)==24,"ProcessorInformation ABI");
void *memset(void*d,int v,size_t n){BYTE*p=d;while(n--)*p++=(BYTE)v;return d;}
static char json[8192];static UINT32 used;
static void s(const char*p){while(*p&&used+1<sizeof(json))json[used++]=*p++;}
static void u(ULONGLONG v){char b[32];int n=0;do{b[n++]=(char)('0'+v%10);v/=10;}while(v);while(n){char c[2]={b[--n],0};s(c);}}
static void field(const char*name,ULONGLONG v){s(",\"");s(name);s("\":");u(v);}
static BOOL tracked(const WCHAR*p){return lstrcmpiW(p,L"dwm.exe")==0||lstrcmpiW(p,L"HoloShellApp.exe")==0||lstrcmpiW(p,L"WWAHost.exe")==0||lstrcmpiW(p,L"HoloCameraApp.exe")==0;}
static void name(const WCHAR*w){char b[256];int n=WideCharToMultiByte(CP_UTF8,0,w,-1,b,sizeof(b),NULL,NULL);s("\"");for(int i=0;i<n-1;i++){if(b[i]=='"'||b[i]=='\\')s("\\");char c[2]={b[i],0};s(c);}s("\"");}
static void arg(WCHAR**p,WCHAR*out){while(**p==L' ')(*p)++;BOOL q=**p==L'"';if(q)(*p)++;UINT32 n=0;while(**p&&(q?**p!=L'"':**p!=L' ')){if(n<1023)out[n++]=**p;(*p)++;}out[n]=0;if(q&&**p)(*p)++;}
void __stdcall gpu_probe_entry(void){
 static WCHAR exe[1024],out[1024],duration[1024];WCHAR*p=GetCommandLineW();arg(&p,exe);arg(&p,out);arg(&p,duration);if(!out[0])ExitProcess(64);
 UINT32 seconds=0;for(UINT32 i=0;duration[i]>=L'0'&&duration[i]<=L'9';i++)seconds=seconds*10+duration[i]-L'0';if(!seconds||seconds>3600)seconds=1;
 HANDLE file=CreateFileW(out,GENERIC_WRITE,FILE_SHARE_READ,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);if(file==INVALID_HANDLE_VALUE)ExitProcess(65);
 HMODULE module=LoadLibraryW(L"gdi32.dll");
 PFND3DKMT_ENUMADAPTERS2 enumerate=module?(PFND3DKMT_ENUMADAPTERS2)GetProcAddress(module,"D3DKMTEnumAdapters2"):NULL;
 PFND3DKMT_QUERYADAPTERINFO query=module?(PFND3DKMT_QUERYADAPTERINFO)GetProcAddress(module,"D3DKMTQueryAdapterInfo"):NULL;
 PFND3DKMT_CLOSEADAPTER closeAdapter=module?(PFND3DKMT_CLOSEADAPTER)GetProcAddress(module,"D3DKMTCloseAdapter"):NULL;
 PFND3DKMT_QUERYSTATISTICS stats=module?(PFND3DKMT_QUERYSTATISTICS)GetProcAddress(module,"D3DKMTQueryStatistics"):NULL;
 HMODULE power_module=LoadLibraryW(L"powrprof.dll");
 typedef NTSTATUS(WINAPI*PowerInfoFn)(POWER_INFORMATION_LEVEL,PVOID,ULONG,PVOID,ULONG);
 PowerInfoFn power_info=power_module?(PowerInfoFn)GetProcAddress(power_module,"CallNtPowerInformation"):NULL;
 D3DKMT_ADAPTERINFO adapters[16]={0};D3DKMT_ENUMADAPTERS2 list={16,adapters};NTSTATUS enumeration=enumerate?enumerate(&list):(NTSTATUS)0xc000007a;
 if(list.NumAdapters>16)list.NumAdapters=16;
 ULONGLONG began=GetTickCount64();
 do{
  used=0;s("{\"processId\":");u(GetCurrentProcessId());field("tickMs",GetTickCount64());field("enumerationStatus",(UINT32)enumeration);
  SYSTEM_POWER_STATUS power={0};BOOL power_ok=GetSystemPowerStatus(&power);field("systemPowerStatusAvailable",power_ok?1:0);if(power_ok){field("acLineStatus",power.ACLineStatus);field("batteryPercent",power.BatteryLifePercent);field("batterySaver",power.SystemStatusFlag);}
  SYSTEM_INFO cpu_info={0};GetNativeSystemInfo(&cpu_info);RiceProcessorPowerInfo cpu[32]={0};ULONG cpu_count=cpu_info.dwNumberOfProcessors;if(cpu_count>32)cpu_count=32;
  NTSTATUS cpu_status=power_info?power_info(ProcessorInformation,NULL,0,cpu,cpu_count*sizeof(cpu[0])):(NTSTATUS)0xc000007a;
  field("cpuPowerStatus",(UINT32)cpu_status);s(",\"cpuFrequency\":[");if(cpu_status>=0)for(ULONG c=0;c<cpu_count;c++){if(c)s(",");s("{\"number\":");u(cpu[c].Number);field("currentMhz",cpu[c].CurrentMhz);field("maximumMhz",cpu[c].MaxMhz);field("limitMhz",cpu[c].MhzLimit);s("}");}s("],\"adapters\":[");
  if(enumeration>=0&&query)for(UINT32 a=0;a<list.NumAdapters;a++){
   if(a)s(",");s("{\"index\":");u(a);field("luidLow",adapters[a].AdapterLuid.LowPart);field("luidHigh",(UINT32)adapters[a].AdapterLuid.HighPart);
   D3DKMT_NODE_PERFDATA node={0};D3DKMT_QUERYADAPTERINFO request={adapters[a].hAdapter,KMTQAITYPE_NODEPERFDATA,&node,sizeof(node)};NTSTATUS ns=query(&request);
   field("nodeStatus",(UINT32)ns);if(ns>=0){field("frequencyHz",node.Frequency);field("maxFrequencyHz",node.MaxFrequency);}
   D3DKMT_ADAPTER_PERFDATA data={0};request.Type=KMTQAITYPE_ADAPTERPERFDATA;request.pPrivateDriverData=&data;request.PrivateDriverDataSize=sizeof(data);NTSTATUS ds=query(&request);
   field("adapterStatus",(UINT32)ds);if(ds>=0){field("memoryFrequencyHz",data.MemoryFrequency);field("temperatureDeciC",data.Temperature);field("powerTenthsPercent",data.Power);}
   if(stats){D3DKMT_QUERYSTATISTICS q={0};q.Type=D3DKMT_QUERYSTATISTICS_NODE;q.AdapterLuid=adapters[a].AdapterLuid;NTSTATUS status=stats(&q);field("nodeTimeStatus",(UINT32)status);if(status>=0){field("globalRunningTimeRaw",q.QueryResult.NodeInformation.GlobalInformation.RunningTime.QuadPart);field("systemRunningTimeRaw",q.QueryResult.NodeInformation.SystemInformation.RunningTime.QuadPart);}}
   s("}");
  }
  s("],\"processes\":[");
  HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);DWORD snapshot_error=snapshot==INVALID_HANDLE_VALUE?GetLastError():0;
  if(snapshot!=INVALID_HANDLE_VALUE){PROCESSENTRY32W entry={0};entry.dwSize=sizeof(entry);BOOL more=Process32FirstW(snapshot,&entry);UINT32 count=0;
   while(more){if(tracked(entry.szExeFile)){if(count++)s(",");s("{\"name\":");name(entry.szExeFile);field("pid",entry.th32ProcessID);HANDLE process=OpenProcess(PROCESS_QUERY_INFORMATION,FALSE,entry.th32ProcessID);DWORD full_error=process?0:GetLastError();if(!process)process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,entry.th32ProcessID);DWORD open_error=process?0:GetLastError();field("fullQueryOpenError",full_error);field("openError",open_error);
    if(process&&stats&&enumeration>=0&&list.NumAdapters){D3DKMT_QUERYSTATISTICS q={0};q.Type=D3DKMT_QUERYSTATISTICS_PROCESS_NODE;q.AdapterLuid=adapters[0].AdapterLuid;q.hProcess=process;NTSTATUS status=stats(&q);field("status",(UINT32)status);if(status>=0){field("runningTimeRaw",q.QueryResult.ProcessNodeInformation.RunningTime.QuadPart);field("contextSwitches",q.QueryResult.ProcessNodeInformation.ContextSwitch);}}
    if(process)CloseHandle(process);s("}");}more=Process32NextW(snapshot,&entry);
   }DWORD end_error=GetLastError();if(end_error!=ERROR_NO_MORE_FILES)snapshot_error=end_error;CloseHandle(snapshot);
  }
  s("]");field("processEnumerationError",snapshot_error);s("}\n");DWORD wrote;WriteFile(file,json,used,&wrote,NULL);FlushFileBuffers(file);if(GetTickCount64()-began>=(ULONGLONG)(seconds-1)*1000)break;Sleep(1000);
 }while(GetTickCount64()-began<(ULONGLONG)seconds*1000);
 if(enumeration>=0&&closeAdapter)for(UINT32 a=0;a<list.NumAdapters;a++){D3DKMT_CLOSEADAPTER c={adapters[a].hAdapter};closeAdapter(&c);}
 CloseHandle(file);if(module)FreeLibrary(module);if(power_module)FreeLibrary(power_module);ExitProcess(0);
}
