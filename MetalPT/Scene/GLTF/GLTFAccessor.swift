import Foundation

nonisolated struct GLTFAccessor {
    let container: GLTFContainer
    func decode(_ index: Int, types: [String], components: [Int]) throws -> [[Double]] {
        let accessor = try (container.document.accessors ?? []).gltfElement(index, "accessor")
        guard types.contains(accessor.type), components.contains(accessor.componentType),
            accessor.count >= 0
        else { throw RenderFailure("不支持的 accessor 类型或数量") }
        let count = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][accessor.type]!
        let byteSize = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][accessor.componentType]!
        guard accessor.count <= Int.max / (count * MemoryLayout<Double>.stride) else {
            throw RenderFailure("Accessor 存储长度溢出")
        }
        let elementSize = count * byteSize
        func values(_ bytes: Data, offset: Int, stride: Int, count records: Int) throws -> [[Double]] {
            guard offset >= 0, offset % byteSize == 0, stride >= elementSize, stride % byteSize == 0,
                offset <= bytes.count,
                records == 0
                    || (elementSize <= bytes.count - offset
                        && records - 1 <= (bytes.count - offset - elementSize) / stride)
            else {
                throw RenderFailure("Accessor offset/stride/count 越界或未对齐")
            }
            return try (0..<records).map { i in
                try (0..<count).map { c in
                    let raw = try bytes.gltfUInt(offset + i * stride + c * byteSize, bytes: byteSize)
                    let value: Double
                    switch accessor.componentType {
                    case 5120: value = Double(Int8(bitPattern: UInt8(raw)))
                    case 5122: value = Double(Int16(bitPattern: UInt16(raw)))
                    case 5126: value = Double(Float(bitPattern: raw))
                    default: value = Double(raw)
                    }
                    guard value.isFinite else { throw RenderFailure("Accessor 包含 NaN/Inf") }
                    if accessor.normalized == true {
                        switch accessor.componentType {
                        case 5120: return max(-1, value / 127)
                        case 5121: return value / 255
                        case 5122: return max(-1, value / 32767)
                        case 5123: return value / 65535
                        default: throw RenderFailure("normalized 仅支持 8/16 位整数")
                        }
                    }
                    return value
                }
            }
        }
        var result: [[Double]]
        if let viewID = accessor.bufferView {
            let view = try (container.document.bufferViews ?? []).gltfElement(viewID, "bufferView")
            if let stride = view.byteStride, (!(4...252).contains(stride) || stride % 4 != 0) {
                throw RenderFailure("无效 byteStride")
            }
            guard (view.byteOffset ?? 0) % byteSize == 0, (accessor.byteOffset ?? 0) >= 0,
                (accessor.byteOffset ?? 0) % byteSize == 0
            else { throw RenderFailure("Accessor 未对齐") }
            result = try values(
                container.view(viewID), offset: accessor.byteOffset ?? 0,
                stride: view.byteStride ?? elementSize, count: accessor.count)
        } else {
            guard accessor.byteOffset ?? 0 == 0 else { throw RenderFailure("无 bufferView 的 accessor 不允许偏移") }
            result = Array(repeating: Array(repeating: 0, count: count), count: accessor.count)
        }
        if let sparse = accessor.sparse {
            guard sparse.count > 0, sparse.count <= accessor.count,
                [5121, 5123, 5125].contains(sparse.indices.componentType)
            else { throw RenderFailure("无效 sparse accessor") }
            let indexSize = [5121: 1, 5123: 2, 5125: 4][sparse.indices.componentType]!
            let indexView = try (container.document.bufferViews ?? []).gltfElement(
                sparse.indices.bufferView, "sparse indices")
            let valueView = try (container.document.bufferViews ?? []).gltfElement(
                sparse.values.bufferView, "sparse values")
            guard indexView.byteStride == nil, valueView.byteStride == nil,
                (indexView.byteOffset ?? 0) % indexSize == 0,
                (valueView.byteOffset ?? 0) % byteSize == 0
            else { throw RenderFailure("Sparse bufferView 布局无效") }
            let indices = try container.view(sparse.indices.bufferView)
            let offset = sparse.indices.byteOffset ?? 0
            guard offset >= 0, offset % indexSize == 0 else { throw RenderFailure("Sparse indices 未对齐") }
            guard offset <= indices.count, sparse.count <= (indices.count - offset) / indexSize else {
                throw RenderFailure("Sparse indices 越界")
            }
            let replacements = try values(
                container.view(sparse.values.bufferView), offset: sparse.values.byteOffset ?? 0,
                stride: elementSize, count: sparse.count)
            var previous = -1
            for i in 0..<sparse.count {
                let target = Int(try indices.gltfUInt(offset + i * indexSize, bytes: indexSize))
                guard target > previous, target < accessor.count else {
                    throw RenderFailure("Sparse 索引越界或未严格递增")
                }
                result[target] = replacements[i]
                previous = target
            }
        }
        return result
    }
}
