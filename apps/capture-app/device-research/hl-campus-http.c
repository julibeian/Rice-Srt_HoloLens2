/* Bounded requests to the university's officially documented Wi-Fi portal.
 * A request file contains method, scheme, host, path, then form body (LF).
 * It is deleted on open/close, never echoed, and wiped before process exit.
 * Redirects are returned for review; TLS certificate verification stays on.
 */
typedef unsigned short WCHAR;
typedef unsigned long DWORD;
typedef unsigned long long U64;
typedef int BOOL;
typedef void *HANDLE;
#define API __stdcall
#define IMPORT __declspec(dllimport)
IMPORT WCHAR* API GetCommandLineW(void);
IMPORT DWORD API GetLastError(void);
IMPORT BOOL API GetUserNameW(WCHAR*,DWORD*);
IMPORT HANDLE API GetStdHandle(DWORD);
IMPORT HANDLE API CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
IMPORT BOOL API ReadFile(HANDLE,void*,DWORD,DWORD*,void*);
IMPORT BOOL API WriteFile(HANDLE,const void*,DWORD,DWORD*,void*);
IMPORT BOOL API CloseHandle(HANDLE);
IMPORT int API MultiByteToWideChar(unsigned int,DWORD,const char*,int,WCHAR*,int);
IMPORT int API WideCharToMultiByte(unsigned int,DWORD,const WCHAR*,int,char*,int,const char*,BOOL*);
IMPORT void API ExitProcess(DWORD);
IMPORT HANDLE API WinHttpOpen(const WCHAR*,DWORD,const WCHAR*,const WCHAR*,DWORD);
IMPORT BOOL API WinHttpSetTimeouts(HANDLE,int,int,int,int);
IMPORT HANDLE API WinHttpConnect(HANDLE,const WCHAR*,unsigned short,DWORD);
IMPORT HANDLE API WinHttpOpenRequest(HANDLE,const WCHAR*,const WCHAR*,const WCHAR*,const WCHAR*,const WCHAR**,DWORD);
IMPORT BOOL API WinHttpSetOption(HANDLE,DWORD,void*,DWORD);
IMPORT BOOL API WinHttpSendRequest(HANDLE,const WCHAR*,DWORD,void*,DWORD,DWORD,U64);
IMPORT BOOL API WinHttpReceiveResponse(HANDLE,void*);
IMPORT BOOL API WinHttpQueryHeaders(HANDLE,DWORD,const WCHAR*,void*,DWORD*,DWORD*);
IMPORT BOOL API WinHttpReadData(HANDLE,void*,DWORD,DWORD*);
IMPORT BOOL API WinHttpCloseHandle(HANDLE);
static WCHAR args[4][2048],user[512],method[16],host[128],path[8192],location[4096],content_type[256],wide_body[262144];
static char request_data[131072],response[262144],output[1800000],utf8[800000];
static DWORD used;
static int equal(const char*a,const char*b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static void chr(char c){if(used<sizeof(output))output[used++]=c;}
static void text(const char*s){while(*s)chr(*s++);}
static void number(U64 n){char b[24];int i=0;do{b[i++]=(char)('0'+n%10);n/=10;}while(n);while(i)chr(b[--i]);}
static void string(const char*s){static const char hex[]="0123456789abcdef";chr('"');while(*s){unsigned char c=(unsigned char)*s++;if(c=='"'||c=='\\'){chr('\\');chr((char)c);}else if(c<32){text("\\u00");chr(hex[c>>4]);chr(hex[c&15]);}else chr((char)c);}chr('"');}
static void wide(const WCHAR*s){if(WideCharToMultiByte(65001,0,s,-1,utf8,sizeof(utf8),0,0)>0)string(utf8);else text("null");}
static void base64(const unsigned char*b,DWORD size){static const char abc[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";chr('"');for(DWORD i=0;i<size;i+=3){DWORD v=(DWORD)b[i]<<16;if(i+1<size)v|=(DWORD)b[i+1]<<8;if(i+2<size)v|=b[i+2];chr(abc[(v>>18)&63]);chr(abc[(v>>12)&63]);chr(i+1<size?abc[(v>>6)&63]:'=');chr(i+2<size?abc[v&63]:'=');}chr('"');}
static void field(const char*key,DWORD n){chr(',');string(key);chr(':');number(n);}
static int parse_args(void){const WCHAR*p=GetCommandLineW();int argc=0;while(*p){int quoted=0,n=0;while(*p==' '||*p=='\t')p++;if(!*p)break;if(argc>=4)return 0;while(*p&&(quoted||(*p!=' '&&*p!='\t'))){if(*p=='"'){quoted=!quoted;p++;continue;}if(n>=2047)return 0;args[argc][n++]=*p++;}if(quoted)return 0;args[argc++][n]=0;}return argc==3;}
void API hl_campus_entry(void){
  DWORD error=0,stage=0,count=0,status=0,sent=0,total=0,n=0,read=0,port=0;HANDLE input=0,file=0,session=0,connection=0,http=0;char*parts[5]={0};
  if(!parse_args()){error=87;goto done;}
  if(args[1][1]!=':'||args[1][2]!='\\'||args[2][1]!=':'||args[2][2]!='\\'){error=87;goto done;}
  file=CreateFileW(args[2],0x40000000,1,0,1,0x80,0);if(file==(HANDLE)(U64)-1){file=0;error=GetLastError();goto done;}
  stage=1;input=CreateFileW(args[1],0x80000000|0x00010000,0,0,3,0x04000000|0x08000000,0);if(input==(HANDLE)(U64)-1){input=0;error=GetLastError();goto done;}
  if(!ReadFile(input,request_data,sizeof(request_data)-1,&count,0)){error=GetLastError();goto done;}CloseHandle(input);input=0;
  parts[0]=request_data;n=1;for(DWORD i=0;i<count&&n<5;i++){if(request_data[i]=='\n'){request_data[i]=0;parts[n++]=&request_data[i+1];}}
  if(n!=5||(!equal(parts[0],"GET")&&!equal(parts[0],"POST"))||(!equal(parts[1],"http")&&!equal(parts[1],"https"))||
    (!equal(parts[2],"wifi.njau.edu.cn")&&!equal(parts[2],"aaa.njau.edu.cn")&&!equal(parts[2],"172.16.0.3")&&!equal(parts[2],"10.64.0.129")&&!equal(parts[2],"10.64.0.129:801"))||parts[3][0]!='/'){error=87;goto done;}
  if(equal(parts[2],"10.64.0.129:801")){parts[2][11]=0;port=801;}
  for(char*p=parts[3];*p;p++)if(*p=='\r'||*p=='\n'){error=87;goto done;}
  if(!MultiByteToWideChar(65001,0,parts[0],-1,method,16)||!MultiByteToWideChar(65001,0,parts[2],-1,host,128)||!MultiByteToWideChar(65001,0,parts[3],-1,path,8192)){error=87;goto done;}
  stage=2;session=WinHttpOpen((const WCHAR*)L"Mozilla/5.0 HoloLensCampusConnectivity/1.0",1,0,0,0);if(!session){error=GetLastError();goto done;}
  WinHttpSetTimeouts(session,4000,4000,4000,4000);
  stage=3;BOOL secure=equal(parts[1],"https");connection=WinHttpConnect(session,host,(unsigned short)(port?port:(secure?443:80)),0);if(!connection){error=GetLastError();goto done;}
  stage=4;http=WinHttpOpenRequest(connection,method,path,0,0,0,secure?0x00800000:0);if(!http){error=GetLastError();goto done;}
  DWORD redirects=0,disabled=7,decompress=3;WinHttpSetOption(http,88,&redirects,4);WinHttpSetOption(http,63,&disabled,4);WinHttpSetOption(http,118,&decompress,4);
  DWORD body_size=count-(DWORD)(parts[4]-request_data);BOOL post=equal(parts[0],"POST");
  stage=5;if(!WinHttpSendRequest(http,(const WCHAR*)L"Content-Type: application/x-www-form-urlencoded\r\nAccept: */*\r\n",(DWORD)-1,post?parts[4]:0,post?body_size:0,post?body_size:0,0)){error=GetLastError();goto done;}
  stage=6;if(!WinHttpReceiveResponse(http,0)){error=GetLastError();goto done;}
  stage=7;n=4;if(!WinHttpQueryHeaders(http,19|0x20000000,0,&status,&n,0)){error=GetLastError();goto done;}
  n=sizeof(location);WinHttpQueryHeaders(http,33,0,location,&n,0);n=sizeof(content_type);WinHttpQueryHeaders(http,1,0,content_type,&n,0);
  stage=8;while(total<sizeof(response)-1){if(!WinHttpReadData(http,response+total,sizeof(response)-1-total,&read)){error=GetLastError();break;}if(!read)break;total+=read;}
done:
  if(input)CloseHandle(input);if(http)WinHttpCloseHandle(http);if(connection)WinHttpCloseHandle(connection);if(session)WinHttpCloseHandle(session);
  DWORD user_size=512;GetUserNameW(user,&user_size);text("{\"user\":");wide(user);field("stage",stage);field("error",error);field("httpStatus",status);text(",\"host\":");wide(host);text(",\"location\":");wide(location);text(",\"contentType\":");wide(content_type);field("responseBytes",total);text(",\"responseBody\":");
  DWORD codepage=65001;for(DWORD i=0;content_type[i]&&i<250;i++)if(content_type[i]=='g'&&content_type[i+1]=='b')codepage=936;
  if(total>2&&(unsigned char)response[0]==31&&(unsigned char)response[1]==139){text("null,\"responseGzipBase64\":");base64((const unsigned char*)response,total);}else{int decoded=MultiByteToWideChar(codepage,0,response,(int)total,wide_body,262143);wide_body[decoded>0?decoded:0]=0;wide(wide_body);}text("}\n");
  volatile char*wipe=request_data;for(DWORD i=0;i<sizeof(request_data);i++)wipe[i]=0;
  if(file){WriteFile(file,output,used,&sent,0);CloseHandle(file);}WriteFile(GetStdHandle((DWORD)-11),output,used,&sent,0);ExitProcess(error?2:0);
}
