import Metal

/// Frame-owned CPU upload arena. Every pass gets a distinct work root and argument table.
final class ComputeBindings {
    let allocations: [MTLAllocation]
    private let context: MetalContext
    private let frames: MTLBuffer
    private let arena: MTLBuffer
    private let depth: Int
    private let capacity: Int
    private var nextSlot = 0
    private var tables: [MTL4ArgumentTable] = []

    init(
        context: MetalContext, pool: TransientPool, keys: FrameSlot.ResourceKeys,
        parameters: FrameParameters, depth: Int
    ) throws {
        self.context = context
        self.depth = depth
        capacity = depth * 6 + 3
        frames = try pool.buffer(keys.constants, label: "Frame constants", length: depth * 256, shared: true)
        arena = try pool.buffer(
            keys.bindings, label: "Pass binding arena", length: capacity * 256, shared: true)
        allocations = [frames, arena]
        for bounce in 0..<depth {
            var constants = parameters.constants
            constants.size.w = UInt32(bounce)
            withUnsafeBytes(of: &constants) {
                frames.contents().advanced(by: bounce * 256).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count)
            }
        }
    }

    func reserve() -> Int { defer { nextSlot += 1 }; return nextSlot }

    func table(
        slot: Int, bounce: Int, work: WorkBindings, scene: SceneBindings?,
        output: RenderGraph.Resource?, resources: RenderGraph.ResolvedResources
    ) throws -> MTL4ArgumentTable {
        guard (0..<capacity).contains(slot), (0..<depth).contains(bounce) else {
            throw RenderFailure("Pass 绑定存储容量或反弹索引越界")
        }
        var root = try work.resolve(resources)
        let offset = slot * 256
        withUnsafeBytes(of: &root) {
            arena.contents().advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        var sceneAddress: UInt64 = 0
        if let scene {
            let source = try resources.buffer(scene.root)
            if let acceleration = scene.acceleration {
                guard source.storageMode == .shared, source.length >= MemoryLayout<PTScene>.stride else {
                    throw RenderFailure("场景根必须为可读取的共享 PTScene 缓冲")
                }
                var sceneRoot = source.contents().load(as: PTScene.self)
                sceneRoot.acceleration = try resources.accelerationStructure(acceleration).gpuResourceID._impl
                withUnsafeBytes(of: &sceneRoot) {
                    arena.contents().advanced(by: offset + 64).copyMemory(
                        from: $0.baseAddress!, byteCount: $0.count)
                }
                sceneAddress = arena.gpuAddress + UInt64(offset + 64)
            } else {
                sceneAddress = source.gpuAddress
            }
        }
        let texture = try output.map { try resources.texture($0) }
        let table = try context.table(
            sceneAddress: sceneAddress, workAddress: arena.gpuAddress + UInt64(offset),
            frameAddress: frames.gpuAddress + UInt64(bounce * 256), output: texture)
        tables.append(table)
        return table
    }
}
