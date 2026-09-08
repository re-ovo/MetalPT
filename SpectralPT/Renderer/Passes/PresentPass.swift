import Metal

enum PresentPass {
    static func add(to graph: RenderGraph, source: RenderGraph.Resource, destination: RenderGraph.Resource) {
        graph.pass("Present", accesses: [.read(source, .blit), .write(destination, .blit)], sideEffect: true)
        { command, resources in
            let encoder = command.makeComputeCommandEncoder()!
            encoder.label = "Present"
            encoder.copy(
                sourceTexture: try resources.texture(source),
                destinationTexture: try resources.texture(destination))
            encoder.endEncoding()
        }
    }
}
