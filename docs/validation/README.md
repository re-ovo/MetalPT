# 本机验证记录

2026-09-08，Apple M4（10 GPU cores，32 GB），macOS 26.6.2，Xcode 26.6。

- Debug / Release 构建成功。唯一构建提示为没有 AppIntents 依赖，跳过其元数据提取。
- RenderGraph / ABI 测试通过；Metal API Validation + Shader Validation 32 spp 测试通过。
- 512 spp Release 离屏渲染：输出 1280×800，内部 640×400，50% 比例、8 次反弹、每帧 1 spp、色散开启。
- Cornell GPU 时间中位数 **11.55 ms**；棱镜 **8.01 ms**。排除前 4 帧，测量包含 wavefront、累积和显示，不包含 UI 与 CPU 编码，不代表固定帧率保证。
- 黑场无额外能量；CIE Y 积分、波长终止权重、GGX 归一化、金属 Fresnel、全反射及几何朝向检查通过。队列溢出和非有限值诊断为零。
- 色散开关图像平均绝对差为 0.01021（归一化显示像素，含采样噪声；它是回归检查，不是物理精度度量）。
- 暂停、曝光不改变 spp；相机/场景/尺寸/重置操作正确清除历史。连续提交场景与尺寸变化测试通过。
- 原生窗口布局、暂停和相机复位按钮已检查；相机数学及状态变化由集成测试覆盖。
- Metal Capture 单独运行成功，最终抓帧为 `/tmp/SpectralPT-delivery-capture/SpectralPT.gputrace`，包含 1 帧。此前同架构抓帧已在 Xcode 回放核对：`intersectPaths` 使用 `dispatchThreadgroupsWithIndirectBuffer` 与 `setArgumentTable`，驻留列表包含 BLAS、TLAS、光谱数据及纹理。51 次 dispatch（8 次反弹）及加速结构内存可见。

抓帧不纳入仓库（约 90 MB），使用 `scripts/validate-gpu.sh capture` 可复现。Shader Validation 与 GPU Capture 不能同时开启。

`report.json` 保存 Release 数值；`gpu-validation-report.json` 和 `gpu-validation.log` 保存验证层结果。PNG 为真实渲染输出，无降噪、无后期修图。玻璃和间接光仍有采样噪声；球体使用几何法线，因此可见三角网格面。

引擎基础改造后的测试见 [引擎基础验证](engine-foundation.md)，包括多实例、资源登记、延迟分配、图缓存和逐 Pass 统计。

架构审查四项修复的回归记录见 [绑定与资源契约验证](contracts.md)。

场景模型升级验证见 [scene-model.md](scene-model.md)。
