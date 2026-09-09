import Foundation
import Observation
import simd

enum DisplayTransform: Int, CaseIterable {
    case aces, reinhard, linear
    var title: String {
        switch self {
        case .aces: "ACES 风格"
        case .reinhard: "亮度 Reinhard"
        case .linear: "线性裁剪"
        }
    }
}

@Observable final class RenderModel {
    let importer = ModelImportController()
    var scene: DemoScene = .cornell
    var paused = false
    var denoiseEnabled = true
    var denoiseStrength: Float = 0.6
    var exposure: Float = 0
    var whiteBalanceTemperature: Float = 6504
    var whiteBalanceTint: Float = 0
    var displayTransform: DisplayTransform = .aces

    /// Approximate daylight white locus, adapted to the neutral 6504 K reference.
    /// Positive tint lowers source y, producing a greener correction. Temperature is illuminant CCT.
    var whiteBalanceMatrix: simd_float3x3 {
        func white(_ temperature: Float, _ tint: Float) -> SIMD3<Float> {
            let t = min(25000, max(4000, temperature))
            let x: Float =
                t <= 7000
                ? -4.607e9 / (t * t * t) + 2.9678e6 / (t * t) + 99.11 / t + 0.244063
                : -2.0064e9 / (t * t * t) + 1.9018e6 / (t * t) + 247.48 / t + 0.237040
            let y = -3 * x * x + 2.87 * x - 0.275 - min(1, max(-1, tint)) * 0.03
            return [x / y, 1, (1 - x - y) / y]
        }
        if whiteBalanceTemperature == 6504 && whiteBalanceTint == 0 { return matrix_identity_float3x3 }
        let rgbToXYZ = simd_float3x3(rows: [
            SIMD3(0.4124564, 0.3575761, 0.1804375),
            SIMD3(0.2126729, 0.7151522, 0.0721750),
            SIMD3(0.0193339, 0.1191920, 0.9503041),
        ])
        let bradford = simd_float3x3(rows: [
            SIMD3(0.8951, 0.2664, -0.1614), SIMD3(-0.7502, 1.7135, 0.0367),
            SIMD3(0.0389, -0.0685, 1.0296),
        ])
        let gain =
            (bradford * white(6504, 0))
            / (bradford * white(whiteBalanceTemperature, whiteBalanceTint))
        return rgbToXYZ.inverse * bradford.inverse * simd_float3x3(diagonal: gain) * bradford * rgbToXYZ
    }
    var scale: Float = 0.5
    var maxDepth = 8
    var resetToken = 0
    var samples = 0
    var gpuMilliseconds = 0.0
    var resolution = "—"
    var gpuName = "Metal 4"
    var error: String?
    var diagnostics = ""
    var sceneSnapshot = SceneDescription()
    var selectedNode: NodeID?
    var movementSpeed: Float = 1.5
    var navigating = false
    var camera = FPSCamera()
    func addLight(_ kind: ScenePunctualLight.Kind) {
        var light = ScenePunctualLight(
            name: "\(kind.title) \(sceneSnapshot.punctualLights.count + 1)", kind: kind)
        light.position = camera.position
        light.direction = camera.forward
        light.intensity = kind == .directional ? 2 : 20
        setLights(sceneSnapshot.punctualLights + [light])
        selectedNode = light.id
    }
    func setLights(_ lights: [ScenePunctualLight]) {
        do {
            guard let renderer = importer.renderer else { throw RenderFailure("渲染器尚未就绪") }
            try renderer.updatePunctualLights(lights)
            importer.error = nil
        } catch {
            importer.error = error.localizedDescription
        }
    }
    func resetCamera() {
        camera = FPSCamera()
        resetToken += 1
    }
}
