import simd

struct SceneMaterial {
    enum Kind: UInt32 { case diffuse, gold, dielectric, emitter }
    var kind: Kind = .diffuse
    var color = SIMD3<Float>(repeating: 0.73)
    var roughness: Float = 0
    var emission: Float = 0
    var texture: Int = 0

    var gpu: PTMaterial {
        PTMaterial(
            color: SIMD4(color, 0), optics: [kind == .emitter ? emission : roughness, 0, 0, 0],
            flags: [kind.rawValue, UInt32(clamping: texture), 0, 0])
    }
}

struct SceneInstance {
    var mesh: Int
    var transform = matrix_identity_float4x4
    var materialOverride: Int? = nil
}

struct SceneLight {
    /// Rectangle in the attached instance's local coordinates. Only this emitter is sampled by NEE.
    var instance: Int
    var material: Int
    var origin: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
}

enum SceneTexture { case white, checker, stripes }

struct SceneDescription {
    var meshes: [SceneMesh] = []
    var instances: [SceneInstance] = []
    var materials: [SceneMaterial] = []
    // Slot zero is always a white fallback.
    var textures: [SceneTexture] = [.white, .checker]
    var lights: [SceneLight] = []

    mutating func addMesh(
        _ mesh: SceneMesh, transform: simd_float4x4 = matrix_identity_float4x4,
        material: Int? = nil
    ) -> Int {
        let index = meshes.count
        meshes.append(mesh)
        instances.append(SceneInstance(mesh: index, transform: transform, materialOverride: material))
        return instances.count - 1
    }

    func validate() throws {
        guard !meshes.isEmpty, !instances.isEmpty, !materials.isEmpty, !textures.isEmpty else {
            throw RenderFailure("场景缺少几何、实例、材质或默认纹理")
        }
        guard case .white = textures[0] else {
            throw RenderFailure("纹理第零槽必须为白色默认纹理")
        }
        for material in materials {
            guard material.roughness.isFinite, material.roughness >= 0,
                material.emission.isFinite, material.emission >= 0,
                material.color.x.isFinite, material.color.y.isFinite, material.color.z.isFinite
            else {
                throw RenderFailure("材质参数必须为有限值，粗糙度与发光强度不能为负")
            }
        }
        for m in meshes {
            guard !m.triangles.isEmpty else { throw RenderFailure("空网格") }
            guard
                m.vertices.allSatisfy({
                    $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite
                })
            else {
                throw RenderFailure("顶点包含非有限坐标")
            }
            for t in m.triangles {
                guard t.indices.x < m.vertices.count, t.indices.y < m.vertices.count,
                    t.indices.z < m.vertices.count, t.indices.w < materials.count
                else {
                    throw RenderFailure("网格索引越界")
                }
            }
        }
        for i in instances {
            let t = i.transform
            guard meshes.indices.contains(i.mesh),
                i.materialOverride.map({ materials.indices.contains($0) }) ?? true,
                t.columns.0.w == 0, t.columns.1.w == 0, t.columns.2.w == 0, t.columns.3.w == 1,
                abs(simd_determinant(t)) > 1e-8,
                [t.columns.0, t.columns.1, t.columns.2, t.columns.3].allSatisfy({
                    $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
                })
            else {
                throw RenderFailure("无效实例或不可逆变换")
            }
        }
        var emitters = Set<Int>()
        for light in lights {
            guard instances.indices.contains(light.instance), materials.indices.contains(light.material),
                materials[light.material].kind == .emitter,
                simd_length(simd_cross(light.u, light.v)).isFinite,
                simd_length(simd_cross(light.u, light.v)) > 1e-8,
                emitters.insert(light.instance).inserted
            else {
                throw RenderFailure("面积灯必须引用独立的有效矩形发光实例")
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
                let material = instance.materialOverride ?? Int(triangle.indices.w)
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
