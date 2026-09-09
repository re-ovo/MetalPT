import SwiftUI
import simd

struct LightInspector: View {
    let model: RenderModel
    let lightID: NodeID

    private var light: ScenePunctualLight? {
        model.sceneSnapshot.punctualLights.first { $0.id == lightID }
    }
    private func edit(_ change: (inout ScenePunctualLight) -> Void) {
        var lights = model.sceneSnapshot.punctualLights
        guard let index = lights.firstIndex(where: { $0.id == lightID }) else { return }
        change(&lights[index])
        model.setLights(lights)
    }
    private func binding<T>(_ path: WritableKeyPath<ScenePunctualLight, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { light?[keyPath: path] ?? fallback }, set: { value in edit { $0[keyPath: path] = value } })
    }
    var body: some View {
        if let light {
            LabeledContent("类型", value: light.kind.title)
            TextField("名称", text: binding(\.name, fallback: light.name))
            Toggle("启用", isOn: binding(\.enabled, fallback: true))
            ColorPicker(
                "颜色",
                selection: Binding(
                    get: {
                        Color(
                            .sRGBLinear, red: Double(light.color.x), green: Double(light.color.y),
                            blue: Double(light.color.z))
                    },
                    set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        func linear(_ value: CGFloat) -> Float {
                            let c = Float(value)
                            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                        }
                        edit {
                            $0.color = simd_clamp(
                                SIMD3(
                                    linear(rgb.redComponent), linear(rgb.greenComponent),
                                    linear(rgb.blueComponent)), SIMD3(repeating: 0), SIMD3(repeating: 1))
                        }
                    }), supportsOpacity: false)
            TextField(
                light.kind == .directional ? "强度 (lux)" : "强度 (cd)",
                value: binding(\.intensity, fallback: 1), format: .number)
            if light.kind != .directional {
                vectorFields("位置", path: \.position, value: light.position)
                TextField("范围（0 = 无限）", value: binding(\.range, fallback: 0), format: .number)
            }
            if light.kind != .point {
                vectorFields("照射方向", path: \.direction, value: light.direction)
            }
            if light.kind == .spot {
                TextField("内锥半角 (°)", value: angleBinding(\.innerAngle), format: .number)
                TextField("外锥半角 (°)", value: angleBinding(\.outerAngle), format: .number)
            }
            Button("移到相机位置并沿视线照射") {
                edit {
                    $0.position = model.camera.position; $0.direction = model.camera.forward
                }
            }
            Button("删除灯光", role: .destructive) {
                model.setLights(model.sceneSnapshot.punctualLights.filter { $0.id != lightID })
                model.selectedNode = nil
            }
        }
    }
    private func angleBinding(_ path: WritableKeyPath<ScenePunctualLight, Float>) -> Binding<Float> {
        Binding(
            get: { (light?[keyPath: path] ?? 0) * 180 / .pi },
            set: { value in edit { $0[keyPath: path] = value * .pi / 180 } })
    }
    private func vectorFields(
        _ title: String, path: WritableKeyPath<ScenePunctualLight, SIMD3<Float>>,
        value: SIMD3<Float>
    ) -> some View {
        VStack(alignment: .leading) {
            Text(title).foregroundStyle(.secondary)
            HStack {
                ForEach(0..<3) { axis in
                    TextField(
                        ["X", "Y", "Z"][axis],
                        value: Binding(
                            get: {
                                light?[keyPath: path][axis] ?? value[axis]
                            }, set: { newValue in edit { $0[keyPath: path][axis] = newValue } }),
                        format: .number)
                }
            }
        }
    }
}
