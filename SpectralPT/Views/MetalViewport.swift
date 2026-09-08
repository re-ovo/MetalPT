import MetalKit
import SwiftUI

struct MetalViewport: NSViewRepresentable {
    let model: RenderModel
    func makeNSView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView()
        view.model = model
        do {
            let renderer = try Renderer(model: model)
            view.renderer = renderer
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
