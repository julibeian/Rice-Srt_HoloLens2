/* Shared parsing for diagnostic output in this project's existing dev layout.
 * Explicit outputs must be one new JSON filename below the allowed directory.
 */
static WCHAR hl_report_argument[1024];
static int hl_report_explicit;
static int hl_report_path(const WCHAR*fallback,const WCHAR*directory,const WCHAR**result){
 const WCHAR*p=GetCommandLineW();int seen=0;
 while(*p){
  while(*p==' '||*p=='\t')p++;if(!*p)break;
  const WCHAR*start=p;int quoted=0;WCHAR token[1024];unsigned n=0;
  while(*p&&(quoted||(*p!=' '&&*p!='\t'))){if(*p=='"'){quoted=!quoted;p++;continue;}if(n>=1023)return 0;token[n++]=*p++;}token[n]=0;if(quoted)return 0;
  if(n==5&&token[0]=='-'&&token[1]=='-'&&token[2]=='o'&&token[3]=='u'&&token[4]=='t'){
   if(seen)return 0;seen=1;while(*p==' '||*p=='\t')p++;quoted=0;n=0;
   while(*p&&(quoted||(*p!=' '&&*p!='\t'))){if(*p=='"'){quoted=!quoted;p++;continue;}if(n>=1023)return 0;hl_report_argument[n++]=*p++;}hl_report_argument[n]=0;if(quoted||!n)return 0;
  }
  (void)start;
 }
 if(!seen){*result=fallback;return 1;}
 unsigned i=0;while(directory[i]){if(hl_report_argument[i]!=directory[i])return 0;i++;}
 unsigned filename=i;while(hl_report_argument[i]&&hl_report_argument[i]!='.'){
  WCHAR c=hl_report_argument[i++];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'))return 0;
 }
 if(i==filename)return 0;const WCHAR*tail=(const WCHAR*)L".json";unsigned j=0;while(tail[j]){if(hl_report_argument[i+j]!=tail[j])return 0;j++;}if(hl_report_argument[i+j])return 0;
 hl_report_explicit=1;*result=hl_report_argument;return 1;
}
