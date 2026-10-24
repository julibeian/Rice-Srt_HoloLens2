/* Bounded native UWP lifecycle test. No camera, network, input injection, or
 * OS setting changes. Logs this app's window creation and lifecycle; opens only
 * the isolated static SurfaceProbe using the public modal protocol API.
 */
#define CINTERFACE
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.applicationmodel.core.h>
#include <windows.ui.core.h>
#include <windows.graphics.holographic.h>
#include <windows.storage.h>
#include <d3d11.h>
#define ENABLE_MODAL_TEST 1
__declspec(dllimport) HRESULT WINAPI CreateDirect3D11DeviceFromDXGIDevice(IDXGIDevice*,IInspectable**);
int _fltused=0;
const IID IID_IDXGIDevice={0x54ec77fa,0x1377,0x44e6,{0x8c,0x32,0x88,0xfd,0x5f,0x44,0xc8,0x4c}};
const IID IID_ID3D11Texture2D={0x6f15aaf2,0xd208,0x4e89,{0x9a,0xb4,0x48,0x95,0x35,0xd3,0x4f,0x9c}};

const IID IID___x_ABI_CWindows_CStorage_CIApplicationDataStatics={0x5612147b,0xe843,0x45e3,{0x94,0xd8,0x06,0x16,0x9e,0x3c,0x8e,0x17}};
const IID IID___x_ABI_CWindows_CStorage_CIStorageItem={0x4207a996,0xca2f,0x42f7,{0xbd,0xe8,0x8b,0x10,0x45,0x7a,0x7f,0x30}};
const IID IID___x_ABI_CWindows_CApplicationModel_CCore_CICoreApplication={0x0aacf7a4,0x5e1d,0x49df,{0x80,0x34,0xfb,0x6a,0x68,0xbc,0x5e,0xd1}};
const IID IID___x_ABI_CWindows_CApplicationModel_CCore_CIFrameworkView={0xfaab5cd0,0x8924,0x45ac,{0xad,0x0f,0xa0,0x8f,0xae,0x5d,0x03,0x24}};
const IID IID___x_ABI_CWindows_CApplicationModel_CCore_CIFrameworkViewSource={0xcd770614,0x65c4,0x426c,{0x94,0x94,0x34,0xfc,0x43,0x55,0x48,0x62}};
const IID IID___x_ABI_CWindows_CGraphics_CHolographic_CIHolographicSpaceStatics={0x364e6064,0xc8f2,0x3ba1,{0x83,0x91,0x66,0xb8,0x48,0x9e,0x67,0xfd}};
static const IID space2_iid={0x4f81a9a8,0xb7ff,0x4883,{0x98,0x27,0x7d,0x67,0x72,0x87,0xea,0x70}};
static const IID activated_iid={0xcf193a96,0xeb13,0x5e3b,{0x8b,0xdf,0x87,0xb6,0xef,0xae,0x83,0x39}};
static const IID uri_factory_iid={0x44a9796f,0x723e,0x4fdf,{0xa2,0x18,0x03,0x3e,0x75,0xb0,0xc0,0x84}};
static const IID launcher2_iid={0x59ba2fbb,0x24cb,0x4c02,{0xa4,0xc4,0x82,0x94,0x56,0x9d,0x54,0xf1}};
static const IID options_iid={0xbafa21d8,0xb071,0x4cd8,{0x85,0x3e,0x34,0x12,0x03,0xe5,0x57,0xd3}};
static const IID options2_iid={0x3ba08eb4,0x6e40,0x4dce,{0xa1,0xa3,0x2f,0x53,0x95,0x0a,0xfb,0x49}};
static const IID async_info_iid={0x00000036,0x0000,0x0000,{0xc0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};
static const IID direct3d_device_iid={0xa37624ab,0x8d5f,0x4650,{0x9d,0x3e,0x9e,0xae,0x3d,0x9b,0xc6,0x70}};
static const IID dxgi_access_iid={0xa9b3d012,0x3df2,0x4ee3,{0xb8,0xd1,0x86,0x95,0xf4,0x57,0xd3,0xc1}};
static const IID camera_added_iid={0x71d80b7c,0x1d27,0x5102,{0x83,0xd1,0x4f,0x0e,0xfc,0x7c,0x9d,0x6f}};

typedef __x_ABI_CWindows_CApplicationModel_CCore_CIFrameworkView View;
typedef __x_ABI_CWindows_CApplicationModel_CCore_CIFrameworkViewVtbl ViewVtbl;
typedef __x_ABI_CWindows_CApplicationModel_CCore_CIFrameworkViewSource Source;
typedef __x_ABI_CWindows_CApplicationModel_CCore_CIFrameworkViewSourceVtbl SourceVtbl;
typedef __x_ABI_CWindows_CApplicationModel_CCore_CICoreApplication CoreApp;
typedef __x_ABI_CWindows_CUI_CCore_CICoreWindow Window;
typedef __x_ABI_CWindows_CUI_CCore_CICoreDispatcher Dispatcher;
typedef __x_ABI_CWindows_CGraphics_CHolographic_CIHolographicSpace Space;
typedef __x_ABI_CWindows_CGraphics_CHolographic_CIHolographicSpaceStatics SpaceStatics;
typedef __x_ABI_CWindows_CStorage_CIApplicationDataStatics DataStatics;
typedef __x_ABI_CWindows_CStorage_CIApplicationData Data;
typedef __x_ABI_CWindows_CStorage_CIStorageFolder Folder;
typedef __x_ABI_CWindows_CStorage_CIStorageItem Item;
typedef __x_ABI_CWindows_CGraphics_CHolographic_CIHolographicSpace2 Space2;
typedef __FITypedEventHandler_2_Windows__CApplicationModel__CCore__CCoreApplicationView_Windows__CApplicationModel__CActivation__CIActivatedEventArgs Activated;
typedef __FITypedEventHandler_2_Windows__CApplicationModel__CCore__CCoreApplicationView_Windows__CApplicationModel__CActivation__CIActivatedEventArgsVtbl ActivatedVtbl;
typedef __FITypedEventHandler_2_Windows__CGraphics__CHolographic__CHolographicSpace_Windows__CGraphics__CHolographic__CHolographicSpaceCameraAddedEventArgs CameraAdded;
typedef __FITypedEventHandler_2_Windows__CGraphics__CHolographic__CHolographicSpace_Windows__CGraphics__CHolographic__CHolographicSpaceCameraAddedEventArgsVtbl CameraAddedVtbl;
typedef struct Object{void**v;}Object;
typedef HRESULT (STDMETHODCALLTYPE *QueryFn)(Object*,REFIID,Object**);
typedef ULONG (STDMETHODCALLTYPE *ReleaseFn)(Object*);
typedef HRESULT (STDMETHODCALLTYPE *CreateUriFn)(Object*,HSTRING,Object**);
typedef HRESULT (STDMETHODCALLTYPE *PutStringFn)(Object*,HSTRING);
typedef HRESULT (STDMETHODCALLTYPE *LaunchModalFn)(Object*,Object*,Object*,Object**);
typedef HRESULT (STDMETHODCALLTYPE *StatusFn)(Object*,int*);
typedef HRESULT (STDMETHODCALLTYPE *ErrorFn)(Object*,HRESULT*);
typedef HRESULT (STDMETHODCALLTYPE *CancelFn)(Object*);
typedef HRESULT (STDMETHODCALLTYPE *GetInterfaceFn)(Object*,REFIID,void**);
static Object *modal_operation,*modal_info;
static Window *window;static Dispatcher *dispatcher;static Space *space;
static WCHAR log_path[2048];static char output[4096];static DWORD used,loops;static boolean visible;
static HRESULT holo_hr=E_PENDING,activate_hr=E_PENDING;
static HRESULT event_hr=E_PENDING,presence_hr=E_PENDING,modal_hr=E_PENDING,modal_error=E_PENDING;
static DWORD activations;static int modal_status=-1,modal_attempted,presence=-1;
static ID3D11Device*d3d;static ID3D11DeviceContext*context;
static HRESULT d3d_hr=E_PENDING,bind_hr=E_PENDING,frame_hr=E_PENDING,present_hr=E_PENDING;
static DWORD frames,rendered_cameras,session_id;
static volatile LONG camera_added_count;static HRESULT subscribe_camera_hr=E_PENDING;
static void text(const char*s){while(*s&&used<sizeof(output)-1)output[used++]=*s++;}
static void number(ULONGLONG n){char b[24];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i)output[used++]=b[--i];}
static void hexhr(HRESULT hr){const char*h="0123456789ABCDEF";text("\"0x");for(int i=7;i>=0;i--){char b[2]={h[((DWORD)hr>>(i*4))&15],0};text(b);}text("\"");}
static UINT32 len(const WCHAR*s){UINT32 n=0;while(s[n])n++;return n;}
static int guid_eq(REFIID a,REFIID b){const BYTE*x=(const BYTE*)a,*y=(const BYTE*)b;for(int i=0;i<16;i++)if(x[i]!=y[i])return 0;return 1;}
static HRESULT get_factory(const WCHAR*name,REFIID iid,void**value){HSTRING h=0;HRESULT hr=WindowsCreateString(name,len(name),&h);if(SUCCEEDED(hr))hr=RoGetActivationFactory(h,iid,value);if(h)WindowsDeleteString(h);return hr;}
static void initialize_log(void){
    DataStatics*s=0;Data*d=0;Folder*f=0;Item*i=0;HSTRING path=0;
    HRESULT hr=get_factory(L"Windows.Storage.ApplicationData",&IID___x_ABI_CWindows_CStorage_CIApplicationDataStatics,(void**)&s);
    if(SUCCEEDED(hr))hr=s->lpVtbl->get_Current(s,&d);
    if(SUCCEEDED(hr))hr=d->lpVtbl->get_LocalFolder(d,&f);
    if(SUCCEEDED(hr))hr=f->lpVtbl->QueryInterface(f,&IID___x_ABI_CWindows_CStorage_CIStorageItem,(void**)&i);
    if(SUCCEEDED(hr))hr=i->lpVtbl->get_Path(i,&path);
    if(SUCCEEDED(hr)){UINT32 n=0;const WCHAR*p=WindowsGetStringRawBuffer(path,&n);if(n<1900){for(UINT32 j=0;j<n;j++)log_path[j]=p[j];const WCHAR*tail=L"\\native-state.json";for(UINT32 j=0;tail[j];j++)log_path[n+j]=tail[j];}}
    if(path)WindowsDeleteString(path);if(i)i->lpVtbl->Release(i);if(f)f->lpVtbl->Release(f);if(d)d->lpVtbl->Release(d);if(s)s->lpVtbl->Release(s);
    if(!log_path[0]){const WCHAR*p=L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensNativeSurface\\native-state-debug.json";for(UINT32 j=0;p[j];j++)log_path[j]=p[j];}
}
static void record(const char*phase,HRESULT hr){
    if(window)window->lpVtbl->get_Visible(window,&visible);
    if(space){Space2*s2=0;presence_hr=space->lpVtbl->QueryInterface(space,&space2_iid,(void**)&s2);if(SUCCEEDED(presence_hr)){enum __x_ABI_CWindows_CGraphics_CHolographic_CHolographicSpaceUserPresence p;presence_hr=s2->lpVtbl->get_UserPresence(s2,&p);if(SUCCEEDED(presence_hr))presence=(int)p;s2->lpVtbl->Release(s2);}}
    if(modal_info){HRESULT sh=((StatusFn)modal_info->v[7])(modal_info,&modal_status);if(FAILED(sh))modal_error=sh;else if(modal_status==2||modal_status==3)((ErrorFn)modal_info->v[8])(modal_info,&modal_error);}
    used=0;text("{\"version\":1,\"pid\":");number(GetCurrentProcessId());text(",\"phase\":\"");text(phase);text("\",\"hresult\":");hexhr(hr);
    text(",\"windowVisible\":");text(visible?"true":"false");text(",\"hasCoreWindow\":");text(window?"true":"false");text(",\"hasHolographicSpace\":");text(space?"true":"false");text(",\"createHolographicSpace\":");hexhr(holo_hr);text(",\"activateWindow\":");hexhr(activate_hr);text(",\"loops\":");number(loops);
    text(",\"tickMs\":");number(GetTickCount64());text(",\"activationEvents\":");number(activations);text(",\"subscribeActivated\":");hexhr(event_hr);text(",\"userPresenceHr\":");hexhr(presence_hr);text(",\"userPresence\":");if(presence<0)text("null");else number(presence);
    text(",\"modalAttempted\":");text(modal_attempted?"true":"false");text(",\"modalLaunchHr\":");hexhr(modal_hr);text(",\"modalStatus\":");if(modal_status<0)text("null");else number(modal_status);text(",\"modalError\":");hexhr(modal_error);text(",\"visualVerified\":false,\"boundedRunMs\":45000}\n");
    used-=2;text(",\"d3dCreate\":");hexhr(d3d_hr);text(",\"d3dBind\":");hexhr(bind_hr);text(",\"frameHr\":");hexhr(frame_hr);text(",\"presentHr\":");hexhr(present_hr);text(",\"presentedFrames\":");number(frames);text(",\"renderedCameras\":");number(rendered_cameras);text(",\"sessionId\":");number(session_id);text(",\"cameraAddedEvents\":");number((DWORD)camera_added_count);text(",\"subscribeCamera\":");hexhr(subscribe_camera_hr);text("}\n");
    output[used]=0;DWORD sent=0;HANDLE file=CreateFileW(log_path,GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);if(file!=INVALID_HANDLE_VALUE){WriteFile(file,output,used,&sent,0);CloseHandle(file);}OutputDebugStringA(output);
}
#define INSPECTABLE(TYPE,PREFIX,IIDVALUE,AGILE) \
static HRESULT STDMETHODCALLTYPE PREFIX##_query(TYPE*self,REFIID iid,void**out){if(!out)return E_POINTER;*out=0;if(guid_eq(iid,&IID_IUnknown)||guid_eq(iid,&IID_IInspectable)||guid_eq(iid,&IIDVALUE)||((AGILE)&&guid_eq(iid,&IID_IAgileObject))){*out=self;return S_OK;}return E_NOINTERFACE;} \
static ULONG STDMETHODCALLTYPE PREFIX##_add(TYPE*self){(void)self;return 2;} \
static ULONG STDMETHODCALLTYPE PREFIX##_release(TYPE*self){(void)self;return 1;} \
static HRESULT STDMETHODCALLTYPE PREFIX##_iids(TYPE*self,ULONG*n,IID**v){(void)self;if(!n||!v)return E_POINTER;*v=CoTaskMemAlloc(sizeof(IID));if(!*v)return E_OUTOFMEMORY;**v=IIDVALUE;*n=1;return S_OK;} \
static HRESULT STDMETHODCALLTYPE PREFIX##_name(TYPE*self,HSTRING*h){(void)self;return WindowsCreateString(L"Rice.HoloLens.NativeSurface.App",len(L"Rice.HoloLens.NativeSurface.App"),h);} \
static HRESULT STDMETHODCALLTYPE PREFIX##_trust(TYPE*self,TrustLevel*t){(void)self;*t=BaseTrust;return S_OK;}
INSPECTABLE(View,view,IID___x_ABI_CWindows_CApplicationModel_CCore_CIFrameworkView,0)
INSPECTABLE(Source,source,IID___x_ABI_CWindows_CApplicationModel_CCore_CIFrameworkViewSource,1)
static void release_object(Object*o){if(o)((ReleaseFn)o->v[2])(o);}
static void initialize_d3d(void){
    D3D_FEATURE_LEVEL requested[]={D3D_FEATURE_LEVEL_11_1,D3D_FEATURE_LEVEL_11_0},actual;
    d3d_hr=D3D11CreateDevice(0,D3D_DRIVER_TYPE_HARDWARE,0,D3D11_CREATE_DEVICE_BGRA_SUPPORT,requested,2,D3D11_SDK_VERSION,&d3d,&actual,&context);
    IDXGIDevice*dxgi=0;IInspectable*inspect=0;__x_ABI_CWindows_CGraphics_CDirectX_CDirect3D11_CIDirect3DDevice*winrt=0;
    bind_hr=d3d_hr;if(SUCCEEDED(bind_hr))bind_hr=d3d->lpVtbl->QueryInterface(d3d,&IID_IDXGIDevice,(void**)&dxgi);
    if(SUCCEEDED(bind_hr))bind_hr=CreateDirect3D11DeviceFromDXGIDevice(dxgi,&inspect);
    if(SUCCEEDED(bind_hr))bind_hr=inspect->lpVtbl->QueryInterface(inspect,&direct3d_device_iid,(void**)&winrt);
    if(SUCCEEDED(bind_hr))bind_hr=space->lpVtbl->SetDirect3D11Device(space,winrt);
    if(winrt)winrt->lpVtbl->Release(winrt);if(inspect)inspect->lpVtbl->Release(inspect);if(dxgi)dxgi->lpVtbl->Release(dxgi);record("d3d_initialized",bind_hr);
}
static void render_frame(void){
    if(!space||FAILED(bind_hr))return;
    __x_ABI_CWindows_CGraphics_CHolographic_CIHolographicFrame*frame=0;
    __x_ABI_CWindows_CGraphics_CHolographic_CIHolographicFramePrediction*prediction=0;
    __FIVectorView_1_Windows__CGraphics__CHolographic__CHolographicCameraPose*poses=0;
    frame_hr=space->lpVtbl->CreateNextFrame(space,&frame);
    if(SUCCEEDED(frame_hr))frame_hr=frame->lpVtbl->get_CurrentPrediction(frame,&prediction);
    if(SUCCEEDED(frame_hr))frame_hr=prediction->lpVtbl->get_CameraPoses(prediction,&poses);
    UINT32 count=0;if(SUCCEEDED(frame_hr))frame_hr=poses->lpVtbl->get_Size(poses,&count);
    for(UINT32 i=0;SUCCEEDED(frame_hr)&&i<count;i++){
        __x_ABI_CWindows_CGraphics_CHolographic_CIHolographicCameraPose*pose=0;
        __x_ABI_CWindows_CGraphics_CHolographic_CIHolographicCameraRenderingParameters*parameters=0;
        __x_ABI_CWindows_CGraphics_CDirectX_CDirect3D11_CIDirect3DSurface*surface=0;
        Object*access=0;ID3D11Texture2D*texture=0;ID3D11RenderTargetView*target=0;
        frame_hr=poses->lpVtbl->GetAt(poses,i,&pose);
        if(SUCCEEDED(frame_hr))frame_hr=frame->lpVtbl->GetRenderingParameters(frame,pose,&parameters);
        if(SUCCEEDED(frame_hr))frame_hr=parameters->lpVtbl->get_Direct3D11BackBuffer(parameters,&surface);
        if(SUCCEEDED(frame_hr))frame_hr=surface->lpVtbl->QueryInterface(surface,&dxgi_access_iid,(void**)&access);
        if(SUCCEEDED(frame_hr))frame_hr=((GetInterfaceFn)access->v[3])(access,&IID_ID3D11Texture2D,(void**)&texture);
        if(SUCCEEDED(frame_hr))frame_hr=d3d->lpVtbl->CreateRenderTargetView(d3d,(ID3D11Resource*)texture,0,&target);
        if(SUCCEEDED(frame_hr)){const FLOAT green[4]={0.015f,0.18f,0.055f,1.0f};context->lpVtbl->ClearRenderTargetView(context,target,green);rendered_cameras++;}
        if(target)target->lpVtbl->Release(target);if(texture)texture->lpVtbl->Release(texture);release_object(access);if(surface)surface->lpVtbl->Release(surface);if(parameters)parameters->lpVtbl->Release(parameters);if(pose)pose->lpVtbl->Release(pose);
    }
    if(SUCCEEDED(frame_hr)&&count){enum __x_ABI_CWindows_CGraphics_CHolographic_CHolographicFramePresentResult result;present_hr=frame->lpVtbl->PresentUsingCurrentPredictionWithBehavior(frame,HolographicFramePresentWaitBehavior_DoNotWaitForFrameToFinish,&result);if(SUCCEEDED(present_hr)&&result==HolographicFramePresentResult_Success)frames++;}
    if(poses)poses->lpVtbl->Release(poses);if(prediction)prediction->lpVtbl->Release(prediction);if(frame)frame->lpVtbl->Release(frame);
}
static void launch_modal(void){
    if(modal_attempted)return;modal_attempted=1;record("modal_enter",S_OK);
    Object *factory=0,*uri=0,*launcher=0,*instance=0,*options=0,*options2=0;HSTRING name=0,value=0;
    modal_hr=get_factory(L"Windows.Foundation.Uri",&uri_factory_iid,(void**)&factory);
    if(SUCCEEDED(modal_hr))modal_hr=WindowsCreateString(L"rice-hololens-surface://open",len(L"rice-hololens-surface://open"),&value);
    if(SUCCEEDED(modal_hr))modal_hr=((CreateUriFn)factory->v[6])(factory,value,&uri);
    if(value){WindowsDeleteString(value);value=0;}
    if(SUCCEEDED(modal_hr))modal_hr=get_factory(L"Windows.System.Launcher",&launcher2_iid,(void**)&launcher);
    if(SUCCEEDED(modal_hr))modal_hr=WindowsCreateString(L"Windows.System.LauncherOptions",len(L"Windows.System.LauncherOptions"),&name);
    if(SUCCEEDED(modal_hr))modal_hr=RoActivateInstance(name,(IInspectable**)&instance);
    if(name)WindowsDeleteString(name);
    if(SUCCEEDED(modal_hr))modal_hr=((QueryFn)instance->v[0])(instance,&options_iid,&options);
    if(SUCCEEDED(modal_hr))modal_hr=((QueryFn)options->v[0])(options,&options2_iid,&options2);
    if(SUCCEEDED(modal_hr))modal_hr=WindowsCreateString(L"Rice.HoloLens.SurfaceProbe_r5420n6798s24",len(L"Rice.HoloLens.SurfaceProbe_r5420n6798s24"),&value);
    if(SUCCEEDED(modal_hr))modal_hr=((PutStringFn)options2->v[7])(options2,value);
    if(value)WindowsDeleteString(value);
    if(SUCCEEDED(modal_hr))modal_hr=((LaunchModalFn)launcher->v[6])(launcher,uri,options,&modal_operation);
    if(SUCCEEDED(modal_hr))modal_hr=((QueryFn)modal_operation->v[0])(modal_operation,&async_info_iid,&modal_info);
    release_object(options2);release_object(options);release_object(instance);release_object(launcher);release_object(uri);release_object(factory);record("modal_requested",modal_hr);
}
static HRESULT STDMETHODCALLTYPE activated_query(Activated*self,REFIID iid,void**out){if(!out)return E_POINTER;*out=0;if(guid_eq(iid,&IID_IUnknown)||guid_eq(iid,&activated_iid)){*out=self;return S_OK;}return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE activated_add(Activated*self){(void)self;return 2;}
static ULONG STDMETHODCALLTYPE activated_release(Activated*self){(void)self;return 1;}
static HRESULT STDMETHODCALLTYPE activated_invoke(Activated*self,__x_ABI_CWindows_CApplicationModel_CCore_CICoreApplicationView*sender,__x_ABI_CWindows_CApplicationModel_CActivation_CIActivatedEventArgs*args){
    (void)self;(void)sender;(void)args;activations++;activate_hr=window?window->lpVtbl->Activate(window):E_POINTER;record("activated",activate_hr);if(ENABLE_MODAL_TEST&&SUCCEEDED(activate_hr))launch_modal();return S_OK;
}
static ActivatedVtbl activated_vtable={activated_query,activated_add,activated_release,activated_invoke};
static Activated activated_handler={&activated_vtable};
static HRESULT STDMETHODCALLTYPE camera_query(CameraAdded*self,REFIID iid,void**out){if(!out)return E_POINTER;*out=0;if(guid_eq(iid,&IID_IUnknown)||guid_eq(iid,&IID_IAgileObject)||guid_eq(iid,&camera_added_iid)){*out=self;return S_OK;}return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE camera_add(CameraAdded*self){(void)self;return 2;}
static ULONG STDMETHODCALLTYPE camera_release(CameraAdded*self){(void)self;return 1;}
static HRESULT STDMETHODCALLTYPE camera_invoke(CameraAdded*self,Space*sender,__x_ABI_CWindows_CGraphics_CHolographic_CIHolographicSpaceCameraAddedEventArgs*args){
    (void)self;(void)sender;InterlockedIncrement(&camera_added_count);__x_ABI_CWindows_CFoundation_CIDeferral*deferral=0;HRESULT hr=args->lpVtbl->GetDeferral(args,&deferral);if(SUCCEEDED(hr)){hr=deferral->lpVtbl->Complete(deferral);deferral->lpVtbl->Release(deferral);}return hr;
}
static CameraAddedVtbl camera_vtable={camera_query,camera_add,camera_release,camera_invoke};
static CameraAdded camera_handler={&camera_vtable};
static HRESULT STDMETHODCALLTYPE view_initialize(View*self,__x_ABI_CWindows_CApplicationModel_CCore_CICoreApplicationView*value){(void)self;EventRegistrationToken token;event_hr=value->lpVtbl->add_Activated(value,&activated_handler,&token);record("initialize",event_hr);return S_OK;}
static HRESULT STDMETHODCALLTYPE view_window(View*self,Window*value){
    (void)self;window=value;window->lpVtbl->AddRef(window);HRESULT hr=window->lpVtbl->get_Dispatcher(window,&dispatcher);record("set_window",hr);
    SpaceStatics*s=0;holo_hr=get_factory(L"Windows.Graphics.Holographic.HolographicSpace",&IID___x_ABI_CWindows_CGraphics_CHolographic_CIHolographicSpaceStatics,(void**)&s);
    if(SUCCEEDED(holo_hr))holo_hr=s->lpVtbl->CreateForCoreWindow(s,window,&space);if(s)s->lpVtbl->Release(s);record("holographic_space",holo_hr);if(SUCCEEDED(holo_hr)){EventRegistrationToken token;subscribe_camera_hr=space->lpVtbl->add_CameraAdded(space,&camera_handler,&token);initialize_d3d();}return S_OK;
}
static HRESULT STDMETHODCALLTYPE view_load(View*self,HSTRING entry){(void)self;(void)entry;record("load",S_OK);return S_OK;}
static HRESULT STDMETHODCALLTYPE view_run(View*self){
    (void)self;activate_hr=window?window->lpVtbl->Activate(window):E_POINTER;record("run_enter",activate_hr);
    ULONGLONG start=GetTickCount64(),last=0;
    while(GetTickCount64()-start<45000){HRESULT hr=dispatcher?dispatcher->lpVtbl->ProcessEvents(dispatcher,CoreProcessEventsOption_ProcessAllIfPresent):E_POINTER;loops++;if(FAILED(hr)){record("dispatcher_failed",hr);break;}if(window)window->lpVtbl->get_Visible(window,&visible);if(visible)render_frame();if(GetTickCount64()-last>1000){record(visible?"run_active":"run_window_not_visible",hr);last=GetTickCount64();}if(ENABLE_MODAL_TEST&&frames>=3)launch_modal();Sleep(10);}
    if(modal_info&&modal_status==0)((CancelFn)modal_info->v[9])(modal_info);record("run_exit",S_OK);return S_OK;
}
static HRESULT STDMETHODCALLTYPE view_uninitialize(View*self){(void)self;record("uninitialize",S_OK);if(context){context->lpVtbl->Release(context);context=0;}if(d3d){d3d->lpVtbl->Release(d3d);d3d=0;}if(space){space->lpVtbl->Release(space);space=0;}if(dispatcher){dispatcher->lpVtbl->Release(dispatcher);dispatcher=0;}if(window){window->lpVtbl->Release(window);window=0;}return S_OK;}
static ViewVtbl view_vtable={view_query,view_add,view_release,view_iids,view_name,view_trust,view_initialize,view_window,view_load,view_run,view_uninitialize};
static View native_view={&view_vtable};
static HRESULT STDMETHODCALLTYPE source_create(Source*self,View**value){(void)self;*value=&native_view;record("create_view",S_OK);return S_OK;}
static SourceVtbl source_vtable={source_query,source_add,source_release,source_iids,source_name,source_trust,source_create};
static Source native_source={&source_vtable};
static DWORD WINAPI guard(void*unused){(void)unused;Sleep(60000);ExitProcess(124);return 0;}
void WINAPI native_surface_entry(void){
    HRESULT init=RoInitialize(RO_INIT_MULTITHREADED);ProcessIdToSessionId(GetCurrentProcessId(),&session_id);initialize_log();record("entry",init);
    HANDLE thread=CreateThread(0,0,guard,0,0,0);if(thread)CloseHandle(thread);
    CoreApp*app=0;HRESULT hr=get_factory(L"Windows.ApplicationModel.Core.CoreApplication",&IID___x_ABI_CWindows_CApplicationModel_CCore_CICoreApplication,(void**)&app);record("core_factory",hr);
    if(SUCCEEDED(hr)){hr=app->lpVtbl->Run(app,&native_source);record("core_run_returned",hr);app->lpVtbl->Release(app);}if(SUCCEEDED(init))RoUninitialize();ExitProcess(SUCCEEDED(hr)?0:2);
}
