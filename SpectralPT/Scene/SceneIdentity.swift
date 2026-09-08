import Foundation

struct SceneID<Tag>: Hashable {
    private let value = UUID()
}
enum MeshTag {}
enum MaterialTag {}
enum NodeTag {}
typealias MeshID = SceneID<MeshTag>
typealias MaterialID = SceneID<MaterialTag>
typealias NodeID = SceneID<NodeTag>

enum ImageTag {}
typealias ImageID = SceneID<ImageTag>

enum TextureTag {}
enum SamplerTag {}
typealias TextureID = SceneID<TextureTag>
typealias SamplerID = SceneID<SamplerTag>
