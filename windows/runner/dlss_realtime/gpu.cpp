#include "gpu.h"
#include "common.h"
#include "vendor/archspoof.h"
#include "vendor/nr_params.h"
#include "ngx_features.h"
#include <d3d12.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <array>
#include <algorithm>
#include <cstring>
#include <deque>
#include <mutex>

using Microsoft::WRL::ComPtr;
namespace {
// NGX's public SDK is not thread safe. Flutter frame leases may be released
// on the raster thread while another video is using the shared render worker.
std::mutex ngxMutex;
using Shutdown = decltype(&NVSDK_NGX_D3D12_Shutdown1);
using Create = void*(__cdecl*)(const wchar_t*, const wchar_t*, ID3D12Device*,
    ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, unsigned, unsigned,
    unsigned, unsigned, const NrModelParams*);
using Evaluate = int(__cdecl*)(ID3D12GraphicsCommandList*, void*,
    NVSDK_NGX_Parameter*, ID3D12Resource*, ID3D12Resource*, ID3D12Resource*,
    ID3D12Resource*, unsigned, unsigned, unsigned, unsigned, int);
using Release = void(__cdecl*)(void*);
template<class T> T Symbol(HMODULE module, const char* name) {
  auto result = reinterpret_cast<T>(GetProcAddress(module, name));
  Require(result != nullptr, name); return result;
}

const char* kConvert = R"hlsl(
#if BGRA
Texture2D<float4> src:register(t0);
#else
Texture2D<float> Y:register(t0); Texture2D<float2> UV:register(t1);
#endif
RWTexture2D<float4> color:register(u0); RWTexture2D<float> depth:register(u1);
cbuffer C:register(b0) { uint w,h,reset,pad; }
[numthreads(8,8,1)] void main(uint3 id:SV_DispatchThreadID) {
 if(id.x>=w || id.y>=h) return;
#if BGRA
 color[id.xy]=float4(src[id.xy].rgb,1);
#else
 float y=(Y[id.xy]-16.0/255.0)*(255.0/219.0);
 float2 uv=(UV[id.xy/2]-128.0/255.0)*(255.0/224.0);
 color[id.xy]=float4(saturate(float3(y+1.5748*uv.y,
     y-0.187324*uv.x-0.468124*uv.y,y+1.8556*uv.x)),1);
#endif
 depth[id.xy]=0.5;
})hlsl";

// A bounded local block search supplies current->previous pixel motion.
// This is video-derived motion, not engine motion/depth or NVOFA.
const char* kFlow = R"hlsl(
Texture2D<float4> cur:register(t0); Texture2D<float4> prev:register(t1);
RWTexture2D<float2> motion:register(u0);
cbuffer C:register(b0) { uint w,h,reset,pad; }
float lum(float3 c) { return dot(c,float3(.2126,.7152,.0722)); }
[numthreads(8,8,1)] void main(uint3 id:SV_DispatchThreadID) {
 int2 base=int2(id.xy)*8; if(base.x>=int(w)||base.y>=int(h)) return;
 float2 best=0; float bestCost=1e10;
 if(reset==0) {
  [loop] for(int dy=-8;dy<=8;dy+=2) [loop] for(int dx=-8;dx<=8;dx+=2) {
   float cost=.00005*(dx*dx+dy*dy);
   [unroll] for(int y=1;y<8;y+=3) [unroll] for(int x=1;x<8;x+=3) {
    int2 p=clamp(base+int2(x,y),int2(0,0),int2(w-1,h-1));
    int2 q=clamp(p+int2(dx,dy),int2(0,0),int2(w-1,h-1));
    cost+=abs(lum(cur[p].rgb)-lum(prev[q].rgb));
   }
   if(cost<bestCost) { bestCost=cost; best=float2(dx,dy); }
  }
 }
 [unroll] for(int by=0;by<8;++by) [unroll] for(int bx=0;bx<8;++bx) {
  int2 p=base+int2(bx,by); if(p.x<int(w)&&p.y<int(h)) motion[p]=best;
 }
})hlsl";
const char* kPack = R"hlsl(
Texture2D<float4> src:register(t0); RWTexture2D<unorm float4> dst:register(u0);
SamplerState linearClamp:register(s0);
cbuffer C:register(b0) { uint w,h,reset,pad; }
[numthreads(8,8,1)] void main(uint3 id:SV_DispatchThreadID) {
 if(id.x>=w || id.y>=h) return;
 uint sw,sh; src.GetDimensions(sw,sh);
 float3 c=(sw==w && sh==h) ? src[id.xy].rgb : src.SampleLevel(linearClamp,(float2(id.xy)+.5)/float2(w,h),0).rgb;
 dst[id.xy]=float4(saturate(c),1);
})hlsl";
struct Texture {
  ComPtr<ID3D12Resource> resource;
  D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_COMMON;
};
struct Completions {
  std::deque<UINT64> pending;
  uint64_t count = 0;
  uint64_t Collect(UINT64 completed) {
    while (!pending.empty() && pending.front() <= completed) {
      pending.pop_front(); ++count;
    }
    return count;
  }
};
}

struct RealtimeGpu::Impl {
  unsigned w, h, scale, dw, dh;
  bool fgEnabled, preparedSr=false, preparedFg=false, reportedSr=false, reportedFg=false;
  bool fgActive=true;
  bool nrActive=true;
  std::wstring nrRuntime,nrCache;
  Create create=nullptr;
  NgxFeatures extra;
  ComPtr<IDXGIFactory4> factory;
  ComPtr<ID3D12Device> device;
  ComPtr<ID3D12CommandQueue> queue;
  ComPtr<ID3D12GraphicsCommandList> list;
  ComPtr<ID3D12Fence> fence;
  Handle event{CreateEventW(nullptr, FALSE, FALSE, nullptr)};
  ComPtr<IDXGISwapChain3> swap;
  ComPtr<ID3D12RootSignature> root;
  ComPtr<ID3D12DescriptorHeap> heap;
  ComPtr<ID3D12PipelineState> convert, flow, pack;
  std::array<Texture, 11> textures; // Y, UV, color, previous, NR, motion, depth, packed, SR, FG, BGRA
  Texture sharedReal, sharedGenerated;
  Texture disableInterpolation;
  ComPtr<ID3D12Resource> disableReadback;
  unsigned char* disableMapped=nullptr;
  std::array<ComPtr<ID3D12Resource>, 3> back;
  struct Slot {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12Resource> upload;
    unsigned char* mapped = nullptr;
    UINT64 fence = 0;
  };
  std::array<Slot, 3> slots;
  unsigned slot = 0, descriptorSize = 0, currentColor = 2;
  UINT64 sequence = 0;
  UINT64 preparedFence=0,preparedAt=0;
  Completions submittedFrames, submittedPresents;
  D3D12_PLACED_SUBRESOURCE_FOOTPRINT yFoot{}, uvFoot{};
  HMODULE forwarder = nullptr;
  NVSDK_NGX_Parameter* parameters = nullptr;
  void* feature = nullptr;
  Shutdown shutdown = nullptr;
  Release release = nullptr;
  Evaluate evaluate = nullptr;

  Impl(unsigned width, unsigned height, unsigned outputScale, bool fg)
      : w(width), h(height), scale(outputScale), dw(w*scale), dh(h*scale), fgEnabled(fg) {}
  ~Impl() {
    // Device loss can make a fence unreachable. Never hang shutdown forever.
    try { Flush(); } catch (...) {}
    extra.Close();
    if (feature && release) release(feature);
    if (parameters) NVSDK_NGX_D3D12_DestroyParameters(parameters);
    if (shutdown && device) shutdown(device.Get());
    for (auto& s : slots) if (s.mapped) s.upload->Unmap(0, nullptr);
    if (disableMapped) disableReadback->Unmap(0, nullptr);
    // Keep driver/forwarder modules loaded until this isolated process exits:
    // the arch compatibility callback can still refer to driver module code.
  }
  void Wait(UINT64 value) {
    if (fence->GetCompletedValue() >= value) return;
    Check(fence->SetEventOnCompletion(value, event.value), "Fence event");
    Require(WaitForSingleObject(event.value, 10000) == WAIT_OBJECT_0, "GPU timed out");
    Check(device->GetDeviceRemovedReason(), "GPU device");
  }
  void Flush() {
    if (!queue || !fence) return;
    Check(queue->Signal(fence.Get(), ++sequence), "Signal GPU"); Wait(sequence);
  }
  Slot& Begin() {
    auto& s=slots[slot]; Wait(s.fence);
    Check(s.allocator->Reset(),"Reset allocator");
    Check(list->Reset(s.allocator.Get(),nullptr),"Reset command list");
    return s;
  }
  UINT64 Submit(bool present=false) {
    Check(list->Close(),"Close GPU commands");
    ID3D12CommandList* lists[]={list.Get()}; queue->ExecuteCommandLists(1,lists);
    if(present) Check(swap->Present(0,0),"Present frame");
    Check(queue->Signal(fence.Get(),++sequence),"Submit GPU fence");
    slots[slot].fence=sequence; slot=(slot+1)%slots.size();
    // Drain even when the embedded player never asks for standalone stats.
    const auto completed=fence->GetCompletedValue();
    submittedFrames.Collect(completed); submittedPresents.Collect(completed);
    return sequence;
  }
  void Transition(Texture& texture, D3D12_RESOURCE_STATES state) {
    if (texture.state == state) return;
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition = {texture.resource.Get(), D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                          texture.state, state};
    list->ResourceBarrier(1, &barrier); texture.state = state;
  }
  void Uav(ID3D12Resource* resource) {
    D3D12_RESOURCE_BARRIER b{}; b.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    b.UAV.pResource = resource; list->ResourceBarrier(1, &b);
  }
  D3D12_CPU_DESCRIPTOR_HANDLE Cpu(unsigned index) {
    auto result = heap->GetCPUDescriptorHandleForHeapStart();
    result.ptr += static_cast<SIZE_T>(index) * descriptorSize; return result;
  }
  D3D12_GPU_DESCRIPTOR_HANDLE Gpu(unsigned index) {
    auto result = heap->GetGPUDescriptorHandleForHeapStart();
    result.ptr += static_cast<UINT64>(index) * descriptorSize; return result;
  }
  ComPtr<ID3D12Resource> Resource(const D3D12_RESOURCE_DESC& desc,D3D12_HEAP_TYPE type=D3D12_HEAP_TYPE_DEFAULT) {
    D3D12_HEAP_PROPERTIES heapProperties{}; heapProperties.Type=type;
    const auto state=type==D3D12_HEAP_TYPE_UPLOAD ? D3D12_RESOURCE_STATE_GENERIC_READ :
        type==D3D12_HEAP_TYPE_READBACK ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_COMMON;
    ComPtr<ID3D12Resource> result;
    Check(device->CreateCommittedResource(&heapProperties,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,
        IID_PPV_ARGS(&result)),"GPU resource");
    return result;
  }
  ComPtr<ID3D12Resource> Buffer(UINT64 size,D3D12_HEAP_TYPE type) {
    D3D12_RESOURCE_DESC desc{}; desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width=size; desc.Height=desc.SampleDesc.Count=1;
    desc.DepthOrArraySize=desc.MipLevels=1;
    desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if(type==D3D12_HEAP_TYPE_DEFAULT) desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    return Resource(desc,type);
  }
  void Compute(ID3D12PipelineState* shader, unsigned src0, unsigned src1,
               unsigned dst0, unsigned dst1, bool reset, unsigned groupsX, unsigned groupsY) {
    // NGX may change all root bindings and descriptor heaps.
    ID3D12DescriptorHeap* heaps[] = {heap.Get()};
    list->SetDescriptorHeaps(1, heaps);
    list->SetComputeRootSignature(root.Get()); list->SetPipelineState(shader);
    list->SetComputeRootDescriptorTable(0, Gpu(src0));
    list->SetComputeRootDescriptorTable(1, Gpu(src1));
    list->SetComputeRootDescriptorTable(2, Gpu(11 + dst0));
    list->SetComputeRootDescriptorTable(3, Gpu(11 + dst1));
    const unsigned constants[] = {shader==pack.Get() ? dw : w,
                                 shader==pack.Get() ? dh : h, reset ? 1u : 0u, 0};
    list->SetComputeRoot32BitConstants(4, 4, constants, 0);
    list->Dispatch(groupsX, groupsY, 1);
  }
  void CreateNr(float intensity) {
    if(feature) release(feature);
    feature=nullptr;
    if(parameters) NVSDK_NGX_D3D12_DestroyParameters(parameters);
    parameters=nullptr;
    Require(NVSDK_NGX_D3D12_AllocateParameters(&parameters)==1 && parameters,"NGX NR parameters unavailable");
    const NrModelParams model{0,intensity,1,1,1,-1,0,0};
    feature=create((nrRuntime+L"\\nvngx_dlssnr.dll").c_str(),nrCache.c_str(),
        device.Get(),list.Get(),parameters,w,h,w,h,&model);
  }
  void Initialize(HWND window, const std::wstring& runtime,
                  const std::wstring& cache, float intensity,
                  const std::wstring& fgRuntime, double fps, const LUID* adapterLuid,
                  const RealtimeSharedTextures* shared) {
    Require(event.value != nullptr, "Create fence event");
    Check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "DXGI factory");
    ComPtr<IDXGIAdapter1> selected;
    SIZE_T memory = 0;
    for (UINT i = 0;; ++i) {
      ComPtr<IDXGIAdapter1> adapter;
      if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) break;
      DXGI_ADAPTER_DESC1 desc{}; Check(adapter->GetDesc1(&desc), "Adapter details");
      if (adapterLuid && (desc.AdapterLuid.LowPart!=adapterLuid->LowPart ||
                         desc.AdapterLuid.HighPart!=adapterLuid->HighPart)) continue;
      if (desc.VendorId == 0x10DE && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
          (!selected || desc.DedicatedVideoMemory > memory)) {
        selected = adapter; memory = desc.DedicatedVideoMemory;
      }
    }
    Require(selected != nullptr, "Video renderer must use the NVIDIA GPU (Windows Graphics settings: High performance)");
    DXGI_ADAPTER_DESC1 desc{}; selected->GetDesc1(&desc);
    LogInfo("GPU: %s", Widen2Narrow(desc.Description).c_str());
    Check(D3D12CreateDevice(selected.Get(), D3D_FEATURE_LEVEL_12_0,
                            IID_PPV_ARGS(&device)), "D3D12 device");
    auto importTexture=[&](HANDLE handle,Texture& texture,unsigned width,unsigned height,
                           DXGI_FORMAT format,const char* operation) {
      Require(handle!=nullptr,operation);
      Check(device->OpenSharedHandle(handle,IID_PPV_ARGS(&texture.resource)),operation);
      const auto description=texture.resource->GetDesc();
      Require(description.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE2D &&
          description.Width==width && description.Height==height && description.Format==format &&
          description.MipLevels==1 && description.DepthOrArraySize==1 && description.SampleDesc.Count==1,
          "Shared video texture layout mismatch");
    };
    if(!window) {
      Require(shared!=nullptr,"Embedded playback requires D3D11 interchange textures");
      importTexture(shared->real,sharedReal,dw,dh,DXGI_FORMAT_R8G8B8A8_UNORM,"Import D3D11 enhanced output into D3D12");
      if(fgEnabled)
        importTexture(shared->generated,sharedGenerated,dw,dh,DXGI_FORMAT_R8G8B8A8_UNORM,"Import D3D11 generated output into D3D12");
    }
    D3D12_COMMAND_QUEUE_DESC q{}; q.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    Check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)), "GPU queue");
    Check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "GPU fence");
    for (auto& s : slots)
      Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
            IID_PPV_ARGS(&s.allocator)), "Command allocator");
    Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
          slots[0].allocator.Get(), nullptr, IID_PPV_ARGS(&list)), "Command list");
    if (window) {
    DXGI_SWAP_CHAIN_DESC1 sd{};
    sd.Width = dw; sd.Height = dh; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 3; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.Scaling = DXGI_SCALING_STRETCH; sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    ComPtr<IDXGISwapChain1> sc;
    Check(factory->CreateSwapChainForHwnd(queue.Get(), window, &sd, nullptr, nullptr, &sc), "Swapchain");
    Check(sc.As(&swap), "Swapchain interface");
    factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER);
    for (unsigned i = 0; i < 3; ++i) Check(swap->GetBuffer(i, IID_PPV_ARGS(&back[i])), "Back buffer");
    }

    const DXGI_FORMAT formats[] = {DXGI_FORMAT_R8_UNORM, DXGI_FORMAT_R8G8_UNORM,
        DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R16G16B16A16_FLOAT,
        DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R16G16_FLOAT,
        DXGI_FORMAT_R32_FLOAT, DXGI_FORMAT_R8G8B8A8_UNORM,
        DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM};
    D3D12_DESCRIPTOR_HEAP_DESC hd{}; hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    hd.NumDescriptors = 22; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    Check(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap)), "Descriptor heap");
    descriptorSize = device->GetDescriptorHandleIncrementSize(hd.Type);
    for (unsigned i = 0; i < textures.size(); ++i) {
      D3D12_RESOURCE_DESC d{}; d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
      d.Width = i == 1 ? w / 2 : (i>=7 && i<=9 ? dw : w);
      d.Height = i == 1 ? h / 2 : (i>=7 && i<=9 ? dh : h);
      d.DepthOrArraySize = 1; d.MipLevels = 1; d.Format = formats[i]; d.SampleDesc.Count = 1;
      if (i >= 2 && i!=10) d.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
      if(!window && i==10) {
        importTexture(shared->input,textures[i],w,h,formats[i],"Import D3D11 input into D3D12");
      } else textures[i].resource=Resource(d);
      D3D12_SHADER_RESOURCE_VIEW_DESC srv{}; srv.Format = formats[i];
      srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; srv.Texture2D.MipLevels = 1;
      srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
      device->CreateShaderResourceView(textures[i].resource.Get(), &srv, Cpu(i));
      if (i >= 2 && i!=10) {
        D3D12_UNORDERED_ACCESS_VIEW_DESC uav{}; uav.Format = formats[i];
        uav.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
        device->CreateUnorderedAccessView(textures[i].resource.Get(), nullptr, &uav, Cpu(11+i));
      }
    }
    if (fgEnabled) {
      disableInterpolation.resource=Buffer(4,D3D12_HEAP_TYPE_DEFAULT);
      disableReadback=Buffer(4,D3D12_HEAP_TYPE_READBACK);
      D3D12_RANGE range{0,4};
      Check(disableReadback->Map(0,&range,reinterpret_cast<void**>(&disableMapped)),"Map FG hint");
    }
    if(window) {
    UINT64 ySize, total;
    auto yDesc = textures[0].resource->GetDesc(), uvDesc = textures[1].resource->GetDesc();
    device->GetCopyableFootprints(&yDesc, 0, 1, 0, &yFoot, nullptr, nullptr, &ySize);
    device->GetCopyableFootprints(&uvDesc, 0, 1, (ySize+511)&~511ull,
                                  &uvFoot, nullptr, nullptr, &total);
    // GetCopyableFootprints' total includes the base offset on current D3D12;
    // allocate from the explicit footprint end to make that contract irrelevant.
    total = uvFoot.Offset + static_cast<UINT64>(uvFoot.Footprint.RowPitch) * (h/2);
    for (auto& s : slots) {
      s.upload=Buffer(total,D3D12_HEAP_TYPE_UPLOAD);
      D3D12_RANGE empty{};
      Check(s.upload->Map(0, &empty, reinterpret_cast<void**>(&s.mapped)), "Map upload");
    }
    }
    std::array<D3D12_DESCRIPTOR_RANGE, 4> ranges{};
    std::array<D3D12_ROOT_PARAMETER, 5> roots{};
    for (unsigned i = 0; i < 4; ++i) {
      ranges[i].RangeType = i<2 ? D3D12_DESCRIPTOR_RANGE_TYPE_SRV : D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
      ranges[i].NumDescriptors = 1; ranges[i].BaseShaderRegister = i%2;
      roots[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
      roots[i].DescriptorTable = {1, &ranges[i]};
    }
    roots[4].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    roots[4].Constants = {0,0,4};
    D3D12_ROOT_SIGNATURE_DESC rd{}; rd.NumParameters = 5; rd.pParameters = roots.data();
    D3D12_STATIC_SAMPLER_DESC sampler{};
    sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxLOD=D3D12_FLOAT32_MAX; sampler.ShaderVisibility=D3D12_SHADER_VISIBILITY_ALL;
    rd.NumStaticSamplers=1; rd.pStaticSamplers=&sampler;
    ComPtr<ID3DBlob> signature, errors;
    Check(D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &signature, &errors), "Root signature");
    Check(device->CreateRootSignature(0, signature->GetBufferPointer(), signature->GetBufferSize(),
                                      IID_PPV_ARGS(&root)), "Root signature object");
    auto compile = [&](const char* source, ComPtr<ID3D12PipelineState>& target) {
      ComPtr<ID3DBlob> shader, error;
      const D3D_SHADER_MACRO input[]={{"BGRA",window ? "0" : "1"},{nullptr,nullptr}};
      const HRESULT hr = D3DCompile(source, strlen(source), nullptr, input, nullptr,
          "main", "cs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &shader, &error);
      if (FAILED(hr) && error) LogInfo("%s", static_cast<char*>(error->GetBufferPointer()));
      Check(hr, "Compile compute shader");
      D3D12_COMPUTE_PIPELINE_STATE_DESC pd{}; pd.pRootSignature = root.Get();
      pd.CS = {shader->GetBufferPointer(), shader->GetBufferSize()};
      Check(device->CreateComputePipelineState(&pd, IID_PPV_ARGS(&target)), "Compute pipeline");
    };
    compile(kConvert, convert); compile(kFlow, flow); compile(kPack, pack);

    SetupArchSpoof();
    const wchar_t* paths[]={runtime.c_str(),fgRuntime.c_str()};
    NVSDK_NGX_FeatureCommonInfo info{};
    info.PathListInfo={paths, fgEnabled ? 2u : 1u};
    // The SDK translates FeatureCommonInfo into the driver's private ABI.
    // Driver exports are not interchangeable with these public entry points.
    const int result = NVSDK_NGX_D3D12_Init_with_ProjectID(
        "d2a90e04-86a3-4755-a1de-fb2fdccab650", NVSDK_NGX_ENGINE_TYPE_CUSTOM, "1.0",
        cache.c_str(), device.Get(), &info, NVSDK_NGX_Version_API);
    if (result != 1) throw std::runtime_error("NGX initialization failed: " + std::to_string(result));
    shutdown = NVSDK_NGX_D3D12_Shutdown1;
    forwarder = LoadLibraryExW((runtime + L"\\nvngx.dll_dlssnr.dll").c_str(),
                               nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    Require(forwarder != nullptr, "Load DLSS forwarder");
    create = Symbol<Create>(forwarder, "fwd_create");
    nrRuntime=runtime; nrCache=cache;
    evaluate = Symbol<Evaluate>(forwarder, "fwd_evaluate");
    release = Symbol<Release>(forwarder, "fwd_release");
    CreateNr(intensity);
    extra.Initialize(list.Get(),w,h,scale,fgEnabled,fps);
    Wait(Submit());
    if (!feature) {
      auto code = reinterpret_cast<int*>(GetProcAddress(forwarder, "fwd_last_create"));
      throw std::runtime_error("DLSS NR feature creation failed: " + std::to_string(code ? *code : 0));
    }
    LogInfo("DLSS NR feature 18 ready; %ux%u; GPU block motion; 3 command slots; no frame readback", w,h);
  }
  bool Prepare(const std::vector<unsigned char>& bytes, bool reset, bool original) {
    auto& s=Begin();
    if (!bytes.empty()) {
    for (unsigned i=0;i<2;++i) {
      const auto& footprint=i==0 ? yFoot : uvFoot;
      const auto* source=bytes.data()+(i==0 ? 0 : static_cast<size_t>(w)*h);
      for(unsigned y=0;y<footprint.Footprint.Height;++y)
        memcpy(s.mapped+footprint.Offset+static_cast<size_t>(y)*footprint.Footprint.RowPitch,
               source+static_cast<size_t>(y)*w,w);
      Transition(textures[i], D3D12_RESOURCE_STATE_COPY_DEST);
      D3D12_TEXTURE_COPY_LOCATION from{}, to{};
      from.pResource=s.upload.Get(); from.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
      from.PlacedFootprint=footprint;
      to.pResource=textures[i].resource.Get(); to.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
      list->CopyTextureRegion(&to,0,0,0,&from,nullptr);
      Transition(textures[i], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    }
    }
    // Alternate color textures; the last input already contains our history.
    const unsigned current=currentColor, previous=5-current;
    Transition(textures[current],D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Transition(textures[6],D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    if(bytes.empty()) Transition(textures[10],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Compute(convert.Get(),bytes.empty() ? 10 : 0,1,current,6,reset,(w+7)/8,(h+7)/8);
    if(bytes.empty()) Transition(textures[10],D3D12_RESOURCE_STATE_COMMON);
    Transition(textures[current],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(textures[previous],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(textures[5],D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Compute(flow.Get(),current,previous,5,6,reset,(w+63)/64,(h+63)/64);
    Transition(textures[5],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Transition(textures[6],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    const unsigned colorIndex=nrActive && !original ? 4u : current;
    if(colorIndex==4) {
    Transition(textures[4],D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    const int result=evaluate(list.Get(),feature,parameters,textures[current].resource.Get(),
        textures[6].resource.Get(),textures[5].resource.Get(),textures[4].resource.Get(),
        w,h,w,h,reset ? 1 : 0);
    if (result!=1) throw std::runtime_error("DLSS NR evaluation failed: "+std::to_string(result));
    Uav(textures[4].resource.Get());
    Transition(textures[4],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    }
    preparedSr=scale>1 && !original;
    preparedFg=fgEnabled && fgActive && !original;
    if (preparedSr) {
      Transition(textures[8],D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
      extra.SuperResolve(list.Get(),textures[colorIndex].resource.Get(),textures[6].resource.Get(),
          textures[5].resource.Get(),textures[8].resource.Get(),reset);
      Uav(textures[8].resource.Get());
      Transition(textures[8],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    }
    Transition(textures[7],D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Compute(pack.Get(),preparedSr ? 8 : colorIndex,3,7,6,reset,(dw+7)/8,(dh+7)/8);
    if (preparedFg) {
      Transition(textures[7],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
      Transition(textures[9],D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
      Transition(disableInterpolation,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
      extra.Generate(list.Get(),textures[7].resource.Get(),textures[6].resource.Get(),
          textures[5].resource.Get(),textures[9].resource.Get(),disableInterpolation.resource.Get(),reset);
      Uav(textures[9].resource.Get());
      Transition(disableInterpolation,D3D12_RESOURCE_STATE_COPY_SOURCE);
      list->CopyBufferRegion(disableReadback.Get(),0,disableInterpolation.resource.Get(),0,4);
    }
    if (!swap) {
      // Imported D3D11 textures are copy destinations, never NGX UAVs.
      // This avoids relying on the driver's D3D12->D3D11 descriptor reflection.
      Transition(textures[7],D3D12_RESOURCE_STATE_COPY_SOURCE);
      Transition(sharedReal,D3D12_RESOURCE_STATE_COPY_DEST);
      list->CopyResource(sharedReal.resource.Get(),textures[7].resource.Get());
      Transition(sharedReal,D3D12_RESOURCE_STATE_COMMON);
      if(preparedFg) {
        Transition(textures[9],D3D12_RESOURCE_STATE_COPY_SOURCE);
        Transition(sharedGenerated,D3D12_RESOURCE_STATE_COPY_DEST);
        list->CopyResource(sharedGenerated.resource.Get(),textures[9].resource.Get());
        Transition(sharedGenerated,D3D12_RESOURCE_STATE_COMMON);
      }
      Transition(textures[7],D3D12_RESOURCE_STATE_COMMON);
      Transition(textures[9],D3D12_RESOURCE_STATE_COMMON);
    }
    preparedFence=Submit(); preparedAt=GetTickCount64();
    submittedFrames.pending.push_back(preparedFence); currentColor=previous;
    return preparedFg && !reset;
  }
  bool Prepared() {
    Check(device->GetDeviceRemovedReason(),"GPU device");
    if (fence->GetCompletedValue()<preparedFence) {
      Require(GetTickCount64()-preparedAt<10000,"GPU enhancement timed out");
      return false;
    }
    if (preparedSr && !reportedSr) { std::puts("FEATURE SR active"); std::fflush(stdout); reportedSr=true; }
    if (preparedFg && !reportedFg) { std::puts("FEATURE FG active"); std::fflush(stdout); reportedFg=true; }
    return true;
  }
  void Present(bool generated) {
    Begin();
    auto& source=textures[generated ? 9 : 7];
    Transition(source,D3D12_RESOURCE_STATE_COPY_SOURCE);
    auto buffer=back[swap->GetCurrentBackBufferIndex()].Get();
    D3D12_RESOURCE_BARRIER barrier{}; barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition={buffer,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                        D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_COPY_DEST};
    list->ResourceBarrier(1,&barrier);
    list->CopyResource(buffer,source.resource.Get());
    std::swap(barrier.Transition.StateBefore,barrier.Transition.StateAfter);
    list->ResourceBarrier(1,&barrier);
    submittedPresents.pending.push_back(Submit(true));
  }
};

RealtimeGpu::RealtimeGpu(HWND window, unsigned w, unsigned h,
    const std::wstring& runtime, const std::wstring& cache, float intensity,
    unsigned scale, const std::wstring& fgRuntime, double fps, const LUID* adapter,
    const RealtimeSharedTextures* shared)
    : impl_(std::make_unique<Impl>(w,h,scale,!fgRuntime.empty())) {
  std::lock_guard<std::mutex> lock(ngxMutex);
  try { impl_->Initialize(window,runtime,cache,intensity,fgRuntime,fps,adapter,shared); }
  catch (...) { impl_.reset(); throw; }
}
RealtimeGpu::~RealtimeGpu() { std::lock_guard<std::mutex> lock(ngxMutex); impl_.reset(); }
bool RealtimeGpu::Prepare(const std::vector<unsigned char>& bytes, bool reset, bool original) {
  std::lock_guard<std::mutex> lock(ngxMutex);
  return impl_->Prepare(bytes,reset,original);
}
bool RealtimeGpu::Prepared() { return impl_->Prepared(); }
void RealtimeGpu::WaitPrepared() { impl_->Wait(impl_->preparedFence); impl_->Prepared(); }
void RealtimeGpu::SetIntensity(float intensity) {
  std::lock_guard<std::mutex> lock(ngxMutex);
  auto& p=*impl_; p.Flush();
  // NR parameters are latched at creation. Retain the device, textures, SR
  // and FG features; only replace the NR feature when its intensity changes.
  p.Begin();
  p.CreateNr(intensity);
  p.Wait(p.Submit());
  Require(p.feature!=nullptr,"DLSS NR intensity update failed");
}
void RealtimeGpu::SetFrameGenerationEnabled(bool enabled) {
  Require(!enabled || impl_->fgEnabled,"Frame generation requires initialization");
  impl_->fgActive=enabled;
}
void RealtimeGpu::SetNeuralRenderingEnabled(bool enabled) { impl_->nrActive=enabled; }
bool RealtimeGpu::InterpolationAllowed() {
  return impl_->preparedFg && Prepared() && impl_->disableMapped[0]==0;
}
void RealtimeGpu::Present(bool generated) { impl_->Present(generated); }
void RealtimeGpu::Flush() { impl_->Flush(); }
uint64_t RealtimeGpu::CompletedFrames() {
  return impl_->submittedFrames.Collect(impl_->fence->GetCompletedValue());
}
uint64_t RealtimeGpu::PresentedFrames() {
  return impl_->submittedPresents.Collect(impl_->fence->GetCompletedValue());
}
