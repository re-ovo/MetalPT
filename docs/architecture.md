# 渲染器架构与扩展边界

## 场景数据与 GPU 快照

`SceneDescription` 分离网格、实例、材质、程序化纹理和矩形面积灯。多个实例可共享网格 BLAS，实例支持可逆仿射变换和材质覆盖。`BindlessScene` 将描述上传为不可变 GPU 快照，TLAS 实例 ID 用于读取网格及变换表。

纹理资源 ID 表按场景实际数量分配，材质引用超界时使用第零槽的白色纹理。NEE 均匀选择灯光，直接采样及发光表面命中的 MIS 都包含灯光选择概率；未登记为采样灯的发光几何仍通过路径命中贡献。采样灯必须对应独立矩形实例，材质、几何与采样参数需一致。

当前更新以替换场景快照实现；尚未实现跨快照网格缓存、BLAS refit、异步上传或模型加载。

## 资源登记与驻留

`ResourceRegistry.Handle` 包含登记表身份、槽位和代数，拒绝失效或跨表句柄。删除后可复用 CPU 槽位，旧快照继续持有原分配，因此不会改变在途帧使用的 GPU 地址。该句柄用于 CPU 管理；Shader 使用快照内的密集索引。

场景登记表中的每个 buffer、texture 和 AS 单独导入 Render Graph。Pass 声明包含间接访问的网格、BLAS、材质、纹理、光谱及灯光资源。最终驻留集直接取自编译后存活的图资源，无额外手工维护的驻留清单。帧槽保留快照和解析资源直至 GPU 完成。

## Pass 与 Render Graph

每个 Pass 的 `Resources` 结构说明其输入输出；`ComputePass` 仅提供编码和绑定服务，不提供整个场景或帧的访问入口。间接参数读取由编码助手自动声明。执行时的资源解析器只允许访问当前 Pass 已声明的资源。

图先声明资源与 Pass，再编译、裁剪、分配、填充绑定并执行。瞬态 buffer 和 texture 仅在存活时分配。显示先写图创建的中间纹理，Present Pass 再复制到 drawable；暂停帧只保留显示所需资源。

编译缓存保存拓扑、依赖、barrier 和生命周期，不保存闭包或 GPU 分配。缓存键包含初始化状态、访问类型、阶段和显式边；尺寸变化可重用计划但重新解析资源，拓扑变化重新编译。缓存采用有界 LRU。

每帧槽有独立资源池：buffer 按容量增长并复用，texture 按描述匹配；未使用缓存清除，超过 256 MiB 缓存预算时放弃缓存所有权，在途帧仍持有分配。预算限制缓存，并非限制渲染所需内存。

依旧采用单队列、整资源级依赖和阶段级 barrier。尚未实现子资源跟踪、内存别名、多队列调度或编译期反射 Shader 访问；开发者仍须维护正确的间接资源声明。

## 验证与性能观察

- `scripts/test-graph.sh`：依赖、RAW/WAR/WAW、非法读取、环、延迟分配裁剪、缓存失效及共享 ABI。
- `scripts/validate-gpu.sh validation`：生产 GPU 路径，以及共享 BLAS 实例、变换与烘焙几何对照、材质覆盖、第三个纹理槽、默认纹理、多灯和暂停资源裁剪。
- `SPECTRAL_PROFILE=1 scripts/validate-gpu.sh validation`：报告增加 `passGPUms`，在 GPU 完成后解析每个 Pass 的时间戳，按 Mach timebase 将支持的 Apple GPU 路径上的 heap ticks 换算为毫秒。时间戳会引入额外同步开销，因此普通性能比较应关闭此开关。

时间戳接口参考 Apple 的 [Metal 4 Counter Heap](https://developer.apple.com/documentation/metal/mtl4counterheap)。统计表示 Pass 前后 GPU 时间戳间隔，不应当作无测量开销的独占执行时间。

本机已直接对照 `MTL4CounterHeap`、`mach_absolute_time()` 与 `sampleTimestamps()`：前两者使用 Mach ticks，后者返回纳秒，不能把后者的 1:1 GPU/CPU 比例直接用于 heap 数值。
