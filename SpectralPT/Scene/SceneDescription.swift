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
            let normal = simd_cross(light.u, light.v)
            let area = simd_length(normal)
            let triangleAreas = mesh.triangles.map { triangle -> Float in
                let a = mesh.vertices[Int(triangle.indices.x)].position.xyz
                let b = mesh.vertices[Int(triangle.indices.y)].position.xyz
                let c = mesh.vertices[Int(triangle.indices.z)].position.xyz
                let cross = simd_cross(b - a, c - a)
                return simd_dot(cross, normal) > 0 ? simd_length(cross) * 0.5 : -1
            }
            guard area.isFinite, triangleAreas.allSatisfy({ $0 > 0 }),
                abs(triangleAreas.reduce(0, +) - area) < max(1e-5, area * 1e-5),
                mesh.triangles.count == 2,
                mesh.triangles.allSatisfy({ triangle in
                    let material = instance.materialOverride ?? Int(triangle.indices.w)
                    return material == light.material
                        && [triangle.indices.x, triangle.indices.y, triangle.indices.z].allSatisfy { index in
                            corners.contains {
                                simd_distance($0, mesh.vertices[Int(index)].position.xyz) < 1e-5
                            }
                        }
                })
            else {
                throw RenderFailure("采样灯的几何与材质必须匹配关联的矩形实例")
            }
        }
    }
}
