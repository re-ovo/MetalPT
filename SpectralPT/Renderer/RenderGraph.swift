import Foundation
import Metal

/// Declaration order defines versions of mutable resources. Explicit edges may reorder
/// independent passes. All reads must refer to an import or an earlier write.
nonisolated final class RenderGraph {
    struct Resource: Hashable {
        let id: Int
    }
    enum Kind {
        case buffer, texture, accelerationStructure
    }
    struct Access {
        let resource: Resource
        let write: Bool
        let stage: MTLStages
        static func read(_ r: Resource, _ stage: MTLStages = .dispatch) -> Self {
            .init(resource: r, write: false, stage: stage)
        }
        static func write(_ r: Resource, _ stage: MTLStages = .dispatch) -> Self {
            .init(resource: r, write: true, stage: stage)
        }
    }
    struct Pass {
        let name: String
        let accesses: [Access]
        let sideEffect: Bool
        let after: [Int]
        let encode: (MTL4CommandBuffer, ResolvedResources) throws -> Void
    }
    struct Barrier {
        let from: MTLStages
        let to: MTLStages
    }
    struct Compiled {
        let order: [Int]
        let barriers: [Int: Barrier]
        let lifetimes: [Resource: ClosedRange<Int>]
    }
    enum GraphError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self {
            case .invalid(let s): return s
            }
        }
    }
    private var resources: [(String, Kind, Bool)] = []
    private(set) var passes: [Pass] = []
    private var allocations: [Resource: MTLAllocation] = [:]
    private var factories: [Resource: () throws -> MTLAllocation] = [:]
    private var importedObjects: [ObjectIdentifier: Resource] = [:]

    /// Captures no graph, so pass closures can safely resolve only their declared resources.
    struct ResolvedResources {
        fileprivate let allocations: [Resource: MTLAllocation]
        func buffer(_ handle: Resource) throws -> MTLBuffer {
            guard let value = allocations[handle] as? MTLBuffer else {
                throw GraphError.invalid("Buffer was culled, not declared, or has the wrong type")
            }
            return value
        }
        func texture(_ handle: Resource) throws -> MTLTexture {
            guard let value = allocations[handle] as? MTLTexture else {
                throw GraphError.invalid("Texture was culled, not declared, or has the wrong type")
            }
            return value
        }
        var liveAllocations: [MTLAllocation] { Array(allocations.values) }
    }

    func createBuffer(
        _ name: String, description: BufferDescription,
        allocate: @escaping (BufferDescription) throws -> MTLBuffer
    ) throws -> Resource {
        guard description.length > 0 else { throw GraphError.invalid("Invalid buffer size: \(name)") }
        let handle = resource(name)
        factories[handle] = { try allocate(description) }
        return handle
    }

    func createTexture(
        _ name: String, description: TextureDescription,
        allocate: @escaping (TextureDescription) throws -> MTLTexture
    ) throws -> Resource {
        guard description.width > 0, description.height > 0 else {
            throw GraphError.invalid("Invalid texture size: \(name)")
        }
        let handle = resource(name, kind: .texture)
        factories[handle] = { try allocate(description) }
        return handle
    }

    /// Allocate only after dependency compilation and dead-pass elimination.
    func materialize(_ compiled: Compiled) throws -> ResolvedResources {
        var result: [Resource: MTLAllocation] = [:]
        for handle in compiled.lifetimes.keys.sorted(by: { $0.id < $1.id }) {
            if let imported = allocations[handle] {
                result[handle] = imported
            } else if let allocate = factories[handle] {
                result[handle] = try allocate()
            }
        }
        return ResolvedResources(allocations: result)
    }

    final class Cache {
        private var plans: [[String]: Compiled] = [:]
        private var lru: [[String]] = []
        private(set) var hits = 0
        private(set) var misses = 0
        let capacity: Int
        init(capacity: Int = 16) { self.capacity = max(1, capacity) }
        fileprivate func lookup(_ key: [String]) -> Compiled? {
            guard let plan = plans[key] else { misses += 1; return nil }
            hits += 1
            lru.removeAll { $0 == key }; lru.append(key)
            return plan
        }
        fileprivate func store(_ plan: Compiled, key: [String]) {
            if plans[key] == nil, lru.count >= capacity { plans.removeValue(forKey: lru.removeFirst()) }
            plans[key] = plan
            lru.removeAll { $0 == key }; lru.append(key)
        }
    }

    func importResource(
        _ name: String, allocation: MTLAllocation, kind: Kind = .buffer, initialized: Bool = true
    ) -> Resource {
        let identity = ObjectIdentifier(allocation)
        if let existing = importedObjects[identity] { return existing }
        let handle = resource(name, kind: kind, imported: initialized)
        importedObjects[identity] = handle
        allocations[handle] = allocation
        return handle
    }
    func resource(_ name: String, kind: Kind = .buffer, imported: Bool = false) -> Resource {
        resources.append((name, kind, imported))
        return Resource(id: resources.count - 1)
    }
    @discardableResult
    func pass(
        _ name: String, accesses: [Access], sideEffect: Bool = false, after: [Int] = [],
        encode: @escaping (MTL4CommandBuffer) throws -> Void
    ) -> Int {
        pass(name, accesses: accesses, sideEffect: sideEffect, after: after) { command, _ in
            try encode(command)
        }
    }

    @discardableResult
    func pass(
        _ name: String, accesses: [Access], sideEffect: Bool = false, after: [Int] = [],
        encode: @escaping (MTL4CommandBuffer, ResolvedResources) throws -> Void
    ) -> Int {
        passes.append(
            Pass(name: name, accesses: accesses, sideEffect: sideEffect, after: after, encode: encode))
        return passes.count - 1
    }

    func compile(cache: Cache) throws -> Compiled {
        // Includes topology and initialization, excludes dimensions and frame-local allocations.
        var key =
            [String(resources.count)] + resources.flatMap { [$0.0, String(describing: $0.1), String($0.2)] }
        key.append("passes")
        for pass in passes {
            key += [
                pass.name, String(pass.sideEffect), String(describing: pass.after),
                String(pass.accesses.count),
            ]
            for a in pass.accesses {
                key += [String(a.resource.id), String(a.write), String(a.stage.rawValue)]
            }
        }
        if let cached = cache.lookup(key) { return cached }
        let result = try compile()
        cache.store(result, key: key)
        return result
    }

    func compile() throws -> Compiled {
        var dependencies = Array(repeating: Set<Int>(), count: passes.count)
        var producers = dependencies
        var writer: [Resource: Int] = [:], readers: [Resource: Set<Int>] = [:]
        for (i, pass) in passes.enumerated() {
            for predecessor in pass.after {
                guard passes.indices.contains(predecessor) else {
                    throw GraphError.invalid("Invalid dependency: \(pass.name)")
                }
                dependencies[i].insert(predecessor)
                producers[i].insert(predecessor)
            }
            // Process reads first, including read/write declarations on the same resource.
            for a in pass.accesses where !a.write {
                guard resources.indices.contains(a.resource.id) else {
                    throw GraphError.invalid("Invalid resource")
                }
                if let w = writer[a.resource] {
                    dependencies[i].insert(w)
                    producers[i].insert(w)
                } else if !resources[a.resource.id].2 {
                    throw GraphError.invalid(
                        "Uninitialized read: \(resources[a.resource.id].0) in \(pass.name)")
                }
                readers[a.resource, default: []].insert(i)
            }
            for a in pass.accesses where a.write {
                guard resources.indices.contains(a.resource.id) else {
                    throw GraphError.invalid("Invalid resource")
                }
                if let w = writer[a.resource], w != i {
                    dependencies[i].insert(w)
                }
                dependencies[i].formUnion((readers[a.resource] ?? []).subtracting([i]))
                readers[a.resource] = []
                writer[a.resource] = i
            }
        }
        // Detect cycles even in dead code, then cull by value-producing dependencies.
        var allOrder: [Int] = [], pending = Set(passes.indices)
        while !pending.isEmpty {
            guard
                let i = pending.sorted().first(where: {
                    dependencies[$0].isDisjoint(with: pending)
                })
            else {
                throw GraphError.invalid("Render graph contains a dependency cycle")
            }
            pending.remove(i)
            allOrder.append(i)
        }
        var live = Set(
            passes.indices.filter {
                passes[$0].sideEffect
            })
        var stack = Array(live)
        while let i = stack.popLast() {
            for d in producers[i] where live.insert(d).inserted {
                stack.append(d)
            }
        }
        let order = allOrder.filter {
            live.contains($0)
        }
        var barriers: [Int: Barrier] = [:], lifetimes: [Resource: ClosedRange<Int>] = [:]
        var previous: [Resource: [Access]] = [:]
        for (position, i) in order.enumerated() {
            var from: MTLStages = [], to: MTLStages = []
            let grouped = Dictionary(grouping: passes[i].accesses, by: \.resource)
            for (r, accesses) in grouped {
                if let old = previous[r], old.contains(where: \.write) || accesses.contains(where: \.write) {
                    for a in old {
                        from.formUnion(a.stage)
                    }
                    for a in accesses {
                        to.formUnion(a.stage)
                    }
                }
                if accesses.contains(where: \.write) {
                    previous[r] = accesses
                } else {
                    previous[r, default: []].append(contentsOf: accesses)
                }
                lifetimes[r] = (lifetimes[r]?.lowerBound ?? position)...position
            }
            if !from.isEmpty {
                barriers[i] = Barrier(from: from, to: to)
            }
        }
        return Compiled(order: order, barriers: barriers, lifetimes: lifetimes)
    }
    func execute(
        _ compiled: Compiled, resources: ResolvedResources, on command: MTL4CommandBuffer,
        profiler: GraphProfiler? = nil
    ) throws {
        for (position, i) in compiled.order.enumerated() {
            if let b = compiled.barriers[i] {
                guard let encoder = command.makeComputeCommandEncoder() else {
                    throw GraphError.invalid("Barrier encoder allocation failed")
                }
                encoder.label = "Barrier → \(passes[i].name)"
                encoder.barrier(afterStages: b.from, beforeQueueStages: b.to, visibilityOptions: [])
                encoder.endEncoding()
            }
            profiler?.begin(position, command: command)
            // Runtime resolver cannot access undeclared resources, even if another pass made them live.
            let allowed = Set(passes[i].accesses.map(\.resource))
            let scoped = ResolvedResources(
                allocations: resources.allocations.filter { allowed.contains($0.key) })
            try passes[i].encode(command, scoped)
            profiler?.end(position, command: command)
        }
    }
    func dump(_ compiled: Compiled) -> String {
        compiled.order.map {
            i in "\(i): \(passes[i].name)\(compiled.barriers[i] == nil ? "" : " [barrier]")"
        }.joined(separator: "\n") + "\n"
            + compiled.lifetimes.sorted {
                $0.key.id < $1.key.id
            }.map {
                "\(resources[$0.key.id].0): \($0.value)"
            }.joined(separator: "\n")
    }
}
