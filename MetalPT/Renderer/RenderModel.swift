import Foundation
import Observation

@Observable final class RenderModel {
    let importer = ModelImportController()
    var scene: DemoScene = .cornell
    var paused = false
    var denoiseEnabled = true
    var denoiseStrength: Float = 0.6
    var exposure: Float = 0
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
