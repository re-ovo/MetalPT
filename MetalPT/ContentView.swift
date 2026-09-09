import SwiftUI

struct ContentView: View {
    @State private var model = RenderModel()
    @State private var showSceneTree = true
    @State private var showInspector = true
    @State private var search = ""

    private var title: String { model.importer.filename ?? model.scene.title }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showSceneTree { sceneTree.frame(minWidth: 190, idealWidth: 220, maxWidth: 280) }
                viewport.frame(minWidth: 400, minHeight: 360)
                if showInspector { inspector.frame(minWidth: 245, idealWidth: 270, maxWidth: 300) }
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    showSceneTree.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("显示或隐藏场景树")
                Menu {
                    Button("打开模型…", systemImage: "doc.badge.plus") { model.importer.open() }
                    Button("打开模型文件夹…", systemImage: "folder") { model.importer.openFolder() }
                    Divider()
                    ForEach(DemoScene.allCases) { scene in
                        Button(scene.title) {
                            model.scene = scene
                            model.importer.showDemo()
                        }
                    }
                } label: {
                    Label("场景", systemImage: "folder")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(ScenePunctualLight.Kind.allCases) { kind in
                        Button(kind.title, systemImage: kind.icon) { model.addLight(kind) }
                    }
                } label: {
                    Label("添加灯光", systemImage: "plus")
                }
                .help("在当前相机位置添加灯光")
                .disabled(model.sceneSnapshot.instances.isEmpty || model.importer.isLoading)
                Button {
                    model.paused.toggle()
                } label: {
                    Label(
                        model.paused ? "继续渲染" : "暂停渲染",
                        systemImage: model.paused ? "play.fill" : "pause.fill")
                }.help(model.paused ? "继续渲染" : "暂停渲染")
                Button {
                    model.resetToken += 1
                } label: {
                    Label("重新累积", systemImage: "arrow.clockwise")
                }.help("清空采样并重新累积")
                Button {
                    model.resetCamera()
                } label: {
                    Label("重置相机", systemImage: "viewfinder")
                }.help("恢复场景初始视角")
                Divider()
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("显示或隐藏检查器")
            }
        }
    }

    private var sceneTree: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("场景", detail: "\(model.sceneSnapshot.instances.count) 个实例")
            TextField("搜索节点", text: $search)
                .textFieldStyle(.roundedBorder).padding(10)
            if filteredTree.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "场景尚未就绪" : "没有匹配节点",
                    systemImage: "cube.transparent")
            } else {
                List(selection: $model.selectedNode) {
                    OutlineGroup(filteredTree, children: \.children) { node in
                        Label(
                            node.name,
                            systemImage: node.light != nil
                                ? "lightbulb" : (node.instance == nil ? "folder" : "cube")
                        )
                        .lineLimit(1).help(node.name).tag(node.id)
                    }
                }.listStyle(.sidebar)
            }
            Divider()
            Label(title, systemImage: "shippingbox")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(12)
        }
    }

    private var filteredTree: [SceneTreeNode] {
        guard !search.isEmpty else { return model.sceneSnapshot.hierarchy }
        func filter(_ nodes: [SceneTreeNode]) -> [SceneTreeNode] {
            nodes.compactMap { node in
                if node.name.localizedCaseInsensitiveContains(search) { return node }
                let children = filter(node.children ?? [])
                guard !children.isEmpty else { return nil }
                var result = node
                result.children = children
                return result
            }
        }
        return filter(model.sceneSnapshot.hierarchy)
    }

    private var viewport: some View {
        VStack(spacing: 0) {
            HStack {
                Label("透视", systemImage: "view.3d")
                Text("/  FPS 相机").foregroundStyle(.secondary)
                Spacer()
                Circle().fill(model.paused ? .orange : .green).frame(width: 6, height: 6)
                Text(model.paused ? "已暂停" : "渐进渲染")
            }.font(.caption).padding(.horizontal, 14).frame(height: 34)
            Divider()
            ZStack {
                MetalViewport(model: model)
                if let error = model.error {
                    ContentUnavailableView(
                        "渲染器无法运行", systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.85))
                }
                if model.importer.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在导入场景…").font(.callout)
                        Text("解析几何与材质，准备纹理").font(.caption).foregroundStyle(.secondary)
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Divider()
            HStack {
                Text(model.navigating ? "WASD 移动 · Q/E 升降 · Shift 加速 · Esc 退出" : "按住右键环顾并使用 WASD 移动 · Q/E 升降")
                Spacer()
                Text("滚轮调速").foregroundStyle(.tertiary)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
        }.background(.black.opacity(0.3))
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            panelHeader("检查器", detail: "METAL 4")
            Form {
                Section("选中节点") {
                    if let node = selectedNode {
                        Text(node.name).font(.headline).textSelection(.enabled)
                        if let id = node.light {
                            LightInspector(model: model, lightID: id)
                        } else if let index = node.instance,
                            model.sceneSnapshot.instances.indices.contains(index)
                        {
                            let instance = model.sceneSnapshot.instances[index]
                            let mesh = model.sceneSnapshot.meshes[instance.mesh]
                            LabeledContent("类型", value: "网格实例")
                            LabeledContent("顶点", value: "\(mesh.vertices.count)")
                            LabeledContent("三角形", value: "\(mesh.triangles.count)")
                            LabeledContent("材质槽", value: "\(instance.materials.count)")
                        } else {
                            LabeledContent("类型", value: "层级节点")
                            LabeledContent("子节点", value: "\(node.children?.count ?? 0)")
                        }
                    } else {
                        Text("在场景树中选择节点以查看信息").foregroundStyle(.secondary)
                    }
                }
                Section("渲染") {
                    Toggle("空间降噪", isOn: $model.denoiseEnabled)
                    if model.denoiseEnabled {
                        LabeledContent("降噪强度", value: String(format: "%.1f", model.denoiseStrength))
                        Slider(value: $model.denoiseStrength, in: 0.1...1.5, step: 0.1)
                        Text("保留镜面与透明表面的原始细节").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("分辨率比例", selection: $model.scale) {
                        Text("25%").tag(Float(0.25))
                        Text("50%").tag(Float(0.5))
                        Text("100%").tag(Float(1))
                    }
                    Stepper("反弹上限  \(model.maxDepth)", value: $model.maxDepth, in: 1...16)
                }
                Section("显示 · SDR sRGB") {
                    Picker("显示变换", selection: $model.displayTransform) {
                        ForEach(DisplayTransform.allCases, id: \.self) { transform in
                            Text(transform.title).tag(transform)
                        }
                    }
                    LabeledContent("光源色温", value: String(format: "%.0f K", model.whiteBalanceTemperature))
                    Slider(value: $model.whiteBalanceTemperature, in: 4000...25000, step: 1)
                    LabeledContent("色调校正（洋红 → 绿色）", value: String(format: "%+.2f", model.whiteBalanceTint))
                    Slider(value: $model.whiteBalanceTint, in: -1...1, step: 0.01)
                    Button("重置白平衡") {
                        model.whiteBalanceTemperature = 6504
                        model.whiteBalanceTint = 0
                    }
                    LabeledContent("曝光", value: String(format: "%+.1f EV", model.exposure))
                    Slider(value: $model.exposure, in: -4...4, step: 0.1)
                }
                Section("FPS 相机") {
                    LabeledContent("视野", value: "\(Int(model.camera.fieldOfView))°")
                    Slider(value: $model.camera.fieldOfView, in: 20...100, step: 1)
                    Toggle("景深", isOn: $model.camera.depthOfField)
                    if model.camera.depthOfField {
                        LabeledContent("孔径半径", value: String(format: "%.3f", model.camera.apertureRadius))
                        Slider(value: $model.camera.apertureRadius, in: 0...0.3, step: 0.001)
                        LabeledContent("对焦距离", value: String(format: "%.2f", model.camera.focusDistance))
                        Slider(value: $model.camera.focusDistance, in: 0.01...100)
                        Text("距离使用场景单位；降噪支持景深，并保留镜面与透明区域。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("移动速度", value: String(format: "%.2f", model.movementSpeed))
                    Slider(value: $model.movementSpeed, in: 0.05...20)
                    Button("重置相机") { model.resetCamera() }
                }
                Section("场景信息") {
                    LabeledContent("网格", value: "\(model.sceneSnapshot.meshes.count)")
                    LabeledContent("材质", value: "\(model.sceneSnapshot.materials.count)")
                    Text(model.importer.notice).foregroundStyle(.secondary).textSelection(.enabled)
                    if let error = model.importer.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }.formStyle(.grouped).controlSize(.small)
        }
    }

    private var selectedNode: SceneTreeNode? {
        func find(_ nodes: [SceneTreeNode]) -> SceneTreeNode? {
            for node in nodes {
                if node.id == model.selectedNode { return node }
                if let result = find(node.children ?? []) { return result }
            }
            return nil
        }
        return find(model.sceneSnapshot.hierarchy)
    }

    private func panelHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            Text(detail).foregroundStyle(.tertiary)
        }.font(.caption).padding(.horizontal, 12).frame(height: 34)
            .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 18) {
            Label("\(model.samples) spp", systemImage: "sparkles")
            Text("\(model.gpuMilliseconds, format: .number.precision(.fractionLength(1))) ms GPU")
            Text(model.resolution)
            Spacer()
            Text(model.gpuName).foregroundStyle(.secondary)
        }.font(.system(size: 10, design: .monospaced)).monospacedDigit()
            .padding(.horizontal, 14).frame(height: 26)
    }
}
