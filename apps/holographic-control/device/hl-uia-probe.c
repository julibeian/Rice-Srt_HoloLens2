/* Read-only UI Automation tree probe on the HoloLens, using public SDK COM APIs.
 * No input or Invoke calls. Text/edit contents and digit-bearing names omitted.
 */
#define CINTERFACE
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <uiautomationclient.h>
static char output[65536],utf8[2048];static DWORD used,count;
static IUIAutomationTreeWalker *walker;
static DWORD WINAPI watchdog(void *unused){(void)unused;Sleep(20000);ExitProcess(124);return 0;}
static void text(const char*s){while(*s&&used<sizeof(output)-1)output[used++]=*s++;}
static void number(DWORD n){char b[12];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i&&used<sizeof(output)-1)output[used++]=b[--i];}
static void hexhr(HRESULT hr){const char*h="0123456789ABCDEF";text("\"0x");for(int i=7;i>=0;i--){char b[2]={h[((DWORD)hr>>(i*4))&15],0};text(b);}text("\"");}
static void string(BSTR s,BOOL hideDigits){
    if(!s){text("null");return;}
    int n=0;for(;s[n]&&n<128;n++){if(hideDigits&&s[n]>=L'0'&&s[n]<=L'9'){text("\"[numeric name omitted]\"");return;}}
    int bytes=WideCharToMultiByte(CP_UTF8,0,s,n,utf8,sizeof(utf8)-1,0,0);
    text("\"");for(int i=0;i<bytes;i++){unsigned char c=utf8[i];if(c=='"'||c=='\\')text("\\");if(c>=32){char b[2]={(char)c,0};text(b);}}text("\"");
}
static void walk(IUIAutomationElement *element,DWORD parent,DWORD depth){
    if(!element||count>=60||depth>5)return;
    DWORD id=count++;CONTROLTYPEID type=0;BOOL offscreen=1,password=1;BSTR name=0,automationId=0,className=0;
    IUIAutomationElement_get_CurrentControlType(element,&type);
    IUIAutomationElement_get_CurrentIsOffscreen(element,&offscreen);
    IUIAutomationElement_get_CurrentIsPassword(element,&password);
    IUIAutomationElement_get_CurrentAutomationId(element,&automationId);
    IUIAutomationElement_get_CurrentClassName(element,&className);
    if(!password&&type!=50004&&type!=50020)IUIAutomationElement_get_CurrentName(element,&name);
    if(id)text(",");text("{\"id\":");number(id);text(",\"parent\":");if(id)number(parent);else text("null");
    text(",\"depth\":");number(depth);text(",\"controlType\":");number((DWORD)type);
    text(",\"offscreen\":");text(offscreen?"true":"false");text(",\"class\":");string(className,FALSE);
    text(",\"automationId\":");string(automationId,TRUE);text(",\"name\":");string(name,TRUE);text("}");
    SysFreeString(name);SysFreeString(automationId);SysFreeString(className);
    if(walker&&depth<5){
        IUIAutomationElement *child=0;
        if(SUCCEEDED(IUIAutomationTreeWalker_GetFirstChildElement(walker,element,&child))){
            while(child&&count<60){IUIAutomationElement *next=0;walk(child,id,depth+1);IUIAutomationTreeWalker_GetNextSiblingElement(walker,child,&next);IUIAutomationElement_Release(child);child=next;}
            if(child)IUIAutomationElement_Release(child);
        }
    }
}
void WINAPI uia_probe_entry(void){
    HANDLE guard=CreateThread(0,0,watchdog,0,0,0);if(guard)CloseHandle(guard);
    HRESULT init=CoInitializeEx(0,COINIT_MULTITHREADED),create=(HRESULT)0x80004005,rootResult=create,walkerResult=create;
    IUIAutomation *automation=0;IUIAutomationElement *root=0;
    create=CoCreateInstance(&CLSID_CUIAutomation,0,CLSCTX_INPROC_SERVER,&IID_IUIAutomation,(void**)&automation);
    WCHAR user[256];DWORD n=256,written=0;
    text("{\"probeVersion\":1,\"inputSent\":false,\"user\":");if(GetUserNameW(user,&n))string(user,FALSE);else text("null");
    text(",\"initialize\":");hexhr(init);text(",\"createAutomation\":");hexhr(create);
    if(automation){rootResult=IUIAutomation_GetRootElement(automation,&root);walkerResult=IUIAutomation_get_RawViewWalker(automation,&walker);}
    text(",\"getRoot\":");hexhr(rootResult);text(",\"getWalker\":");hexhr(walkerResult);text(",\"elements\":[");
    if(root)walk(root,0,0);text("],\"count\":");number(count);text("}\n");
    if(root)IUIAutomationElement_Release(root);if(walker)IUIAutomationTreeWalker_Release(walker);if(automation)IUIAutomation_Release(automation);if(SUCCEEDED(init))CoUninitialize();
    HANDLE report=CreateFileW(L"U:\\Users\\DefaultAccount\\AppData\\Local\\DevelopmentFiles\\RiceHoloLensFieldV1\\uia-probe-result.json",GENERIC_WRITE,FILE_SHARE_READ,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(report!=INVALID_HANDLE_VALUE){WriteFile(report,output,used,&written,0);CloseHandle(report);}
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),output,used,&written,0);ExitProcess(SUCCEEDED(create)&&root?0:2);
}
