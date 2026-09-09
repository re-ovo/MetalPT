# 渲染器架构与扩展边界

当前积分与累积均使用线性 RGB；玻璃 IOR 固定为 1.5，黄金使用近似 RGB F0=(1, 0.71, 0.29)。当前程序不加载光谱表。PTPath 删除波长及波长 PDF 后为 80 字节，PTScene 删除 CIE/Au 指针后为 80 字节。

## 场景数据与 GPU 快照

`SceneGraph` 是 CPU 编辑层：Mesh、Material 与 Node 使用不同类型的 UUID，资产数组重排不会改变节点引用。节点具有父子关系、局部变换与可见性；父变换失效会传播到子树，编译时只重新计算失效的世界矩阵。重挂节点保留局部变换，拒绝环；删除节点同时删除子树。编译结果 `SceneDescription` 是扁平的渲染快照，用密集索引供 GPU 上传。

`SceneMesh` 使用独立 CPU 顶点/三角形结构，上传时转换为共享 ABI。三角形引用 Mesh 内部材质槽，节点将每个槽绑定到 MaterialID，GPU `PTInstance` 通过独立指针访问绑定表。同一个 Mesh/BLAS 可以具有不同的多材质组合；`PTInstance` 大小为 96 字节。`SceneMaterial.Surface` 支持漫反射、黄金、玻璃、吸收表面及 metallic-roughness；发光为附加属性。图片/纹理/采样器分离，支持七种纹理语义、UV0/1、顶点颜色、切线、法线贴图和透明覆盖。结构及使用方式见 [表面资产](surface-assets.md)。

纹理资源 ID 表按场景实际数量分配，材质引用超界时使用第零槽的白色纹理。NEE 均匀选择灯光，直接采样及发光表面命中的 MIS 都包含灯光选择概率；未登记为采样灯的发光几何仍通过路径命中贡献。矩形采样灯必须对应独立矩形实例；两个三角形须沿任一对角线完整覆盖矩形，且使用与采样参数一致的规范 0–1 UV。重叠、缺面或自定义 UV 会被拒绝，以保证 NEE 与路径命中的发光求值一致。

`Renderer.sceneGraph` 接收编辑后的图；赋值后下次渲染编译新快照并重置累积。内置场景及验证用 `sceneOverride` 也经过同一编译路径；显式 sceneGraph 优先。新 `BindlessScene` 按 MeshID 和完整几何比较复用上一已提交快照的顶点、索引及 BLAS。仅实例变换或材质变化时不编码 BLAS 构建，只构建新的 TLAS；几何变化构建对应的新 BLAS。复用 AS 作为已初始化资源导入图，跨帧完成事件提供同步，旧快照仍由在途帧持有。

该复用只覆盖相邻快照；材质、纹理和实例表仍整表上传，TLAS 使用新分配的 build 而非 refit。几何比较为线性扫描，尚无内容版本、跨场景资产缓存、后台网格上传、LOD 或蒙皮。glTF 图片纹理准备在导入工作线程执行，GPU blit 生成 mip 并完成后再安装场景。

## 材质工作流与 BSDF

CPU `SceneMaterial.Surface` 保留 Metallic-Roughness 和 Specular-Glossiness 两种工作流。`PTMaterial` 为 432 字节，新增独立的 RGB specular / glossiness 因子和纹理绑定；其余路径、场景 ABI 大小不变。

`MaterialTextures.h` 在交点读取纹理、颜色与透明覆盖；`SurfaceParameters.h` 的 `prepareBSDF` 将工作流转换为不带 GPU 指针或纹理绑定的公共参数：散射类型、漫反射颜色、F0、GGX alpha、透射颜色及分量采样概率。MR、SG 与黄金共享 microfacet 类型，保留各自能量约定与原有 MR 行为。

`BSDF.h` 的 `evaluateBSDF` 同时返回有限立体角 BSDF 与完整混合 PDF；`sampleSurfaceBSDF` 返回方向、已经包含 `f * abs(cos) / pdf` 的权重、PDF、delta / transmitted 标记和 etaI/etaT。理想玻璃通过同一接口返回离散反射/折射事件；透射权重包含辐亮度 eta²，积分器用返回的 eta 补偿俄罗斯轮盘。理想玻璃使用几何法线和固定 IOR 1.5；薄表面直透的 eta 为 1。

`MaterialShading.metal` 只负责发光命中、直接光采样/MIS、应用 BSDF 样本和路径队列，不再自行实现玻璃 Fresnel 或折射采样。当前分派为内联类型分支，未引入按材质分队列或动态函数表。SG 的非 delta GGX 仍使用粗糙度数值下限；多层涂层和通用 BSDF 混合图尚未实现。

路径追踪与玻璃 BSDF 为独立实现，参考 [PBRT 波前路径追踪](https://www.pbr-book.org/4ed/Wavefront_Rendering_on_GPUs/Path_Tracer_Implementation)和[电介质 BSDF](https://pbr-book.org/4ed/Reflection_Models/Dielectric_BSDF)；未复制 PBRT 代码或 RGB 光谱查找表。历史光谱数据来源与许可可从 Git 历史查阅。

## 相机与显示处理

薄透镜相机均匀采样圆形光圈，焦距参数表示沿相机前向轴测量的对焦距离，单位为场景单位。光圈响应经过归一化，调整光圈不会自动改变曝光；默认有效光圈半径为零，保持针孔采样。相机参数变化重置累积。

显示处理作用于累积的线性 sRGB，顺序为曝光 → Bradford 白点适应 → 非负 RGB → 所选色调映射 → sRGB 编码。白平衡采用 4000–25000 K 的近似日光轨迹，以同一轨迹的 6504 K 为基准归一化；色调偏移修改源白点的色度 y。默认 6504 K、零色调偏移严格保持颜色不变。这是艺术化的光照颜色校正，不是经过标定的相机配置。

色调映射提供 ACES 风格有理函数、带中性轴 SDR 色域压缩的亮度 Reinhard，以及线性裁剪。ACES 风格曲线参考 K. Narkowicz 的 [ACES Filmic Tone Mapping Curve](https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/)。输出为 SDR sRGB，不构成完整 ACES、ICC/OCIO 或 HDR 管线；显示参数变化保留线性累积。

## 资源登记与驻留

`ResourceRegistry.Handle` 包含登记表身份、槽位和代数，拒绝失效或跨表句柄。删除后可复用 CPU 槽位，旧快照继续持有原分配，因此不会改变在途帧使用的 GPU 地址。该句柄用于 CPU 管理；Shader 使用快照内的密集索引。

场景登记表中的每个 buffer、texture 和 AS 单独导入 Render Graph。Pass 声明包含间接访问的网格、BLAS、材质、纹理及灯光资源。最终驻留集直接取自编译后存活的图资源，无额外手工维护的驻留清单。帧槽保留快照和解析资源直至 GPU 完成；SamplerState 不属于 MTLAllocation，由快照单独持有。

## Pass 与 Render Graph

每个 Pass 的 `Resources` 转成 `WorkBindings` / `SceneBindings`；同一份描述同时生成依赖与实际 GPU 指针。`ComputeBindings` 为每个 Pass 分配独立的工作根和 argument table，并从受限解析器读取资源；不存在固定的 A/B 绑定表。显式绑定缺失或类型错误会抛错，不再静默写入空指针。间接 dispatch 参数及输出纹理的访问由编码助手自动声明。

图资源句柄包含图身份，编译结果和解析资源包含图身份与版本；跨图使用和修改图后使用旧计划会被拒绝。

图先声明资源与 Pass，再编译、裁剪、分配；编码时填充各 Pass 的独立绑定，随后一次性提交。瞬态 buffer 和 texture 仅在存活时分配。显示先写图创建的中间纹理，Present Pass 再复制到 drawable；暂停帧只保留显示所需资源。

编译缓存保存拓扑、依赖、barrier 和生命周期，不保存闭包或 GPU 分配。缓存键包含初始化状态、访问类型、阶段和显式边；尺寸变化可重用计划但重新解析资源，拓扑变化重新编译。缓存采用有界 LRU，仅保存局部资源索引；命中后重建当前图句柄，并且命中前仍校验输入句柄归属。

每帧槽有独立资源池，使用稳定的 `TransientPool.Key` 标识资源，显示名称不参与身份判定；同帧重复租用同一个键会报错。图分配阶段还会检查不同逻辑资源是否意外使用同一分配。buffer 按容量增长并复用，texture 按描述匹配；未使用缓存清除，超过 256 MiB 缓存预算时放弃缓存所有权，在途帧仍持有分配。预算限制缓存，并非限制渲染所需内存。

依旧采用单队列、整资源级依赖和阶段级 barrier。尚未实现子资源跟踪、内存别名、多队列调度或编译期反射 Shader 访问；开发者仍须维护正确的间接资源声明。

## 验证与性能观察

- `scripts/test-graph.sh`：依赖、RAW/WAR/WAW、非法读取、环、延迟分配裁剪、缓存失效、跨图句柄、过期计划及共享 ABI；`SurfaceAssetTests` 检查 primitive、图片解码、颜色空间 mip 和绑定契约；场景层还覆盖父子变换、脏子树、可见性、重挂、稳定资产引用和材质槽。
- `scripts/validate-gpu.sh validation`：生产 GPU 路径，以及共享 BLAS 实例、变换与烘焙几何对照、多材质槽、父节点移动、空可见场景、BLAS 复用/失效、第三个纹理槽、默认纹理、多灯和暂停资源裁剪；另验证同一命令缓冲内两个累积/显示 Pass 的不同输入输出、池租用规则和面积灯契约。
- `METALPT_PROFILE=1 scripts/validate-gpu.sh validation`：报告增加 `passGPUms`，在 GPU 完成后解析每个 Pass 的时间戳，按 Mach timebase 将支持的 Apple GPU 路径上的 heap ticks 换算为毫秒。时间戳会引入额外同步开销，因此普通性能比较应关闭此开关。

时间戳接口参考 Apple 的 [Metal 4 Counter Heap](https://developer.apple.com/documentation/metal/mtl4counterheap)。统计表示 Pass 前后 GPU 时间戳间隔，不应当作无测量开销的独占执行时间。

本机已直接对照 `MTL4CounterHeap`、`mach_absolute_time()` 与 `sampleTimestamps()`：前两者使用 Mach ticks，后者返回纳秒，不能把后者的 1:1 GPU/CPU 比例直接用于 heap 数值。

## 解析灯光与交互编辑

点光源、聚光灯和平行光存于 `SceneDescription.punctualLights`，上传时接在矩形灯之后，矩形灯的实例索引映射不变。`PTLight` 保持 80 字节，`indices.z` 标记类型；解析灯光复用其余字段保存世界位置、线性 RGB 强度、照射方向、锥角余弦及范围。字段语义见 `Shared.h`。

所有灯光共同参与均匀选择；矩形灯使用立体角 PDF 与 MIS，delta 光源使用离散选择概率和 MIS 权重 1。点/聚光的强度单位为 cd，平行光为 lux；输出采用现有曝光与色调映射。距离衰减、范围平滑截断和聚光过渡依据 [Khronos KHR_lights_punctual](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_lights_punctual) 的定义。三种解析灯光均产生硬阴影；发光点本身不作为可见几何或镜面命中目标。

编辑只创建新灯光表和场景根表，复用所有几何、纹理及加速结构。新的资源句柄替换对应 pass 依赖，其余句柄保持不变。旧帧持有旧快照直至 GPU 完成，避免 CPU 写入正在使用的缓冲；编辑触发累积失效。当前灯光编辑只保存在内存中，切换或重新导入场景会重置，尚无保存/导出功能。

## GGX VNDF 采样

MR、SG 与黄金的有限粗糙度分量使用各向同性 GGX 可见法线采样，采用伸缩出射方向、可见半球投影圆盘采样、逆伸缩法线的构造。方法依据 [PBRT 的可见法线采样说明](https://www.pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory#SamplingtheDistributionofVisibleNormals)。粗糙度映射、Fresnel 和现有可分离 Smith 遮蔽模型保持不变。

半向量密度为 `p(h|wo) = D(h) G1(wo) max(wo·h, 0) / (n·wo)`；反射方向 PDF 经雅可比约简为 `D(h) G1(wo) / (4 n·wo)`。实现使用等价的稳定表达式避免掠射角除法。混合分量概率继续进入最终 PDF；薄表面透射沿用折叠反射方向的单位雅可比，与反射共同使用 VNDF。下半球的无效反射作为零贡献事件，不重复采样，也不重新归一化 PDF。理想玻璃和光滑透射的 delta 分支不变。

GGX D 分母写成 `(1 − nh²) + nh² alpha²`，避免低粗糙度、法线附近的减法精度损失。没有加入能量限幅或降噪。数值、方差与图像验证见 [VNDF 验证](validation/vndf.md)。

## 空间降噪

显示前可选执行首交点引导缓冲生成和三轮步长为 1、2、4 的 5×5 à-trous 联合双边滤波。零光圈时，引导缓冲使用无抖动的像素中心射线，分别记录着色法线与几何法线，以及相机空间深度、线性反照率和保护标记。几何法线用于切平面距离及景深分支的共面性判断，着色法线只用于法线相似度。滤波权重由空间核、法线差、双向切平面距离、反照率差和 HDR 亮度差共同决定。反照率只参与权重，不对颜色进行解调。

滤波处理线性 HDR 累积结果，输出到两个独立 ping-pong 缓冲，再交给原来的曝光、色调映射与 sRGB 编码。持久累积始终不被滤波覆盖，开关/强度变化不重置采样；没有使用上一帧的滤波结果。镜面玻璃、低粗糙度镜面、透射、非 OPAQUE 覆盖和发光表面保守保留原始颜色。

所有引导、输入和输出读写均通过 typed pass 声明；关闭时不创建引导/滤波资源、不执行额外 pass。开启时每个内部渲染像素增加五个 float4 缓冲（80 字节，另有池容量取整），每帧增加一轮引导生成和三轮空间滤波，包括暂停显示帧；零光圈每像素使用一条引导射线，非零光圈使用 16 条。资源按帧槽保留到 GPU 完成，沿用现有驻留机制。

`PTWork` 由 64 增至 104 字节；五个新增指针对应 normalDepth、albedoGuide、filterInput、filterOutput、geometricNormal。256 字节的 pass 绑定槽中，临时 PTScene 从偏移 64 移至 128，避免与新增字段重叠。Swift/C ABI 断言和资源绑定 GPU 回归同步更新。结果见 [空间降噪验证](validation/spatial-denoise.md)。

该滤波会平滑小于滤波尺度的照明细节，不是神经网络降噪器或 SVGF；首表面引导无法描述反射/透射后的结构。保护区域仍可能有明显噪点，像素中心引导与累积的抗锯齿覆盖也并非完全一致。

引导射线使用独立的确定性覆盖模式：非零覆盖的 BLEND 前景始终命中并标记保护；零覆盖及 MASK 裁掉的区域继续穿透。路径追踪的随机覆盖策略不变。

非零光圈时，引导生成使用 16 个固定、成对的光圈样本，以反照率、法线、深度的均值及深度离散程度引导失焦漫反射区域的滤波，避免从混合深度重建单一针孔平面。任一样本未命中，或命中发光、透明覆盖、透射及近镜面表面，都会保守保护该像素。这是有限样本的空间近似，会增加引导射线开销，不使用时间累积或学习模型。
