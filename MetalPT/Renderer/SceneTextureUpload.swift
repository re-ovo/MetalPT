import Metal

/// Creates semantic texture views and bindless sampler IDs, retaining sampler state through GPU completion.
struct SceneTextureUpload {
    let textures: [PTTexture]
    let samplers: [MTLSamplerState]
    let handles: [ResourceRegistry.Handle]

    init(context: MetalContext, scene: SceneDescription, registry: ResourceRegistry) throws {
        var table: [PTTexture] = []
        var resources: [ResourceRegistry.Handle] = []
        for (index, source) in scene.textures.enumerated() {
            switch source.source {
            case .image(let id):
                let image = scene.images.first { $0.id == id }!
                var pair: [MTLTexture] = []
                for sRGB in [false, true] {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: sRGB ? .rgba8Unorm_srgb : .rgba8Unorm,
                        width: image.width, height: image.height, mipmapped: true)
                    descriptor.storageMode = .shared
                    descriptor.usage = .shaderRead
                    guard let texture = context.device.makeTexture(descriptor: descriptor) else {
                        throw RenderFailure("图片纹理分配失败")
                    }
                    texture.label = "Texture \(index) \(sRGB ? "sRGB" : "linear")"
                    for (level, mip) in image.mipLevels(sRGB: sRGB).enumerated() {
                        mip.pixels.withUnsafeBytes {
                            texture.replace(
                                region: MTLRegionMake2D(0, 0, mip.width, mip.height), mipmapLevel: level,
                                withBytes: $0.baseAddress!, bytesPerRow: mip.width * 4)
                        }
                    }
                    pair.append(texture)
                    resources.append(registry.insert(texture, name: texture.label!, kind: .texture))
                }
                table.append(
                    PTTexture(linear: pair[0].gpuResourceID._impl, color: pair[1].gpuResourceID._impl))
            case .white, .checker, .stripes:
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba32Float, width: 128, height: 128, mipmapped: true)
                descriptor.storageMode = .shared
                descriptor.usage = .shaderRead
                guard let texture = context.device.makeTexture(descriptor: descriptor) else {
                    throw RenderFailure("程序化纹理分配失败")
                }
                texture.label = "Procedural texture \(index)"
                var pixels: [SIMD4<Float>] = (0..<(128 * 128)).map { p in
                    let value: Float
                    switch source.source {
                    case .white: value = 1
                    case .checker: value = (p % 128 / 8 + p / 128 / 32) % 2 == 0 ? 1 : 0.015
                    case .stripes: value = p % 128 / 8 % 2 == 0 ? 1 : 0.015
                    case .image: preconditionFailure("Image handled above")
                    }
                    return [value, value, value, 1]
                }
                var size = 128
                for level in 0..<texture.mipmapLevelCount {
                    pixels.withUnsafeBytes {
                        texture.replace(
                            region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: level,
                            withBytes: $0.baseAddress!, bytesPerRow: size * 16)
                    }
                    if size > 1 {
                        let next = size / 2
                        pixels = (0..<(next * next)).map { p in
                            let x = (p % next) * 2, y = (p / next) * 2
                            return
                                (pixels[y * size + x] + pixels[y * size + x + 1]
                                + pixels[(y + 1) * size + x] + pixels[(y + 1) * size + x + 1]) * 0.25
                        }
                        size = next
                    }
                }
                resources.append(registry.insert(texture, name: texture.label!, kind: .texture))
                table.append(
                    PTTexture(linear: texture.gpuResourceID._impl, color: texture.gpuResourceID._impl))
            }
        }
        textures = table
        handles = resources
        samplers = try scene.samplers.map { source in
            let descriptor = MTLSamplerDescriptor()
            descriptor.supportArgumentBuffers = true
            descriptor.minFilter = source.minFilter == .nearest ? .nearest : .linear
            descriptor.magFilter = source.magFilter == .nearest ? .nearest : .linear
            switch source.mipFilter {
            case .none: descriptor.mipFilter = .notMipmapped
            case .nearest: descriptor.mipFilter = .nearest
            case .linear: descriptor.mipFilter = .linear
            }
            func address(_ wrap: SceneSampler.Wrap) -> MTLSamplerAddressMode {
                switch wrap {
                case .repeatMode: return .repeat
                case .clamp: return .clampToEdge
                case .mirror: return .mirrorRepeat
                }
            }
            descriptor.sAddressMode = address(source.wrapU)
            descriptor.tAddressMode = address(source.wrapV)
            guard let sampler = context.device.makeSamplerState(descriptor: descriptor) else {
                throw RenderFailure("采样器分配失败")
            }
            return sampler
        }
    }
}
