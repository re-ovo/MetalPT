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
        constants.display = [model.exposure, 0, 12, validationMode]
    }
}

/// Owns frame-local allocations and bindings until the frame slot completes.
final class FrameResources {
    struct Handles {
        let pathA, pathB, hits, shadows, sample, counts, indirect: RenderGraph.Resource
    }

    let graph = RenderGraph()
    let parameters: FrameParameters
    let handles: Handles
    let counts: MTLBuffer
    let radiance: MTLBuffer
    let indirect: MTLBuffer
    let tables: [MTL4ArgumentTable]
    let residency: MTLResidencySet
    private let keepAlive: [Any]

    init(
        context: MetalContext, slot: FrameSlot, scene: BindlessScene, accumulation: MTLBuffer,
        output: MTLTexture, parameters: FrameParameters
    ) throws {
        self.parameters = parameters
        let n = parameters.pixelCount
        let (pathA, input) = try graph.createBuffer("Path queue A", length: n * MemoryLayout<PTPath>.stride) {
            try slot.pool.buffer("Path queue A", length: $0, shared: false)
        }
        let (pathB, next) = try graph.createBuffer("Path queue B", length: n * MemoryLayout<PTPath>.stride) {
            try slot.pool.buffer("Path queue B", length: $0, shared: false)
        }
        let (hitR, hits) = try graph.createBuffer("Intersections", length: n * MemoryLayout<PTHit>.stride) {
            try slot.pool.buffer("Intersections", length: $0, shared: false)
        }
        let (shadowR, shadows) = try graph.createBuffer(
            "Shadow queue", length: n * MemoryLayout<PTShadow>.stride
        ) {
            try slot.pool.buffer("Shadow queue", length: $0, shared: false)
        }
        let (sampleR, radiance) = try graph.createBuffer("Sample XYZ", length: n * 16) {
            try slot.pool.buffer("Sample XYZ", length: $0, shared: true)
        }
        let (countsR, counts) = try graph.createBuffer("Queue counters and diagnostics", length: 32) {
            try slot.pool.buffer("Queue counters and diagnostics", length: $0, shared: true)
        }
        let (indirectR, indirect) = try graph.createBuffer("GPU dispatch arguments", length: 32) {
            try slot.pool.buffer("GPU dispatch arguments", length: $0, shared: false)
        }
        let frames = try slot.pool.buffer(
            "Frame and bounce constants", length: 256 * parameters.maxDepth, shared: true)
        var work = PTWork()
        work.inputPaths = input.gpuAddress
        work.outputPaths = next.gpuAddress
        work.hits = hits.gpuAddress
        work.shadows = shadows.gpuAddress
        work.radiance = radiance.gpuAddress
        work.accumulation = accumulation.gpuAddress
        work.counts = counts.gpuAddress
        work.indirect = indirect.gpuAddress
        let rootA = try context.upload([work], "Work root A")
        work.inputPaths = next.gpuAddress
        work.outputPaths = input.gpuAddress
        let rootB = try context.upload([work], "Work root B")
        var tables: [MTL4ArgumentTable] = []
        for bounce in 0..<parameters.maxDepth {
            var frame = parameters.constants
            frame.size.w = UInt32(bounce)
            frame.lightOrigin = scene.lightOrigin
            frame.lightU = scene.lightU
            frame.lightV = scene.lightV
            frame.lightNormal = scene.lightNormal
            frame.display.y = scene.lightArea
            withUnsafeBytes(of: &frame) {
                frames.contents().advanced(by: bounce * 256).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count)
            }
            tables.append(
                try context.table(
                    scene: scene.root, work: bounce % 2 == 0 ? rootA : rootB, frame: frames,
                    offset: bounce * 256, output: output))
        }
        let allocations: [MTLAllocation] =
            scene.allocations + [
                input, next, hits, shadows, radiance, counts, indirect, frames, rootA, rootB, accumulation,
                output,
            ]
        let residency = try context.residency(allocations)
        keepAlive = [scene, accumulation, residency, tables, rootA, rootB, output]
        self.counts = counts
        self.radiance = radiance
        self.indirect = indirect
        self.tables = tables
        self.residency = residency
        handles = Handles(
            pathA: pathA, pathB: pathB, hits: hitR, shadows: shadowR,
            sample: sampleR, counts: countsR, indirect: indirectR)
    }
}
