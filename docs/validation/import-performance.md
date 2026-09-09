# glTF 加载性能验证

2026-09-09，Apple M4，Debug / -Onone。定位 Rikki 小文件加载慢，以及 Bistro 大纹理集的主线程阻塞问题。

## 原因与修改

- glTF accessor 曾逐字节通过 Data 下标读取每个分量；改为一次检查布局后在原始字节缓冲中批量读取，保留 normalized、sparse、非有限值及越界检查。GLB 子区间使用共享切片，避免复制整个 BIN 及重复 bufferView。
- 新节点设置变换曾扫描已有节点寻找后代；没有世界矩阵缓存的新子树无需失效遍历。
- 编译和校验曾按实例重复扫描网格三角形；槽位数量与 UV 可用标记现在按网格预计算，材质 UV 需求按材质计算。自动取景先计算局部 AABB，再变换每个实例的八个角，得到保守世界包围盒。
- 生产纹理曾在主线程用 Swift 逐像素生成两套 mip；现在在导入工作线程准备所需语义的纹理，由 GPU blit 生成 mip，完成后安装。opaque 图片/texel 跳过不必要的反预乘运算。
- 旧导入请求此前仅在最终安装时丢弃，会堵住后续小模型；现在在图片、网格和纹理准备边界检查取消。

## 单次测量

同一个独立 Debug CPU 驱动、同一 Rikki 文件的阶段对照（秒，不含 GPU 上传和首帧）：

| 阶段 | 修改前 | 修改后 |
|---|---:|---:|
| 容器 | 0.053 | 0.033 |
| 解析与场景编译 | 6.144 | 2.511 |
| 自动取景与校验 | 1.112 | 0.366 |
| 再次校验 | 1.025 | 0.288 |
| 合计 | 8.334 | 3.198 |

实际异步 Rikki 导入开启 API/Shader Validation：总计 4.269 秒，解析/编译 2.995 秒，取景 0.426 秒，纹理准备 0.021 秒，主线程安装 0.799 秒。上述总计到安装完成，不含首帧加速结构构建。文件有 820 个网格、3618 个实例、384729 个独立顶点、566440 个独立三角形；查看灯增加两个网格/实例。

1024×1024 图片在原 CPU 函数中生成 linear/sRGB mip 各约 1.16/1.21 秒。含同尺寸 PNG、同时绑定颜色和数据语义的约 10 KB GLB，通过实际导入测得纹理准备 26.5 毫秒，总计 46.0 毫秒。二者是阶段性负载对照，不是全模型端到端加速比。测量未做多轮统计，也未测 Release 性能。

静态扫描 Bistro 的 338 张 PNG：约 15.18 亿像素；旧代码两套 RGBA8 mip 约需 15.08 GiB，新代码按实际材质语义约 7.54 GiB（理论纹理负载估算，不含分配对齐、CPU 图片、几何和其他资源）。本次没有完整加载 Bistro，不能据此给出其实际加载时间。原始图片解码、仍保留的 CPU 像素和主线程几何安装还有优化空间。

## 验证

- Debug 构建、图/场景/资产 CPU 测试、glTF CPU 测试通过；新增非零起点 Data 切片与取消检查点回归。
- 完整生产 API / Shader Validation：640×480 输出、320×240 内部、Cornell/棱镜 16 spp、8 次反弹，通过纹理颜色空间/mip、SG、覆盖、资源驻留、玻璃及场景回归。
- 实际 Rikki 和 1024² 纹理 GLB：320×240 输出、160×120 内部、4 spp、8 次反弹，导入、取消旧请求、失败保留场景及 GPU 渲染通过；队列溢出/非有限值均为零。
- 已查看 Rikki 渲染输出。未运行 Metal Capture。

报告：[生产回归](import-regression.json)、[Rikki](import-rikki.json)、[纹理小模型](import-texture.json)。

```sh
scripts/test-graph.sh
scripts/test-gltf.sh
METALPT_SPP=16 scripts/validate-gpu.sh validation
METALPT_GLTF="$PWD/models/Rikimaru_Street.glb" METALPT_IMPORT_PROFILE=1 METALPT_SPP=4 METALPT_WIDTH=320 METALPT_HEIGHT=240 scripts/validate-gpu.sh validation
```

GPU mip 接口参考 [Apple generateMipmaps](https://developer.apple.com/documentation/metal/mtlblitcommandencoder/generatemipmaps(for:))。颜色空间及 alpha 语义通过生产 GPU 检查确认。
