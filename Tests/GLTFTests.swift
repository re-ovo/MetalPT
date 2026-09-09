import AppKit
import Foundation
import simd

@main enum GLTFTests {
    static func main() throws {
        var binary = Data()
        func word(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                binary.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        for point: [Float] in [[-1, -1, 0], [1, -1, 0], [0, 1, 0]] {
            for value in point { word(value.bitPattern) }
            word(0)  // interleaved padding
        }
        binary.append(contentsOf: [0, 1, 2, 0])
        var json: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]],
            "nodes": [
                ["translation": [0, 2, 0], "children": [1, 2]], ["mesh": 0],
                ["mesh": 0, "translation": [3, 0, 0]],
            ],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1, "material": 0]]]],
            "materials": [
                [
                    "pbrMetallicRoughness": ["baseColorFactor": [0.8, 0.1, 0.05, 1], "metallicFactor": 0],
                    "doubleSided": true,
                ]
            ],
            "buffers": [["byteLength": binary.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 48, "byteStride": 16],
                ["buffer": 0, "byteOffset": 48, "byteLength": 3],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
                ["bufferView": 1, "componentType": 5121, "count": 3, "type": "SCALAR"],
            ],
        ]
        func glb(_ json: [String: Any]) throws -> Data {
            var encoded = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            while encoded.count % 4 != 0 { encoded.append(32) }
            var output = Data()
            func append(_ value: UInt32) {
                for shift in stride(from: 0, to: 32, by: 8) {
                    output.append(UInt8(truncatingIfNeeded: value >> shift))
                }
            }
            append(0x46546c67); append(2); append(UInt32(28 + encoded.count + binary.count))
            append(UInt32(encoded.count)); append(0x4e4f534a); output += encoded
            append(UInt32(binary.count)); append(0x004e4942); output += binary
            return output
        }
        func load(_ json: [String: Any]) throws -> SceneDescription {
            try GLTFImporter(container: GLTFContainer(data: glb(json), baseURL: URL(fileURLWithPath: "/tmp")))
                .load()
        }
        let scene = try load(json)
        assert(scene.meshes.count == 1 && scene.instances.count == 2, "mesh sharing")
        assert(scene.instances[1].transform.columns.3 == SIMD4<Float>(3, 2, 0, 1), "hierarchy TRS")
        assert(scene.meshes[0].vertices[2].position.y == 1, "interleaved accessor")
        try GLTFPresentation.prepare(scene).validate()
        try glb(json).write(to: URL(fileURLWithPath: "/tmp/spectral-import-fixture.glb"))
        func reject(_ body: () throws -> Void) {
            do { try body(); fatalError("invalid asset accepted") } catch {}
        }
        // Normalized UVs/colors and an embedded PNG traverse the bindless texture asset chain.
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let pixels: [UInt8] = [255, 255, 255, 255, 20, 100, 255, 255, 255, 30, 10, 255, 255, 255, 255, 255]
        pixels.withUnsafeBufferPointer { bitmap.bitmapData!.update(from: $0.baseAddress!, count: 16) }
        let png = bitmap.representation(using: .png, properties: [:])!
        var textured = json
        let uvOffset = binary.count
        binary.append(contentsOf: [0, 255, 0, 0, 255, 255, 0, 0, 128, 0, 0, 0])
        let imageOffset = binary.count
        binary += png
        while binary.count % 4 != 0 { binary.append(0) }
        var views = json["bufferViews"] as! [[String: Any]]
        views.append(["buffer": 0, "byteOffset": uvOffset, "byteLength": 12, "byteStride": 4])
        views.append(["buffer": 0, "byteOffset": imageOffset, "byteLength": png.count])
        var accessors = json["accessors"] as! [[String: Any]]
        accessors.append([
            "bufferView": 2, "componentType": 5121, "normalized": true, "count": 3, "type": "VEC2",
        ])
        textured["buffers"] = [["byteLength": binary.count]]
        textured["bufferViews"] = views
        textured["accessors"] = accessors
        textured["images"] = [["bufferView": 3, "mimeType": "image/png"]]
        textured["textures"] = [["source": 0]]
        textured["materials"] = [
            [
                "pbrMetallicRoughness": ["metallicFactor": 0, "baseColorTexture": ["index": 0]],
                "doubleSided": true,
            ]
        ]
        textured["meshes"] = [
            ["primitives": [["attributes": ["POSITION": 0, "TEXCOORD_0": 2], "indices": 1, "material": 0]]]
        ]
        var sgAsset = textured
        sgAsset["extensionsRequired"] = ["KHR_materials_pbrSpecularGlossiness"]
        sgAsset["materials"] = [
            [
                "pbrMetallicRoughness": ["baseColorFactor": [1, 0, 0, 1], "metallicFactor": 1],
                "alphaMode": "MASK", "alphaCutoff": 0.4,
                "extensions": [
                    "KHR_materials_pbrSpecularGlossiness": [
                        "diffuseFactor": [0.2, 0.4, 0.6, 0.8], "specularFactor": [0.1, 0.3, 0.5],
                        "glossinessFactor": 0.7, "diffuseTexture": ["index": 0],
                        "specularGlossinessTexture": [
                            "index": 0, "extensions": ["KHR_texture_transform": ["offset": [0.25, 0.5]]],
                        ],
                    ]
                ],
            ]
        ]
        let sgScene = try load(sgAsset)
        let sg = sgScene.materials[0]
        assert(
            sg.kind == .specularGlossiness && sg.color == SIMD4(0.2, 0.4, 0.6, 0.8),
            "SG overrides MR fallback")
        assert(
            sg.specularGlossiness == SIMD4(0.1, 0.3, 0.5, 0.7), "Independent RGB specular/glossiness factors")
        assert(
            sg.baseColorTexture?.texture == sgScene.textures[2].id && sg.alphaMode == .mask
                && sg.alphaCutoff == 0.4,
            "SG diffuse texture carries coverage")
        assert(
            sg.specularGlossinessTexture?.offset == SIMD2(0.25, 0.5) && sg.metallicRoughnessTexture == nil,
            "SG texture transform and workflow isolation")
        try glb(sgAsset).write(to: URL(fileURLWithPath: "/tmp/specular-glossiness-fixture.glb"))
        sgAsset["materials"] = [["extensions": ["KHR_materials_pbrSpecularGlossiness": [:]]]]
        let sgDefault = try load(sgAsset).materials[0]
        assert(
            sgDefault.color == SIMD4(repeating: 1) && sgDefault.specularGlossiness == SIMD4(repeating: 1),
            "SG defaults without MR fallback")
        sgAsset["materials"] = [
            ["extensions": ["KHR_materials_pbrSpecularGlossiness": ["specularFactor": [1, 2]]]]
        ]
        reject { _ = try load(sgAsset) }
        var transmissionAsset = textured
        transmissionAsset["extensionsRequired"] = ["KHR_materials_transmission"]
        transmissionAsset["materials"] = [
            [
                "pbrMetallicRoughness": ["metallicFactor": 0, "roughnessFactor": 0],
                "extensions": [
                    "KHR_materials_transmission": [
                        "transmissionFactor": 0.75, "transmissionTexture": ["index": 0],
                    ]
                ],
            ]
        ]
        let transmitted = try load(transmissionAsset)
        assert(transmitted.materials[0].transmissionFactor == 0.75, "transmission factor")
        assert(
            transmitted.materials[0].transmissionTexture?.texture == transmitted.textures[2].id,
            "transmission texture")
        transmissionAsset["materials"] = [["extensions": ["KHR_materials_transmission": [:]]]]
        let defaults = try load(transmissionAsset)
        assert(defaults.materials[0].transmissionFactor == 0, "transmission default")
        let texturedScene = try load(textured)
        assert(texturedScene.images.count == 1 && texturedScene.images[0].width == 2, "embedded PNG")
        assert(texturedScene.meshes[0].vertices[2].uv.x == Float(128.0 / 255), "normalized UV")
        assert(
            texturedScene.materials[0].baseColorTexture?.texture == texturedScene.textures[2].id,
            "texture binding")
        try glb(textured).write(to: URL(fileURLWithPath: "/tmp/spectral-import-fixture.glb"))
        // JSON + external buffer uses the same parser.
        var external = textured
        external["buffers"] = [["byteLength": binary.count, "uri": "spectral-import-fixture.bin"]]
        try binary.write(to: URL(fileURLWithPath: "/tmp/spectral-import-fixture.bin"))
        try JSONSerialization.data(withJSONObject: external).write(
            to: URL(fileURLWithPath: "/tmp/spectral-import-fixture.gltf"))
        _ = try GLTFImporter(
            container: GLTFContainer(url: URL(fileURLWithPath: "/tmp/spectral-import-fixture.gltf"))
        ).load()
        binary = binary.prefix(52)
        var bad = json
        bad["extensionsRequired"] = ["KHR_draco_mesh_compression"]
        reject { _ = try load(bad) }
        bad = json; bad["nodes"] = [["children": [0], "mesh": 0]]
        reject { _ = try load(bad) }
        bad = json; bad["nodes"] = [["mesh": Int.max]]
        reject { _ = try load(bad) }
        bad = json;
        bad["accessors"] = [
            ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "byteOffset": Int.max]
        ]
        reject { _ = try load(bad) }
        var truncated = try glb(json); truncated.removeLast()
        reject { _ = try GLTFContainer(data: truncated, baseURL: URL(fileURLWithPath: "/tmp")) }
        reject { _ = try GLTFContainer.resolve("../secret", baseURL: URL(fileURLWithPath: "/tmp/model")) }
        // Sparse replacement overlays the zero-initialized accessor.
        json["accessors"] = [
            [
                "componentType": 5126, "count": 3, "type": "VEC3",
                "sparse": [
                    "count": 3, "indices": ["bufferView": 1, "componentType": 5121],
                    "values": ["bufferView": 0],
                ],
            ], ["bufferView": 1, "componentType": 5121, "count": 3, "type": "SCALAR"],
        ]
        json["bufferViews"] = [
            ["buffer": 0, "byteOffset": 0, "byteLength": 36],
            ["buffer": 0, "byteOffset": 48, "byteLength": 3],
        ]
        let sparse = try GLTFContainer(data: glb(json), baseURL: URL(fileURLWithPath: "/tmp"))
        let decoded = try GLTFAccessor(container: sparse).decode(0, types: ["VEC3"], components: [5126])
        assert(decoded[0] == [-1, -1, 0], "sparse values")
        print("GLTF tests passed; fixture: /tmp/spectral-import-fixture.glb")
    }
}
