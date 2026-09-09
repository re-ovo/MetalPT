import Metal

enum DisplayPass {
    struct Resources { let accumulation, output: RenderGraph.Resource }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources) {
        compute.add(
            to: graph, kernel: "displayImage", work: WorkBindings([.accumulation: .read(io.accumulation)]),
            output: io.output, label: "Display · RGB → sRGB")
    }
}
