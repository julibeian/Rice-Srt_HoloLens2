/* Stop only the JavaScript host belonging to this app, before an in-place update.
   No other package, camera process, user account, service or device setting. */
typedef unsigned short WCHAR;typedef unsigned long DWORD;typedef unsigned long long U64;typedef long LONG;typedef int BOOL;typedef void* HANDLE;
#define API __stdcall
#define IMPORT __declspec(dllimport)
IMPORT HANDLE API CreateToolhelp32Snapshot(DWORD,DWORD);
IMPORT BOOL API Process32FirstW(HANDLE,void*);IMPORT BOOL API Process32NextW(HANDLE,void*);
IMPORT HANDLE API OpenProcess(DWORD,BOOL,DWORD);IMPORT LONG API GetPackageFamilyName(HANDLE,DWORD*,WCHAR*);
IMPORT BOOL API TerminateProcess(HANDLE,unsigned int);IMPORT BOOL API CloseHandle(HANDLE);
IMPORT DWORD API GetLastError(void);IMPORT HANDLE API GetStdHandle(DWORD);IMPORT BOOL API WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);IMPORT void API ExitProcess(DWORD);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
typedef struct {DWORD size,usage,pid;U64 heap;DWORD module,threads,parent;LONG priority;DWORD flags;WCHAR name[260];} Entry;
_Static_assert(sizeof(Entry)==568,"PROCESSENTRY32W size");
static WCHAR family[256];static char out[1024];static DWORD used;
static void text(const char*s){while(*s&&used<sizeof(out))out[used++]=*s++;}static void number(DWORD n){char b[12];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i)out[used++]=b[--i];}
static int eq(const WCHAR*a,const WCHAR*b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
void API stop_field_entry(void){
 Entry e;DWORD matched=0,stopped=0,error=0,written=0;HANDLE snapshot=CreateToolhelp32Snapshot(2,0);
 if(snapshot==(HANDLE)(U64)-1){error=GetLastError();}else{e.size=sizeof(e);BOOL more=Process32FirstW(snapshot,&e);while(more){if(eq(e.name,(const WCHAR*)L"WWAHost.exe")||eq(e.name,(const WCHAR*)L"wwahost.exe")){HANDLE p=OpenProcess(0x1001,0,e.pid);if(p){DWORD n=256;if(GetPackageFamilyName(p,&n,family)==0&&eq(family,(const WCHAR*)L"Rice.HoloLens.Field_r5420n6798s24")){matched++;if(TerminateProcess(p,0))stopped++;else error=GetLastError();}CloseHandle(p);}}more=Process32NextW(snapshot,&e);}CloseHandle(snapshot);}
 text("{\"package\":\"Rice.HoloLens.Field_r5420n6798s24\",\"matched\":");number(matched);text(",\"terminated\":");number(stopped);text(",\"error\":");number(error);text("}\n");
 HANDLE report=CreateFileW((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\stop-result.json",0x40000000,1,0,2,0x80,0);if(report!=(HANDLE)(U64)-1){WriteFile(report,out,used,&written,0);CloseHandle(report);}WriteFile(GetStdHandle((DWORD)-11),out,used,&written,0);ExitProcess(error?1:0);
}
