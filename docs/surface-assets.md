# 表面资产

当前实现覆盖静态三角形 primitive、着色法线、图片纹理、采样器和 metallic-roughness / specular-glossiness 着色。glTF 文件解析见 [导入说明](gltf-import.md)。

## Mesh 与顶点

`SceneMesh.appendPrimitive(vertices:indices:materialSlot:)` 保留 primitive 内共享顶点；`primitives` 暴露索引范围和局部材质槽，并保留相邻同材质 primitive 的显式边界。GPU 仍使用平坦三角形表和共享 BLAS。

CPU Vertex 包含 position、normal、tangent（w 为手性）、color 和两套 UV；`uv.xy/zw` 分别为 UV0/UV1。attributes 位 1/2/4/8/16 分别声明 normal/tangent/UV0/UV1/color。缺少 normal 使用几何法线，缺少 tangent 从对应 UV 的三角形导数构造切线空间；缺失颜色默认白色。材质引用不存在的 UV 集会报错。暂不支持 UV2+、点线拓扑、蒙皮和 morph。

## 图片与绑定

`SceneImage` 接收 RGBA8 或 ImageIO 可解码的 PNG/JPEG 数据，通过 vImage 直接转换为非预乘 RGBA8，保留零 alpha 和低 alpha 像素的 RGB（alpha 也可能表示光泽度）以及图片行序。`SceneTexture` 引用稳定 ImageID；图片纹理按材质实际使用的语义上传线性或 sRGB 版本，兼用时保留两套独立 mip；未使用的纹理表项指向白色回退。生产路径通过 GPU blit 生成 mip，导入时在后台等待上传完成。颜色 mip 在解码后的线性空间平均，再编码存储；数据和 alpha 不做 sRGB 变换。CPU `mipLevels` 保留为测试参考，生产 mip 使用 Metal 滤波，非二次幂尺寸的低级 mip 不保证与 CPU 区域平均逐字节相同。

`TextureBinding` 持有稳定 TextureID、可选 SamplerID、texCoord、offset、scale、rotation 和显式 lod。上传时解析成密集 GPU 索引。缺省 sampler 使用场景第零槽；失效纹理使用白色槽，显式无效 sampler 报错。SceneSampler 支持 min/mag 最近点和线性、mip 最近点和线性、repeat/clamp/mirror。

```swift
let image = try SceneImage(encoded: imageData)
let texture = SceneTexture(source: .image(image.id))
let sampler = SceneSampler()
graph.images.append(image)
graph.textures.append(texture)
graph.samplers.append(sampler)
let binding = TextureBinding(texture: texture.id, sampler: sampler.id, texCoord: 0)
let material = SceneMaterial(
    surface: .metallicRoughness(baseColor: [1, 1, 1, 1], metallic: 0.3, roughness: 0.5),
    baseColorTexture: binding)
graph.materials.append(material)
```

Sampler GPU ID 表由场景根访问，SamplerState 随场景快照保留；buffer/texture/AS 继续通过 Render Graph 声明和 residency set 管理。主路径和阴影求交现在也声明材质、纹理与采样器表读取。

## 着色与透明覆盖

几何法线负责朝向、偏移和玻璃介质边界；插值法线经逆转置变换用于非 delta BSDF。负缩放修正几何朝向和切线手性，矩形灯法线采用同一约定。法线贴图使用线性 RGB，XY 乘 normalScale；UV 变换或非 UV0 贴图使用对应 UV 导数建立切线空间。折射仍使用几何法线，避免改变封闭介质边界。

PBR 使用 Lambert + GGX/Smith/Schlick：metallic 混合介电质 F0=0.04 与基色反射率，roughness 映射为 GGX alpha=roughness²（数值下限 0.001）。GGX 使用依赖出射方向的可见法线采样（VNDF）；采样和 NEE 使用相同的漫反射/镜面混合 PDF。黄金使用 RGB F0=(1, 0.71, 0.29) 的 Schlick 近似。Specular-Glossiness 保留独立 RGB F0，以 `diffuse * (1 - max(F0))` 构造漫反射项，以 `(1 - glossiness)²` 构造 GGX alpha；该工作流不再回退为默认金属。SG 镜面纹理 RGB 使用 sRGB 视图，alpha 是线性光泽度。

发光是所有表面的附加属性，`absorbing` 表面可用于只发光、不反射的灯。

基色与发光纹理使用 sRGB 视图；MR 的 G/B 分别控制 roughness/metallic，法线与 AO 使用线性视图。顶点颜色调制基色和 alpha。AO 数据会采样并验证，但不再乘进已计算真实可见性的路径积分，避免重复遮挡。

OPAQUE 忽略 alpha；MASK 使用 alphaCutoff；BLEND 将 alpha 解释为随机表面覆盖，未命中覆盖部分继续遍历且不消耗反弹。阴影累乘每层的 1-alpha。两者复用 Metal intersection query 候选处理与半开三角形边界归属，避免共享边上的重复透明度。doubleSided 允许背面并翻转着色朝向；理想闭合玻璃保留双向介质界面。

## 当前边界

- 材质与路径计算均使用线性 RGB，颜色纹理解码一次；没有光谱重建。色调映射可能与其他 glTF 查看器不同。
- mip 已生成并可按绑定 lod 访问，尚无 ray cone/射线微分自动选择 LOD；不存在屏幕导数时默认 LOD 0。
- BLEND 是覆盖混合，不代表体积透射或折射；glTF transmission 薄表面透射已支持，volume 尚未实现。
- NEE 仍只登记完整矩形灯（OPAQUE、规范 UV0）；其他发光网格靠路径命中贡献。

实现语义参考 [glTF 2.0](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#materials) 和 Apple [Intersection Queries](https://developer.apple.com/documentation/metal/control-the-ray-tracing-process-using-intersection-queries)。实现代码和测试图案为本仓库编写，无新增第三方数据依赖。

显示输出在线性 RGB 中完成曝光、白平衡和色调映射，再手动编码一次 sRGB；视口使用 `bgra8Unorm` 并显式声明 sRGB 色彩空间，由系统匹配显示器色域。
