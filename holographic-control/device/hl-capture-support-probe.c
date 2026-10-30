/* Query screen-capture support only. No picker, capture item, capture session,
 * camera/microphone access, simulation input, settings, or security changes. */
#define perception_probe_entry unused_capture_perception_entry
#include "hl-perception-probe.c"
#undef perception_probe_entry
IMPORT WCHAR* API GetCommandLineW(void);
IMPORT HRESULT API WindowsCreateString(const WCHAR*,DWORD,void**);
IMPORT HRESULT API WindowsDeleteString(void*);
IMPORT HRESULT API RoGetActivationFactory(void*,const GUID*,void**);
#include "../../native/hl-report-path.h"

/* Windows SDK26100 windows.graphics.capture.h: IGraphicsCaptureSessionStatics,
 * IInspectable(6 slots) followed by HRESULT IsSupported(boolean*). */
static const GUID capture_statics_iid={0x2224a540,0x5974,0x49aa,{0xb2,0x32,0x08,0x82,0x53,0x6f,0x4c,0xb5}};
typedef HRESULT (API *CaptureSupportedFn)(Object*,BYTE*);
_Static_assert(sizeof(GUID)==16,"WinRT GUID ABI");

void API capture_support_probe_entry(void){
 const WCHAR*path=0;
 if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\capture-support.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&path))ExitProcess(64);
 HANDLE file=CreateFileW(path,0x40000000,1,0,1,0x80,0);if(file==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);
 static const WCHAR name[]=L"Windows.Graphics.Capture.GraphicsCaptureSession";
 HRESULT ro=RoInitialize(1),string_hr=(HRESULT)0x8000000A,factory_hr=(HRESULT)0x8000000A,support_hr=(HRESULT)0x8000000A;
 void*class_name=0;Object*factory=0;BYTE supported=0;
 if(ro>=0){
  string_hr=WindowsCreateString(name,sizeof(name)/sizeof(name[0])-1,&class_name);
  if(string_hr>=0)factory_hr=RoGetActivationFactory(class_name,&capture_statics_iid,(void**)&factory);
  if(factory_hr>=0&&factory)support_hr=((CaptureSupportedFn)factory->v[6])(factory,&supported);
 }
 DWORD user_length=512;
 text("{\"schema_version\":1,\"readonly\":true,\"inputSent\":false,\"pickerOpened\":false,\"captureStarted\":false,\"processId\":");number(GetCurrentProcessId());
 text(",\"user\":");if(GetUserNameW(wide_buffer,&user_length))json_wide(wide_buffer);else text("null");
 text(",\"roInitialize\":");hex_result(ro);text(",\"classString\":");hex_result(string_hr);text(",\"activationFactory\":");hex_result(factory_hr);text(",\"isSupportedResult\":");hex_result(support_hr);
 text(",\"supported\":");text(support_hr>=0?(supported?"true":"false"):"null");text("}\n");
 drop(factory);if(class_name)WindowsDeleteString(class_name);if(ro>=0)RoUninitialize();
 DWORD written=0;BOOL saved=WriteFile(file,output,output_used,&written,0)&&written==output_used;CloseHandle(file);flush();ExitProcess(saved?0:4);
}
