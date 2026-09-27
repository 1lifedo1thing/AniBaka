#pragma once
#include "common.h"
#include <vector>
#include <filesystem>

inline std::wstring QuoteArgument(const std::wstring& argument) {
  std::wstring result=L"\""; size_t slashes=0;
  for(wchar_t c:argument) {
    if(c==L'\\') { ++slashes; continue; }
    result.append(c==L'"' ? slashes*2+1 : slashes,L'\\'); slashes=0; result+=c;
  }
  result.append(slashes*2,L'\\'); return result+L'"';
}

// Each decoder is isolated in a kill-on-close job; only its own handles are inherited.
class DecoderProcess {
 public:
  Handle output, process, job;
  DecoderProcess(const std::wstring& executable, const std::vector<std::wstring>& args) {
    job.reset(CreateJobObjectW(nullptr,nullptr)); Require(job.value!=nullptr,"Create decoder job");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    Require(SetInformationJobObject(job.value,JobObjectExtendedLimitInformation,&limits,sizeof(limits))!=0,"Configure decoder job");
    SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};
    Handle writer, input, error;
    Require(CreatePipe(&output.value,&writer.value,&sa,1024*1024)!=0,"Decoder pipe");
    Require(SetHandleInformation(output.value,HANDLE_FLAG_INHERIT,0)!=0,"Pipe inheritance");
    input.reset(CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr));
    Require(input.value!=INVALID_HANDLE_VALUE,"Decoder stdin");
    Require(DuplicateHandle(GetCurrentProcess(),GetStdHandle(STD_ERROR_HANDLE),GetCurrentProcess(),
        &error.value,0,TRUE,DUPLICATE_SAME_ACCESS)!=0,"Decoder diagnostics");
    std::wstring command=QuoteArgument(executable);
    for(const auto& a:args) command+=L" "+QuoteArgument(a);
    Require(command.size()<32767,"Decoder command length");
    STARTUPINFOEXW si{}; si.StartupInfo.cb=sizeof(si);
    si.StartupInfo.dwFlags=STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput=input.value; si.StartupInfo.hStdOutput=writer.value; si.StartupInfo.hStdError=error.value;
    SIZE_T size=0; InitializeProcThreadAttributeList(nullptr,1,0,&size);
    std::vector<unsigned char> attributes(size);
    si.lpAttributeList=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
    Require(InitializeProcThreadAttributeList(si.lpAttributeList,1,0,&size)!=0,"Decoder attributes");
    HANDLE handles[]={input.value,writer.value,error.value};
    BOOL ok=UpdateProcThreadAttribute(si.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        handles,sizeof(handles),nullptr,nullptr);
    PROCESS_INFORMATION child{};
    if(ok) ok=CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,TRUE,
        CREATE_NO_WINDOW|CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT,nullptr,
        std::filesystem::path(executable).parent_path().c_str(),&si.StartupInfo,&child);
    DWORD errorCode=GetLastError(); DeleteProcThreadAttributeList(si.lpAttributeList);
    SetLastError(errorCode); Require(ok!=0,"Start FFmpeg");
    process.reset(child.hProcess); Handle thread(child.hThread);
    if(!AssignProcessToJobObject(job.value,process.value) || ResumeThread(thread.value)==static_cast<DWORD>(-1)) {
      errorCode=GetLastError(); TerminateProcess(process.value,1);
      WaitForSingleObject(process.value,5000); SetLastError(errorCode);
      Require(false,"Start owned decoder");
    }
  }
  ~DecoderProcess() { Stop(); }
  void Stop() {
    if(job.value) TerminateJobObject(job.value,1);
    if(process.value) WaitForSingleObject(process.value,5000);
  }
  size_t Read(unsigned char* target,size_t size) {
    size_t total=0;
    while(total<size) {
      DWORD got=0;
      if(!ReadFile(output.value,target+total,static_cast<DWORD>(std::min<size_t>(size-total,1024*1024)),&got,nullptr)||!got) break;
      total+=got;
    }
    return total;
  }
  bool Succeeded() {
    if(WaitForSingleObject(process.value,5000)!=WAIT_OBJECT_0) return false;
    DWORD code=1; return GetExitCodeProcess(process.value,&code) && code==0;
  }
};
