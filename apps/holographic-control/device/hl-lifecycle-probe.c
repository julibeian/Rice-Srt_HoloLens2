/* Public package lifecycle diagnostics, restricted to this project's packages.
 * Optional 30-second debugging lease always calls DisableDebugging afterwards.
 */
#define perception_probe_entry unused_perception_probe_entry
#include "hl-perception-probe.c"
#undef perception_probe_entry
IMPORT WCHAR* API GetCommandLineW(void);IMPORT void API Sleep(DWORD);
IMPORT LONG API GetPackagesByPackageFamily(const WCHAR*,DWORD*,WCHAR**,DWORD*,WCHAR*);
IMPORT DWORD API WTSGetActiveConsoleSessionId(void);IMPORT BOOL API ProcessIdToSessionId(DWORD,DWORD*);
#include "../../../native/hl-report-path.h"
typedef HRESULT (API *EnableFn)(Object*,const WCHAR*,const WCHAR*,WCHAR*);
typedef HRESULT (API *PackageFn)(Object*,const WCHAR*);
typedef HRESULT (API *StateFn)(Object*,const WCHAR*,int*);
typedef HRESULT (API *ActivateFn)(Object*,const WCHAR*,const WCHAR*,DWORD,DWORD*);
typedef HRESULT (API *SessionFn)(Object*,DWORD);
static const GUID debug_clsid={0xb1aec16f,0x2383,0x4852,{0xb0,0xe9,0x8f,0x0b,0x1d,0xc6,0x6b,0x4d}};
static const GUID debug_iid={0xf27c3930,0x8029,0x4ad1,{0x94,0xe3,0x3d,0xba,0x41,0x78,0x10,0xc1}};
static const GUID activate_clsid={0x45ba127d,0x10a8,0x46ea,{0x8a,0xb7,0x56,0xea,0x90,0x78,0x94,0x3c}};
static const GUID activate_iid={0x2e941141,0x7f97,0x4756,{0xba,0x1d,0x9d,0xec,0xde,0x89,0x4a,0x3d}};
static WCHAR buffer[8192];static WCHAR*names[8];static const WCHAR*family,*aumid;
static HRESULT factory_hr=(HRESULT)0x8000000a,state_hr=(HRESULT)0x8000000a,enable_hr=(HRESULT)0x8000000a,disable_hr=(HRESULT)0x8000000a,resume_hr=(HRESULT)0x8000000a,activation_hr=(HRESULT)0x8000000a;
static LONG enumeration_error;static DWORD count=8,target_pid;static int state=-1,lease,field;
static DWORD own_session,console_session;static HRESULT session_hr=(HRESULT)0x8000000a;
static const WCHAR*lifecycle_path;static int surface,resume_only;
static int option(const WCHAR*n){const WCHAR*p=GetCommandLineW();for(;*p;p++){int i=0;while(n[i]&&p[i]==n[i])i++;if(!n[i]&&(!p[i]||p[i]==' '))return 1;}return 0;}
static void lifecycle_report(const char*phase){
 DWORD n=512,written=0;output_used=0;text("{\"version\":1,\"phase\":");json_string(phase);text(",\"pid\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");text(",\"packageFamily\":");json_wide(family);text(",\"packageEnumerationError\":");number((DWORD)enumeration_error);text(",\"packages\":[");
 if(!enumeration_error)for(DWORD i=0;i<count;i++){if(i)text(",");json_wide(names[i]);}text("],\"factory\":");hex_result(factory_hr);text(",\"stateQuery\":");hex_result(state_hr);text(",\"executionState\":");if(state>=0)number((DWORD)state);else text("null");text(",\"enableDebugging\":");hex_result(enable_hr);text(",\"resume\":");hex_result(resume_hr);text(",\"activate\":");hex_result(activation_hr);text(",\"targetPid\":");number(target_pid);text(",\"disableDebugging\":");hex_result(disable_hr);text(",\"ownSession\":");number(own_session);text(",\"consoleSession\":");number(console_session);text(",\"targetSessionHr\":");hex_result(session_hr);text(",\"leaseRequested\":");text(lease?"true":"false");text(",\"leaseMs\":30000,\"visualVerified\":false}\n");
 HANDLE f=CreateFileW(lifecycle_path,0x40000000,1,0,2,0x80,0);if(f!=(HANDLE)(ULONG_PTR)-1){WriteFile(f,output,output_used,&written,0);CloseHandle(f);}
}
void API lifecycle_probe_entry(void){
 if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\lifecycle-result.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&lifecycle_path))ExitProcess(64);
 if(hl_report_explicit){HANDLE f=CreateFileW(lifecycle_path,0x40000000,1,0,1,0x80,0);if(f==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);CloseHandle(f);}
 field=option((const WCHAR*)L" --field");surface=option((const WCHAR*)L" --surface");resume_only=option((const WCHAR*)L" --resume-existing");lease=option((const WCHAR*)L" --lease");family=(const WCHAR*)(field?L"Rice.HoloLens.Field_r5420n6798s24":surface?L"Rice.HoloLens.SurfaceProbe_r5420n6798s24":L"Rice.HoloLens.NativeSurface_r5420n6798s24");aumid=(const WCHAR*)(field?L"Rice.HoloLens.Field_r5420n6798s24!Field":surface?L"Rice.HoloLens.SurfaceProbe_r5420n6798s24!Surface":L"Rice.HoloLens.NativeSurface_r5420n6798s24!Native");
 HRESULT ro=RoInitialize(1);DWORD chars=8192;Object*debug=0,*activation=0;console_session=WTSGetActiveConsoleSessionId();ProcessIdToSessionId(GetCurrentProcessId(),&own_session);enumeration_error=GetPackagesByPackageFamily(family,&count,names,&chars,buffer);
 factory_hr=CoCreateInstance(&debug_clsid,0,1,&debug_iid,(void**)&debug);
 if(factory_hr>=0&&!enumeration_error&&count==1){
  if(console_session!=(DWORD)-1)session_hr=((SessionFn)debug->v[8])(debug,console_session);
  state_hr=((StateFn)debug->v[15])(debug,names[0],&state);lifecycle_report("initial");
  if(lease){
   enable_hr=((EnableFn)debug->v[3])(debug,names[0],0,0);
   if(enable_hr>=0){
    if(!resume_only){HRESULT a=CoCreateInstance(&activate_clsid,0,4,&activate_iid,(void**)&activation);activation_hr=a>=0?((ActivateFn)activation->v[3])(activation,aumid,(const WCHAR*)L"",0,&target_pid):a;}
    resume_hr=((PackageFn)debug->v[6])(debug,names[0]);
    for(int i=0;i<30;i++){state_hr=((StateFn)debug->v[15])(debug,names[0],&state);lifecycle_report("lease_active");Sleep(1000);}
    disable_hr=((PackageFn)debug->v[4])(debug,names[0]);state_hr=((StateFn)debug->v[15])(debug,names[0],&state);
   }
  }
 }
 lifecycle_report("finished");drop(activation);drop(debug);if(ro>=0)RoUninitialize();flush();ExitProcess(lease&&enable_hr<0?2:0);
}
