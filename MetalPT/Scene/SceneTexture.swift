import Foundation
import simd

/// One image can be sampled as sRGB color or linear data without duplicating the CPU asset.
nonisolated struct SceneTexture {
    enum Source: Equatable { case white, checker, stripes, image(ImageID) }
    var id = TextureID()
    var source: Source
    static let white = SceneTexture(source: .white)
    static let checker = SceneTexture(source: .checker)
    static let stripes = SceneTexture(source: .stripes)
}

nonisolated struct SceneSampler: Equatable {
    var id = SamplerID()
    enum Filter: UInt32 { case nearest, linear }
    enum MipFilter: UInt32 { case none, nearest, linear }
    enum Wrap: UInt32 { case repeatMode, clamp, mirror }
    var minFilter: Filter = .linear
    var magFilter: Filter = .linear
    var mipFilter: MipFilter = .linear
    var wrapU: Wrap = .repeatMode
    var wrapV: Wrap = .repeatMode
    static let nearest = SceneSampler(minFilter: .nearest, magFilter: .nearest, mipFilter: .none)
}

nonisolated struct TextureBinding {
    var texture: TextureID
    var sampler: SamplerID?
    var texCoord: Int = 0
    var offset: SIMD2<Float> = .zero
    var scale = SIMD2<Float>(repeating: 1)
    var rotation: Float = 0
    /// Explicit ray texture LOD; footprint-based LOD can replace this without changing asset bindings.
    var lod: Float = 0

    func gpu(textures: [TextureID: Int], samplers: [SamplerID: Int]) -> PTTextureBinding {
        PTTextureBinding(
            indices: [
                UInt32(textures[texture] ?? 0), UInt32(sampler.map { samplers[$0]! } ?? 0), UInt32(texCoord),
                1,
            ],
            transform: SIMD4(offset.x, offset.y, scale.x, scale.y),
            rotationLOD: [cos(rotation), sin(rotation), lod, 0])
    }

    func validate(samplers: Set<SamplerID>) throws {
        guard sampler.map({ samplers.contains($0) }) ?? true, (0...1).contains(texCoord),
            offset.x.isFinite, offset.y.isFinite, scale.x.isFinite, scale.y.isFinite,
            rotation.isFinite, lod.isFinite, lod >= 0
        else {
            throw RenderFailure("无效纹理绑定、采样器或 UV 集；当前支持 TEXCOORD_0/1")
        }
    }
}
