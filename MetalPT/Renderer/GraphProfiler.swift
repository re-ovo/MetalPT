import Metal
import Darwin

/// Optional GPU timestamps. Resolve only after frame completion; profiling adds synchronization overhead.
nonisolated final class GraphProfiler {
    let heap: MTL4CounterHeap
    let names: [String]
    private let nanosecondsPerTick: Double
    init(device: MTLDevice, names: [String]) throws {
        self.names = names
        // Metal 4 heaps on the supported Apple GPU path contain Mach absolute ticks.
        // MTLDevice.sampleTimestamps() returns nanoseconds and must not be used as the heap scale.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
        let descriptor = MTL4CounterHeapDescriptor()
        descriptor.type = .timestamp
        descriptor.count = max(2, names.count * 2)
        heap = try device.makeCounterHeap(descriptor: descriptor)
        heap.label = "Render Graph pass timestamps"
    }
    func begin(_ index: Int, command: MTL4CommandBuffer) {
        command.writeTimestamp(counterHeap: heap, index: index * 2)
    }
    func end(_ index: Int, command: MTL4CommandBuffer) {
        command.writeTimestamp(counterHeap: heap, index: index * 2 + 1)
    }
    func resolve() throws -> [String: Double] {
        guard let data = try heap.resolveCounterRange(0..<(names.count * 2)) else { return [:] }
        return data.withUnsafeBytes { bytes in
            var result: [String: Double] = [:]
            for (index, name) in names.enumerated() {
                let start = bytes.loadUnaligned(fromByteOffset: index * 16, as: UInt64.self)
                let end = bytes.loadUnaligned(fromByteOffset: index * 16 + 8, as: UInt64.self)
                if start > 0, end != UInt64.max, end >= start {
                    result[name] = Double(end - start) * nanosecondsPerTick / 1_000_000
                }
            }
            return result
        }
    }
}
