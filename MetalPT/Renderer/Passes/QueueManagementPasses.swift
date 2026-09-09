import Metal

enum QueueManagementPasses {
    struct Resources { let counts, indirect: RenderGraph.Resource }
    static func prepareBounce(
        to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int
    ) {
        compute.add(
            to: graph, kernel: "prepareBounce",
            work: WorkBindings([.counts: .readWrite(io.counts), .indirect: .write(io.indirect)]),
            bounce: bounce)
    }
    static func prepareShadow(
        to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int
    ) {
        compute.add(
            to: graph, kernel: "prepareShadow",
            work: WorkBindings([.counts: .read(io.counts), .indirect: .write(io.indirect)]), bounce: bounce)
    }
    static func finishBounce(
        to graph: RenderGraph, compute: ComputePass, resources io: Resources, bounce: Int
    ) {
        compute.add(
            to: graph, kernel: "finishBounce", work: WorkBindings([.counts: .readWrite(io.counts)]),
            bounce: bounce)
    }
}
