# GGX VNDF 验证

2026-09-09，Apple M4，Debug，Metal API Validation 与 Shader Validation 开启。

## 改动

GGX 从全法线分布采样切换为可见法线采样。同步修改反射方向 PDF 和混合分量 PDF，并保留当前薄表面透射的折叠映射。此改动覆盖 MR、SG 和黄金，未改变理想玻璃、光滑透射或材质粗糙度。另以等价表达式提高低粗糙度 GGX D 的浮点稳定性。

## 数值验证

生产 `sampleSurfaceBSDF` 与 `evaluateBSDF` 由新增 GPU kernel 直接调用。全 NDF 基线仅保留在验证 kernel 内，不提供运行时切换。

掠射角白色导体测试使用 `alpha=0.35`、`wo=normalize(1,0,0.05)`，每个方法 65,536 次采样，白色均匀环境：

| 指标 | VNDF | 全 NDF 基线 |
| --- | ---: | ---: |
| 平均贡献 | 0.847958 | 0.843768 |
| 单样本方差 | 0.047688 | 2.946699 |
| 最大样本权重 | 0.999999 | 28.504940 |

该测试方差约降低至原来的 1/61.8；这是特定测试场景的数据，不能外推为所有场景的收敛加速比。

独立球面积分与采样的有效概率分别为：纯反射 0.982077 / 0.982407，含漫反射和薄表面透射的混合分布 0.984766 / 0.985062。方向一阶矩、能量估计的绝对差均小于 0.001。测试保留拒绝采样的零贡献概率，防止重新归一化带来偏差。

另测试 alpha=0.001 / 0.05 / 1，出射余弦=1 / 0.2 / 0.001，以及旋转后的法线坐标系。未出现非有限权重/PDF，白色导体权重上限为 1。已有材质互易性、白炉、MIS 使用路径、灯光与引擎回归均通过。

## 构建与渲染

- `SPECTRAL_SPP=16 SPECTRAL_OUTPUT=/tmp/MetalPT-vndf-validation scripts/validate-gpu.sh validation` 通过。输出 640×480，50% 渲染比例；Cornell / Prism 为 16 spp、深度 8。表面画廊固定 32 spp、深度 8。结果见 [vndf-regression.json](vndf-regression.json)。
- 检查同参数、同种子的 [修改前 PBR 画廊](vndf-before-pbr.png) 与 [VNDF PBR 画廊](vndf-after-pbr.png)，以及 SG 画廊，整体材质与照明表现一致，噪点分布变化。未将低采样截图作为定量方差结论。
- `SPECTRAL_TRANSMISSION_VALIDATE=1 SPECTRAL_SPP=32 SPECTRAL_OUTPUT=/tmp/MetalPT-vndf-transmission scripts/validate-gpu.sh validation` 通过。该专用验证内部固定各透射场景 128 spp、深度 8、640×480 输出和 50% 比例。已检查粗糙透射图像。结果见 [vndf-transmission.json](vndf-transmission.json)。

VNDF 降低采样与 BSDF 不匹配引起的方差，并不能消除小光源、玻璃焦散等路径的全部高方差。本轮未加入降噪、贡献限幅或对真实场景进行收敛速度承诺。
