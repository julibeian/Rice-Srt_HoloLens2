/* Bounded read-only power and System/Kernel-Power event observations.
 * No execution requests, settings writes, simulated input or elevation. */
#define hl_entry unused_power_state_token_entry
#include "../../../native/hl-token-probe.c"
#undef hl_entry
IMPORT WCHAR* API GetCommandLineW(void);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT LONG API CallNtPowerInformation(int,void*,DWORD,void*,DWORD);
IMPORT unsigned long long API GetTickCount64(void);
IMPORT HANDLE API LoadLibraryExW(const WCHAR*,HANDLE,DWORD);
IMPORT void* API GetProcAddress(HANDLE,const char*);
IMPORT BOOL API FreeLibrary(HANDLE);
#include "../../../native/hl-report-path.h"
typedef HANDLE (API *QueryEvents)(HANDLE,const WCHAR*,const WCHAR*,DWORD);
typedef BOOL (API *NextEvents)(HANDLE,DWORD,HANDLE*,DWORD,DWORD,DWORD*);
typedef BOOL (API *RenderEvent)(HANDLE,HANDLE,DWORD,DWORD,void*,DWORD*,DWORD*);
typedef BOOL (API *CloseEvent)(HANDLE);
typedef struct {DWORD maxIdleness,idleness,timeRemaining;BYTE coolingMode,reserved[3];} SystemPowerInfo;
_Static_assert(sizeof(SystemPowerInfo)==16,"SYSTEM_POWER_INFORMATION size");
static WCHAR event_xml[32768],event_path[1100];
static const WCHAR *report_path;
static void number64(unsigned long long value){char digits[24];int n=0;do{digits[n++]=(char)('0'+value%10);value/=10;}while(value);while(n)chr(digits[--n]);}
static void status32(LONG value){static const char hex[]="0123456789abcdef";text("\"0x");for(int i=7;i>=0;i--)chr(hex[((DWORD)value>>(i*4))&15]);chr('"');}
static void wide_length_path(int index){unsigned n=0;while(report_path[n]&&n<1023){event_path[n]=report_path[n];n++;}const WCHAR*suffix=(const WCHAR*)L".event-0.xml";while(*suffix&&n<1098)event_path[n++]=*suffix++;event_path[n]=0;event_path[n-5]=(WCHAR)('0'+index);}
static void events(void){
 HANDLE module=LoadLibraryExW((const WCHAR*)L"wevtapi.dll",0,0x800);
 text(",\"systemEvents\":{");
 if(!module){text("\"loadError\":");number(GetLastError());chr('}');return;}
 QueryEvents query=(QueryEvents)GetProcAddress(module,"EvtQuery");NextEvents next=(NextEvents)GetProcAddress(module,"EvtNext");RenderEvent render=(RenderEvent)GetProcAddress(module,"EvtRender");CloseEvent close=(CloseEvent)GetProcAddress(module,"EvtClose");
 if(!query||!next||!render||!close){text("\"entryPointError\":");number(GetLastError());chr('}');FreeLibrary(module);return;}
 HANDLE results=query(0,(const WCHAR*)L"System",(const WCHAR*)L"*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=42 or EventID=506 or EventID=507)]]",0x201);
 if(!results){text("\"queryError\":");number(GetLastError());chr('}');FreeLibrary(module);return;}
 text("\"files\":[");int count=0;DWORD next_error=0;
 for(int i=0;i<6;i++){
  HANDLE item=0;DWORD returned=0;
  if(!next(results,1,&item,2000,0,&returned)){next_error=GetLastError();break;}
  if(!returned)break;
  DWORD used=0,properties=0;BOOL rendered=render(0,item,1,sizeof(event_xml),event_xml,&used,&properties);DWORD render_error=rendered?0:GetLastError(),write_error=0;BOOL written_ok=0;
  if(rendered&&used>=2&&used<=sizeof(event_xml)){
   wide_length_path(i);HANDLE file=CreateFileW(event_path,0x40000000,1,0,1,0x80,0);
   if(file==(HANDLE)(ULONG_PTR)-1)write_error=GetLastError();
   else{WCHAR bom=0xfeff;DWORD done=0;BOOL bom_ok=WriteFile(file,&bom,2,&done,0)&&done==2;DWORD bytes=used-2;BOOL data_ok=WriteFile(file,event_xml,bytes,&done,0)&&done==bytes;written_ok=bom_ok&&data_ok;if(!written_ok)write_error=GetLastError();CloseHandle(file);}
  }
  if(count++)chr(',');text("{\"renderError\":");number(render_error);text(",\"bytes\":");number(used);text(",\"writeError\":");number(write_error);text(",\"saved\":");text(written_ok?"true":"false");if(written_ok){text(",\"path\":");json_wide(event_path);}chr('}');close(item);
 }
 text("],\"nextError\":");number(next_error);chr('}');close(results);FreeLibrary(module);
}
void API power_state_probe_entry(void){
 if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\power-state.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&report_path))ExitProcess(64);
 HANDLE file=CreateFileW(report_path,0x40000000,1,0,1,0x80,0);if(file==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);
 DWORD execution=0;SystemPowerInfo info={0};unsigned long long sleep=0,wake=0;
 LONG execution_status=CallNtPowerInformation(16,0,0,&execution,sizeof(execution));LONG power_status=CallNtPowerInformation(12,0,0,&info,sizeof(info));LONG sleep_status=CallNtPowerInformation(15,0,0,&sleep,sizeof(sleep));LONG wake_status=CallNtPowerInformation(14,0,0,&wake,sizeof(wake));
 DWORD n=512;text("{\"schema_version\":1,\"readonly\":true,\"inputSent\":false,\"processId\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");text(",\"uptimeMs\":");number64(GetTickCount64());
 text(",\"execution\":{\"status\":");status32(execution_status);text(",\"flags\":");number(execution);text("},\"powerInformation\":{\"status\":");status32(power_status);text(",\"maxIdleness\":");number(info.maxIdleness);text(",\"idleness\":");number(info.idleness);text(",\"timeRemaining\":");number(info.timeRemaining);text(",\"coolingMode\":");number(info.coolingMode);text("},\"lastSleep\":{\"status\":");status32(sleep_status);text(",\"interruptTime100ns\":");number64(sleep);text("},\"lastWake\":{\"status\":");status32(wake_status);text(",\"interruptTime100ns\":");number64(wake);chr('}');events();text("}\n");
 DWORD written=0;BOOL saved=WriteFile(file,output,output_used,&written,0)&&written==output_used;CloseHandle(file);flush();ExitProcess(saved?0:4);
}
