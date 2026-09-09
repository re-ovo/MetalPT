# 渲染器界面与 FPS 相机

2026-09-09，Apple M4，Debug，Metal API Validation 与 Shader Validation 开启。

## 实现

- 工具栏、可折叠及调整宽度的场景树/检查器、独立渲染视口、底部采样与 GPU 状态。
- SceneDescription 的 CPU 元数据保留节点名称、稳定 ID、父子层级与可见实例索引；不改变 GPU ABI。glTF 查看灯光作为额外根节点。
- 场景树支持展开、搜索、选择；检查器显示网格顶点、三角形、材质槽数量。这一版是浏览检查功能，尚无变换编辑、视口拾取或选中轮廓。
- FPS 相机绕自身位置旋转；WASD 沿水平面移动，Q/E 沿世界竖直方向移动；对角线速度归一化。右键按住期间启用移动，Shift 四倍加速。滚轮调速，检查器调视野。
- 松开右键、Esc、视图失去第一响应者或窗口失焦时清空按键并停用定时器。相机变化继续走既有累积失效逻辑。

## 验证

- Debug 构建通过。
- `scripts/test-graph.sh` 通过：相机原地环顾、俯仰限制、水平移动、对角速度、投影基底；层级顺序、节点 ID、隐藏节点实例映射，以及已有 Graph / ABI 测试。
- `scripts/test-gltf.sh` 通过：导入层级与查看灯光元数据保留，以及既有导入检查。
- `SPECTRAL_SPP=16 SPECTRAL_OUTPUT=/tmp/MetalPT-ui-validation scripts/validate-gpu.sh validation` 通过。输出 640×480，渲染比例 50%，深度 8；表面画廊 32 spp。检查 Cornell 图像，未发现相机基底或投影异常。结果见 [ui-fps-regression.json](ui-fps-regression.json)。
- 实际窗口检查：工具栏暂停、场景树搜索、节点选择及统计显示；从场景菜单导入层级 fixture 后展开 Node 0，正确显示 Node 1 / Node 2 和两个独立查看灯光。

本轮未重新加载完整 Bistro；导入数据和渲染路径沿用之前已验证的实现，仅新增 CPU 层级元数据。
