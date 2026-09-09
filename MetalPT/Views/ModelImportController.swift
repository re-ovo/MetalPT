import AppKit
import Observation
import UniformTypeIdentifiers

/// One serial worker limits memory usage; generation checks prevent stale loads from being installed.
@Observable final class ModelImportController {
    var filename: String?
    var isLoading = false
    var error: String?
    var notice = "支持 glTF 2.0 / GLB · 拖入视口加载"
    weak var renderer: Renderer?
    private var generation = 0
    private let worker = DispatchQueue(label: "MetalPT.glTF", qos: .userInitiated)

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "glb"), UTType(filenameExtension: "gltf")]
            .compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.load(url) }
        }
    }

    func openFolder() {
        let folderPanel = NSOpenPanel()
        folderPanel.canChooseDirectories = true
        folderPanel.canChooseFiles = false
        folderPanel.message = "选择包含 glTF、纹理和 bin 的模型文件夹"
        folderPanel.begin { [weak self] response in
            guard response == .OK, let folder = folderPanel.url else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            let panel = NSOpenPanel()
            panel.directoryURL = folder
            panel.allowedContentTypes = [UTType(filenameExtension: "glb"), UTType(filenameExtension: "gltf")]
                .compactMap { $0 }
            panel.begin { response in
                if response == .OK, let url = panel.url { self?.load(url, directory: folder) }
                if scoped { folder.stopAccessingSecurityScopedResource() }
            }
        }
    }

    func load(_ url: URL, directory: URL? = nil) {
        guard ["glb", "gltf"].contains(url.pathExtension.lowercased()) else {
            error = "请选择 .glb 或 .gltf 文件"
            return
        }
        generation += 1
        let request = generation
        isLoading = true
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        let folderScoped = directory?.startAccessingSecurityScopedResource() ?? false
        worker.async { [weak self] in
            let result = Result { () -> (SceneDescription, String) in
                let container = try GLTFContainer(url: url)
                let description = try GLTFPresentation.prepare(GLTFImporter(container: container).load())
                var notice = "自动取景 · 查看灯光"
                if !(container.document.animations ?? []).isEmpty { notice += " · 动画使用静态姿态" }
                let ignored = Set(container.document.extensionsUsed ?? []).subtracting([
                    "KHR_texture_transform", "KHR_materials_emissive_strength", "KHR_materials_transmission",
                ])
                if !ignored.isEmpty { notice += "\n忽略可选扩展：" + ignored.sorted().joined(separator: ", ") }
                return (description, notice)
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            if folderScoped { directory?.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard let self, request == self.generation else { return }
                self.isLoading = false
                do {
                    let (description, notice) = try result.get()
                    guard let renderer = self.renderer else { throw RenderFailure("渲染器尚未就绪") }
                    try renderer.installImportedScene(description)
                    self.filename = url.lastPathComponent
                    self.notice = notice
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func showDemo() {
        generation += 1
        isLoading = false
        filename = nil
        error = nil
        notice = "支持 glTF 2.0 / GLB · 拖入视口加载"
        renderer?.sceneGraph = nil
        renderer?.sceneOverride = nil
        renderer?.model.resetCamera()
    }
}
