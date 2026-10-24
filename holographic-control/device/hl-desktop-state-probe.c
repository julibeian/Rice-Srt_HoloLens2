/* Read-only interactive-desktop status. No switching, unlocking or input. */
#define perception_probe_entry unused_perception_probe_entry
#include "hl-perception-probe.c"
#undef perception_probe_entry
IMPORT WCHAR* API GetCommandLineW(void);IMPORT DWORD API GetCurrentThreadId(void);
IMPORT HANDLE API OpenProcess(DWORD,BOOL,DWORD);IMPORT BOOL API QueryFullProcessImageNameW(HANDLE,DWORD,WCHAR*,DWORD*);
IMPORT DWORD API WTSGetActiveConsoleSessionId(void);IMPORT BOOL API ProcessIdToSessionId(DWORD,DWORD*);
IMPORT unsigned long long API GetTickCount64(void);
#include "../../native/hl-report-path.h"
typedef HANDLE (API *OpenDesktopFn)(DWORD,BOOL,DWORD);
typedef BOOL (API *ObjectInfoFn)(HANDLE,int,void*,DWORD,DWORD*);
typedef BOOL (API *CloseDesktopFn)(HANDLE);
typedef HANDLE (API *ForegroundFn)(void);
typedef int (API *ClassFn)(HANDLE,WCHAR*,int);
typedef DWORD (API *WindowPidFn)(HANDLE,DWORD*);
typedef BOOL (API *SessionInfoFn)(HANDLE,DWORD,int,WCHAR**,DWORD*);
typedef void (API *SessionFreeFn)(void*);
typedef struct {DWORD size,tick;} LastInput;
typedef BOOL (API *LastInputFn)(LastInput*);
static WCHAR desktop_name[256],class_name[256],image_path[2048];
void API desktop_state_probe_entry(void){
 const WCHAR*report_path=0;if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\desktop-state-result.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&report_path))ExitProcess(64);
 HANDLE user=LoadLibraryExW((const WCHAR*)L"MinUser.dll",0,0x800);DWORD load_error=user?0:GetLastError();
 OpenDesktopFn open=user?(OpenDesktopFn)GetProcAddress(user,"OpenInputDesktop"):0;ObjectInfoFn info=user?(ObjectInfoFn)GetProcAddress(user,"GetUserObjectInformationW"):0;CloseDesktopFn close=user?(CloseDesktopFn)GetProcAddress(user,"CloseDesktop"):0;
 ForegroundFn foreground=user?(ForegroundFn)GetProcAddress(user,"GetForegroundWindow"):0;ClassFn get_class=user?(ClassFn)GetProcAddress(user,"GetClassNameW"):0;WindowPidFn get_pid=user?(WindowPidFn)GetProcAddress(user,"GetWindowThreadProcessId"):0;
 DWORD desktop_error=0,name_error=0,name_bytes=0,foreground_pid=0,image_error=0;HANDLE desktop=open?open(0,0,1):0;if(open&&!desktop)desktop_error=GetLastError();
 if(desktop&&info&&!info(desktop,2,desktop_name,sizeof(desktop_name),&name_bytes))name_error=GetLastError();
 HANDLE window=foreground?foreground():0;if(window&&get_class)get_class(window,class_name,256);if(window&&get_pid)get_pid(window,&foreground_pid);
 DWORD own_session=(DWORD)-1,console_session=WTSGetActiveConsoleSessionId();ProcessIdToSessionId(GetCurrentProcessId(),&own_session);
 LastInput last={sizeof(LastInput),0};LastInputFn get_last=user?(LastInputFn)GetProcAddress(user,"GetLastInputInfo"):0;BOOL last_ok=get_last?get_last(&last):0;
 DWORD last_error=get_last&&!last_ok?GetLastError():0;
 const WCHAR*wts_names[]={(const WCHAR*)L"wtsapi32.dll",(const WCHAR*)L"api-ms-win-session-wtsapi32-l1-1-0.dll",(const WCHAR*)L"ext-ms-win-session-wtsapi32-l1-1-0.dll"};
 HANDLE wts=0;SessionInfoFn query=0;SessionFreeFn free_info=0;DWORD wts_error=0,session_error=0,session_flags=(DWORD)-1,session_state=(DWORD)-1;
 for(int i=0;i<3;i++){wts=LoadLibraryExW(wts_names[i],0,0x800);if(!wts){wts_error=GetLastError();continue;}query=(SessionInfoFn)GetProcAddress(wts,"WTSQuerySessionInformationW");free_info=(SessionFreeFn)GetProcAddress(wts,"WTSFreeMemory");if(query&&free_info)break;FreeLibrary(wts);wts=0;query=0;free_info=0;}
 if(query&&free_info){WCHAR*data=0;DWORD bytes=0;if(query(0,own_session,25,&data,&bytes)){/* WTSINFOEXW level 1, SDK alignment: data starts at byte 8. */
   DWORD*p=(DWORD*)data;if(bytes>=20&&p[0]==1){session_state=p[3];session_flags=p[4];}else session_error=13;
  }else session_error=GetLastError();if(data)free_info(data);}
 if(foreground_pid){HANDLE p=OpenProcess(0x1000,0,foreground_pid);if(!p)image_error=GetLastError();else{DWORD n=2048;if(!QueryFullProcessImageNameW(p,0,image_path,&n))image_error=GetLastError();CloseHandle(p);}}
 DWORD n=512,sent=0;text("{\"version\":1,\"readOnly\":true,\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");text(",\"loadError\":");number(load_error);text(",\"openInputDesktopAvailable\":");text(open?"true":"false");text(",\"openInputDesktopError\":");number(desktop_error);text(",\"desktopNameError\":");number(name_error);text(",\"desktopName\":");if(desktop&&!name_error)json_wide(desktop_name);else text("null");text(",\"foregroundPresent\":");text(window?"true":"false");text(",\"foregroundClass\":");if(class_name[0])json_wide(class_name);else text("null");text(",\"foregroundPid\":");number(foreground_pid);text(",\"foregroundImageError\":");number(image_error);text(",\"foregroundImage\":");
 if(image_path[0]){const WCHAR*base=image_path;for(const WCHAR*p=image_path;*p;p++)if(*p=='\\'||*p=='/')base=p+1;json_wide(base);}else text("null");
 text(",\"ownSession\":");number(own_session);text(",\"consoleSession\":");number(console_session);text(",\"lastInputApiAvailable\":");text(get_last?"true":"false");text(",\"lastInputError\":");number(last_error);text(",\"lastInputAgeMs\":");if(last_ok)number((DWORD)GetTickCount64()-last.tick);else text("null");text(",\"wtsInfoApiAvailable\":");text(query&&free_info?"true":"false");text(",\"wtsLoadError\":");number(wts?0:wts_error);text(",\"wtsQueryError\":");number(session_error);text(",\"sessionState\":");if(session_state!=(DWORD)-1)number(session_state);else text("null");text(",\"sessionFlags\":");if(session_flags!=(DWORD)-1)number(session_flags);else text("null");text(",\"lockState\":");json_string(session_flags==0?"locked":session_flags==1?"unlocked":"unverified");text("}\n");
 HANDLE f=CreateFileW(report_path,0x40000000,1,0,hl_report_explicit?1:2,0x80,0);if(f!=(HANDLE)(ULONG_PTR)-1){WriteFile(f,output,output_used,&sent,0);CloseHandle(f);}if(desktop&&close)close(desktop);if(wts)FreeLibrary(wts);if(user)FreeLibrary(user);flush();ExitProcess(0);
}
