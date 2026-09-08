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
        let encode: (MTL4CommandBuffer) throws -> Void
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
    /// Creation is backed by a completed-frame pool supplied by the caller. Allocation
    /// reuse spans frames; no two live graph resources alias the same pooled name.
    func createBuffer(_ name: String, length: Int, allocate: (Int) throws -> MTLBuffer) throws -> (
        Resource, MTLBuffer
    ) {
        guard length > 0 else {
            throw GraphError.invalid("Invalid buffer size: \(name)")
        }
        let buffer = try allocate(length)
        let handle = resource(name)
        allocations[handle] = buffer
        return (handle, buffer)
    }
    func importResource(
        _ name: String, allocation: MTLAllocation, kind: Kind = .buffer, initialized: Bool = true
    ) -> Resource {
        let handle = resource(name, kind: kind, imported: initialized)
        allocations[handle] = allocation
        return handle
    }
    func liveAllocations(_ compiled: Compiled) -> [MTLAllocation] {
        compiled.lifetimes.keys.compactMap {
            allocations[$0]
        }
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
        passes.append(
            Pass(name: name, accesses: accesses, sideEffect: sideEffect, after: after, encode: encode))
        return passes.count - 1
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
    func execute(_ compiled: Compiled, on command: MTL4CommandBuffer) throws {
        for i in compiled.order {
            if let b = compiled.barriers[i] {
                guard let encoder = command.makeComputeCommandEncoder() else {
                    throw GraphError.invalid("Barrier encoder allocation failed")
                }
                encoder.label = "Barrier → \(passes[i].name)"
                encoder.barrier(afterStages: b.from, beforeQueueStages: b.to, visibilityOptions: [])
                encoder.endEncoding()
            }
            try passes[i].encode(command)
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
