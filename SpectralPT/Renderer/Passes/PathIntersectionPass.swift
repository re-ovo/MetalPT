import Metal

enum PathIntersectionPass {
    struct Resources {
        let paths, counts, indirect, hits: RenderGraph.Resource
        let scene: SceneBindings
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int) {
        compute.add(
            to: graph, kernel: "intersectPaths",
            work: WorkBindings([
                .inputPaths: .read(io.paths), .counts: .read(io.counts), .hits: .write(io.hits),
            ]), scene: io.scene, bounce: bounce, indirect: io.indirect)
    }
}
