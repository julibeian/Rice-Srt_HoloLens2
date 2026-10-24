/* Read-only local-interface inventory plus ONE fixed HTTPS WinHTTP GET.
 * No MAC output, network scan, proxy discovery, redirects, authentication,
 * certificate bypass, configuration changes, or camera access.
 * --inspect skips all WinHTTP/network activity; it still reads local adapters.
 * Structures/constants checked against Windows SDK 10.0.26100.0 headers.
 */
typedef unsigned char BYTE;
typedef unsigned short WCHAR;
typedef unsigned short USHORT;
typedef unsigned long DWORD;
typedef unsigned long ULONG;
typedef unsigned long long U64;
typedef int BOOL;
typedef void *HANDLE;
typedef void *HINTERNET;
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
IMPORT int API MultiByteToWideChar(unsigned int,DWORD,const char*,int,WCHAR*,int);
IMPORT U64 API GetTickCount64(void);
IMPORT HANDLE API CreateThread(void*,U64,DWORD(API*)(void*),void*,DWORD,DWORD*);
IMPORT DWORD API WaitForSingleObject(HANDLE,DWORD);
IMPORT void API ExitProcess(DWORD);
IMPORT HINTERNET API WinHttpOpen(const WCHAR*,DWORD,const WCHAR*,const WCHAR*,DWORD);
IMPORT BOOL API WinHttpSetTimeouts(HINTERNET,int,int,int,int);
IMPORT HINTERNET API WinHttpConnect(HINTERNET,const WCHAR*,USHORT,DWORD);
IMPORT HINTERNET API WinHttpOpenRequest(HINTERNET,const WCHAR*,const WCHAR*,const WCHAR*,const WCHAR*,const WCHAR**,DWORD);
IMPORT BOOL API WinHttpSetOption(HINTERNET,DWORD,void*,DWORD);
IMPORT BOOL API WinHttpSendRequest(HINTERNET,const WCHAR*,DWORD,void*,DWORD,DWORD,U64);
IMPORT BOOL API WinHttpReceiveResponse(HINTERNET,void*);
IMPORT BOOL API WinHttpQueryHeaders(HINTERNET,DWORD,const WCHAR*,void*,DWORD*,DWORD*);
IMPORT BOOL API WinHttpReadData(HINTERNET,void*,DWORD,DWORD*);
IMPORT BOOL API WinHttpCloseHandle(HINTERNET);
IMPORT ULONG API GetAdaptersAddresses(ULONG,ULONG,void*,void*,ULONG*);
IMPORT const WCHAR *API InetNtopW(int,const void*,WCHAR*,U64);

typedef struct { void *address; int length; } SocketAddress;
typedef struct Unicast {
    DWORD length,flags;
    struct Unicast *next;
    SocketAddress socket;
} Unicast;
/* Prefix layout of IP_ADAPTER_ADDRESSES_LH. Physical bytes are never inspected. */
typedef struct Adapter {
    DWORD length,index;
    struct Adapter *next;
    char *adapter_name;
    Unicast *unicast;
    void *skip_anycast,*skip_multicast,*skip_dns;
    WCHAR *skip_suffix,*skip_description,*skip_friendly;
    BYTE skip_physical[8];
    ULONG skip_physical_length,skip_flags,mtu,if_type,oper_status,ipv6_index;
} Adapter;

static __declspec(align(16)) BYTE adapter_buffer[262144];
static WCHAR args[6][2048],username[512],ip_text[80],body_wide[2048];
static char json[65536],utf8[8192],response_body[1024];
static DWORD used;
static volatile DWORD stage_attempted[9],stage_done[9],stage_error[9];
static volatile DWORD current_stage,status_code,response_bytes,network_finished,network_success;
static const char *stage_names[]={"open","setTimeouts","connect","openRequest","redirectPolicy","sendRequest","receiveResponse","queryStatus","readBody"};
static int argc;

static void chr(char c){if(used<sizeof(json))json[used++]=c;}
static void text(const char *s){while(*s)chr(*s++);}
static void number(U64 v){char b[24];int n=0;do{b[n++]=(char)('0'+v%10);v/=10;}while(v);while(n)chr(b[--n]);}
static void json_string(const char *s){
    static const char hex[]="0123456789abcdef";chr('"');
    while(*s){BYTE c=(BYTE)*s++;if(c=='"'||c=='\\'){chr('\\');chr((char)c);}
    else if(c<32){text("\\u00");chr(hex[c>>4]);chr(hex[c&15]);}else chr((char)c);}chr('"');
}
static void json_wide(const WCHAR *s){
    if(!s){text("null");return;}
    if(WideCharToMultiByte(65001,0,s,-1,utf8,sizeof(utf8),0,0)>0)json_string(utf8);else text("null");
}
static int eq(const WCHAR *s,const char *v){while(*v)if(*s++!=(BYTE)*v++)return 0;return *s==0;}
static unsigned int length(const WCHAR *s){unsigned int n=0;while(s&&s[n])n++;return n;}
static int parse(void){
    const WCHAR *p=GetCommandLineW();
    while(*p){int quoted=0,n=0;while(*p==' '||*p=='\t')p++;if(!*p)break;if(argc==6)return 0;
        while(*p&&(quoted||(*p!=' '&&*p!='\t'))){if(*p=='"'){quoted=!quoted;p++;continue;}if(n==2047)return 0;args[argc][n++]=*p++;}
        if(quoted)return 0;args[argc++][n]=0;
    }return argc>0;
}
static int output_path_allowed(const WCHAR *s){
    unsigned int n=length(s);return n>=8&&((s[0]>='A'&&s[0]<='Z')||(s[0]>='a'&&s[0]<='z'))&&s[1]==':'&&s[2]=='\\'&&
        s[n-5]=='.'&&s[n-4]=='j'&&s[n-3]=='s'&&s[n-2]=='o'&&s[n-1]=='n';
}
static void begin_stage(DWORD stage){current_stage=stage;stage_attempted[stage]=1;}
static int end_stage(DWORD stage,BOOL ok){stage_error[stage]=ok?0:GetLastError();stage_done[stage]=1;return ok!=0;}

static DWORD API request_worker(void *unused){
    HINTERNET session=0,connection=0,request=0;
    DWORD redirect_policy=0,disabled_features=7,code=0,code_size=4,count=0,read=0;
    (void)unused;
    begin_stage(0);
    session=WinHttpOpen((const WCHAR*)L"RiceHoloLensConnectivityProbe/1.0",1,0,0,0); /* NO_PROXY; no WPAD. */
    if(!end_stage(0,session!=0))goto cleanup;
    begin_stage(1);
    if(!end_stage(1,WinHttpSetTimeouts(session,5000,5000,5000,5000)))goto cleanup;
    begin_stage(2);
    connection=WinHttpConnect(session,(const WCHAR*)L"rice-srt.cn",443,0);
    if(!end_stage(2,connection!=0))goto cleanup;
    begin_stage(3);
    request=WinHttpOpenRequest(connection,(const WCHAR*)L"GET",(const WCHAR*)L"/hololens/api/health",0,0,0,0x00800000);
    if(!end_stage(3,request!=0))goto cleanup;
    begin_stage(4);
    /* REDIRECT_POLICY_NEVER. Do not set SECURITY_FLAGS; TLS verification stays enabled. */
    if(!end_stage(4,WinHttpSetOption(request,88,&redirect_policy,4)&&
        WinHttpSetOption(request,63,&disabled_features,4)))goto cleanup;
    begin_stage(5);
    if(!end_stage(5,WinHttpSendRequest(request,(const WCHAR*)L"Accept: application/json\r\n",(DWORD)-1,0,0,0,0)))goto cleanup;
    begin_stage(6);
    if(!end_stage(6,WinHttpReceiveResponse(request,0)))goto cleanup;
    begin_stage(7);
    if(!end_stage(7,WinHttpQueryHeaders(request,19|0x20000000,0,&code,&code_size,0)))goto cleanup;
    status_code=code;
    begin_stage(8);
    while(count<sizeof(response_body)){
        if(!WinHttpReadData(request,response_body+count,(DWORD)sizeof(response_body)-count,&read)){
            end_stage(8,0);goto cleanup;
        }
        if(read==0)break;
        count+=read;response_bytes=count;
    }
    end_stage(8,1);
    network_success=code>=200&&code<300;
cleanup:
    if(request)WinHttpCloseHandle(request);
    if(connection)WinHttpCloseHandle(connection);
    if(session)WinHttpCloseHandle(session);
    network_finished=1;
    return 0;
}

static const char *adapter_type(ULONG value){
    if(value==6)return "ethernet";if(value==71)return "wifi";if(value==24)return "loopback";
    if(value==131)return "tunnel";if(value==23)return "ppp";return "other";
}
static const char *private_kind(USHORT family,const BYTE *bytes){
    if(family==2){
        if(bytes[0]==10||(bytes[0]==172&&bytes[1]>=16&&bytes[1]<=31)||(bytes[0]==192&&bytes[1]==168))return "private_ipv4";
        if(bytes[0]==169&&bytes[1]==254)return "link_local_ipv4";
        if(bytes[0]==127)return "loopback_ipv4";
    }else if(family==23){
        if((bytes[0]&0xfe)==0xfc)return "unique_local_ipv6";
        if(bytes[0]==0xfe&&(bytes[1]&0xc0)==0x80)return "link_local_ipv6";
        int zero=1;for(int i=0;i<15;i++)if(bytes[i])zero=0;
        if(zero&&bytes[15]==1)return "loopback_ipv6";
    }return 0;
}

void API hl_network_entry(void){
    const WCHAR *output_path=0;
    const char *argument_error=0;
    HANDLE output_file=0,thread=0;
    DWORD sent=0,user_size=512,adapter_size=sizeof(adapter_buffer),adapter_error=0,output_error=0,thread_error=0;
    DWORD timeout_result=0,exit_code=0;
    U64 started=GetTickCount64();
    int inspect=0,timed_out=0,adapter_count=0;
    if(!parse())argument_error="invalid_arguments";
    for(int i=1;!argument_error&&i<argc;i++){
        if(eq(args[i],"--inspect"))inspect=1;
        else if(eq(args[i],"--out")&&!output_path&&i+1<argc){output_path=args[++i];if(!output_path_allowed(output_path))argument_error="output_requires_absolute_local_json_path";}
        else argument_error="only_inspect_and_out_arguments_are_accepted";
    }
    if(!argument_error&&output_path){
        output_file=CreateFileW(output_path,0x40000000,1,0,1,0x80,0);
        if(output_file==(HANDLE)(U64)-1){output_error=GetLastError();output_file=0;}
    }
    if(!argument_error){
        adapter_error=GetAdaptersAddresses(0,0x082e,0,adapter_buffer,&adapter_size);
        if(!inspect){
            thread=CreateThread(0,0,request_worker,0,0,0);
            if(!thread)thread_error=GetLastError();
            else{timeout_result=WaitForSingleObject(thread,7000);timed_out=timeout_result==258;CloseHandle(thread);}
        }
    }
    text("{\"probeVersion\":1,\"processId\":");number(GetCurrentProcessId());
    text(",\"user\":");if(GetUserNameW(username,&user_size))json_wide(username);else text("null");
#if defined(_M_ARM64) || defined(__aarch64__)
    text(",\"architecture\":\"arm64\"");
#else
    text(",\"architecture\":\"x64\"");
#endif
    text(",\"inspectOnly\":");text(inspect?"true":"false");
    text(",\"method\":\"GET\",\"url\":\"https://rice-srt.cn/hololens/api/health\"");
    text(",\"proxyMode\":\"direct\",\"redirectsAllowed\":false,\"defaultTlsValidation\":true");
    text(",\"networkAttempted\":");text((!inspect&&!argument_error)?"true":"false");
    text(",\"overallBudgetMs\":7000,\"stageTimeoutMs\":5000,\"overallTimedOut\":");text(timed_out?"true":"false");
    text(",\"threadCreateError\":");number(thread_error);
    text(",\"workerFinished\":");text(network_finished?"true":"false");
    text(",\"httpStatus\":");if(status_code)number(status_code);else text("null");
    text(",\"responseBytesRetained\":");number(response_bytes);
    text(",\"responsePrefix\":");
    if(response_bytes){int n=MultiByteToWideChar(65001,0,response_body,(int)response_bytes,body_wide,2047);body_wide[n>0?n:0]=0;json_wide(body_wide);}else text("null");
    text(",\"stages\":{");
    for(DWORD i=0;i<9;i++){
        if(i)chr(',');json_string(stage_names[i]);text(":{\"attempted\":");text(stage_attempted[i]?"true":"false");
        text(",\"completed\":");text(stage_done[i]?"true":"false");
        text(",\"win32Error\":");if(stage_done[i])number(stage_error[i]);else if(timed_out&&stage_attempted[i]&&current_stage==i)number(1460);else text("null");chr('}');
    }text("},\"adapterQueryError\":");number(adapter_error);
    text(",\"adapterRequiredBufferBytes\":");number(adapter_size);
    text(",\"adapters\":[");
    if(!argument_error&&adapter_error==0){
        for(Adapter *a=(Adapter*)adapter_buffer;a&&adapter_count<32;a=a->next){
            if(a->length<112)continue;
            if(adapter_count++)chr(',');
            text("{\"ifIndex\":");number(a->index);text(",\"ifType\":");number(a->if_type);
            text(",\"kind\":");json_string(adapter_type(a->if_type));
            text(",\"operStatus\":");number(a->oper_status);text(",\"up\":");text(a->oper_status==1?"true":"false");
            text(",\"localAddresses\":[");int addresses=0;
            for(Unicast *u=a->unicast;u&&addresses<8;u=u->next){
                if(!u->socket.address||u->socket.length<8)continue;
                BYTE *s=(BYTE*)u->socket.address;USHORT family=*(USHORT*)s;
                if(family!=2&&family!=23)continue;
                if(family==23&&u->socket.length<28)continue;
                const BYTE *bytes=s+(family==2?4:8);const char *kind=private_kind(family,bytes);
                if(!kind)continue;
                if(!InetNtopW(family,bytes,ip_text,80))continue;
                if(addresses++)chr(',');text("{\"family\":");number(family);text(",\"scope\":");json_string(kind);
                text(",\"address\":");json_wide(ip_text);chr('}');
            }text("]}");
        }
    }text("],\"argumentError\":");if(argument_error)json_string(argument_error);else text("null");
    text(",\"outputPath\":");json_wide(output_path);text(",\"outputCreateError\":");number(output_error);
    text(",\"elapsedMs\":");number(GetTickCount64()-started);
    text(",\"scope\":\"Local adapter state and a single fixed HTTPS GET only; no MAC output, network scan or changes\"}\n");
    if(argument_error)exit_code=64;
    else if(!inspect&&(!network_finished||!network_success||thread_error||timed_out))exit_code=2;
    else if(adapter_error)exit_code=1;
    if(output_file){if(!WriteFile(output_file,json,used,&sent,0)||sent!=used)exit_code=3;CloseHandle(output_file);}
    if(output_error)exit_code=3;
    WriteFile(GetStdHandle((DWORD)-11),json,used,&sent,0);
    /* Exiting this isolated probe also stops its worker if the overall deadline expired. */
    ExitProcess(exit_code);
}
