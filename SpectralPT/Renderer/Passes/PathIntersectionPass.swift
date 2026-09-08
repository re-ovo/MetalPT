import Metal

enum PathIntersectionPass {
    struct Resources {
        let paths, counts, indirect, hits, acceleration: RenderGraph.Resource
        let scene: [RenderGraph.Resource]
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int) {
        compute.add(
            to: graph, kernel: "intersectPaths",
            accesses: [.read(io.paths), .read(io.counts), .read(io.acceleration), .write(io.hits)]
                + io.scene.map { .read($0) },
            bounce: bounce, indirect: io.indirect)
    }
}
