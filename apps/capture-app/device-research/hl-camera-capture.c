/* Explicit, one-exposure MediaCapture worker for the paired eye.
 * Public ABI from Windows SDK headers. No audio, network, history or permission changes.
 * A CREATE_NEW attempt marker survives errors/restarts. No automatic retry.
 * Output stays in this application's own developer layout for USB retrieval.
 */
#include "hl-camera-probe.c"
IMPORT BOOL API CreateDirectoryW(const WCHAR*,void*);
IMPORT DWORD API GetFileAttributesW(const WCHAR*);
IMPORT DWORD API GetEnvironmentVariableW(const WCHAR*,WCHAR*,DWORD);
IMPORT BOOL API ReadFile(HANDLE,void*,DWORD,DWORD*,void*);
IMPORT BOOL API MoveFileExW(const WCHAR*,const WCHAR*,DWORD);
IMPORT long API BCryptOpenAlgorithmProvider(HANDLE*,const WCHAR*,const WCHAR*,DWORD);
IMPORT long API BCryptGetProperty(HANDLE,const WCHAR*,BYTE*,DWORD,DWORD*,DWORD);
IMPORT long API BCryptCreateHash(HANDLE,HANDLE*,BYTE*,DWORD,BYTE*,DWORD,DWORD);
IMPORT long API BCryptHashData(HANDLE,BYTE*,DWORD,DWORD);
IMPORT long API BCryptFinishHash(HANDLE,BYTE*,DWORD,DWORD);
IMPORT long API BCryptDestroyHash(HANDLE);
IMPORT long API BCryptCloseAlgorithmProvider(HANDLE,DWORD);
typedef HRESULT(API *FilePathFn)(Object*,HSTRING,Object**);
typedef HRESULT(API *CreateJpegFn)(Object*,Object**);
typedef HRESULT(API *PhotoFileFn)(Object*,Object*,Object*,Object**);
typedef HRESULT(API *BoxUIntFn)(Object*,DWORD,Object**);
typedef HRESULT(API *BoxBoolFn)(Object*,BYTE,Object**);
typedef HRESULT(API *MapInsertFn)(Object*,HSTRING,Object*,BYTE*);
typedef HRESULT(API *AddEffectFn)(Object*,int,HSTRING,Object*,Object**);
static const GUID file_statics_iid={0x5984c710,0xdaf2,0x43c8,{0x8b,0xb4,0xa4,0xd3,0xea,0xcf,0xd0,0x3f}};
static const GUID jpeg_statics_iid={0x257c68dc,0x8b99,0x439e,{0xaa,0x59,0x91,0x3a,0x36,0x16,0x12,0x97}};
static const GUID propertyset_iid={0x8a43ed9f,0xf4e6,0x4421,{0xac,0xf9,0x1d,0xab,0x29,0x86,0x82,0x0c}};
static const GUID map_iid={0x1b0d3570,0x0877,0x5ec2,{0x8a,0x2c,0x3b,0x95,0x39,0x50,0x6a,0xca}};
static const GUID propertyvalue_statics_iid={0x629bdbc8,0xd932,0x4ff4,{0x96,0xb9,0x8d,0x96,0xc5,0xc1,0xe8,0x58}};
static const WCHAR app_layout[]=L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensCaptureV1";
static WCHAR run_directory[2048],partial_path[2048],photo_path[2048],meta_path[2048],native_state_path[2048],lock_path[2048],own_state_path[2048],request_id[128];
static BYTE hash_object[4096],file_buffer[65536],digest[32];
static char image_hash[65];static U64 image_bytes;static const WCHAR *capture_run;
static int mrc_requested,mrc_applied;
static unsigned int slen(const WCHAR *s){return wide_len(s);}
static int add_path(WCHAR *d,const WCHAR *s){unsigned int n=slen(d),m=slen(s);if(n+m>=2048)return 0;for(unsigned int i=0;i<=m;i++)d[n+i]=s[i];return 1;}
static void path_set(WCHAR *d,const WCHAR *s){d[0]=0;add_path(d,s);}
static void path_file(WCHAR *d,const WCHAR *name){path_set(d,run_directory);add_path(d,(const WCHAR*)L"\\");add_path(d,name);}
static void id_number(U64 v){WCHAR b[24];int n=0;do{b[n++]=(WCHAR)('0'+v%10);v/=10;}while(v);unsigned int at=slen(request_id);while(n)request_id[at++]=b[--n];request_id[at]=0;}
static int safe_run(const WCHAR *s){unsigned int n=slen(s);if(!n||n>64)return 0;for(unsigned int i=0;i<n;i++)if(!((s[i]>='a'&&s[i]<='z')||(s[i]>='A'&&s[i]<='Z')||(s[i]>='0'&&s[i]<='9')||s[i]=='-'||s[i]=='_'))return 0;return 1;}
static DWORD make_directory(const WCHAR *p){if(CreateDirectoryW(p,0))return 0;DWORD e=GetLastError();return e==183&&(GetFileAttributesW(p)&16)?0:e;}
static DWORD write_new(const WCHAR *p){DWORD sent=0;HANDLE f=CreateFileW(p,0x40000000,1,0,1,0x80,0);if(f==(HANDLE)(U64)-1)return GetLastError();BOOL ok=WriteFile(f,output,used,&sent,0);DWORD e=!ok?GetLastError():(sent==used?0:29);CloseHandle(f);return e;}
static HRESULT await_action(Object *op,DWORD budget){
    Object *info=0;HRESULT hr=((QueryInterfaceFn)op->v[0])(op,&async_info_iid,&info);if(hr<0)return hr;
    HANDLE e=CreateEventW(0,0,0,0);U64 begin=GetTickCount64();int status=0;DWORD index=0;
    do{hr=((StatusFn)info->v[7])(info,&status);if(hr<0||status!=0)break;if(e)CoWaitForMultipleHandles(24,20,1,&e,&index);else Sleep(20);}while(GetTickCount64()-begin<budget);
    if(hr>=0&&status==0){((CancelFn)info->v[9])(info);hr=(HRESULT)0x800705B4;}
    else if(hr>=0&&status!=1){((ErrorFn)info->v[8])(info,&hr);if(hr>=0)hr=(HRESULT)0x80004004;}
    if(e)CloseHandle(e);release(info);return hr;
}
static HRESULT insert_mrc_value(Object *map,Object *statics,const WCHAR *key_text,DWORD value,int boolean_value){
    HSTRING key=0;Object *boxed=0;BYTE replaced=0;HRESULT hr=WindowsCreateString(key_text,slen(key_text),&key);
    if(hr>=0)hr=boolean_value?((BoxBoolFn)statics->v[17])(statics,(BYTE)value,&boxed):((BoxUIntFn)statics->v[11])(statics,value,&boxed);
    if(hr>=0)hr=((MapInsertFn)map->v[10])(map,key,boxed,&replaced);
    release(boxed);if(key)WindowsDeleteString(key);return hr;
}
static HRESULT enable_mrc(Object *capture){
    Object *properties=0,*map=0,*statics=0,*operation=0;HSTRING effect_name=0;
    const WCHAR *effect_text=(const WCHAR*)L"Windows.Media.MixedRealityCapture.MixedRealityCaptureVideoEffect";
    HRESULT hr=activate_as((const WCHAR*)L"Windows.Foundation.Collections.PropertySet",&propertyset_iid,&properties);
    if(hr>=0)hr=((QueryInterfaceFn)properties->v[0])(properties,&map_iid,&map);
    if(hr>=0)hr=factory((const WCHAR*)L"Windows.Foundation.PropertyValue",&propertyvalue_statics_iid,&statics);
    if(hr>=0)hr=insert_mrc_value(map,statics,(const WCHAR*)L"StreamType",3,0);
    if(hr>=0)hr=insert_mrc_value(map,statics,(const WCHAR*)L"PreferredHologramPerspective",0,0);
    if(hr>=0)hr=insert_mrc_value(map,statics,(const WCHAR*)L"HologramCompositionEnabled",1,1);
    if(hr>=0)hr=insert_mrc_value(map,statics,(const WCHAR*)L"RecordingIndicatorEnabled",1,1);
    if(hr>=0)hr=WindowsCreateString(effect_text,slen(effect_text),&effect_name);
    if(hr>=0)hr=((AddEffectFn)capture->v[15])(capture,3,effect_name,properties,&operation);
    if(hr>=0)hr=await_action(operation,5000);
    if(hr>=0)hr=((ActionResultFn)operation->v[8])(operation);
    if(effect_name)WindowsDeleteString(effect_name);release(operation);release(statics);release(map);release(properties);return hr;
}
static DWORD hash_jpeg(const WCHAR *path){
    HANDLE alg=0,hash=0,f=0;DWORD object_bytes=0,received=0,count=0,error=0;long status;
    status=BCryptOpenAlgorithmProvider(&alg,(const WCHAR*)L"SHA256",0,0);if(status<0)return (DWORD)status;
    status=BCryptGetProperty(alg,(const WCHAR*)L"ObjectLength",(BYTE*)&object_bytes,4,&received,0);
    if(status<0||object_bytes>sizeof(hash_object)){error=status<0?(DWORD)status:223;goto finish;}
    status=BCryptCreateHash(alg,&hash,hash_object,object_bytes,0,0,0);if(status<0){error=(DWORD)status;goto finish;}
    f=CreateFileW(path,0x80000000,1,0,3,0x80,0);if(f==(HANDLE)(U64)-1){f=0;error=GetLastError();goto finish;}
    image_bytes=0;
    for(;;){
        if(!ReadFile(f,file_buffer,sizeof(file_buffer),&count,0)){error=GetLastError();goto finish;}
        if(!count)break;
        if(image_bytes==0&&(count<2||file_buffer[0]!=0xff||file_buffer[1]!=0xd8)){error=13;goto finish;}
        image_bytes+=count;if(image_bytes>7*1024*1024){error=223;goto finish;}
        status=BCryptHashData(hash,file_buffer,count,0);if(status<0){error=(DWORD)status;goto finish;}
    }
    if(!image_bytes){error=13;goto finish;}
    status=BCryptFinishHash(hash,digest,32,0);if(status<0){error=(DWORD)status;goto finish;}
    static const char hex[]="0123456789abcdef";for(int i=0;i<32;i++){image_hash[2*i]=hex[digest[i]>>4];image_hash[2*i+1]=hex[digest[i]&15];}image_hash[64]=0;
finish:
    if(f)CloseHandle(f);if(hash)BCryptDestroyHash(hash);if(alg)BCryptCloseAlgorithmProvider(alg,0);return error;
}
static int prior_ui_attempt(void){
    unsigned int n=GetEnvironmentVariableW((const WCHAR*)L"LOCALAPPDATA",own_state_path,2048);if(!n||n>1600)return -1;
    add_path(own_state_path,(const WCHAR*)L"\\Packages\\Rice.HoloLens.Capture_r5420n6798s24\\LocalState\\single-shot\\");add_path(own_state_path,capture_run);add_path(own_state_path,(const WCHAR*)L"\\state.json");
    HANDLE f=CreateFileW(own_state_path,0x80000000,7,0,3,0x80,0);if(f==(HANDLE)(U64)-1){DWORD e=GetLastError();return e==2||e==3?0:-1;}
    DWORD bytes=0;BOOL ok=ReadFile(f,file_buffer,sizeof(file_buffer)-1,&bytes,0);CloseHandle(f);if(!ok)return -1;file_buffer[bytes]=0;
    const char marker[]="\"request_id\"";
    for(DWORD i=0;i<bytes;i++){DWORD j=0;while(marker[j]&&i+j<bytes&&file_buffer[i+j]==marker[j])j++;if(!marker[j])return 1;}
    return 0;
}
static void metadata_json(void){
    text("{\"run_id\":");json_wide(capture_run);text(",\"request_id\":");json_wide(request_id);text(",\"image_sha256\":");json_string(image_hash);text(",\"image_bytes\":");number(image_bytes);
    text(",\"filename\":\"photo.jpg\",\"content_type\":\"image/jpeg\",\"camera_closed\":true,\"capture_origin\":\"arm64-mediacapture\",\"photo_api_completed\":true,\"photo_attempts\":1,\"mrc_requested\":");text(mrc_requested?"true":"false");text(",\"mrc_effect_applied\":");text(mrc_applied?"true":"false");chr('}');
}
void API hl_camera_capture_entry(void){
    const WCHAR *report_path=0;const char *reason="not_started";int explicit_capture=0,valid=1,photo_attempts=0,photo_completed=0,closed=0;DWORD error=0,exit_code=0,user_length=512,sent=0;
    HANDLE report=0,temporary=0,lock=0;U64 started=GetTickCount64();
    Object *capture=0,*settings=0,*settings5=0,*init=0,*file_factory=0,*file_operation=0,*storage_file=0,*jpeg_factory=0,*jpeg=0,*photo_action=0,*closable=0;
    HRESULT hr_ro=(HRESULT)0x8000000A,hr_init=(HRESULT)0x8000000A,hr_file=(HRESULT)0x8000000A,hr_jpeg=(HRESULT)0x8000000A,hr_photo=(HRESULT)0x8000000A,hr_close=(HRESULT)0x8000000A,hr_mrc=(HRESULT)0x8000000A;HSTRING path_string=0;
    if(!parse_args())valid=0;
    for(int i=1;valid&&i<argc;i++){
        if(equal_ascii(args[i],"--capture"))explicit_capture=1;
        else if(equal_ascii(args[i],"--mrc"))mrc_requested=1;
        else if(equal_ascii(args[i],"--run")&&!capture_run&&i+1<argc)capture_run=args[++i];
        else if(equal_ascii(args[i],"--out")&&!report_path&&i+1<argc)report_path=args[++i];
        else valid=0;
    }
    if(!valid||!explicit_capture||!capture_run||!safe_run(capture_run)||!report_path||!allowed_output(report_path)){reason="explicit_capture_run_and_new_report_required";exit_code=64;goto done;}
    report=CreateFileW(report_path,0x40000000,1,0,1,0x80,0);if(report==(HANDLE)(U64)-1){report=0;error=GetLastError();reason="report_exists_or_unwritable_no_capture";exit_code=3;goto done;}
    if(prior_ui_attempt()!=0){reason="prior_ui_attempt_or_unknown_state_no_capture";exit_code=2;goto done;}
    path_set(run_directory,app_layout);add_path(run_directory,(const WCHAR*)L"\\native-shots");error=make_directory(run_directory);if(error)goto path_failed;
    add_path(run_directory,(const WCHAR*)L"\\");add_path(run_directory,capture_run);error=make_directory(run_directory);if(error)goto path_failed;
    path_file(partial_path,(const WCHAR*)L"photo.partial.jpg");path_file(photo_path,(const WCHAR*)L"photo.jpg");path_file(meta_path,(const WCHAR*)L"capture.json");path_file(native_state_path,(const WCHAR*)L"state-native.json");path_file(lock_path,(const WCHAR*)L"attempt.json");
    if(GetFileAttributesW(lock_path)!=(DWORD)-1||GetFileAttributesW(photo_path)!=(DWORD)-1||GetFileAttributesW(meta_path)!=(DWORD)-1){reason="existing_native_attempt_or_photo_no_capture";exit_code=2;goto done;}
    temporary=CreateFileW(partial_path,0x40000000,1,0,1,0x80,0);if(temporary==(HANDLE)(U64)-1){temporary=0;error=GetLastError();reason="partial_file_exists_or_unwritable_no_capture";exit_code=2;goto done;}CloseHandle(temporary);temporary=0;
    request_id[0]='h';request_id[1]='l';request_id[2]='-';request_id[3]='n';request_id[4]='-';request_id[5]=0;id_number(GetCurrentProcessId());add_path(request_id,(const WCHAR*)L"-");id_number(started);
    hr_ro=RoInitialize(0);if(hr_ro<0){reason="ro_initialize_failed";exit_code=2;goto done;}
    hr_init=activate_as((const WCHAR*)L"Windows.Media.Capture.MediaCapture",&capture_iid,&capture);
    if(hr_init>=0)hr_init=activate_as((const WCHAR*)L"Windows.Media.Capture.MediaCaptureInitializationSettings",&settings_iid,&settings);
    if(hr_init>=0)hr_init=((PutIntFn)settings->v[10])(settings,2);
    if(hr_init>=0)hr_init=((QueryInterfaceFn)settings->v[0])(settings,&settings5_iid,&settings5);
    if(hr_init>=0)hr_init=((PutIntFn)settings5->v[9])(settings5,0);
    if(hr_init>=0)hr_init=((InitCaptureFn)capture->v[7])(capture,settings,&init);
    if(hr_init>=0)hr_init=await_action(init,10000);
    if(hr_init>=0)hr_init=((ActionResultFn)init->v[8])(init);
    if(hr_init<0){reason="exclusive_camera_initialization_failed_no_photo";exit_code=2;goto done;}
    hr_file=factory((const WCHAR*)L"Windows.Storage.StorageFile",&file_statics_iid,&file_factory);
    if(hr_file>=0)hr_file=WindowsCreateString(partial_path,slen(partial_path),&path_string);
    if(hr_file>=0)hr_file=((FilePathFn)file_factory->v[6])(file_factory,path_string,&file_operation);
    if(hr_file>=0)hr_file=await_action(file_operation,5000);
    if(hr_file>=0)hr_file=((ObjectResultsFn)file_operation->v[8])(file_operation,&storage_file);
    if(hr_file<0){reason="new_storage_file_unavailable_no_photo";exit_code=2;goto done;}
    hr_jpeg=factory((const WCHAR*)L"Windows.Media.MediaProperties.ImageEncodingProperties",&jpeg_statics_iid,&jpeg_factory);
    if(hr_jpeg>=0)hr_jpeg=((CreateJpegFn)jpeg_factory->v[6])(jpeg_factory,&jpeg);
    if(hr_jpeg<0){reason="jpeg_encoder_unavailable_no_photo";exit_code=2;goto done;}
    if(mrc_requested){hr_mrc=enable_mrc(capture);mrc_applied=hr_mrc>=0;}
    lock=CreateFileW(lock_path,0x40000000,1,0,1,0x80,0);if(lock==(HANDLE)(U64)-1){lock=0;error=GetLastError();reason="attempt_already_reserved_no_new_capture";exit_code=2;goto done;}
    used=0;text("{\"run_id\":");json_wide(capture_run);text(",\"request_id\":");json_wide(request_id);text(",\"reserved_before_exposure\":true}\n");
    if(!WriteFile(lock,output,used,&sent,0)||sent!=used){error=GetLastError();reason="attempt_persistence_failed_no_photo";exit_code=2;goto done;}CloseHandle(lock);lock=0;
    Sleep(800);
    photo_attempts=1;
    hr_photo=((PhotoFileFn)capture->v[13])(capture,jpeg,storage_file,&photo_action); /* Exactly ONE exposure call. */
    if(hr_photo>=0)hr_photo=await_action(photo_action,15000);
    if(hr_photo>=0)hr_photo=((ActionResultFn)photo_action->v[8])(photo_action);
    photo_completed=hr_photo>=0;
    reason=photo_completed?"photo_api_completed":"photo_api_failed_attempt_retained";if(!photo_completed)exit_code=2;
    goto done;
path_failed:
    reason="own_native_directory_unavailable_no_photo";exit_code=2;
done:
    if(capture){hr_close=((QueryInterfaceFn)capture->v[0])(capture,&closable_iid,&closable);if(hr_close>=0)hr_close=((ActionResultFn)closable->v[6])(closable);closed=hr_close>=0;}
    release(closable);release(photo_action);release(jpeg);release(jpeg_factory);release(storage_file);release(file_operation);release(file_factory);release(init);release(settings5);release(settings);release(capture);
    if(path_string)WindowsDeleteString(path_string);if(hr_ro>=0)RoUninitialize();if(temporary)CloseHandle(temporary);if(lock)CloseHandle(lock);
    if(photo_completed&&closed){
        error=hash_jpeg(partial_path);
        if(!error&&!MoveFileExW(partial_path,photo_path,8))error=GetLastError();
        if(!error){used=0;metadata_json();error=write_new(meta_path);}
        if(!error){used=0;text("{\"schema_version\":1,\"run_id\":");json_wide(capture_run);text(",\"phase\":\"waiting_for_result\",\"runtime\":\"winrt-media-capture\",\"capture_origin\":\"arm64-mediacapture\",\"photo\":");metadata_json();text("}\n");error=write_new(native_state_path);}
        if(error){reason="new_photo_retained_but_publish_failed_no_retry";exit_code=2;}else reason="single_new_photo_saved_camera_closed";
    }
    used=0;text("{\"workerVersion\":1,\"processId\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(user,&user_length))json_wide(user);else text("null");text(",\"run_id\":");json_wide(capture_run);text(",\"request_id\":");json_wide(request_id);text(",\"photoAttempts\":");number(photo_attempts);text(",\"photoApiCompleted\":");text(photo_completed?"true":"false");text(",\"cameraClosed\":");text(closed?"true":"false");text(",\"photoPath\":");json_wide(photo_path);text(",\"image_sha256\":");json_string(image_hash);text(",\"image_bytes\":");number(image_bytes);text(",\"mrcRequested\":");text(mrc_requested?"true":"false");text(",\"mrcEffectApplied\":");text(mrc_applied?"true":"false");text(",\"stages\":{\"roInitialize\":");hex_hr(hr_ro);text(",\"initializeCamera\":");hex_hr(hr_init);text(",\"storageFile\":");hex_hr(hr_file);text(",\"jpegEncoding\":");hex_hr(hr_jpeg);text(",\"mrcEffect\":");hex_hr(hr_mrc);text(",\"capturePhoto\":");hex_hr(hr_photo);text(",\"closeCamera\":");hex_hr(hr_close);text("},\"win32OrHashError\":");number(error);text(",\"reason\":");json_string(reason);text(",\"elapsedMs\":");number(GetTickCount64()-started);text(",\"scope\":\"One current camera JPEG only; no audio, history, network, overwrite or automatic retries\"}\n");
    if(report){if(!WriteFile(report,output,used,&sent,0)||sent!=used)exit_code=3;CloseHandle(report);}WriteFile(GetStdHandle((DWORD)-11),output,used,&sent,0);ExitProcess(exit_code);
}
