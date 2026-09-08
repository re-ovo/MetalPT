import Metal

extension PathTracingPassContext {
    func buildAccelerationStructures() {
        graph.pass(
            "Build BLAS",
            accesses: [
                .read(geometry, .accelerationStructure), .write(bottom, .accelerationStructure),
                .write(scratchB, .accelerationStructure),
            ]
        ) {
            [scene] command in
            let e = command.makeComputeCommandEncoder()!
            e.label = "Build BLAS"
            e.build(
                destinationAccelerationStructure: scene.blas, descriptor: scene.blasDescriptor,
                scratchBuffer: MTL4BufferRange(
                    bufferAddress: scene.scratchBLAS.gpuAddress, length: UInt64(scene.scratchBLAS.length))
            )
            e.endEncoding()
        }
        graph.pass(
            "Build TLAS",
            accesses: [
                .read(bottom, .accelerationStructure), .read(geometry, .accelerationStructure),
                .write(top, .accelerationStructure), .write(scratchT, .accelerationStructure),
            ]
        ) {
            [scene] command in
            let e = command.makeComputeCommandEncoder()!
            e.label = "Build TLAS"
            e.build(
                destinationAccelerationStructure: scene.tlas, descriptor: scene.tlasDescriptor,
                scratchBuffer: MTL4BufferRange(
                    bufferAddress: scene.scratchTLAS.gpuAddress, length: UInt64(scene.scratchTLAS.length))
            )
            e.endEncoding()
        }
    }
}
