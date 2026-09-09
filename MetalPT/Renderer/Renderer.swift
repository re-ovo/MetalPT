import Foundation
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    let context: MetalContext
    let model: RenderModel
    private let graphCache = RenderGraph.Cache()
    private(set) var lastFrameStats: [String: Int] = [:]
    private(set) var lastPassTimings: [String: Double] = [:]
    var sceneGraph: SceneGraph? { didSet { sceneKind = nil } }
    var sceneOverride: SceneDescription? { didSet { sceneKind = nil } }
    private var slots: [FrameSlot] = []
    private var slotIndex = 0
    private var scene: BindlessScene?
    private var sceneKind: DemoScene?
    private var sceneBuilt = false
    private var accumulation: MTLBuffer?
    private var size = SIMD2<Int>(0, 0)
    private var sampleIndex: UInt32 = 0
    private var previousCamera = OrbitCamera()
    private var previousDepth = 0, previousReset = -1
    private var generation = 0
    private var firstGraphDump = true
    private(set) var lastCounters: MTLBuffer?
    private(set) var lastRadiance: MTLBuffer?
    private(set) var lastGraph = ""
    var validationMode: Float = 0  // 1: black scene validation

    init(model: RenderModel) throws {
        context = try MetalContext()
        self.model = model
        super.init()
        slots = try (0..<3).map {
            _ in try FrameSlot(context)
        }
        model.gpuName = context.device.name
    }
    /// Allocate the replacement before mutating state; failed imports keep the current snapshot.
    func installImportedScene(_ description: SceneDescription, textures: SceneTextureUpload.Prepared? = nil)
        throws
    {
        let replacement = try BindlessScene(context, description: description, preparedTextures: textures)
        sceneGraph = nil
        sceneOverride = description
        scene = replacement
        sceneKind = model.scene
        sceneBuilt = false
        model.resetCamera()
        model.paused = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    func draw(in view: MTKView) {
        guard model.error == nil, let drawable = view.currentDrawable else {
            return
        }
        do {
            _ = try render(to: drawable.texture, drawable: drawable)
        } catch {
            model.error = error.localizedDescription
        }
    }
    @discardableResult
    func render(to output: MTLTexture, drawable: CAMetalDrawable? = nil) throws -> UInt64? {
        let slot = slots[slotIndex]
        guard !slot.inFlight, context.event.signaledValue >= slot.completedValue else {
            return nil
        }
        slot.retained.removeAll()
        slot.allocator.reset()
        slot.pool.beginFrame()
        let width = max(1, Int(Float(output.width) * model.scale))
        let height = max(1, Int(Float(output.height) * model.scale))
        var reset = false
        if sceneKind != model.scene {
            let description: SceneDescription
            if var graph = sceneGraph {
                description = try graph.compile()
                sceneGraph = graph
            } else {
                var graph = try SceneGraph(
                    description: sceneOverride ?? ProceduralScene(kind: model.scene).description)
                description = try graph.compile()
            }
            scene = try BindlessScene(context, description: description, reusing: sceneBuilt ? scene : nil)
            sceneKind = model.scene
            sceneBuilt = false
            reset = true
        }
        guard let scene else {
            return nil
        }
        if size != SIMD2(width, height) {
            accumulation = try context.buffer(width * height * 16, "Persistent RGB mean")
            size = SIMD2(width, height)
            reset = true
        }
        if previousCamera != model.camera || previousDepth != model.maxDepth
            || previousReset != model.resetToken
        {
            reset = true
        }
        previousCamera = model.camera
        previousDepth = model.maxDepth
        previousReset = model.resetToken
        if reset {
            sampleIndex = 0
            generation += 1
        }
        let shouldTrace = !model.paused || sampleIndex == 0
        let accumulation = accumulation!
        let parameters = FrameParameters(
            model: model, width: width, height: height,
            sampleIndex: sampleIndex, reset: reset, validationMode: validationMode)
        let frame = try FrameResources(
            context: context, slot: slot, scene: scene, sceneBuilt: sceneBuilt,
            accumulation: accumulation, output: output, parameters: parameters, shouldTrace: shouldTrace)
        slot.retained = [frame]
        PathTracingPasses.populate(
            context: context, scene: scene, sceneBuilt: sceneBuilt, frame: frame, shouldTrace: shouldTrace)
        let graph = frame.graph
        let compiled = try graph.compile(cache: graphCache)
        try frame.materialize(compiled)
        let resolved = frame.resolved!
        lastFrameStats = [
            "liveResources": resolved.liveAllocations.count,
            "cachedBytes": slot.pool.cachedBytes,
            "graphCacheHits": graphCache.hits, "graphCacheMisses": graphCache.misses,
            "reusedBLASCount": scene.reusedAccelerationStructures.count,
            "meshCount": scene.meshBuilds.count,
            "instanceCount": scene.tlasDescriptor.instanceCount,
        ]
        let counts = try? resolved.buffer(frame.handles.counts)
        let profiler =
            ProcessInfo.processInfo.environment["SPECTRAL_PROFILE"] == "1"
            ? try GraphProfiler(device: context.device, names: compiled.order.map { graph.passes[$0].name })
            : nil
        lastGraph = try graph.dump(compiled)
        if firstGraphDump && ProcessInfo.processInfo.environment["SPECTRAL_DUMP_GRAPH"] != nil {
            print(lastGraph)
            firstGraphDump = false
        }
        slot.command.beginCommandBuffer(allocator: slot.allocator)
        slot.command.useResidencySet(frame.residency!)
        try graph.execute(compiled, resources: resolved, on: slot.command, profiler: profiler)
        slot.command.endCommandBuffer()
        if context.sequence > 0 {
            context.queue.waitForEvent(context.event, value: context.sequence)
        }
        if let drawable {
            context.queue.waitForDrawable(drawable)
        }
        context.sequence += 1
        let value = context.sequence
        let options = MTL4CommitOptions()
        let currentGeneration = generation
        let completedSPP = Int(sampleIndex) + (shouldTrace ? 1 : 0)
        options.addFeedbackHandler {
            [weak self] feedback in
            let ms = (feedback.gpuEndTime - feedback.gpuStartTime) * 1000
            let failure = feedback.error?.localizedDescription
            Task {
                @MainActor [weak self] in
                guard let self else {
                    return
                }
                slot.inFlight = false
                if let failure {
                    self.model.error = failure
                }
                if self.generation == currentGeneration {
                    self.model.gpuMilliseconds = ms
                    self.model.samples = completedSPP
                    self.model.resolution = "\(width) × \(height)"
                    if let profiler {
                        self.lastPassTimings = (try? profiler.resolve()) ?? [:]
                    }
                    guard let counts else { return }
                    let p = counts.contents().bindMemory(to: UInt32.self, capacity: 8)
                    self.model.diagnostics = "溢出 \(p[3]) · 非有限值 \(p[4])"
                    if p[3] > 0 || p[4] > 0 {
                        self.model.error = "GPU 队列溢出或产生非有限值，请检查验证日志"
                    }
                }
            }
        }
        slot.inFlight = true
        context.queue.commit([slot.command], options: options)
        context.queue.signalEvent(context.event, value: value)
        if let drawable {
            context.queue.signalDrawable(drawable)
            drawable.present()
        }
        slot.completedValue = value
        slotIndex = (slotIndex + 1) % slots.count
        sceneBuilt = true
        if shouldTrace {
            sampleIndex += 1
        }
        lastCounters = counts
        lastRadiance = try? resolved.buffer(frame.handles.sample)
        return value
    }
    func waitForGPU() async {
        while context.event.signaledValue < context.sequence
            || slots.contains(where: {
                $0.inFlight
            })
        {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func validateRGB() async throws -> [SIMD4<Float>] {
        try await validateNumerics(kernel: "validateRGB", count: 4)
    }
    func validateNumerics(kernel: String, count: Int) async throws -> [SIMD4<Float>] {
        await waitForGPU()
        guard let scene else {
            throw RenderFailure("先渲染一个场景")
        }
        let allocator = context.device.makeCommandAllocator()!
        let command = context.device.makeCommandBuffer()!
        let result = try context.buffer(count * 16, "Numerical validation", shared: true)
        var w = PTWork()
        w.radiance = result.gpuAddress
        let root = try context.upload([w], "Validation work")
        let frame = try context.buffer(256, "Validation frame", shared: true)
        let table = try context.table(scene: scene.root, work: root, frame: frame)
        let residency = try context.residency(scene.allocations + [result, root, frame])
        command.beginCommandBuffer(allocator: allocator)
        command.useResidencySet(residency)
        let e = command.makeComputeCommandEncoder()!
        e.setComputePipelineState(context.pipelines[kernel]!)
        e.setArgumentTable(table)
        e.dispatchThreadgroups(
            threadgroupsPerGrid: MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        e.endEncoding()
        command.endCommandBuffer()
        context.queue.commit([command])
        context.sequence += 1
        context.queue.signalEvent(context.event, value: context.sequence)
        await waitForGPU()
        return Array(
            UnsafeBufferPointer(
                start: result.contents().bindMemory(to: SIMD4<Float>.self, capacity: count), count: count))
    }
}
