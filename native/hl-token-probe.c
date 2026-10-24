/* Read-only Win32 token and access probe. No account, ACL, service, or registry writes. */
typedef unsigned char BYTE;
typedef unsigned short WCHAR;
typedef unsigned long DWORD;
typedef long LONG;
typedef int BOOL;
typedef unsigned long long ULONG_PTR;
typedef void *HANDLE;
typedef void *HKEY;
#define IMPORT __declspec(dllimport)
#define API __stdcall
IMPORT HANDLE API GetCurrentProcess(void);
IMPORT DWORD API GetCurrentProcessId(void);
IMPORT HANDLE API GetStdHandle(DWORD);
IMPORT BOOL API WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
IMPORT void API ExitProcess(DWORD);
IMPORT DWORD API GetLastError(void);
IMPORT BOOL API CloseHandle(HANDLE);
IMPORT BOOL API GetComputerNameW(WCHAR*,DWORD*);
IMPORT BOOL API GetUserNameW(WCHAR*,DWORD*);
IMPORT int API WideCharToMultiByte(unsigned int,DWORD,const WCHAR*,int,char*,int,const char*,BOOL*);
IMPORT BOOL API OpenProcessToken(HANDLE,DWORD,HANDLE*);
IMPORT BOOL API GetTokenInformation(HANDLE,int,void*,DWORD,DWORD*);
IMPORT BOOL API ConvertSidToStringSidW(void*,WCHAR**);
IMPORT void * API LocalFree(void*);
IMPORT BYTE * API GetSidSubAuthorityCount(void*);
IMPORT DWORD * API GetSidSubAuthority(void*,DWORD);
IMPORT BOOL API CheckTokenMembership(HANDLE,void*,BOOL*);
IMPORT BOOL API AllocateAndInitializeSid(void*,BYTE,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,void**);
IMPORT void * API FreeSid(void*);
IMPORT HANDLE API OpenSCManagerW(const WCHAR*,const WCHAR*,DWORD);
IMPORT BOOL API CloseServiceHandle(HANDLE);
IMPORT LONG API RegOpenKeyExW(HKEY,const WCHAR*,DWORD,DWORD,HKEY*);
IMPORT LONG API RegCloseKey(HKEY);
typedef struct { DWORD LowPart; LONG HighPart; } LUID;
IMPORT BOOL API LookupPrivilegeNameW(const WCHAR*,const LUID*,WCHAR*,DWORD*);
typedef struct { void *Sid; DWORD Attributes; } SID_ATTRIBUTES;
typedef struct { DWORD Count; SID_ATTRIBUTES Groups[1]; } TOKEN_GROUPS;
typedef struct { LUID Luid; DWORD Attributes; } PRIVILEGE;
typedef struct { DWORD Count; PRIVILEGE Privileges[1]; } TOKEN_PRIVILEGES;
static __declspec(align(16)) BYTE token_buffer[65536];
static char output[16384];
static DWORD output_used;
static WCHAR wide_buffer[512];
static char utf8_buffer[2048];
static const BYTE nt_authority[6]={0,0,0,0,0,5};
static const WCHAR current_version_key[]={
    'S','O','F','T','W','A','R','E','\\','M','i','c','r','o','s','o','f','t','\\',
    'W','i','n','d','o','w','s',' ','N','T','\\','C','u','r','r','e','n','t','V','e','r','s','i','o','n',0
};

static void flush(void){
    DWORD sent=0;
    if(output_used){WriteFile(GetStdHandle((DWORD)-11),output,output_used,&sent,0);output_used=0;}
}
static void chr(char value){if(output_used==sizeof(output))flush();output[output_used++]=value;}
static void text(const char *value){while(*value)chr(*value++);}
static void number(DWORD value){char digits[16];int count=0;do{digits[count++]=(char)('0'+value%10);value/=10;}while(value);while(count)chr(digits[--count]);}
static void json_string(const char *value){
    static const char hex[]="0123456789abcdef";
    chr('"');
    while(*value){unsigned char c=(unsigned char)*value++;
        if(c=='"'||c=='\\'){chr('\\');chr((char)c);}
        else if(c<32){text("\\u00");chr(hex[c>>4]);chr(hex[c&15]);}
        else chr((char)c);
    }
    chr('"');
}
static void json_wide(const WCHAR *value){
    int result=WideCharToMultiByte(65001,0,value,-1,utf8_buffer,sizeof(utf8_buffer),0,0);
    if(result>0)json_string(utf8_buffer);else text("null");
}
static BOOL token_query(HANDLE token,int kind){DWORD needed=0;return GetTokenInformation(token,kind,token_buffer,sizeof(token_buffer),&needed);}
static void token_number(HANDLE token,int kind){DWORD value=0,needed=0;if(GetTokenInformation(token,kind,&value,sizeof(value),&needed))number(value);else text("null");}
static void json_sid(void *sid){
    WCHAR *value=0;
    if(ConvertSidToStringSidW(sid,&value)){json_wide(value);LocalFree(value);}else text("null");
}

void API hl_entry(void){
    HANDLE token=0,service=0;
    HKEY key=0;
    DWORD length=512,error=0;
    BOOL member=0;
    void *admin_sid=0;
    text("{\"probeReadOnly\":true,\"processId\":");number(GetCurrentProcessId());
    text(",\"computer\":");if(GetComputerNameW(wide_buffer,&length))json_wide(wide_buffer);else text("null");
    text(",\"user\":");length=512;if(GetUserNameW(wide_buffer,&length))json_wide(wide_buffer);else text("null");
    if(!OpenProcessToken(GetCurrentProcess(),8,&token)){
        text(",\"tokenOpenError\":");number(GetLastError());text("}\n");flush();ExitProcess(1);
    }
    text(",\"userSid\":");if(token_query(token,1))json_sid(((SID_ATTRIBUTES*)token_buffer)->Sid);else text("null");
    text(",\"elevationType\":");token_number(token,18);
    text(",\"isElevated\":");token_number(token,20);
    text(",\"isAppContainer\":");token_number(token,29);
    text(",\"integrityRid\":");
    if(token_query(token,25)){
        void *sid=((SID_ATTRIBUTES*)token_buffer)->Sid;
        BYTE count=*GetSidSubAuthorityCount(sid);
        if(count)number(*GetSidSubAuthority(sid,count-1));else text("null");
    }else text("null");
    text(",\"administratorMembership\":");
    if(AllocateAndInitializeSid((void*)nt_authority,2,32,544,0,0,0,0,0,0,&admin_sid)){
        if(CheckTokenMembership(0,admin_sid,&member))text(member?"true":"false");else text("null");
        FreeSid(admin_sid);
    }else text("null");
    text(",\"groups\":[");
    if(token_query(token,2)){
        TOKEN_GROUPS *groups=(TOKEN_GROUPS*)token_buffer;
        for(DWORD i=0;i<groups->Count;i++){
            if(i)chr(',');text("{\"sid\":");json_sid(groups->Groups[i].Sid);
            text(",\"attributes\":");number(groups->Groups[i].Attributes);chr('}');
        }
    }
    text("],\"privileges\":[");
    if(token_query(token,3)){
        TOKEN_PRIVILEGES *privileges=(TOKEN_PRIVILEGES*)token_buffer;
        for(DWORD i=0;i<privileges->Count;i++){
            if(i)chr(',');text("{\"name\":");length=512;
            if(LookupPrivilegeNameW(0,&privileges->Privileges[i].Luid,wide_buffer,&length))json_wide(wide_buffer);else text("null");
            text(",\"attributes\":");number(privileges->Privileges[i].Attributes);chr('}');
        }
    }
    text("],\"serviceManagerReadError\":");
    service=OpenSCManagerW(0,0,5);error=service?0:GetLastError();number(error);if(service)CloseServiceHandle(service);
    text(",\"serviceManagerFullAccessError\":");
    service=OpenSCManagerW(0,0,0xF003F);error=service?0:GetLastError();number(error);if(service)CloseServiceHandle(service);
    text(",\"systemRegistryReadError\":");
    error=(DWORD)RegOpenKeyExW((HKEY)(ULONG_PTR)(LONG)0x80000002,current_version_key,0,0x20019,&key);number(error);if(!error)RegCloseKey(key);
    text(",\"systemRegistryWriteAccessError\":");
    error=(DWORD)RegOpenKeyExW((HKEY)(ULONG_PTR)(LONG)0x80000002,current_version_key,0,2,&key);number(error);if(!error)RegCloseKey(key);
    text("}\n");flush();CloseHandle(token);ExitProcess(0);
}
