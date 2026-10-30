/* Default: read-only wait observations. Explicit period-test flag requests1ms
 * for this worker, holds45s, and balances timeEndPeriod before reporting. */
#define perception_probe_entry unused_timing_perception_entry
#include "hl-perception-probe.c"
#undef perception_probe_entry
IMPORT WCHAR* API GetCommandLineW(void);
IMPORT BOOL API QueryPerformanceCounter(long long*);
IMPORT BOOL API QueryPerformanceFrequency(long long*);
IMPORT unsigned long long API GetTickCount64(void);
IMPORT void API Sleep(DWORD);
IMPORT DWORD API SetFilePointer(HANDLE,LONG,LONG*,DWORD);
IMPORT BOOL API SetEndOfFile(HANDLE);
#include "../../../native/hl-report-path.h"
typedef LONG (API *QueryResolutionFn)(DWORD*,DWORD*,DWORD*);
typedef DWORD (API *PeriodFn)(DWORD);
static DWORD largest,smallest,current,before_interval,after_interval,begin_result=0xffffffff,end_result=0xffffffff,module_error;
static LONG query_status=(LONG)0x80004001;
static long long frequency,samples[30];
static int sample_count,period_test;
static unsigned long long deadline;
static void timing_number64(unsigned long long value){char s[24];int n=0;do{s[n++]=(char)('0'+value%10);value/=10;}while(value);while(n)chr(s[--n]);}
static int timing_test_flag(void){const WCHAR*p=GetCommandLineW();const WCHAR*flag=(const WCHAR*)L"--period-test-45-seconds";for(;*p;p++){if(p!=GetCommandLineW()&&p[-1]!=' '&&p[-1]!='\t')continue;int i=0;while(flag[i]&&p[i]==flag[i])i++;if(!flag[i]&&(!p[i]||p[i]==' '||p[i]=='\t'))return 1;}return 0;}
static BOOL timing_report(HANDLE file,const char*phase){
 output_used=0;DWORD n=512;
 text("{\"schema_version\":1,\"readonly\":");text(period_test?"false":"true");text(",\"inputSent\":false,\"timerResolutionChanged\":");text(begin_result==0?"true":"false");text(",\"phase\":");json_string(phase);
 text(",\"processId\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");
 text(",\"uptimeMs\":");timing_number64(GetTickCount64());text(",\"deadlineUptimeMs\":");timing_number64(deadline);
 text(",\"queryTimerResolution\":");hex_result(query_status);text(",\"largestInterval100ns\":");number(largest);text(",\"smallestInterval100ns\":");number(smallest);text(",\"currentInterval100ns\":");number(current);
 text(",\"beforeInterval100ns\":");number(before_interval);text(",\"afterInterval100ns\":");number(after_interval);
 text(",\"beginPeriodResult\":");number(begin_result);text(",\"endPeriodResult\":");number(end_result);text(",\"moduleError\":");number(module_error);
 text(",\"qpcFrequency\":");if(frequency>0)timing_number64((unsigned long long)frequency);else text("null");text(",\"waitSamples\":[");
 for(int i=0;i<sample_count;i++){if(i)chr(',');text("{\"requestedMs\":");number(i<10?1:i<20?33:66);text(",\"elapsedTicks\":");if(samples[i]>=0)timing_number64((unsigned long long)samples[i]);else text("null");chr('}');}text("]}\n");
 DWORD written=0;SetFilePointer(file,0,0,0);BOOL ok=WriteFile(file,output,output_used,&written,0)&&written==output_used;return SetEndOfFile(file)&&ok;
}
void API timing_probe_entry(void){
 const WCHAR*path=0;
 if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\timing.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&path))ExitProcess(64);
 HANDLE file=CreateFileW(path,0x40000000,1,0,1,0x80,0);if(file==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);
 HANDLE module=LoadLibraryExW((const WCHAR*)L"ntdll.dll",0,0x800);
 QueryResolutionFn query=module?(QueryResolutionFn)GetProcAddress(module,"NtQueryTimerResolution"):0;
 query_status=query?query(&largest,&smallest,&current):(LONG)0x80004001;before_interval=current;
 period_test=timing_test_flag();HANDLE multimedia=0;PeriodFn begin=0,end=0;
 if(period_test){const WCHAR*names[]={(const WCHAR*)L"api-ms-win-mm-time-l1-1-0.dll",(const WCHAR*)L"winmm.dll"};for(int i=0;i<2;i++){multimedia=LoadLibraryExW(names[i],0,0x800);if(!multimedia){module_error=GetLastError();continue;}begin=(PeriodFn)GetProcAddress(multimedia,"timeBeginPeriod");end=(PeriodFn)GetProcAddress(multimedia,"timeEndPeriod");if(begin&&end)break;FreeLibrary(multimedia);multimedia=0;begin=0;end=0;}if(begin&&end){begin_result=begin(1);if(query)query_status=query(&largest,&smallest,&current);}}
 BOOL frequency_ok=QueryPerformanceFrequency(&frequency);
 if(frequency_ok&&frequency>0){const DWORD waits[]={1,33,66};for(int kind=0;kind<3;kind++)for(int i=0;i<10;i++){
  long long start=0,end=0;BOOL before=QueryPerformanceCounter(&start);Sleep(waits[kind]);BOOL after=QueryPerformanceCounter(&end);
  samples[sample_count++]=before&&after&&end>=start?end-start:-1;
 }}
 if(begin_result==0){deadline=GetTickCount64()+45000;timing_report(file,"period_active");while(GetTickCount64()<deadline)Sleep(100);end_result=end(1);}
 if(query)query_status=query(&largest,&smallest,&after_interval);if(!period_test)after_interval=current;
 BOOL saved=timing_report(file,"finished");CloseHandle(file);if(multimedia)FreeLibrary(multimedia);if(module)FreeLibrary(module);flush();ExitProcess(saved?0:4);
}
