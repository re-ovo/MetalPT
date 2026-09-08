import Metal

enum MaterialShadingPass {
    struct Resources {
        let paths, hits, counts, indirect, sample, nextPaths, shadows: RenderGraph.Resource
        let scene: [RenderGraph.Resource]
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int) {
        compute.add(
            to: graph, kernel: "shadePaths",
            accesses: [
                .read(io.paths), .read(io.hits), .read(io.counts), .read(io.sample),
                .write(io.nextPaths), .write(io.shadows), .write(io.counts), .write(io.sample),
            ] + io.scene.map { .read($0) },
            bounce: bounce, indirect: io.indirect)
    }
}
