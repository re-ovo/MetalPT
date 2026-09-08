# 渲染器架构与扩展边界

## 场景数据与 GPU 快照

`SceneGraph` 是 CPU 编辑层：Mesh、Material 与 Node 使用不同类型的 UUID，资产数组重排不会改变节点引用。节点具有父子关系、局部变换与可见性；父变换失效会传播到子树，编译时只重新计算失效的世界矩阵。重挂节点保留局部变换，拒绝环；删除节点同时删除子树。编译结果 `SceneDescription` 是扁平的渲染快照，用密集索引供 GPU 上传。

`SceneMesh` 使用独立 CPU 顶点/三角形结构，上传时转换为共享 ABI。三角形引用 Mesh 内部材质槽，节点将每个槽绑定到 MaterialID，GPU `PTInstance` 通过独立指针访问绑定表。同一个 Mesh/BLAS 可以具有不同的多材质组合；`PTInstance` 大小为 96 字节。`SceneMaterial.Surface` 支持漫反射、黄金、玻璃、吸收表面及 metallic-roughness；发光为附加属性。图片/纹理/采样器分离，支持五种纹理语义、UV0/1、顶点颜色、切线、法线贴图和透明覆盖。结构及使用方式见 [表面资产](surface-assets.md)。

纹理资源 ID 表按场景实际数量分配，材质引用超界时使用第零槽的白色纹理。NEE 均匀选择灯光，直接采样及发光表面命中的 MIS 都包含灯光选择概率；未登记为采样灯的发光几何仍通过路径命中贡献。采样灯必须对应独立矩形实例；两个三角形须沿任一对角线完整覆盖矩形，且使用与采样参数一致的规范 0–1 UV。重叠、缺面或自定义 UV 会被拒绝，以保证 NEE 与路径命中的发光求值一致。

`Renderer.sceneGraph` 接收编辑后的图；赋值后下次渲染编译新快照并重置累积。内置场景及验证用 `sceneOverride` 也经过同一编译路径；显式 sceneGraph 优先。新 `BindlessScene` 按 MeshID 和完整几何比较复用上一已提交快照的顶点、索引及 BLAS。仅实例变换或材质变化时不编码 BLAS 构建，只构建新的 TLAS；几何变化构建对应的新 BLAS。复用 AS 作为已初始化资源导入图，跨帧完成事件提供同步，旧快照仍由在途帧持有。

该复用只覆盖相邻快照；材质、纹理、光谱和实例表仍整表上传，TLAS 使用新分配的 build 而非 refit。几何比较为线性扫描，尚无内容版本、跨场景资产缓存、异步上传、模型加载、LOD或蒙皮。

## 资源登记与驻留

`ResourceRegistry.Handle` 包含登记表身份、槽位和代数，拒绝失效或跨表句柄。删除后可复用 CPU 槽位，旧快照继续持有原分配，因此不会改变在途帧使用的 GPU 地址。该句柄用于 CPU 管理；Shader 使用快照内的密集索引。

场景登记表中的每个 buffer、texture 和 AS 单独导入 Render Graph。Pass 声明包含间接访问的网格、BLAS、材质、纹理、光谱及灯光资源。最终驻留集直接取自编译后存活的图资源，无额外手工维护的驻留清单。帧槽保留快照和解析资源直至 GPU 完成；SamplerState 不属于 MTLAllocation，由快照单独持有。

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
- `SPECTRAL_PROFILE=1 scripts/validate-gpu.sh validation`：报告增加 `passGPUms`，在 GPU 完成后解析每个 Pass 的时间戳，按 Mach timebase 将支持的 Apple GPU 路径上的 heap ticks 换算为毫秒。时间戳会引入额外同步开销，因此普通性能比较应关闭此开关。

时间戳接口参考 Apple 的 [Metal 4 Counter Heap](https://developer.apple.com/documentation/metal/mtl4counterheap)。统计表示 Pass 前后 GPU 时间戳间隔，不应当作无测量开销的独占执行时间。

本机已直接对照 `MTL4CounterHeap`、`mach_absolute_time()` 与 `sampleTimestamps()`：前两者使用 Mach ticks，后者返回纳秒，不能把后者的 1:1 GPU/CPU 比例直接用于 heap 数值。
