#include <windows.h>
#include <cstdio>
BOOL CALLBACK Close(HWND window, LPARAM data) {
 wchar_t text[128];GetWindowTextW(window,text,128);
 if(wcscmp(text,L"LRDP")==0){PostMessageW(window,WM_CLOSE,0,0);*reinterpret_cast<bool*>(data)=true;return FALSE;}
 return TRUE;
}
int main(){bool found=false;EnumWindows(Close,reinterpret_cast<LPARAM>(&found));return found?0:1;}
