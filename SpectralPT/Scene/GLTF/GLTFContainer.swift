import Foundation

/// Owns input bytes; all unaligned little-endian reads and range checks are centralized here.
nonisolated struct GLTFContainer {
    let document: GLTFDocument
    let buffers: [Data]
    let baseURL: URL

    init(url: URL) throws {
        let data = try Self.read(url)
        try self.init(data: data, baseURL: url.deletingLastPathComponent())
    }
    init(data: Data, baseURL: URL) throws {
        self.baseURL = baseURL
        var json = data
        var binary: Data?
        if try data.count >= 4 && data.gltfUInt(0, bytes: 4) == 0x46546c67 {
            guard data.count >= 20, try data.gltfUInt(4, bytes: 4) == 2,
                try data.gltfUInt(8, bytes: 4) == data.count
            else { throw RenderFailure("无效 GLB 头或长度") }
            var offset = 12, chunk = 0
            while offset < data.count {
                let length = Int(try data.gltfUInt(offset, bytes: 4))
                let type = try data.gltfUInt(offset + 4, bytes: 4)
                guard length % 4 == 0 else { throw RenderFailure("GLB chunk 未按四字节对齐") }
                let payload = try data.gltfSlice(offset + 8, length)
                if chunk == 0 {
                    guard type == 0x4e4f534a else { throw RenderFailure("GLB 首个 chunk 必须为 JSON") }
                    json = payload
                } else if type == 0x004e4942 {
                    guard chunk == 1, binary == nil else { throw RenderFailure("GLB BIN chunk 顺序或数量无效") }
                    binary = payload
                } else if type == 0x4e4f534a {
                    throw RenderFailure("重复的 GLB JSON chunk")
                }
                offset += 8 + length
                chunk += 1
            }
        }
        do { document = try JSONDecoder().decode(GLTFDocument.self, from: json) } catch {
            throw RenderFailure("glTF JSON 解析失败：\(error.localizedDescription)")
        }
        guard document.asset.version == "2.0", document.asset.minVersion.map({ $0 == "2.0" }) ?? true else {
            throw RenderFailure("仅支持 glTF 2.0")
        }
        var loaded: [Data] = []
        for (index, buffer) in (document.buffers ?? []).enumerated() {
            guard buffer.byteLength >= 0 else {
                throw RenderFailure("glTF buffer 长度无效")
            }
            let bytes: Data
            if let uri = buffer.uri {
                bytes = try Self.resolve(uri, baseURL: baseURL)
            } else if index == 0, let binary {
                bytes = binary
            } else {
                throw RenderFailure("glTF buffer 缺少 URI/BIN 数据")
            }
            guard bytes.count >= buffer.byteLength else { throw RenderFailure("glTF buffer 数据不足") }
            if buffer.uri == nil && bytes.count - buffer.byteLength > 3 {
                throw RenderFailure("GLB BIN 填充无效")
            }
            loaded.append(try bytes.gltfSlice(0, buffer.byteLength))
        }
        buffers = loaded
        for view in document.bufferViews ?? [] {
            _ = try buffers.gltfElement(view.buffer, "buffer").gltfSlice(
                view.byteOffset ?? 0, view.byteLength)
        }
    }
    static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw RenderFailure(
                "无法读取 \(url.lastPathComponent)。外部资源需要所在文件夹的读取权限：\(error.localizedDescription)")
        }
    }
    static func resolve(_ uri: String, baseURL: URL) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
                let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            else {
                throw RenderFailure("无效 base64 data URI")
            }
            return data
        }
        guard let components = URLComponents(string: uri), components.scheme == nil, components.host == nil,
            components.query == nil, components.fragment == nil,
            !components.path.hasPrefix("/")
        else { throw RenderFailure("仅支持 glTF 本地相对 URI 和 data URI") }
        let url = baseURL.appendingPathComponent(components.path).standardizedFileURL
            .resolvingSymlinksInPath()
        let directory = baseURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(directory) else { throw RenderFailure("glTF 外部资源必须位于模型文件夹内") }
        return try read(url)
    }
    func view(_ index: Int) throws -> Data {
        let view = try (document.bufferViews ?? []).gltfElement(index, "bufferView")
        return try buffers.gltfElement(view.buffer, "buffer").gltfSlice(view.byteOffset ?? 0, view.byteLength)
    }
}

nonisolated extension Data {
    func gltfSlice(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw RenderFailure("glTF 二进制范围越界")
        }
        return subdata(in: offset..<(offset + length))
    }
    func gltfUInt(_ offset: Int, bytes: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count, bytes <= count - offset else {
            throw RenderFailure("glTF 数值读取越界")
        }
        var result: UInt32 = 0
        for i in 0..<bytes { result |= UInt32(self[startIndex + offset + i]) << (i * 8) }
        return result
    }
}
