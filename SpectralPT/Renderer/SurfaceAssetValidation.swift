import Metal
import simd

/// GPU checks call the same texture, geometry, BSDF and candidate traversal helpers as production passes.
enum SurfaceAssetValidation {
    static func run(_ renderer: Renderer, output: MTLTexture, folder: URL) async throws -> [String: Any] {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw RenderFailure(message) }
        }
        func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tolerance: Float = 0.003) -> Bool {
            simd_length(a - b) < tolerance
        }
        renderer.sceneGraph = nil
        renderer.model.camera = OrbitCamera()
        renderer.model.paused = false
        renderer.model.exposure = 0
        renderer.model.maxDepth = 1
        let image = try SceneImage(
            width: 2, height: 2,
            pixels: [
                128, 64, 192, 128, 255, 0, 0, 255,
                0, 255, 0, 255, 0, 0, 255, 255,
            ])
        let normal = try SceneImage(width: 1, height: 1, pixels: [191, 128, 238, 255])
        var scene = SceneDescription()
        scene.images = [image, normal]
        scene.textures = [.white, .init(source: .image(image.id)), .init(source: .image(normal.id))]
        scene.samplers = [
            .nearest, SceneSampler(),
            SceneSampler(minFilter: .nearest, magFilter: .nearest, mipFilter: .none, wrapU: .clamp),
            SceneSampler(minFilter: .nearest, magFilter: .nearest, mipFilter: .none, wrapU: .mirror),
        ]
        let material = SceneMaterial(
            surface: .metallicRoughness(baseColor: [1, 1, 1, 0.8], metallic: 0.6, roughness: 0.8),
            emission: .init(strength: 2), baseColorTexture: .init(texture: scene.textures[1].id),
            metallicRoughnessTexture: .init(texture: scene.textures[1].id),
            emissiveTexture: .init(texture: scene.textures[1].id),
            occlusionTexture: .init(texture: scene.textures[1].id))
        var mapped = material
        mapped.id = MaterialID()
        mapped.normalTexture = .init(texture: scene.textures[2].id)
        scene.materials = [material, mapped]
        var mesh = SceneMesh()
        let vertices = [SIMD3<Float>(-0.5, -0.5, 0), [0.5, -0.5, 0], [0.5, 0.5, 0], [-0.5, 0.5, 0]]
            .enumerated().map { i, p in
                SceneMesh.Vertex(
                    position: SIMD4(p, 1), normal: [0.6, 0, 0.8, 0],
                    uv: [i == 1 || i == 2 ? 1 : 0, i >= 2 ? 1 : 0, 0.75, 0.25],
                    tangent: [0.8, 0, -0.6, 1], color: SIMD4(repeating: 1), attributes: 31)
            }
        try mesh.appendPrimitive(vertices: vertices, indices: [0, 1, 2, 0, 2, 3], materialSlot: 0)
        scene.meshes = [mesh]
        var mirror = matrix_identity_float4x4
        mirror.columns.0.x = -2
        mirror.columns.2.z = 3
        scene.instances = [
            .init(mesh: 0, materials: [0]), .init(mesh: 0, transform: mirror, materials: [0]),
            .init(mesh: 0, materials: [1]),
        ]
        var flat = mesh
        flat.id = MeshID()
        for index in flat.vertices.indices { flat.vertices[index].attributes &= ~UInt32(3) }
        _ = scene.addMesh(flat, materials: [0])
        scene.lights = [
            .init(instance: 1, material: 0, origin: [-0.5, -0.5, 0], u: [1, 0, 0], v: [0, 1, 0])
        ]
        renderer.sceneOverride = scene
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        let values = try await renderer.validateNumerics(kernel: "validateSurfaceAssets", count: 26)
        try require(
            values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite },
            "Surface validation produced nonfinite values")
        func decode(_ byte: Float) -> Float {
            let v = byte / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let color = SIMD4<Float>(decode(128), decode(64), decode(192), 128 / 255)
        let linear = SIMD4<Float>(128, 64, 192, 128) / 255
        let average = (color + SIMD4(1, 0, 0, 1) + SIMD4(0, 1, 0, 1) + SIMD4(0, 0, 1, 1)) / 4
        try require(
            close(values[0], color) && close(values[1], linear), "sRGB/data texture interpretation disagrees")
        try require(close(values[2], average, tolerance: 0.006), "Semantic mip sampling failed")
        try require(close(values[3], [1, 0, 0, 1]), "UV1 not sampled")
        try require(
            close(values[4], color) && close(values[5], [1, 0, 0, 1]) && close(values[6], [1, 0, 0, 1]),
            "Bindless sampler wrap modes failed")
        try require(close(values[7], average), "Linear filtering failed")
        try require(
            close(values[8], [0.8 * linear.y, 0.6 * linear.z, 0.4 * linear.w, linear.x]),
            "MR channels, vertex alpha or occlusion sampling failed")
        try require(close(values[9], SIMD4(color.xyz * 2, 0)), "Emissive color texture failed")
        try require(close(values[10], [0, 0, 1, 0]), "Mirrored geometric normal is reversed")
        let expectedNormal = simd_normalize(SIMD3<Float>(-0.3, 0, 0.8 / 3))
        try require(close(values[11], SIMD4(expectedNormal, 0)), "Inverse-transpose shading normal failed")
        let map = SIMD3<Float>(191, 128, 238) / 255 * 2 - 1
        let expectedMapped = simd_normalize(
            SIMD3<Float>(0.8, 0, -0.6) * map.x + SIMD3<Float>(0, 1, 0) * map.y + SIMD3<Float>(0.6, 0, 0.8)
                * map.z)
        try require(close(values[12], SIMD4(expectedMapped, 0)), "Tangent normal map failed")
        try require(close(values[13], [0, 0, 1, 0]), "Missing normals did not use geometry")
        try require(values[14].max() < 0.00001, "PBR BSDF lost reciprocity")
        for i in 15...17 {
            try require(values[i].min() > 0 && values[i].max() <= 1.025, "PBR white furnace energy failed")
            try require(
                abs(values[i + 3].x - values[i + 3].y) < 0.02, "PBR mixture PDF does not match samples")
        }
        try require(values[21].min() > 0, "Emissive PBR lost its reflection lobe")
        try require(
            close(values[22], [1, 0, 0, 1]) && close(values[23], [1, 0, 0, 1]), "UV transform failed")

        try require(close(values[24], [0, 0, 1, 2]), "Mirrored emitter disagrees with geometric normal")

        try require(
            close(values[25], SIMD4(repeating: 0.8), tolerance: 0.02), "Zero roughness PBR became unstable")
        var reordered = scene
        reordered.materials[0].baseColorTexture!.sampler = scene.samplers[2].id
        reordered.textures = [scene.textures[0], scene.textures[2], scene.textures[1]]
        reordered.samplers = [scene.samplers[0], scene.samplers[2], scene.samplers[1], scene.samplers[3]]
        renderer.sceneOverride = reordered
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        let remapped = try await renderer.validateNumerics(kernel: "validateSurfaceAssets", count: 26)
        try require(
            close(remapped[0], color) && close(remapped[4], [1, 0, 0, 1]),
            "Texture/sampler IDs did not survive table reorder")

        let alphaImage = try SceneImage(width: 2, height: 1, pixels: [255, 255, 255, 0, 255, 255, 255, 255])
        var coverage = SceneDescription()
        coverage.images = [alphaImage]
        coverage.textures = [.white, .init(source: .image(alphaImage.id))]
        let surface = SceneMaterial.Surface.metallicRoughness(
            baseColor: SIMD4(repeating: 1), metallic: 0, roughness: 0.5)
        coverage.materials = [
            SceneMaterial(
                surface: surface, alphaMode: .mask, baseColorTexture: .init(texture: coverage.textures[1].id)),
            SceneMaterial(
                surface: .metallicRoughness(baseColor: [1, 1, 1, 0.5], metallic: 0, roughness: 0.5),
                alphaMode: .blend),
            SceneMaterial(surface: surface), SceneMaterial(surface: surface, doubleSided: true),
        ]
        var plane = SceneMesh()
        plane.quad([-0.5, -0.5, 0], [0.5, -0.5, 0], [0.5, 0.5, 0], [-0.5, 0.5, 0], 0)
        coverage.meshes = [plane]
        for (x, z, material) in [(0, 0, 0), (2, 0, 1), (2, -1, 1), (4, 0, 2), (6, 0, 3), (8, 0, 1)] {
            var transform = matrix_identity_float4x4
            transform.columns.3 = [Float(x), 0, Float(z), 1]
            coverage.instances.append(.init(mesh: 0, transform: transform, materials: [material]))
        }
        renderer.sceneOverride = coverage
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        let alpha = try await renderer.validateNumerics(kernel: "validateCoverage", count: 4)
        try require(close(alpha[0], [1, 0, 0.25, 0.5]), "MASK/BLEND shadow transmittance failed: \(alpha)")
        try require(
            close(alpha[1], [0, 1, 0, 0]) && close(alpha[2], SIMD4(repeating: 1)),
            "Ray/shadow sidedness differs")
        try require(abs(alpha[3].x - 0.75) < 0.03, "Stochastic BLEND coverage is biased")

        var gallery = ProceduralScene(kind: .cornell).description
        gallery.images = [normal]
        gallery.textures.append(.init(source: .image(normal.id)))
        gallery.materials[3].surface = .metallicRoughness(
            baseColor: [0.95, 0.45, 0.18, 1], metallic: 1, roughness: 0.25)
        gallery.materials[4].surface = .metallicRoughness(
            baseColor: [0.12, 0.48, 0.85, 1], metallic: 0.15, roughness: 0.55)
        gallery.materials[4].normalTexture = .init(texture: gallery.textures.last!.id)
        renderer.sceneOverride = gallery
        renderer.model.maxDepth = 8
        for _ in 0..<32 {
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            if let error = renderer.model.error { throw RenderFailure(error) }
        }
        _ = try ValidationRunner.save(output, to: folder.appendingPathComponent("surface-pbr.png"))
        renderer.sceneOverride = nil
        return [
            "passed": true, "textureViews": true, "stableTextureBindings": true, "samplers": true,
            "normalFrames": true,
            "coverage": alpha.map { [$0.x, $0.y, $0.z, $0.w] },
            "whiteFurnace": values[15...17].map { [$0.x, $0.y, $0.z, $0.w] },
            "sampleVsPDF": values[18...20].map { [$0.x, $0.y] }, "gallerySPP": 32,
        ]
    }
}
