/* Observe only this app's public activation and process lifetime. */
#define hl_uri_entry unused_uri_entry
#include "../../../apps/capture-app/device-research/hl-uri-launch.c"
#undef hl_uri_entry
IMPORT HANDLE API OpenProcess(DWORD,BOOL,DWORD);
IMPORT DWORD API WaitForSingleObject(HANDLE,DWORD);
IMPORT BOOL API GetExitCodeProcess(HANDLE,DWORD*);
IMPORT HANDLE API CreateToolhelp32Snapshot(DWORD,DWORD);
IMPORT BOOL API Process32FirstW(HANDLE,void*);
IMPORT BOOL API Process32NextW(HANDLE,void*);
IMPORT HRESULT API GetPackageFamilyName(HANDLE,DWORD*,WCHAR*);
IMPORT BOOL API DebugActiveProcess(DWORD);
IMPORT BOOL API DebugActiveProcessStop(DWORD);
IMPORT BOOL API DebugSetProcessKillOnExit(BOOL);
IMPORT BOOL API WaitForDebugEvent(void*,DWORD);
IMPORT BOOL API ContinueDebugEvent(DWORD,DWORD,DWORD);
IMPORT BOOL API ReadProcessMemory(HANDLE,const void*,void*,U64,U64*);
IMPORT HRESULT API CoAllowSetForegroundWindow(Object*,void*);
typedef struct {DWORD size,usage,pid;U64 heap;DWORD module,threads,parent;long priority;DWORD flags;WCHAR name[260];} Entry;
typedef struct {DWORD code,pid,tid,padding;unsigned char info[160];} DebugEvent;
static WCHAR debugText[2048];
static int equal_wide(const WCHAR*a,const WCHAR*b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
void API launch_watch_entry(void){
 Object*manager=0;DWORD pid=0,sent=0,exitCode=259,openError=0,waitResult=0xffffffff,userLength=512;HANDLE p=0,report=0;
 if(!parse_args()||(argc!=2&&argc!=3)||!allowed_output(args[1]))ExitProcess(64);
 report=CreateFileW(args[1],0x40000000,1,0,1,0x80,0);if(report==(HANDLE)(U64)-1)ExitProcess(3);
 if(argc==3&&(equal_ascii(args[2],"--observe")||equal_ascii(args[2],"--debug"))){
  U64 started=GetTickCount64();DWORD scans=0;WCHAR family[256];
  while(GetTickCount64()-started<15000&&!p){
   HANDLE snapshot=CreateToolhelp32Snapshot(2,0);Entry e;e.size=sizeof(e);scans++;
   if(snapshot!=(HANDLE)(U64)-1){BOOL more=Process32FirstW(snapshot,&e);while(more){
    if(equal_wide(e.name,(const WCHAR*)L"NativeSurface.exe")){HANDLE candidate=OpenProcess(0x1000,0,e.pid);DWORD n=256;if(candidate){if(!GetPackageFamilyName(candidate,&n,family)&&equal_wide(family,(const WCHAR*)L"Rice.HoloLens.NativeSurface_r5420n6798s24")){p=candidate;pid=e.pid;break;}CloseHandle(candidate);}else openError=GetLastError();}
    more=Process32NextW(snapshot,&e);
   }CloseHandle(snapshot);}
   if(!p)Sleep(5);
  }
  if(p&&equal_ascii(args[2],"--debug")){
   text("{\"debugEvents\":[");DWORD eventCount=0,debugError=0;
   if(DebugActiveProcess(pid)){DebugSetProcessKillOnExit(0);HANDLE memory=OpenProcess(0x1010,0,pid);BOOL exited=0;
    while(GetTickCount64()-started<18000&&!exited){DebugEvent e;if(!WaitForDebugEvent(&e,200))continue;DWORD continuation=0x10002;
     DWORD exception=e.code==1?*(DWORD*)e.info:0;if(e.code==1&&exception!=0x80000003&&exception!=0x80000004)continuation=0x80010001;
     if((e.code==1&&exception!=0x406d1388&&exception!=0xe06d7363)||e.code==8||e.code==5){if(eventCount++)text(",");text("{\"event\":");number(e.code);
      if(e.code==1){DWORD code=*(DWORD*)e.info;text(",\"exception\":");hex_hr((HRESULT)code);text(",\"firstChance\":");number(*(DWORD*)(e.info+152));DWORD count=*(DWORD*)(e.info+24);text(",\"parameters\":[");for(DWORD j=0;j<count&&j<4;j++){if(j)text(",");number(*(U64*)(e.info+32+j*8));}text("]");if(code==0x40080201&&count>=3&&memory){U64 chars=*(U64*)(e.info+40),read=0;if(chars>2047)chars=2047;if(ReadProcessMemory(memory,*(void**)(e.info+48),debugText,chars*2,&read)){debugText[chars]=0;text(",\"winrtMessage\":");json_wide(debugText);}}}
      if(e.code==5){exitCode=*(DWORD*)e.info;exited=1;text(",\"exitCode\":");hex_hr((HRESULT)exitCode);}
      if(e.code==8&&memory){DWORD chars=*(unsigned short*)(e.info+10);BOOL unicode=*(unsigned short*)(e.info+8);U64 read=0;if(chars>2047)chars=2047;if(ReadProcessMemory(memory,*(void**)e.info,debugText,chars*(unicode?2:1),&read)){debugText[unicode?chars:(chars+1)/2]=0;text(",\"text\":");if(unicode)json_wide(debugText);else{((char*)debugText)[chars]=0;json_string((char*)debugText);}}}
      text("}");
     }
     if(e.code==3||e.code==6){HANDLE file=*(HANDLE*)e.info;if(file)CloseHandle(file);}
     ContinueDebugEvent(e.pid,e.tid,continuation);
    }
    if(!exited)DebugActiveProcessStop(pid);if(memory)CloseHandle(memory);
   }else debugError=GetLastError();
   text("],\"debugError\":");number(debugError);text(",\"pid\":");number(pid);text("}\n");WriteFile(report,output,used,&sent,0);CloseHandle(report);CloseHandle(p);ExitProcess(0);
  }
  if(p){while(GetTickCount64()-started<20000&&GetExitCodeProcess(p,&exitCode)&&exitCode==259)Sleep(5);CloseHandle(p);}
  text("{\"observer\":true,\"pid\":");number(pid);text(",\"openError\":");number(openError);text(",\"scans\":");number(scans);text(",\"elapsedMs\":");number(GetTickCount64()-started);text(",\"exitCode\":");hex_hr((HRESULT)exitCode);text("}\n");WriteFile(report,output,used,&sent,0);CloseHandle(report);ExitProcess(0);
 }
 HRESULT hrRo=RoInitialize(1),hrFactory=hrRo,hrLaunch=hrRo,hrForeground=hrRo;
 if(hrRo>=0)hrFactory=CoCreateInstance(&app_activation_clsid,0,4,&app_activation_iid,(void**)&manager);
 if(hrFactory>=0){hrForeground=CoAllowSetForegroundWindow(manager,0);hrLaunch=((ActivateAppFn)manager->v[3])(manager,(const WCHAR*)L"Rice.HoloLens.NativeSurface_r5420n6798s24!Native",(const WCHAR*)L"",0,&pid);}
 if(pid){p=OpenProcess(0x101000,0,pid);if(!p)openError=GetLastError();else{waitResult=WaitForSingleObject(p,12000);GetExitCodeProcess(p,&exitCode);CloseHandle(p);}}
 text("{\"user\":");if(GetUserNameW(user,&userLength))json_wide(user);else text("null");text(",\"factory\":");hex_hr(hrFactory);text(",\"foreground\":");hex_hr(hrForeground);text(",\"launch\":");hex_hr(hrLaunch);text(",\"pid\":");number(pid);text(",\"openError\":");number(openError);text(",\"waitResult\":");number(waitResult);text(",\"exitCode\":");hex_hr((HRESULT)exitCode);text("}\n");
 WriteFile(report,output,used,&sent,0);CloseHandle(report);if(argc==3&&equal_ascii(args[2],"--hold"))Sleep(45000);release(manager);if(hrRo>=0)RoUninitialize();ExitProcess(0);
}
