import Metal

/// Encoding services only. A pass supplies its typed resources and declares every access.
struct ComputePass {
    let context: MetalContext
    let bindings: ComputeBindings
    let bindingResources: [RenderGraph.Resource]

    func add(
        to graph: RenderGraph, kernel: String, accesses: [RenderGraph.Access],
        bounce: Int = 0, tasks: Int = 1, indirect: RenderGraph.Resource? = nil,
        indirectOffset: Int = 0, sideEffect: Bool = false
    ) {
        let pipeline = context.pipelines[kernel]!
        let bindings = bindings
        var declared = accesses + bindingResources.map { .read($0) }
        if let indirect { declared.append(.read(indirect)) }
        graph.pass("\(kernel) [\(bounce)]", accesses: declared, sideEffect: sideEffect) {
            command, resources in
            let encoder = command.makeComputeCommandEncoder()!
            encoder.label = "\(kernel) [\(bounce)]"
            encoder.setComputePipelineState(pipeline)
            encoder.setArgumentTable(bindings.tables[bounce])
            if let indirect {
                let buffer = try resources.buffer(indirect)
                encoder.dispatchThreadgroups(
                    indirectBuffer: buffer.gpuAddress + UInt64(indirectOffset),
                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            } else {
                encoder.dispatchThreadgroups(
                    threadgroupsPerGrid: MTLSize(width: (tasks + 63) / 64, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            }
            encoder.endEncoding()
        }
    }
}
