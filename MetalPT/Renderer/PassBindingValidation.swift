import Metal

/// Exercises two passes wired to different resources in the same command buffer.
enum PassBindingValidation {
    static func run(_ context: MetalContext) async throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw RenderFailure(message) }
        }
        let pool = TransientPool(context)
        let firstKey = TransientPool.Key(), secondKey = TransientPool.Key()
        let a = try pool.buffer(firstKey, label: "same label", length: 32, shared: true)
        let b = try pool.buffer(secondKey, label: "same label", length: 32, shared: true)
        try require(a !== b, "Different pool keys aliased buffers with identical labels")
        do {
            _ = try pool.buffer(firstKey, label: "renamed", length: 32);
            throw RenderFailure("Duplicate lease accepted")
        } catch let error as RenderFailure where error.message == "Duplicate lease accepted" {
            throw error
        } catch {}
        let td = TextureDescription(width: 1, height: 1, pixelFormat: .bgra8Unorm, storageMode: .shared)
        let textureKey = TransientPool.Key()
        let imageA = try pool.texture(textureKey, label: "same label", description: td)
        let imageB = try pool.texture(TransientPool.Key(), label: "same label", description: td)
        try require(imageA !== imageB, "Different pool keys aliased textures with identical labels")
        do {
            _ = try pool.texture(textureKey, label: "renamed", description: td);
            throw RenderFailure("Duplicate texture lease accepted")
        } catch let error as RenderFailure where error.message == "Duplicate texture lease accepted" {
            throw error
        } catch {}

        let aliasGraph = RenderGraph()
        let aliasA = try aliasGraph.createBuffer("a", description: BufferDescription(length: 32)) { _ in a }
        let aliasB = try aliasGraph.createBuffer("b", description: BufferDescription(length: 32)) { _ in a }
        aliasGraph.pass("two logical writes", accesses: [.write(aliasA), .write(aliasB)], sideEffect: true) {
            _ in
        }
        do {
            _ = try aliasGraph.materialize(aliasGraph.compile());
            throw RenderFailure("Undeclared allocation alias accepted")
        } catch let error as RenderFailure where error.message == "Undeclared allocation alias accepted" {
            throw error
        } catch {}

        let graph = RenderGraph()
        let sampleA = try context.upload([SIMD4<Float>(0.1, 0.1, 0.1, 0)], "Sample A")
        let sampleB = try context.upload([SIMD4<Float>(0.6, 0.1, 0.1, 0)], "Sample B")
        let meanA = try context.upload([SIMD4<Float>.zero], "Mean A")
        let meanB = try context.upload([SIMD4<Float>.zero], "Mean B")
        let countBuffer = try context.upload([UInt32](repeating: 0, count: 8), "Counters")
        let sampleAR = graph.importResource("Sample A", allocation: sampleA)
        let sampleBR = graph.importResource("Sample B", allocation: sampleB)
        let meanAR = graph.importResource("Mean A", allocation: meanA)
        let meanBR = graph.importResource("Mean B", allocation: meanB)
        let counts = graph.importResource("Counts", allocation: countBuffer)
        let outputA = graph.importResource("Output A", allocation: imageA, kind: .texture, initialized: false)
        let outputB = graph.importResource("Output B", allocation: imageB, kind: .texture, initialized: false)
        let parameters = FrameParameters(
            model: RenderModel(), width: 1, height: 1, sampleIndex: 0, reset: false, validationMode: 0)
        let bindings = try ComputeBindings(
            context: context, pool: pool, keys: FrameSlot.ResourceKeys(), parameters: parameters, depth: 1)
        let bindingResources = bindings.allocations.enumerated().map {
            graph.importResource("Binding \($0.offset)", allocation: $0.element)
        }
        let compute = ComputePass(context: context, bindings: bindings, bindingResources: bindingResources)
        AccumulationPass.add(
            to: graph, compute: compute,
            resources: .init(sample: sampleAR, accumulation: meanAR, counts: counts), pixels: 1)
        AccumulationPass.add(
            to: graph, compute: compute,
            resources: .init(sample: sampleBR, accumulation: meanBR, counts: counts), pixels: 1)
        DisplayPass.add(to: graph, compute: compute, resources: .init(accumulation: meanAR, output: outputA))
        DisplayPass.add(to: graph, compute: compute, resources: .init(accumulation: meanBR, output: outputB))
        graph.pass("Export both displays", accesses: [.read(outputA), .read(outputB)], sideEffect: true) {
            _ in
        }
        let compiled = try graph.compile()
        let resources = try graph.materialize(compiled)
        do {
            _ = try WorkBindings([.hits: .read(outputA)]).resolve(resources);
            throw RenderFailure("Wrong binding type converted to null")
        } catch let error as RenderFailure where error.message == "Wrong binding type converted to null" {
            throw error
        } catch {}
        let other = RenderGraph()
        let otherResources = try other.materialize(other.compile())
        let command = context.device.makeCommandBuffer()!
        do {
            try graph.execute(compiled, resources: otherResources, on: command);
            throw RenderFailure("Foreign resolved resources accepted")
        } catch let error as RenderFailure where error.message == "Foreign resolved resources accepted" {
            throw error
        } catch {}
        let allocator = context.device.makeCommandAllocator()!
        let residency = try context.residency(resources.liveAllocations)
        command.beginCommandBuffer(allocator: allocator)
        command.useResidencySet(residency)
        try graph.execute(compiled, resources: resources, on: command)
        command.endCommandBuffer()
        let completion = context.device.makeSharedEvent()!
        context.queue.commit([command])
        context.queue.signalEvent(completion, value: 1)
        while completion.signaledValue < 1 { try await Task.sleep(for: .milliseconds(1)) }
        try require(
            meanA.contents().load(as: SIMD4<Float>.self) == sampleA.contents().load(as: SIMD4<Float>.self),
            "First pass read the second pass's binding")
        try require(
            meanB.contents().load(as: SIMD4<Float>.self) == sampleB.contents().load(as: SIMD4<Float>.self),
            "Second pass ignored its resource input")
        try require(
            ValidationRunner.readPixels(imageA) != ValidationRunner.readPixels(imageB),
            "Display passes ignored their distinct inputs or outputs")
        // Validate linear RGB through accumulation, tone mapping and exactly one sRGB encoding.
        func encoded(_ linear: Float) -> Int {
            let mapped = min(
                1, max(0, (linear * (2.51 * linear + 0.03)) / (linear * (2.43 * linear + 0.59) + 0.14)))
            let srgb = mapped <= 0.0031308 ? 12.92 * mapped : 1.055 * pow(mapped, 1 / 2.4) - 0.055
            return Int((srgb * 255).rounded())
        }
        for (image, rgb) in [(imageA, SIMD3<Float>(repeating: 0.1)), (imageB, SIMD3<Float>(0.6, 0.1, 0.1))] {
            let pixel = ValidationRunner.readPixels(image)
            let expected = [encoded(rgb.z), encoded(rgb.y), encoded(rgb.x), 255]
            try require(
                zip(pixel, expected).allSatisfy { abs(Int($0) - $1) <= 1 },
                "RGB display changed channels or applied an incorrect transfer function")
        }
        withExtendedLifetime((bindings, resources, residency, allocator, command)) {}
    }
}
