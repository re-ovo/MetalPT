import Metal

/// Declares the wavefront algorithm and its resource dependencies in execution order.
/// Resource allocation and command submission belong to FrameResources and Renderer.
enum PathTracingPasses {
    static func populate(
        context: MetalContext, scene: BindlessScene, sceneBuilt: Bool,
        frame: FrameResources, accumulation: MTLBuffer, output: MTLTexture,
        shouldTrace: Bool
    ) {
        let graph = frame.graph
        let handles = frame.handles
        let pathA = handles.pathA
        let pathB = handles.pathB
        let hitR = handles.hits
        let shadowR = handles.shadows
        let sampleR = handles.sample
        let countsR = handles.counts
        let indirectR = handles.indirect
        let n = frame.parameters.pixelCount
        let tables = frame.tables
        let indirect = frame.indirect
        let geometry = graph.importResource(
            "Bindless geometry / materials / spectral tables", allocation: scene.root)
        let bottom = graph.importResource(
            "BLAS", allocation: scene.blas, kind: .accelerationStructure, initialized: sceneBuilt)
        let top = graph.importResource(
            "TLAS", allocation: scene.tlas, kind: .accelerationStructure, initialized: sceneBuilt)
        let scratchB = graph.resource("BLAS scratch")
        let scratchT = graph.resource("TLAS scratch")
        let meanR = graph.importResource(
            "Persistent XYZ", allocation: accumulation, initialized: !frame.parameters.reset)
        let outputR = graph.importResource("Drawable", allocation: output, kind: .texture, initialized: false)
        if !sceneBuilt {
            graph.pass(
                "Build BLAS",
                accesses: [
                    .read(geometry, .accelerationStructure), .write(bottom, .accelerationStructure),
                    .write(scratchB, .accelerationStructure),
                ]
            ) {
                command in
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
                command in
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
        func dispatch(
            _ name: String, _ accesses: [RenderGraph.Access], bounce: Int = 0, tasks: Int = 1,
            indirectOffset: Int? = nil, effect: Bool = false
        ) {
            let pipeline = context.pipelines[name]!
            let table = tables[bounce]
            graph.pass("\(name) [\(bounce)]", accesses: accesses, sideEffect: effect) {
                command in
                let encoder = command.makeComputeCommandEncoder()!
                encoder.label = "\(name) [\(bounce)]"
                encoder.setComputePipelineState(pipeline)
                encoder.setArgumentTable(table)
                if let offset = indirectOffset {
                    encoder.dispatchThreadgroups(
                        indirectBuffer: indirect.gpuAddress + UInt64(offset),
                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                } else {
                    encoder.dispatchThreadgroups(
                        threadgroupsPerGrid: MTLSize(width: (tasks + 63) / 64, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                }
                encoder.endEncoding()
            }
        }
        if shouldTrace {
            var initAccess: [RenderGraph.Access] = [.write(pathA), .write(sampleR), .write(countsR)]
            if frame.parameters.reset {
                initAccess.append(.write(meanR))
            }
            dispatch("initialize", initAccess, tasks: n)
            for bounce in 0..<frame.parameters.maxDepth {
                let read = bounce % 2 == 0 ? pathA : pathB
                let write = bounce % 2 == 0 ? pathB : pathA
                dispatch(
                    "prepareBounce", [.read(countsR), .write(countsR), .write(indirectR)], bounce: bounce)
                dispatch(
                    "intersectPaths",
                    [
                        .read(read), .read(countsR), .read(indirectR), .read(top), .read(geometry),
                        .write(hitR),
                    ], bounce: bounce, indirectOffset: 0)
                dispatch(
                    "shadePaths",
                    [
                        .read(read), .read(hitR), .read(geometry), .read(countsR), .read(indirectR),
                        .read(sampleR), .write(write), .write(shadowR), .write(countsR), .write(sampleR),
                    ], bounce: bounce, indirectOffset: 0)
                dispatch("prepareShadow", [.read(countsR), .write(indirectR)], bounce: bounce)
                dispatch(
                    "traceShadows",
                    [
                        .read(shadowR), .read(top), .read(countsR), .read(indirectR), .read(sampleR),
                        .write(sampleR),
                    ], bounce: bounce, indirectOffset: 12)
                dispatch("finishBounce", [.read(countsR), .write(countsR)], bounce: bounce)
            }
            dispatch(
                "accumulate", [.read(sampleR), .read(meanR), .read(countsR), .write(countsR), .write(meanR)],
                tasks: n, effect: true)
        }
        let display = context.pipelines["displayImage"]!
        let table = tables[0]
        graph.pass("Display · XYZ → sRGB", accesses: [.read(meanR), .write(outputR)], sideEffect: true) {

            command in
            let e = command.makeComputeCommandEncoder()!
            e.label = "Display · XYZ → sRGB"
            e.setComputePipelineState(display)
            e.setArgumentTable(table)
            e.dispatchThreadgroups(
                threadgroupsPerGrid: MTLSize(
                    width: (output.width + 7) / 8, height: (output.height + 7) / 8, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            e.endEncoding()
        }
    }
}
