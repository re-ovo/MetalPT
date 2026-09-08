import Metal
import simd

/// Structural integration checks through the production renderer, including shared meshes and texture tables.
enum EngineValidation {
    static func run(_ renderer: Renderer, output: MTLTexture) async throws -> [String: Any] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw RenderFailure(message) }
        }
        let context = renderer.context
        let registry = ResourceRegistry()
        let buffer = try context.buffer(32, "Handle validation", shared: true)
        let first = registry.insert(buffer, name: "first")
        let snapshot = registry.snapshot()
        try registry.remove(first)
        let second = registry.insert(try context.buffer(32, "Replacement"), name: "second")
        try require(
            first.index == second.index && first.generation != second.generation,
            "Handle recycling lost generation")
        do { _ = try registry.entry(first); throw RenderFailure("Stale handle accepted") } catch let error
            as RenderFailure where error.message == "Stale handle accepted"
        { throw error } catch {}
        try require(snapshot[0].allocation === buffer, "Snapshot did not retain retired resource")

        let graph = RenderGraph()
        var allocated = 0
        let texture = try graph.createTexture(
            "Live texture", description: TextureDescription(width: 16, height: 8)
        ) { description in
            allocated += 1
            return context.device.makeTexture(descriptor: description.makeDescriptor())!
        }
        graph.pass("write", accesses: [.write(texture)], sideEffect: true) { _ in }
        let compiled = try graph.compile()
        try require(allocated == 0, "Graph allocated before compilation")
        let resources = try graph.materialize(compiled)
        try require(
            allocated == 1 && resources.texture(texture).width == 16, "Deferred texture allocation failed")
        let pool = TransientPool(context)
        let growth = TransientPool.Key()
        let small = try pool.buffer(growth, label: "growth", length: 257)
        pool.beginFrame()
        let smaller = try pool.buffer(growth, label: "growth", length: 300)
        pool.beginFrame()
        let large = try pool.buffer(growth, label: "growth", length: 1025)
        try require(small === smaller && large.length >= 1025, "Buffer capacity reuse failed")
        pool.beginFrame()
        pool.trim()
        try require(pool.cachedBytes == 0, "Unused pool resources not retired")

        try await PassBindingValidation.run(context)
        renderer.model.camera = OrbitCamera()
        renderer.model.exposure = 0
        renderer.model.paused = false
        renderer.model.maxDepth = 1
        var fixture = SceneDescription()
        fixture.textures = [.white, .checker, .stripes]
        fixture.materials = [
            SceneMaterial(kind: .emitter, emission: 2),
            SceneMaterial(kind: .emitter, emission: 6, texture: 2),
        ]
        var quad = SceneMesh()
        quad.quad([-0.6, -0.6, 0], [0.6, -0.6, 0], [0.6, 0.6, 0], [-0.6, 0.6, 0], 0)
        fixture.meshes = [quad]
        var left = matrix_identity_float4x4
        left.columns.0.x = 0.8
        left.columns.1.y = 1.1
        left.columns.3 = [-0.85, 1.35, 0, 1]
        var right = matrix_identity_float4x4
        right.columns.0 = [0.9, 0.2, 0, 0]
        right.columns.1 = [-0.1, 0.9, 0, 0]
        right.columns.3 = [0.85, 1.35, -0.2, 1]
        fixture.instances = [
            SceneInstance(mesh: 0, transform: left),
            SceneInstance(mesh: 0, transform: right, materialOverride: 1),
        ]
        func render(_ description: SceneDescription, samples: Int = 1) async throws -> [UInt8] {
            renderer.sceneOverride = description
            for _ in 0..<samples {
                _ = try renderer.render(to: output)
                await renderer.waitForGPU()
                if let error = renderer.model.error { throw RenderFailure(error) }
            }
            return ValidationRunner.readPixels(output)
        }
        let instanced = try await render(fixture)
        try require(
            renderer.lastFrameStats["meshCount"] == 1 && renderer.lastFrameStats["instanceCount"] == 2,
            "Mesh instances did not share a BLAS")
        var baked = fixture
        baked.meshes = []
        baked.instances = []
        for instance in fixture.instances {
            var mesh = quad
            for i in mesh.vertices.indices {
                mesh.vertices[i].position = instance.transform * mesh.vertices[i].position
            }
            if let material = instance.materialOverride {
                for i in mesh.triangles.indices { mesh.triangles[i].indices.w = UInt32(material) }
            }
            _ = baked.addMesh(mesh)
        }
        let bakedPixels = try await render(baked)
        let bakedDifference = difference(instanced, bakedPixels)
        try require(bakedDifference < 0.001, "Instanced and baked transforms disagree")
        var fallback = fixture
        fallback.materials[0].texture = 999
        let fallbackPixels = try await render(fallback)
        try require(fallbackPixels == instanced, "Invalid texture did not use default white slot")
        var changed = fixture
        changed.materials[1].texture = 0
        let whitePixels = try await render(changed)
        try require(
            difference(instanced, whitePixels) > 0.001, "Texture index beyond slot one was not sampled")

        renderer.model.maxDepth = 8
        let cornell = ProceduralScene(kind: .cornell).description
        var invalid = cornell
        invalid.instances[0].transform.columns.0 = .zero
        do { try invalid.validate(); throw RenderFailure("Singular transform accepted") } catch let error
            as RenderFailure where error.message == "Singular transform accepted"
        { throw error } catch {}
        invalid = cornell
        invalid.lights[0].u *= 2
        do { try invalid.validate(); throw RenderFailure("Mismatched area light accepted") } catch let error
            as RenderFailure where error.message == "Mismatched area light accepted"
        { throw error } catch {}
        let lampMesh = cornell.instances[cornell.lights[0].instance].mesh
        invalid = cornell
        invalid.meshes[lampMesh].triangles[1] = invalid.meshes[lampMesh].triangles[0]
        do { try invalid.validate(); throw RenderFailure("Duplicate emitter triangle accepted") } catch let
            error as RenderFailure where error.message == "Duplicate emitter triangle accepted"
        { throw error } catch {}
        invalid = cornell
        for index in invalid.meshes[lampMesh].vertices.indices {
            invalid.meshes[lampMesh].vertices[index].uv = [0.2, 0.2, 0, 0]
        }
        do { try invalid.validate(); throw RenderFailure("Noncanonical emitter UV accepted") } catch let error
            as RenderFailure where error.message == "Noncanonical emitter UV accepted"
        { throw error } catch {}
        var alternate = cornell
        var alternateLamp = SceneMesh()
        let light = cornell.lights[0]
        let o = light.origin, u = light.u, v = light.v
        alternateLamp.triangle(
            o, o + u, o + v, material: UInt32(light.material), uv: [[0, 0], [1, 0], [0, 1]])
        alternateLamp.triangle(
            o + u, o + u + v, o + v, material: UInt32(light.material), uv: [[1, 0], [1, 1], [0, 1]])
        alternate.meshes[lampMesh] = alternateLamp
        try alternate.validate()
        var overlapping = SceneMesh()
        overlapping.triangle(
            o, o + u, o + u + v, material: UInt32(light.material), uv: [[0, 0], [1, 0], [1, 1]])
        overlapping.triangle(
            o, o + u, o + v, material: UInt32(light.material), uv: [[0, 0], [1, 0], [0, 1]])
        invalid = cornell
        invalid.meshes[lampMesh] = overlapping
        do { try invalid.validate(); throw RenderFailure("Overlapping area light accepted") } catch let error
            as RenderFailure where error.message == "Overlapping area light accepted"
        { throw error } catch {}
        let oneLight = try await render(cornell, samples: 8)
        var twoLights = cornell
        let original = cornell.lights[0]
        var secondInstance = cornell.instances[original.instance]
        secondInstance.transform.columns.3.x = 1.25
        let newIndex = twoLights.instances.count
        twoLights.instances.append(secondInstance)
        var secondLight = original
        secondLight.instance = newIndex
        twoLights.lights.append(secondLight)
        let multipleLights = try await render(twoLights, samples: 8)
        try require(
            difference(oneLight, multipleLights) > 0.001, "Multiple lights did not affect illumination")
        let liveTracing = renderer.lastFrameStats["liveResources"]!
        renderer.model.paused = true
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        try require(
            !renderer.lastGraph.contains("intersectPaths") && renderer.lastRadiance == nil,
            "Paused frame retained transient path allocations")
        try require(
            renderer.lastFrameStats["liveResources"]! < liveTracing, "Paused graph failed to cull resources")
        try require(renderer.lastFrameStats["graphCacheHits"]! > 0, "Graph cache never reused topology")
        renderer.model.paused = false
        renderer.sceneOverride = nil
        return [
            "passBindingContracts": true, "emitterContracts": true, "passed": true, "sharedMeshInstances": 2,
            "textureSlots": 3, "lightCount": 2,
            "instancedVsBakedDifference": bakedDifference,
            "graphCacheHits": renderer.lastFrameStats["graphCacheHits"]!,
        ]
    }
    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) / 255
    }
}
