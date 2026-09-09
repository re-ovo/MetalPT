import Metal

enum CameraPathPass {
    struct Resources {
        let paths, sample, counts, accumulation: RenderGraph.Resource
    }
    static func add(
        to graph: RenderGraph, compute: ComputePass, resources io: Resources, reset: Bool, pixels: Int
    ) {
        var fields: [WorkBindings.Field: WorkBindings.Binding] = [
            .inputPaths: .write(io.paths), .radiance: .write(io.sample), .counts: .write(io.counts),
        ]
        if reset { fields[.accumulation] = .write(io.accumulation) }
        compute.add(to: graph, kernel: "initialize", work: WorkBindings(fields), tasks: pixels)
    }
}
