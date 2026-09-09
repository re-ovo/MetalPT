import Foundation
import simd

/// Static glTF assets retain mesh sharing and material slots through the scene compiler.
nonisolated struct GLTFImporter {
    let container: GLTFContainer
    var document: GLTFDocument { container.document }

    static let supportedExtensions: Set<String> = [
        "KHR_texture_transform", "KHR_materials_emissive_strength", "KHR_materials_transmission",
        "KHR_materials_pbrSpecularGlossiness",
    ]
    func load(reportWarning: (String) -> Void = { _ in }, checkCancellation: () throws -> Void = {}) throws
        -> SceneDescription
    {
        var invalidTangents = 0
        try checkCancellation()
        let missing = Set(document.extensionsRequired ?? []).subtracting(Self.supportedExtensions)
        guard missing.isEmpty else {
            throw RenderFailure("不支持必需扩展：\(missing.sorted().joined(separator: ", "))")
        }
        var graph = SceneGraph()
        graph.samplers = [SceneSampler()]
        for sampler in document.samplers ?? [] {
            func wrap(_ value: Int?) throws -> SceneSampler.Wrap {
                switch value ?? 10497 {
                case 10497: return .repeatMode
                case 33071: return .clamp
                case 33648: return .mirror
                default: throw RenderFailure("无效 glTF wrap 模式")
                }
            }
            let min = sampler.minFilter ?? 9987
            guard [9728, 9729, 9984, 9985, 9986, 9987].contains(min),
                [9728, 9729].contains(sampler.magFilter ?? 9729)
            else { throw RenderFailure("无效 glTF filter") }
            graph.samplers.append(
                SceneSampler(
                    minFilter: [9728, 9984, 9986].contains(min) ? .nearest : .linear,
                    magFilter: sampler.magFilter == 9728 ? .nearest : .linear,
                    mipFilter: min < 9984 ? .none : (min < 9986 ? .nearest : .linear),
                    wrapU: try wrap(sampler.wrapS), wrapV: try wrap(sampler.wrapT)))
        }
        for image in document.images ?? [] {
            try checkCancellation()
            let bytes: Data
            if let uri = image.uri, image.bufferView == nil {
                bytes = try GLTFContainer.resolve(uri, baseURL: container.baseURL)
            } else if let view = image.bufferView, image.uri == nil {
                bytes = try container.view(view)
            } else {
                throw RenderFailure("图片必须引用 URI 或 bufferView")
            }
            graph.images.append(try SceneImage(encoded: bytes))
        }
        for texture in document.textures ?? [] {
            guard let source = texture.source else { throw RenderFailure("纹理缺少标准图片 source") }
            graph.textures.append(
                SceneTexture(source: .image(try graph.images.gltfElement(source, "image").id)))
        }
        func binding(_ info: GLTFDocument.TextureInfo?) throws -> TextureBinding? {
            guard let info else { return nil }
            let texture = try (document.textures ?? []).gltfElement(info.index, "texture")
            let transform = info.extensions?.KHR_texture_transform
            let offset = try vector(transform?.offset, count: 2, fallback: [0, 0])
            let scale = try vector(transform?.scale, count: 2, fallback: [1, 1])
            let sampler = try texture.sampler.map { index in
                _ = try (document.samplers ?? []).gltfElement(index, "sampler")
                return graph.samplers[index + 1].id
            }
            return TextureBinding(
                texture: graph.textures[info.index + 2].id, sampler: sampler,
                texCoord: transform?.texCoord ?? info.texCoord ?? 0,
                offset: [offset[0], offset[1]], scale: [scale[0], scale[1]],
                rotation: transform?.rotation ?? 0)
        }
        for material in document.materials ?? [] {
            let pbr = material.pbrMetallicRoughness
            let color = try vector(pbr?.baseColorFactor, count: 4, fallback: [1, 1, 1, 1])
            let emission = try vector(material.emissiveFactor, count: 3, fallback: [0, 0, 0])
            var result = SceneMaterial(
                surface: .metallicRoughness(
                    baseColor: SIMD4(color),
                    metallic: pbr?.metallicFactor ?? 1, roughness: pbr?.roughnessFactor ?? 1))
            result.emission = .init(
                color: SIMD3(emission),
                strength: material.extensions?.KHR_materials_emissive_strength?.emissiveStrength ?? 1)
            result.doubleSided = material.doubleSided ?? false
            switch material.alphaMode ?? "OPAQUE" {
            case "OPAQUE": result.alphaMode = .opaque
            case "MASK": result.alphaMode = .mask
            case "BLEND": result.alphaMode = .blend
            default: throw RenderFailure("无效 alphaMode")
            }
            result.transmissionFactor =
                material.extensions?.KHR_materials_transmission?.transmissionFactor ?? 0
            result.transmissionTexture = try binding(
                material.extensions?.KHR_materials_transmission?.transmissionTexture)
            result.alphaCutoff = material.alphaCutoff ?? 0.5
            result.normalScale = material.normalTexture?.scale ?? 1
            result.occlusionStrength = material.occlusionTexture?.strength ?? 1
            result.baseColorTexture = try binding(pbr?.baseColorTexture)
            result.metallicRoughnessTexture = try binding(pbr?.metallicRoughnessTexture)
            result.normalTexture = try binding(material.normalTexture)
            result.emissiveTexture = try binding(material.emissiveTexture)
            result.occlusionTexture = try binding(material.occlusionTexture)
            // The SG extension takes precedence over the core MR fallback.
            if let sg = material.extensions?.KHR_materials_pbrSpecularGlossiness {
                let diffuse = try vector(sg.diffuseFactor, count: 4, fallback: [1, 1, 1, 1])
                let specular = try vector(sg.specularFactor, count: 3, fallback: [1, 1, 1])
                result.surface = .specularGlossiness(
                    diffuse: SIMD4(diffuse), specular: SIMD3(specular), glossiness: sg.glossinessFactor ?? 1)
                result.baseColorTexture = try binding(sg.diffuseTexture)
                result.metallicRoughnessTexture = nil
                result.specularGlossinessTexture = try binding(sg.specularGlossinessTexture)
            }
            graph.materials.append(result)
        }
        let defaultMaterial = SceneMaterial(
            surface: .metallicRoughness(baseColor: SIMD4(repeating: 1), metallic: 1, roughness: 1))
        graph.materials.append(defaultMaterial)
        var slots: [[MaterialID]] = []
        let reader = GLTFAccessor(container: container)
        for source in document.meshes ?? [] {
            try checkCancellation()
            var mesh = SceneMesh()
            var materials: [MaterialID] = []
            for primitive in source.primitives {
                try checkCancellation()
                guard primitive.targets?.isEmpty ?? true else { throw RenderFailure("暂不支持 morph targets") }
                guard let position = primitive.attributes["POSITION"] else {
                    throw RenderFailure("primitive 缺少 POSITION")
                }
                let positionAccessor = try (document.accessors ?? []).gltfElement(position, "POSITION")
                guard positionAccessor.count > 0, positionAccessor.count <= UInt32.max else {
                    throw RenderFailure("顶点为空或超过 GPU UInt32 索引范围")
                }
                let positions = try reader.decode(position, types: ["VEC3"], components: [5126])
                var vertices = positions.map {
                    SceneMesh.Vertex(
                        position: [Float($0[0]), Float($0[1]), Float($0[2]), 1], normal: .zero, uv: .zero,
                        attributes: 0)
                }
                for (name, types, components, flag) in [
                    ("NORMAL", ["VEC3"], [5126], UInt32(1)), ("TANGENT", ["VEC4"], [5126], UInt32(2)),
                    ("TEXCOORD_0", ["VEC2"], [5121, 5123, 5126], UInt32(4)),
                    ("TEXCOORD_1", ["VEC2"], [5121, 5123, 5126], UInt32(8)),
                    ("COLOR_0", ["VEC3", "VEC4"], [5121, 5123, 5126], UInt32(16)),
                ] {
                    guard let index = primitive.attributes[name] else { continue }
                    let accessor = try (document.accessors ?? []).gltfElement(index, "accessor")
                    guard accessor.componentType == 5126 || accessor.normalized == true else {
                        throw RenderFailure("\(name) 整数属性必须 normalized")
                    }
                    let values = try reader.decode(
                        index, types: types, components: components, allowNonFinite: name == "TANGENT")
                    guard values.count == vertices.count else { throw RenderFailure("顶点属性数量不一致") }
                    for i in vertices.indices {
                        let v = values[i].map(Float.init)
                        if name == "TANGENT" {
                            let direction = SIMD3<Float>(v[0], v[1], v[2])
                            let length = simd_length(direction)
                            // Keep finite defaults but omit the attribute, so affected triangles use UV derivatives.
                            guard v.allSatisfy(\.isFinite), length.isFinite, length > 1e-8, abs(v[3]) == 1
                            else {
                                invalidTangents += 1
                                continue
                            }
                        }
                        vertices[i].attributes |= flag
                        switch name {
                        case "NORMAL": vertices[i].normal = [v[0], v[1], v[2], 0]
                        case "TANGENT": vertices[i].tangent = SIMD4(v)
                        case "TEXCOORD_0": vertices[i].uv.x = v[0]; vertices[i].uv.y = v[1]
                        case "TEXCOORD_1": vertices[i].uv.z = v[0]; vertices[i].uv.w = v[1]
                        default: vertices[i].color = [v[0], v[1], v[2], v.count == 4 ? v[3] : 1]
                        }
                    }
                }
                var indices = Array(0..<UInt32(vertices.count))
                if let index = primitive.indices {
                    guard try (document.accessors ?? []).gltfElement(index, "indices").normalized != true
                    else { throw RenderFailure("indices 不能 normalized") }
                    indices = try reader.decode(index, types: ["SCALAR"], components: [5121, 5123, 5125]).map
                    { UInt32($0[0]) }
                }
                switch primitive.mode ?? 4 {
                case 4: break
                case 5, 6:
                    guard indices.count >= 3 else { throw RenderFailure("三角带顶点不足") }
                    let original = indices
                    indices = (2..<original.count).flatMap { i -> [UInt32] in
                        if primitive.mode == 6 { return [original[0], original[i - 1], original[i]] }
                        return i % 2 == 0
                            ? [original[i - 2], original[i - 1], original[i]]
                            : [original[i - 1], original[i - 2], original[i]]
                    }
                default: throw RenderFailure("仅支持三角形、三角带和三角扇")
                }
                try mesh.appendPrimitive(
                    vertices: vertices, indices: indices, materialSlot: UInt32(materials.count))
                materials.append(
                    try primitive.material.map {
                        try graph.materials.dropLast().map { $0 }.gltfElement($0, "material").id
                    } ?? defaultMaterial.id)
            }
            graph.meshes.append(mesh)
            slots.append(materials)
        }
        let nodes = document.nodes ?? []
        var roots: [Int]
        if let scene = document.scene ?? ((document.scenes ?? []).isEmpty ? nil : 0) {
            roots = try (document.scenes ?? []).gltfElement(scene, "scene").nodes ?? []
        } else {
            let children = Set(nodes.flatMap { $0.children ?? [] })
            roots = nodes.indices.filter { !children.contains($0) }
        }
        var visited = Set<Int>()
        func append(_ index: Int, parent: NodeID?, depth: Int) throws {
            guard depth < 256, visited.insert(index).inserted else { throw RenderFailure("节点形成环、重复引用或层级过深") }
            let node = try nodes.gltfElement(index, "node")
            guard node.skin == nil else { throw RenderFailure("暂不支持蒙皮模型") }
            let mesh = try node.mesh.map { try graph.meshes.gltfElement($0, "mesh").id }
            let id = try graph.add(
                .init(
                    name: node.name ?? "Node \(index)", parent: parent, mesh: mesh,
                    materials: node.mesh.map { slots[$0] } ?? []))
            try graph.setTransform(try transform(node), for: id)
            for child in node.children ?? [] { try append(child, parent: id, depth: depth + 1) }
        }
        for root in roots { try append(root, parent: nil, depth: 0) }
        try checkCancellation()
        let result = try graph.compile()
        guard !result.instances.isEmpty else { throw RenderFailure("场景没有可渲染的三角形实例") }
        if invalidTangents > 0 {
            reportWarning("已忽略 \(invalidTangents) 条无效切线，受影响三角形改用 UV 重建切线空间")
        }
        return result
    }

    private func vector(_ value: [Float]?, count: Int, fallback: [Float]) throws -> [Float] {
        let value = value ?? fallback
        guard value.count == count, value.allSatisfy(\.isFinite) else { throw RenderFailure("无效 glTF 向量") }
        return value
    }

    private func transform(_ node: GLTFDocument.Node) throws -> simd_float4x4 {
        if let matrix = node.matrix {
            guard node.translation == nil, node.rotation == nil, node.scale == nil else {
                throw RenderFailure("matrix 与 TRS 不能同时存在")
            }
            let m = try vector(matrix, count: 16, fallback: [])
            return simd_float4x4(
                columns: (
                    SIMD4(Array(m[0..<4])), SIMD4(Array(m[4..<8])), SIMD4(Array(m[8..<12])),
                    SIMD4(Array(m[12..<16]))
                ))
        }
        let t = try vector(node.translation, count: 3, fallback: [0, 0, 0])
        let s = try vector(node.scale, count: 3, fallback: [1, 1, 1])
        let r = try vector(node.rotation, count: 4, fallback: [0, 0, 0, 1])
        let quaternion = simd_quatf(vector: SIMD4(r))
        guard abs(simd_length(quaternion.vector) - 1) < 0.001 else { throw RenderFailure("旋转四元数必须归一化") }
        var result = simd_float4x4(quaternion)
        result.columns.0 *= s[0]; result.columns.1 *= s[1]; result.columns.2 *= s[2]
        result.columns.3 = [t[0], t[1], t[2], 1]
        return result
    }
}
