/* Core Audio render endpoints only. Default is read-only; --mute explicitly
 * sets playback mute and zero volume, then independently reads both values. */
#define hl_entry unused_audio_token_entry
#include "../../../native/hl-token-probe.c"
#undef hl_entry
typedef long HRESULT;
typedef struct {DWORD a;unsigned short b,c;BYTE d[8];} GUID;
typedef struct {void **v;} Object;
IMPORT HRESULT API CoInitializeEx(void*,DWORD);
IMPORT void API CoUninitialize(void);
IMPORT HRESULT API CoCreateInstance(const GUID*,void*,DWORD,const GUID*,void**);
IMPORT WCHAR* API GetCommandLineW(void);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
#include "../../../native/hl-report-path.h"
typedef HRESULT(API *DefaultFn)(Object*,int,int,Object**);
typedef HRESULT(API *ActivateFn)(Object*,const GUID*,DWORD,void*,Object**);
typedef HRESULT(API *GetVolumeFn)(Object*,float*);
typedef HRESULT(API *SetVolumeFn)(Object*,float,const GUID*);
typedef HRESULT(API *GetMuteFn)(Object*,BOOL*);
typedef HRESULT(API *SetMuteFn)(Object*,BOOL,const GUID*);
static const GUID enumerator_clsid={0xbcde0395,0xe52f,0x467c,{0x8e,0x3d,0xc4,0x57,0x92,0x91,0x69,0x2e}};
static const GUID enumerator_iid={0xa95664d2,0x9614,0x4f35,{0xa7,0x46,0xde,0x8d,0xb6,0x36,0x17,0xe6}};
static const GUID volume_iid={0x5cdf2c82,0x841e,0x4546,{0x97,0x22,0x0c,0xf7,0x40,0x78,0x22,0x9a}};
static void release(Object*o){if(o)((DWORD(API*)(Object*))o->v[2])(o);}
static void hr(HRESULT value){const char*h="0123456789ABCDEF";text("\"0x");for(int i=7;i>=0;i--)chr(h[((DWORD)value>>(i*4))&15]);chr('"');}
static int mute_requested(void){const WCHAR*s=GetCommandLineW();for(;*s;s++)if(s[0]==' '&&s[1]=='-'&&s[2]=='-'&&s[3]=='m'&&s[4]=='u'&&s[5]=='t'&&s[6]=='e'&&(!s[7]||s[7]==' '))return 1;return 0;}
void API audio_probe_entry(void){
 const WCHAR*path=0;
 if(!hl_report_path((const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\audio.json",(const WCHAR*)L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\",&path))ExitProcess(64);
 HANDLE file=CreateFileW(path,0x40000000,1,0,1,0x80,0);if(file==(HANDLE)(ULONG_PTR)-1)ExitProcess(3);
 int change=mute_requested(),verified=0;HRESULT init=CoInitializeEx(0,0),created=(HRESULT)0x8000000a;Object*enumerator=0;
 if(init>=0)created=CoCreateInstance(&enumerator_clsid,0,1,&enumerator_iid,(void**)&enumerator);
 text("{\"schema_version\":1,\"playbackOnly\":true,\"muteRequested\":");text(change?"true":"false");text(",\"comInitialize\":");hr(init);text(",\"enumerator\":");hr(created);text(",\"roles\":[");
 for(int role=0;role<3;role++){
  Object*device=0,*volume=0;HRESULT endpoint=(HRESULT)0x8000000a,activate=endpoint,beforeVolume=endpoint,beforeMute=endpoint,setMute=endpoint,setVolume=endpoint,afterVolume=endpoint,afterMute=endpoint;float oldLevel=-1,newLevel=-1;BOOL oldMute=-1,newMute=-1;
  if(enumerator)endpoint=((DefaultFn)enumerator->v[4])(enumerator,0,role,&device);
  if(endpoint>=0)activate=((ActivateFn)device->v[3])(device,&volume_iid,23,0,&volume);
  if(activate>=0){beforeVolume=((GetVolumeFn)volume->v[9])(volume,&oldLevel);beforeMute=((GetMuteFn)volume->v[15])(volume,&oldMute);
   if(change){setMute=((SetMuteFn)volume->v[14])(volume,1,0);setVolume=((SetVolumeFn)volume->v[7])(volume,0.0f,0);}
   afterVolume=((GetVolumeFn)volume->v[9])(volume,&newLevel);afterMute=((GetMuteFn)volume->v[15])(volume,&newMute);
  }
  if(role)chr(',');text("{\"role\":");number(role);text(",\"endpoint\":");hr(endpoint);text(",\"activate\":");hr(activate);
  text(",\"beforeVolumeRead\":");hr(beforeVolume);text(",\"beforeVolumePermille\":");if(beforeVolume>=0)number((DWORD)(oldLevel*1000.0f+0.5f));else text("null");text(",\"beforeMuteRead\":");hr(beforeMute);text(",\"beforeMute\":");if(beforeMute>=0)text(oldMute?"true":"false");else text("null");
  text(",\"setMute\":");hr(setMute);text(",\"setVolume\":");hr(setVolume);text(",\"afterVolumeRead\":");hr(afterVolume);text(",\"afterVolumePermille\":");if(afterVolume>=0)number((DWORD)(newLevel*1000.0f+0.5f));else text("null");text(",\"afterMuteRead\":");hr(afterMute);text(",\"afterMute\":");if(afterMute>=0)text(newMute?"true":"false");else text("null");
  int ok=afterVolume>=0&&afterMute>=0&&newMute&&newLevel<0.0001f;if(ok)verified++;text(",\"silentVerified\":");text(ok?"true":"false");chr('}');release(volume);release(device);
 }
 text("],\"allPlaybackRolesSilent\":");text(verified==3?"true":"false");text("}\n");DWORD written=0;WriteFile(file,output,output_used,&written,0);CloseHandle(file);release(enumerator);if(init>=0)CoUninitialize();flush();ExitProcess(change&&verified!=3?2:0);
}
