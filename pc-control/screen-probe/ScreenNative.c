/* A small WinRT bridge for WGC, whose system types are hidden from JavaScript.
   The picker is opened only by OpenPicker on the application's UI thread.
   Capture is bounded to 20 seconds; this component has no input, audio or network. */
#define CINTERFACE
#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <roapi.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <d3d11.h>
#undef CHECK_NS_PREFIX_STATE
#include "ScreenNative.h"

typedef __x_Rice_CHoloLens_CScreenNative_CIProbe Probe;
typedef __x_ABI_CWindows_CGraphics_CCapture_CIGraphicsCaptureSessionStatics SessionStatics;
typedef __x_ABI_CWindows_CGraphics_CCapture_CIDirect3D11CaptureFramePoolStatics2 PoolStatics;
typedef __x_ABI_CWindows_CGraphics_CCapture_CIDirect3D11CaptureFramePool Pool;
typedef __x_ABI_CWindows_CGraphics_CCapture_CIGraphicsCapturePicker Picker;
typedef __x_ABI_CWindows_CGraphics_CCapture_CIGraphicsCaptureItem Item;
typedef __x_ABI_CWindows_CGraphics_CCapture_CIGraphicsCaptureSession Session;
typedef __x_ABI_CWindows_CGraphics_CCapture_CIDirect3D11CaptureFrame Frame;
typedef __x_ABI_CWindows_CGraphics_CDirectX_CDirect3D11_CIDirect3DDevice WinDevice;
typedef __x_ABI_CWindows_CGraphics_CDirectX_CDirect3D11_CIDirect3DSurface WinSurface;
typedef __x_ABI_CWindows_CFoundation_CIClosable Closable;
typedef __FIAsyncOperation_1_Windows__CGraphics__CCapture__CGraphicsCaptureItem PickOperation;
typedef struct __x_ABI_CWindows_CGraphics_CSizeInt32 Size;
typedef struct __x_ABI_CWindows_CFoundation_CTimeSpan TimeSpan;

static const GUID iid_probe={0xee34c01b,0x9e1a,0x4148,{0xb8,0x33,0x87,0x3d,0x42,0x53,0x8c,0x94}};
static const GUID iid_unknown={0,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const GUID iid_inspectable={0xaf86e2e0,0xb12d,0x4c6a,{0x9c,0x5a,0xd7,0xaa,0x65,0x10,0x1e,0x90}};
static const GUID iid_agile={0x94ea2b94,0xe9cc,0x49e0,{0xc0,0xff,0xee,0x64,0xca,0x8f,0x5b,0x90}};
static const GUID iid_factory={0x00000035,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const GUID iid_session_statics={0x2224a540,0x5974,0x49aa,{0xb2,0x32,0x08,0x82,0x53,0x6f,0x4c,0xb5}};
static const GUID iid_pool_statics={0x589b103f,0x6bbc,0x5df5,{0xa9,0x91,0x02,0xe2,0x8b,0x3b,0x66,0xd5}};
static const GUID iid_picker={0x5a1711b3,0xad79,0x4b4a,{0x93,0x36,0x13,0x18,0xfd,0xde,0x35,0x39}};
static const GUID iid_async_info={0x00000036,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const GUID iid_pick_operation={0x01ccf2ae,0x1059,0x5d57,{0xa8,0x05,0x0a,0x1d,0xfc,0x54,0xca,0xb9}};
static const GUID iid_closable={0x30d5a829,0x7fa4,0x4026,{0x83,0xbb,0xd7,0x5b,0xae,0x4e,0xa9,0x9e}};
static const GUID iid_dxgi_device={0x54ec77fa,0x1377,0x44e6,{0x8c,0x32,0x88,0xfd,0x5f,0x44,0xc8,0x4c}};
static const GUID iid_win_device={0xa37624ab,0x8d5f,0x4650,{0x9d,0x3e,0x9e,0xae,0x3d,0x9b,0xc6,0x70}};
static const GUID iid_texture={0x6f15aaf2,0xd208,0x4e89,{0x9a,0xb4,0x48,0x95,0x35,0xd3,0x4f,0x9c}};
static const GUID iid_dxgi_access={0xa9b3d012,0x3df2,0x4ee3,{0xb8,0xd1,0x86,0x95,0xf4,0x57,0xd3,0xc1}};
typedef struct DxgiAccess DxgiAccess;
typedef struct {HRESULT(STDMETHODCALLTYPE*QueryInterface)(DxgiAccess*,REFIID,void**);ULONG(STDMETHODCALLTYPE*AddRef)(DxgiAccess*);ULONG(STDMETHODCALLTYPE*Release)(DxgiAccess*);HRESULT(STDMETHODCALLTYPE*GetInterface)(DxgiAccess*,REFIID,void**);} DxgiAccessVtbl;
struct DxgiAccess {const DxgiAccessVtbl*lpVtbl;};

void *memcpy(void *dst,const void *src,size_t n){unsigned char*d=dst;const unsigned char*s=src;while(n--)*d++=*s++;return dst;}
void *memset(void *dst,int value,size_t n){unsigned char*d=dst;while(n--)*d++=(unsigned char)value;return dst;}
static UINT32 length(const WCHAR*s){UINT32 n=0;while(s&&s[n])n++;return n;}
static int equal(REFIID a,REFIID b){const BYTE*x=(const BYTE*)a,*y=(const BYTE*)b;for(int i=0;i<16;i++)if(x[i]!=y[i])return 0;return 1;}
static void copy_text(WCHAR*dst,UINT32 capacity,const WCHAR*src){UINT32 i=0;while(i+1<capacity&&src&&src[i]){dst[i]=src[i];i++;}if(i&&dst[i-1]>=0xd800&&dst[i-1]<=0xdbff)i--;dst[i]=0;}
#define RELEASE(x) do{if(x){(x)->lpVtbl->Release(x);(x)=NULL;}}while(0)
static HRESULT close_object(void*value){if(!value)return S_OK;IUnknown*u=value;Closable*c=NULL;HRESULT hr=u->lpVtbl->QueryInterface(u,&iid_closable,(void**)&c);if(SUCCEEDED(hr)){hr=c->lpVtbl->Close(c);RELEASE(c);}return hr;}
static HRESULT factory(const WCHAR*name,REFIID iid,void**out){HSTRING s=NULL;HRESULT hr=WindowsCreateString(name,length(name),&s);if(SUCCEEDED(hr)){hr=RoGetActivationFactory(s,iid,out);WindowsDeleteString(s);}return hr;}
static HRESULT activate(const WCHAR*name,IInspectable**out){HSTRING s=NULL;HRESULT hr=WindowsCreateString(name,length(name),&s);if(SUCCEEDED(hr)){hr=RoActivateInstance(s,out);WindowsDeleteString(s);}return hr;}

#define MAX_SAMPLES 2000
typedef struct {LONGLONG received_us,device_100ns;LONG width,height;} Observation;
typedef struct {
 WCHAR phase[40],stage[64],source_name[256],folder[1024],snapshot[80],stop_reason[32];
 HRESULT hr,snapshot_hr,session_close_hr,pool_close_hr,picker_cancel_hr,picker_close_hr;
 BOOL supported,device_created,pool_available,selected,started,terminal,picker_requested,picker_outcome_known,picker_cleanup_verified;
 LONG width,height,count;ULONGLONG capture_id;Observation samples[MAX_SAMPLES];
} State;
static State state={.phase=L"not_inspected",.snapshot_hr=E_PENDING,.picker_cancel_hr=E_PENDING,.picker_close_hr=E_PENDING,.picker_outcome_known=TRUE,.picker_cleanup_verified=TRUE};
static SRWLOCK state_lock=SRWLOCK_INIT;
static volatile LONG active=0,stop_requested=0;
static IAgileReference*operation_ref=NULL;

typedef struct {WCHAR*p;UINT32 n,capacity;BOOL overflow;} Json;
static void text(Json*j,const WCHAR*s){while(*s){if(j->n+1>=j->capacity){j->overflow=TRUE;return;}j->p[j->n++]=*s++;}j->p[j->n]=0;}
static void number(Json*j,LONGLONG n){WCHAR b[24];UINT32 i=0;ULONGLONG v;if(n<0){text(j,L"-");v=(ULONGLONG)(-(n+1))+1;}else v=(ULONGLONG)n;do{b[i++]=(WCHAR)(L'0'+v%10);v/=10;}while(v);while(i){WCHAR s[2]={b[--i],0};text(j,s);}}
static void quoted(Json*j,const WCHAR*s){text(j,L"\"");while(*s){WCHAR c=*s++;if(c==L'"')text(j,L"\\\"");else if(c==L'\\')text(j,L"\\\\");else if(c<32)text(j,L" ");else{WCHAR q[2]={c,0};text(j,q);}}text(j,L"\"");}
static void boolean_json(Json*j,BOOL value){text(j,value?L"true":L"false");}
static void hr_json(Json*j,HRESULT hr){const WCHAR digits[]=L"0123456789ABCDEF";WCHAR b[11]=L"0x00000000";for(int i=0;i<8;i++)b[9-i]=digits[((ULONG)hr>>(4*i))&15];quoted(j,b);}
static void phase(const WCHAR*p,const WCHAR*stage,HRESULT hr){AcquireSRWLockExclusive(&state_lock);copy_text(state.phase,40,p);copy_text(state.stage,64,stage);state.hr=hr;ReleaseSRWLockExclusive(&state_lock);}
static HRESULT get_state(Probe*self,HSTRING*out){(void)self;if(!out)return E_POINTER;*out=NULL;WCHAR*buffer=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,360000*sizeof(WCHAR));if(!buffer)return E_OUTOFMEMORY;Json j={buffer,0,360000,FALSE};
 AcquireSRWLockShared(&state_lock);
 text(&j,L"{\"component_protocol\":2,\"phase\":");quoted(&j,state.phase);text(&j,L",\"stage\":");quoted(&j,state.stage);text(&j,L",\"hresult\":");hr_json(&j,state.hr);
 text(&j,L",\"active\":");boolean_json(&j,InterlockedCompareExchange(&active,0,0)!=0);text(&j,L",\"terminal\":");boolean_json(&j,state.terminal);
 text(&j,L",\"supported\":");boolean_json(&j,state.supported);text(&j,L",\"device_created\":");boolean_json(&j,state.device_created);text(&j,L",\"frame_pool_factory_available\":");boolean_json(&j,state.pool_available);
 text(&j,L",\"source_selected\":");boolean_json(&j,state.selected);text(&j,L",\"capture_started\":");boolean_json(&j,state.started);text(&j,L",\"capture_id\":");number(&j,(LONGLONG)state.capture_id);
 text(&j,L",\"source\":{\"display_name\":");quoted(&j,state.source_name);text(&j,L",\"width\":");number(&j,state.width);text(&j,L",\"height\":");number(&j,state.height);text(&j,L",\"scope_verified\":false}");
 text(&j,L",\"frame_file\":");quoted(&j,state.snapshot);text(&j,L",\"snapshot_hresult\":");hr_json(&j,state.snapshot_hr);text(&j,L",\"session_close_hresult\":");hr_json(&j,state.session_close_hr);text(&j,L",\"pool_close_hresult\":");hr_json(&j,state.pool_close_hr);
 text(&j,L",\"stop_reason\":");quoted(&j,state.stop_reason);
 text(&j,L",\"picker_requested\":");boolean_json(&j,state.picker_requested);text(&j,L",\"picker_outcome_known\":");boolean_json(&j,state.picker_outcome_known);text(&j,L",\"picker_cleanup_verified\":");boolean_json(&j,state.picker_cleanup_verified);
 text(&j,L",\"picker_cancel_hresult\":");hr_json(&j,state.picker_cancel_hr);text(&j,L",\"picker_close_hresult\":");hr_json(&j,state.picker_close_hr);
 text(&j,L",\"observed_frames\":");number(&j,state.count);text(&j,L",\"duration_budget_ms\":20000,\"picker_budget_ms\":120000,\"observations\":[");
 if(state.terminal)for(LONG i=0;i<state.count;i++){if(i)text(&j,L",");text(&j,L"{\"received_us\":");number(&j,state.samples[i].received_us);text(&j,L",\"device_100ns\":");number(&j,state.samples[i].device_100ns);text(&j,L",\"width\":");number(&j,state.samples[i].width);text(&j,L",\"height\":");number(&j,state.samples[i].height);text(&j,L"}");}
 text(&j,L"]}");ReleaseSRWLockShared(&state_lock);HRESULT hr=j.overflow?E_BOUNDS:WindowsCreateString(buffer,j.n,out);HeapFree(GetProcessHeap(),0,buffer);return hr;
}

static HRESULT create_device(ID3D11Device**device,ID3D11DeviceContext**context,WinDevice**win_device){IDXGIDevice*dxgi=NULL;IInspectable*wrapped=NULL;
 HRESULT hr=D3D11CreateDevice(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,D3D11_CREATE_DEVICE_BGRA_SUPPORT,NULL,0,D3D11_SDK_VERSION,device,NULL,context);
 if(SUCCEEDED(hr))hr=(*device)->lpVtbl->QueryInterface(*device,&iid_dxgi_device,(void**)&dxgi);
 if(SUCCEEDED(hr))hr=CreateDirect3D11DeviceFromDXGIDevice(dxgi,&wrapped);
 if(SUCCEEDED(hr))hr=wrapped->lpVtbl->QueryInterface(wrapped,&iid_win_device,(void**)win_device);
 RELEASE(wrapped);RELEASE(dxgi);return hr;
}
static HRESULT inspect(Probe*self,HSTRING*out){
 if(InterlockedCompareExchange(&active,0,0))return get_state(self,out);
 AcquireSRWLockShared(&state_lock);BOOL pending_picker=state.picker_requested&&!state.picker_cleanup_verified;ReleaseSRWLockShared(&state_lock);
 if(pending_picker)return get_state(self,out);
 SessionStatics*ss=NULL;PoolStatics*ps=NULL;ID3D11Device*d=NULL;ID3D11DeviceContext*c=NULL;WinDevice*w=NULL;boolean supported=FALSE;
 const WCHAR*stage=L"session_factory";HRESULT hr=factory(L"Windows.Graphics.Capture.GraphicsCaptureSession",&iid_session_statics,(void**)&ss);
 if(SUCCEEDED(hr)){stage=L"is_supported";hr=ss->lpVtbl->IsSupported(ss,&supported);}
 AcquireSRWLockExclusive(&state_lock);state.supported=supported;ReleaseSRWLockExclusive(&state_lock);
 if(SUCCEEDED(hr)&&!supported)hr=E_NOTIMPL;
 if(SUCCEEDED(hr)){stage=L"d3d_device";hr=create_device(&d,&c,&w);}
 AcquireSRWLockExclusive(&state_lock);state.device_created=w!=NULL;ReleaseSRWLockExclusive(&state_lock);
 if(SUCCEEDED(hr)){stage=L"frame_pool_factory";hr=factory(L"Windows.Graphics.Capture.Direct3D11CaptureFramePool",&iid_pool_statics,(void**)&ps);}
 AcquireSRWLockExclusive(&state_lock);state.pool_available=ps!=NULL;state.terminal=FALSE;ReleaseSRWLockExclusive(&state_lock);
 RELEASE(w);RELEASE(c);RELEASE(d);RELEASE(ps);RELEASE(ss);phase(SUCCEEDED(hr)?L"ready":L"preflight_failed",stage,hr);return get_state(self,out);
}

static HRESULT copy_first(Frame*frame,ID3D11Device*device,ID3D11DeviceContext*context,ID3D11Texture2D**copy){WinSurface*surface=NULL;DxgiAccess*access=NULL;ID3D11Texture2D*texture=NULL;D3D11_TEXTURE2D_DESC desc;
 HRESULT hr=frame->lpVtbl->get_Surface(frame,&surface);
 if(SUCCEEDED(hr))hr=surface->lpVtbl->QueryInterface(surface,&iid_dxgi_access,(void**)&access);
 if(SUCCEEDED(hr))hr=access->lpVtbl->GetInterface(access,&iid_texture,(void**)&texture);
 if(SUCCEEDED(hr)){texture->lpVtbl->GetDesc(texture,&desc);if(desc.Width>4096||desc.Height>4096||desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM)hr=E_INVALIDARG;
 else{desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;desc.MiscFlags=0;hr=device->lpVtbl->CreateTexture2D(device,&desc,NULL,copy);if(SUCCEEDED(hr)){context->lpVtbl->CopyResource(context,(ID3D11Resource*)*copy,(ID3D11Resource*)texture);context->lpVtbl->Flush(context);}}}
 RELEASE(texture);RELEASE(access);RELEASE(surface);return hr;
}
static void put32(BYTE*b,UINT32 n){for(int i=0;i<4;i++)b[i]=(BYTE)(n>>(8*i));}
static HRESULT save_snapshot(ID3D11Texture2D*texture,ID3D11DeviceContext*context){if(!texture)return E_PENDING;D3D11_TEXTURE2D_DESC desc;D3D11_MAPPED_SUBRESOURCE map;texture->lpVtbl->GetDesc(texture,&desc);
 HRESULT hr=context->lpVtbl->Map(context,(ID3D11Resource*)texture,0,D3D11_MAP_READ,D3D11_MAP_FLAG_DO_NOT_WAIT,&map);if(FAILED(hr))return hr;
 WCHAR name[80]={0},path[1150]={0};Json nj={name,0,80,FALSE};text(&nj,L"capture-");number(&nj,(LONGLONG)state.capture_id);text(&nj,L".bmp");Json pj={path,0,1150,FALSE};text(&pj,state.folder);text(&pj,L"\\");text(&pj,name);
 HANDLE file=CreateFileW(path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);if(file==INVALID_HANDLE_VALUE){hr=HRESULT_FROM_WIN32(GetLastError());goto unmap;}
 BYTE header[54]={0};header[0]='B';header[1]='M';put32(header+2,54+desc.Width*desc.Height*4);put32(header+10,54);put32(header+14,40);put32(header+18,desc.Width);put32(header+22,(UINT32)(-(LONG)desc.Height));header[26]=1;header[28]=32;put32(header+34,desc.Width*desc.Height*4);
 DWORD written=0;if(!WriteFile(file,header,54,&written,NULL)||written!=54)hr=HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
 for(UINT32 y=0;SUCCEEDED(hr)&&y<desc.Height;y++)if(!WriteFile(file,(BYTE*)map.pData+(size_t)y*map.RowPitch,desc.Width*4,&written,NULL)||written!=desc.Width*4)hr=HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
 if(!CloseHandle(file)&&SUCCEEDED(hr))hr=HRESULT_FROM_WIN32(GetLastError());
 if(SUCCEEDED(hr)){AcquireSRWLockExclusive(&state_lock);copy_text(state.snapshot,80,name);ReleaseSRWLockExclusive(&state_lock);}
 unmap:context->lpVtbl->Unmap(context,(ID3D11Resource*)texture,0);return hr;
}

static BOOL continue_capture(BOOL*cancelled){if(InterlockedCompareExchange(&stop_requested,0,0))*cancelled=TRUE;return !*cancelled;}
static BOOL terminal_status(AsyncStatus status){return status==Completed||status==Canceled||status==Error;}
static void close_picker(IAsyncInfo*info,BOOL*known,HRESULT*close_hr){
 if(!info)return;AsyncStatus status=Started;
 HRESULT hr=info->lpVtbl->get_Status(info,&status);
 if(FAILED(hr)){*close_hr=hr;return;}
 *known=terminal_status(status);
 /* IAsyncInfo.Close is illegal while the operation is still running. */
 if(!*known){*close_hr=E_PENDING;return;}
 *close_hr=info->lpVtbl->Close(info);
}
static DWORD WINAPI capture_worker(void*unused){(void)unused;HRESULT initialized=RoInitialize(RO_INIT_MULTITHREADED),hr=initialized;const WCHAR*stage=L"worker_initialize";
 PickOperation*op=NULL;IAsyncInfo*info=NULL;Item*item=NULL;PoolStatics*ps=NULL;Pool*pool=NULL;Session*session=NULL;ID3D11Device*d=NULL;ID3D11DeviceContext*c=NULL;WinDevice*w=NULL;ID3D11Texture2D*snapshot=NULL;Size size={0};HSTRING name=NULL;LARGE_INTEGER frequency,start,now;BOOL cancelled=FALSE,picker_known=FALSE,cancel_sent=FALSE;HRESULT snapshot_hr=E_PENDING,session_close=S_OK,pool_close=S_OK,cancel_hr=E_PENDING,picker_close=E_PENDING;
 if(SUCCEEDED(hr)){stage=L"resolve_picker";hr=operation_ref->lpVtbl->Resolve(operation_ref,&iid_pick_operation,(void**)&op);}
 if(SUCCEEDED(hr)){stage=L"picker_status";hr=op->lpVtbl->QueryInterface(op,&iid_async_info,(void**)&info);}
 ULONGLONG picker_start=GetTickCount64(),cancel_deadline=0;
 while(SUCCEEDED(hr)){AsyncStatus status=Started;hr=info->lpVtbl->get_Status(info,&status);if(FAILED(hr))break;
  if(terminal_status(status))picker_known=TRUE;
  if(status==Completed)break;
  if(status==Canceled){cancelled=TRUE;break;}
  if(status==Error){info->lpVtbl->get_ErrorCode(info,&hr);if(SUCCEEDED(hr))hr=E_FAIL;break;}
  if(InterlockedCompareExchange(&stop_requested,0,0)||GetTickCount64()-picker_start>=120000){
   cancelled=TRUE;
   if(!cancel_sent){cancel_sent=TRUE;cancel_deadline=GetTickCount64()+2000;cancel_hr=info->lpVtbl->Cancel(info);if(FAILED(cancel_hr)){stage=L"cancel_picker";hr=cancel_hr;break;}}
   if(GetTickCount64()>=cancel_deadline){stage=L"picker_cancel_timeout";hr=HRESULT_FROM_WIN32(ERROR_TIMEOUT);break;}
  }Sleep(20);
 }
 /* Stop can arrive as the picker completes or during any setup call. */
 if(SUCCEEDED(hr)&&continue_capture(&cancelled)){stage=L"picker_result";hr=op->lpVtbl->GetResults(op,&item);if(SUCCEEDED(hr)&&!item)cancelled=TRUE;}
 if(item){AcquireSRWLockExclusive(&state_lock);state.selected=TRUE;ReleaseSRWLockExclusive(&state_lock);}
 if(SUCCEEDED(hr)&&continue_capture(&cancelled)){stage=L"item_size";hr=item->lpVtbl->get_Size(item,&size);if(SUCCEEDED(hr)&&(size.Width<16||size.Height<16||size.Width>4096||size.Height>4096))hr=E_INVALIDARG;
  if(SUCCEEDED(hr)&&continue_capture(&cancelled))item->lpVtbl->get_DisplayName(item,&name);AcquireSRWLockExclusive(&state_lock);state.width=size.Width;state.height=size.Height;copy_text(state.source_name,256,WindowsGetStringRawBuffer(name,NULL));ReleaseSRWLockExclusive(&state_lock);}
 if(SUCCEEDED(hr)&&continue_capture(&cancelled)){stage=L"d3d_device";hr=create_device(&d,&c,&w);}
 if(SUCCEEDED(hr)&&continue_capture(&cancelled)){stage=L"frame_pool_factory";hr=factory(L"Windows.Graphics.Capture.Direct3D11CaptureFramePool",&iid_pool_statics,(void**)&ps);}
 if(SUCCEEDED(hr)&&continue_capture(&cancelled)){stage=L"create_frame_pool";hr=ps->lpVtbl->CreateFreeThreaded(ps,w,DirectXPixelFormat_B8G8R8A8UIntNormalized,3,size,&pool);}
 if(SUCCEEDED(hr)&&continue_capture(&cancelled)){stage=L"create_session";hr=pool->lpVtbl->CreateCaptureSession(pool,item,&session);}
 if(SUCCEEDED(hr)&&continue_capture(&cancelled)){stage=L"start_capture";hr=session->lpVtbl->StartCapture(session);}
 if(SUCCEEDED(hr)&&!cancelled){
  AcquireSRWLockExclusive(&state_lock);state.started=TRUE;ReleaseSRWLockExclusive(&state_lock);phase(L"capturing",L"receive_frames",S_OK);
  QueryPerformanceFrequency(&frequency);QueryPerformanceCounter(&start);
  while(!InterlockedCompareExchange(&stop_requested,0,0)){
   QueryPerformanceCounter(&now);if((now.QuadPart-start.QuadPart)*1000/frequency.QuadPart>=20000)break;
   Frame*frame=NULL;stage=L"next_frame";hr=pool->lpVtbl->TryGetNextFrame(pool,&frame);if(FAILED(hr))break;
   if(!frame){Sleep(1);continue;}
   TimeSpan time={0};Size current={0};QueryPerformanceCounter(&now);stage=L"frame_timestamp";hr=frame->lpVtbl->get_SystemRelativeTime(frame,&time);if(SUCCEEDED(hr)){stage=L"frame_size";hr=frame->lpVtbl->get_ContentSize(frame,&current);}
   if(SUCCEEDED(hr)){
    AcquireSRWLockExclusive(&state_lock);if(state.count>=MAX_SAMPLES)hr=E_BOUNDS;else state.samples[state.count++]=(Observation){(now.QuadPart-start.QuadPart)*1000000/frequency.QuadPart,time.Duration,current.Width,current.Height};ReleaseSRWLockExclusive(&state_lock);
    if(snapshot_hr==E_PENDING)snapshot_hr=copy_first(frame,d,c,&snapshot);
    if(current.Width!=size.Width||current.Height!=size.Height){stage=L"source_resized";hr=E_CHANGED_STATE;}
   }
   HRESULT closed=close_object(frame);RELEASE(frame);if(SUCCEEDED(hr)&&FAILED(closed)){stage=L"close_frame";hr=closed;}if(FAILED(hr))break;
  }
 }
 session_close=close_object(session);pool_close=close_object(pool);RELEASE(session);RELEASE(pool);
 if(snapshot){snapshot_hr=save_snapshot(snapshot,c);RELEASE(snapshot);}
 if(SUCCEEDED(hr)&&FAILED(session_close)){hr=session_close;stage=L"close_session";}
 if(SUCCEEDED(hr)&&FAILED(pool_close)){hr=pool_close;stage=L"close_pool";}
 close_picker(info,&picker_known,&picker_close);
 if(SUCCEEDED(hr)&&FAILED(picker_close)){hr=picker_close;stage=L"close_picker";}
 RELEASE(info);RELEASE(op);RELEASE(item);RELEASE(ps);RELEASE(w);RELEASE(c);RELEASE(d);WindowsDeleteString(name);RELEASE(operation_ref);
 if(SUCCEEDED(initialized))RoUninitialize();
 AcquireSRWLockExclusive(&state_lock);state.snapshot_hr=snapshot_hr;state.session_close_hr=session_close;state.pool_close_hr=pool_close;state.picker_cancel_hr=cancel_hr;state.picker_close_hr=picker_close;state.picker_outcome_known=picker_known;state.picker_cleanup_verified=picker_known&&SUCCEEDED(picker_close);state.terminal=TRUE;copy_text(state.phase,40,FAILED(hr)?L"failed":cancelled?L"selection_cancelled":L"completed");copy_text(state.stage,64,stage);copy_text(state.stop_reason,32,FAILED(hr)?L"capture_error":InterlockedCompareExchange(&stop_requested,0,0)?L"stop_requested":cancelled?L"selection_cancelled_or_timeout":L"time_budget");state.hr=hr;ReleaseSRWLockExclusive(&state_lock);InterlockedExchange(&active,0);return 0;
}

static HRESULT open_picker(Probe*self,HSTRING local_folder){(void)self;UINT32 n=0;const WCHAR*path=WindowsGetStringRawBuffer(local_folder,&n);
 const WCHAR suffix[]=L"\\Rice.HoloLens.ScreenProbe_r5420n6798s24\\LocalState";UINT32 suffix_length=length(suffix);
 if(n<suffix_length||n>=1024||path[1]!=L':'||path[2]!=L'\\')return E_INVALIDARG;
 for(UINT32 i=0;i<n;i++){if(path[i]==L'/'||(path[i]==L'.'&&i+1<n&&path[i+1]==L'.'))return E_INVALIDARG;}
 for(UINT32 i=0;i<suffix_length;i++)if(path[n-suffix_length+i]!=suffix[i])return E_INVALIDARG;
 AcquireSRWLockShared(&state_lock);BOOL previous_unknown=state.picker_requested&&!state.picker_cleanup_verified;ReleaseSRWLockShared(&state_lock);
 if(previous_unknown)return E_ILLEGAL_METHOD_CALL;
 if(InterlockedCompareExchange(&active,1,0))return HRESULT_FROM_WIN32(ERROR_BUSY);
 InterlockedExchange(&stop_requested,0);AcquireSRWLockExclusive(&state_lock);state.count=0;state.selected=FALSE;state.started=FALSE;state.terminal=FALSE;state.source_name[0]=0;state.snapshot[0]=0;state.stop_reason[0]=0;state.capture_id=GetTickCount64();state.snapshot_hr=E_PENDING;state.session_close_hr=S_OK;state.pool_close_hr=S_OK;state.picker_cancel_hr=E_PENDING;state.picker_close_hr=E_PENDING;state.picker_requested=FALSE;state.picker_outcome_known=TRUE;state.picker_cleanup_verified=TRUE;copy_text(state.folder,1024,path);ReleaseSRWLockExclusive(&state_lock);phase(L"choosing_source",L"activate_picker",S_OK);
 IInspectable*object=NULL;Picker*picker=NULL;PickOperation*operation=NULL;HRESULT hr=activate(L"Windows.Graphics.Capture.GraphicsCapturePicker",&object);
 if(SUCCEEDED(hr))hr=object->lpVtbl->QueryInterface(object,&iid_picker,(void**)&picker);
 if(SUCCEEDED(hr)){AcquireSRWLockExclusive(&state_lock);state.picker_requested=TRUE;state.picker_outcome_known=FALSE;state.picker_cleanup_verified=FALSE;ReleaseSRWLockExclusive(&state_lock);hr=picker->lpVtbl->PickSingleItemAsync(picker,&operation);}
 if(SUCCEEDED(hr))hr=RoGetAgileReference(AGILEREFERENCE_DEFAULT,&iid_pick_operation,(IUnknown*)operation,&operation_ref);
 if(SUCCEEDED(hr)){HANDLE thread=CreateThread(NULL,0,capture_worker,NULL,0,NULL);if(thread)CloseHandle(thread);else hr=HRESULT_FROM_WIN32(GetLastError());}
 if(FAILED(hr)){
  IAsyncInfo*info=NULL;BOOL known=FALSE;HRESULT cancel_hr=E_PENDING,close_hr=E_PENDING;
  if(operation&&SUCCEEDED(operation->lpVtbl->QueryInterface(operation,&iid_async_info,(void**)&info))){AsyncStatus status=Started;if(SUCCEEDED(info->lpVtbl->get_Status(info,&status))){known=terminal_status(status);if(!known)cancel_hr=info->lpVtbl->Cancel(info);}close_picker(info,&known,&close_hr);RELEASE(info);}
  RELEASE(operation_ref);phase(L"failed",L"open_picker",hr);AcquireSRWLockExclusive(&state_lock);state.terminal=TRUE;if(state.picker_requested){state.picker_cancel_hr=cancel_hr;state.picker_close_hr=close_hr;state.picker_outcome_known=known;state.picker_cleanup_verified=known&&SUCCEEDED(close_hr);}ReleaseSRWLockExclusive(&state_lock);InterlockedExchange(&active,0);
 }RELEASE(operation);RELEASE(picker);RELEASE(object);return hr;
}
static HRESULT stop(Probe*self){(void)self;InterlockedExchange(&stop_requested,1);return S_OK;}

static HRESULT STDMETHODCALLTYPE probe_qi(Probe*self,REFIID iid,void**out){if(!out)return E_POINTER;*out=NULL;if(equal(iid,&iid_probe)||equal(iid,&iid_unknown)||equal(iid,&iid_inspectable)||equal(iid,&iid_agile)){*out=self;return S_OK;}return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE probe_ref(Probe*self){(void)self;return 2;}
static HRESULT STDMETHODCALLTYPE probe_iids(Probe*self,ULONG*count,IID**iids){(void)self;if(!count||!iids)return E_POINTER;*count=0;*iids=CoTaskMemAlloc(sizeof(IID));if(!*iids)return E_OUTOFMEMORY;**iids=iid_probe;*count=1;return S_OK;}
static HRESULT STDMETHODCALLTYPE class_name(Probe*self,HSTRING*out){(void)self;const WCHAR*n=L"Rice.HoloLens.ScreenNative.Probe";if(!out)return E_POINTER;return WindowsCreateString(n,length(n),out);}
static HRESULT STDMETHODCALLTYPE trust(Probe*self,TrustLevel*out){(void)self;if(!out)return E_POINTER;*out=BaseTrust;return S_OK;}
static const __x_Rice_CHoloLens_CScreenNative_CIProbeVtbl probe_vtbl={probe_qi,probe_ref,probe_ref,probe_iids,class_name,trust,inspect,open_picker,get_state,stop};
static Probe probe={&probe_vtbl};
static HRESULT STDMETHODCALLTYPE factory_qi(IActivationFactory*self,REFIID iid,void**out){if(!out)return E_POINTER;*out=NULL;if(equal(iid,&iid_factory)||equal(iid,&iid_unknown)||equal(iid,&iid_inspectable)||equal(iid,&iid_agile)){*out=self;return S_OK;}return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE factory_ref(IActivationFactory*self){(void)self;return 2;}
static HRESULT STDMETHODCALLTYPE factory_iids(IActivationFactory*self,ULONG*count,IID**iids){(void)self;if(!count||!iids)return E_POINTER;*count=0;*iids=CoTaskMemAlloc(sizeof(IID));if(!*iids)return E_OUTOFMEMORY;**iids=iid_factory;*count=1;return S_OK;}
static HRESULT STDMETHODCALLTYPE factory_name(IActivationFactory*self,HSTRING*out){(void)self;return class_name(&probe,out);}
static HRESULT STDMETHODCALLTYPE factory_trust(IActivationFactory*self,TrustLevel*out){(void)self;return trust(&probe,out);}
static HRESULT STDMETHODCALLTYPE factory_activate(IActivationFactory*self,IInspectable**out){(void)self;if(!out)return E_POINTER;*out=(IInspectable*)&probe;return S_OK;}
static const IActivationFactoryVtbl factory_vtbl={factory_qi,factory_ref,factory_ref,factory_iids,factory_name,factory_trust,factory_activate};
static IActivationFactory activation_factory={&factory_vtbl};
HRESULT WINAPI DllGetActivationFactory(HSTRING name,IActivationFactory**out){if(!out)return E_POINTER;*out=NULL;UINT32 n=0;const WCHAR*s=WindowsGetStringRawBuffer(name,&n);const WCHAR*expected=L"Rice.HoloLens.ScreenNative.Probe";if(n!=length(expected))return CLASS_E_CLASSNOTAVAILABLE;for(UINT32 i=0;i<n;i++)if(s[i]!=expected[i])return CLASS_E_CLASSNOTAVAILABLE;*out=&activation_factory;return S_OK;}
/* Static singleton and an outstanding worker must never be unloaded by a JS GC. */
HRESULT WINAPI DllCanUnloadNow(void){return S_FALSE;}
