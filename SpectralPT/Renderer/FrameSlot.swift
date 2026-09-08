import Metal

final class FrameSlot {
    let allocator: MTL4CommandAllocator
    let command: MTL4CommandBuffer
    let pool: TransientPool
    var completedValue: UInt64 = 0
    var inFlight = false
    var retained: [Any] = []
    init(_ context: MetalContext) throws {
        guard let a = context.device.makeCommandAllocator() else {
            throw RenderFailure("Command allocator allocation failed")
        }
        allocator = a
        guard let c = context.device.makeCommandBuffer() else {
            throw RenderFailure("命令缓冲分配失败")
        }
        command = c
        pool = TransientPool(context)
    }
}

/// Pools only resources whose frame slot has completed; never aliases live allocations.
final class TransientPool {
    let context: MetalContext
    private var buffers: [String: MTLBuffer] = [:]
    init(_ context: MetalContext) {
        self.context = context
    }
    func buffer(_ name: String, length: Int, shared: Bool = false) throws -> MTLBuffer {
        if let old = buffers[name], old.length == max(16, length),
            old.storageMode == (shared ? .shared : .private)
        {
            return old
        }
        let b = try context.buffer(length, name, shared: shared)
        buffers[name] = b
        return b
    }
}
