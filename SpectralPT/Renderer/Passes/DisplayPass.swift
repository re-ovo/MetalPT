import Metal

enum DisplayPass {
    struct Resources { let accumulation, output: RenderGraph.Resource }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources) {
        let pipeline = compute.context.pipelines["displayImage"]!
        let bindings = compute.bindings
        graph.pass(
            "Display · XYZ → sRGB",
            accesses: [.read(io.accumulation), .write(io.output)]
                + compute.bindingResources.map { .read($0) }, sideEffect: false
        ) { command, resources in
            let output = try resources.texture(io.output)
            let encoder = command.makeComputeCommandEncoder()!
            encoder.label = "Display · XYZ → sRGB"
            encoder.setComputePipelineState(pipeline)
            encoder.setArgumentTable(bindings.tables[0])
            encoder.dispatchThreadgroups(
                threadgroupsPerGrid: MTLSize(
                    width: (output.width + 7) / 8, height: (output.height + 7) / 8, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
    }
}
