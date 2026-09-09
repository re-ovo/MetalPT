import Observation

@Observable final class RenderModel {
    let importer = ModelImportController()
    var scene: DemoScene = .cornell
    var paused = false
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
    func resetCamera() {
        camera = FPSCamera()
        resetToken += 1
    }
}
