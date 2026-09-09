import MetalKit
import SwiftUI

struct MetalViewport: NSViewRepresentable {
    let model: RenderModel
    func makeNSView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView()
        view.model = model
        view.registerForDraggedTypes([.fileURL])
        do {
            let renderer = try Renderer(model: model)
            view.renderer = renderer
            model.importer.renderer = renderer
            view.device = renderer.context.device
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.preferredFramesPerSecond = 60
            view.delegate = renderer
        } catch {
            model.error = error.localizedDescription
        }
        return view
    }
    func updateNSView(_ view: InteractiveMetalView, context: Context) {
    }
}

final class InteractiveMetalView: MTKView {
    var renderer: Renderer?
    var model: RenderModel?
    private func modelURL(_ sender: any NSDraggingInfo) -> URL? {
        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1,
            ["glb", "gltf"].contains(urls[0].pathExtension.lowercased())
        else { return nil }
        return urls[0]
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        modelURL(sender) == nil ? [] : .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = modelURL(sender), let model else { return false }
        model.importer.load(url)
        return true
    }
    override var acceptsFirstResponder: Bool {
        true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            model?.camera.pan(Float(event.deltaX), Float(event.deltaY))
        } else {
            model?.camera.orbit(Float(event.deltaX), Float(event.deltaY))
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        model?.camera.pan(Float(event.deltaX), Float(event.deltaY))
    }
    override func scrollWheel(with event: NSEvent) {
        model?.camera.zoom(Float(event.scrollingDeltaY))
    }
}
