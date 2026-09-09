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
    private var keys = Set<UInt16>()
    private var movementTimer: Timer?
    private var previousTick = 0.0
    private var fastMovement = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopNavigation()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(stopNavigation), name: NSWindow.didResignKeyNotification,
                object: window)
        }
    }

    override func resignFirstResponder() -> Bool {
        stopNavigation()
        return super.resignFirstResponder()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        model?.navigating = true
        fastMovement = event.modifierFlags.contains(.shift)
        previousTick = ProcessInfo.processInfo.systemUptime
        movementTimer?.invalidate()
        let timer = Timer(
            timeInterval: 1.0 / 60, target: self, selector: #selector(updateMovement),
            userInfo: nil, repeats: true)
        movementTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard model?.navigating == true else { return }
        model?.camera.look(Float(event.deltaX), Float(event.deltaY))
    }

    override func rightMouseUp(with event: NSEvent) { stopNavigation() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { stopNavigation(); return }
        guard model?.navigating == true, [0, 1, 2, 12, 13, 14].contains(event.keyCode),
            !event.modifierFlags.contains(.command)
        else {
            super.keyDown(with: event)
            return
        }
        keys.insert(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        keys.remove(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        fastMovement = event.modifierFlags.contains(.shift)
    }

    @objc private func updateMovement() {
        guard let model, model.navigating, window?.isKeyWindow == true else {
            stopNavigation()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = Float(min(now - previousTick, 0.05))
        previousTick = now
        func axis(_ positive: UInt16, _ negative: UInt16) -> Float {
            (keys.contains(positive) ? 1 : 0) - (keys.contains(negative) ? 1 : 0)
        }
        model.camera.move(
            [axis(2, 0), axis(14, 12), axis(13, 1)],
            distance: delta * model.movementSpeed * (fastMovement ? 4 : 1))
    }

    @objc private func stopNavigation() {
        movementTimer?.invalidate()
        movementTimer = nil
        keys.removeAll()
        model?.navigating = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        model.movementSpeed = min(
            20, max(0.05, model.movementSpeed * exp(Float(event.scrollingDeltaY) * 0.02)))
    }
}
