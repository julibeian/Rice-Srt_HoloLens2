/* Keep normal idle power only while the pinned PC refreshes a USB lease.
 * Restores the three original DC timeouts on expiry/stop. No simulated input. */
#define hl_entry unused_usb_power_token_entry
#include "../../../native/hl-token-probe.c"
#undef hl_entry
typedef struct {DWORD a;unsigned short b,c;BYTE d[8];} Guid;
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT BOOL API ReadFile(HANDLE,void*,DWORD,DWORD*,void*);
IMPORT BOOL API DeleteFileW(const WCHAR*);
IMPORT HANDLE API CreateMutexW(void*,BOOL,const WCHAR*);
IMPORT DWORD API WaitForSingleObject(HANDLE,DWORD);
IMPORT BOOL API ReleaseMutex(HANDLE);
IMPORT void API Sleep(DWORD);
IMPORT unsigned long long API GetTickCount64(void);
IMPORT DWORD API SetThreadExecutionState(DWORD);
IMPORT DWORD API PowerGetActiveScheme(HKEY,Guid**);
IMPORT DWORD API PowerReadDCValueIndex(HKEY,const Guid*,const Guid*,const Guid*,DWORD*);
IMPORT DWORD API PowerWriteDCValueIndex(HKEY,const Guid*,const Guid*,const Guid*,DWORD);
IMPORT DWORD API PowerSetActiveScheme(HKEY,const Guid*);
typedef struct {DWORD version,flags;union {struct {HANDLE module;DWORD id,count;WCHAR**strings;} detailed;WCHAR*simple;} reason;} ReasonContext;
IMPORT HANDLE API PowerCreateRequest(ReasonContext*);
IMPORT BOOL API PowerSetRequest(HANDLE,int);
IMPORT BOOL API PowerClearRequest(HANDLE,int);
#define ROOT L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\"
static const WCHAR *heartbeat_path=(const WCHAR*)ROOT L"usb-power-heartbeat.bin";
static const WCHAR *backup_path=(const WCHAR*)ROOT L"usb-power-backup.bin";
static const WCHAR *report_path=(const WCHAR*)ROOT L"usb-power-report.json";
static const Guid sleep_group={0x238c9fa8,0x0aad,0x41ed,{0x83,0xf4,0x97,0xbe,0x24,0x2c,0x8f,0x20}};
static const Guid video_group={0x7516b95f,0xf776,0x4464,{0x8c,0x53,0x06,0x16,0x7f,0x40,0xcc,0x99}};
static const Guid settings[3]={
 {0x29f6c1db,0x86da,0x48c5,{0x9f,0xdb,0xf2,0xb6,0x7b,0x1f,0x44,0xda}},
 {0x7bc4a2f9,0xd8fc,0x4469,{0xb0,0x7b,0x33,0xeb,0x78,0x5a,0xac,0xa0}},
 {0x3c0bc021,0xc8a8,0x4e07,{0xa9,0x73,0x6b,0x14,0xcb,0xcb,0x2b,0x7e}}
};
typedef struct {DWORD magic,version;BYTE owner[16];unsigned long long sequence;} Heartbeat;
typedef struct {DWORD magic,version;Guid scheme;DWORD original[3],mask;} Backup;
static Heartbeat lease;
static Backup backup;
static DWORD last_error,apply_error[3],restore_error[3],execution_result;
static unsigned long long last_seen;
static HANDLE execution_request;
static const Guid *group(int i){return i==2?&video_group:&sleep_group;}
static int same(const void*a,const void*b,DWORD n){const BYTE*x=a,*y=b;for(DWORD i=0;i<n;i++)if(x[i]!=y[i])return 0;return 1;}
static int read_file(const WCHAR *path,void *data,DWORD size){
 HANDLE file=CreateFileW(path,0x80000000,7,0,3,0x80,0);if(file==(HANDLE)(ULONG_PTR)-1){last_error=GetLastError();return 0;}
 DWORD count=0;BOOL ok=ReadFile(file,data,size,&count,0);if(!ok)last_error=GetLastError();CloseHandle(file);return ok&&count==size;
}
static int write_file(const WCHAR *path,const void *data,DWORD size,DWORD mode){
 HANDLE file=CreateFileW(path,0x40000000,1,0,mode,0x80,0);if(file==(HANDLE)(ULONG_PTR)-1){last_error=GetLastError();return 0;}
 DWORD count=0;BOOL ok=WriteFile(file,data,size,&count,0);if(!ok)last_error=GetLastError();CloseHandle(file);return ok&&count==size;
}
static void report(const char *phase){
 output_used=0;DWORD n=512;text("{\"protocol\":2,\"processId\":");number(GetCurrentProcessId());text(",\"user\":");if(GetUserNameW(wide_buffer,&n))json_wide(wide_buffer);else text("null");
 text(",\"phase\":");json_string(phase);text(",\"owner\":\"");const char*hex="0123456789abcdef";for(int i=0;i<16;i++){chr(hex[lease.owner[i]>>4]);chr(hex[lease.owner[i]&15]);}text("\",\"ackSequenceLow\":");number((DWORD)lease.sequence);
 text(",\"leaseMs\":45000,\"lastHeartbeatAgeMs\":");number((DWORD)(GetTickCount64()-last_seen));text(",\"lastError\":");number(last_error);text(",\"executionStateResult\":");number(execution_result);text(",\"settings\":[");
 for(int i=0;i<3;i++){if(i)chr(',');text("{\"index\":");number(i);text(",\"originalDC\":");number(backup.original[i]);text(",\"applyError\":");number(apply_error[i]);text(",\"restoreError\":");number(restore_error[i]);chr('}');}
 text("],\"appliedMask\":");number(backup.mask);text(",\"inputSent\":false,\"securityChanged\":false}\n");write_file(report_path,output,output_used,2);
}
static void peer_owned(void){
 /* A fresh kernel observation; never overwrite the existing worker's report. */
 read_file(heartbeat_path,&lease,sizeof(lease));output_used=0;
 text("{\"protocol\":2,\"kernelMutexOwned\":true,\"probePid\":");number(GetCurrentProcessId());text(",\"heartbeatSequenceLow\":");number((DWORD)lease.sequence);text(",\"inputSent\":false}\n");
 write_file((const WCHAR*)ROOT L"usb-power-ensure.json",output,output_used,2);
}
static int restore(void){
 int ok=1;for(int i=0;i<3;i++)if(backup.mask&(1UL<<i)){
  DWORD current=0,error=PowerReadDCValueIndex(0,&backup.scheme,group(i),&settings[i],&current);
  if(error)restore_error[i]=error;
  else if(current!=0&&current!=backup.original[i])restore_error[i]=183; /* user changed it: retain their value */
  else if(current==0)restore_error[i]=PowerWriteDCValueIndex(0,&backup.scheme,group(i),&settings[i],backup.original[i]);
  if(restore_error[i])ok=0;
 }
 Guid*active=0;if(!PowerGetActiveScheme(0,&active)&&active){if(same(active,&backup.scheme,sizeof(Guid)))PowerSetActiveScheme(0,active);LocalFree(active);}
 if(ok)DeleteFileW(backup_path);return ok;
}
void API usb_power_entry(void){
 HANDLE mutex=CreateMutexW(0,0,(const WCHAR*)L"Local\\RiceHoloLensUsbNormalPowerV1");if(!mutex)ExitProcess(2);
 DWORD wait=WaitForSingleObject(mutex,0);if(wait!=0&&wait!=0x80){if(wait==258)peer_owned();CloseHandle(mutex);ExitProcess(0);}
 last_seen=GetTickCount64();
 if(read_file(backup_path,&backup,sizeof(backup))){
  if(backup.magic!=0x48555042||backup.version!=1||backup.mask>7){last_error=13;report("invalid_backup");goto done;}
  if(!restore()){report("recovery_pending");goto done;}
 }
 if(!read_file(heartbeat_path,&lease,sizeof(lease))||lease.magic!=0x48555048||lease.version!=1){last_error=13;report("invalid_heartbeat");goto done;}
 ReasonContext reason={0};reason.flags=1;reason.reason.simple=(WCHAR*)L"Pinned USB power lease watchdog";
 execution_request=PowerCreateRequest(&reason);
 if(execution_request==(HANDLE)(ULONG_PTR)-1){last_error=GetLastError();execution_request=0;report("execution_request_failed");goto done;}
 if(!PowerSetRequest(execution_request,3)){last_error=GetLastError();report("execution_request_failed");CloseHandle(execution_request);execution_request=0;goto done;}
 backup.magic=0x48555042;backup.version=1;backup.mask=0;Guid*scheme=0;
 last_error=PowerGetActiveScheme(0,&scheme);if(last_error||!scheme){report("read_failed");goto done;}backup.scheme=*scheme;LocalFree(scheme);
 for(int i=0;i<3;i++){last_error=PowerReadDCValueIndex(0,&backup.scheme,group(i),&settings[i],&backup.original[i]);if(last_error){report("read_failed");goto done;}}
 /* Persist all intended writes BEFORE changing them, to recover after a crash. */
 backup.mask=7;if(!write_file(backup_path,&backup,sizeof(backup),1)){report("backup_failed");goto done;}
 for(int i=0;i<3;i++)apply_error[i]=PowerWriteDCValueIndex(0,&backup.scheme,group(i),&settings[i],0);
 last_error=PowerSetActiveScheme(0,&backup.scheme);
 execution_result=SetThreadExecutionState(0x80000003UL);last_seen=GetTickCount64();report("active");
 for(int i=0;i<3;i++)if(apply_error[i]){last_error=apply_error[i];goto release;}
 {
  unsigned long long started=last_seen,last_report=last_seen;
  while(GetTickCount64()-last_seen<45000&&GetTickCount64()-started<86400000){
   Sleep(500);Heartbeat next;
   if(read_file(heartbeat_path,&next,sizeof(next))&&next.magic==0x48555048&&next.version==1){
    if(!same(next.owner,lease.owner,16))break;
    if(next.sequence!=lease.sequence){lease=next;last_seen=GetTickCount64();}
   }
   if(GetTickCount64()-last_report>=5000){last_report=GetTickCount64();report("active");}
  }
 }
release:
 SetThreadExecutionState(0x80000000UL);if(restore())report("released");else report("restore_pending");
done:
 if(execution_request){PowerClearRequest(execution_request,3);CloseHandle(execution_request);}
 ReleaseMutex(mutex);CloseHandle(mutex);ExitProcess(0);
}
