#include <windows.h>
#include <cstdio>
#include <cstring>
#include <string>
std::wstring Quote(const wchar_t* text) {
 std::wstring result=L"\"";unsigned backslashes=0;
 for(;*text;++text) {
  if(*text==L'\\'){++backslashes;continue;}
  result.append(*text==L'"'?backslashes*2+1:backslashes,L'\\');backslashes=0;result+=*text;
 }
 result.append(backslashes*2,L'\\');return result+L"\"";
}
int wmain(int argc,wchar_t** argv){
 if(argc<3||!GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"wine_get_version"))return 2;
 std::wstring command;
 for(int i=2;i<argc;++i){if(i>2)command+=L' ';command+=Quote(argv[i]);}
 STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};
 if(!CreateProcessW(nullptr,command.data(),nullptr,nullptr,FALSE,CREATE_SUSPENDED,nullptr,nullptr,&startup,&process))return 3;
 auto fail=[&](int code){TerminateProcess(process.hProcess,code);CloseHandle(process.hThread);CloseHandle(process.hProcess);return code;};
 SIZE_T bytes=(wcslen(argv[1])+1)*sizeof(wchar_t);
 void* memory=VirtualAllocEx(process.hProcess,nullptr,bytes,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
 if(!memory||!WriteProcessMemory(process.hProcess,memory,argv[1],bytes,nullptr))return fail(4);
 auto raw=GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"LoadLibraryW");
 LPTHREAD_START_ROUTINE load;static_assert(sizeof(raw)==sizeof(load));std::memcpy(&load,&raw,sizeof(load));
 HANDLE thread=CreateRemoteThread(process.hProcess,nullptr,0,load,memory,0,nullptr);
 if(!thread)return fail(5);
 if(WaitForSingleObject(thread,30000)!=WAIT_OBJECT_0){CloseHandle(thread);return fail(6);}
 DWORD loaded=0;GetExitCodeThread(thread,&loaded);CloseHandle(thread);
 if(!loaded)return fail(7);
 VirtualFreeEx(process.hProcess,memory,0,MEM_RELEASE);
 std::puts("Owned Wine child: explicit Dart legacy allocator compatibility enabled");std::fflush(stdout);
 ResumeThread(process.hThread);WaitForSingleObject(process.hProcess,INFINITE);
 DWORD result=1;GetExitCodeProcess(process.hProcess,&result);CloseHandle(process.hThread);CloseHandle(process.hProcess);return static_cast<int>(result);
}
