/* Read-only, fixed loopback Device Portal GETs. No credentials or redirects. */
#define hl_entry unused_token_probe_entry
#include "../../native/hl-token-probe.c"
#undef hl_entry
typedef void* HINTERNET;
IMPORT HINTERNET API WinHttpOpen(const WCHAR*,DWORD,const WCHAR*,const WCHAR*,DWORD);
IMPORT BOOL API WinHttpSetTimeouts(HINTERNET,int,int,int,int);
IMPORT HINTERNET API WinHttpConnect(HINTERNET,const WCHAR*,unsigned short,DWORD);
IMPORT HINTERNET API WinHttpOpenRequest(HINTERNET,const WCHAR*,const WCHAR*,const WCHAR*,const WCHAR*,const WCHAR**,DWORD);
IMPORT BOOL API WinHttpSetOption(HINTERNET,DWORD,void*,DWORD);
IMPORT BOOL API WinHttpSendRequest(HINTERNET,const WCHAR*,DWORD,void*,DWORD,DWORD,ULONG_PTR);
IMPORT BOOL API WinHttpReceiveResponse(HINTERNET,void*);
IMPORT BOOL API WinHttpQueryHeaders(HINTERNET,DWORD,const WCHAR*,void*,DWORD*,DWORD*);
IMPORT BOOL API WinHttpCloseHandle(HINTERNET);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
void API portal_probe_entry(void) {
    const WCHAR *paths[]={L"/api/os/info",L"/api/holographic/simulation/control/mode"};
    HINTERNET session=WinHttpOpen((const WCHAR*)L"HoloLensPortalReadOnlyProbe/1.0",1,0,0,0);
    DWORD length=512,sent=0;
    text("{\"probeVersion\":1,\"method\":\"GET\",\"host\":\"127.0.0.1\",\"port\":80,\"user\":");
    if(GetUserNameW(wide_buffer,&length))json_wide(wide_buffer);else text("null");
    text(",\"credentialsSent\":false,\"requests\":[");
    if(session){
        WinHttpSetTimeouts(session,2500,2500,2500,2500);
        HINTERNET connection=WinHttpConnect(session,(const WCHAR*)L"127.0.0.1",80,0);
        for(int i=0;i<2;i++){
            DWORD code=0,bytes=4,error=0,disable=7,redirect=0;
            HINTERNET request=connection?WinHttpOpenRequest(connection,(const WCHAR*)L"GET",paths[i],0,0,0,0):0;
            if(request){
                WinHttpSetOption(request,63,&disable,4); /* Disable cookies, redirects, and auto-auth. */
                WinHttpSetOption(request,88,&redirect,4);
                if(!WinHttpSendRequest(request,0,0,0,0,0,0)||!WinHttpReceiveResponse(request,0)||!WinHttpQueryHeaders(request,19|0x20000000,0,&code,&bytes,0))error=GetLastError();
                WinHttpCloseHandle(request);
            }else error=GetLastError();
            if(i)text(",");text("{\"path\":");json_wide(paths[i]);text(",\"status\":");number(code);text(",\"error\":");number(error);text("}");
        }
        if(connection)WinHttpCloseHandle(connection);WinHttpCloseHandle(session);
    }
    text("]}\n");
    HANDLE report=CreateFileW((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\portal-loopback-probe.json",0x40000000,1,0,2,0x80,0);
    if(report!=(HANDLE)(ULONG_PTR)-1){WriteFile(report,output,output_used,&sent,0);CloseHandle(report);}
    flush();ExitProcess(0);
}
