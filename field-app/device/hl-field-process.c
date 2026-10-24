/* Read-only inventory of this task's app/camera hosts. No process termination. */
typedef unsigned short WCHAR;typedef unsigned long DWORD;typedef unsigned long long U64;typedef long LONG;typedef int BOOL;typedef void* HANDLE;
#define API __stdcall
#define IMPORT __declspec(dllimport)
IMPORT HANDLE API CreateToolhelp32Snapshot(DWORD,DWORD);IMPORT BOOL API Process32FirstW(HANDLE,void*);IMPORT BOOL API Process32NextW(HANDLE,void*);IMPORT HANDLE API OpenProcess(DWORD,BOOL,DWORD);IMPORT LONG API GetPackageFamilyName(HANDLE,DWORD*,WCHAR*);IMPORT BOOL API CloseHandle(HANDLE);IMPORT DWORD API GetLastError(void);IMPORT BOOL API WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);IMPORT void API ExitProcess(DWORD);IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT HANDLE API GetStdHandle(DWORD);
IMPORT WCHAR* API GetCommandLineW(void);IMPORT BOOL API GetExitCodeProcess(HANDLE,DWORD*);
#include "../../native/hl-report-path.h"
typedef struct {DWORD size,usage,pid;U64 heap;DWORD module,threads,parent;LONG priority;DWORD flags;WCHAR name[260];} Entry;
_Static_assert(sizeof(Entry)==568,"PROCESSENTRY32W size");
IMPORT LONG API GetPackagesByPackageFamily(const WCHAR*,DWORD*,WCHAR**,DWORD*,WCHAR*); static WCHAR packageBuffer[8192];static WCHAR* packageNames[32];static WCHAR family[256];static char out[16000];static DWORD used;
static void text(const char*s){while(*s&&used<sizeof(out))out[used++]=*s++;}static void number(DWORD n){char b[12];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i)out[used++]=b[--i];}
static WCHAR lower(WCHAR c){return c>='A'&&c<='Z'?c+32:c;}static int contains(const WCHAR*s,const char*needle){for(;*s;s++){int i=0;while(needle[i]&&lower(s[i])==needle[i])i++;if(!needle[i])return 1;}return 0;}
static void wide(const WCHAR*s){text("\"");for(;*s;s++){if(*s=='\\'||*s=='\"')out[used++]='\\';out[used++]=*s<128?(char)*s:'?';}text("\"");}
static DWORD target_pid(void){const WCHAR*p=GetCommandLineW();if(*p=='"'){p++;while(*p&&*p!='"')p++;if(*p)p++;}else while(*p&&*p!=' ')p++;while(*p==' ')p++;DWORD n=0;while(*p>='0'&&*p<='9'){n=n*10+(*p++-'0');}return *p&&*p!=' '?0:n;}
void API field_process_entry(void){
 Entry e;DWORD count=0,written=0,scanned=0,snapshot_error=0,enumeration_error=0;
 const WCHAR*report_path=0;
 if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\processes-result.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&report_path))ExitProcess(64);
 HANDLE report=CreateFileW(report_path,0x40000000,1,0,hl_report_explicit?1:2,0x80,0);DWORD report_error=report==(HANDLE)(U64)-1?GetLastError():0;
 HANDLE snapshot=CreateToolhelp32Snapshot(2,0);if(snapshot==(HANDLE)(U64)-1)snapshot_error=GetLastError();
 text("{\"processes\":[");
 if(snapshot!=(HANDLE)(U64)-1){
  e.size=sizeof(e);BOOL more=Process32FirstW(snapshot,&e);
  while(more){
   scanned++;
   if(contains(e.name,"camera")||contains(e.name,"wwahost")||contains(e.name,"hl-field")){
    if(count++)text(",");text("{\"pid\":");number(e.pid);text(",\"parent\":");number(e.parent);text(",\"name\":");wide(e.name);text(",\"package\":");
    HANDLE p=OpenProcess(0x1000,0,e.pid);DWORD n=256;LONG package_error=p?GetPackageFamilyName(p,&n,family):(LONG)GetLastError();if(!package_error)wide(family);else text("null");text(",\"package_error\":");number((DWORD)package_error);if(p)CloseHandle(p);text("}");
   }
   more=Process32NextW(snapshot,&e);
  }
  enumeration_error=GetLastError();CloseHandle(snapshot);
 }
 text("],\"snapshot_error\":");number(snapshot_error);text(",\"enumeration_error\":");number(enumeration_error);text(",\"enumeration_complete\":");text(!snapshot_error&&enumeration_error==18?"true":"false");text(",\"scanned_processes\":");number(scanned);
 DWORD pid=target_pid();text(",\"target\":");
 if(pid){
  HANDLE p=OpenProcess(0x1000,0,pid);DWORD error=p?0:GetLastError(),code=0,code_error=0;
  if(p&&!GetExitCodeProcess(p,&code))code_error=GetLastError();
  text("{\"pid\":");number(pid);text(",\"open_error\":");number(error);text(",\"exit_code_error\":");number(code_error);text(",\"exit_code\":");if(p&&!code_error)number(code);else text("null");text(",\"alive\":");if(p&&!code_error)text(code==259?"true":"false");else text("null");text("}");if(p)CloseHandle(p);
 }else text("null");
 text(",\"registered_packages\":[");DWORD packageCount=32,packageChars=8192;LONG packageError=GetPackagesByPackageFamily((const WCHAR*)L"Rice.HoloLens.Field_r5420n6798s24",&packageCount,packageNames,&packageChars,packageBuffer);
 if(!packageError){for(DWORD i=0;i<packageCount&&i<32;i++){if(i)text(",");wide(packageNames[i]);}}
 text("],\"registration_error\":");number((DWORD)packageError);text(",\"report_create_error\":");number(report_error);text("}\n");
 if(report!=(HANDLE)(U64)-1){if(!WriteFile(report,out,used,&written,0)||written!=used)report_error=GetLastError();CloseHandle(report);}WriteFile(GetStdHandle((DWORD)-11),out,used,&written,0);ExitProcess(report_error?3:0);
}

