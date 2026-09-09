import Metal

/// Generation-checked CPU handles. Snapshots retain allocations until the owning GPU frame completes.
final class ResourceRegistry {
    struct Handle: Hashable {
        fileprivate let owner: UUID
        let index: Int
        let generation: UInt64
    }
    struct Entry {
        let handle: Handle
        let name: String
        let allocation: MTLAllocation
        let kind: RenderGraph.Kind
    }
    private struct Slot {
        var generation: UInt64 = 0
        var entry: Entry?
    }
    private let identity = UUID()
    private var slots: [Slot] = []
    private var free: [Int] = []

    func insert(_ allocation: MTLAllocation, name: String, kind: RenderGraph.Kind = .buffer) -> Handle {
        let index: Int
        if let reused = free.popLast() { index = reused } else { index = slots.count; slots.append(Slot()) }
        let handle = Handle(owner: identity, index: index, generation: slots[index].generation)
        slots[index].entry = Entry(handle: handle, name: name, allocation: allocation, kind: kind)
        return handle
    }

    func entry(_ handle: Handle) throws -> Entry {
        guard handle.owner == identity, slots.indices.contains(handle.index),
            let entry = slots[handle.index].entry, entry.handle == handle
        else {
            throw RenderFailure("资源句柄已失效或来自其他登记表")
        }
        return entry
    }

    /// Existing frame snapshots keep the old resource alive even after the slot is recycled.
    func remove(_ handle: Handle) throws {
        _ = try entry(handle)
        slots[handle.index].entry = nil
        slots[handle.index].generation &+= 1
        free.append(handle.index)
    }

    func snapshot() -> [Entry] { slots.compactMap(\.entry) }
}
