import Metal

enum MaterialShadingPass {
    struct Resources {
        let paths, hits, counts, indirect, sample, nextPaths, shadows: RenderGraph.Resource
        let scene: SceneBindings
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int) {
        compute.add(
            to: graph, kernel: "shadePaths",
            work: WorkBindings([
                .inputPaths: .read(io.paths), .hits: .read(io.hits), .counts: .readWrite(io.counts),
                .radiance: .readWrite(io.sample), .outputPaths: .write(io.nextPaths),
                .shadows: .write(io.shadows),
            ]), scene: io.scene, bounce: bounce, indirect: io.indirect)
    }
}
