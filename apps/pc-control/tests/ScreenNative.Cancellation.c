/* Runs the actual native worker with a fake picker operation, never a UI. */
#include "ScreenNative.c"
static LONG scenario,get_results_calls,status_calls,cancel_calls,close_calls,item_size_calls;
static AsyncStatus async_status;
static IAsyncInfo fake_info;
static PickOperation fake_operation;
static Item fake_item;
static HRESULT STDMETHODCALLTYPE op_query(PickOperation*self,REFIID iid,void**out){(void)self;if(equal(iid,&iid_async_info)){*out=&fake_info;return S_OK;}*out=NULL;return E_NOINTERFACE;}
static ULONG STDMETHODCALLTYPE op_ref(PickOperation*self){(void)self;return 2;}
static HRESULT STDMETHODCALLTYPE op_results(PickOperation*self,Item**out){(void)self;get_results_calls++;*out=NULL;if(scenario==7){InterlockedExchange(&stop_requested,1);*out=&fake_item;return S_OK;}return scenario==5||scenario==8?S_OK:E_UNEXPECTED;}
static const __FIAsyncOperation_1_Windows__CGraphics__CCapture__CGraphicsCaptureItemVtbl operation_vtable={.QueryInterface=op_query,.AddRef=op_ref,.Release=op_ref,.GetResults=op_results};
static PickOperation fake_operation={&operation_vtable};
static ULONG STDMETHODCALLTYPE info_ref(IAsyncInfo*self){(void)self;return 2;}
static HRESULT STDMETHODCALLTYPE info_status(IAsyncInfo*self,AsyncStatus*out){(void)self;status_calls++;*out=async_status;return S_OK;}
static HRESULT STDMETHODCALLTYPE info_error(IAsyncInfo*self,HRESULT*out){(void)self;*out=E_ACCESSDENIED;return S_OK;}
static HRESULT STDMETHODCALLTYPE info_cancel(IAsyncInfo*self){(void)self;cancel_calls++;if(scenario==3)return E_FAIL;if(scenario==9)async_status=Completed;else if(scenario!=4)async_status=Canceled;return S_OK;}
static HRESULT STDMETHODCALLTYPE info_close(IAsyncInfo*self){(void)self;close_calls++;if(scenario==8)return E_FAIL;return async_status==Started?E_ILLEGAL_METHOD_CALL:S_OK;}
static const IAsyncInfoVtbl info_vtable={.AddRef=info_ref,.Release=info_ref,.get_Status=info_status,.get_ErrorCode=info_error,.Cancel=info_cancel,.Close=info_close};
static IAsyncInfo fake_info={&info_vtable};
static ULONG STDMETHODCALLTYPE agile_ref(IAgileReference*self){(void)self;return 2;}
static HRESULT STDMETHODCALLTYPE agile_resolve(IAgileReference*self,REFIID iid,void**out){(void)self;if(!equal(iid,&iid_pick_operation))return E_NOINTERFACE;*out=&fake_operation;return S_OK;}
static const IAgileReferenceVtbl agile_vtable={.AddRef=agile_ref,.Release=agile_ref,.Resolve=agile_resolve};
static IAgileReference fake_agile={&agile_vtable};
static ULONG STDMETHODCALLTYPE item_ref(Item*self){(void)self;return 2;}
static HRESULT STDMETHODCALLTYPE item_size(Item*self,Size*out){(void)self;item_size_calls++;*out=(Size){640,480};return E_ABORT;}
static HRESULT STDMETHODCALLTYPE item_name(Item*self,HSTRING*out){(void)self;*out=NULL;return S_OK;}
static const __x_ABI_CWindows_CGraphics_CCapture_CIGraphicsCaptureItemVtbl item_vtable={.AddRef=item_ref,.Release=item_ref,.get_Size=item_size,.get_DisplayName=item_name};
static Item fake_item={&item_vtable};
static void output(const WCHAR*text_value){DWORD bytes=WideCharToMultiByte(CP_UTF8,0,text_value,-1,NULL,0,NULL,NULL);char*buffer=HeapAlloc(GetProcessHeap(),0,bytes);if(!buffer)ExitProcess(91);WideCharToMultiByte(CP_UTF8,0,text_value,-1,buffer,bytes,NULL,NULL);DWORD written=0;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),buffer,bytes-1,&written,NULL);HeapFree(GetProcessHeap(),0,buffer);}
void screen_native_cancellation_entry(void){
 const WCHAR*names[]={L"stop_before_completed_picker",L"cancel_acknowledged",L"cancel_rejected",L"cancel_not_acknowledged",L"selection_cancelled",L"picker_error",L"stop_during_get_results",L"picker_close_failure",L"completed_after_cancel"};
 BOOL all_pass=TRUE;output(L"{\"cases\":[");
 for(scenario=1;scenario<=9;scenario++){
  memset(&state,0,sizeof(state));state.picker_requested=TRUE;state.snapshot_hr=E_PENDING;get_results_calls=status_calls=cancel_calls=close_calls=item_size_calls=0;
  async_status=((scenario>=2&&scenario<=4)||scenario==9)?Started:scenario==6?Error:Completed;
  operation_ref=&fake_agile;InterlockedExchange(&active,1);InterlockedExchange(&stop_requested,scenario<=4||scenario==9);
  ULONGLONG start=GetTickCount64();capture_worker(NULL);ULONGLONG elapsed=GetTickCount64()-start;
  BOOL expected_known=scenario!=3&&scenario!=4,expected_cleanup=expected_known&&scenario!=8;
  int expected_results=scenario==5||scenario==7||scenario==8?1:0;
  BOOL pass=!state.started&&active==0&&get_results_calls==expected_results&&item_size_calls==0&&cancel_calls<=1&&close_calls==(expected_known?1:0)&&state.picker_outcome_known==expected_known&&state.picker_cleanup_verified==expected_cleanup;
  if(scenario==3)pass=pass&&state.picker_cancel_hr==E_FAIL&&state.hr==E_FAIL;
  if(scenario==4)pass=pass&&elapsed>=1900&&elapsed<4000&&state.hr==HRESULT_FROM_WIN32(ERROR_TIMEOUT);
  if(scenario==3||scenario==4)pass=pass&&state.picker_close_hr==E_PENDING;
  if(scenario==6)pass=pass&&state.hr==E_ACCESSDENIED;
  if(scenario==8)pass=pass&&state.picker_close_hr==E_FAIL&&state.hr==E_FAIL;
  if(scenario==1||scenario==2||scenario==5||scenario==7||scenario==9)pass=pass&&SUCCEEDED(state.hr)&&state.phase[0]==L's';
  if(!expected_cleanup){HRESULT failure=state.hr;HSTRING inspected=NULL;pass=pass&&inspect(&probe,&inspected)==S_OK&&state.hr==failure&&state.phase[0]==L'f'&&!state.picker_cleanup_verified;WindowsDeleteString(inspected);}
  all_pass=all_pass&&pass;HSTRING value=NULL;if(FAILED(get_state(&probe,&value)))ExitProcess(92);
  WCHAR prefix[320]={0};Json j={prefix,0,320,FALSE};if(scenario>1)text(&j,L",");text(&j,L"{\"name\":");quoted(&j,names[scenario-1]);text(&j,L",\"elapsed_ms\":");number(&j,(LONGLONG)elapsed);text(&j,L",\"get_results_calls\":");number(&j,get_results_calls);text(&j,L",\"cancel_calls\":");number(&j,cancel_calls);text(&j,L",\"status_calls\":");number(&j,status_calls);text(&j,L",\"close_calls\":");number(&j,close_calls);text(&j,L",\"pass\":");boolean_json(&j,pass);text(&j,L",\"state\":");output(prefix);output(WindowsGetStringRawBuffer(value,NULL));WindowsDeleteString(value);output(L"}");
 }
 output(all_pass?L"],\"pass\":true,\"picker_ui_created\":false,\"real_capture_sessions\":0}\n":L"],\"pass\":false,\"picker_ui_created\":false,\"real_capture_sessions\":0}\n");ExitProcess(all_pass?0:1);
}
