import simd

nonisolated enum GLTFPresentation {
    /// Normalize only the viewer snapshot; imported mesh coordinates and sharing remain intact.
    static func prepare(_ input: SceneDescription) throws -> SceneDescription {
        var result = input
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        // Transform eight local bound corners per instance; shared vertices are scanned only once.
        let bounds = input.meshes.map { mesh -> (SIMD3<Float>, SIMD3<Float>) in
            var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
            for vertex in mesh.vertices {
                low = simd_min(low, vertex.position.xyz)
                high = simd_max(high, vertex.position.xyz)
            }
            return (low, high)
        }
        for instance in input.instances {
            let (a, b) = bounds[instance.mesh]
            for corner in 0..<8 {
                let local = SIMD4<Float>(
                    corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y,
                    corner & 4 == 0 ? a.z : b.z, 1)
                let point = (instance.transform * local).xyz
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
        }
        let extent = (high - low).max()
        guard extent.isFinite, extent > 0 else { throw RenderFailure("模型包围盒无效") }
        let scale = 2 / extent
        var fit = matrix_identity_float4x4
        fit.columns.0.x = scale; fit.columns.1.y = scale; fit.columns.2.z = scale
        fit.columns.3 = SIMD4(SIMD3<Float>(0, 1.35, 0) - (low + (high - low) * 0.5) * scale, 1)
        for i in result.instances.indices {
            result.instances[i].transform = fit * result.instances[i].transform
        }
        let material = result.materials.count
        result.materials.append(SceneMaterial(emission: .init(strength: 3), doubleSided: true))
        for (origin, u, v) in [
            (SIMD3<Float>(-2, 4, -1), SIMD3<Float>(4, 0, 0), SIMD3<Float>(0, 0, 3)),
            (SIMD3<Float>(-2, 0, 7), SIMD3<Float>(4, 0, 0), SIMD3<Float>(0, 3, 0)),
        ] {
            var light = SceneMesh()
            light.quad(origin, origin + u, origin + u + v, origin + v, 0)
            let instance = result.addMesh(light, materials: [material])
            result.lights.append(
                SceneLight(instance: instance, material: material, origin: origin, u: u, v: v))
        }
        try result.validate()
        return result
    }
}
