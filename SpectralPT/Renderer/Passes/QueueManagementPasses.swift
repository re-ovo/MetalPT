import Metal

enum QueueManagementPasses {
    struct Resources { let counts, indirect: RenderGraph.Resource }
    static func prepareBounce(
        to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int
    ) {
        compute.add(
            to: graph, kernel: "prepareBounce",
            accesses: [.read(io.counts), .write(io.counts), .write(io.indirect)], bounce: bounce)
    }
    static func prepareShadow(
        to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int
    ) {
        compute.add(
            to: graph, kernel: "prepareShadow", accesses: [.read(io.counts), .write(io.indirect)],
            bounce: bounce)
    }
    static func finishBounce(
        to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int
    ) {
        compute.add(
            to: graph, kernel: "finishBounce", accesses: [.read(io.counts), .write(io.counts)], bounce: bounce
        )
    }
}
