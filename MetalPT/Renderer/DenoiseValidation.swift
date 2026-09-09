import Metal

/// Same accumulated sample set with display filtering on/off, plus a higher-spp reference.
enum DenoiseValidation {
    static func run(_ renderer: Renderer, output: MTLTexture, folder: URL) async throws -> [String: Any] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw RenderFailure(message) }
        }
        try await checkEdges(renderer.context)
        try await checkGuides(renderer, output: output)
        try renderer.installImportedScene(ProceduralScene(kind: .cornell).description)
        renderer.model.denoiseEnabled = false
        renderer.model.maxDepth = 8
        renderer.model.denoiseStrength = 0.6
        renderer.model.exposure = 0
        for _ in 0..<8 {
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
        }
        let raw = ValidationRunner.readPixels(output)
        _ = try ValidationRunner.save(output, to: folder.appendingPathComponent("denoise-off.png"))
        let samples = renderer.model.samples
        renderer.model.paused = true
        renderer.model.denoiseEnabled = true
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        try require(renderer.model.samples == samples, "Denoise toggle reset samples")
        try require(
            renderer.lastGraph.contains("Denoise · primary guides")
                && renderer.lastGraph.contains("Denoise · spatial 2"),
            "Denoise passes missing from production graph")
        let filtered = ValidationRunner.readPixels(output)
        _ = try ValidationRunner.save(output, to: folder.appendingPathComponent("denoise-on.png"))
        try require(filtered != raw, "Spatial denoise has no effect")
        renderer.model.denoiseEnabled = false
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        try require(ValidationRunner.readPixels(output) == raw, "Denoise overwrote persistent accumulation")
        try require(!renderer.lastGraph.contains("Denoise ·"), "Disabled denoiser still executes")
        renderer.model.paused = false
        for _ in samples..<256 {
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
        }
        let reference = ValidationRunner.readPixels(output)
        _ = try ValidationRunner.save(output, to: folder.appendingPathComponent("denoise-reference.png"))
        func mse(_ pixels: [UInt8]) -> Double {
            var sum = 0.0
            for i in pixels.indices where i % 4 != 3 {
                let delta = (Double(pixels[i]) - Double(reference[i])) / 255
                sum += delta * delta
            }
            return sum / Double(pixels.count / 4 * 3)
        }
        let rawMSE = mse(raw), filteredMSE = mse(filtered)
        try require(
            filteredMSE < rawMSE, "Denoise increased Cornell display MSE: \(filteredMSE) vs \(rawMSE)")
        // Re-enable after a camera reset while paused: fresh guides/accumulation must be initialized.
        renderer.model.paused = true
        renderer.model.denoiseEnabled = true
        renderer.model.camera.look(15, -5)
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        try require(renderer.model.samples == 1, "Paused camera change did not rebuild denoise inputs")
        if let error = renderer.model.error { throw RenderFailure(error) }
        renderer.model.denoiseEnabled = false
        renderer.model.paused = false
        return [
            "passed": true, "inputSPP": samples, "referenceSPP": 256, "rawDisplayMSE": rawMSE,
            "filteredDisplayMSE": filteredMSE, "preservesAccumulation": true,
            "pausedToggleAndCameraReset": true,
        ]
    }
    private static func checkGuides(_ renderer: Renderer, output: MTLTexture) async throws {
        var fixture = SceneDescription()
        let normal = try SceneImage(width: 1, height: 1, pixels: [218, 128, 218, 255])
        fixture.images = [normal]
        fixture.textures.append(SceneTexture(source: .image(normal.id)))
        fixture.materials = [
            SceneMaterial(
                surface: .metallicRoughness(baseColor: [1, 1, 1, 0.5], metallic: 0, roughness: 0.5),
                alphaMode: .blend, normalTexture: .init(texture: fixture.textures.last!.id)),
            SceneMaterial(),
        ]
        for (index, z) in [Float(1), 0].enumerated() {
            var quad = SceneMesh()
            quad.quad([-1, -1, z], [1, -1, z], [1, 1, z], [-1, 1, z], 0)
            _ = fixture.addMesh(quad, materials: [index])
        }
        renderer.model.denoiseEnabled = false
        for (alpha, mode, front) in [
            (Float(0.5), SceneMaterial.AlphaMode.blend, true),
            (0, .blend, false), (0.25, .mask, false), (0.75, .mask, true),
        ] {
            fixture.materials[0].surface = .metallicRoughness(
                baseColor: [1, 1, 1, alpha], metallic: 0, roughness: 0.5)
            fixture.materials[0].alphaMode = mode
            try renderer.installImportedScene(fixture)
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            let values = try await renderer.validateNumerics(kernel: "validateDenoiseGuide", count: 3)
            guard abs(values[0].x - (front ? 3 : 4)) < 0.00001,
                (values[0].y < 0) == front, values[0].z == 0
            else {
                throw RenderFailure("Denoise guide incorrectly handled alpha coverage: \(values)")
            }
            if alpha == 0.5 {
                guard abs(values[0].w - 0.5) < 0.03, abs(values[1].x) > 0.6,
                    abs(values[1].z) < 0.8, values[2] == SIMD4(0, 0, 1, 0)
                else {
                    throw RenderFailure(
                        "Guide normals were conflated or stochastic transport changed: \(values)")
                }
            }
        }
    }

    /// Isolate each guide: color edge, depth discontinuity, normal discontinuity, protected pixel.
    private static func checkEdges(_ context: MetalContext) async throws {
        let width = 16, height = 8, count = width * height
        var tiltedOutput: [Float] = []
        for mode in 0..<6 {
            let pool = TransientPool(context)
            let graph = RenderGraph()
            var colors: [SIMD4<Float>] = [], normals: [SIMD4<Float>] = [], albedo: [SIMD4<Float>] = []
            for i in 0..<count {
                let right = i % width >= width / 2
                let noise: Float = (i + i / width) % 2 == 0 ? 0.1 : -0.1
                colors.append(SIMD4(repeating: (mode >= 4 ? 0.5 : (right ? 0.8 : 0.2)) + noise))
                normals.append(
                    mode == 4
                        ? SIMD4(0.70710677, 0, 0.70710677, 4)
                        : (mode == 2 && right
                            ? SIMD4(0, 1, 0, 4) : SIMD4(0, 0, 1, mode == 1 && right ? 8 : 4)))
                albedo.append(
                    mode == 0
                        ? (right ? SIMD4(0, 0, 1, 1) : SIMD4(1, 0, 0, 1)) : SIMD4(1, 1, 1, mode == 3 ? -1 : 1)
                )
            }
            func input(_ values: [SIMD4<Float>], _ name: String) throws -> RenderGraph.Resource {
                graph.importResource(name, allocation: try context.upload(values, name))
            }
            let source = try input(colors, "Synthetic noisy input")
            let normal = try input(normals, "Synthetic normal depth")
            let geometry = try input(
                [SIMD4<Float>](repeating: [0, 0, 1, 0], count: count), "Synthetic geometric normals")
            let color = try input(albedo, "Synthetic albedo")
            let destination = try context.buffer(count * 16, "Synthetic filter output", shared: true)
            let result = graph.importResource("Synthetic output", allocation: destination, initialized: false)
            let model = RenderModel()
            model.denoiseStrength = 1.5
            let parameters = FrameParameters(
                model: model, width: width, height: height, sampleIndex: 0, reset: false, validationMode: 0)
            let bindings = try ComputeBindings(
                context: context, pool: pool, keys: FrameSlot.ResourceKeys(), parameters: parameters, depth: 1
            )
            let bound = bindings.allocations.enumerated().map {
                graph.importResource("Binding \($0.offset)", allocation: $0.element)
            }
            let compute = ComputePass(context: context, bindings: bindings, bindingResources: bound)
            compute.add(
                to: graph, kernel: "spatialDenoise",
                work: WorkBindings([
                    .filterInput: .read(source), .filterOutput: .write(result), .normalDepth: .read(normal),
                    .albedoGuide: .read(color), .geometricNormal: .read(geometry),
                ]), tasks: count, sideEffect: true)
            let compiled = try graph.compile()
            let resources = try graph.materialize(compiled)
            let allocator = context.device.makeCommandAllocator()!
            let command = context.device.makeCommandBuffer()!
            let residency = try context.residency(resources.liveAllocations)
            command.beginCommandBuffer(allocator: allocator)
            command.useResidencySet(residency)
            try graph.execute(compiled, resources: resources, on: command)
            command.endCommandBuffer()
            let completion = context.device.makeSharedEvent()!
            context.queue.commit([command])
            context.queue.signalEvent(completion, value: 1)
            while completion.signaledValue < 1 { try await Task.sleep(for: .milliseconds(1)) }
            let values = destination.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
            if mode == 4 {
                tiltedOutput = (0..<count).map { values[$0].x }
            } else if mode == 5 {
                guard (0..<count).allSatisfy({ abs(values[$0].x - tiltedOutput[$0]) < 0.00001 }) else {
                    throw RenderFailure("Shading normals incorrectly changed geometric plane weights")
                }
            } else if mode == 3 {
                guard (0..<count).allSatisfy({ values[$0] == colors[$0] }) else {
                    throw RenderFailure("Protected surface was filtered")
                }
            } else {
                let left = values[4 * width + 7].x, right = values[4 * width + 8].x
                guard abs(left - 0.2) < 0.06, abs(right - 0.8) < 0.06 else {
                    throw RenderFailure(
                        "Denoise guide \(mode) blurred edge or failed noise reduction: \(left), \(right)")
                }
            }
            withExtendedLifetime((bindings, resources, residency, allocator, command)) {}
        }
    }
}
