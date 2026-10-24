/* Inspect the OS perception-simulation factory under the existing SDK identity.
 * Does not change simulation mode or send head, hand, keyboard, or mouse input.
 */
#define hl_entry unused_token_probe_entry
#include "../../native/hl-token-probe.c"
#undef hl_entry

typedef long HRESULT;
typedef struct Object { void **v; } Object;
IMPORT HANDLE API LoadLibraryExW(const WCHAR*,HANDLE,DWORD);
IMPORT void* API GetProcAddress(HANDLE,const char*);
IMPORT BOOL API FreeLibrary(HANDLE);
IMPORT HRESULT API RoInitialize(DWORD);
IMPORT void API RoUninitialize(void);
typedef struct{DWORD a;unsigned short b,c;BYTE d[8];} GUID;
IMPORT HRESULT API CoCreateInstance(const GUID*,void*,DWORD,const GUID*,void**);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
typedef BOOL (API *UsingDriverFn)(void);
typedef int (API *ControlModeFn)(void);
typedef HRESULT (API *CreateManagerFn)(Object*,Object**);
typedef HRESULT (API *GetObjectFn)(Object*,Object**);
typedef DWORD (API *ReleaseFn)(Object*);
static const GUID simulation_clsid={0x3ad33743,0x429f,0x4de2,{0x8b,0x95,0x58,0xfa,0x5c,0x72,0x75,0x15}};
static const GUID simulation_iid={0xaecbecf6,0x92ff,0x4155,{0xa5,0xbc,0x6a,0x5a,0x9e,0x9e,0xfb,0xb9}};

static void hex_result(HRESULT hr) {
    static const char hex[]="0123456789ABCDEF";
    text("\"0x");
    for(int i=7;i>=0;i--) chr(hex[((DWORD)hr>>(4*i))&15]);
    chr('"');
}
static void drop(Object *o) { if(o) ((ReleaseFn)o->v[2])(o); }

void API perception_probe_entry(void) {
    DWORD length=512, sent=0;
    HRESULT ro=RoInitialize(1), factory=(HRESULT)0x80004005;
    Object *manager=0, *human=0, *head=0,*local_simulation=0;
    HANDLE lib=LoadLibraryExW((const WCHAR*)L"PerceptionSimulationManager.dll",0,0x800);
    DWORD load_error=lib?0:GetLastError();
    UsingDriverFn driver=lib?(UsingDriverFn)GetProcAddress(lib,"GetIsUsingDriver"):0;
    ControlModeFn mode=lib?(ControlModeFn)GetProcAddress(lib,"GetControlMode"):0;
    CreateManagerFn create=lib?(CreateManagerFn)GetProcAddress(lib,"CreatePerceptionSimulationManager"):0;
    text("{\"probeVersion\":1,\"inputSent\":false,\"modeChanged\":false,\"processId\":");
    number(GetCurrentProcessId());text(",\"user\":");
    if(GetUserNameW(wide_buffer,&length))json_wide(wide_buffer);else text("null");
    text(",\"roInitialize\":");hex_result(ro);
    text(",\"loadError\":");number(load_error);
    text(",\"usingDriver\":");if(driver)text(driver()?"true":"false");else text("null");
    text(",\"controlMode\":");if(mode)number((DWORD)mode());else text("null");
    HRESULT local=CoCreateInstance(&simulation_clsid,0,4,&simulation_iid,(void**)&local_simulation);
    text(",\"localSimulationCom\":");hex_result(local);text(",\"hasLocalSimulation\":");text(local_simulation?"true":"false");
    if(create)factory=create(0,&manager);
    text(",\"localFactory\":");hex_result(factory);
    text(",\"hasManager\":");text(manager?"true":"false");
    if(manager){
        HRESULT hr=((GetObjectFn)manager->v[4])(manager,&human);
        text(",\"getHuman\":");hex_result(hr);
        if(human){hr=((GetObjectFn)human->v[11])(human,&head);text(",\"getHead\":");hex_result(hr);}
    }
    text(",\"hasHead\":");text(head?"true":"false");text("}\n");
    drop(head);drop(human);drop(manager);drop(local_simulation);
    if(lib)FreeLibrary(lib);if(ro>=0)RoUninitialize();
    HANDLE report=CreateFileW((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\perception-probe-result.json",0x40000000,1,0,2,0x80,0);
    if(report!=(HANDLE)(ULONG_PTR)-1){WriteFile(report,output,output_used,&sent,0);CloseHandle(report);}
    flush();ExitProcess(factory<0?2:0);
}
