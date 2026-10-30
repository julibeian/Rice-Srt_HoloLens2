/* Default: capability check only. --shortcut-start explicitly tests the public
 * HoloLens system Start shortcut. This binary is deployed only to the pinned
 * HoloLens. It never changes capabilities or inputs authentication data.
 */
#include "../../../apps/capture-app/device-research/hl-uri-launch.c"
static const GUID injector_statics_iid={0xdeae6943,0x7402,0x4141,{0xa5,0xc6,0x0c,0x01,0xaa,0x57,0xb1,0x6a}};
typedef HRESULT(API *TryCreateFn)(Object*,Object**);
typedef HRESULT(API *ShortcutFn)(Object*,int);
void API injector_probe_entry(void){
    HRESULT init=RoInitialize(1),activation=(HRESULT)0x8000000a,create=(HRESULT)0x8000000a;
    HRESULT shortcut=(HRESULT)0x8000000a;int start=0,valid=parse_args();
    for(int i=1;valid&&i<argc;i++){if(equal_ascii(args[i],"--shortcut-start"))start=1;else if(!equal_ascii(args[i],"--inspect"))valid=0;}
    Object *statics=0,*injector=0;DWORD n=512,sent=0;WCHAR user[512];
    if(init>=0)activation=factory((const WCHAR*)L"Windows.UI.Input.Preview.Injection.InputInjector",&injector_statics_iid,&statics);
    if(activation>=0)create=((TryCreateFn)statics->v[6])(statics,&injector);
    if(valid&&start&&injector)shortcut=((ShortcutFn)injector->v[14])(injector,1);
    text("{\"probeVersion\":2,\"inputRequested\":");text(start?"true":"false");text(",\"inputApiAccepted\":");text(start&&shortcut>=0?"true":"false");text(",\"inputSent\":");text(start&&shortcut>=0?"true":"false");text(",\"capabilitiesChanged\":false,\"user\":");
    if(GetUserNameW(user,&n))json_wide(user);else text("null");
    text(",\"initialize\":");hex_hr(init);text(",\"activationFactory\":");hex_hr(activation);text(",\"tryCreate\":");hex_hr(create);text(",\"hasInjector\":");text(injector?"true":"false");text(",\"shortcutStart\":");hex_hr(shortcut);text("}\n");
    release(injector);release(statics);if(init>=0)RoUninitialize();
    HANDLE report=CreateFileW((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\injector-probe-result.json",0x40000000,1,0,2,0x80,0);
    if(report!=(HANDLE)(unsigned long long)-1){WriteFile(report,output,used,&sent,0);CloseHandle(report);}
    WriteFile(GetStdHandle((DWORD)-11),output,used,&sent,0);ExitProcess(injector?0:2);
}
