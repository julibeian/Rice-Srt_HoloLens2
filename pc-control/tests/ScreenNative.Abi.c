/* Exercises the real DLL without opening a picker or a capture session. */
#define CINTERFACE
#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <roapi.h>
#include "ScreenNative.h"
typedef __x_Rice_CHoloLens_CScreenNative_CIProbe Probe;
typedef HRESULT(WINAPI*GetFactory)(HSTRING,IActivationFactory**);
typedef HRESULT(WINAPI*CanUnload)(void);
static const GUID iid_probe={0xee34c01b,0x9e1a,0x4148,{0xb8,0x33,0x87,0x3d,0x42,0x53,0x8c,0x94}};
static const GUID wrong_iid={0x12345678,0x9abc,0x4def,{1,2,3,4,5,6,7,8}};
static DWORD checks=0;
static void check(BOOL ok){if(!ok)ExitProcess(10+checks);checks++;}
static UINT32 length(const WCHAR*s){UINT32 n=0;while(s[n])n++;return n;}
static HSTRING string(const WCHAR*s){HSTRING result=NULL;check(SUCCEEDED(WindowsCreateString(s,length(s),&result)));return result;}
static void write_text(const WCHAR*s){DWORD n=WideCharToMultiByte(CP_UTF8,0,s,-1,NULL,0,NULL,NULL);char*data=HeapAlloc(GetProcessHeap(),0,n);if(!data)ExitProcess(90);WideCharToMultiByte(CP_UTF8,0,s,-1,data,n,NULL,NULL);DWORD written=0;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),data,n-1,&written,NULL);HeapFree(GetProcessHeap(),0,data);}
void screen_native_abi_entry(void){
 int argc=0;LPWSTR*argv=CommandLineToArgvW(GetCommandLineW(),&argc);check(argc==2);check(SUCCEEDED(RoInitialize(RO_INIT_MULTITHREADED)));
 HMODULE dll=LoadLibraryW(argv[1]);check(dll!=NULL);GetFactory get=(GetFactory)(void*)GetProcAddress(dll,"DllGetActivationFactory");CanUnload unload=(CanUnload)(void*)GetProcAddress(dll,"DllCanUnloadNow");check(get&&unload);check(unload()==S_FALSE);
 IActivationFactory*f=NULL;HSTRING name=string(L"Unknown.Class");check(get(name,&f)==CLASS_E_CLASSNOTAVAILABLE&&f==NULL);WindowsDeleteString(name);
 name=string(L"Rice.HoloLens.ScreenNative.Probe");check(get(name,NULL)==E_POINTER);check(get(name,&f)==S_OK&&f!=NULL);WindowsDeleteString(name);
 IInspectable*object=NULL;check(f->lpVtbl->ActivateInstance(f,&object)==S_OK&&object);Probe*p=NULL;check(object->lpVtbl->QueryInterface(object,&iid_probe,(void**)&p)==S_OK&&p);
 void*unexpected=(void*)1;check(p->lpVtbl->QueryInterface(p,&wrong_iid,&unexpected)==E_NOINTERFACE&&unexpected==NULL);
 ULONG count=0;IID*iids=NULL;check(p->lpVtbl->GetIids(p,&count,&iids)==S_OK&&count==1);CoTaskMemFree(iids);
 HSTRING runtime=NULL;check(p->lpVtbl->GetRuntimeClassName(p,&runtime)==S_OK);WindowsDeleteString(runtime);
 HSTRING inspection=NULL;check(p->lpVtbl->Inspect(p,&inspection)==S_OK&&inspection);write_text(L"{\"abi_pass\":true,\"inspection\":");write_text(WindowsGetStringRawBuffer(inspection,NULL));WindowsDeleteString(inspection);
 const WCHAR*invalid[]={L"",L"C:\\Other\\LocalState",L"C:\\..\\Rice.HoloLens.ScreenProbe_r5420n6798s24\\LocalState",L"C:/Rice.HoloLens.ScreenProbe_r5420n6798s24/LocalState"};
 for(int i=0;i<4;i++){HSTRING path=string(invalid[i]);check(p->lpVtbl->OpenPicker(p,path)==E_INVALIDARG);WindowsDeleteString(path);}
 check(p->lpVtbl->Stop(p)==S_OK);check(p->lpVtbl->Stop(p)==S_OK);check(p->lpVtbl->GetState(p,NULL)==E_POINTER);
 HSTRING after=NULL;check(p->lpVtbl->GetState(p,&after)==S_OK);write_text(L",\"after_invalid_requests\":");write_text(WindowsGetStringRawBuffer(after,NULL));WindowsDeleteString(after);
 write_text(L",\"picker_requests\":0,\"capture_sessions\":0,\"ui_opened\":false,\"checks\":");WCHAR digits[16],reverse[16];DWORD n=0,value=checks;do{reverse[n++]=(WCHAR)(L'0'+value%10);value/=10;}while(value);for(DWORD i=0;i<n;i++)digits[i]=reverse[n-i-1];digits[n]=0;write_text(digits);write_text(L"}\n");
 p->lpVtbl->Release(p);object->lpVtbl->Release(object);f->lpVtbl->Release(f);LocalFree(argv);RoUninitialize();ExitProcess(0);
}
