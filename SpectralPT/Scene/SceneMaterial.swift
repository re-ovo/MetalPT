import simd

/// Typed authoring parameters; packing conventions are confined to the GPU conversion.
struct SceneMaterial {
    enum Surface {
        case diffuse(reflectance: SIMD3<Float>)
        case gold(roughness: Float)
        case dielectric
        case emitter(color: SIMD3<Float>, strength: Float)
    }
    enum Kind: UInt32 { case diffuse, gold, dielectric, emitter }
    var id = MaterialID()
    var surface: Surface = .diffuse(reflectance: SIMD3(repeating: 0.73))
    var texture: Int = 0

    var kind: Kind {
        switch surface {
        case .diffuse: return .diffuse
        case .gold: return .gold
        case .dielectric: return .dielectric
        case .emitter: return .emitter
        }
    }
    var color: SIMD3<Float> {
        switch surface {
        case .diffuse(let color), .emitter(let color, _): return color
        case .gold, .dielectric: return SIMD3(repeating: 1)
        }
    }
    var roughness: Float {
        if case .gold(let roughness) = surface { return roughness }
        return 0
    }
    var emission: Float {
        if case .emitter(_, let strength) = surface { return strength }
        return 0
    }
    var gpu: PTMaterial {
        PTMaterial(
            color: SIMD4(color, 0), optics: [kind == .emitter ? emission : roughness, 0, 0, 0],
            flags: [kind.rawValue, UInt32(clamping: texture), 0, 0])
    }
}
