# SpectralPT

原生 macOS 光谱路径追踪演示器。使用 SwiftUI、Metal 4 和 MSL，运行时不联网、不加载外部模型。

## 运行

需要 macOS 26.5+、M3 或更新 Apple Silicon，以及带 Metal Toolchain 的 Xcode 26。打开 `SpectralPT.xcodeproj`，选择 **SpectralPT / My Mac** 运行。如果 Xcode 提示缺少 Metal 编译器，执行 `xcodebuild -downloadComponent MetalToolchain`。

- 拖动旋转，Shift / 右键拖动平移，滚轮缩放。
- 场景：Cornell 光谱材质、BK7 棱镜与发光条纹背景。
- 默认 50% drawable 分辨率、每帧 1 spp、最多 8 次表面交互。Retina 下以 drawable 像素为准。
- 相机、场景、分辨率、反弹深度和色散设置变化会重置累积。曝光只改变显示；暂停保持现有采样。
- 玻璃在低采样时会有明显彩色噪声，需保持相机静止渐进收敛。此版本无去噪和专门焦散算法。

## 代码组织

- `Views/MetalViewport.swift`：SwiftUI / MetalKit 桥接和鼠标事件；控制面板保留在 `ContentView.swift`。
- `Renderer/RenderModel.swift`、`OrbitCamera.swift`：界面状态和相机数学。
- `Renderer/Renderer.swift`：历史失效、帧调度和提交；`FrameSlot.swift`、`FrameResources.swift`：帧生命周期、资源池和参数绑定。
- `Renderer/PathTracingPasses.swift`：执行顺序；`Renderer/Passes/`：各 pass 的资源访问声明与编码，公共 context 提供资源导入和 dispatch；`RenderGraph.swift`：通用图编译与同步。
- `Scene/`：`SceneMesh` 生成几何，`ProceduralScene` 描述内置场景，`SpectralData` 读取光谱数据。`Renderer/BindlessScene.swift` 负责 GPU 上传与加速结构配置。
- `Shaders/`：`Sampling.h`、`Spectrum.h`、`BSDF.h` 提供可复用数学；路径追踪按相机生成、求交、着色、阴影、队列管理和累积分文件；`Display.metal` 与 `Validation.metal` 实现显示和数值验证。

| Swift Pass 文件 | Shader 文件 / 职责 |
| --- | --- |
| `CameraPathPass.swift` | `CameraPath.metal`：生成相机路径、清理帧状态 |
| `PathIntersectionPass.swift` | `PathIntersection.metal`：硬件求交 |
| `MaterialShadingPass.swift` | `MaterialShading.metal`：材质采样、NEE、后续路径 |
| `ShadowTracePass.swift` | `ShadowTrace.metal`：阴影求交与贡献合并 |
| `QueueManagementPasses.swift` | `QueueManagement.metal`：反弹准备、阴影间接参数、队列推进 |
| `AccumulationPass.swift` | `Accumulation.metal`：XYZ 渐进累积 |
| `DisplayPass.swift` | `Display.metal`：曝光、色调映射和显示 |
| `AccelerationStructurePasses.swift` | Metal 加速结构构建命令：BLAS / TLAS |

新增 pass 时在 `Renderer/Passes/` 定义访问声明与编码，在 `PathTracingPasses` 安排执行顺序，并维护对应着色器入口及 `MetalContext` 的 pipeline 注册。编码闭包只捕获所需资源，避免捕获包含 graph 的整个 context 而形成引用环。共享 MSL 函数放入带包含保护的头文件并声明为 `inline`；kernel 只在一个 `.metal` 编译单元定义。CPU/GPU 数据布局继续统一维护在 `Renderer/Shared.h`。

以上路径均相对于 `SpectralPT/`。本轮仅拆分职责，保持 kernel 名称、共享 ABI、pass 顺序和采样算法不变。

## 实现

`MetalContext` 创建 Metal 4 queue、compiler 和 compute pipelines。三个帧槽各自拥有 command allocator、command buffer、参数和临时资源池；完成事件与反馈回调共同保护 CPU 复用。场景或分辨率变化时，旧资源由尚未完成的帧保留。共享 XYZ 累积通过单队列事件顺序同步。

`RenderGraph` 以资源读写及 GPU stage 声明依赖，编译时检查未初始化读取和环，执行拓扑排序、无用 pass 剔除及生命周期分析，并自动发出 RAW/WAR/WAW barrier。图提供缓冲创建及 buffer/texture/AS 导入接口，瞬态缓冲从已完成帧槽的描述匹配池复用。首版不做内存别名和多队列调度；各阶段目前单独编码，优先保证可检查性。

```text
初次场景：Build BLAS → Build TLAS
每个样本：Initialize
          ┌ PrepareBounce → Intersect → Shade
          │                      ↓
          └ FinishBounce ← TraceShadows ← PrepareShadow
          Accumulate XYZ → Tone map → sRGB display
```

- **GPU driven**：GPU 原子计数器压紧路径与阴影队列，GPU 写入间接线程组参数。每跳通过 indirect dispatch 工作，不回读路径数到 CPU 控制调度。CPU 编码固定最大反弹次数；空队列调度一组并立即退出。
- **Bindless**：共享头文件定义的场景根表持有 buffer GPU 地址、纹理 resource ID 和 TLAS handle。MSL 动态索引三角形、材质及纹理，Metal 4 argument table 只绑定入口。所有间接引用由 residency set 覆盖。
- **硬件光追**：程序化三角形 BLAS + TLAS 实例，MSL triangle/instancing intersector 求交。场景静态，相机操作不重建 AS。
- **光谱**：360–830 nm 范围内相关分层采样 4 个波长。路径保存波长 PDF，初始为 1/470；XYZ 转换显式包含逆 PDF 与四样本平均。波长相关玻璃仅保留主波长，其 PDF 除以 4、次要波长 PDF 置零，以补偿其余通道的终止。
- **材质**：有界光谱漫反射、GGX 金属（实测金 n/k）、BK7 Sellmeier 玻璃与理想介电质 Fresnel。包含全反射、辐亮度透射 η² 和用于俄罗斯轮盘的 η 补偿。
- **积分**：天花板矩形灯 NEE、power heuristic MIS、光源命中权重、俄罗斯轮盘、尺度相关起点偏移。发光背景通过 BSDF 采样命中，不参与灯光 NEE，因而其命中权重为 1。
- **显示**：FP32 XYZ 运行平均 → 线性 sRGB → 曝光与 ACES 风格曲线 → 一次 sRGB 编码，输出非 sRGB BGRA8 drawable。

球体使用三角网格几何法线；玻璃为独立封闭边界，不支持嵌套介质或吸收。漫反射参数是光谱基底系数，尚未实现精确 RGB-to-spectrum。有限反弹深度会截断较长路径。

## 验证

```sh
scripts/test-graph.sh
scripts/validate-gpu.sh validation
scripts/validate-gpu.sh capture
SPECTRAL_SPP=512 scripts/validate-gpu.sh release
```

验证入口运行真实渲染管线，输出 PNG、JSON 指标和图结构后退出。支持 `SPECTRAL_OUTPUT` 指定目录；GPU Capture 与 Shader Validation 必须分别运行。`SPECTRAL_DUMP_GRAPH=1` 在首次提交时打印图信息。

测试覆盖图剔除、RAW/WAR/WAW、生命周期、未初始化读取、环、AS 阶段转换、CPU/GPU ABI、CIE 积分、漫反射光谱、金属 Fresnel、GGX 归一化、玻璃全反射、主波长权重、黑场、色散差异、暂停/曝光、连续缩放与场景切换。

数据来源及许可见 `SpectralPT/Resources/NOTICE.md`。本机验证结果与渲染图见 `docs/validation/`。
