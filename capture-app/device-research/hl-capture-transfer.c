/* Narrow, offline bridge for THIS application's one-shot LocalState files.
 * Run via the registered application's developer launcher as its ordinary user.
 * No camera/network/shell, credential access, arbitrary source, delete or overwrite.
 */
typedef unsigned short WCHAR;
typedef unsigned long DWORD;
typedef unsigned long long U64;
typedef int BOOL;
typedef void *HANDLE;
#define IMPORT __declspec(dllimport)
#define API __stdcall
IMPORT WCHAR *API GetCommandLineW(void);
IMPORT DWORD API GetEnvironmentVariableW(const WCHAR*,WCHAR*,DWORD);
IMPORT BOOL API GetUserNameW(WCHAR*,DWORD*);
IMPORT DWORD API GetLastError(void);
IMPORT DWORD API GetFileAttributesW(const WCHAR*);
IMPORT BOOL API CreateDirectoryW(const WCHAR*,void*);
IMPORT BOOL API CopyFileW(const WCHAR*,const WCHAR*,BOOL);
IMPORT HANDLE API GetStdHandle(DWORD);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT BOOL API GetFileSizeEx(HANDLE,long long*);
IMPORT BOOL API WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
IMPORT BOOL API CloseHandle(HANDLE);
IMPORT DWORD API GetCurrentProcessId(void);
IMPORT U64 API GetTickCount64(void);
IMPORT int API WideCharToMultiByte(unsigned int,DWORD,const WCHAR*,int,char*,int,const char*,BOOL*);
IMPORT void API ExitProcess(DWORD);
static WCHAR args[6][2048],user[512],local[2048],source[2048],target[2048],folder[2048];
static char json[24000],utf8[8192]; static DWORD used; static int argc;
static const WCHAR base[]=L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensCaptureV1";
static unsigned int len(const WCHAR *s){unsigned int n=0;while(s&&s[n])n++;return n;}
static int eq(const WCHAR *s,const char *t){while(*t)if(*s++!=(unsigned char)*t++)return 0;return *s==0;}
static int append(WCHAR *d,const WCHAR *s){unsigned int n=len(d),m=len(s);if(n+m>=2048)return 0;for(unsigned int i=0;i<=m;i++)d[n+i]=s[i];return 1;}
static void set(WCHAR *d,const WCHAR *s){d[0]=0;append(d,s);}
static int prefix(const WCHAR *s,const WCHAR *p){while(*p)if(*s++!=*p++)return 0;return 1;}
static void chr(char c){if(used<sizeof(json))json[used++]=c;}
static void text(const char *s){while(*s)chr(*s++);}
static void number(U64 n){char b[24];int count=0;do{b[count++]=(char)('0'+n%10);n/=10;}while(n);while(count)chr(b[--count]);}
static void string(const char *s){static const char h[]="0123456789abcdef";chr('"');while(*s){unsigned char c=*s++;if(c=='"'||c=='\\'){chr('\\');chr((char)c);}else if(c<32){text("\\u00");chr(h[c>>4]);chr(h[c&15]);}else chr((char)c);}chr('"');}
static void wide(const WCHAR *s){if(!s){text("null");return;}if(WideCharToMultiByte(65001,0,s,-1,utf8,sizeof(utf8),0,0)>0)string(utf8);else text("null");}
static int parse(void){const WCHAR *p=GetCommandLineW();while(*p){int q=0,n=0;while(*p==' '||*p=='\t')p++;if(!*p)break;if(argc==6)return 0;while(*p&&(q||(*p!=' '&&*p!='\t'))){if(*p=='"'){q=!q;p++;continue;}if(n==2047)return 0;args[argc][n++]=*p++;}if(q)return 0;args[argc++][n]=0;}return argc>0;}
static int run_allowed(const WCHAR *s){unsigned int n=len(s);if(n<1||n>64)return 0;for(unsigned int i=0;i<n;i++)if(!((s[i]>='A'&&s[i]<='Z')||(s[i]>='a'&&s[i]<='z')||(s[i]>='0'&&s[i]<='9')||s[i]=='-'||s[i]=='_'))return 0;return 1;}
static void decimal(WCHAR *d,U64 n){WCHAR b[24];int count=0;do{b[count++]=(WCHAR)('0'+n%10);n/=10;}while(n);unsigned int offset=len(d);while(count&&offset<2047)d[offset++]=b[--count];d[offset]=0;}
static U64 file_size(const WCHAR *path,DWORD *error){long long size=0;HANDLE f=CreateFileW(path,0x80000000,7,0,3,0x80,0);if(f==(HANDLE)(U64)-1){*error=GetLastError();return 0;}if(!GetFileSizeEx(f,&size))*error=GetLastError();else *error=0;CloseHandle(f);return size<0?0:(U64)size;}
static DWORD copy(const WCHAR *from,const WCHAR *to,U64 limit,U64 *bytes){DWORD e=0;*bytes=file_size(from,&e);if(e)return e;if(!*bytes||*bytes>limit)return 223;if(!CopyFileW(from,to,1))return GetLastError();return 0;}
void API hl_transfer_entry(void){
    const WCHAR *run=0,*out=0;const char *argument_error=0;BOOL importing=0;DWORD exit_code=0,user_size=512,env_size=0,create_error=0,written=0;HANDLE report=0;U64 tick=GetTickCount64();
    if(!parse()||argc!=5||(!eq(args[1],"--export")&&!eq(args[1],"--import"))||!eq(args[3],"--out")||!run_allowed(args[2]))argument_error="expected_export_or_import_run_and_fixed_output_path";
    else{
        importing=eq(args[1],"--import");run=args[2];out=args[4];
        unsigned int n=len(out),b=len(base);
        if(!prefix(out,base)||out[b]!='\\'||n<b+7||n<5||out[n-5]!='.'||out[n-4]!='j'||out[n-3]!='s'||out[n-2]!='o'||out[n-1]!='n')argument_error="output_must_be_json_inside_own_developer_layout";
        for(unsigned int i=b+1;!argument_error&&i<n;i++)if(out[i]=='/'||out[i]==':'||(out[i]=='.'&&out[i+1]=='.'))argument_error="invalid_output_path";
    }
    if(!argument_error){
        report=CreateFileW(out,0x40000000,1,0,1,0x80,0);if(report==(HANDLE)(U64)-1){create_error=GetLastError();report=0;exit_code=3;}
        env_size=GetEnvironmentVariableW((const WCHAR*)L"LOCALAPPDATA",local,2048);
        if(!env_size||env_size>=1700){local[0]=0;argument_error="localappdata_unavailable";}
        else{append(local,(const WCHAR*)L"\\Packages\\Rice.HoloLens.Capture_r5420n6798s24\\LocalState\\single-shot\\");append(local,run);}
    }
    text("{\"helperVersion\":1,\"processId\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(user,&user_size))wide(user);else text("null");
#if defined(_M_ARM64) || defined(__aarch64__)
    text(",\"architecture\":\"arm64\"");
#else
    text(",\"architecture\":\"x64\"");
#endif
    text(",\"action\":");string(importing?"import":"export");text(",\"run_id\":");wide(run);text(",\"appRunDirectory\":");wide(argument_error?0:local);text(",\"files\":[");
    if(!argument_error&&report){
        if(importing){
            set(source,base);append(source,(const WCHAR*)L"\\incoming-result-");append(source,run);append(source,(const WCHAR*)L".json");
            set(target,local);append(target,(const WCHAR*)L"\\result.json");U64 bytes=0;DWORD e=copy(source,target,262144,&bytes);
            text("{\"name\":\"result.json\",\"source\":");wide(source);text(",\"destination\":");wide(target);text(",\"bytes\":");number(bytes);text(",\"win32Error\":");number(e);chr('}');if(e!=0&&e!=80&&e!=183)exit_code=2;
        }else{
            set(folder,base);append(folder,(const WCHAR*)L"\\transfer");if(!CreateDirectoryW(folder,0)&&GetLastError()!=183)create_error=GetLastError();
            append(folder,(const WCHAR*)L"\\");append(folder,run);if(!create_error&&!CreateDirectoryW(folder,0)&&GetLastError()!=183)create_error=GetLastError();
            const WCHAR *names[]={(const WCHAR*)L"state.json",(const WCHAR*)L"capture.json",(const WCHAR*)L"photo.jpg"};
            for(int i=0;i<3;i++){
                if(i)chr(',');set(source,local);append(source,(const WCHAR*)L"\\");append(source,names[i]);
                set(target,folder);append(target,(const WCHAR*)L"\\");
                if(i<2){append(target,i==0?(const WCHAR*)L"state-":(const WCHAR*)L"capture-");decimal(target,tick);append(target,(const WCHAR*)L".json");}else append(target,names[i]);
                U64 bytes=0;DWORD e=create_error?create_error:copy(source,target,i==2?10485760:262144,&bytes);
                text("{\"name\":");wide(names[i]);text(",\"source\":");wide(source);text(",\"destination\":");wide(target);text(",\"bytes\":");number(bytes);text(",\"win32Error\":");number(e);chr('}');
                if(e!=0&&e!=80&&e!=183)exit_code=2;
            }
        }
    }
    text("],\"argumentError\":");if(argument_error)string(argument_error);else text("null");text(",\"outputCreateError\":");number(create_error);text(",\"elapsedMs\":");number(GetTickCount64()-tick);
    text(",\"scope\":\"Only this app and run LocalState files; no network, camera, credentials or overwrite\"}\n");
    if(argument_error)exit_code=64;
    if(report){if(!WriteFile(report,json,used,&written,0)||written!=used)exit_code=3;CloseHandle(report);}
    WriteFile(GetStdHandle((DWORD)-11),json,used,&written,0);ExitProcess(exit_code);
}
