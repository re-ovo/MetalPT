import Metal

/// Binding storage has no graph reference and is retained by the frame until GPU completion.
final class ComputeBindings {
    let allocations: [MTLAllocation]
    private(set) var tables: [MTL4ArgumentTable] = []
    private let context: MetalContext
    private let sceneRoot: MTLBuffer
    private let frames: MTLBuffer
    private let roots: [MTLBuffer]
    private let depth: Int

    init(
        context: MetalContext, pool: TransientPool, parameters: FrameParameters,
        sceneRoot: MTLBuffer, depth: Int
    ) throws {
        self.context = context
        self.sceneRoot = sceneRoot
        self.depth = depth
        frames = try pool.buffer("Frame constants", length: depth * 256, shared: true)
        roots = try [
            pool.buffer("Work root A", length: MemoryLayout<PTWork>.stride, shared: true),
            pool.buffer("Work root B", length: MemoryLayout<PTWork>.stride, shared: true),
        ]
        allocations = [frames] + roots
        for bounce in 0..<depth {
            var constants = parameters.constants
            constants.size.w = UInt32(bounce)
            withUnsafeBytes(of: &constants) {
                frames.contents().advanced(by: bounce * 256).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count)
            }
        }
    }

    func prepare(
        resources: RenderGraph.ResolvedResources, handles: FrameResources.Handles,
        accumulation: RenderGraph.Resource, outputTexture: MTLTexture
    ) throws {
        func address(_ handle: RenderGraph.Resource) -> UInt64 {
            (try? resources.buffer(handle).gpuAddress) ?? 0
        }
        var work = PTWork()
        work.inputPaths = address(handles.pathA)
        work.outputPaths = address(handles.pathB)
        work.hits = address(handles.hits)
        work.shadows = address(handles.shadows)
        work.radiance = address(handles.sample)
        work.counts = address(handles.counts)
        work.indirect = address(handles.indirect)
        work.accumulation = try resources.buffer(accumulation).gpuAddress
        for index in 0..<2 {
            withUnsafeBytes(of: &work) {
                roots[index].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
            swap(&work.inputPaths, &work.outputPaths)
        }
        tables = try (0..<depth).map { bounce in
            try context.table(
                scene: sceneRoot, work: roots[bounce % 2], frame: frames, offset: bounce * 256,
                output: outputTexture
            )
        }
    }
}
