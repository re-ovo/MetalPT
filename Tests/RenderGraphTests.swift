import Foundation
import Metal

@main struct GraphTests {
    static func main() throws {
        func require(_ b: Bool, _ message: String) {
            precondition(b, message)
        }
        let graph = RenderGraph(), input = graph.resource("import", imported: true), a = graph.resource("a"),
            b = graph.resource("b"), dead = graph.resource("dead")
        graph.pass("produce", accesses: [.read(input), .write(a)]) {
            _ in
        }
        graph.pass("consume", accesses: [.read(a), .write(b)]) {
            _ in
        }
        graph.pass("unused", accesses: [.write(dead)]) {
            _ in
        }
        graph.pass("present", accesses: [.read(b)], sideEffect: true) {
            _ in
        }
        let c = try graph.compile()
        require(c.order == [0, 1, 3], "dead pass culling")
        require(c.barriers[1] != nil && c.barriers[3] != nil, "RAW barriers")
        require(c.lifetimes[a] == 0...1, "lifetime")
        let hazards = RenderGraph(), r = hazards.resource("shared", imported: true)
        hazards.pass("read", accesses: [.read(r)], sideEffect: true) {
            _ in
        }
        hazards.pass("overwrite", accesses: [.write(r)], sideEffect: true) {
            _ in
        }
        hazards.pass("overwrite again", accesses: [.write(r)], sideEffect: true) {
            _ in
        }
        let h = try hazards.compile()
        require(h.barriers[1] != nil && h.barriers[2] != nil, "WAR and WAW barriers")
        let invalid = RenderGraph(), uninitialized = invalid.resource("uninitialized")
        invalid.pass("bad read", accesses: [.read(uninitialized)], sideEffect: true) {
            _ in
        }
        do {
            _ = try invalid.compile()
            fatalError("uninitialized read accepted")
        } catch {
        }
        let cyclic = RenderGraph()
        cyclic.pass("a", accesses: [], sideEffect: true, after: [1]) {
            _ in
        }
        cyclic.pass("b", accesses: [], sideEffect: true, after: [0]) {
            _ in
        }
        do {
            _ = try cyclic.compile()
            fatalError("cycle accepted")
        } catch {
        }
        let asGraph = RenderGraph(), accel = asGraph.resource("AS", kind: .accelerationStructure)
        asGraph.pass("build", accesses: [.write(accel, .accelerationStructure)]) {
            _ in
        }
        asGraph.pass("trace", accesses: [.read(accel, .dispatch)], sideEffect: true) {
            _ in
        }
        let ac = try asGraph.compile()
        require(
            ac.barriers[1]!.from == .accelerationStructure && ac.barriers[1]!.to == .dispatch,
            "AS stage transition")
        require(MemoryLayout<PTPath>.stride == 112 && MemoryLayout<PTFrame>.stride == 112, "shared ABI")
        require(MemoryLayout<PTScene>.stride == 80 && MemoryLayout<PTWork>.stride == 64, "bindless root ABI")
        require(
            MemoryLayout<PTMesh>.stride == 16 && MemoryLayout<PTInstance>.stride == 80, "mesh/instance ABI")
        require(
            MemoryLayout<PTLight>.stride == 80 && MemoryLayout<PTTexture>.stride == 8, "light/texture ABI")
        let lazy = RenderGraph()
        var allocated = 0
        let unusedBuffer = try lazy.createBuffer("dead buffer", description: BufferDescription(length: 4096))
        { _ in
            allocated += 1
            throw RenderGraph.GraphError.invalid("dead buffer allocated")
        }
        let unusedTexture = try lazy.createTexture(
            "dead texture", description: TextureDescription(width: 16, height: 16)
        ) { _ in
            allocated += 1
            throw RenderGraph.GraphError.invalid("dead texture allocated")
        }
        lazy.pass("dead producer", accesses: [.write(unusedBuffer), .write(unusedTexture)]) { _ in }
        lazy.pass("external", accesses: [], sideEffect: true) { _ in }
        let lazyPlan = try lazy.compile()
        let resolved = try lazy.materialize(lazyPlan)
        require(allocated == 0 && resolved.liveAllocations.isEmpty, "culling must precede allocation")
        do { _ = try resolved.buffer(unusedBuffer); fatalError("culled buffer resolved") } catch {}
        let cache = RenderGraph.Cache(capacity: 2)
        _ = try graph.compile(cache: cache)
        let cached = try graph.compile(cache: cache)
        require(cache.hits == 1 && cache.misses == 1 && cached.order == c.order, "structural cache hit")
        graph.pass("new side effect", accesses: [], sideEffect: true) { _ in }
        _ = try graph.compile(cache: cache)
        require(cache.misses == 2, "topology invalidates cache")
        do { _ = try invalid.compile(cache: cache); fatalError("cache bypassed invalid read") } catch {}
        print(
            "RenderGraph and ABI tests passed (culling, RAW/WAR/WAW, lifecycle, invalid read, cycle, AS stages)."
        )
    }
}
