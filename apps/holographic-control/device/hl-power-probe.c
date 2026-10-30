/* Explicit, bounded execution-state request. No input or security changes. */
#define hl_entry unused_power_token_entry
#include "../../../native/hl-token-probe.c"
#undef hl_entry
IMPORT DWORD API SetThreadExecutionState(DWORD);
IMPORT void API Sleep(DWORD);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT WCHAR* API GetCommandLineW(void);
typedef struct {DWORD version,flags;union {struct {HANDLE module;DWORD id,count;WCHAR**strings;} detailed;WCHAR*simple;} reason;} ReasonContext;
IMPORT HANDLE API PowerCreateRequest(ReasonContext*);
IMPORT BOOL API PowerSetRequest(HANDLE,int);
IMPORT BOOL API PowerClearRequest(HANDLE,int);
#include "../../../native/hl-report-path.h"
static const WCHAR *report_path;
static DWORD requested,request_error,released,release_error;
static DWORD create_error,set_errors[3],clear_errors[3];static BOOL sets[3],clears[3];static const int kinds[3]={0,1,3};
static void save(const char *phase){
    output_used=0;DWORD n=512,written=0;
    text("{\"schema_version\":1,\"processId\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");
    text(",\"phase\":");json_string(phase);text(",\"requestedFlags\":2147483651,\"previousExecutionState\":");number(requested);text(",\"requestError\":");number(request_error);
    text(",\"releasedExecutionState\":");number(released);text(",\"releaseError\":");number(release_error);text(",\"createRequestError\":");number(create_error);text(",\"powerRequests\":[");
    for(int i=0;i<3;i++){if(i)chr(',');text("{\"kind\":");number(kinds[i]);text(",\"set\":");text(sets[i]?"true":"false");text(",\"setError\":");number(set_errors[i]);text(",\"clear\":");text(clears[i]?"true":"false");text(",\"clearError\":");number(clear_errors[i]);chr('}');}
    text("],\"leaseMs\":30000,\"inputSent\":false}\n");
    HANDLE file=CreateFileW(report_path,0x40000000,1,0,2,0x80,0);if(file!=(HANDLE)(ULONG_PTR)-1){WriteFile(file,output,output_used,&written,0);CloseHandle(file);}
}
void API power_probe_entry(void){
    if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\power.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&report_path))ExitProcess(64);
    HANDLE first=CreateFileW(report_path,0x40000000,1,0,1,0x80,0);if(first==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);CloseHandle(first);
    ReasonContext reason={0};reason.flags=1;reason.reason.simple=(WCHAR*)L"Pinned USB HoloLens control session";
    HANDLE request=PowerCreateRequest(&reason);if(request==(HANDLE)(ULONG_PTR)-1)create_error=GetLastError();
    else for(int i=0;i<3;i++){sets[i]=PowerSetRequest(request,kinds[i]);if(!sets[i])set_errors[i]=GetLastError();}
    requested=SetThreadExecutionState(0x80000003UL);if(!requested)request_error=GetLastError();save("request_active");
    Sleep(30000);
    if(request!=(HANDLE)(ULONG_PTR)-1){for(int i=0;i<3;i++)if(sets[i]){clears[i]=PowerClearRequest(request,kinds[i]);if(!clears[i])clear_errors[i]=GetLastError();}CloseHandle(request);}
    released=SetThreadExecutionState(0x80000000UL);if(!released)release_error=GetLastError();save("released");ExitProcess(requested&&released?0:2);
}
