import Metal

enum ShadowTracePass {
    struct Resources {
        let shadows, counts, indirect, sample: RenderGraph.Resource
        let scene: SceneBindings
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int) {
        compute.add(
            to: graph, kernel: "traceShadows",
            work: WorkBindings([
                .shadows: .read(io.shadows), .counts: .read(io.counts), .radiance: .readWrite(io.sample),
            ]), scene: io.scene, bounce: bounce, indirect: io.indirect, indirectOffset: 12)
    }
}
