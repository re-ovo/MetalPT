import Observation

@Observable final class RenderModel {
    let importer = ModelImportController()
    var scene: DemoScene = .cornell
    var paused = false
    var exposure: Float = 0
    var scale: Float = 0.5
    var maxDepth = 8
    var dispersion = true
    var resetToken = 0
    var samples = 0
    var gpuMilliseconds = 0.0
    var resolution = "—"
    var gpuName = "Metal 4"
    var error: String?
    var diagnostics = ""
    var camera = OrbitCamera()
    func resetCamera() {
        camera = OrbitCamera()
        resetToken += 1
    }
}
