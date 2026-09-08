import Metal

/// Shared frame resources and compute encoding; each pass declares its own accesses.
struct PathTracingPassContext {
    let context: MetalContext
    let scene: BindlessScene
    let frame: FrameResources
    let output: MTLTexture
    let graph: RenderGraph
    let pathA: RenderGraph.Resource
    let pathB: RenderGraph.Resource
    let hitR: RenderGraph.Resource
    let shadowR: RenderGraph.Resource
    let sampleR: RenderGraph.Resource
    let countsR: RenderGraph.Resource
    let indirectR: RenderGraph.Resource
    let n: Int
    let tables: [MTL4ArgumentTable]
    let indirect: MTLBuffer
    let geometry: RenderGraph.Resource
    let bottom: RenderGraph.Resource
    let top: RenderGraph.Resource
    let scratchB: RenderGraph.Resource
    let scratchT: RenderGraph.Resource
    let meanR: RenderGraph.Resource
    let outputR: RenderGraph.Resource

    init(
        context: MetalContext, scene: BindlessScene, sceneBuilt: Bool,
        frame: FrameResources, accumulation: MTLBuffer, output: MTLTexture
    ) {
        self.context = context
        self.scene = scene
        self.frame = frame
        self.output = output
        let graph = frame.graph
        self.graph = graph
        let handles = frame.handles
        self.pathA = handles.pathA
        self.pathB = handles.pathB
        self.hitR = handles.hits
        self.shadowR = handles.shadows
        self.sampleR = handles.sample
        self.countsR = handles.counts
        self.indirectR = handles.indirect
        self.n = frame.parameters.pixelCount
        self.tables = frame.tables
        self.indirect = frame.indirect
        self.geometry = graph.importResource(
            "Bindless geometry / materials / spectral tables", allocation: scene.root)
        self.bottom = graph.importResource(
            "BLAS", allocation: scene.blas, kind: .accelerationStructure, initialized: sceneBuilt)
        self.top = graph.importResource(
            "TLAS", allocation: scene.tlas, kind: .accelerationStructure, initialized: sceneBuilt)
        self.scratchB = graph.resource("BLAS scratch")
        self.scratchT = graph.resource("TLAS scratch")
        self.meanR = graph.importResource(
            "Persistent XYZ", allocation: accumulation, initialized: !frame.parameters.reset)
        self.outputR = graph.importResource(
            "Drawable", allocation: output, kind: .texture, initialized: false)
    }
    func dispatch(
        _ name: String, _ accesses: [RenderGraph.Access], bounce: Int = 0, tasks: Int = 1,
        indirectOffset: Int? = nil, effect: Bool = false
    ) {
        let pipeline = context.pipelines[name]!
        let table = tables[bounce]
        graph.pass("\(name) [\(bounce)]", accesses: accesses, sideEffect: effect) {
            [indirect] command in
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
}
