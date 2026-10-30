/* Uses the public local COM simulation endpoint under the existing SDK account.
 * No driver, account, authentication or registry changes. A presence test has a
 * 30-second lease and restores the preceding simulation state and control mode.
 */
#define perception_probe_entry unused_perception_probe_entry
#include "hl-perception-probe.c"
#undef perception_probe_entry
IMPORT WCHAR* API GetCommandLineW(void);
IMPORT void API Sleep(DWORD);
IMPORT DWORD API SetThreadExecutionState(DWORD);
#include "../../../native/hl-report-path.h"
typedef HRESULT (API *CreateStreamFn)(Object*,int,Object**);
typedef HRESULT (API *QueryFn)(Object*,const GUID*,Object**);
typedef HRESULT (API *GetBoolFn)(Object*,BOOL*);
typedef HRESULT (API *PutBoolFn)(Object*,BOOL);
typedef HRESULT (API *SetModeFn)(int);
typedef HRESULT (API *GestureFn)(Object*,int);
typedef struct{float x,y,z;} Triple;
typedef HRESULT (API *PutTripleFn)(Object*,Triple);
typedef HRESULT (API *PutIntFn)(Object*,int);
static const GUID device2_iid={0x7c2388d4,0xd596,0x4600,{0xa9,0x3c,0x1b,0xe2,0xbf,0xfc,0xab,0xbb}};
static HRESULT com_hr=(HRESULT)0x8000000a,stream_hr=(HRESULT)0x8000000a,manager_hr=(HRESULT)0x8000000a,device_hr=(HRESULT)0x8000000a;
static HRESULT presence_read_hr=(HRESULT)0x8000000a,presence_write_hr=(HRESULT)0x8000000a,mode_write_hr=(HRESULT)0x8000000a,presence_restore_hr=(HRESULT)0x8000000a,mode_restore_hr=(HRESULT)0x8000000a;
static BOOL previous_presence;static int previous_mode=-1,current_mode=-1,control,home;
static HRESULT head_hr=(HRESULT)0x8000000a,home_hr=(HRESULT)0x8000000a;
static DWORD previous_execution,restore_execution;
static const WCHAR*local_report_path;
static void local_report(const char*phase){
 DWORD sent=0,n=512;output_used=0;
 text("{\"version\":1,\"phase\":");json_string(phase);text(",\"pid\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");
 text(",\"localCom\":");hex_result(com_hr);text(",\"createControlStream\":");hex_result(stream_hr);text(",\"createManager\":");hex_result(manager_hr);text(",\"getDevice2\":");hex_result(device_hr);
 text(",\"presenceRead\":");hex_result(presence_read_hr);text(",\"previousSimulatedPresence\":");if(presence_read_hr>=0)text(previous_presence?"true":"false");else text("null");text(",\"setPresence\":");hex_result(presence_write_hr);text(",\"restorePresence\":");hex_result(presence_restore_hr);
 text(",\"previousControlMode\":");if(previous_mode>=0)number((DWORD)previous_mode);else text("null");text(",\"currentControlMode\":");if(current_mode>=0)number((DWORD)current_mode);else text("null");text(",\"setControlMode\":");hex_result(mode_write_hr);text(",\"restoreControlMode\":");hex_result(mode_restore_hr);
 text(",\"controlRequested\":");text(control?"true":"false");text(",\"inputSent\":");text(presence_write_hr>=0?"true":"false");text(",\"leaseMs\":30000,\"visualVerified\":false}\n");
 output_used-=2;text(",\"headUpdate\":");hex_result(head_hr);text(",\"homeGesture\":");hex_result(home_hr);text(",\"previousExecutionState\":");number(previous_execution);text(",\"restoreExecutionState\":");number(restore_execution);text("}\n");
 HANDLE f=CreateFileW(local_report_path,0x40000000,1,0,2,0x80,0);if(f!=(HANDLE)(ULONG_PTR)-1){WriteFile(f,output,output_used,&sent,0);CloseHandle(f);}
}
static int requested(const WCHAR*n){const WCHAR*p=GetCommandLineW();for(;*p;p++){int i=0;while(n[i]&&p[i]==n[i])i++;if(!n[i]&&(!p[i]||p[i]==' '))return 1;}return 0;}
void API local_simulation_probe_entry(void){
 if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\local-simulation-result.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&local_report_path))ExitProcess(64);
 if(hl_report_explicit){HANDLE initial=CreateFileW(local_report_path,0x40000000,1,0,1,0x80,0);if(initial==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);CloseHandle(initial);}
 home=requested((const WCHAR*)L" --home-test");control=home||requested((const WCHAR*)L" --presence-test");HRESULT ro=RoInitialize(1);Object *simulation=0,*sink=0,*manager=0,*device=0,*device2=0,*human=0,*head=0,*hand=0,*tracker=0;
 HANDLE lib=LoadLibraryExW((const WCHAR*)L"PerceptionSimulationManager.dll",0,0x800);
 CreateManagerFn create=lib?(CreateManagerFn)GetProcAddress(lib,"CreatePerceptionSimulationManager"):0;
 ControlModeFn get_mode=lib?(ControlModeFn)GetProcAddress(lib,"GetControlMode"):0;SetModeFn set_mode=lib?(SetModeFn)GetProcAddress(lib,"SetControlMode"):0;
 if(get_mode)previous_mode=current_mode=get_mode();
 com_hr=CoCreateInstance(&simulation_clsid,0,4,&simulation_iid,(void**)&simulation);local_report("local_com_checked");
 if(control&&com_hr>=0&&get_mode&&set_mode&&create&&previous_mode==0){
  stream_hr=((CreateStreamFn)simulation->v[3])(simulation,1,&sink);local_report("stream_checked");
  if(stream_hr>=0)manager_hr=create(sink,&manager);local_report("manager_checked");
  if(manager_hr>=0)device_hr=((GetObjectFn)manager->v[3])(manager,&device);
  if(device_hr>=0)device_hr=((QueryFn)device->v[0])(device,&device2_iid,&device2);
  if(device_hr>=0)presence_read_hr=((GetBoolFn)device2->v[6])(device2,&previous_presence);
  if(presence_read_hr>=0){
   mode_write_hr=set_mode(1);
   if(mode_write_hr>=0){
    if(home){previous_execution=SetThreadExecutionState(0x80000003);presence_write_hr=((PutBoolFn)device2->v[7])(device2,0);if(presence_write_hr>=0)Sleep(100);}
    if(!home||presence_write_hr>=0)presence_write_hr=((PutBoolFn)device2->v[7])(device2,1);
   }
   if(home&&presence_write_hr>=0){
    head_hr=((GetObjectFn)device->v[3])(device,&tracker);if(head_hr>=0)head_hr=((PutIntFn)tracker->v[4])(tracker,2);
    if(head_hr>=0)head_hr=((GetObjectFn)manager->v[4])(manager,&human);if(head_hr>=0)head_hr=((GetObjectFn)human->v[11])(human,&head);
    if(head_hr>=0){Triple rotation={0.0f,0.0f,0.0f};head_hr=((PutTripleFn)head->v[5])(head,rotation);}
    if(head_hr>=0)home_hr=((GetObjectFn)human->v[10])(human,&hand);if(home_hr>=0)home_hr=((PutBoolFn)hand->v[7])(hand,1);
    if(home_hr>=0){Sleep(250);home_hr=((GestureFn)hand->v[11])(hand,4);}
   }
   current_mode=get_mode();local_report("lease_active");if(presence_write_hr>=0)Sleep(30000);
  }
  if(presence_write_hr>=0)presence_restore_hr=((PutBoolFn)device2->v[7])(device2,previous_presence);
 }
 drop(tracker);drop(hand);drop(head);drop(human);drop(device2);drop(device);drop(manager);drop(sink);drop(simulation);
 if(mode_write_hr>=0&&set_mode)mode_restore_hr=set_mode(previous_mode);if(get_mode)current_mode=get_mode();
 if(previous_execution)restore_execution=SetThreadExecutionState(previous_execution);
 local_report(control?"finished":"inspect_only_no_stream");if(lib)FreeLibrary(lib);if(ro>=0)RoUninitialize();flush();ExitProcess(control&&presence_write_hr<0?2:0);
}
