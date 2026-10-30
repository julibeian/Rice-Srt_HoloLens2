/* Read-only public certificate verification through authenticated SDK SSH.
 * Only reports a certificate matching the requested SHA256; never opens keys.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
static char output[4096],utf8[2048];static DWORD used;
static WCHAR requested[65],subject[512],user[256];
static void text(const char*s){while(*s&&used<sizeof(output))output[used++]=*s++;}
static void number(DWORD n){char b[12];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i)output[used++]=b[--i];}
static void wide(const WCHAR*s){text("\"");int n=WideCharToMultiByte(65001,0,s,-1,utf8,sizeof(utf8),0,0);if(n>0)for(int i=0;i<n-1;i++){char c=utf8[i];if(c=='\\'||c=='"')text("\\");if((BYTE)c>=32)output[used++]=c;}text("\"");}
static int arguments(void){const WCHAR*p=GetCommandLineW();if(*p=='"'){p++;while(*p&&*p!='"')p++;if(*p)p++;}else while(*p&&*p!=' ')p++;while(*p==' ')p++;for(int i=0;i<64;i++){WCHAR c=*p++;if(!((c>='0'&&c<='9')||(c>='A'&&c<='F')))return 0;requested[i]=c;}return *p==0;}
void WINAPI certificate_probe_entry(void){
 DWORD sent=0,user_length=256,matches=0;int valid=arguments();text("{\"version\":1,\"readOnly\":true,\"privateKeysAccessed\":false,\"user\":");if(GetUserNameW(user,&user_length))wide(user);else text("null");text(",\"argumentValid\":");text(valid?"true":"false");text(",\"stores\":[");
 if(valid){const WCHAR*names[]={L"MY",L"WebHosting"};for(int k=0;k<2;k++){
  if(k)text(",");HCERTSTORE store=CertOpenStore(CERT_STORE_PROV_SYSTEM_W,0,0,CERT_SYSTEM_STORE_LOCAL_MACHINE|CERT_STORE_OPEN_EXISTING_FLAG|CERT_STORE_READONLY_FLAG,names[k]);DWORD error=store?0:GetLastError(),scanned=0,found=0;
  if(store){PCCERT_CONTEXT cert=0;while((cert=CertEnumCertificatesInStore(store,cert))!=0){scanned++;BYTE hash[32];DWORD n=32;if(CertGetCertificateContextProperty(cert,CERT_SHA256_HASH_PROP_ID,hash,&n)&&n==32){const WCHAR*hex=L"0123456789ABCDEF";int equal=1;for(int i=0;i<32;i++)if(requested[i*2]!=hex[hash[i]>>4]||requested[i*2+1]!=hex[hash[i]&15]){equal=0;break;}if(equal){matches++;found++;CertGetNameStringW(cert,CERT_NAME_SIMPLE_DISPLAY_TYPE,0,0,subject,512);}}}CertCloseStore(store,0);}
  text("{\"location\":\"LocalMachine\",\"name\":");wide(names[k]);text(",\"openError\":");number(error);text(",\"scanned\":");number(scanned);text(",\"matches\":");number(found);text("}");
 }}
 text("],\"matched\":");text(matches?"true":"false");text(",\"matchCount\":");number(matches);text(",\"matchingSubject\":");if(matches)wide(subject);else text("null");text(",\"requestedSha256\":");if(valid)wide(requested);else text("null");text("}\n");WriteFile(GetStdHandle((DWORD)-11),output,used,&sent,0);ExitProcess(valid?0:64);
}
