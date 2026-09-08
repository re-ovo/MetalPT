import simd

struct MeshPrimitive: Equatable {
    /// Range into the flattened triangle index stream (three indices per triangle).
    let indexRange: Range<Int>
    let materialSlot: UInt32
}

extension SceneMesh {
    /// Contiguous slot runs remain coherent even when CPU triangles are edited directly.
    var primitives: [MeshPrimitive] {
        var result: [MeshPrimitive] = []
        var start = 0
        while start < triangles.count {
            let slot = triangles[start].indices.w
            var end = start + 1
            while end < triangles.count && triangles[end].indices.w == slot && !primitiveStarts.contains(end)
            { end += 1 }
            result.append(MeshPrimitive(indexRange: (start * 3)..<(end * 3), materialSlot: slot))
            start = end
        }
        return result
    }

    /// Import-friendly indexed path: preserves vertex sharing within each primitive.
    mutating func appendPrimitive(vertices input: [Vertex], indices: [UInt32], materialSlot: UInt32) throws {
        guard !indices.isEmpty, indices.count % 3 == 0,
            indices.allSatisfy({ $0 < input.count }),
            UInt64(vertices.count) + UInt64(input.count) <= UInt64(UInt32.max)
        else {
            throw RenderFailure("Primitive 必须包含有效的三角形索引")
        }
        let base = UInt32(vertices.count)
        primitiveStarts.insert(triangles.count)
        vertices += input
        for i in stride(from: 0, to: indices.count, by: 3) {
            triangles.append(
                Triangle(indices: [
                    base + indices[i], base + indices[i + 1], base + indices[i + 2], materialSlot,
                ]))
        }
    }
}
