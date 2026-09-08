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

/// Per-slot pool: only accessed after the slot completes. Budget limits cached, not live, memory.
final class TransientPool {
    let context: MetalContext
    private var buffers: [String: MTLBuffer] = [:]
    private var textures: [String: (TextureDescription, MTLTexture)] = [:]
    private var touched = Set<String>()
    let budget = 256 * 1024 * 1024
    var cachedBytes: Int {
        buffers.values.reduce(0) { $0 + $1.length } + textures.values.reduce(0) { $0 + $1.1.allocatedSize }
    }
    init(_ context: MetalContext) { self.context = context }
    func beginFrame() { touched.removeAll() }
    func trim() {
        for key in Array(buffers.keys) where !touched.contains("b:" + key) {
            buffers.removeValue(forKey: key)
        }
        for key in Array(textures.keys) where !touched.contains("t:" + key) {
            textures.removeValue(forKey: key)
        }
        // Resolved frame resources retain these allocations independently of the cache.
        if cachedBytes > budget { buffers.removeAll(); textures.removeAll() }
    }
    func buffer(_ name: String, length: Int, shared: Bool = false) throws -> MTLBuffer {
        touched.insert("b:" + name)
        if let old = buffers[name], old.length >= max(16, length),
            old.storageMode == (shared ? .shared : .private)
        {
            return old
        }
        var capacity = 256
        while capacity < length { capacity *= 2 }
        let b = try context.buffer(capacity, name, shared: shared)
        buffers[name] = b
        return b
    }
    func texture(_ name: String, description: TextureDescription) throws -> MTLTexture {
        touched.insert("t:" + name)
        if let old = textures[name], old.0 == description { return old.1 }
        guard let texture = context.device.makeTexture(descriptor: description.makeDescriptor()) else {
            throw RenderFailure("纹理分配失败：\(name)")
        }
        texture.label = name
        textures[name] = (description, texture)
        return texture
    }
}
