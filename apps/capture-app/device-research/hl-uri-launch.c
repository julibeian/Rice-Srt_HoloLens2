/* Public WinRT URI launcher. No camera, networking, elevation or registry calls.
 * ABI checked against SDK 10.0.26100.0 winrt/windows.system.h,
 * windows.foundation.h and AsyncInfo.h. --inspect never activates a URI.
 */
typedef unsigned char BYTE;
typedef unsigned short WCHAR;
typedef unsigned long DWORD;
typedef unsigned long ULONG;
typedef long HRESULT;
typedef int BOOL;
typedef unsigned long long U64;
typedef void *HANDLE;
typedef void *HSTRING;
typedef struct { DWORD a; unsigned short b,c; BYTE d[8]; } GUID;
#define IMPORT __declspec(dllimport)
#define API __stdcall
IMPORT WCHAR *API GetCommandLineW(void);
IMPORT DWORD API GetCurrentProcessId(void);
IMPORT BOOL API GetUserNameW(WCHAR*,DWORD*);
IMPORT DWORD API GetLastError(void);
IMPORT HANDLE API GetStdHandle(DWORD);
IMPORT BOOL API WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT BOOL API CloseHandle(HANDLE);
IMPORT int API WideCharToMultiByte(unsigned int,DWORD,const WCHAR*,int,char*,int,const char*,BOOL*);
IMPORT U64 API GetTickCount64(void);
IMPORT void API Sleep(DWORD);
IMPORT void API ExitProcess(DWORD);
IMPORT HRESULT API RoInitialize(unsigned int);
IMPORT void API RoUninitialize(void);
IMPORT HRESULT API RoGetActivationFactory(HSTRING,const GUID*,void**);
IMPORT HRESULT API WindowsCreateString(const WCHAR*,unsigned int,HSTRING*);
IMPORT HRESULT API WindowsDeleteString(HSTRING);
IMPORT HRESULT API CoCreateInstance(const GUID*,void*,DWORD,const GUID*,void**);
IMPORT HRESULT API RoActivateInstance(HSTRING,void**);

typedef struct Object { void **v; } Object;
IMPORT HRESULT API CoAllowSetForegroundWindow(Object*,void*);
typedef HRESULT (API *QueryInterfaceFn)(Object*,const GUID*,Object**);
typedef ULONG (API *ReleaseFn)(Object*);
typedef HRESULT (API *CreateUriFn)(Object*,HSTRING,Object**);
typedef HRESULT (API *LaunchUriFn)(Object*,Object*,Object**);
typedef HRESULT (API *StatusFn)(Object*,int*);
typedef HRESULT (API *ErrorFn)(Object*,HRESULT*);
typedef HRESULT (API *CancelFn)(Object*);
typedef HRESULT (API *ResultsFn)(Object*,BYTE*);
typedef HRESULT (API *ActivateAppFn)(Object*,const WCHAR*,const WCHAR*,DWORD,DWORD*);
typedef HRESULT (API *PutStringFn)(Object*,HSTRING);
typedef HRESULT (API *LaunchModalFn)(Object*,Object*,Object*,Object**);
typedef HRESULT (API *ObjectResultsFn)(Object*,Object**);
typedef HRESULT (API *IntResultFn)(Object*,int*);
static const GUID app_activation_clsid={0x45ba127d,0x10a8,0x46ea,{0x8a,0xb7,0x56,0xea,0x90,0x78,0x94,0x3c}};
static const GUID app_activation_iid={0x2e941141,0x7f97,0x4756,{0xba,0x1d,0x9d,0xec,0xde,0x89,0x4a,0x3d}};
static const GUID launcher2_iid={0x59ba2fbb,0x24cb,0x4c02,{0xa4,0xc4,0x82,0x94,0x56,0x9d,0x54,0xf1}};
static const GUID options2_iid={0x3ba08eb4,0x6e40,0x4dce,{0xa1,0xa3,0x2f,0x53,0x95,0x0a,0xfb,0x49}};
static const GUID options_iid={0xbafa21d8,0xb071,0x4cd8,{0x85,0x3e,0x34,0x12,0x03,0xe5,0x57,0xd3}};

static const GUID uri_factory_iid={0x44a9796f,0x723e,0x4fdf,{0xa2,0x18,0x03,0x3e,0x75,0xb0,0xc0,0x84}};
static const GUID launcher_iid={0x277151c3,0x9e3e,0x42f6,{0x91,0xa4,0x5d,0xfd,0xeb,0x23,0x24,0x51}};
static const GUID async_info_iid={0x00000036,0x0000,0x0000,{0xc0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};
static WCHAR args[8][2048], user[512];
static char utf8[8192], output[32768];
static DWORD used;
static int argc;

static unsigned int wide_len(const WCHAR *s){unsigned int n=0;while(s&&s[n])n++;return n;}
static int equal_ascii(const WCHAR *s,const char *v){while(*v){if(*s++!=(BYTE)*v++)return 0;}return *s==0;}
static int prefix_ascii(const WCHAR *s,const char *v){while(*v){if(*s++!=(BYTE)*v++)return 0;}return 1;}
static int parse_args(void){
    const WCHAR *p=GetCommandLineW();int quote,n;
    while(*p){
        while(*p==' '||*p=='\t')p++;
        if(!*p)break;
        if(argc==8)return 0;
        n=0;quote=0;
        while(*p&&(quote||(*p!=' '&&*p!='\t'))){
            if(*p=='"'){quote=!quote;p++;continue;}
            if(n==2047)return 0;
            args[argc][n++]=*p++;
        }
        if(quote)return 0;
        args[argc++][n]=0;
    }
    return argc>0;
}
static int allowed_uri(const WCHAR *uri){
#if defined(HL_FIXED_DEVELOPER_SETTINGS)
    return uri&&equal_ascii(uri,"ms-settings:developers");
#else
    unsigned int i,start;
    int own_app;
    if(!uri)return 0;
    own_app=equal_ascii(uri,"rice-hololens-capture://open");
    if(!own_app&&!prefix_ascii(uri,"https://rice-srt.cn/hololens/")&&
       !prefix_ascii(uri,"microsoft-edge:https://rice-srt.cn/hololens/"))return 0;
    for(i=0;uri[i];i++)if(uri[i]<=32||uri[i]=='"'||uri[i]=='\\'||uri[i]==127)return 0;
    if(own_app)return 1;
    start=prefix_ascii(uri,"https://")?8:23;
    for(i=start;uri[i]&&uri[i]!='?'&&uri[i]!='#';i++){
        /* Canonicalization must not move an allowed URI outside /hololens/. */
        if(uri[i]=='%')return 0;
        if(uri[i]=='/'&&uri[i+1]=='.'){
            unsigned int j=i+2;
            if(uri[j]=='.')j++;
            if(uri[j]=='/'||uri[j]=='?'||uri[j]=='#'||uri[j]==0)return 0;
        }
    }
    return 1;
#endif
}
static int allowed_output(const WCHAR *path){
    unsigned int n=wide_len(path);
    if(n<8||!((path[0]>='A'&&path[0]<='Z')||(path[0]>='a'&&path[0]<='z'))||
       path[1]!=':'||path[2]!='\\')return 0;
    return path[n-5]=='.'&&path[n-4]=='j'&&path[n-3]=='s'&&path[n-2]=='o'&&path[n-1]=='n';
}
static void chr(char c){if(used<sizeof(output))output[used++]=c;}
static void text(const char *s){while(*s)chr(*s++);}
static void number(U64 value){char digits[24];int n=0;do{digits[n++]=(char)('0'+value%10);value/=10;}while(value);while(n)chr(digits[--n]);}
static void json_string(const char *s){
    static const char hex[]="0123456789abcdef";chr('"');
    while(*s){BYTE c=(BYTE)*s++;if(c=='"'||c=='\\'){chr('\\');chr((char)c);}
        else if(c<32){text("\\u00");chr(hex[c>>4]);chr(hex[c&15]);}else chr((char)c);}
    chr('"');
}
static void json_wide(const WCHAR *s){
    if(!s){text("null");return;}
    if(WideCharToMultiByte(65001,0,s,-1,utf8,sizeof(utf8),0,0)>0)json_string(utf8);else text("null");
}
static void hex_hr(HRESULT hr){
    static const char digits[]="0123456789ABCDEF";DWORD value=(DWORD)hr;
    text("\"0x");for(int i=7;i>=0;i--)chr(digits[(value>>(i*4))&15]);chr('"');
}
static void release(Object *o){if(o)((ReleaseFn)o->v[2])(o);}
static HRESULT factory(const WCHAR *name,const GUID *iid,Object **out){
    HSTRING value=0;HRESULT hr=WindowsCreateString(name,wide_len(name),&value);
    if(hr>=0){hr=RoGetActivationFactory(value,iid,(void**)out);WindowsDeleteString(value);}return hr;
}

void API hl_uri_entry(void){
    const WCHAR *uri_text=0,*output_path=0;
    const char *reason="not_started";
    int inspect=0,valid=1,status=-1,ro_ok=0,attempted=0,complete=0,direct_app=0,modal_app=0,modal_result=-1,hold=0;
    BYTE launched=0;
    DWORD user_length=512,written=0,out_error=0,exit_code=0,activated_pid=0;
    HANDLE output_file=0;
    U64 start=GetTickCount64();
    HRESULT hr_ro=(HRESULT)0x8000000A,hr_uri_factory=(HRESULT)0x8000000A;
    HRESULT hr_create=(HRESULT)0x8000000A,hr_launcher=(HRESULT)0x8000000A;
    HRESULT hr_launch=(HRESULT)0x8000000A,hr_async=(HRESULT)0x8000000A;
    HRESULT hr_status=(HRESULT)0x8000000A,hr_result=(HRESULT)0x8000000A,async_error=0;
    HRESULT hr_foreground=(HRESULT)0x8000000A;
    Object *uri_factory=0,*uri=0,*launcher=0,*operation=0,*info=0,*options=0,*options2=0,*modal_response=0;
    HSTRING uri_string=0;
    if(!parse_args()){valid=0;reason="invalid_arguments";}
    for(int i=1;valid&&i<argc;i++){
        if(equal_ascii(args[i],"--inspect"))inspect=1;
        else if(equal_ascii(args[i],"--activate-app"))direct_app=1;
        else if(equal_ascii(args[i],"--modal-app"))modal_app=1;
        else if(equal_ascii(args[i],"--hold-60-seconds"))hold=1;
        else if(equal_ascii(args[i],"--out")){
            if(output_path||i+1>=argc){valid=0;reason="invalid_output_argument";break;}
            output_path=args[++i];
            if(!allowed_output(output_path)){valid=0;reason="output_requires_absolute_local_json_path";}
        }else if(!uri_text)uri_text=args[i];
        else{valid=0;reason="unexpected_argument";}
    }
    if(valid&&uri_text&&!allowed_uri(uri_text)){valid=0;reason="uri_not_allowed";}
    if(valid&&direct_app&&!equal_ascii(uri_text?uri_text:(const WCHAR*)L"","rice-hololens-capture://open")){valid=0;reason="direct_activation_only_own_registered_app";}
    if(valid&&modal_app&&(!equal_ascii(uri_text?uri_text:(const WCHAR*)L"","rice-hololens-capture://open")||direct_app)){valid=0;reason="modal_activation_only_own_registered_app";}
    if(valid&&hold&&!direct_app){valid=0;reason="activation_lease_only_own_registered_app";}
    if(valid&&!inspect&&!uri_text){valid=0;reason="uri_required";}
    if(valid&&output_path){
        output_file=CreateFileW(output_path,0x40000000,1,0,1,0x80,0); /* CREATE_NEW: no overwrites. */
        if(output_file==(HANDLE)(U64)-1){out_error=GetLastError();output_file=0;}
    }
    if(!valid){exit_code=64;goto report;}
    if(inspect){reason="inspect_only_no_activation";goto report;}
    attempted=1;
    hr_ro=RoInitialize(1); /* RO_INIT_MULTITHREADED. */
    if(hr_ro<0){reason="ro_initialize_failed";exit_code=1;goto report;}ro_ok=1;
    if(direct_app){
        hr_launcher=CoCreateInstance(&app_activation_clsid,0,4,&app_activation_iid,(void**)&launcher);
        if(hr_launcher<0){reason="app_activation_manager_unavailable";exit_code=1;goto report;}
        hr_foreground=CoAllowSetForegroundWindow(launcher,0);
        hr_launch=((ActivateAppFn)launcher->v[3])(launcher,(const WCHAR*)L"Rice.HoloLens.Capture_r5420n6798s24!Capture",(const WCHAR*)L"",0,&activated_pid);
        complete=hr_launch>=0;launched=complete&&activated_pid!=0;
        reason=launched?"own_app_activated":"own_app_activation_failed";exit_code=launched?0:2;goto report;
    }
    hr_uri_factory=factory((const WCHAR*)L"Windows.Foundation.Uri",&uri_factory_iid,&uri_factory);
    if(hr_uri_factory<0){reason="uri_factory_failed";exit_code=1;goto report;}
    hr_create=WindowsCreateString(uri_text,wide_len(uri_text),&uri_string);
    if(hr_create>=0)hr_create=((CreateUriFn)uri_factory->v[6])(uri_factory,uri_string,&uri);
    if(hr_create<0){reason="uri_creation_failed";exit_code=1;goto report;}
    hr_launcher=factory((const WCHAR*)L"Windows.System.Launcher",modal_app?&launcher2_iid:&launcher_iid,&launcher);
    if(hr_launcher<0){reason="launcher_factory_failed";exit_code=1;goto report;}
    if(modal_app){
        Object *options_instance=0;
        HSTRING class_name=0,package_name=0;
        const WCHAR *class_text=(const WCHAR*)L"Windows.System.LauncherOptions";
        const WCHAR *package_text=(const WCHAR*)L"Rice.HoloLens.Capture_r5420n6798s24";
        hr_launch=WindowsCreateString(class_text,wide_len(class_text),&class_name);
        if(hr_launch>=0)hr_launch=RoActivateInstance(class_name,(void**)&options_instance);
        if(hr_launch>=0)hr_launch=((QueryInterfaceFn)options_instance->v[0])(options_instance,&options_iid,&options);
        release(options_instance);
        if(class_name)WindowsDeleteString(class_name);
        if(hr_launch>=0)hr_launch=((QueryInterfaceFn)options->v[0])(options,&options2_iid,&options2);
        if(hr_launch>=0)hr_launch=WindowsCreateString(package_text,wide_len(package_text),&package_name);
        if(hr_launch>=0)hr_launch=((PutStringFn)options2->v[7])(options2,package_name);
        if(package_name)WindowsDeleteString(package_name);
        if(hr_launch>=0)hr_launch=((LaunchModalFn)launcher->v[6])(launcher,uri,options,&operation);
    }else hr_launch=((LaunchUriFn)launcher->v[8])(launcher,uri,&operation);
    if(hr_launch<0){reason="launch_request_failed";exit_code=1;goto report;}
    hr_async=((QueryInterfaceFn)operation->v[0])(operation,&async_info_iid,&info);
    if(hr_async<0){reason="async_info_failed";exit_code=1;goto report;}
    do{
        hr_status=((StatusFn)info->v[7])(info,&status);
        if(hr_status<0||status!=0)break;
        Sleep(20);
    }while(GetTickCount64()-start<(modal_app?60000:10000));
    if(hr_status<0){reason="async_status_failed";exit_code=1;goto report;}
    if(status==0){((CancelFn)info->v[9])(info);async_error=(HRESULT)0x800705B4;reason=modal_app?"modal_observation_deadline_no_completion_claim":"launch_timeout";exit_code=1;goto report;}
    if(status!=1){((ErrorFn)info->v[8])(info,&async_error);reason="launch_canceled_or_failed";exit_code=1;goto report;}
    complete=1;
    if(modal_app){
        hr_result=((ObjectResultsFn)operation->v[8])(operation,&modal_response);
        if(hr_result>=0)hr_result=((IntResultFn)modal_response->v[6])(modal_response,&modal_result);
        launched=hr_result>=0&&modal_result==0;
    }else hr_result=((ResultsFn)operation->v[8])(operation,&launched);
    if(hr_result<0){reason="launch_result_failed";exit_code=1;goto report;}
    reason=launched?"uri_activation_accepted":"uri_activation_rejected";
    exit_code=launched?0:2;
report:
    release(modal_response);release(options2);release(options);release(info);release(operation);release(uri);release(uri_factory);
    if(uri_string)WindowsDeleteString(uri_string);
    text("{\"helperVersion\":1,\"inspectOnly\":");text(inspect?"true":"false");
    text(",\"processId\":");number(GetCurrentProcessId());
    text(",\"user\":");if(GetUserNameW(user,&user_length))json_wide(user);else text("null");
#if defined(_M_ARM64) || defined(__aarch64__)
    text(",\"architecture\":\"arm64\"");
#else
    text(",\"architecture\":\"x64\"");
#endif
    text(",\"uri\":");json_wide(uri_text);
    text(",\"allowedUri\":");text(allowed_uri(uri_text)?"true":"false");
    text(",\"activationAttempted\":");text(attempted?"true":"false");
    text(",\"operationCompleted\":");text(complete?"true":"false");
    text(",\"launchAccepted\":");text(launched?"true":"false");
    text(",\"activationMode\":");json_string(modal_app?"own_app_modal":(direct_app?"own_app_aumid":"uri"));text(",\"activatedProcessId\":");number(activated_pid);
    text(",\"modalResultStatus\":");if(modal_result<0)text("null");else number((DWORD)modal_result);
    text(",\"operationStatus\":");if(status<0)text("null");else number((DWORD)status);
    text(",\"stages\":{\"roInitialize\":");hex_hr(hr_ro);
    text(",\"uriFactory\":");hex_hr(hr_uri_factory);text(",\"uriCreation\":");hex_hr(hr_create);
    text(",\"launcherFactory\":");hex_hr(hr_launcher);text(",\"launchRequest\":");hex_hr(hr_launch);
    text(",\"asyncInfo\":");hex_hr(hr_async);text(",\"asyncStatus\":");hex_hr(hr_status);
    text(",\"getResults\":");hex_hr(hr_result);text(",\"asyncError\":");hex_hr(async_error);text("}");
    text(",\"foregroundPermission\":");hex_hr(hr_foreground);
    text(",\"reason\":");json_string(reason);text(",\"elapsedMs\":");number(GetTickCount64()-start);
    text(",\"activationLeaseMs\":");number(hold&&launched?60000:0);
    text(",\"outputPath\":");json_wide(output_path);text(",\"outputCreateError\":");number(out_error);
#if defined(HL_FIXED_DEVELOPER_SETTINGS)
    text(",\"proofScope\":\"Fixed settings URI activation only; no visible window, setting change or pairing PIN success is claimed\"}\n");
#else
    text(",\"proofScope\":\"URI activation result only; server client events must prove actual page and camera flow\"}\n");
#endif
    if(output_file){if(!WriteFile(output_file,output,used,&written,0)||written!=used)exit_code=3;CloseHandle(output_file);}
    if(out_error)exit_code=3;
    WriteFile(GetStdHandle((DWORD)-11),output,used,&written,0);
    if(hold&&launched&&!exit_code)Sleep(60000);
    release(launcher);if(ro_ok)RoUninitialize();
    ExitProcess(exit_code);
}
