import Metal

enum CameraPathPass {
    struct Resources {
        let paths, sample, counts, accumulation: RenderGraph.Resource
    }
    static func add(
        to graph: RenderGraph, compute: ComputePass, resources io: Resources, reset: Bool, pixels: Int
    ) {
        var accesses: [RenderGraph.Access] = [.write(io.paths), .write(io.sample), .write(io.counts)]
        if reset { accesses.append(.write(io.accumulation)) }
        compute.add(to: graph, kernel: "initialize", accesses: accesses, tasks: pixels)
    }
}
