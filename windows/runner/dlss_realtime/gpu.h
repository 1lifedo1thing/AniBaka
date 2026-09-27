#pragma once
#include <memory>
#include <string>
#include <vector>
#include <cstdint>
#include <windows.h>

// D3D11 owns the interchange textures. D3D12 imports their NT handles.
// Output textures only need copy access; NGX UAVs remain private to D3D12.
struct RealtimeSharedTextures {
  HANDLE input=nullptr, real=nullptr, generated=nullptr;
};

// Owns persistent NR/SR/FG features and a three-slot D3D12 submission ring.
// Decoded NV12 enters once; enhanced pixels never return to system memory.
class RealtimeGpu {
 public:
  RealtimeGpu(HWND window, unsigned width, unsigned height,
              const std::wstring& runtime, const std::wstring& cache,
              float intensity, unsigned scale, const std::wstring& fgRuntime,
              double fps, const LUID* adapter = nullptr,
              const RealtimeSharedTextures* shared = nullptr);
  ~RealtimeGpu();
  // Prepare once, then present the midpoint and real image at their deadlines.
  bool Prepare(const std::vector<unsigned char>& nv12, bool reset, bool original);
  void SetIntensity(float intensity);
  void SetFrameGenerationEnabled(bool enabled);
  void SetNeuralRenderingEnabled(bool enabled);
  bool Prepared();
  void WaitPrepared();
  bool InterpolationAllowed();
  void Present(bool generated);
  void Flush();
  uint64_t CompletedFrames();
  uint64_t PresentedFrames();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
