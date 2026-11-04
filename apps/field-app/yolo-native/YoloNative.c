/* HoloLens in-process YOLO engine. No network, image upload or simulation input.
   The UI submits a fresh RGBA PV frame only when the single native slot is idle.
   Loading, preprocessing, inference and NMS all run on the owned MTA thread. */
#define CINTERFACE
#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <roapi.h>
#include <roerrorapi.h>
#include <restrictederrorinfo.h>
#include <windows.ai.machinelearning.h>
#include <bcrypt.h>
#undef CHECK_NS_PREFIX_STATE
/* MIDLRT emits the unprefixed system spelling; SDK C headers use ABI_. */
#define __x_Windows_CStorage_CStreams_CIBuffer __x_ABI_CWindows_CStorage_CStreams_CIBuffer
#include "YoloNative.h"
#include "YoloCore.h"

void*memcpy(void*d,const void*s,size_t n){unsigned char*a=d;const unsigned char*b=s;while(n--)*a++=*b++;return d;}
void*memset(void*d,int v,size_t n){unsigned char*a=d;while(n--)*a++=(unsigned char)v;return d;}
static UINT32 wlen(const WCHAR*s){UINT32 n=0;while(s&&s[n])n++;return n;}
static void wcopy(WCHAR*d,UINT32 n,const WCHAR*s){UINT32 i=0;while(s&&s[i]&&i+1<n){d[i]=s[i];i++;}d[i]=0;}
static int same(REFIID a,REFIID b){const BYTE*x=(const BYTE*)a,*y=(const BYTE*)b;for(int i=0;i<16;i++)if(x[i]!=y[i])return 0;return 1;}
static HSTRING hs(const WCHAR*s){HSTRING h=NULL;WindowsCreateString(s,wlen(s),&h);return h;}
static HRESULT factory(const WCHAR*name,const WCHAR*iid,void**out){GUID id;HRESULT hr=IIDFromString(iid,&id);HSTRING h=hs(name);if(SUCCEEDED(hr))hr=RoGetActivationFactory(h,&id,out);WindowsDeleteString(h);return hr;}
#define RELEASE(p) do{if(p){(p)->lpVtbl->Release(p);p=NULL;}}while(0)
static const GUID iid_unknown={0,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const GUID iid_inspectable={0xaf86e2e0,0xb12d,0x4c6a,{0x9c,0x5a,0xd7,0xaa,0x65,0x10,0x1e,0x90}};
static const GUID iid_agile={0x94ea2b94,0xe9cc,0x49e0,{0xc0,0xff,0xee,0x64,0xca,0x8f,0x5b,0x90}};
static const GUID iid_factory={0x00000035,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const GUID iid_detector={0x7e0645c1,0x3d55,0x4e34,{0x99,0xbb,0x41,0x66,0x65,0x92,0x2c,0x31}};
static const GUID iid_buffer_access={0x905a0fef,0xbc53,0x11df,{0x8c,0x49,0x00,0x1e,0x4f,0xc6,0x86,0xda}};
static const GUID iid_tensor={0xf2282d82,0xaa02,0x42c8,{0xa0,0xc8,0xdf,0x1e,0xfc,0x96,0x76,0xe1}};
static const GUID iid_closable={0x30d5a829,0x7fa4,0x4026,{0x83,0xbb,0xd7,0x5b,0xae,0x4e,0xa9,0x9e}};
typedef __x_Rice_CHoloLens_CYolo_CIDetector Detector;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModelStatics ModelFactory;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModel Model;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModelSessionFactory SessionFactory;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModelSession Session;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModelBindingFactory BindingFactory;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModelBinding Binding;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CITensorFloatStatics2 TensorFactory;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CITensorFloat Tensor;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModelEvaluationResult Result;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModelDeviceFactory DeviceFactory;
typedef __x_ABI_CWindows_CAI_CMachineLearning_CILearningModelDevice Device;
typedef struct BufferAccess BufferAccess;
typedef struct{HRESULT(STDMETHODCALLTYPE*QueryInterface)(BufferAccess*,REFIID,void**);ULONG(STDMETHODCALLTYPE*AddRef)(BufferAccess*);ULONG(STDMETHODCALLTYPE*Release)(BufferAccess*);HRESULT(STDMETHODCALLTYPE*Buffer)(BufferAccess*,BYTE**);} BufferAccessVtbl;
struct BufferAccess{const BufferAccessVtbl*lpVtbl;};
typedef struct{WCHAR phase[32],stage[48],error[600],path[1024],hash[65];HRESULT hr;BOOL loaded,busy,diagnostic;UINT32 device,frames,camera_frames,asset_frames,rejected,boxes_count;INT32 width,height;DOUBLE source_time,preprocess_ms,inference_ms;ULONGLONG started,submitted,finished,signature;YoloBox boxes[YOLO_DETECTIONS];} State;
static State state={.phase=L"stopped",.stage=L"not_started"};
static SRWLOCK guard=SRWLOCK_INIT;
static HANDLE worker_thread=NULL,work_event=NULL;
static volatile LONG active=0,stop_requested=0,object_refs=0;
static BYTE*pixels=NULL;static UINT32 pixel_capacity=0;
static struct{INT32 width,height;DOUBLE time;BOOL diagnostic;ULONGLONG submitted;} pending;
static DOUBLE last_camera_time=-1;
static const WCHAR*labels[6]={L"稻纵卷叶螟",L"稻水象甲",L"稻叶蝉",L"白叶枯病",L"胡麻斑病",L"稻瘟病"};
static void close_object(void*p){if(!p)return;IUnknown*u=p;__x_ABI_CWindows_CFoundation_CIClosable*c=NULL;if(SUCCEEDED(u->lpVtbl->QueryInterface(u,&iid_closable,(void**)&c))){c->lpVtbl->Close(c);RELEASE(c);}}
static void set_error(const WCHAR*stage,HRESULT hr){
 IRestrictedErrorInfo*err=NULL;BSTR desc=NULL,detail=NULL,cap=NULL;HRESULT ignored=0;
 if(SUCCEEDED(GetRestrictedErrorInfo(&err))&&err)err->lpVtbl->GetErrorDetails(err,&desc,&ignored,&detail,&cap);
 AcquireSRWLockExclusive(&guard);state.hr=hr;wcopy(state.phase,32,L"error");wcopy(state.stage,48,stage);wcopy(state.error,600,detail?detail:desc?desc:L"Native YOLO operation failed");state.loaded=FALSE;state.busy=FALSE;ReleaseSRWLockExclusive(&guard);
 if(desc)SysFreeString(desc);if(detail)SysFreeString(detail);if(cap)SysFreeString(cap);RELEASE(err);
}
static HRESULT verify_model(const WCHAR*path,const WCHAR*expected){
 if(wlen(expected)!=64)return E_INVALIDARG;
 HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);if(file==INVALID_HANDLE_VALUE)return HRESULT_FROM_WIN32(GetLastError());
 BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE hash=NULL;BYTE*object=NULL,*chunk=NULL,result[32];DWORD size=0,got=0;NTSTATUS status=BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0);
 if(status>=0)status=BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,(BYTE*)&size,sizeof(size),&got,0);
 if(status>=0){object=HeapAlloc(GetProcessHeap(),0,size);chunk=HeapAlloc(GetProcessHeap(),0,65536);if(!object||!chunk)status=(NTSTATUS)0xC0000017;}
 if(status>=0)status=BCryptCreateHash(alg,&hash,object,size,NULL,0,0);
 HRESULT hr=S_OK;
 while(status>=0){if(!ReadFile(file,chunk,65536,&got,NULL)){hr=HRESULT_FROM_WIN32(GetLastError());break;}if(!got)break;status=BCryptHashData(hash,chunk,got,0);}
 if(status>=0&&SUCCEEDED(hr))status=BCryptFinishHash(hash,result,sizeof(result),0);
 if(status<0)hr=E_FAIL;
 if(SUCCEEDED(hr)){const WCHAR*hex=L"0123456789abcdef";for(int i=0;i<32;i++)if(expected[2*i]!=hex[result[i]>>4]||expected[2*i+1]!=hex[result[i]&15]){hr=HRESULT_FROM_WIN32(ERROR_CRC);break;}}
 if(hash)BCryptDestroyHash(hash);if(alg)BCryptCloseAlgorithmProvider(alg,0);if(object)HeapFree(GetProcessHeap(),0,object);if(chunk)HeapFree(GetProcessHeap(),0,chunk);CloseHandle(file);return hr;
}
static DWORD WINAPI run_worker(void*unused){
 (void)unused;HRESULT ro=RoInitialize(RO_INIT_MULTITHREADED),hr=ro;const WCHAR*stage=L"ro_initialize";
 ModelFactory*mf=NULL;Model*model=NULL;SessionFactory*sf=NULL;Session*session=NULL;BindingFactory*bf=NULL;Binding*binding=NULL;TensorFactory*tf=NULL;DeviceFactory*df=NULL;Device*device=NULL;
 Tensor*input=NULL,*output=NULL;Result*result=NULL;__FIMapView_2_HSTRING_IInspectable*outputs=NULL;IInspectable*value=NULL;__FIVectorView_1_float*values=NULL;
 float*tensor=NULL,*raw=NULL;YoloBox*candidates=NULL,*boxes=NULL;HSTRING path=NULL,input_name=NULL,output_name=NULL,correlation=NULL;
 #define STEP(name,call) do{stage=L##name;hr=(call);if(FAILED(hr))goto cleanup;}while(0)
 if(FAILED(ro))goto cleanup;
 STEP("model_hash",verify_model(state.path,state.hash));
 STEP("model_factory",factory(L"Windows.AI.MachineLearning.LearningModel",L"{e3b977e8-6952-4e47-8ef4-1f7f07897c6d}",(void**)&mf));
 path=hs(state.path);STEP("model_load",mf->lpVtbl->LoadFromFilePath(mf,path,&model));
 STEP("device_factory",factory(L"Windows.AI.MachineLearning.LearningModelDevice",L"{9cffd74d-b1e5-4f20-80ad-0a56690db06b}",(void**)&df));
 STEP("device_create",df->lpVtbl->Create(df,(enum __x_ABI_CWindows_CAI_CMachineLearning_CLearningModelDeviceKind)state.device,&device));
 STEP("session_factory",factory(L"Windows.AI.MachineLearning.LearningModelSession",L"{0f6b881d-1c9b-47b6-bfe0-f1cf62a67579}",(void**)&sf));
 STEP("session_create",sf->lpVtbl->CreateFromModelOnDevice(sf,model,device,&session));
 STEP("binding_factory",factory(L"Windows.AI.MachineLearning.LearningModelBinding",L"{c95f7a7a-e788-475e-8917-23aa381faf0b}",(void**)&bf));
 STEP("binding_create",bf->lpVtbl->CreateFromSession(bf,session,&binding));
 STEP("tensor_factory",factory(L"Windows.AI.MachineLearning.TensorFloat",L"{24610bc1-5e44-5713-b281-8f4ad4d555e8}",(void**)&tf));
 tensor=HeapAlloc(GetProcessHeap(),0,3*YOLO_SIDE*YOLO_SIDE*sizeof(float));raw=HeapAlloc(GetProcessHeap(),0,YOLO_OUTPUTS*sizeof(float));candidates=HeapAlloc(GetProcessHeap(),0,YOLO_CANDIDATES*sizeof(YoloBox));boxes=HeapAlloc(GetProcessHeap(),0,YOLO_DETECTIONS*sizeof(YoloBox));
 if(!tensor||!raw||!candidates||!boxes){hr=E_OUTOFMEMORY;goto cleanup;}
 input_name=hs(L"images");output_name=hs(L"output0");correlation=hs(L"yolo-local-frame");
 AcquireSRWLockExclusive(&guard);state.loaded=TRUE;state.hr=S_OK;wcopy(state.phase,32,L"running");wcopy(state.stage,48,L"ready");ReleaseSRWLockExclusive(&guard);
 while(!InterlockedCompareExchange(&stop_requested,0,0)){
  DWORD waited=WaitForSingleObject(work_event,1000);if(InterlockedCompareExchange(&stop_requested,0,0))break;
  AcquireSRWLockShared(&guard);BOOL busy=state.busy,diagnostic=pending.diagnostic;int width=pending.width,height=pending.height;DOUBLE source_time=pending.time;ULONGLONG submitted=pending.submitted,last_activity=state.submitted;ReleaseSRWLockShared(&guard);
  if(waited!=WAIT_OBJECT_0){if(GetTickCount64()-last_activity>30000)break;continue;}if(!busy)continue;
  LARGE_INTEGER freq,start,finish;QueryPerformanceFrequency(&freq);QueryPerformanceCounter(&start);
  y_letterbox(pixels,width,height,tensor);QueryPerformanceCounter(&finish);double preprocessing=(double)(finish.QuadPart-start.QuadPart)*1000/freq.QuadPart;
  UINT64 signature=1469598103934665603ull;for(UINT32 i=0;i<(UINT32)(width*height*4);i+=97){signature^=pixels[i];signature*=1099511628211ull;}
  INT64 shape[4]={1,3,YOLO_SIDE,YOLO_SIDE};STEP("binding_clear",binding->lpVtbl->Clear(binding));RELEASE(input);
  STEP("tensor_create",tf->lpVtbl->CreateFromShapeArrayAndDataArray(tf,4,shape,3*YOLO_SIDE*YOLO_SIDE,tensor,&input));
  STEP("bind",binding->lpVtbl->Bind(binding,input_name,(IInspectable*)input));QueryPerformanceCounter(&start);
  STEP("evaluate",session->lpVtbl->Evaluate(session,binding,correlation,&result));QueryPerformanceCounter(&finish);double inference=(double)(finish.QuadPart-start.QuadPart)*1000/freq.QuadPart;
  boolean ok=FALSE;STEP("result_status",result->lpVtbl->get_Succeeded(result,&ok));if(!ok){INT32 error=0;result->lpVtbl->get_ErrorStatus(result,&error);hr=error<0?error:E_FAIL;stage=L"evaluate_status";goto cleanup;}
  STEP("result_outputs",result->lpVtbl->get_Outputs(result,&outputs));STEP("output_lookup",outputs->lpVtbl->Lookup(outputs,output_name,&value));STEP("output_tensor",value->lpVtbl->QueryInterface(value,&iid_tensor,(void**)&output));STEP("output_view",output->lpVtbl->GetAsVectorView(output,&values));
  UINT32 size=0,actual=0;STEP("output_count",values->lpVtbl->get_Size(values,&size));if(size!=YOLO_OUTPUTS){hr=E_UNEXPECTED;goto cleanup;}
  STEP("output_data",values->lpVtbl->GetMany(values,0,YOLO_OUTPUTS,raw,&actual));if(actual!=YOLO_OUTPUTS){hr=E_UNEXPECTED;goto cleanup;}
  int count=y_decode(raw,width,height,.4f,.45f,candidates,boxes);
  RELEASE(values);RELEASE(output);RELEASE(value);RELEASE(outputs);RELEASE(result);
  AcquireSRWLockExclusive(&guard);
  if(!InterlockedCompareExchange(&stop_requested,0,0)){state.frames++;if(diagnostic)state.asset_frames++;else state.camera_frames++;state.width=width;state.height=height;state.source_time=source_time;state.diagnostic=diagnostic;state.preprocess_ms=preprocessing;state.inference_ms=inference;state.finished=GetTickCount64();state.submitted=submitted;state.signature=signature;state.boxes_count=count;memcpy(state.boxes,boxes,count*sizeof(YoloBox));wcopy(state.stage,48,L"frame_complete");}
  state.busy=FALSE;ReleaseSRWLockExclusive(&guard);
 }
 cleanup:
 if(FAILED(hr))set_error(stage,hr);
 RELEASE(values);RELEASE(output);RELEASE(value);RELEASE(outputs);RELEASE(result);RELEASE(input);RELEASE(tf);close_object(binding);RELEASE(binding);RELEASE(bf);close_object(session);RELEASE(session);RELEASE(sf);RELEASE(device);RELEASE(df);close_object(model);RELEASE(model);RELEASE(mf);
 if(path)WindowsDeleteString(path);if(input_name)WindowsDeleteString(input_name);if(output_name)WindowsDeleteString(output_name);if(correlation)WindowsDeleteString(correlation);
 if(tensor)HeapFree(GetProcessHeap(),0,tensor);if(raw)HeapFree(GetProcessHeap(),0,raw);if(candidates)HeapFree(GetProcessHeap(),0,candidates);if(boxes)HeapFree(GetProcessHeap(),0,boxes);
 AcquireSRWLockExclusive(&guard);if(pixels){HeapFree(GetProcessHeap(),0,pixels);pixels=NULL;pixel_capacity=0;}state.loaded=FALSE;state.busy=FALSE;if(SUCCEEDED(hr)){wcopy(state.phase,32,L"stopped");wcopy(state.stage,48,L"resources_released");}ReleaseSRWLockExclusive(&guard);
 InterlockedExchange(&active,0);if(SUCCEEDED(ro))RoUninitialize();return 0;
}
typedef struct{char*data;UINT32 count,capacity;} Json;
static void js(Json*j,const char*s){while(*s&&j->count+1<j->capacity)j->data[j->count++]=*s++;j->data[j->count]=0;}
static void ju(Json*j,UINT64 n){char b[32];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i){char c[2]={b[--i],0};js(j,c);}}
static void jn(Json*j,double n){if(n<0){js(j,"-");n=-n;}UINT64 v=(UINT64)(n*1000+.5);ju(j,v/1000);js(j,".");char b[4]={(char)('0'+v/100%10),(char)('0'+v/10%10),(char)('0'+v%10),0};js(j,b);}
static void jq(Json*j,const WCHAR*w){char*text=HeapAlloc(GetProcessHeap(),0,8192);js(j,"\"");if(text){int n=WideCharToMultiByte(CP_UTF8,0,w,-1,text,8192,NULL,NULL);for(int i=0;i<n-1;i++){char c=text[i];if(c=='"'||c=='\\')js(j,"\\");if((BYTE)c<32){js(j," ");continue;}char b[2]={c,0};js(j,b);}HeapFree(GetProcessHeap(),0,text);}js(j,"\"");}
static HRESULT STDMETHODCALLTYPE d_qi(Detector*self,REFIID id,void**out){if(!out)return E_POINTER;*out=NULL;if(same(id,&iid_unknown)||same(id,&iid_inspectable)||same(id,&iid_agile)||same(id,&iid_detector)){*out=self;InterlockedIncrement(&object_refs);return S_OK;}return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE d_add(Detector*self){(void)self;return (ULONG)InterlockedIncrement(&object_refs);}
static ULONG STDMETHODCALLTYPE d_release(Detector*self){(void)self;return (ULONG)InterlockedDecrement(&object_refs);}
static HRESULT STDMETHODCALLTYPE d_ids(Detector*self,ULONG*n,IID**ids){(void)self;if(!n||!ids)return E_POINTER;*ids=CoTaskMemAlloc(sizeof(IID));if(!*ids)return E_OUTOFMEMORY;**ids=iid_detector;*n=1;return S_OK;}
static HRESULT STDMETHODCALLTYPE d_name(Detector*self,HSTRING*out){(void)self;return WindowsCreateString(L"Rice.HoloLens.Yolo.Detector",wlen(L"Rice.HoloLens.Yolo.Detector"),out);}
static HRESULT STDMETHODCALLTYPE d_trust(Detector*self,TrustLevel*out){(void)self;if(!out)return E_POINTER;*out=BaseTrust;return S_OK;}
static HRESULT STDMETHODCALLTYPE d_start(Detector*self,HSTRING path,HSTRING expected,UINT32 device){
 (void)self;const WCHAR*p=WindowsGetStringRawBuffer(path,NULL),*hash=WindowsGetStringRawBuffer(expected,NULL);
 if(wlen(p)<3||wlen(p)>1000||wlen(hash)!=64||(device!=1&&device!=3))return E_INVALIDARG;
 AcquireSRWLockExclusive(&guard);
 if(InterlockedCompareExchange(&active,0,0)){ReleaseSRWLockExclusive(&guard);return HRESULT_FROM_WIN32(ERROR_BUSY);}
 if(worker_thread){CloseHandle(worker_thread);worker_thread=NULL;}if(work_event){CloseHandle(work_event);work_event=NULL;}
 memset(&state,0,sizeof(state));memset(&pending,0,sizeof(pending));last_camera_time=-1;wcopy(state.path,1024,p);wcopy(state.hash,65,hash);wcopy(state.phase,32,L"loading");wcopy(state.stage,48,L"model_initializing");state.device=device;state.started=state.submitted=GetTickCount64();
 work_event=CreateEventW(NULL,FALSE,FALSE,NULL);if(!work_event){ReleaseSRWLockExclusive(&guard);return HRESULT_FROM_WIN32(GetLastError());}
 InterlockedExchange(&stop_requested,0);InterlockedExchange(&active,1);worker_thread=CreateThread(NULL,0,run_worker,NULL,0,NULL);
 if(!worker_thread){InterlockedExchange(&active,0);CloseHandle(work_event);work_event=NULL;ReleaseSRWLockExclusive(&guard);return HRESULT_FROM_WIN32(GetLastError());}
 ReleaseSRWLockExclusive(&guard);return S_OK;
}
static HRESULT STDMETHODCALLTYPE d_submit(Detector*self,__x_ABI_CWindows_CStorage_CStreams_CIBuffer*buffer,INT32 width,INT32 height,DOUBLE frame_time,boolean diagnostic,boolean*accepted){
 (void)self;if(!accepted||!buffer)return E_POINTER;*accepted=FALSE;
 if(width<16||height<16||width>1920||height>1080||frame_time!=frame_time||frame_time<0||frame_time>1e15)return E_INVALIDARG;
 UINT32 length=0;HRESULT hr=buffer->lpVtbl->get_Length(buffer,&length);UINT32 needed=(UINT32)(width*height*4);if(FAILED(hr)||length!=needed)return E_INVALIDARG;
 BufferAccess*access=NULL;BYTE*source=NULL;hr=buffer->lpVtbl->QueryInterface(buffer,&iid_buffer_access,(void**)&access);if(SUCCEEDED(hr))hr=access->lpVtbl->Buffer(access,&source);if(FAILED(hr)){RELEASE(access);return hr;}
 AcquireSRWLockExclusive(&guard);
 if(!state.loaded||state.busy||InterlockedCompareExchange(&stop_requested,0,0)||(!diagnostic&&frame_time<=last_camera_time)){state.rejected++;ReleaseSRWLockExclusive(&guard);RELEASE(access);return S_OK;}
 if(pixel_capacity<needed){BYTE*new_pixels=HeapAlloc(GetProcessHeap(),0,needed);if(!new_pixels){ReleaseSRWLockExclusive(&guard);RELEASE(access);return E_OUTOFMEMORY;}if(pixels)HeapFree(GetProcessHeap(),0,pixels);pixels=new_pixels;pixel_capacity=needed;}
 memcpy(pixels,source,needed);pending.width=width;pending.height=height;pending.time=frame_time;pending.diagnostic=diagnostic;pending.submitted=GetTickCount64();if(!diagnostic)last_camera_time=frame_time;state.busy=TRUE;*accepted=TRUE;SetEvent(work_event);ReleaseSRWLockExclusive(&guard);RELEASE(access);return S_OK;
}
static HRESULT STDMETHODCALLTYPE d_state(Detector*self,HSTRING*out){
 (void)self;if(!out)return E_POINTER;State*copy=HeapAlloc(GetProcessHeap(),0,sizeof(State));char*buffer=HeapAlloc(GetProcessHeap(),0,32768);if(!copy||!buffer){if(copy)HeapFree(GetProcessHeap(),0,copy);if(buffer)HeapFree(GetProcessHeap(),0,buffer);return E_OUTOFMEMORY;}
 AcquireSRWLockShared(&guard);memcpy(copy,&state,sizeof(State));ReleaseSRWLockShared(&guard);Json j={buffer,0,32768};
 js(&j,"{\"protocol\":1,\"onDevice\":true,\"networkRequests\":0,\"runtime\":\"Windows.AI.MachineLearning\",\"phase\":");jq(&j,copy->phase);js(&j,",\"stage\":");jq(&j,copy->stage);js(&j,",\"error\":");jq(&j,copy->error);js(&j,",\"hr\":");ju(&j,(UINT32)copy->hr);js(&j,",\"modelLoaded\":");js(&j,copy->loaded?"true":"false");js(&j,",\"workerActive\":");js(&j,InterlockedCompareExchange(&active,0,0)?"true":"false");js(&j,",\"busy\":");js(&j,copy->busy?"true":"false");js(&j,",\"modelSha256\":");jq(&j,copy->hash);js(&j,",\"model\":\"YOLOv8n-6\",\"inputSize\":");ju(&j,YOLO_SIDE);js(&j,",\"deviceKind\":");ju(&j,copy->device);js(&j,",\"processId\":");ju(&j,GetCurrentProcessId());js(&j,",\"frames\":");ju(&j,copy->frames);js(&j,",\"cameraFrames\":");ju(&j,copy->camera_frames);js(&j,",\"assetFrames\":");ju(&j,copy->asset_frames);js(&j,",\"rejected\":");ju(&j,copy->rejected);js(&j,",\"frameTime\":");jn(&j,copy->source_time);js(&j,",\"source\":");js(&j,copy->diagnostic?"\"diagnostic_asset\"":"\"camera\"");js(&j,",\"sourceWidth\":");ju(&j,copy->width);js(&j,",\"sourceHeight\":");ju(&j,copy->height);js(&j,",\"preprocessMs\":");jn(&j,copy->preprocess_ms);js(&j,",\"inferenceMs\":");jn(&j,copy->inference_ms);js(&j,",\"resultAgeMs\":");ju(&j,copy->finished?GetTickCount64()-copy->finished:0);js(&j,",\"captureToResultMs\":");ju(&j,copy->finished>=copy->submitted?copy->finished-copy->submitted:0);js(&j,",\"inputSignature\":\"");ju(&j,copy->signature);js(&j,"\",\"detections\":[");
 for(UINT32 i=0;i<copy->boxes_count;i++){YoloBox*b=&copy->boxes[i];if(i)js(&j,",");js(&j,"{\"classId\":");ju(&j,b->class_id);js(&j,",\"label\":");jq(&j,labels[b->class_id]);js(&j,",\"confidence\":");jn(&j,b->score);js(&j,",\"box\":[");jn(&j,b->x1);js(&j,",");jn(&j,b->y1);js(&j,",");jn(&j,b->x2);js(&j,",");jn(&j,b->y2);js(&j,"]}");}js(&j,"]}");
 int chars=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,buffer,j.count,NULL,0);WCHAR*wide=HeapAlloc(GetProcessHeap(),0,(chars+1)*sizeof(WCHAR));HRESULT hr=E_OUTOFMEMORY;if(wide){MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,buffer,j.count,wide,chars);hr=WindowsCreateString(wide,chars,out);HeapFree(GetProcessHeap(),0,wide);}HeapFree(GetProcessHeap(),0,copy);HeapFree(GetProcessHeap(),0,buffer);return hr;
}
static HRESULT STDMETHODCALLTYPE d_stop(Detector*self){(void)self;InterlockedExchange(&stop_requested,1);AcquireSRWLockExclusive(&guard);if(InterlockedCompareExchange(&active,0,0))wcopy(state.phase,32,L"stopping");if(work_event)SetEvent(work_event);ReleaseSRWLockExclusive(&guard);return S_OK;}
static const __x_Rice_CHoloLens_CYolo_CIDetectorVtbl detector_vtable={d_qi,d_add,d_release,d_ids,d_name,d_trust,d_start,d_submit,d_state,d_stop};
static Detector detector={&detector_vtable};
static HRESULT STDMETHODCALLTYPE f_qi(IActivationFactory*self,REFIID id,void**out){if(!out)return E_POINTER;*out=NULL;if(same(id,&iid_unknown)||same(id,&iid_inspectable)||same(id,&iid_factory)||same(id,&iid_agile)){*out=self;InterlockedIncrement(&object_refs);return S_OK;}return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE f_add(IActivationFactory*self){(void)self;return (ULONG)InterlockedIncrement(&object_refs);}
static ULONG STDMETHODCALLTYPE f_release(IActivationFactory*self){(void)self;return (ULONG)InterlockedDecrement(&object_refs);}
static HRESULT STDMETHODCALLTYPE f_ids(IActivationFactory*self,ULONG*n,IID**ids){(void)self;if(!n||!ids)return E_POINTER;*n=0;*ids=NULL;return S_OK;}
static HRESULT STDMETHODCALLTYPE f_name(IActivationFactory*self,HSTRING*out){(void)self;return d_name(&detector,out);}
static HRESULT STDMETHODCALLTYPE f_trust(IActivationFactory*self,TrustLevel*out){(void)self;return d_trust(&detector,out);}
static HRESULT STDMETHODCALLTYPE f_activate(IActivationFactory*self,IInspectable**out){(void)self;if(!out)return E_POINTER;*out=(IInspectable*)&detector;d_add(&detector);return S_OK;}
static const IActivationFactoryVtbl factory_vtable={f_qi,f_add,f_release,f_ids,f_name,f_trust,f_activate};
static IActivationFactory activation_factory={&factory_vtable};
HRESULT WINAPI DllGetActivationFactory(HSTRING name,IActivationFactory**out){const WCHAR*w=WindowsGetStringRawBuffer(name,NULL),*wanted=L"Rice.HoloLens.Yolo.Detector";UINT32 i=0;while(w[i]&&wanted[i]&&w[i]==wanted[i])i++;if(w[i]||wanted[i])return CLASS_E_CLASSNOTAVAILABLE;if(!out)return E_POINTER;*out=&activation_factory;f_add(&activation_factory);return S_OK;}
HRESULT WINAPI DllCanUnloadNow(void){return !InterlockedCompareExchange(&active,0,0)&&!InterlockedCompareExchange(&object_refs,0,0)?S_OK:S_FALSE;}
