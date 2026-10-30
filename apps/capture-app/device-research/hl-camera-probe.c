/* Foreground-context diagnostic. NEVER takes photos or reads camera frames.
 * --initialize requests video-only SHARED READ ONLY initialization, then closes.
 * The normal OS consent policy is unchanged. Default is activation-only inspection.
 * Common JSON/argument/COM helpers are reused; hl_uri_entry is never the entry point.
 */
#include "hl-uri-launch.c"
IMPORT HANDLE API GetCurrentProcess(void);
IMPORT BOOL API OpenProcessToken(HANDLE,DWORD,HANDLE*);
IMPORT BOOL API GetTokenInformation(HANDLE,int,void*,DWORD,DWORD*);
IMPORT long API GetCurrentPackageFullName(unsigned int*,WCHAR*);
IMPORT HANDLE API CreateEventW(void*,BOOL,BOOL,const WCHAR*);
IMPORT HRESULT API CoWaitForMultipleHandles(DWORD,DWORD,ULONG,HANDLE*,DWORD*);
static const GUID capture_iid={0xc61afbb4,0xfb10,0x4a34,{0xac,0x18,0xca,0x80,0xd9,0xc8,0xe7,0xee}};
static const GUID settings_iid={0x9782ba70,0xea65,0x4900,{0x93,0x56,0x8c,0xa8,0x87,0x72,0x68,0x84}};
static const GUID settings5_iid={0xd5a2e3b8,0x2626,0x4e94,{0xb7,0xb3,0x53,0x08,0xa0,0xf6,0x4b,0x1a}};
static const GUID closable_iid={0x30d5a829,0x7fa4,0x4026,{0x83,0xbb,0xd7,0x5b,0xae,0x4e,0xa9,0x9e}};
typedef HRESULT(API *PutIntFn)(Object*,int);
typedef HRESULT(API *InitCaptureFn)(Object*,Object*,Object**);
typedef HRESULT(API *ActionResultFn)(Object*);
static WCHAR current_package[512];
static HRESULT activate_as(const WCHAR *name,const GUID *iid,Object **out){HSTRING h=0;Object *instance=0;HRESULT hr=WindowsCreateString(name,wide_len(name),&h);if(hr>=0)hr=RoActivateInstance(h,(void**)&instance);if(h)WindowsDeleteString(h);if(hr>=0)hr=((QueryInterfaceFn)instance->v[0])(instance,iid,out);release(instance);return hr;}
void API hl_camera_probe_entry(void){
    Object *capture=0,*settings=0,*settings5=0,*action=0,*async=0,*closable=0;
    HANDLE report=0,token=0,event=0;const WCHAR *out=0;
    const char *reason="inspect_only";int initialize=0,valid=1,initialized=0,status=-1,exclusive=0;
    DWORD user_length=512,sent=0,app_container=0,token_bytes=0,output_error=0,exit_code=0,wait_index=0;
    unsigned int package_length=512;
    long package_error=GetCurrentPackageFullName(&package_length,current_package);
    BOOL token_known=OpenProcessToken(GetCurrentProcess(),8,&token)&&GetTokenInformation(token,29,&app_container,4,&token_bytes);
    if(token)CloseHandle(token);
    U64 start=GetTickCount64();
    HRESULT hr_ro=(HRESULT)0x8000000A,hr_capture=(HRESULT)0x8000000A,hr_settings=(HRESULT)0x8000000A,hr_mode=(HRESULT)0x8000000A,hr_shared=(HRESULT)0x8000000A,hr_initialize=(HRESULT)0x8000000A,hr_async=(HRESULT)0x8000000A,hr_result=(HRESULT)0x8000000A,hr_close=(HRESULT)0x8000000A,async_error=0;
    if(!parse_args())valid=0;
    for(int i=1;valid&&i<argc;i++){
        if(equal_ascii(args[i],"--initialize"))initialize=1;
        else if(equal_ascii(args[i],"--exclusive"))exclusive=1;
        else if(equal_ascii(args[i],"--out")&&!out&&i+1<argc){out=args[++i];if(!allowed_output(out))valid=0;}
        else valid=0;
    }
    if(!valid){reason="invalid_arguments";exit_code=64;goto done;}
    if(out){report=CreateFileW(out,0x40000000,1,0,1,0x80,0);if(report==(HANDLE)(U64)-1){report=0;output_error=GetLastError();reason="output_create_failed_no_camera_initialization";exit_code=3;goto done;}}
    hr_ro=RoInitialize(0); /* STA, preserving the public API's first-use requirement. */
    if(hr_ro<0){reason="ro_initialize_failed";exit_code=2;goto done;}
    hr_capture=activate_as((const WCHAR*)L"Windows.Media.Capture.MediaCapture",&capture_iid,&capture);
    if(hr_capture<0){reason="capture_class_unavailable";exit_code=2;goto done;}
    if(!initialize)goto done;
    hr_settings=activate_as((const WCHAR*)L"Windows.Media.Capture.MediaCaptureInitializationSettings",&settings_iid,&settings);
    if(hr_settings<0){reason="settings_unavailable";exit_code=2;goto done;}
    hr_mode=((PutIntFn)settings->v[10])(settings,2); /* StreamingCaptureMode.Video, NOT audio. */
    if(hr_mode<0){reason="video_only_setting_failed";exit_code=2;goto done;}
    hr_shared=((QueryInterfaceFn)settings->v[0])(settings,&settings5_iid,&settings5);
    if(hr_shared>=0)hr_shared=((PutIntFn)settings5->v[9])(settings5,exclusive?0:1);
    if(hr_shared<0){reason="shared_read_only_unavailable_no_initialization";exit_code=2;goto done;}
    hr_initialize=((InitCaptureFn)capture->v[7])(capture,settings,&action);
    if(hr_initialize<0){reason="initialization_request_failed";exit_code=2;goto done;}
    hr_async=((QueryInterfaceFn)action->v[0])(action,&async_info_iid,&async);
    if(hr_async<0){reason="async_info_failed";exit_code=2;goto done;}
    event=CreateEventW(0,0,0,0);
    do{
        HRESULT checked=((StatusFn)async->v[7])(async,&status);
        if(checked<0){hr_async=checked;reason="status_failed";exit_code=2;goto done;}
        if(status!=0)break;
        if(event)CoWaitForMultipleHandles(24,20,1,&event,&wait_index);else Sleep(20);
    }while(GetTickCount64()-start<8000);
    if(status==0){((CancelFn)async->v[9])(async);reason="initialization_deadline";exit_code=2;goto done;}
    if(status!=1){((ErrorFn)async->v[8])(async,&async_error);reason="initialization_failed";exit_code=2;goto done;}
    hr_result=((ActionResultFn)action->v[8])(action);initialized=hr_result>=0;
    reason=initialized?"shared_initialization_succeeded_no_photo_taken":"initialization_result_failed";
done:
    if(capture){hr_close=((QueryInterfaceFn)capture->v[0])(capture,&closable_iid,&closable);if(hr_close>=0)hr_close=((ActionResultFn)closable->v[6])(closable);}
    release(closable);release(async);release(action);release(settings5);release(settings);release(capture);
    if(event)CloseHandle(event);if(hr_ro>=0)RoUninitialize();
    text("{\"probeVersion\":1,\"processId\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(user,&user_length))json_wide(user);else text("null");
    text(",\"appContainer\":");if(token_known)text(app_container?"true":"false");else text("null");text(",\"packageIdentityError\":");number((DWORD)package_error);text(",\"packageIdentity\":");json_wide(package_error?0:current_package);
    text(",\"initializationRequested\":");text(initialize?"true":"false");text(",\"initialized\":");text(initialized?"true":"false");text(",\"photoTaken\":false,\"framesRead\":0,\"streamingMode\":\"video_only\",\"sharingMode\":");json_string(exclusive?"exclusive_control":"shared_read_only");text(",\"stages\":{\"roInitialize\":");hex_hr(hr_ro);text(",\"captureActivation\":");hex_hr(hr_capture);text(",\"settingsActivation\":");hex_hr(hr_settings);text(",\"videoMode\":");hex_hr(hr_mode);text(",\"sharedMode\":");hex_hr(hr_shared);text(",\"initializeRequest\":");hex_hr(hr_initialize);text(",\"asyncInfo\":");hex_hr(hr_async);text(",\"getResults\":");hex_hr(hr_result);text(",\"asyncError\":");hex_hr(async_error);text(",\"close\":");hex_hr(hr_close);text("},\"reason\":");json_string(reason);text(",\"elapsedMs\":");number(GetTickCount64()-start);text(",\"outputCreateError\":");number(output_error);text(",\"scope\":\"No photo, no frames, no network or permission changes. Initialization only when explicit.\"}\n");
    if(report){if(!WriteFile(report,output,used,&sent,0)||sent!=used)exit_code=3;CloseHandle(report);}WriteFile(GetStdHandle((DWORD)-11),output,used,&sent,0);ExitProcess(exit_code);
}
