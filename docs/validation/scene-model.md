# 场景模型与增量几何验证

2026-09-08，Apple M4，macOS 26.6.2，Xcode 26.6。

- `scripts/test-graph.sh`：Render Graph、96 字节 PTInstance ABI、父子变换/脏子树、节点重挂与删除、环拒绝、可见性继承、稳定材质引用及槽位检查通过。
- Debug/Release 构建使用 `xcodebuild -project SpectralPT.xcodeproj -scheme SpectralPT -configuration Debug -derivedDataPath /tmp/SpectralPT-scene CODE_SIGNING_ALLOWED=NO build`，Release 替换配置名。
- Debug GPU 验证使用 `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 METALPT_VALIDATE=1 METALPT_SPP=32 METALPT_OUTPUT=/tmp/SpectralPT-scene-final /tmp/SpectralPT-scene/Build/Products/Debug/SpectralPT.app/Contents/MacOS/SpectralPT`。
- 输出 640×480，内部 320×240，默认图 32 spp、8 次反弹；结构测试使用 1 次反弹发光场景及 8 spp 多灯场景。
- 新增 GPU 检查：同一 BLAS 的不同多材质槽绑定与拆分几何结果一致；父节点移动改变图像但只构建 TLAS；隐藏整棵子树产生空实例黑场；修改顶点使旧 BLAS 失效。
- `cornell.png`、`prism.png`、`prism-no-dispersion.png` 与前一轮 `/tmp/SpectralPT-contract-final` 的固定种子基准逐字节一致，不重复保存图片。
- Metal API 与 Shader Validation 未报告错误。机器可读结果见 [scene-model-report.json](scene-model-report.json)，日志见 [scene-model-validation.log](scene-model-validation.log)。

更新仍通过新快照发布；几何/BLAS 可复用，材质、纹理与实例表仍整表上传，TLAS 仍为 build。暂未实现 TLAS refit、长期资产缓存或编辑器。
