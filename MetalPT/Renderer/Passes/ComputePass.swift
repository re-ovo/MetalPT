import Metal

/// Dependencies and actual GPU pointers are both derived from each pass's binding description.
struct ComputePass {
    let context: MetalContext
    let bindings: ComputeBindings
    let bindingResources: [RenderGraph.Resource]

    func add(
        to graph: RenderGraph, kernel: String, work: WorkBindings, scene: SceneBindings? = nil,
        output: RenderGraph.Resource? = nil, bounce: Int = 0, tasks: Int = 1,
        indirect: RenderGraph.Resource? = nil, indirectOffset: Int = 0,
        sideEffect: Bool = false, label: String? = nil
    ) {
        let pipeline = context.pipelines[kernel]!
        let bindings = bindings
        let slot = bindings.reserve()
        var accesses = work.accesses + (scene?.accesses ?? []) + bindingResources.map { .read($0) }
        if let indirect { accesses.append(.read(indirect)) }
        if let output { accesses.append(.write(output)) }
        let name = label ?? "\(kernel) [\(bounce)]"
        graph.pass(name, accesses: accesses, sideEffect: sideEffect) { command, resources in
            let table = try bindings.table(
                slot: slot, bounce: bounce, work: work, scene: scene,
                output: output, resources: resources)
            let encoder = command.makeComputeCommandEncoder()!
            encoder.label = name
            encoder.setComputePipelineState(pipeline)
            encoder.setArgumentTable(table)
            if let output {
                let texture = try resources.texture(output)
                encoder.dispatchThreadgroups(
                    threadgroupsPerGrid: MTLSize(
                        width: (texture.width + 7) / 8,
                        height: (texture.height + 7) / 8, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            } else if let indirect {
                encoder.dispatchThreadgroups(
                    indirectBuffer: try resources.buffer(indirect).gpuAddress + UInt64(indirectOffset),
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
