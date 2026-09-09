import Foundation

nonisolated struct GLTFDocument: Decodable {
    struct Asset: Decodable { let version: String; let minVersion: String? }
    struct Scene: Decodable { let nodes: [Int]? }
    struct Node: Decodable {
        let name: String?; let children: [Int]?; let mesh: Int?; let skin: Int?
        let matrix: [Float]?; let translation: [Float]?; let rotation: [Float]?; let scale: [Float]?
    }
    struct Mesh: Decodable {
        struct Primitive: Decodable {
            let attributes: [String: Int]; let indices: Int?; let material: Int?; let mode: Int?
            let targets: [[String: Int]]?
        }
        let primitives: [Primitive]
    }
    struct Buffer: Decodable { let uri: String?; let byteLength: Int }
    struct BufferView: Decodable {
        let buffer: Int; let byteOffset: Int?; let byteLength: Int; let byteStride: Int?
    }
    struct Accessor: Decodable {
        struct Sparse: Decodable {
            struct Indices: Decodable { let bufferView: Int; let byteOffset: Int?; let componentType: Int }
            struct Values: Decodable { let bufferView: Int; let byteOffset: Int? }
            let count: Int; let indices: Indices; let values: Values
        }
        let bufferView: Int?; let byteOffset: Int?; let componentType: Int; let count: Int
        let type: String; let normalized: Bool?; let sparse: Sparse?
    }
    struct Image: Decodable { let uri: String?; let bufferView: Int?; let mimeType: String? }
    struct Texture: Decodable { let source: Int?; let sampler: Int? }
    struct Sampler: Decodable { let minFilter: Int?; let magFilter: Int?; let wrapS: Int?; let wrapT: Int? }
    struct TextureInfo: Decodable {
        struct Extensions: Decodable {
            struct Transform: Decodable {
                let offset: [Float]?; let scale: [Float]?; let rotation: Float?; let texCoord: Int?
            }
            let KHR_texture_transform: Transform?
        }
        let index: Int; let texCoord: Int?; let scale: Float?; let strength: Float?;
        let extensions: Extensions?
    }
    struct Material: Decodable {
        struct PBR: Decodable {
            let baseColorFactor: [Float]?; let metallicFactor: Float?; let roughnessFactor: Float?
            let baseColorTexture: TextureInfo?; let metallicRoughnessTexture: TextureInfo?
        }
        struct Extensions: Decodable {
            struct SpecularGlossiness: Decodable {
                let diffuseFactor: [Float]?
                let specularFactor: [Float]?
                let glossinessFactor: Float?
                let diffuseTexture: TextureInfo?
                let specularGlossinessTexture: TextureInfo?
            }
            let KHR_materials_pbrSpecularGlossiness: SpecularGlossiness?
            struct Strength: Decodable { let emissiveStrength: Float }
            struct Transmission: Decodable {
                let transmissionFactor: Float?
                let transmissionTexture: TextureInfo?
            }
            let KHR_materials_emissive_strength: Strength?
            let KHR_materials_transmission: Transmission?
        }
        let pbrMetallicRoughness: PBR?; let normalTexture: TextureInfo?; let occlusionTexture: TextureInfo?
        let emissiveTexture: TextureInfo?; let emissiveFactor: [Float]?
        let alphaMode: String?; let alphaCutoff: Float?; let doubleSided: Bool?; let extensions: Extensions?
    }
    let asset: Asset
    let scene: Int?; let scenes: [Scene]?; let nodes: [Node]?; let meshes: [Mesh]?
    let buffers: [Buffer]?; let bufferViews: [BufferView]?; let accessors: [Accessor]?
    let images: [Image]?; let textures: [Texture]?; let samplers: [Sampler]?; let materials: [Material]?
    let extensionsRequired: [String]?; let extensionsUsed: [String]?
    // Only the presence matters: imported nodes use their authored static pose.
    let animations: [IgnoredObject]?
    struct IgnoredObject: Decodable {}
}

nonisolated extension Array {
    func gltfElement(_ index: Int, _ context: String) throws -> Element {
        guard indices.contains(index) else { throw RenderFailure("glTF \(context) 索引越界：\(index)") }
        return self[index]
    }
}
