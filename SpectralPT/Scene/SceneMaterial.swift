import simd

nonisolated struct SceneMaterial {
    enum Surface {
        case diffuse(reflectance: SIMD3<Float>)
        case gold(roughness: Float)
        case dielectric
        case absorbing
        case metallicRoughness(baseColor: SIMD4<Float>, metallic: Float, roughness: Float)
    }
    enum Kind: UInt32 { case diffuse, gold, dielectric, absorbing, metallicRoughness }
    enum AlphaMode: UInt32 { case opaque, mask, blend }
    struct Emission {
        var color = SIMD3<Float>(repeating: 1)
        var strength: Float = 0
    }
    var id = MaterialID()
    var surface: Surface = .diffuse(reflectance: SIMD3(repeating: 0.73))
    var emission = Emission()
    var doubleSided = false
    var alphaMode: AlphaMode = .opaque
    var alphaCutoff: Float = 0.5
    var normalScale: Float = 1
    var occlusionStrength: Float = 1
    var baseColorTexture: TextureBinding?
    var metallicRoughnessTexture: TextureBinding?
    var normalTexture: TextureBinding?
    var emissiveTexture: TextureBinding?
    var occlusionTexture: TextureBinding?

    var kind: Kind {
        switch surface {
        case .diffuse: return .diffuse
        case .gold: return .gold
        case .dielectric: return .dielectric
        case .absorbing: return .absorbing
        case .metallicRoughness: return .metallicRoughness
        }
    }
    var color: SIMD4<Float> {
        switch surface {
        case .diffuse(let color): return SIMD4(color, 1)
        case .metallicRoughness(let color, _, _): return color
        default: return SIMD4(repeating: 1)
        }
    }
    var roughness: Float {
        switch surface {
        case .gold(let roughness), .metallicRoughness(_, _, let roughness): return roughness
        default: return 0
        }
    }
    var metallic: Float {
        if case .metallicRoughness(_, let metallic, _) = surface { return metallic }
        return 0
    }
    var bindings: [TextureBinding] {
        [baseColorTexture, metallicRoughnessTexture, normalTexture, emissiveTexture, occlusionTexture]
            .compactMap { $0 }
    }
    func gpu(textures: [TextureID: Int], samplers: [SamplerID: Int]) -> PTMaterial {
        func binding(_ value: TextureBinding?) -> PTTextureBinding {
            value?.gpu(textures: textures, samplers: samplers) ?? PTTextureBinding()
        }
        return PTMaterial(
            color: color, emission: SIMD4(emission.color, emission.strength),
            optics: [roughness, metallic, normalScale, occlusionStrength],
            coverage: [alphaCutoff, 0, 0, 0],
            flags: [kind.rawValue, alphaMode.rawValue, doubleSided ? 1 : 0, 0],
            baseColorTexture: binding(baseColorTexture),
            metallicRoughnessTexture: binding(metallicRoughnessTexture),
            normalTexture: binding(normalTexture),
            emissiveTexture: binding(emissiveTexture),
            occlusionTexture: binding(occlusionTexture))
    }
    func validate(samplers: Set<SamplerID>) throws {
        guard
            [color.x, color.y, color.z, color.w, emission.color.x, emission.color.y, emission.color.z]
                .allSatisfy(\.isFinite),
            color.min() >= 0, color.max() <= 1,
            roughness.isFinite, (0...1).contains(roughness), metallic.isFinite, (0...1).contains(metallic),
            emission.color.min() >= 0, emission.color.max().isFinite,
            emission.strength.isFinite, emission.strength >= 0,
            normalScale.isFinite, normalScale >= 0, (0...1).contains(occlusionStrength),
            (0...1).contains(alphaCutoff)
        else { throw RenderFailure("材质参数无效") }
        for binding in bindings { try binding.validate(samplers: samplers) }
    }
}
