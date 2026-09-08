# glTF / GLB 导入

将单个 `.glb` 或 `.gltf` 拖入视口，或点击「打开模型」。对于含外部 bin / 图片的 glTF，使用「打开模型文件夹」授予目录读取权限，再选择文件。加载完成后自动取景并添加查看灯光；失败保留当前场景，连续加载仅安装最新结果。「返回内置场景」恢复演示场景。

支持 glTF 2.0 静态三角形、三角带和三角扇，节点 matrix / TRS、共享网格、多材质、交错 / normalized / sparse accessor、UV0/1、顶点色、PNG/JPEG 和 metallic-roughness 材质。支持 `KHR_texture_transform`、`KHR_materials_emissive_strength`、`KHR_materials_transmission`。动画使用静态姿态；蒙皮、morph targets 和未知必需扩展会明确报错。未知可选扩展在界面提示。RGB 材质仍使用渲染器的近似光谱重建。

文件体积、顶点总量和三角形总量没有人为配额；保留数据范围、整数表示与 GPU 资源有效性检查。当前 CPU accessor 解码和主线程纹理准备尚未针对大模型优化。

## 验证

```sh
scripts/test-gltf.sh
SPECTRAL_GLTF=/absolute/path/model.glb SPECTRAL_SPP=32 scripts/validate-gpu.sh validation
SPECTRAL_GLTF=/absolute/path/model.glb SPECTRAL_SPP=32 scripts/validate-gpu.sh capture
```

CPU 测试生成 `/tmp/spectral-import-fixture.glb`，覆盖交错数据、normalized UV、sparse、内嵌 PNG、外部 buffer、共享实例及无效数据。GPU 入口使用实际异步加载和场景安装流程，验证旧请求丢弃、失败保留场景、批量 BLAS 构建及 TLAS 屏障。Capture 与 Shader Validation 分开运行。

## 多网格场景的 Capture 崩溃修复

`Rikimaru_Street.glb` 含 820 个网格。旧版每个 BLAS 各开一个 compute encoder；启用 Metal Capture 时可复现 `command buffer residency set limit of 32 exceeded`。应用虽然只显式绑定一个 residency set，Capture / 驱动路径仍会增加内部驻留状态。

独立 BLAS 现在在同一 pass、同一 encoder 内批量构建，各自保留独立 scratch 和 GPU 标记。Render Graph 声明全部输入、输出及 scratch，TLAS 仍是独立 pass，并在读取 BLAS 前执行依赖屏障。此修改没有限制网格数量。

本机 M4 验证：实际加载后为 822 个网格、3620 个实例。Debug Capture 32 spp 与独立 Shader Validation 4 spp 均通过，队列溢出和非有限值均为 0；结果见 `docs/validation/gltf-residency.json`。验证期间存在并发负载，GPU 时间不作为性能基准。

## 薄表面透射

`KHR_materials_transmission` 支持 factor（默认 0）乘以 transmissionTexture 的线性 R 通道，复用 UV0/1、采样器和纹理变换。透射替代非金属的漫反射分量，保留菲涅耳反射，并由 baseColor 着色；metallic=1 时不透射。Alpha 继续表示表面覆盖率，OPAQUE 材质也可以透光。

光滑表面使用离散反射 / 直透采样；粗糙表面使用 GGX 薄表面透射分布，采样与求值使用匹配的双半球 PDF。直接光照支持表面两侧，delta 路径正确跳过有限 PDF 的 MIS。此模型没有宏观折射、体积吸收或色散，不复用 BK7 Sellmeier 材质；厚玻璃需要后续的 volume / IOR 等支持。

实现依据：[KHR_materials_transmission 规范](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_materials_transmission)。

透射专项验证：

```sh
SPECTRAL_TRANSMISSION_VALIDATE=1 SPECTRAL_WIDTH=320 SPECTRAL_HEIGHT=240 scripts/validate-gpu.sh validation
```

本机 M4 的 API / Shader Validation 已通过纹理 R 通道、光滑能量、着色、金属不透射、粗糙采样 PDF，以及 opaque / partial / clear / rough 四组 128 spp 对照图。数值记录见 `docs/validation/transmission.json`。用户新版 GLASS.glb 已通过 64 spp 导入渲染验证。
