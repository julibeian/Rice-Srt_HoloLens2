#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "../yolo-native/YoloCore.h"
int _fltused=0;
void*memcpy(void*d,const void*s,size_t n){unsigned char*a=d;const unsigned char*b=s;while(n--)*a++=*b++;return d;}
__declspec(dllexport) void YoloLetterbox(const BYTE*pixels,int width,int height,float*out){y_letterbox(pixels,width,height,out);}
__declspec(dllexport) int YoloDecode(const float*raw,int width,int height,YoloBox*out){YoloBox*work=HeapAlloc(GetProcessHeap(),0,YOLO_CANDIDATES*sizeof(YoloBox));if(!work)return -1;int count=y_decode(raw,width,height,.4f,.45f,work,out);HeapFree(GetProcessHeap(),0,work);return count;}
