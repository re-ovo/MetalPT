# 点光源、聚光灯和平行光验证

2026-09-09，Apple M4，Debug，Metal API Validation / Shader Validation 开启。

## 实现与操作

工具栏「＋」添加三种解析灯光。默认位置和方向取当前相机；场景树选中后，检查器可以修改名称、启用状态、线性 RGB 颜色、强度、位置、方向、范围和聚光半角，也可删除灯光。点/聚光强度单位为 cd，平行光为 lux。范围 0 表示无限；内锥半角须小于外锥半角，外锥最大 90°。这些参数只保存在当前内存场景，尚不支持保存或导出。

GPU 使用共同的均匀灯光选择，解析灯光使用离散 PDF 与 MIS 权重 1；面积灯保留原有立体角 PDF 与 MIS。三种光源产生硬阴影，光源本身不带可见几何。编辑仅替换灯光表及根表，纹理、网格和加速结构复用，旧帧继续持有旧快照。

## 检查结果

- Debug 构建、`scripts/test-graph.sh`、`scripts/test-gltf.sh` 通过。CPU 检查包括无效方向、强度、锥角拒绝，三种 glTF 灯光类型、父节点变换、−Z 方向、层级绑定及查看器归一化补偿。
- `SPECTRAL_SPP=16 SPECTRAL_OUTPUT=/tmp/MetalPT-lights-validation scripts/validate-gpu.sh validation` 通过，结果见 [lights-regression.json](lights-regression.json)。已有 Cornell / Prism、面积灯、材质与引擎回归全部通过。
- 新增解析灯光场景输出 640×480，渲染比例 50%，深度 1，每项使用单样本直接光照。Lambert 白板中心点光源参考值 1/π；实测距离 2 时 0.318301，距离 4 时 0.079577，符合平方反比。相同两灯亮度为单灯两倍，验证选择概率补偿。
- 聚光中心值 0.318282；锥外、范围外、禁用灯光均为零。平行光为 0.318310，改变其位置不影响亮度。点光和平行光的遮挡阴影测试均为零，无遮挡点光结果大于零。
- 帧提交后、完成前替换灯光快照，再渲染下一帧，未出现 GPU 验证错误；灯光编辑未重新构建 TLAS。
- 查看 [点光源](light-point.png)、[聚光灯](light-spot.png)、[平行光](light-directional.png) 输出，分别显示距离衰减、平滑光锥和均匀照明。
- `SPECTRAL_GLTF=/tmp/punctual-lights-fixture.glb SPECTRAL_SPP=4 SPECTRAL_WIDTH=320 SPECTRAL_HEIGHT=240 SPECTRAL_OUTPUT=/tmp/MetalPT-lights-import scripts/validate-gpu.sh validation` 通过完整异步导入、上传与渲染；深度 8、50% 比例、4 spp。结果见 [lights-import.json](lights-import.json)。
- 实际窗口验证了添加点光源、树中自动选择、强度从 20 改为 40、启用开关及累积重置。

本轮未重新运行完整 Bistro；其方向光通过新增 `KHR_lights_punctual` 路径导入，查看器仍会额外添加两个矩形查看灯光。
