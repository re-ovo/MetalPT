# 绑定与资源契约验证

2026-09-08，Apple M4，640×480 输出、320×240 内部分辨率、32 spp、8 次反弹。

- Debug / Release 构建及完整 GPU 验证通过；Debug 同时开启 Metal API Validation、Shader Validation 和逐 Pass 时间戳。
- 三个默认场景输出 PNG 与修复前逐字节相同。
- 同一命令缓冲中的两个累积 Pass 分别读取不同 sample buffer、写入不同 accumulation buffer；两个显示 Pass 分别绑定输入和输出纹理。检查实际 GPU 结果，确认未串用绑定。
- 图测试覆盖跨图句柄、缓存命中前的归属检查、缓存计划重新绑定当前图句柄、跨图/过期编译结果。GPU 集成测试还检查跨图解析资源被拒绝。
- 同名不同键的 buffer/texture 不共享分配；同帧重复租用同键被拒绝。图分配阶段拒绝两个逻辑资源意外引用同一分配。跨帧容量复用继续通过。
- 面积灯拒绝重复三角形、沿边重叠的三角形和非规范 UV；两种合法对角线划分均可接受。

图和 ABI 测试：`scripts/test-graph.sh`。GPU 测试：`METALPT_PROFILE=1 METALPT_SPP=32 scripts/validate-gpu.sh validation`。

`contract-report.json` 保存结果，`contract-validation.log` 保存验证层日志。未重复保存相同图片。
