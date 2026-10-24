/* Read-only account metadata. Never reads passwords, credentials, or SAM files. */
#define hl_entry unused_token_probe_entry
#include "hl-token-probe.c"
#undef hl_entry

IMPORT HANDLE API LoadLibraryW(const WCHAR*);
IMPORT void * API GetProcAddress(HANDLE,const char*);
IMPORT BOOL API FreeLibrary(HANDLE);
IMPORT BOOL API LookupAccountSidW(const WCHAR*,void*,WCHAR*,DWORD*,WCHAR*,DWORD*,DWORD*);

typedef struct { WCHAR *name,*full_name,*comment; DWORD flags,user_id; } USER20;
typedef struct { BOOL identity; DWORD flags; WCHAR *provider,*principal; void *sid; } USER24;
typedef DWORD (API *USER_ENUM)(const WCHAR*,DWORD,DWORD,BYTE**,DWORD,DWORD*,DWORD*,DWORD*);
typedef DWORD (API *USER_GET)(const WCHAR*,const WCHAR*,DWORD,BYTE**);
typedef DWORD (API *GROUP_MEMBERS)(const WCHAR*,const WCHAR*,DWORD,BYTE**,DWORD,DWORD*,DWORD*,ULONG_PTR*);
typedef DWORD (API *BUFFER_FREE)(void*);

void API hl_entry(void){
    HANDLE library=LoadLibraryW((const WCHAR*)L"Netapi32.dll");
    DWORD status=0,read=0,total=0,resume=0;
    BYTE *buffer=0;
    text("{\"probeReadOnly\":true,\"netApiLoadError\":");
    number(library?0:GetLastError());
    if(!library){text("}\n");flush();ExitProcess(0);}
    USER_ENUM user_enum=(USER_ENUM)GetProcAddress(library,"NetUserEnum");
    USER_GET user_get=(USER_GET)GetProcAddress(library,"NetUserGetInfo");
    GROUP_MEMBERS group_members=(GROUP_MEMBERS)GetProcAddress(library,"NetLocalGroupGetMembers");
    BUFFER_FREE buffer_free=(BUFFER_FREE)GetProcAddress(library,"NetApiBufferFree");
    if(!user_enum||!user_get||!group_members||!buffer_free){
        text(",\"apiMissing\":true}\n");flush();FreeLibrary(library);ExitProcess(0);
    }
    status=user_enum(0,20,2,&buffer,(DWORD)-1,&read,&total,&resume);
    text(",\"userEnumerationError\":");number(status);
    text(",\"userTotal\":");number(total);text(",\"users\":[");
    if(status==0||status==234){
        USER20 *users=(USER20*)buffer;
        for(DWORD i=0;i<read;i++){
            BYTE *identity_buffer=0;
            if(i)chr(',');text("{\"name\":");json_wide(users[i].name);
            text(",\"rid\":");number(users[i].user_id);
            text(",\"disabled\":");text((users[i].flags&2)?"true":"false");
            text(",\"flags\":");number(users[i].flags);
            status=user_get(0,users[i].name,24,&identity_buffer);
            text(",\"internetIdentityQueryError\":");number(status);
            if(!status&&identity_buffer){
                USER24 *identity=(USER24*)identity_buffer;
                text(",\"hasInternetIdentity\":");text(identity->identity?"true":"false");
                if(identity->identity){
                    text(",\"provider\":");if(identity->provider)json_wide(identity->provider);else text("null");
                    text(",\"principal\":");if(identity->principal)json_wide(identity->principal);else text("null");
                    text(",\"sid\":");json_sid(identity->sid);
                }
            }
            if(identity_buffer)buffer_free(identity_buffer);chr('}');
        }
    }
    if(buffer)buffer_free(buffer);buffer=0;
    text("],\"administratorGroup\":");
    void *admin_sid=0;
    WCHAR name[256],domain[256];DWORD name_size=256,domain_size=256,sid_use=0;
    if(AllocateAndInitializeSid((void*)nt_authority,2,32,544,0,0,0,0,0,0,&admin_sid)){
        if(LookupAccountSidW(0,admin_sid,name,&name_size,domain,&domain_size,&sid_use)){
            json_wide(name);read=0;total=0;ULONG_PTR group_resume=0;
            status=group_members(0,name,3,&buffer,(DWORD)-1,&read,&total,&group_resume);
            text(",\"administratorEnumerationError\":");number(status);
            text(",\"administratorMembers\":[");
            if(!status||status==234){WCHAR **members=(WCHAR**)buffer;for(DWORD i=0;i<read;i++){if(i)chr(',');json_wide(members[i]);}}
            chr(']');if(buffer)buffer_free(buffer);
        }else{text("null,\"administratorLookupError\":");number(GetLastError());}
        FreeSid(admin_sid);
    }else{text("null,\"administratorSidError\":");number(GetLastError());}
    text("}\n");flush();FreeLibrary(library);ExitProcess(0);
}
