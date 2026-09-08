import Foundation
import simd

struct SceneInstance {
    var mesh: Int
    var transform = matrix_identity_float4x4
    /// Mesh-local slot -> scene material index. GPU snapshots resolve this table per instance.
    var materials: [Int] = []
}

struct SceneLight {
    /// Rectangle in the attached instance's local coordinates. Only this emitter is sampled by NEE.
    var instance: Int
    var material: Int
    var origin: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
}

struct SceneDescription {
    var meshes: [SceneMesh] = []
    var instances: [SceneInstance] = []
    var materials: [SceneMaterial] = []
    // Slot zero is always a white fallback.
    var images: [SceneImage] = []
    var samplers: [SceneSampler] = [.nearest]
    var textures: [SceneTexture] = [.white, .checker]
    var lights: [SceneLight] = []

    mutating func addMesh(
        _ mesh: SceneMesh, transform: simd_float4x4 = matrix_identity_float4x4,
        materials bindings: [Int]
    ) -> Int {
        let index = meshes.count
        meshes.append(mesh)
        instances.append(SceneInstance(mesh: index, transform: transform, materials: bindings))
        return instances.count - 1
    }

    func validate() throws {
        guard !textures.isEmpty else {
            throw RenderFailure("场景缺少默认纹理")
        }
        guard case .white = textures[0].source else {
            throw RenderFailure("纹理第零槽必须为白色默认纹理")
        }
        guard !samplers.isEmpty, Set(images.map(\.id)).count == images.count,
            Set(textures.map(\.id)).count == textures.count, Set(samplers.map(\.id)).count == samplers.count
        else {
            throw RenderFailure("缺少默认采样器或图片 ID 重复")
        }
        for texture in textures {
            if case .image(let id) = texture.source, !images.contains(where: { $0.id == id }) {
                throw RenderFailure("纹理引用的图片不存在")
            }
        }
        for material in materials { try material.validate(samplers: Set(samplers.map(\.id))) }
        for m in meshes {
            guard !m.triangles.isEmpty else { throw RenderFailure("空网格") }
            for vertex in m.vertices {
                let fields = [vertex.position, vertex.normal, vertex.uv, vertex.tangent, vertex.color]
                guard
                    fields.allSatisfy({ v in v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite }),
                    vertex.attributes & ~UInt32(31) == 0,
                    vertex.attributes & 1 == 0 || simd_length(vertex.normal.xyz) > 1e-8,
                    vertex.attributes & 2 == 0
                        || (simd_length(vertex.tangent.xyz) > 1e-8 && abs(vertex.tangent.w) == 1),
                    vertex.attributes & 16 == 0 || (vertex.color.min() >= 0 && vertex.color.max() <= 1)
                else { throw RenderFailure("顶点属性、法线或切线无效") }
            }
            for t in m.triangles {
                guard t.indices.x < m.vertices.count, t.indices.y < m.vertices.count,
                    t.indices.z < m.vertices.count
                else {
                    throw RenderFailure("网格索引越界")
                }
            }
        }
        for i in instances {
            let t = i.transform
            guard meshes.indices.contains(i.mesh),
                i.materials.count == meshes[i.mesh].materialSlotCount,
                i.materials.allSatisfy({ materials.indices.contains($0) }),
                t.columns.0.w == 0, t.columns.1.w == 0, t.columns.2.w == 0, t.columns.3.w == 1,
                abs(simd_determinant(t)) > 1e-8,
                [t.columns.0, t.columns.1, t.columns.2, t.columns.3].allSatisfy({
                    $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
                })
            else {
                throw RenderFailure("无效实例或不可逆变换")
            }
        }
        for instance in instances {
            let mesh = meshes[instance.mesh]
            for triangle in mesh.triangles {
                let material = materials[instance.materials[Int(triangle.indices.w)]]
                for binding in material.bindings {
                    let mask = UInt32(4 << binding.texCoord)
                    for index in [triangle.indices.x, triangle.indices.y, triangle.indices.z] {
                        guard mesh.vertices[Int(index)].attributes & mask != 0 else {
                            throw RenderFailure("材质引用了 Primitive 未提供的 UV 集")
                        }
                    }
                }
            }
        }
        var emitters = Set<Int>()
        for light in lights {
            guard instances.indices.contains(light.instance), materials.indices.contains(light.material),
                materials[light.material].emission.strength > 0,
                simd_length(simd_cross(light.u, light.v)).isFinite,
                simd_length(simd_cross(light.u, light.v)) > 1e-8,
                emitters.insert(light.instance).inserted
            else {
                throw RenderFailure("面积灯必须引用独立的有效矩形发光实例")
            }
            let emitter = materials[light.material]
            guard emitter.alphaMode == .opaque, emitter.emissiveTexture?.texCoord ?? 0 == 0 else {
                throw RenderFailure("登记的矩形采样灯需要 OPAQUE 和 UV0 发光纹理")
            }
            let instance = instances[light.instance]
            let mesh = meshes[instance.mesh]
            let corners = [
                light.origin, light.origin + light.u, light.origin + light.u + light.v,
                light.origin + light.v,
            ]
            // Canonical rectangle UVs ensure NEE and surface-hit emission evaluate the same texture.
            let expectedUV: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1]]
            var cornerTriangles: [Set<Int>] = []
            for triangle in mesh.triangles {
                let material = instance.materials[Int(triangle.indices.w)]
                guard material == light.material else { throw RenderFailure("面积灯材质不匹配") }
                let indices = [triangle.indices.x, triangle.indices.y, triangle.indices.z]
                var ids: [Int] = []
                for index in indices {
                    let vertex = mesh.vertices[Int(index)]
                    guard
                        let corner = corners.firstIndex(where: {
                            simd_distance($0, vertex.position.xyz) < 1e-5
                        }),
                        simd_distance(SIMD2(vertex.uv.x, vertex.uv.y), expectedUV[corner]) < 1e-5
                    else {
                        throw RenderFailure("采样灯必须使用完整矩形及规范的 0–1 UV")
                    }
                    ids.append(corner)
                }
                let a = corners[ids[0]], b = corners[ids[1]], c = corners[ids[2]]
                guard Set(ids).count == 3,
                    simd_dot(simd_cross(b - a, c - a), simd_cross(light.u, light.v)) > 0
                else {
                    throw RenderFailure("面积灯三角形重复顶点或绕序错误")
                }
                cornerTriangles.append(Set(ids))
            }
            // Either diagonal is valid, but triangles must be distinct and share a diagonal, not an edge.
            let diagonal =
                cornerTriangles.count == 2 ? cornerTriangles[0].intersection(cornerTriangles[1]) : []
            guard cornerTriangles.count == 2, cornerTriangles[0] != cornerTriangles[1],
                cornerTriangles[0].union(cornerTriangles[1]) == Set(0..<4),
                diagonal == Set([0, 2]) || diagonal == Set([1, 3])
            else {
                throw RenderFailure("采样灯三角形必须恰好覆盖完整矩形")
            }
        }
    }
}
