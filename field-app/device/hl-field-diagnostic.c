/* Export only this app's two diagnostic JSON files from its ordinary user.
 * No camera, network, credentials, registry, arbitrary file reads or overwrite.
 */
typedef unsigned short WCHAR;
typedef unsigned long DWORD;
typedef unsigned long long U64;
typedef int BOOL;
typedef void *HANDLE;
#define API __stdcall
#define IMPORT __declspec(dllimport)
IMPORT WCHAR *API GetCommandLineW(void);
IMPORT DWORD API GetEnvironmentVariableW(const WCHAR*,WCHAR*,DWORD);
IMPORT BOOL API GetUserNameW(WCHAR*,DWORD*);
IMPORT DWORD API GetLastError(void);
IMPORT DWORD API GetFileAttributesW(const WCHAR*);
IMPORT BOOL API CopyFileW(const WCHAR*,const WCHAR*,BOOL);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT BOOL API WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
IMPORT BOOL API CloseHandle(HANDLE);
IMPORT int API WideCharToMultiByte(unsigned int,DWORD,const WCHAR*,int,char*,int,const char*,BOOL*);
IMPORT void API ExitProcess(DWORD);
static WCHAR args[3][2048],local[2048],source[2048],target[2048],user[512];
static char output[18000],utf8[8192];static DWORD used;static int argc;
static const WCHAR base[]=L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\";
static unsigned int len(const WCHAR*s){unsigned int n=0;while(s&&s[n])n++;return n;}
static int add(WCHAR*d,const WCHAR*s){unsigned int n=len(d),m=len(s);if(n+m>=2048)return 0;for(unsigned int i=0;i<=m;i++)d[n+i]=s[i];return 1;}
static void set(WCHAR*d,const WCHAR*s){d[0]=0;add(d,s);}
static int prefix(const WCHAR*s,const WCHAR*p){while(*p)if(*s++!=*p++)return 0;return 1;}
static void chr(char c){if(used<sizeof(output))output[used++]=c;}
static void text(const char*s){while(*s)chr(*s++);}
static void number(U64 n){char b[24];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i)chr(b[--i]);}
static void wide(const WCHAR*s){if(WideCharToMultiByte(65001,0,s,-1,utf8,sizeof(utf8),0,0)<1){text("null");return;}chr('"');for(char*p=utf8;*p;p++){if(*p=='"'||*p=='\\')chr('\\');if((unsigned char)*p>=32)chr(*p);}chr('"');}
static int parse(void){const WCHAR*p=GetCommandLineW();while(*p){while(*p==' '||*p=='\t')p++;if(!*p)break;if(argc==3)return 0;int n=0,q=0;while(*p&&(q||(*p!=' '&&*p!='\t'))){if(*p=='"'){q=!q;p++;continue;}if(n==2047)return 0;args[argc][n++]=*p++;}if(q)return 0;args[argc++][n]=0;}return argc==2;}
void API field_diagnostic_entry(void){
 DWORD size=512,written=0,exit_code=0;HANDLE report=0;
 if(!parse()||!prefix(args[1],base))ExitProcess(64);
 const WCHAR*tail=args[1]+len(base);unsigned int n=len(tail);
 if(n<6||n>90)ExitProcess(64);
 for(unsigned int i=0;i<n;i++)if(!((tail[i]>='a'&&tail[i]<='z')||(tail[i]>='0'&&tail[i]<='9')||tail[i]=='-'||tail[i]=='_'||tail[i]=='.'))ExitProcess(64);
 if(tail[n-5]!='.'||tail[n-4]!='j'||tail[n-3]!='s'||tail[n-2]!='o'||tail[n-1]!='n')ExitProcess(64);
 report=CreateFileW(args[1],0x40000000,1,0,1,0x80,0);if(report==(HANDLE)(U64)-1)ExitProcess(3);
 DWORD env=GetEnvironmentVariableW((const WCHAR*)L"LOCALAPPDATA",local,2048);
 text("{\"user\":");if(GetUserNameW(user,&size))wide(user);else text("null");text(",\"localAppData\":");wide(local);
 if(!env||env>1700){text(",\"error\":\"localappdata_unavailable\"}");exit_code=2;}
 else{
  add(local,(const WCHAR*)L"\\Packages\\Rice.HoloLens.Field_r5420n6798s24\\LocalState");
  text(",\"appLocalState\":");wide(local);text(",\"files\":[");
  const WCHAR*names[]={(const WCHAR*)L"app-state.json",(const WCHAR*)L"boot-error.json",(const WCHAR*)L"boot-state.json"};
  for(int i=0;i<3;i++){
   if(i)chr(',');set(source,local);add(source,(const WCHAR*)L"\\");add(source,names[i]);
   set(target,args[1]);target[len(target)-5]=0;add(target,i==0?(const WCHAR*)L"-app-state.json":i==1?(const WCHAR*)L"-boot-error.json":(const WCHAR*)L"-boot-state.json");
   DWORD attrs=GetFileAttributesW(source),error=attrs==0xffffffff?GetLastError():0;
   if(!error&&!CopyFileW(source,target,1))error=GetLastError();
   text("{\"name\":");wide(names[i]);text(",\"destination\":");wide(target);text(",\"win32Error\":");number(error);chr('}');
  }
  text("],\"scope\":\"Only this application's app and boot diagnostics; no app credentials or photos\"}");
 }
 if(!WriteFile(report,output,used,&written,0)||written!=used)exit_code=3;CloseHandle(report);ExitProcess(exit_code);
}
