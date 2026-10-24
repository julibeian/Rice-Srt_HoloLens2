/* Native Wi-Fi inventory and explicitly requested njau connection only.
 * Does not accept, print or persist any password. Never changes other profiles.
 * WLAN ABI layouts checked against Windows SDK 10.0.26100.0 wlanapi.h.
 */
typedef unsigned char BYTE;
typedef unsigned short WCHAR;
typedef unsigned long DWORD;
typedef unsigned long ULONG;
typedef unsigned long long U64;
typedef int BOOL;
typedef void *HANDLE;
#define API __stdcall
#define IMPORT __declspec(dllimport)
IMPORT WCHAR *API GetCommandLineW(void);
IMPORT DWORD API GetLastError(void);
IMPORT BOOL API GetUserNameW(WCHAR*,DWORD*);
IMPORT HANDLE API GetStdHandle(DWORD);
IMPORT BOOL API WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT BOOL API CloseHandle(HANDLE);
IMPORT HANDLE API LoadLibraryW(const WCHAR*);
IMPORT void *API GetProcAddress(HANDLE,const char*);
IMPORT int API WideCharToMultiByte(unsigned int,DWORD,const WCHAR*,int,char*,int,const char*,BOOL*);
IMPORT void API Sleep(DWORD);
IMPORT U64 API GetTickCount64(void);
IMPORT DWORD API SetThreadExecutionState(DWORD);
IMPORT void API ExitProcess(DWORD);
typedef struct {DWORD a;unsigned short b,c;BYTE d[8];} GUID;
typedef struct {DWORD length;BYTE bytes[32];} SSID;
typedef struct {GUID guid;WCHAR description[256];DWORD state;} Interface;
typedef struct {DWORD count,index;Interface items[1];} Interfaces;
typedef struct {WCHAR profile[256];SSID ssid;DWORD bss,count;BOOL connectable;DWORD reason,phy_count,phys[8];BOOL more_phys;DWORD quality;BOOL secure;DWORD auth,cipher,flags,reserved;} Network;
typedef struct {DWORD count,index;Network items[1];} Networks;
typedef struct {DWORD index,software,hardware;} PhyRadio;
typedef struct {DWORD count;PhyRadio phys[64];} Radio;
typedef struct {SSID ssid;DWORD bss;BYTE bssid[6];DWORD phy,index,quality,rx,tx;} Association;
typedef struct {BOOL enabled,onex;DWORD auth,cipher;} Security;
typedef struct {DWORD state,mode;WCHAR profile[256];Association association;Security security;} Connection;
typedef struct {DWORD mode;const WCHAR *profile;SSID *ssid;void *bssids;DWORD bss,flags;} Parameters;
typedef DWORD(API *OpenFn)(DWORD,void*,DWORD*,HANDLE*);
typedef DWORD(API *CloseFn)(HANDLE,void*);
typedef DWORD(API *EnumFn)(HANDLE,void*,Interfaces**);
typedef void(API *FreeFn)(void*);
typedef DWORD(API *ListFn)(HANDLE,const GUID*,DWORD,void*,Networks**);
typedef DWORD(API *QueryFn)(HANDLE,const GUID*,DWORD,void*,DWORD*,void**,DWORD*);
typedef DWORD(API *SetFn)(HANDLE,const GUID*,DWORD,DWORD,const void*,void*);
typedef DWORD(API *ScanFn)(HANDLE,const GUID*,const SSID*,void*,void*);
typedef DWORD(API *ConnectFn)(HANDLE,const GUID*,const Parameters*,void*);
typedef DWORD(API *DisconnectFn)(HANDLE,const GUID*,void*);
typedef struct {DWORD source,code;GUID guid;DWORD size;void*data;} Notification;
typedef struct {DWORD mode;WCHAR profile[256];SSID ssid;DWORD bss;BOOL secure;DWORD reason,flags;} ConnectionNotification;
typedef DWORD(API *RegisterFn)(HANDLE,DWORD,BOOL,void(API*)(Notification*,void*),void*,void*,DWORD*);
typedef DWORD(API *ReasonFn)(DWORD,DWORD,WCHAR*,void*);
static volatile DWORD connection_notice,connection_reason;
static WCHAR reason_text[512];
static int target(const SSID*s);
static void API notified(Notification*n,void*context){(void)context;if(n&&n->source==8&&(n->code==10||n->code==11||n->code==21)&&n->data&&n->size>=564){ConnectionNotification*c=(ConnectionNotification*)n->data;if(target(&c->ssid)){connection_notice=n->code;connection_reason=c->reason;}}}
static char output[32768],utf8[2048];
static DWORD used;
static WCHAR argv[6][2048],username[512];
static int argc;
static void chr(char c){if(used<sizeof(output))output[used++]=c;}
static void text(const char*s){while(*s)chr(*s++);}
static void number(U64 n){char b[24];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i)chr(b[--i]);}
static void string(const char*s){chr('"');while(*s){BYTE c=(BYTE)*s++;if(c=='"'||c=='\\'){chr('\\');chr((char)c);}else if(c<32)chr(' ');else chr((char)c);}chr('"');}
static void wide(const WCHAR*s){if(WideCharToMultiByte(65001,0,s,-1,utf8,sizeof(utf8),0,0)>0)string(utf8);else text("null");}
static void ssid_json(const SSID*s){DWORD n=s->length<32?s->length:32;chr('"');for(DWORD i=0;i<n;i++){BYTE c=s->bytes[i];if(c=='"'||c=='\\'){chr('\\');chr((char)c);}else if(c>=32&&c<127)chr((char)c);else chr('?');}chr('"');}
static int target(const SSID*s){return s->length==4&&(s->bytes[0]=='n'||s->bytes[0]=='N')&&(s->bytes[1]=='j'||s->bytes[1]=='J')&&(s->bytes[2]=='a'||s->bytes[2]=='A')&&(s->bytes[3]=='u'||s->bytes[3]=='U');}
static int related(const SSID*s){return s->length>=4&&(s->bytes[0]=='n'||s->bytes[0]=='N')&&(s->bytes[1]=='j'||s->bytes[1]=='J')&&(s->bytes[2]=='a'||s->bytes[2]=='A')&&(s->bytes[3]=='u'||s->bytes[3]=='U');}
static int eq(const WCHAR*s,const char*t){while(*t)if(*s++!=(BYTE)*t++)return 0;return !*s;}
static int parse(void){const WCHAR*p=GetCommandLineW();while(*p){int quoted=0,n=0;while(*p==' '||*p=='\t')p++;if(!*p)break;if(argc>=6)return 0;while(*p&&(quoted||(*p!=' '&&*p!='\t'))){if(*p=='"'){quoted=!quoted;p++;continue;}if(n>=2047)return 0;argv[argc][n++]=*p++;}if(quoted)return 0;argv[argc++][n]=0;}return argc>0;}
static void err(const char*key,DWORD value){chr(',');string(key);chr(':');number(value);}
void API hl_wifi_entry(void){
    SetThreadExecutionState(0x80000003);
    BOOL scan=0,enable=0,connect_open=0,reconnect=0;const WCHAR*out=0;DWORD error=0,version=0,sent=0;HANDLE handle=0,file=0;Interfaces*interfaces=0;
    if(!parse())error=87;
    for(int i=1;i<argc;i++){if(eq(argv[i],"--scan"))scan=1;else if(eq(argv[i],"--enable"))enable=1;else if(eq(argv[i],"--connect-open")){connect_open=1;scan=1;}else if(eq(argv[i],"--reconnect-open")){connect_open=1;scan=1;reconnect=1;}else if(eq(argv[i],"--inspect")){}else if(eq(argv[i],"--out")&&i+1<argc)out=argv[++i];else error=87;}
    if(out){if(out[0]!='C'&&out[0]!='U')error=87;else if(out[1]!=':'||out[2]!='\\')error=87;else{file=CreateFileW(out,0x40000000,0,0,1,0x80,0);if(file==(HANDLE)(U64)-1){file=0;error=GetLastError();}}}
    DWORD namesize=512;GetUserNameW(username,&namesize);
    text("{\"user\":");wide(username);text(",\"target\":\"njau\",\"scanRequested\":");text(scan?"true":"false");text(",\"enableRequested\":");text(enable?"true":"false");text(",\"connectOpenRequested\":");text(connect_open?"true":"false");
    HANDLE library=LoadLibraryW((const WCHAR*)L"wlanapi.dll");
    OpenFn open=library?(OpenFn)GetProcAddress(library,"WlanOpenHandle"):0;
    CloseFn close=library?(CloseFn)GetProcAddress(library,"WlanCloseHandle"):0;
    EnumFn enumerate=library?(EnumFn)GetProcAddress(library,"WlanEnumInterfaces"):0;
    FreeFn release=library?(FreeFn)GetProcAddress(library,"WlanFreeMemory"):0;
    ListFn list=library?(ListFn)GetProcAddress(library,"WlanGetAvailableNetworkList"):0;
    QueryFn query=library?(QueryFn)GetProcAddress(library,"WlanQueryInterface"):0;
    SetFn set=library?(SetFn)GetProcAddress(library,"WlanSetInterface"):0;
    ScanFn scanfn=library?(ScanFn)GetProcAddress(library,"WlanScan"):0;
    ConnectFn connect=library?(ConnectFn)GetProcAddress(library,"WlanConnect"):0;
    DisconnectFn disconnect=library?(DisconnectFn)GetProcAddress(library,"WlanDisconnect"):0;
    RegisterFn register_notice=library?(RegisterFn)GetProcAddress(library,"WlanRegisterNotification"):0;
    ReasonFn explain=library?(ReasonFn)GetProcAddress(library,"WlanReasonCodeToString"):0;
    if(!open||!close||!enumerate||!release||!list||!query||!set||!scanfn||!connect)error=127;
    DWORD open_error=error?error:open(2,0,&version,&handle);err("openError",open_error);
    DWORD enum_error=open_error?open_error:enumerate(handle,0,&interfaces);err("enumError",enum_error);
    if(!open_error&&register_notice)register_notice(handle,8,1,notified,0,0,0);
    text(",\"interfaces\":[");
    if(!enum_error&&interfaces){
      for(DWORD i=0;i<interfaces->count&&i<8;i++){
        Interface*iface=&interfaces->items[i];if(i)chr(',');text("{\"index\":");number(i);text(",\"description\":");wide(iface->description);err("state",iface->state);
        DWORD size=0,type=0;void*data=0;DWORD q=query(handle,&iface->guid,4,0,&size,&data,&type);err("radioQueryError",q);text(",\"radios\":[");
        if(!q&&data&&size>=4){Radio*r=(Radio*)data;for(DWORD j=0;j<r->count&&j<64&&4+(j+1)*sizeof(PhyRadio)<=size;j++){if(j)chr(',');text("{\"phy\":");number(r->phys[j].index);err("software",r->phys[j].software);err("hardware",r->phys[j].hardware);if(enable&&r->phys[j].software==2&&r->phys[j].hardware==1){PhyRadio wanted=r->phys[j];wanted.software=1;err("enableError",set(handle,&iface->guid,4,sizeof(wanted),&wanted,0));}chr('}');}}text("]");if(data)release(data);data=0;
        if(scan){SSID wanted={4,{'N','J','A','U'}};DWORD se=scanfn(handle,&iface->guid,&wanted,0,0);err("scanError",se);if(!se)Sleep(2500);}
        Networks*networks=0;DWORD le=list(handle,&iface->guid,0,0,&networks);err("listError",le);text(",\"matchingNetworks\":[");DWORD matches=0;Network*chosen=0;
        if(!le&&networks){for(DWORD j=0;j<networks->count&&j<512;j++){Network*n=&networks->items[j];if(!related(&n->ssid))continue;if(matches++)chr(',');text("{\"ssid\":");ssid_json(&n->ssid);text(",\"profile\":");wide(n->profile);err("signalQuality",n->quality);text(",\"connectable\":");text(n->connectable?"true":"false");err("reason",n->reason);text(",\"secure\":");text(n->secure?"true":"false");err("auth",n->auth);err("cipher",n->cipher);err("flags",n->flags);chr('}');if(target(&n->ssid)&&(!chosen||n->profile[0]))chosen=n;}}
        text("]");
        if(connect_open){if(!chosen)err("connectError",1168);else if(chosen->secure||chosen->auth!=1)err("connectError",50);else{BOOL allowed=1;if(reconnect&&iface->state==1){void*current=0;DWORD current_size=0;DWORD qe=query(handle,&iface->guid,7,0,&current_size,&current,0);if(qe||!current||current_size<sizeof(Connection)||!target(&((Connection*)current)->association.ssid))allowed=0;if(current)release(current);if(allowed&&disconnect){err("disconnectError",disconnect(handle,&iface->guid,0));Sleep(1500);}}if(allowed){Parameters p;p.mode=chosen->profile[0]?0:3;p.profile=chosen->profile[0]?chosen->profile:0;p.ssid=&chosen->ssid;p.bssids=0;p.bss=1;p.flags=0;DWORD ce=connect(handle,&iface->guid,&p,0);err("connectError",ce);if(!ce){U64 deadline=GetTickCount64()+12000;do{void*current=0;DWORD current_size=0;DWORD qe=query(handle,&iface->guid,7,0,&current_size,&current,0);BOOL connected=!qe&&current&&current_size>=sizeof(Connection)&&target(&((Connection*)current)->association.ssid)&&((Connection*)current)->state==1;if(current)release(current);if(connected)break;Sleep(500);}while(GetTickCount64()<deadline);}}else err("connectError",5);}}
        q=query(handle,&iface->guid,7,0,&size,&data,&type);err("connectionQueryError",q);
        if(!q&&data&&size>=sizeof(Connection)){Connection*c=(Connection*)data;err("connectionState",c->state);text(",\"connectedSsid\":");ssid_json(&c->association.ssid);err("connectedSignalQuality",c->association.quality);}
        if(data)release(data);if(networks)release(networks);chr('}');
      }
    }
    text("]");err("connectionNotice",connection_notice);err("connectionReason",connection_reason);text(",\"connectionReasonText\":");if(explain&&connection_reason)explain(connection_reason,512,reason_text,0);wide(reason_text);
    if(handle&&register_notice)register_notice(handle,0,1,0,0,0,0);if(interfaces)release(interfaces);if(handle)close(handle,0);text("}\n");
    if(file){WriteFile(file,output,used,&sent,0);CloseHandle(file);}WriteFile(GetStdHandle((DWORD)-11),output,used,&sent,0);ExitProcess(enum_error?2:0);
}
