/* Query the documented Win32 monitor-capture target. Never opens a picker or
 * starts capture, changes permissions, or sends input. Preserve API failures. */
#define capture_support_probe_entry unused_item_support_entry
#include "hl-capture-support-probe.c"
#undef capture_support_probe_entry
IMPORT const WCHAR* API WindowsGetStringRawBuffer(void*,DWORD*);
typedef HANDLE (API *CaptureDesktopFn)(void);
typedef HANDLE (API *CaptureMonitorFn)(HANDLE,DWORD);
typedef HRESULT (API *CaptureForMonitorFn)(Object*,HANDLE,const GUID*,void**);
typedef struct {int width,height;} CaptureSize;
typedef HRESULT (API *CaptureItemSizeFn)(Object*,CaptureSize*);
typedef HRESULT (API *CaptureItemNameFn)(Object*,void**);
static const GUID capture_interop_iid={0x3628e81b,0x3cac,0x4c60,{0xb7,0xf4,0x23,0xce,0x0e,0x0c,0x33,0x56}};
static const GUID capture_item_iid={0x79c3f95b,0x31f7,0x4ec2,{0xa4,0x64,0x63,0x2e,0xf5,0xd3,0x07,0x60}};
_Static_assert(sizeof(CaptureSize)==8,"SizeInt32 ABI");
void API capture_item_probe_entry(void){
 const WCHAR*path=0;
 if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\capture-item.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&path))ExitProcess(64);
 HANDLE file=CreateFileW(path,0x40000000,1,0,1,0x80,0);if(file==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);
 HANDLE user=LoadLibraryExW((const WCHAR*)L"MinUser.dll",0,0x800);DWORD load_error=user?0:GetLastError();
 CaptureDesktopFn get_desktop=user?(CaptureDesktopFn)GetProcAddress(user,"GetDesktopWindow"):0;
 CaptureMonitorFn get_monitor=user?(CaptureMonitorFn)GetProcAddress(user,"MonitorFromWindow"):0;
 HANDLE desktop=get_desktop?get_desktop():0;HANDLE monitor=get_monitor?get_monitor(desktop,1):0;
 DWORD monitor_error=get_monitor&&!monitor?GetLastError():0;
 HRESULT ro=RoInitialize(1),factory_hr=(HRESULT)0x8000000A,item_hr=(HRESULT)0x8000000A,size_hr=(HRESULT)0x8000000A,name_hr=(HRESULT)0x8000000A;
 Object*factory=0,*item=0;void*class_name=0,*display_name=0;CaptureSize size={0};
 static const WCHAR name[]=L"Windows.Graphics.Capture.GraphicsCaptureItem";
 if(ro>=0){HRESULT str=WindowsCreateString(name,sizeof(name)/sizeof(name[0])-1,&class_name);if(str>=0)factory_hr=RoGetActivationFactory(class_name,&capture_interop_iid,(void**)&factory);else factory_hr=str;}
 if(factory&&monitor)item_hr=((CaptureForMonitorFn)factory->v[4])(factory,monitor,&capture_item_iid,(void**)&item);
 if(item){size_hr=((CaptureItemSizeFn)item->v[7])(item,&size);name_hr=((CaptureItemNameFn)item->v[6])(item,&display_name);}
 DWORD n=512;text("{\"schema_version\":1,\"readonly\":true,\"inputSent\":false,\"pickerOpened\":false,\"captureStarted\":false,\"processId\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");
 text(",\"minUserLoadError\":");number(load_error);text(",\"desktopApiAvailable\":");text(get_desktop?"true":"false");text(",\"monitorApiAvailable\":");text(get_monitor?"true":"false");text(",\"desktopPresent\":");text(desktop?"true":"false");text(",\"monitorPresent\":");text(monitor?"true":"false");text(",\"monitorError\":");number(monitor_error);
 text(",\"roInitialize\":");hex_result(ro);text(",\"interopFactory\":");hex_result(factory_hr);text(",\"createForMonitor\":");hex_result(item_hr);text(",\"itemPresent\":");text(item?"true":"false");text(",\"getSize\":");hex_result(size_hr);text(",\"width\":");number((DWORD)size.width);text(",\"height\":");number((DWORD)size.height);text(",\"getDisplayName\":");hex_result(name_hr);text(",\"displayName\":");if(name_hr>=0&&display_name)json_wide(WindowsGetStringRawBuffer(display_name,0));else text("null");text("}\n");
 if(display_name)WindowsDeleteString(display_name);drop(item);drop(factory);if(class_name)WindowsDeleteString(class_name);if(ro>=0)RoUninitialize();if(user)FreeLibrary(user);
 DWORD written=0;BOOL saved=WriteFile(file,output,output_used,&written,0)&&written==output_used;CloseHandle(file);flush();ExitProcess(saved?0:4);
}
