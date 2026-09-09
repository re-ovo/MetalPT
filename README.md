# MetalPT

原生 macOS **RGB 路径追踪器**，使用 SwiftUI、Metal 4 和 MSL。渲染使用线性 RGB，不再使用光谱采样、光学数据表或色散。

需要 macOS 26.5+、M3 或更新 Apple Silicon，以及带 Metal Toolchain 的 Xcode 26。打开 `MetalPT.xcodeproj`，选择 **MetalPT / My Mac** 运行。

## 功能与交互

- 内置 Cornell 材质场景与玻璃棱镜场景；支持打开或拖入 glTF / GLB，异步解析、自动取景和查看灯光。
- 顶部工具栏提供场景导入与切换、暂停、重新累积和相机复位；左侧场景树保留 glTF 节点名称和父子层级，支持展开、搜索、选择，右侧检查器显示节点统计和渲染设置。两侧面板可调整宽度或收起。
- FPS 相机：按住右键环顾，同时 WASD 水平移动、Q/E 升降、Shift 四倍加速；滚轮调整速度，检查器调整视野。松开右键、按 Esc 或窗口失焦会停止移动。
- 工具栏「＋」可添加点光源、聚光灯和平行光；检查器支持启用、颜色、强度、位置、方向、范围、锥角和删除。支持 glTF `KHR_lights_punctual` 导入。
- 默认启用空间降噪：首交点法线、深度和反照率引导三轮边缘保持滤波，可在检查器开关和调节强度；镜面、透明及发光表面保留原图，不修改原始累积。
- 默认 50% drawable 分辨率、每帧 1 spp、最多 8 次表面交互。相机、场景、尺寸和深度变化重置累积；曝光只改变显示。
- 漫反射、RGB 黄金、metallic-roughness / specular-glossiness PBR、固定折射率 1.5 的理想玻璃、附加发光及 glTF 薄表面透射。
- UV0/1、顶点颜色、平滑法线、法线贴图、纹理变换、采样器、mip、单双面及 OPAQUE/MASK/BLEND 覆盖。

模型支持和限制见 [glTF 导入](docs/gltf-import.md)，资产语义见 [表面资产](docs/surface-assets.md)。

## 渲染实现

```text
新几何：批量 Build BLAS → Build TLAS
每个样本：Initialize
          ┌ PrepareBounce → Intersect → Shade
          │                      ↓
          └ FinishBounce ← TraceShadows ← PrepareShadow
          Accumulate linear RGB → Tone map → sRGB display
```

GPU 原子计数器压紧路径和阴影队列，GPU 写入间接 dispatch 参数；CPU 编码固定最大反弹次数，不回读路径数量控制调度。硬件 triangle/instancing intersection query 处理求交、单双面和 alpha coverage。

材质颜色、发光和路径吞吐量均为线性 RGB。基色/发光图片通过 sRGB 纹理视图解码，数据纹理保持线性。BSDF 计算三个颜色通道，缓冲使用对齐的 float4，第四分量保留为零。FP32 RGB 运行平均经曝光、ACES 风格曲线和一次 sRGB 编码，写入非 sRGB BGRA8 drawable。

漫反射使用 RGB Lambert；两种 PBR 工作流经公共表面参数使用 GGX/Smith/Schlick；黄金使用近似 RGB F0=(1, 0.71, 0.29)。玻璃使用固定 IOR=1.5 的 Fresnel、全反射、辐亮度透射 η² 和俄罗斯轮盘 η 补偿。矩形灯使用 NEE、power heuristic MIS 和包含灯光选择概率的 PDF；点光源与聚光灯使用平方反比衰减，平行光无距离衰减，三者使用 delta 光源采样与阴影射线；其他发光几何靠路径命中贡献。

没有波长采样、RGB-to-spectrum、CIE/XYZ 转换、Sellmeier 或色散。没有时间降噪、专门焦散算法、嵌套介质和体积吸收；有限反弹深度会截断较长路径。glTF transmission 是薄表面透射，厚玻璃 volume/IOR 扩展尚未实现。

## 代码组织与资源管理

- `MetalPT/ContentView.swift` 和 `Views/`：控制面板、MetalKit 桥接、鼠标和模型加载。
- `Scene/`：稳定 ID 场景图、层级变换、网格局部材质槽、图片/纹理/采样器和 glTF 解析。
- `Renderer/Renderer.swift`：历史失效、帧调度、场景快照和提交；`PathTracingPasses.swift` 安排各个类型化 Pass。
- `Renderer/RenderGraph.swift`：依赖检查、拓扑排序、无用 Pass 剔除、RAW/WAR/WAW 屏障、生命周期和编译缓存。
- `FrameSlot.swift` / `FrameResources.swift`：三个帧槽、延迟分配、描述匹配资源池及 GPU 完成后的复用。
- `BindlessScene.swift` / `ResourceRegistry.swift`：场景根表、GPU 地址、纹理 ID、AS、间接资源登记和驻留。
- `Shaders/SurfaceParameters.h`：将材质工作流转换为不含纹理绑定的公共 BSDF 参数。
- `Shaders/`：采样、BSDF、求交、着色、阴影、队列、累积、显示和生产 GPU 验证。
- `Renderer/Shared.h`：CPU/GPU ABI，PTPath 和 PTScene 均为 80 字节。

相邻快照复用未变化的网格/BLAS；TLAS 重新 build。单队列、整资源依赖；尚无多队列、子资源跟踪、内存别名和 TLAS refit。详细契约见 [架构说明](docs/architecture.md)。

## 验证

```sh
xcodebuild -project MetalPT.xcodeproj -scheme MetalPT \
  -configuration Debug -derivedDataPath /tmp/MetalPT-build CODE_SIGNING_ALLOWED=NO build
scripts/test-graph.sh
scripts/test-gltf.sh
scripts/validate-gpu.sh validation
SPECTRAL_TRANSMISSION_VALIDATE=1 scripts/validate-gpu.sh validation
scripts/validate-gpu.sh capture
SPECTRAL_SPP=512 scripts/validate-gpu.sh release
```

为兼容现有脚本，环境变量仍使用 `SPECTRAL_` 前缀。`SPECTRAL_OUTPUT` 指定报告目录，`SPECTRAL_PROFILE=1` 开启逐 Pass GPU 时间戳。Capture 与 Shader Validation 分开运行。

CPU 覆盖图/ABI、场景层级、primitive、图片及 glTF。GPU 覆盖 RGB 通道保持、显示编码、Fresnel/TIR、GGX、黑场、PBR 能量/PDF、纹理/覆盖、透射、资源绑定、BLAS 复用和累积失效。材质重构记录见 [BSDF 验证](docs/validation/bsdf.md)，RGB 基线见 [RGB 验证](docs/validation/rgb.md)；其他历史光谱截图和性能不能作为 RGB 基线。

历史数据来源与许可保留在 `MetalPT/Resources/NOTICE.md`；当前程序不加载这些数据。
