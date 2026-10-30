/* Sends one result notification for ONLY our registered application.
 * Reads one own-run XML file; no camera, network, elevation or settings changes.
 * An accepted notification/history entry is NOT proof of visible pixels.
 * ABI verified against Windows SDK 10.0.26100.0 WinRT headers.
 */
#include "hl-uri-launch.c"
IMPORT BOOL API ReadFile(HANDLE,void*,DWORD,DWORD*,void*);
IMPORT int API MultiByteToWideChar(unsigned int,DWORD,const char*,int,WCHAR*,int);
IMPORT const WCHAR *API WindowsGetStringRawBuffer(HSTRING,unsigned int*);
static const GUID toast_manager_iid={0x50ac103f,0xd235,0x4598,{0xbb,0xef,0x98,0xfe,0x4d,0x1a,0x3a,0xd4}};
static const GUID toast_manager2_iid={0x7ab93c52,0x0e48,0x4750,{0xba,0x9d,0x1a,0x41,0x13,0x98,0x18,0x47}};
static const GUID toast_factory_iid={0x04124b20,0x82c6,0x4229,{0xb1,0x09,0xfd,0x9e,0xd4,0x66,0x2b,0x53}};
static const GUID toast2_iid={0x9dfb9fd1,0x143a,0x490e,{0x90,0xbf,0xb9,0xfb,0xa7,0x13,0x2d,0xe7}};
static const GUID history2_iid={0x3bc3d253,0x2f31,0x4092,{0x91,0x29,0x8a,0xd5,0xab,0xf0,0x67,0xda}};
static const GUID xml_io_iid={0x6cd0e74e,0xee65,0x4489,{0x9e,0xbf,0xca,0x43,0xe8,0x7b,0xa6,0x37}};
static const GUID serializer_iid={0x5cc5b382,0xe6dd,0x4991,{0xab,0xef,0x06,0xd8,0xd2,0xe7,0xbd,0x0c}};
typedef HRESULT(API *IdObjectFn)(Object*,HSTRING,Object**);
typedef HRESULT(API *ObjectOutFn)(Object*,Object**);
typedef HRESULT(API *IntOutFn)(Object*,int*);
typedef HRESULT(API *SizeOutFn)(Object*,unsigned int*);
typedef HRESULT(API *AtOutFn)(Object*,unsigned int,Object**);
typedef HRESULT(API *StringOutFn)(Object*,HSTRING*);
typedef HRESULT(API *OneObjectFn)(Object*,Object*);
typedef HRESULT(API *CreateToastFn)(Object*,Object*,Object**);
static char xml_bytes[16384];static WCHAR xml_wide[16384];
static const WCHAR app_id[]=L"Rice.HoloLens.Capture_r5420n6798s24!Capture";
static int same_wide(const WCHAR*a,const WCHAR*b){if(!a||!b)return a==b;while(*a&&*a==*b){a++;b++;}return *a==*b;}
static int valid_tag(const WCHAR*t){unsigned int n=0;while(t&&t[n]){WCHAR c=t[n++];if(!((c>='a'&&c<='f')||(c>='0'&&c<='9')))return 0;}return n==16;}
static HRESULT make_string(const WCHAR*s,HSTRING*out){return WindowsCreateString(s,wide_len(s),out);}
static int find_own_toast(Object*history,HSTRING app,const WCHAR*tag,HSTRING*found_xml,HRESULT*hr_out){
    Object *view=0,*toast=0,*toast2=0,*content=0,*serializer=0;unsigned int count=0;HSTRING item_tag=0;int found=0;
    *hr_out=((IdObjectFn)history->v[7])(history,app,&view);
    if(*hr_out>=0)*hr_out=((SizeOutFn)view->v[7])(view,&count);
    if(*hr_out>=0)for(unsigned int i=0;i<count&&i<64;i++){
        if(((AtOutFn)view->v[6])(view,i,&toast)<0)continue;
        HRESULT hr=((QueryInterfaceFn)toast->v[0])(toast,&toast2_iid,&toast2);
        if(hr>=0)hr=((StringOutFn)toast2->v[7])(toast2,&item_tag);
        found=hr>=0&&same_wide(WindowsGetStringRawBuffer(item_tag,0),tag);
        if(item_tag){WindowsDeleteString(item_tag);item_tag=0;}release(toast2);toast2=0;
        if(found){
            hr=((ObjectOutFn)toast->v[6])(toast,&content);
            if(hr>=0)hr=((QueryInterfaceFn)content->v[0])(content,&serializer_iid,&serializer);
            if(hr>=0)hr=((StringOutFn)serializer->v[6])(serializer,found_xml);
            *hr_out=hr;release(serializer);release(content);release(toast);toast=0;break;
        }
        release(toast);toast=0;
    }
    release(view);return found;
}
void API hl_result_notification_entry(void){
    const WCHAR *xml_path=0,*tag=0,*out=0;int valid=1,setting=-1,show_called=0,history_found=0,duplicate=0,ro_ok=0;
    DWORD error=0,read=0,sent=0,user_size=512,exit_code=0;HANDLE report=0,input=0;HSTRING app=0,tag_h=0,xml_h=0,cls=0,found_xml=0;
    Object *manager=0,*manager2=0,*notifier=0,*history_base=0,*history=0,*xml=0,*xml_io=0,*toast_factory=0,*toast=0,*toast2=0;
    HRESULT hr_ro=(HRESULT)0x8000000A,hr_notifier=hr_ro,hr_xml=hr_ro,hr_toast=hr_ro,hr_show=hr_ro,hr_history=hr_ro,hr_setting=hr_ro;
    const char*reason="not_started";U64 start=GetTickCount64();
    if(!parse_args())valid=0;
    for(int i=1;valid&&i<argc;i++){
        if(equal_ascii(args[i],"--xml")&&!xml_path&&i+1<argc)xml_path=args[++i];
        else if(equal_ascii(args[i],"--tag")&&!tag&&i+1<argc)tag=args[++i];
        else if(equal_ascii(args[i],"--out")&&!out&&i+1<argc)out=args[++i];
        else valid=0;
    }
    if(!valid||!xml_path||!prefix_ascii(xml_path,"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensCaptureV1\\native-shots\\")||!valid_tag(tag)||!out||!allowed_output(out)){reason="invalid_own_result_arguments";exit_code=64;goto done;}
    report=CreateFileW(out,0x40000000,1,0,1,0x80,0);
    if(report==(HANDLE)(U64)-1){report=0;error=GetLastError();reason="report_exists_or_unwritable_no_notification";exit_code=3;goto done;}
    input=CreateFileW(xml_path,0x80000000,1,0,3,0x80,0);
    if(input==(HANDLE)(U64)-1){input=0;error=GetLastError();reason="own_xml_unreadable";exit_code=2;goto done;}
    if(!ReadFile(input,xml_bytes,sizeof(xml_bytes),&read,0)||read==sizeof(xml_bytes)){error=GetLastError();reason="own_xml_read_failed_or_too_large";exit_code=2;goto done;}
    int wide_count=MultiByteToWideChar(65001,8,xml_bytes,(int)read,xml_wide,16383);
    if(wide_count<=0){error=GetLastError();reason="invalid_utf8_xml";exit_code=2;goto done;}xml_wide[wide_count]=0;
    hr_ro=RoInitialize(0);if(hr_ro<0){reason="ro_initialization_failed";exit_code=2;goto done;}ro_ok=1;
    hr_notifier=make_string(app_id,&app);
    if(hr_notifier>=0)hr_notifier=factory((const WCHAR*)L"Windows.UI.Notifications.ToastNotificationManager",&toast_manager_iid,&manager);
    if(hr_notifier>=0)hr_notifier=((IdObjectFn)manager->v[7])(manager,app,&notifier);
    if(hr_notifier<0){reason="own_notifier_unavailable";exit_code=2;goto done;}
    hr_setting=((IntOutFn)notifier->v[8])(notifier,&setting);
    if(hr_setting<0||setting!=0){reason="notifications_not_enabled_settings_unchanged";exit_code=2;goto done;}
    hr_history=factory((const WCHAR*)L"Windows.UI.Notifications.ToastNotificationManager",&toast_manager2_iid,&manager2);
    if(hr_history>=0)hr_history=((ObjectOutFn)manager2->v[6])(manager2,&history_base);
    if(hr_history>=0)hr_history=((QueryInterfaceFn)history_base->v[0])(history_base,&history2_iid,&history);
    if(hr_history>=0)history_found=find_own_toast(history,app,tag,&found_xml,&hr_history);
    if(history_found){duplicate=1;reason="same_result_already_in_own_notification_history";goto done;}
    hr_xml=make_string((const WCHAR*)L"Windows.Data.Xml.Dom.XmlDocument",&cls);
    if(hr_xml>=0)hr_xml=RoActivateInstance(cls,(void**)&xml);
    if(hr_xml>=0)hr_xml=((QueryInterfaceFn)xml->v[0])(xml,&xml_io_iid,&xml_io);
    if(hr_xml>=0)hr_xml=make_string(xml_wide,&xml_h);
    if(hr_xml>=0)hr_xml=((PutStringFn)xml_io->v[6])(xml_io,xml_h);
    if(hr_xml<0){reason="result_xml_invalid";exit_code=2;goto done;}
    hr_toast=factory((const WCHAR*)L"Windows.UI.Notifications.ToastNotification",&toast_factory_iid,&toast_factory);
    if(hr_toast>=0)hr_toast=((CreateToastFn)toast_factory->v[6])(toast_factory,xml,&toast);
    if(hr_toast>=0)hr_toast=((QueryInterfaceFn)toast->v[0])(toast,&toast2_iid,&toast2);
    if(hr_toast>=0)hr_toast=make_string(tag,&tag_h);
    if(hr_toast>=0)hr_toast=((PutStringFn)toast2->v[6])(toast2,tag_h);
    if(hr_toast<0){reason="result_notification_creation_failed";exit_code=2;goto done;}
    show_called=1;hr_show=((OneObjectFn)notifier->v[6])(notifier,toast);
    if(hr_show<0){reason="notification_show_rejected";exit_code=2;goto done;}
    if(history)for(int i=0;i<10&&!history_found;i++){Sleep(200);history_found=find_own_toast(history,app,tag,&found_xml,&hr_history);}
    reason=history_found?"own_result_notification_accepted_and_found_in_history":"show_accepted_no_history_entry_observed";
done:
    text("{\"version\":1,\"user\":");if(GetUserNameW(user,&user_size))json_wide(user);else text("null");
    text(",\"application_id\":");json_wide(app_id);text(",\"tag\":");json_wide(tag);
    text(",\"showCalled\":");text(show_called?"true":"false");text(",\"alreadyInOwnHistory\":");text(duplicate?"true":"false");
    text(",\"historyEntryFound\":");text(history_found?"true":"false");text(",\"notificationSetting\":");if(setting<0)text("null");else number((U64)setting);
    text(",\"visiblePixelsVerified\":false,\"notificationXml\":");json_wide(found_xml?WindowsGetStringRawBuffer(found_xml,0):0);
    text(",\"stages\":{\"roInitialize\":");hex_hr(hr_ro);text(",\"notifier\":");hex_hr(hr_notifier);text(",\"setting\":");hex_hr(hr_setting);
    text(",\"xml\":");hex_hr(hr_xml);text(",\"toast\":");hex_hr(hr_toast);text(",\"show\":");hex_hr(hr_show);text(",\"ownHistory\":");hex_hr(hr_history);
    text("},\"win32Error\":");number(error);text(",\"reason\":");json_string(reason);text(",\"elapsedMs\":");number(GetTickCount64()-start);
    text(",\"scope\":\"Only this application result notification; no camera, network, notification settings or other applications' history.\"}\n");
    if(report){if(!WriteFile(report,output,used,&sent,0)||sent!=used)exit_code=3;CloseHandle(report);}WriteFile(GetStdHandle((DWORD)-11),output,used,&sent,0);
    if(input)CloseHandle(input);release(toast2);release(toast);release(toast_factory);release(xml_io);release(xml);release(history);release(history_base);release(manager2);release(notifier);release(manager);
    if(found_xml)WindowsDeleteString(found_xml);if(tag_h)WindowsDeleteString(tag_h);if(xml_h)WindowsDeleteString(xml_h);if(cls)WindowsDeleteString(cls);if(app)WindowsDeleteString(app);if(ro_ok)RoUninitialize();ExitProcess(exit_code);
}
