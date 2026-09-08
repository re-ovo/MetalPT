import Metal

enum AccumulationPass {
    struct Resources {
        let sample, accumulation, counts: RenderGraph.Resource
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, pixels: Int) {
        compute.add(
            to: graph, kernel: "accumulate",
            work: WorkBindings([
                .radiance: .read(io.sample), .accumulation: .readWrite(io.accumulation),
                .counts: .readWrite(io.counts),
            ]), tasks: pixels, sideEffect: true)
    }
}
