import SwiftUI

struct ContentView: View {
    @State private var model = RenderModel()
    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                MetalViewport(model: model)
                if let error = model.error {
                    ContentUnavailableView(
                        "渲染器无法运行", systemImage: "exclamationmark.triangle", description: Text(error)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.85))
                } else {
                    HStack(spacing: 18) {
                        Label("\(model.samples) spp", systemImage: "sparkles")
                        Text("\(model.gpuMilliseconds, format: .number.precision(.fractionLength(1))) ms GPU")
                        Text(model.resolution)
                    }
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    .padding(12).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    .padding(16)
                }
            }.frame(minWidth: 500, minHeight: 400)
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SPECTRAL").font(.system(size: 24, weight: .light, design: .rounded)).tracking(4)
                    Text("METAL 4 · PATH TRACING").font(
                        .system(size: 9, weight: .medium, design: .monospaced)
                    ).tracking(1.3).foregroundStyle(.secondary)
                }
                Picker("场景", selection: $model.scene) {
                    ForEach(DemoScene.allCases) {
                        Text($0.title).tag($0)
                    }
                }.labelsHidden()
                HStack {
                    Button {
                        model.paused.toggle()
                    } label: {
                        Label(
                            model.paused ? "继续" : "暂停", systemImage: model.paused ? "play.fill" : "pause.fill"
                        )
                    }
                    Button {
                        model.resetToken += 1
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }.help("重置累积")
                }.buttonStyle(.bordered)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("曝光")
                        Spacer()

                        Text(String(format: "%+.1f EV", model.exposure)).monospacedDigit().foregroundStyle(
                            .secondary)
                    }
                    Slider(value: $model.exposure, in: -4...4, step: 0.1)
                }
                Picker("渲染比例", selection: $model.scale) {
                    Text("25%").tag(Float(0.25))
                    Text("50%").tag(Float(0.5))
                    Text("100%").tag(Float(1))
                }
                Stepper("最大反弹  \(model.maxDepth)", value: $model.maxDepth, in: 1...16)
                Toggle("玻璃色散", isOn: $model.dispersion).toggleStyle(.switch)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("360–830 nm").font(.system(.title3, design: .monospaced))
                    LinearGradient(
                        colors: [.purple, .blue, .cyan, .green, .yellow, .orange, .red], startPoint: .leading,
                        endPoint: .trailing
                    ).frame(height: 3).clipShape(Capsule())
                    Text("每条路径 4 个波长\n色散事件保留主波长").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }
                Spacer()
                Button("重置相机") {
                    model.resetCamera()
                }
                Text("拖动旋转 · Shift / 右键拖动平移\n滚轮缩放").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.gpuName)
                    Text("GPU queues · Bindless · HW RT")
                    Text(model.diagnostics)
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(24).frame(width: 275).background(Color(nsColor: .windowBackgroundColor))
        }.preferredColorScheme(.dark)
    }
}
