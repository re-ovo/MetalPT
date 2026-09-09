import Metal

final class FrameSlot {
    let allocator: MTL4CommandAllocator
    let command: MTL4CommandBuffer
    struct ResourceKeys {
        let pathA = TransientPool.Key(), pathB = TransientPool.Key(), hits = TransientPool.Key()
        let shadows = TransientPool.Key(), sample = TransientPool.Key(), counts = TransientPool.Key()
        let indirect = TransientPool.Key(), display = TransientPool.Key()
        let constants = TransientPool.Key(), bindings = TransientPool.Key()
    }
    let resourceKeys = ResourceKeys()
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
    struct Key: Hashable { private let value = UUID() }
    let context: MetalContext
    private var buffers: [Key: MTLBuffer] = [:]
    private var textures: [Key: (TextureDescription, MTLTexture)] = [:]
    private var touched = Set<Key>()
    let budget = 256 * 1024 * 1024
    var cachedBytes: Int {
        buffers.values.reduce(0) { $0 + $1.length } + textures.values.reduce(0) { $0 + $1.1.allocatedSize }
    }
    init(_ context: MetalContext) { self.context = context }
    func beginFrame() { touched.removeAll() }
    func trim() {
        for key in Array(buffers.keys) where !touched.contains(key) {
            buffers.removeValue(forKey: key)
        }
        for key in Array(textures.keys) where !touched.contains(key) {
            textures.removeValue(forKey: key)
        }
        // Resolved frame resources retain these allocations independently of the cache.
        if cachedBytes > budget { buffers.removeAll(); textures.removeAll() }
    }
    func buffer(_ key: Key, label name: String, length: Int, shared: Bool = false) throws -> MTLBuffer {
        guard touched.insert(key).inserted else { throw RenderFailure("资源在同一帧被重复租用：\(name)") }
        if let old = buffers[key], old.length >= max(16, length),
            old.storageMode == (shared ? .shared : .private)
        {
            return old
        }
        var capacity = 256
        while capacity < length { capacity *= 2 }
        let b = try context.buffer(capacity, name, shared: shared)
        buffers[key] = b
        return b
    }
    func texture(_ key: Key, label name: String, description: TextureDescription) throws -> MTLTexture {
        guard touched.insert(key).inserted else { throw RenderFailure("资源在同一帧被重复租用：\(name)") }
        if let old = textures[key], old.0 == description { return old.1 }
        guard let texture = context.device.makeTexture(descriptor: description.makeDescriptor()) else {
            throw RenderFailure("纹理分配失败：\(name)")
        }
        texture.label = name
        textures[key] = (description, texture)
        return texture
    }
}
