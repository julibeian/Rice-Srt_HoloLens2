/* One bounded test of the public OS simulation mode API; restores prior mode.
 * No driver installation, registry modification, credential access, or input.
 */
#define hl_entry unused_token_probe_entry
#include "../../native/hl-token-probe.c"
#undef hl_entry
typedef long HRESULT;
IMPORT HANDLE API LoadLibraryExW(const WCHAR*,HANDLE,DWORD);
IMPORT void* API GetProcAddress(HANDLE,const char*);
IMPORT BOOL API FreeLibrary(HANDLE);
IMPORT void API Sleep(DWORD);
IMPORT HRESULT API RoInitialize(DWORD);
IMPORT void API RoUninitialize(void);
IMPORT WCHAR* API GetCommandLineW(void);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
#include "../../native/hl-report-path.h"
typedef int (API *GetModeFn)(void);
typedef HRESULT (API *SetModeFn)(int);
static GetModeFn get_mode;static SetModeFn set_mode;static int previous=-1;static HRESULT changed=(HRESULT)0x8000000a;
static DWORD lease_ms=20000;
static const WCHAR*report_path;static WCHAR stop_path[512];
static int option(const WCHAR*n){const WCHAR*s=GetCommandLineW();for(;*s;s++){int i=0;while(n[i]&&s[i]==n[i])i++;if(!n[i]&&(!s[i]||s[i]==' '))return 1;}return 0;}
static void hr(HRESULT v){const char*h="0123456789ABCDEF";text("\"0x");for(int i=7;i>=0;i--){char b[2]={h[((DWORD)v>>(4*i))&15],0};text(b);}text("\"");}
static void report(const char*phase,HRESULT restore){
    DWORD sent=0,n=512;output_used=0;
    text("{\"version\":2,\"processId\":");number(GetCurrentProcessId());text(",\"phase\":");json_string(phase);text(",\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");
    text(",\"previousMode\":");if(previous>=0)number((DWORD)previous);else text("null");text(",\"currentMode\":");if(get_mode)number((DWORD)get_mode());else text("null");
    text(",\"setSimulation\":");hr(changed);text(",\"restore\":");hr(restore);text(",\"leaseMs\":");number(lease_ms);text(",\"inputSent\":false}\n");
    HANDLE f=CreateFileW(report_path,0x40000000,1,0,2,0x80,0);
    if(f!=(HANDLE)(ULONG_PTR)-1){WriteFile(f,output,output_used,&sent,0);CloseHandle(f);}
}
void API simulation_lease_entry(void){
    HRESULT initialized=RoInitialize(1);
    if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\simulation-lease.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&report_path))ExitProcess(64);
    DWORD chars=0;while(report_path[chars])chars++;if(chars>490)ExitProcess(64);
    for(DWORD i=0;i<chars;i++)stop_path[i]=report_path[i];const WCHAR*suffix=(const WCHAR*)L".stop";for(DWORD i=0;i<6;i++)stop_path[chars+i]=suffix[i];
    if(hl_report_explicit){HANDLE first=CreateFileW(report_path,0x40000000,1,0,1,0x80,0);if(first==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);CloseHandle(first);}
    if(option((const WCHAR*)L" --test-60-seconds"))lease_ms=60000;
    if(option((const WCHAR*)L" --test-300-seconds"))lease_ms=300000;
    HANDLE lib=LoadLibraryExW((const WCHAR*)L"PerceptionSimulationManager.dll",0,0x800);
    if(lib){get_mode=(GetModeFn)GetProcAddress(lib,"GetControlMode");set_mode=(SetModeFn)GetProcAddress(lib,"SetControlMode");}
    if(get_mode&&set_mode){
        previous=get_mode();changed=previous==0?set_mode(1):(HRESULT)0x8000000a;
        report("test_active",(HRESULT)0x8000000a);
        if(changed>=0){for(DWORD elapsed=0;elapsed<lease_ms;elapsed+=250){HANDLE stop=CreateFileW(stop_path,0x80000000,1,0,3,0x80,0);if(stop!=(HANDLE)(ULONG_PTR)-1){CloseHandle(stop);break;}Sleep(250);}HRESULT restored=set_mode(previous);report("restored",restored);}
        else report("change_rejected_no_lease",(HRESULT)0x8000000a);
    }else report("api_unavailable",(HRESULT)0x8000000a);
    if(lib)FreeLibrary(lib);if(initialized>=0)RoUninitialize();flush();ExitProcess(changed>=0?0:2);
}
