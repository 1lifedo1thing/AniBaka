#include "common.h"
#include "gpu.h"
#include "decoder_process.h"
#include <mmsystem.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <memory>
#include <sstream>
#include <thread>

namespace {
using Clock=std::chrono::steady_clock;
double Seconds(Clock::time_point time) { return std::chrono::duration<double>(Clock::now()-time).count(); }
void Emit(const char* text) { std::printf("%s\n",text); std::fflush(stdout); }
struct Options {
  std::wstring ffmpeg, file, runtime, cache, matrix, fgRuntime;
  unsigned width=0,height=0,parent=0,scale=1;
  double fps=0,duration=0;
  int video=0,audio=-1;
  float intensity=.7f;
};
std::vector<std::wstring> InputArgs(const Options& o,double seek) {
  return {L"-nostdin",L"-hide_banner",L"-v",L"error",L"-xerror",
          L"-ss",std::to_wstring(seek),L"-noautorotate",L"-i",o.file};
}
struct VideoFrame { std::vector<unsigned char> bytes; uint64_t index=0; };
class VideoDecoder {
 public:
  std::atomic<bool> stopped{false};
  std::mutex mutex; std::condition_variable room;
  std::deque<VideoFrame> frames;
  bool done=false; std::string error;
  std::unique_ptr<DecoderProcess> process;
  std::thread worker;
  VideoDecoder(const Options& o,double seek) {
    auto args=InputArgs(o,seek);
    // FFmpeg negotiates hardware decode where supported; the raw NV12 boundary
    // still transfers through system memory. Color conversion into NR is on GPU.
    args.insert(args.begin()+5,{L"-hwaccel",L"auto"});
    const std::wstring filter=L"fps="+std::to_wstring(o.fps)+L":start_time=0,scale="+
        std::to_wstring(o.width)+L":"+std::to_wstring(o.height)+
        L":in_color_matrix="+o.matrix+L":out_color_matrix=bt709:out_range=tv,format=nv12";
    args.insert(args.end(),{L"-map",L"0:"+std::to_wstring(o.video),L"-an",L"-sn",L"-dn",
        L"-vf",filter,L"-pix_fmt",L"nv12",L"-f",L"rawvideo",L"-fps_mode",L"passthrough",L"pipe:1"});
    process=std::make_unique<DecoderProcess>(o.ffmpeg,args);
    const size_t size=static_cast<size_t>(o.width)*o.height*3/2;
    worker=std::thread([this,size] {
      uint64_t index=0;
      while(!stopped) {
        VideoFrame frame; frame.index=index++; frame.bytes.resize(size);
        const size_t got=process->Read(frame.bytes.data(),size);
        if(got!=size) {
          const bool success=got==0 && process->Succeeded();
          std::lock_guard<std::mutex> lock(mutex);
          if(!stopped && !success) error="Video decoding failed or produced a partial frame";
          done=true; return;
        }
        std::unique_lock<std::mutex> lock(mutex);
        room.wait(lock,[&] { return stopped || frames.size()<4; });
        if(stopped) return;
        frames.push_back(std::move(frame));
      }
    });
  }
  ~VideoDecoder() { stopped=true; room.notify_all(); process->Stop(); if(worker.joinable()) worker.join(); }
  bool Pop(VideoFrame& frame) {
    std::lock_guard<std::mutex> lock(mutex);
    if(!error.empty()) throw std::runtime_error(error);
    if(frames.empty()) return false;
    frame=std::move(frames.front()); frames.pop_front(); room.notify_one(); return true;
  }
  bool Ended() { std::lock_guard<std::mutex> lock(mutex); return done && frames.empty(); }
};

class AudioDecoder {
 public:
  std::atomic<bool> stopped{false},finished{false},ready{false},failed{false};
  HWAVEOUT wave=nullptr;
  Handle event{CreateEventW(nullptr,FALSE,FALSE,nullptr)};
  std::unique_ptr<DecoderProcess> process;
  std::thread worker;
  // Three 50ms blocks bound audio read-ahead and make seeking cheap.
  std::array<std::array<unsigned char,9600>,3> buffers{};
  std::array<WAVEHDR,3> headers{};
  AudioDecoder(const Options& o,double seek) {
    WAVEFORMATEX format{}; format.wFormatTag=WAVE_FORMAT_PCM;
    format.nChannels=2; format.nSamplesPerSec=48000; format.wBitsPerSample=16;
    format.nBlockAlign=4; format.nAvgBytesPerSec=192000;
    Require(event.value!=nullptr,"Audio event");
    if(waveOutOpen(&wave,WAVE_MAPPER,&format,reinterpret_cast<DWORD_PTR>(event.value),0,CALLBACK_EVENT)!=MMSYSERR_NOERROR)
      throw std::runtime_error("Could not open audio output");
    waveOutPause(wave);
    try {
      auto args=InputArgs(o,seek);
      args.insert(args.end(),{L"-map",L"0:"+std::to_wstring(o.audio),L"-vn",L"-sn",L"-dn",
          L"-af",L"aresample=async=1:first_pts=0",L"-ac",L"2",L"-ar",L"48000",
          L"-f",L"s16le",L"pipe:1"});
      process=std::make_unique<DecoderProcess>(o.ffmpeg,args);
      for(size_t i=0;i<headers.size();++i) {
        headers[i].lpData=reinterpret_cast<char*>(buffers[i].data());
        headers[i].dwBufferLength=static_cast<DWORD>(buffers[i].size());
        if(waveOutPrepareHeader(wave,&headers[i],sizeof(WAVEHDR))!=MMSYSERR_NOERROR)
          throw std::runtime_error("Could not prepare audio buffer");
      }
      worker=std::thread([this] {
        size_t slot=0; bool any=false;
        while(!stopped) {
          auto& header=headers[slot];
          while(!stopped && (header.dwFlags&WHDR_INQUEUE)) WaitForSingleObject(event.value,20);
          if(stopped) break;
          const size_t got=process->Read(buffers[slot].data(),buffers[slot].size());
          if(got%4) { failed=true; break; }
          if(got==0) {
            if(!process->Succeeded() && !stopped) failed=true;
            break;
          }
          header.dwBufferLength=static_cast<DWORD>(got);
          if(waveOutWrite(wave,&header,sizeof(header))!=MMSYSERR_NOERROR) { failed=true; break; }
          any=true; ready=true; slot=(slot+1)%headers.size();
        }
        if(!any) ready=true;
        while(!stopped) {
          bool pending=false;
          for(const auto& header:headers) pending=pending || (header.dwFlags&WHDR_INQUEUE)!=0;
          if(!pending) break;
          WaitForSingleObject(event.value,20);
        }
        finished=true;
      });
    } catch(...) { Close(); throw; }
  }
  ~AudioDecoder() { Close(); }
  void Close() {
    stopped=true;
    if(process) process->Stop();
    SetEvent(event.value);
    if(worker.joinable()) worker.join();
    if(wave) {
      waveOutReset(wave);
      for(auto& header:headers) if(header.dwFlags&WHDR_PREPARED) waveOutUnprepareHeader(wave,&header,sizeof(header));
      waveOutClose(wave); wave=nullptr;
    }
  }
  void Pause(bool value) { if(value) waveOutPause(wave); else waveOutRestart(wave); }
  double Position() {
    MMTIME time{}; time.wType=TIME_SAMPLES;
    if(waveOutGetPosition(wave,&time,sizeof(time))!=MMSYSERR_NOERROR)
      throw std::runtime_error("Audio clock unavailable");
    if(time.wType==TIME_SAMPLES) return time.u.sample/48000.0;
    if(time.wType==TIME_BYTES) return time.u.cb/192000.0;
    if(time.wType==TIME_MS) return time.u.ms/1000.0;
    throw std::runtime_error("Unsupported audio clock");
  }
};

struct Controls {
  std::mutex mutex;
  std::deque<std::string> commands;
  std::atomic<bool> stopped{false};
  std::thread thread;
  Controls() {
    thread=std::thread([this] {
      char data[256]; DWORD got=0; std::string pending;
      const HANDLE input=GetStdHandle(STD_INPUT_HANDLE);
      while(!stopped) {
        DWORD available=0;
        if(!PeekNamedPipe(input,nullptr,0,nullptr,&available,nullptr)) break;
        if(available==0) { std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }
        if(!ReadFile(input,data,std::min<DWORD>(available,sizeof(data)),&got,nullptr) || !got) break;
        for(DWORD i=0;i<got;++i) {
          if(data[i]=='\n') {
            std::lock_guard<std::mutex> lock(mutex);
            if(commands.size()<64) commands.push_back(pending);
            pending.clear();
          } else if(data[i]!='\r' && pending.size()<128) pending+=data[i];
        }
      }
      stopped=true;
    });
  }
  ~Controls() {
    stopped=true;
    if(thread.joinable()) thread.join();
  }
  std::deque<std::string> Take() {
    std::lock_guard<std::mutex> lock(mutex);
    std::deque<std::string> result; result.swap(commands); return result;
  }
};
HWND videoWindow=nullptr;
unsigned videoWidth=0,videoHeight=0;
bool closing=false,togglePause=false,toggleCompare=false;
bool fullscreen=false;
WINDOWPLACEMENT windowPlacement{sizeof(WINDOWPLACEMENT)};
double jump=0;
void Layout(HWND parent) {
  if(!videoWindow) return;
  RECT rect{}; GetClientRect(parent,&rect);
  int w=rect.right,h=rect.bottom;
  if(w<=0||h<=0) return;
  const double scale=std::min(static_cast<double>(w)/videoWidth,static_cast<double>(h)/videoHeight);
  const int vw=std::max(1,static_cast<int>(videoWidth*scale)), vh=std::max(1,static_cast<int>(videoHeight*scale));
  MoveWindow(videoWindow,(w-vw)/2,(h-vh)/2,vw,vh,TRUE);
}
LRESULT CALLBACK WindowProc(HWND window,UINT message,WPARAM key,LPARAM lparam) {
  switch(message) {
    case WM_CLOSE: closing=true; return 0;
    case WM_SIZE: Layout(window); return 0;
    case WM_KEYDOWN:
      if(key==VK_ESCAPE) closing=true;
      if(key==VK_SPACE) togglePause=true;
      if(key=='D') toggleCompare=true;
      if(key==VK_LEFT) jump=-10;
      if(key==VK_RIGHT) jump=10;
      if(key==VK_F11) {
        if(!fullscreen) {
          GetWindowPlacement(window,&windowPlacement);
          MONITORINFO monitor{sizeof(MONITORINFO)};
          if(GetMonitorInfoW(MonitorFromWindow(window,MONITOR_DEFAULTTONEAREST),&monitor)) {
            SetWindowLongPtrW(window,GWL_STYLE,WS_POPUP|WS_VISIBLE|WS_CLIPCHILDREN);
            SetWindowPos(window,HWND_TOP,monitor.rcMonitor.left,monitor.rcMonitor.top,
                monitor.rcMonitor.right-monitor.rcMonitor.left,monitor.rcMonitor.bottom-monitor.rcMonitor.top,
                SWP_FRAMECHANGED); fullscreen=true;
          }
        } else {
          SetWindowLongPtrW(window,GWL_STYLE,WS_OVERLAPPEDWINDOW|WS_VISIBLE|WS_CLIPCHILDREN);
          SetWindowPlacement(window,&windowPlacement);
          SetWindowPos(window,nullptr,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_FRAMECHANGED);
          fullscreen=false;
        }
      }
      return 0;
  }
  return DefWindowProcW(window,message,key,lparam);
}
bool SceneCut(const VideoFrame& frame,std::vector<unsigned char>& previous,unsigned w,unsigned h) {
  std::vector<unsigned char> current; current.reserve(32*18);
  for(unsigned y=0;y<18;++y) for(unsigned x=0;x<32;++x)
    current.push_back(frame.bytes[static_cast<size_t>(y*h/18)*w+x*w/32]);
  double difference=0;
  if(previous.size()==current.size()) for(size_t i=0;i<current.size();++i)
    difference+=std::abs(static_cast<int>(current[i])-static_cast<int>(previous[i]));
  const bool cut=previous.empty() || difference/(current.size()*255.0)>.24;
  previous=std::move(current); return cut;
}

void Play(const Options& o) {
  Handle parent(OpenProcess(SYNCHRONIZE,FALSE,o.parent));
  Require(parent.value!=nullptr,"Open parent application");
  WNDCLASSW wc{}; wc.lpfnWndProc=WindowProc; wc.hInstance=GetModuleHandleW(nullptr);
  wc.hCursor=LoadCursorW(nullptr,IDC_ARROW); wc.hbrBackground=static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  wc.lpszClassName=L"BakaDlssRealtime"; Require(RegisterClassW(&wc)!=0,"Register player window");
  WNDCLASSW surface{}; surface.lpfnWndProc=DefWindowProcW;
  surface.hInstance=wc.hInstance; surface.lpszClassName=L"BakaDlssSurface";
  Require(RegisterClassW(&surface)!=0,"Register video surface");
  videoWidth=o.width; videoHeight=o.height;
  HWND window=CreateWindowW(wc.lpszClassName,L"Baka · DLSS 5 — Space: pause · D: compare · ←/→: seek",
      WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,CW_USEDEFAULT,CW_USEDEFAULT,1120,700,
      nullptr,nullptr,wc.hInstance,nullptr);
  Require(window!=nullptr,"Create player window");
  videoWindow=CreateWindowW(surface.lpszClassName,nullptr,WS_CHILD|WS_VISIBLE,0,0,1,1,
                             window,nullptr,wc.hInstance,nullptr);
  Require(videoWindow!=nullptr,"Create video surface");
  Layout(window); ShowWindow(window,SW_SHOW); SetFocus(window);
  Controls controls;
  RealtimeGpu gpu(videoWindow,o.width,o.height,o.runtime,o.cache,o.intensity,o.scale,o.fgRuntime,o.fps);
  std::unique_ptr<VideoDecoder> video;
  std::unique_ptr<AudioDecoder> audio;
  VideoFrame pending, displayed; bool have=false,paused=false,started=false,original=false,reset=true;
  bool prepared=false,interpolate=false;
  double realDeadline=0;
  auto redraw=[&] {
    gpu.Prepare(displayed.bytes,true,original); gpu.WaitPrepared();
    gpu.Present(false); prepared=false; reset=true;
  };
  double origin=0,pausedAt=0,position=0;
  Clock::time_point anchor=Clock::now(),statsTime=anchor;
  uint64_t dropped=0,lastRendered=0,lastPresented=0,generated=0;
  std::vector<unsigned char> previous;
  auto restart=[&](double seek) {
    if(audio) audio->Pause(true);
    audio.reset(); video.reset(); gpu.Flush();
    origin=std::clamp(seek,0.0,std::max(0.0,o.duration-.05)); position=origin;
    started=false; have=false; prepared=false; reset=true; previous.clear();
    Emit("STATE buffering");
    video=std::make_unique<VideoDecoder>(o,origin);
    if(o.audio>=0) audio=std::make_unique<AudioDecoder>(o,origin);
  };
  restart(0); Emit("READY");
  while(!closing && !controls.stopped && WaitForSingleObject(parent.value,0)==WAIT_TIMEOUT) {
    MSG message;
    while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) {
      if(message.message==WM_QUIT) closing=true;
      TranslateMessage(&message); DispatchMessageW(&message);
    }
    auto commands=controls.Take();
    if(togglePause) { commands.push_back(paused ? "resume" : "pause"); togglePause=false; }
    if(toggleCompare) { commands.push_back(original ? "compare 0" : "compare 1"); toggleCompare=false; }
    if(jump!=0) { commands.push_back("seek "+std::to_string(position+jump)); jump=0; }
    for(const auto& command:commands) {
      if(command=="stop") { closing=true; break; }
      if(command=="pause" && !paused) {
        pausedAt=Seconds(anchor); paused=true; if(audio) audio->Pause(true); Emit("STATE paused");
        reset=true;
        if(prepared) { gpu.WaitPrepared(); gpu.Present(false); prepared=false; }
      } else if(command=="resume" && paused) {
        anchor=Clock::now()-std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(pausedAt));
        paused=false; if(started && audio) audio->Pause(false); Emit(started ? "STATE playing" : "STATE buffering");
      } else if(command.rfind("seek ",0)==0) {
        const double seek=std::stod(command.substr(5)); if(std::isfinite(seek)) restart(seek);
      } else if(command=="compare 0" || command=="compare 1") {
        original=command.back()=='1'; Emit(original ? "COMPARE original" : "COMPARE enhanced");
        reset=true;
        if(started && !displayed.bytes.empty()) redraw();
      }
    }
    if(closing) break;
    if(audio && audio->failed) throw std::runtime_error("Audio decoding/output failed; see FFmpeg log");
    if(!have) have=video->Pop(pending);
    if(!started && !have && video->Ended()) {
      if(origin>0) { Emit("STATE ended"); break; }
      throw std::runtime_error("The decoder produced no video frames");
    }
    if(!started && have && (!audio || audio->ready)) {
      reset=true;
      gpu.Prepare(pending.bytes,true,original); gpu.WaitPrepared(); gpu.Present(false);
      anchor=Clock::now(); pausedAt=0;
      SceneCut(pending,previous,o.width,o.height);
      displayed=std::move(pending);
      have=false; started=true; reset=false;
      if(!paused && audio) audio->Pause(false);
      Emit(paused ? "STATE paused" : "STATE playing");
    }
    if(started && !paused) {
      const double elapsed=audio && !audio->finished ? audio->Position() : Seconds(anchor);
      position=std::min(o.duration,origin+elapsed);
      // Inference runs ahead, but each image is submitted at its own timestamp.
      // A late midpoint is skipped, never shown immediately beside the real frame.
      if(prepared && gpu.Prepared()) {
        if(interpolate && elapsed>=realDeadline-.5/o.fps) {
          if(elapsed<realDeadline-.002 && gpu.InterpolationAllowed()) {
            gpu.Present(true); ++generated;
          }
          interpolate=false;
        }
        if(elapsed>=realDeadline) { gpu.Present(false); prepared=false; }
      }
      // Audio is the master clock. Drop stale decoded frames before inference.
      unsigned budget=8;
      while(!prepared && have && pending.index/o.fps < elapsed-1.5/o.fps && budget>0) {
        --budget;
        ++dropped; reset=true; have=video->Pop(pending);
      }
      if(!prepared && have) {
        reset=SceneCut(pending,previous,o.width,o.height) || reset;
        realDeadline=pending.index/o.fps;
        interpolate=gpu.Prepare(pending.bytes,reset,original);
        prepared=true; have=false; reset=false;
        displayed=std::move(pending);
      }
      if(!prepared && !have && video->Ended() && (!audio || audio->finished)) { Emit("STATE ended"); break; }
    }
    const double statsElapsed=Seconds(statsTime);
    if(statsElapsed>=.5) {
      const uint64_t rendered=gpu.CompletedFrames();
      const uint64_t presented=gpu.PresentedFrames();
      const double fps=(rendered-lastRendered)/statsElapsed;
      const double displayFps=(presented-lastPresented)/statsElapsed;
      std::printf("STAT %.3f %.2f %llu %.2f %llu\n",position,fps,static_cast<unsigned long long>(dropped),
                  displayFps,static_cast<unsigned long long>(generated)); std::fflush(stdout);
      lastRendered=rendered; lastPresented=presented; statsTime=Clock::now();
      const auto title=L"Baka · DLSS 5 | "+std::to_wstring(static_cast<int>(fps))+L" fps | drop "+
          std::to_wstring(dropped)+L" | present "+std::to_wstring(static_cast<int>(displayFps))+
          (original ? L" | Original" : L" | Enhanced")+
          (paused ? L" | Paused" : L"");
      SetWindowTextW(window,title.c_str());
    }
    MsgWaitForMultipleObjects(0,nullptr,FALSE,2,QS_ALLINPUT);
  }
  audio.reset(); video.reset(); gpu.Flush();
  DestroyWindow(window); videoWindow=nullptr;
}
} // namespace

int wmain(int argc,wchar_t** argv) {
  try {
    // All paths are individual argv values, never shell commands.
    if(argc!=17 || std::wstring(argv[1])!=L"--v2") throw std::runtime_error("Invalid realtime protocol; rebuild the Windows app");
    Options o; o.parent=std::stoul(argv[2]); o.ffmpeg=argv[3]; o.file=argv[4];
    o.runtime=argv[5]; o.cache=argv[6]; o.width=std::stoul(argv[7]); o.height=std::stoul(argv[8]);
    o.fps=std::stod(argv[9]); o.duration=std::stod(argv[10]);
    o.video=std::stoi(argv[11]); o.audio=std::stoi(argv[12]); o.intensity=std::stof(argv[13]); o.matrix=argv[14];
    o.scale=std::stoul(argv[15]); o.fgRuntime=argv[16];
    if(!o.parent || o.width<2 || o.height<2 || o.width>1920 || o.height>1080 ||
        o.width%2 || o.height%2 || !std::isfinite(o.fps) || o.fps<=0 || o.fps>60 ||
        !std::isfinite(o.duration) || o.duration<=0 || !std::isfinite(o.intensity) ||
        o.intensity<.1 || o.intensity>2 || o.video<0 || o.audio< -1 || (o.scale!=1 && o.scale!=2) ||
        (o.matrix!=L"bt709" && o.matrix!=L"smpte170m" && o.matrix!=L"bt470bg"))
      throw std::runtime_error("Unsupported realtime video parameters");
    Play(o); return 0;
  } catch(const std::exception& error) {
    LogInfo("ERROR %s",error.what()); return 1;
  }
}
