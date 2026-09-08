# glTF 导入前的表面资产基础

当前实现覆盖静态三角形 primitive、着色法线、图片纹理、采样器和 metallic-roughness 着色。未加入 glTF 文件解析器。

## Mesh 与顶点

`SceneMesh.appendPrimitive(vertices:indices:materialSlot:)` 保留 primitive 内共享顶点；`primitives` 暴露索引范围和局部材质槽，并保留相邻同材质 primitive 的显式边界。GPU 仍使用平坦三角形表和共享 BLAS。

CPU Vertex 包含 position、normal、tangent（w 为手性）、color 和两套 UV；`uv.xy/zw` 分别为 UV0/UV1。attributes 位 1/2/4/8/16 分别声明 normal/tangent/UV0/UV1/color。缺少 normal 使用几何法线，缺少 tangent 从对应 UV 的三角形导数构造切线空间；缺失颜色默认白色。材质引用不存在的 UV 集会报错。暂不支持 UV2+、点线拓扑、蒙皮和 morph。

## 图片与绑定

`SceneImage` 接收 RGBA8 或 ImageIO 可解码的 PNG/JPEG 数据，保留直通 alpha 和图片行序。`SceneTexture` 引用稳定 ImageID；同一图片按语义上传线性与 sRGB 纹理，各自生成 mip 链。颜色 mip 在解码后的线性空间平均，再编码存储；数据和 alpha 不做 sRGB 变换。

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

PBR 使用 Lambert + GGX/Smith/Schlick：metallic 混合介电质 F0=0.04 与基色反射率，roughness 映射为 GGX alpha=roughness²（数值下限 0.001）。采样和 NEE 使用相同的漫反射/镜面混合 PDF。黄金仍可使用实测复折射率模型。发光是所有表面的附加属性，`absorbing` 表面可用于只发光、不反射的灯。

基色与发光纹理使用 sRGB 视图；MR 的 G/B 分别控制 roughness/metallic，法线与 AO 使用线性视图。顶点颜色调制基色和 alpha。AO 数据会采样并验证，但不再乘进已计算真实可见性的路径积分，避免重复遮挡。

OPAQUE 忽略 alpha；MASK 使用 alphaCutoff；BLEND 将 alpha 解释为随机表面覆盖，未命中覆盖部分继续遍历且不消耗反弹。阴影累乘每层的 1-alpha。两者复用 Metal intersection query 候选处理与半开三角形边界归属，避免共享边上的重复透明度。doubleSided 允许背面并翻转着色朝向；理想闭合玻璃保留双向介质界面。

## 当前边界

- RGB→光谱仍使用原创有界解析基底；这是近似重建，不保证与 RGB glTF 查看器逐色匹配，也不是测量光谱。
- mip 已生成并可按绑定 lod 访问，尚无 ray cone/射线微分自动选择 LOD；不存在屏幕导数时默认 LOD 0。
- BLEND 是覆盖混合，不代表体积透射或折射；尚未加入 glTF transmission/volume 扩展。
- NEE 仍只登记完整矩形灯（OPAQUE、规范 UV0）；其他发光网格靠路径命中贡献。

实现语义参考 [glTF 2.0](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#materials) 和 Apple [Intersection Queries](https://developer.apple.com/documentation/metal/control-the-ray-tracing-process-using-intersection-queries)。实现代码和测试图案为本仓库编写，无新增第三方数据依赖。
