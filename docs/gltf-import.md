# glTF / GLB 导入

将单个 `.glb` 或 `.gltf` 拖入视口，或点击「打开模型」。对于含外部 bin / 图片的 glTF，使用「打开模型文件夹」授予目录读取权限，再选择文件。加载完成后自动取景并添加查看灯光；失败保留当前场景，连续加载仅安装最新结果，旧请求会在图片、网格与纹理准备检查点取消。「返回内置场景」恢复演示场景。

支持 glTF 2.0 静态三角形、三角带和三角扇，节点 matrix / TRS、共享网格、多材质、交错 / normalized / sparse accessor、UV0/1、顶点色、PNG/JPEG 和 metallic-roughness 材质。支持 `KHR_materials_pbrSpecularGlossiness`、`KHR_texture_transform`、`KHR_materials_emissive_strength`、`KHR_materials_transmission`。动画使用静态姿态；蒙皮、morph targets 和未知必需扩展会明确报错。未知可选扩展在界面提示。材质颜色直接在线性 RGB 中参与积分。

文件体积、顶点总量和三角形总量没有人为配额；保留数据范围、整数表示与 GPU 资源有效性检查。Accessor 在验证范围后批量读取原始字节；共享网格的槽位/UV 校验与局部包围盒只计算一次，再用于实例。纹理在导入工作线程准备，mip 由 GPU 生成，完成后才安装场景。图片解码仍是串行 CPU 工作，几何上传与快照安装仍在主线程。

本文以下本机 M4 结果为 RGB 重构前的历史验证；当前记录见 [RGB 验证](validation/rgb.md)。

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

光滑表面使用离散反射 / 直透采样；粗糙表面使用 GGX 薄表面透射分布，采样与求值使用匹配的双半球 PDF。直接光照支持表面两侧，delta 路径正确跳过有限 PDF 的 MIS。此模型没有宏观折射、体积吸收或色散，与固定 IOR=1.5 的封闭玻璃材质独立；厚玻璃需要后续的 volume / IOR 等支持。

实现依据：[KHR_materials_transmission 规范](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_materials_transmission)。

透射专项验证：

```sh
SPECTRAL_TRANSMISSION_VALIDATE=1 SPECTRAL_WIDTH=320 SPECTRAL_HEIGHT=240 scripts/validate-gpu.sh validation
```

本机 M4 的 API / Shader Validation 已通过纹理 R 通道、光滑能量、着色、金属不透射、粗糙采样 PDF，以及 opaque / partial / clear / rough 四组 128 spp 对照图。数值记录见 `docs/validation/transmission.json`。用户新版 GLASS.glb 已通过 64 spp 导入渲染验证。

## Specular-Glossiness 材质

支持 `KHR_materials_pbrSpecularGlossiness` 的 diffuseFactor、specularFactor、glossinessFactor、diffuseTexture 和 specularGlossinessTexture；同时存在 Metallic-Roughness 回退时优先使用 SG。SG 纹理支持同一套 UV、采样器和 KHR_texture_transform。

diffuseTexture 的 RGB 经 sRGB 解码并乘顶点颜色，alpha 用于 OPAQUE/MASK/BLEND；specularGlossinessTexture 的 RGB 经 sRGB 解码作为独立 F0，alpha 保持线性并乘 glossinessFactor。两种纹理的 alpha 不混用。交点参数使用 `c_diff = diffuse.rgb * (1 - max(F0))`、`alpha = (1 - glossiness)^2`，GGX 保留数值下限，与 MR 共享 BSDF 求值和混合 PDF。SG 当前不叠加 transmission 扩展。

本地 Bistro 的 254 个材质中，234 个使用 SG、19 个使用 MR（其中 18 个附加 transmission）。本次补齐其 SG 材质导入与着色路径；`KHR_lights_punctual` 方向光仍未实现，不能据此认为原场景光照已完整还原。`MSFT_texture_dds` 仍被忽略，该文件的全部纹理同时提供标准 PNG source。

依据：[KHR_materials_pbrSpecularGlossiness](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Archived/KHR_materials_pbrSpecularGlossiness)。

## 加载性能诊断

设置 `SPECTRAL_IMPORT_PROFILE=1` 会输出队列等待、容器读取、解析/编译、自动取景、纹理准备、主线程安装与总耗时（毫秒）；glTF GPU 验证报告包含同样的 `importTimingsMs`。总耗时到场景安装完成为止，不包含首帧 BLAS/TLAS 构建。

纹理仅为实际使用的颜色空间创建 mip 链，未使用的表项指向白色回退。颜色/数据同时使用时保留两套独立 mip；不再无条件为每张图片分配两套。后台上传使用独立 Metal blit 队列，并等待完成后将纹理登记为已初始化的场景资源。1×1 纹理跳过 mip 生成。

本机 Rikki 与纹理负载的测量及边界见 [导入性能验证](validation/import-performance.md)。

## 无效导出切线的容错

对 TANGENT 中的 NaN/Inf、零方向或不合法手性（w 不为 ±1），导入器仅取消该顶点的切线属性并保留有限默认值。受影响的三角形通过已有 UV 导数路径建立切线空间；退化 UV 无法形成切线时保留基础着色法线。有效切线继续使用导出值。界面显示修复数量。

位置、法线、UV 等其他 accessor 仍严格拒绝 NaN/Inf；错误现在包含 accessor 编号、记录与分量，方便定位源数据。本地 Bistro 原始字节中有 12 个切线 accessor 的 847 条记录含 NaN，加上零方向等无效值，共 13552 条切线需要回退。

完整 Bistro 已通过此次切线容错后的导入与 GPU 验证，详见 [Bistro 切线验证](validation/bistro-tangents.md)。
