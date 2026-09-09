import Metal

/// Creates semantic texture views and bindless sampler IDs, retaining sampler state through GPU completion.
struct SceneTextureUpload {
    let textures: [PTTexture]
    let samplers: [MTLSamplerState]
    let handles: [ResourceRegistry.Handle]

    init(
        context: MetalContext, scene: SceneDescription, registry: ResourceRegistry, prepared: Prepared? = nil
    ) throws {
        let ready = try prepared ?? Prepared(device: context.device, scene: scene)
        textures = ready.textures
        samplers = ready.samplers
        handles = ready.allocations.map {
            registry.insert($0, name: $0.label ?? "Scene texture", kind: .texture)
        }
    }

    /// Owns completed immutable texture uploads. The import worker prepares these before UI installation.
    nonisolated struct Prepared {
        let textures: [PTTexture]
        let samplers: [MTLSamplerState]
        let allocations: [MTLTexture]

        init(device: MTLDevice, scene: SceneDescription, checkCancellation: () throws -> Void = {}) throws {
            try checkCancellation()
            var table: [PTTexture] = []
            var resources: [MTLTexture] = []
            let imageByID = Dictionary(uniqueKeysWithValues: scene.images.map { ($0.id, $0) })
            // Material semantics determine which mip chains are needed. One image may need both.
            var colorIDs = Set<TextureID>(), linearIDs = Set<TextureID>()
            for material in scene.materials {
                for binding in [
                    material.baseColorTexture, material.emissiveTexture, material.specularGlossinessTexture,
                ].compactMap({ $0 }) {
                    colorIDs.insert(binding.texture)
                }
                for binding in [
                    material.metallicRoughnessTexture, material.normalTexture, material.occlusionTexture,
                    material.transmissionTexture,
                ].compactMap({ $0 }) {
                    linearIDs.insert(binding.texture)
                }
            }
            guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
                let blit = command.makeBlitCommandEncoder()
            else { throw RenderFailure("纹理上传队列创建失败") }
            command.label = "Scene texture mip generation"
            var ended = false
            defer { if !ended { blit.endEncoding() } }

            for (index, source) in scene.textures.enumerated() {
                try checkCancellation()
                switch source.source {
                case .image(let id):
                    guard let image = imageByID[id] else { throw RenderFailure("纹理引用的图片不存在") }
                    let needsColor = colorIDs.contains(source.id)
                    let needsLinear = linearIDs.contains(source.id)
                    if !needsColor && !needsLinear, let fallback = table.first {
                        table.append(fallback)
                        continue
                    }
                    var pair: [MTLTexture] = []
                    for sRGB in [false, true] where sRGB ? needsColor : needsLinear {
                        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: sRGB ? .rgba8Unorm_srgb : .rgba8Unorm,
                            width: image.width, height: image.height, mipmapped: true)
                        descriptor.storageMode = .shared
                        descriptor.usage = .shaderRead
                        guard let texture = device.makeTexture(descriptor: descriptor) else {
                            throw RenderFailure("图片纹理分配失败")
                        }
                        texture.label = "Texture \(index) \(sRGB ? "sRGB" : "linear")"
                        image.pixels.withUnsafeBytes {
                            texture.replace(
                                region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: image.width * 4)
                        }
                        if texture.mipmapLevelCount > 1 { blit.generateMipmaps(for: texture) }
                        pair.append(texture)
                        resources.append(texture)
                    }
                    table.append(
                        PTTexture(linear: pair[0].gpuResourceID._impl, color: pair.last!.gpuResourceID._impl))
                case .white, .checker, .stripes:
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .rgba32Float, width: 128, height: 128, mipmapped: true)
                    descriptor.storageMode = .shared
                    descriptor.usage = .shaderRead
                    guard let texture = device.makeTexture(descriptor: descriptor) else {
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
                    resources.append(texture)
                    table.append(
                        PTTexture(linear: texture.gpuResourceID._impl, color: texture.gpuResourceID._impl))
                }
            }
            blit.endEncoding()
            ended = true
            try checkCancellation()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw RenderFailure("纹理 mip 生成失败：\(error.localizedDescription)") }
            textures = table
            allocations = resources
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
                guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
                    throw RenderFailure("采样器分配失败")
                }
                return sampler
            }
        }
    }
}
