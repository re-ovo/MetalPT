import Metal

enum AccelerationStructurePasses {
    static func add(
        to graph: RenderGraph, scene: BindlessScene, handles: [ResourceRegistry.Handle: RenderGraph.Resource]
    ) {
        let pending = scene.meshBuilds.enumerated().filter { $0.element.required }
        if !pending.isEmpty {
            // Metal creates internal residency state per acceleration-structure encoder.
            // Independent BLAS builds share one encoder to avoid the command-buffer set limit.
            graph.pass(
                "Build BLAS",
                accesses: pending.flatMap { _, build in
                    build.inputs.map { .read(handles[$0]!, .accelerationStructure) } + [
                        .write(handles[build.output]!, .accelerationStructure),
                        .write(handles[build.scratchHandle]!, .accelerationStructure),
                    ]
                }
            ) { command in
                let encoder = command.makeComputeCommandEncoder()!
                encoder.label = "Build BLAS"
                for (index, build) in pending {
                    encoder.pushDebugGroup("Mesh \(index)")
                    encoder.build(
                        destinationAccelerationStructure: build.destination, descriptor: build.descriptor,
                        scratchBuffer: MTL4BufferRange(
                            bufferAddress: build.scratch.gpuAddress, length: UInt64(build.scratch.length)))
                    encoder.popDebugGroup()
                }
                encoder.endEncoding()
            }
        }
        graph.pass(
            "Build TLAS",
            accesses: scene.meshBuilds.map { .read(handles[$0.output]!, .accelerationStructure) } + [
                .read(handles[scene.instanceHandle]!, .accelerationStructure),
                .write(handles[scene.tlasHandle]!, .accelerationStructure),
                .write(handles[scene.scratchHandle]!, .accelerationStructure),
            ]
        ) { command in
            let encoder = command.makeComputeCommandEncoder()!
            encoder.label = "Build TLAS"
            encoder.build(
                destinationAccelerationStructure: scene.tlas, descriptor: scene.tlasDescriptor,
                scratchBuffer: MTL4BufferRange(
                    bufferAddress: scene.scratchTLAS.gpuAddress, length: UInt64(scene.scratchTLAS.length)))
            encoder.endEncoding()
        }
    }
}
