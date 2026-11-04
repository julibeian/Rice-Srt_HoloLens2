#define CINTERFACE
#define COBJMACROS
#define CONST_VTABLE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <roapi.h>
#include <windows.ai.machinelearning.h>
#include <restrictederrorinfo.h>
#include <roerrorapi.h>

void *memcpy(void*d,const void*s,size_t n){unsigned char*a=d;const unsigned char*b=s;while(n--)*a++=*b++;return d;}
void *memset(void*d,int x,size_t n){unsigned char*a=d;while(n--)*a++=(unsigned char)x;return d;}
static UINT32 len(const WCHAR*s){UINT32 n=0;while(s[n])n++;return n;}
static HSTRING hs(const WCHAR*s){HSTRING h=NULL;WindowsCreateString(s,len(s),&h);return h;}
static HRESULT fac(const WCHAR*name,const WCHAR*iid,void**out){GUID id;HRESULT hr=IIDFromString(iid,&id);HSTRING h=hs(name);if(SUCCEEDED(hr))hr=RoGetActivationFactory(h,&id,out);WindowsDeleteString(h);return hr;}
#define RELEASE(p) do{if(p){(p)->lpVtbl->Release(p);p=NULL;}}while(0)
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
#ifndef YOLO_PROBE_SIDE
#define YOLO_PROBE_SIDE 640
#endif
#define YOLO_PROBE_OUTPUTS (10*((YOLO_PROBE_SIDE/8)*(YOLO_PROBE_SIDE/8)+(YOLO_PROBE_SIDE/16)*(YOLO_PROBE_SIDE/16)+(YOLO_PROBE_SIDE/32)*(YOLO_PROBE_SIDE/32)))
#ifndef YOLO_DEVICE_KIND
#define YOLO_DEVICE_KIND 1
#endif
static char json[8192];static UINT32 jp=0;
static void s(const char*t){while(*t&&jp+1<sizeof(json))json[jp++]=*t++;json[jp]=0;}
static void u(UINT64 x){char v[32];int n=0;do{v[n++]=(char)('0'+x%10);x/=10;}while(x);while(n){char c[2]={v[--n],0};s(c);}}
static void hex(HRESULT h){const char*d="0123456789ABCDEF";s("\"0x");for(int i=7;i>=0;i--){char b[2]={d[((UINT32)h>>(i*4))&15],0};s(b);}s("\"");}
static void quoted(const WCHAR*w){static char b[4096];int n=WideCharToMultiByte(CP_UTF8,0,w,-1,b,sizeof(b),NULL,NULL);s("\"");for(int i=0;i<n-1;i++){unsigned char c=b[i];if(c=='"'||c=='\\')s("\\");if(c<32){s(" ");continue;}char a[2]={(char)c,0};s(a);}s("\"");}
static WCHAR*arg(WCHAR**p,WCHAR*out){WCHAR*s0=*p;while(*s0==L' ')s0++;BOOL q=*s0==L'"';if(q)s0++;UINT32 i=0;while(*s0&&(q?*s0!=L'"':*s0!=L' ')){if(i<1023)out[i++]=*s0;s0++;}out[i]=0;if(q&&*s0)s0++;*p=s0;return out;}
void __stdcall yolo_probe_entry(void){
 static WCHAR exe[1024],path[1024],out[1024];WCHAR*p=GetCommandLineW();arg(&p,exe);arg(&p,path);arg(&p,out);
 if(!*path||!*out)ExitProcess(64);
 HRESULT hr=RoInitialize(RO_INIT_MULTITHREADED);const char*stage="ro_initialize";ModelFactory*mf=NULL;Model*m=NULL;SessionFactory*sf=NULL;Session*session=NULL;BindingFactory*bf=NULL;Binding*b=NULL;TensorFactory*tf=NULL;Tensor*t=NULL;Result*r=NULL;
 __FIMapView_2_HSTRING_IInspectable*outputs=NULL;IInspectable*output=NULL;Tensor*ot=NULL;__FIVectorView_1_float*view=NULL;DeviceFactory*df=NULL;Device*device=NULL;ULONGLONG runs[4]={0};
 FLOAT*data=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,3*YOLO_PROBE_SIDE*YOLO_PROBE_SIDE*sizeof(FLOAT));INT64 shape[4]={1,3,YOLO_PROBE_SIDE,YOLO_PROBE_SIDE};UINT32 count=0;ULONGLONG start=GetTickCount64(),load=0,infer=0;
 #define STEP(label,call) do{stage=label;hr=(call);if(FAILED(hr))goto done;}while(0)
 STEP("model_factory",fac(L"Windows.AI.MachineLearning.LearningModel",L"{e3b977e8-6952-4e47-8ef4-1f7f07897c6d}",(void**)&mf));
 HSTRING file=hs(path);hr=mf->lpVtbl->LoadFromFilePath(mf,file,&m);WindowsDeleteString(file);stage="model_load";if(FAILED(hr))goto done;load=GetTickCount64()-start;
 STEP("session_factory",fac(L"Windows.AI.MachineLearning.LearningModelSession",L"{0f6b881d-1c9b-47b6-bfe0-f1cf62a67579}",(void**)&sf));
 STEP("device_factory",fac(L"Windows.AI.MachineLearning.LearningModelDevice",L"{9cffd74d-b1e5-4f20-80ad-0a56690db06b}",(void**)&df));
 STEP("device_create",df->lpVtbl->Create(df,YOLO_DEVICE_KIND,&device));
 STEP("session_create",sf->lpVtbl->CreateFromModelOnDevice(sf,m,device,&session));
 STEP("binding_factory",fac(L"Windows.AI.MachineLearning.LearningModelBinding",L"{c95f7a7a-e788-475e-8917-23aa381faf0b}",(void**)&bf));
 STEP("binding_create",bf->lpVtbl->CreateFromSession(bf,session,&b));
 STEP("tensor_factory",fac(L"Windows.AI.MachineLearning.TensorFloat",L"{24610bc1-5e44-5713-b281-8f4ad4d555e8}",(void**)&tf));
 if(!data){hr=E_OUTOFMEMORY;goto done;}
 STEP("tensor_create",tf->lpVtbl->CreateFromShapeArrayAndDataArray(tf,4,shape,3*YOLO_PROBE_SIDE*YOLO_PROBE_SIDE,data,&t));
 HSTRING input=hs(L"images");hr=b->lpVtbl->Bind(b,input,(IInspectable*)t);WindowsDeleteString(input);stage="bind";if(FAILED(hr))goto done;
 HSTRING cid=hs(L"native-yolo-probe");for(int run=0;run<4;run++){RELEASE(r);start=GetTickCount64();hr=session->lpVtbl->Evaluate(session,b,cid,&r);runs[run]=GetTickCount64()-start;if(FAILED(hr))break;}WindowsDeleteString(cid);infer=runs[0];stage="evaluate";if(FAILED(hr))goto done;
 STEP("outputs",r->lpVtbl->get_Outputs(r,&outputs));HSTRING name=hs(L"output0");hr=outputs->lpVtbl->Lookup(outputs,name,&output);WindowsDeleteString(name);stage="output_lookup";if(FAILED(hr))goto done;
 GUID tid;IIDFromString(L"{f2282d82-aa02-42c8-a0c8-df1efc9676e1}",&tid);STEP("output_tensor",output->lpVtbl->QueryInterface(output,&tid,(void**)&ot));
 STEP("output_values",ot->lpVtbl->GetAsVectorView(ot,&view));STEP("output_count",view->lpVtbl->get_Size(view,&count));if(count!=YOLO_PROBE_OUTPUTS){hr=E_UNEXPECTED;goto done;}stage="complete";
 done:;
 IRestrictedErrorInfo*err=NULL;BSTR description=NULL,restricted=NULL,cap=NULL;HRESULT error_hr=0;if(FAILED(hr)&&SUCCEEDED(GetRestrictedErrorInfo(&err))&&err)err->lpVtbl->GetErrorDetails(err,&description,&error_hr,&restricted,&cap);
 s("{\"stage\":\"");s(stage);s("\",\"hr\":");hex(hr);s(",\"loadMs\":");u(load);s(",\"inferenceMs\":");u(infer);s(",\"deviceKind\":");u(YOLO_DEVICE_KIND);s(",\"runsMs\":[");for(int run=0;run<4;run++){if(run)s(",");u(runs[run]);}s("],\"outputElements\":");u(count);s(",\"processId\":");u(GetCurrentProcessId());s(",\"error\":");quoted(restricted?restricted:description?description:L"");s("}");
 HANDLE f=CreateFileW(out,GENERIC_WRITE,FILE_SHARE_READ,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);if(f!=INVALID_HANDLE_VALUE){DWORD wrote;WriteFile(f,json,jp,&wrote,NULL);CloseHandle(f);}DWORD wrote;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),json,jp,&wrote,NULL);
 if(description)SysFreeString(description);if(restricted)SysFreeString(restricted);if(cap)SysFreeString(cap);RELEASE(err);RELEASE(view);RELEASE(ot);RELEASE(output);RELEASE(outputs);RELEASE(r);RELEASE(t);RELEASE(tf);RELEASE(b);RELEASE(bf);RELEASE(session);RELEASE(sf);RELEASE(device);RELEASE(df);RELEASE(m);RELEASE(mf);if(data)HeapFree(GetProcessHeap(),0,data);RoUninitialize();ExitProcess(FAILED(hr)?1:0);
}
