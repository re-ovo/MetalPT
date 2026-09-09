import Metal

/// One source for a work-root pointer and its graph access. Unbound fields remain zero.
struct WorkBindings {
    enum Field: Int, CaseIterable {
        case inputPaths, outputPaths, hits, shadows, radiance, accumulation, counts, indirect
        case normalDepth, albedoGuide, filterInput, filterOutput, geometricNormal
        var keyPath: WritableKeyPath<PTWork, UInt64> {
            switch self {
            case .inputPaths: return \.inputPaths
            case .outputPaths: return \.outputPaths
            case .hits: return \.hits
            case .shadows: return \.shadows
            case .radiance: return \.radiance
            case .accumulation: return \.accumulation
            case .counts: return \.counts
            case .indirect: return \.indirect
            case .normalDepth: return \.normalDepth
            case .albedoGuide: return \.albedoGuide
            case .filterInput: return \.filterInput
            case .filterOutput: return \.filterOutput
            case .geometricNormal: return \.geometricNormal
            }
        }
    }
    struct Binding {
        let resource: RenderGraph.Resource
        let reads: Bool
        let writes: Bool
        static func read(_ resource: RenderGraph.Resource) -> Self {
            .init(resource: resource, reads: true, writes: false)
        }
        static func write(_ resource: RenderGraph.Resource) -> Self {
            .init(resource: resource, reads: false, writes: true)
        }
        static func readWrite(_ resource: RenderGraph.Resource) -> Self {
            .init(resource: resource, reads: true, writes: true)
        }
    }
    let fields: [Field: Binding]
    init(_ fields: [Field: Binding]) { self.fields = fields }
    var accesses: [RenderGraph.Access] {
        Field.allCases.flatMap { field -> [RenderGraph.Access] in
            guard let binding = fields[field] else { return [] }
            return (binding.reads ? [.read(binding.resource)] : [])
                + (binding.writes ? [.write(binding.resource)] : [])
        }
    }
    func resolve(_ resources: RenderGraph.ResolvedResources) throws -> PTWork {
        var work = PTWork()
        for field in Field.allCases {
            if let binding = fields[field] {
                work[keyPath: field.keyPath] = try resources.buffer(binding.resource).gpuAddress
            }
        }
        return work
    }
}

struct SceneBindings {
    let root: RenderGraph.Resource
    let dependencies: [RenderGraph.Resource]
    var acceleration: RenderGraph.Resource? = nil
    var accesses: [RenderGraph.Access] {
        ([root] + dependencies + (acceleration.map { [$0] } ?? [])).map { .read($0) }
    }
}
