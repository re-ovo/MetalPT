import Foundation

nonisolated struct SceneID<Tag>: Hashable {
    private let value = UUID()
}
nonisolated enum MeshTag {}
nonisolated enum MaterialTag {}
nonisolated enum NodeTag {}
typealias MeshID = SceneID<MeshTag>
typealias MaterialID = SceneID<MaterialTag>
typealias NodeID = SceneID<NodeTag>

nonisolated enum ImageTag {}
typealias ImageID = SceneID<ImageTag>

nonisolated enum TextureTag {}
nonisolated enum SamplerTag {}
typealias TextureID = SceneID<TextureTag>
typealias SamplerID = SceneID<SamplerTag>
