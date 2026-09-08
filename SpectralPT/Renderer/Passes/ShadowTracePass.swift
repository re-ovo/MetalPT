import Metal

enum ShadowTracePass {
    struct Resources {
        let shadows, acceleration, sceneRoot, counts, indirect, sample: RenderGraph.Resource
        let traversal: [RenderGraph.Resource]
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int) {
        compute.add(
            to: graph, kernel: "traceShadows",
            accesses: [
                .read(io.shadows), .read(io.acceleration), .read(io.sceneRoot), .read(io.counts),
                .read(io.sample), .write(io.sample),
            ] + io.traversal.map { .read($0) },
            bounce: bounce, indirect: io.indirect, indirectOffset: 12)
    }
}
