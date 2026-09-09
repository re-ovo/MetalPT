# 空间降噪验证

2026-09-09，Apple M4，Debug，Metal API Validation / Shader Validation 开启。

## 功能

检查器「渲染 → 空间降噪」，默认开启，强度默认 0.6，可调 0.1–1.5。使用首交点法线、深度、反照率引导三轮空间滤波；位于色调映射之前，只影响显示结果。镜面玻璃、低粗糙度镜面、透明覆盖、透射和发光表面保留原图。

## 验证

- Debug 构建通过。
- `scripts/test-graph.sh` 通过，包含 PTWork 新大小 104、新增指针偏移 64/88/96 的断言及已有图/资产检查。
- `SPECTRAL_SPP=16 SPECTRAL_OUTPUT=/tmp/MetalPT-denoise-fix-validation scripts/validate-gpu.sh validation` 通过，报告见 [spatial-denoise-regression.json](spatial-denoise-regression.json)。已有生产 BSDF、灯光、场景和 pass 绑定回归使用未滤波输出，均通过。
- 降噪专项使用 Cornell，640×480 输出，320×240 内部渲染，深度 8，输入 8 spp；同一份累积分别打开、关闭降噪，参考为原始 256 spp。强度 0.6。
- 显示空间 RGB MSE：原图 0.010258，滤波后 0.004158，降低约 59.5%。这是该场景和参数的结果，不是所有场景的画质保证，且 256 spp 参考仍有噪声。
- 逐字节验证：暂停时开关降噪再关闭，原图完全一致；采样数不变。关闭时图中无降噪 pass，开启时主射线引导与三个滤波 pass 均存在。
- 暂停时移动相机，正确重新生成首样本及引导缓冲，无未初始化资源或 GPU 错误。
- 独立合成数据分别验证反照率边界、深度断层、法线断层的边缘保持及区域内噪声降低；保护标记的输入逐字节保持不变。
- 实际界面检查：暂停于 685 spp，关闭再打开降噪，仍为 685 spp；强度控件按开关显示，随后恢复渲染。

## 图像

已检查 [原始 8 spp](spatial-denoise-off.png)、[空间降噪 8 spp](spatial-denoise-on.png) 和 [256 spp 参考](spatial-denoise-reference.png)。墙面与漫反射区域噪声降低，玻璃保留原始噪声；部分高光细节会软化。没有加入时间累积降噪、运动向量或贡献限幅。

## 代码审查修复验证

- 半透明法线贴图前景覆盖不透明背景：生产引导生成函数在 4,096 个随机种子下始终选择前景并保护；原始路径追踪仍保持约 50% 的前景接受率。
- BLEND alpha=0、MASK alpha=0.25（cutoff=0.5）正确穿透到背景，MASK alpha=0.75 正确命中前景。
- 实际法线贴图产生倾斜着色法线时，几何引导仍为平面法线。合成平面测试将着色法线统一倾斜 45°，滤波结果与平直着色法线相同，证明切平面距离不再使用着色法线。
- 新增几何法线缓冲的读写和驻留随 typed pass 声明，CPU ABI 测试与完整 GPU 回归通过。
