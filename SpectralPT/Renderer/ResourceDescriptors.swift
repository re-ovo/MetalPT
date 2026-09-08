import Metal

nonisolated struct BufferDescription: Hashable {
    let length: Int
    var shared: Bool = false
}

nonisolated struct TextureDescription: Equatable {
    let width: Int
    let height: Int
    var pixelFormat: MTLPixelFormat = .rgba16Float
    var usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
    var storageMode: MTLStorageMode = .private
    var mipmapped: Bool = false

    func makeDescriptor() -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: mipmapped)
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        return descriptor
    }
}
