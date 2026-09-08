import Metal

enum AccumulationPass {
    struct Resources {
        let sample, accumulation, counts: RenderGraph.Resource
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, pixels: Int) {
        compute.add(
            to: graph, kernel: "accumulate",
            accesses: [
                .read(io.sample), .read(io.accumulation), .read(io.counts), .write(io.counts),
                .write(io.accumulation),
            ], tasks: pixels, sideEffect: true)
    }
}
