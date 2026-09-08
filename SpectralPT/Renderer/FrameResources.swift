import Metal

/// Immutable CPU settings for one sample; each bounce receives its own constants.
struct FrameParameters {
    var constants: PTFrame
    var maxDepth: Int {
        Int(constants.settings.x)
    }
    var pixelCount: Int {
        Int(constants.size.x) * Int(constants.size.y)
    }
    var reset: Bool {
        constants.settings.y != 0
    }

    init(model: RenderModel, width: Int, height: Int, sampleIndex: UInt32, reset: Bool, validationMode: Float)
    {
        constants = PTFrame()
        model.camera.fill(&constants, aspect: Float(width) / Float(height))
        constants.size = [UInt32(width), UInt32(height), sampleIndex, 0]
        constants.settings = [UInt32(model.maxDepth), reset ? 1 : 0, model.dispersion ? 1 : 0, 0x1234_5678]
        constants.display = [model.exposure, 0, 0, validationMode]
    }
}

/// Declares transient resources first; only the compiled graph's live resources are materialized.
final class FrameResources {
    struct Handles {
        let pathA, pathB, hits, shadows, sample, counts, indirect: RenderGraph.Resource
    }
    let graph = RenderGraph()
    let parameters: FrameParameters
    let handles: Handles
    let accumulation: RenderGraph.Resource
    let output: RenderGraph.Resource
    let displayColor: RenderGraph.Resource
    let sceneHandles: [ResourceRegistry.Handle: RenderGraph.Resource]
    let bindings: ComputeBindings
    let bindingResources: [RenderGraph.Resource]
    private(set) var resolved: RenderGraph.ResolvedResources?
    private(set) var residency: MTLResidencySet?
    private let sceneSnapshot: [ResourceRegistry.Entry]
    private let scene: BindlessScene
    private let context: MetalContext
    private let pool: TransientPool

    init(
        context: MetalContext, slot: FrameSlot, scene: BindlessScene, sceneBuilt: Bool,
        accumulation: MTLBuffer, output: MTLTexture, parameters: FrameParameters, shouldTrace: Bool
    ) throws {
        self.context = context
        self.pool = slot.pool
        self.scene = scene
        self.parameters = parameters
        sceneSnapshot = scene.resources
        let graph = self.graph
        let pool = slot.pool
        let displayKey = slot.resourceKeys.display
        let n = parameters.pixelCount
        func buffer(_ key: TransientPool.Key, _ name: String, _ length: Int, shared: Bool = false) throws
            -> RenderGraph.Resource
        {
            try graph.createBuffer(name, description: BufferDescription(length: length, shared: shared)) {
                description in
                try pool.buffer(key, label: name, length: description.length, shared: description.shared)
            }
        }
        handles = Handles(
            pathA: try buffer(slot.resourceKeys.pathA, "Path queue A", n * MemoryLayout<PTPath>.stride),
            pathB: try buffer(slot.resourceKeys.pathB, "Path queue B", n * MemoryLayout<PTPath>.stride),
            hits: try buffer(slot.resourceKeys.hits, "Intersections", n * MemoryLayout<PTHit>.stride),
            shadows: try buffer(slot.resourceKeys.shadows, "Shadow queue", n * MemoryLayout<PTShadow>.stride),
            sample: try buffer(slot.resourceKeys.sample, "Sample XYZ", n * 16, shared: true),
            counts: try buffer(slot.resourceKeys.counts, "Queue counters", 32, shared: true),
            indirect: try buffer(slot.resourceKeys.indirect, "Indirect dispatch", 32))
        self.accumulation = graph.importResource(
            "Persistent XYZ", allocation: accumulation, initialized: !parameters.reset)
        self.output = graph.importResource("Drawable", allocation: output, kind: .texture, initialized: false)
        displayColor = try graph.createTexture(
            "Display color",
            description: TextureDescription(
                width: output.width, height: output.height, pixelFormat: output.pixelFormat)
        ) { description in
            try pool.texture(displayKey, label: "Display color", description: description)
        }
        var imported: [ResourceRegistry.Handle: RenderGraph.Resource] = [:]
        for entry in sceneSnapshot {
            imported[entry.handle] = graph.importResource(
                entry.name, allocation: entry.allocation,
                kind: entry.kind, initialized: entry.kind == .accelerationStructure ? sceneBuilt : true)
        }
        sceneHandles = imported
        bindings = try ComputeBindings(
            context: context, pool: pool, keys: slot.resourceKeys, parameters: parameters,
            depth: shouldTrace ? parameters.maxDepth : 1)
        bindingResources = bindings.allocations.enumerated().map {
            graph.importResource("Frame binding \($0.offset)", allocation: $0.element)
        }
    }

    func materialize(_ compiled: RenderGraph.Compiled) throws {
        let resources = try graph.materialize(compiled)
        // All directly and indirectly accessed allocations come from the same graph declarations.
        residency = try context.residency(resources.liveAllocations)
        resolved = resources
        pool.trim()
    }
}
