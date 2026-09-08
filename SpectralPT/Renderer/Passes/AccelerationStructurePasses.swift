import Metal

enum AccelerationStructurePasses {
    static func add(
        to graph: RenderGraph, scene: BindlessScene, handles: [ResourceRegistry.Handle: RenderGraph.Resource]
    ) {
        for (index, build) in scene.meshBuilds.enumerated() where build.required {
            graph.pass(
                "Build BLAS \(index)",
                accesses: build.inputs.map { .read(handles[$0]!, .accelerationStructure) } + [
                    .write(handles[build.output]!, .accelerationStructure),
                    .write(handles[build.scratchHandle]!, .accelerationStructure),
                ]
            ) { command in
                let encoder = command.makeComputeCommandEncoder()!
                encoder.label = "Build BLAS \(index)"
                encoder.build(
                    destinationAccelerationStructure: build.destination, descriptor: build.descriptor,
                    scratchBuffer: MTL4BufferRange(
                        bufferAddress: build.scratch.gpuAddress, length: UInt64(build.scratch.length)))
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
