// Raw frames travel directly between inherited Windows pipe handles. Only
// bounded, tagged diagnostic lines cross back into Flutter.
#include <windows.h>

#include <array>
#include <cstdio>
#include <cwchar>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
class Handle {
 public:
  HANDLE value = nullptr;
  ~Handle() { reset(); }
  Handle() = default;
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  void reset(HANDLE next = nullptr) {
    if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value);
    value = next;
  }
};

struct Pipe {
  Handle read;
  Handle write;
  bool create(DWORD capacity = 65536) {
    SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    return CreatePipe(&read.value, &write.value, &security, capacity) != FALSE;
  }
};

std::mutex log_mutex;
void Emit(char stage, const std::string& line) {
  if (line.empty()) return;
  std::lock_guard<std::mutex> lock(log_mutex);
  std::fputc(stage, stdout);
  std::fputc('\t', stdout);
  std::fwrite(line.data(), 1, line.size(), stdout);
  std::fputc('\n', stdout);
  std::fflush(stdout);
}

void Drain(HANDLE pipe, char stage) {
  std::array<char, 4096> buffer{};
  std::string line;
  DWORD bytes = 0;
  while (ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &bytes, nullptr) && bytes != 0) {
    for (DWORD i = 0; i < bytes; ++i) {
      const char c = buffer[i];
      if (c == '\n' || c == '\r') {
        Emit(stage, line);
        line.clear();
      } else {
        // Keep logs bounded even for malformed output without line breaks.
        if (line.size() == 16000) {
          Emit(stage, line);
          line.clear();
        }
        line += c;
      }
    }
  }
  Emit(stage, line);
}

// Windows CRT command-line quoting, including quotes and trailing backslashes.
std::wstring Quote(const std::wstring& argument) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t c : argument) {
    if (c == L'\\') {
      ++slashes;
    } else {
      result.append(c == L'"' ? slashes * 2 + 1 : slashes, L'\\');
      slashes = 0;
      result += c;
    }
  }
  result.append(slashes * 2, L'\\');
  return result + L'"';
}

bool Start(const std::vector<std::wstring>& arguments, HANDLE input,
           HANDLE output, HANDLE error, HANDLE job, Handle& process) {
  std::wstring command;
  for (const auto& arg : arguments) {
    if (!command.empty()) command += L' ';
    command += Quote(arg);
  }
  if (command.size() >= 32767) {
    SetLastError(ERROR_BAD_LENGTH);
    return false;
  }
  const auto separator = arguments[0].find_last_of(L"\\/");
  const std::wstring directory = arguments[0].substr(0, separator);
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = input;
  startup.StartupInfo.hStdOutput = output;
  startup.StartupInfo.hStdError = error;
  SIZE_T attribute_bytes = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
  std::vector<unsigned char> attributes(attribute_bytes);
  startup.lpAttributeList =
      reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0,
                                         &attribute_bytes)) return false;
  // Only these handles may be inherited. Inheriting another pipe's writer
  // would prevent EOF and hang the downstream process forever.
  std::vector<HANDLE> handles{input, output};
  if (error != output) handles.push_back(error);
  BOOL ok = UpdateProcThreadAttribute(
      startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      handles.data(), handles.size() * sizeof(HANDLE), nullptr, nullptr);
  PROCESS_INFORMATION child{};
  if (ok) {
    ok = CreateProcessW(arguments[0].c_str(), command.data(), nullptr, nullptr,
                        TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED |
                                  EXTENDED_STARTUPINFO_PRESENT,
                        nullptr, directory.c_str(), &startup.StartupInfo,
                        &child);
  }
  const DWORD create_error = GetLastError();
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (!ok) {
    SetLastError(create_error);
    return false;
  }
  process.reset(child.hProcess);
  Handle thread;
  thread.reset(child.hThread);
  // Assign before resuming so cancellation cannot leave a running orphan.
  if (!AssignProcessToJobObject(job, process.value) ||
      ResumeThread(thread.value) == static_cast<DWORD>(-1)) {
    const DWORD error_code = GetLastError();
    TerminateProcess(process.value, 1);
    WaitForSingleObject(process.value, INFINITE);
    SetLastError(error_code);
    return false;
  }
  return true;
}

int Error(const char* operation) {
  std::fprintf(stderr, "%s failed (Windows error %lu)\n", operation,
               GetLastError());
  return 1;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  // Protocol v1: parent PID, then three length-prefixed argv groups. There is
  // no shell, config script, or delimiter that a file name can escape into.
  if (argc < 9 || std::wstring(argv[1]) != L"--v1") return 2;
  wchar_t* end = nullptr;
  const unsigned long parent_id = std::wcstoul(argv[2], &end, 10);
  if (!parent_id || *end != L'\0') return 2;
  std::array<std::vector<std::wstring>, 3> arguments;
  int cursor = 3;
  for (auto& args : arguments) {
    if (cursor >= argc) return 2;
    const long count = std::wcstol(argv[cursor++], &end, 10);
    if (*end != L'\0' || count < 1 || count > argc - cursor) return 2;
    for (long i = 0; i < count; ++i) args.emplace_back(argv[cursor++]);
  }
  if (cursor != argc) return 2;
  Handle parent;
  parent.reset(OpenProcess(SYNCHRONIZE, FALSE, parent_id));
  if (!parent.value) return Error("Open parent");
  Handle job;
  job.reset(CreateJobObjectW(nullptr, nullptr));
  if (!job.value) return Error("Create job");
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job.value, JobObjectExtendedLimitInformation,
                               &limits, sizeof(limits))) return Error("Set job");
  Pipe decoded;
  Pipe enhanced;
  std::array<Pipe, 3> logs;
  // Two bounded 1 MiB raw buffers; no whole-video buffering.
  if (!decoded.create(1024 * 1024) || !enhanced.create(1024 * 1024))
    return Error("Create frame pipes");
  for (auto& pipe : logs) {
    if (!pipe.create()) return Error("Create log pipe");
  }
  SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  Handle null_input;
  null_input.reset(CreateFileW(L"NUL", GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, &security,
                              OPEN_EXISTING, 0, nullptr));
  if (null_input.value == INVALID_HANDLE_VALUE) return Error("Open NUL");
  const std::array<HANDLE, 3> inputs{
      null_input.value, decoded.read.value, enhanced.read.value};
  const std::array<HANDLE, 3> outputs{
      decoded.write.value, enhanced.write.value, logs[2].write.value};
  std::array<Handle, 3> children;
  for (size_t i = 0; i < children.size(); ++i) {
    if (!Start(arguments[i], inputs[i], outputs[i], logs[i].write.value,
               job.value, children[i])) {
      const int result = Error("Start pipeline stage");
      TerminateJobObject(job.value, 1);
      for (auto& child : children) {
        if (child.value) WaitForSingleObject(child.value, INFINITE);
      }
      return result;
    }
  }
  decoded.read.reset();
  decoded.write.reset();
  enhanced.read.reset();
  enhanced.write.reset();
  null_input.reset();
  std::array<std::thread, 3> readers;
  for (size_t i = 0; i < logs.size(); ++i) {
    logs[i].write.reset();
    readers[i] = std::thread(Drain, logs[i].read.value, "DNE"[i]);
  }
  std::array<bool, 3> finished{};
  size_t remaining = children.size();
  bool failed = false;
  while (remaining && !failed) {
    std::vector<HANDLE> waiting{parent.value};
    std::vector<size_t> indices;
    for (size_t i = 0; i < children.size(); ++i) {
      if (!finished[i]) {
        waiting.push_back(children[i].value);
        indices.push_back(i);
      }
    }
    const DWORD event = WaitForMultipleObjects(
        static_cast<DWORD>(waiting.size()), waiting.data(), FALSE, INFINITE);
    if (event == WAIT_OBJECT_0 || event == WAIT_FAILED) {
      failed = true;  // Parent closed or the wait failed: stop this job only.
      break;
    }
    const size_t index = indices[event - WAIT_OBJECT_0 - 1];
    DWORD code = 1;
    if (!GetExitCodeProcess(children[index].value, &code)) code = 1;
    Emit('X', std::to_string(index) + "\t" + std::to_string(code));
    finished[index] = true;
    --remaining;
    failed = code != 0;
  }
  if (failed) TerminateJobObject(job.value, 1);
  for (auto& child : children) WaitForSingleObject(child.value, INFINITE);
  for (auto& reader : readers) reader.join();
  return failed ? 1 : 0;
}
