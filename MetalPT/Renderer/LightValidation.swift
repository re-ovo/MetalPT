import Metal
import simd

/// Production NEE and shadow passes, including immutable light edits with a frame in flight.
enum LightValidation {
    static func run(_ renderer: Renderer, output: MTLTexture, folder: URL) async throws -> [String: Any] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw RenderFailure(message) }
        }
        renderer.sceneGraph = nil
        renderer.model.camera = FPSCamera(position: [0, 0, 4], pitch: 0)
        renderer.model.maxDepth = 1
        renderer.model.paused = false
        renderer.validationMode = 0
        var fixture = SceneDescription()
        fixture.materials = [SceneMaterial(surface: .diffuse(reflectance: [1, 1, 1]))]
        var plane = SceneMesh()
        plane.quad([-3, -3, 0], [3, -3, 0], [3, 3, 0], [-3, 3, 0], 0)
        _ = fixture.addMesh(plane, materials: [0])
        var light = ScenePunctualLight(
            name: "Validation", kind: .point, intensity: 4, position: [0, 0, 2], direction: [0, 0, -1])
        fixture.punctualLights = [light]
        try renderer.installImportedScene(fixture)
        renderer.model.camera = FPSCamera(position: [0, 0, 4], pitch: 0)
        func sample(_ lights: [ScenePunctualLight]) async throws -> Float {
            try renderer.updatePunctualLights(lights)
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            if let error = renderer.model.error { throw RenderFailure(error) }
            let counters = renderer.lastCounters!.contents().bindMemory(to: UInt32.self, capacity: 8)
            try require(counters[3] == 0 && counters[4] == 0, "Analytic light GPU counters")
            let width = Int(Float(output.width) * renderer.model.scale)
            let height = Int(Float(output.height) * renderer.model.scale)
            let values = renderer.lastRadiance!.contents().bindMemory(
                to: SIMD4<Float>.self, capacity: width * height)
            return values[(height / 2) * width + width / 2].x
        }
        let near = try await sample([light])
        try require(abs(near - 1 / .pi) < 0.01, "Point light Lambertian reference")
        _ = try ValidationRunner.save(output, to: folder.appendingPathComponent("light-point.png"))
        var second = light
        second.id = NodeID()
        let doubled = try await sample([light, second])
        try require(abs(doubled / near - 2) < 0.01, "Uniform light selection probability compensation")
        light.position.z = 4
        let far = try await sample([light])
        try require(abs(near / far - 4) < 0.05, "Point light inverse-square attenuation")
        light.position.z = 2
        light.range = 1
        let cutoff = try await sample([light])
        try require(cutoff == 0, "Light range cutoff")
        light.range = 0
        light.kind = .spot
        let spot = try await sample([light])
        try require(abs(spot - near) < 0.01, "Spot cone center")
        _ = try ValidationRunner.save(output, to: folder.appendingPathComponent("light-spot.png"))
        light.direction = [1, 0, 0]
        let outside = try await sample([light])
        try require(outside == 0, "Outside spot cone")
        light.kind = .directional
        light.direction = [0, 0, -1]
        light.intensity = 1
        let directional = try await sample([light])
        try require(abs(directional - 1 / .pi) < 0.01, "Directional light Lambertian reference")
        light.position = [100, -50, 500]
        let translated = try await sample([light])
        try require(abs(translated - directional) < 0.0001, "Directional light ignores position")
        _ = try ValidationRunner.save(output, to: folder.appendingPathComponent("light-directional.png"))
        light.enabled = false
        // Submit an old snapshot, replace lights before completion, then verify the next frame.
        _ = try renderer.render(to: output)
        try renderer.updatePunctualLights([light])
        await renderer.waitForGPU()
        let disabled = try await sample([light])
        try require(disabled == 0, "Disabled light edit")
        try require(!renderer.lastGraph.contains("Build TLAS"), "Light edit unexpectedly rebuilt geometry")
        light.enabled = true
        light.kind = .point
        light.position = [2, 0, 2]
        light.intensity = 4
        let unoccluded = try await sample([light])
        var blocker = SceneMesh()
        blocker.quad([0.7, -0.4, 1], [1.3, -0.4, 1], [1.3, 0.4, 1], [0.7, 0.4, 1], 0)
        fixture.materials[0].doubleSided = true
        _ = fixture.addMesh(blocker, materials: [0])
        fixture.punctualLights = [light]
        try renderer.installImportedScene(fixture)
        renderer.model.camera = FPSCamera(position: [0, 0, 4], pitch: 0)
        let occluded = try await sample([light])
        try require(unoccluded > 0.05 && occluded == 0, "Point light shadow visibility")
        light.kind = .directional
        light.direction = [-1, 0, -1]
        let directionalShadow = try await sample([light])
        try require(directionalShadow == 0, "Infinite directional shadow visibility")
        return [
            "passed": true, "pointNear": near, "pointFar": far, "spotCenter": spot,
            "directional": directional, "rangeCutoff": cutoff, "outsideCone": outside,
            "pointShadow": occluded, "directionalShadow": directionalShadow,
            "lightEditsPreserveGeometry": true,
        ]
    }
}
