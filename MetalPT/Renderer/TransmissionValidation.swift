import Foundation
import Metal
import simd

enum TransmissionValidation {
    static func run(_ renderer: Renderer, output: MTLTexture, folder: URL) async throws {
        var scene = SceneDescription()
        let image = try SceneImage(width: 1, height: 1, pixels: [128, 0, 255, 255])
        scene.images = [image]
        scene.textures.append(.init(source: .image(image.id)))
        var sheet = SceneMaterial(
            surface: .metallicRoughness(baseColor: SIMD4(repeating: 1), metallic: 0, roughness: 0),
            transmissionFactor: 0.8, transmissionTexture: .init(texture: scene.textures[2].id))
        scene.materials = [
            sheet,
            SceneMaterial(
                emission: .init(strength: 1), emissiveTexture: .init(texture: scene.textures[1].id)),
        ]
        var front = SceneMesh()
        front.quad([-1, 0, 1], [1, 0, 1], [1, 2, 1], [-1, 2, 1], 0)
        _ = scene.addMesh(front, materials: [0])
        var back = SceneMesh()
        back.quad([-2, -1, 0], [2, -1, 0], [2, 3, 0], [-2, 3, 0], 0)
        _ = scene.addMesh(back, materials: [1])
        renderer.sceneOverride = scene
        renderer.model.camera.position = [0, 1, 4]
        renderer.model.camera.pitch = 0
        renderer.model.maxDepth = 8
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        let values = try await renderer.validateNumerics(kernel: "validateTransmission", count: 9)
        guard abs(values[0].x - 0.8 * 128 / 255) < 0.0001,
            simd_length(values[1] - SIMD4(1, 1, 1, 0)) < 0.04,
            simd_length(values[2] - SIMD4(0.52, 0.52, 0.52, 0)) < 0.03,
            values[7].x == 0,
            values[4].xyz.min() > 0.8, values[4].max() <= 1.01,
            abs(values[8].y - values[8].z) < 0.015,
            values[8].x > 0.4
        else { throw RenderFailure("Transmission 数值验证失败：\(values)") }
        var means: [String: Double] = [:]
        for (name, transmission, roughness) in [
            ("opaque", Float(0), Float(0)), ("clear", 1, 0), ("partial", 0.5, 0), ("rough", 1, 0.5),
        ] {
            sheet.transmissionTexture = nil
            sheet.transmissionFactor = transmission
            sheet.surface = .metallicRoughness(
                baseColor: SIMD4(repeating: 1), metallic: 0, roughness: roughness)
            scene.materials[0] = sheet
            renderer.sceneOverride = scene
            for _ in 0..<128 {
                _ = try renderer.render(to: output)
                await renderer.waitForGPU()
            }
            let stats = try ValidationRunner.save(
                output, to: folder.appendingPathComponent("transmission-\(name).png"))
            means[name] = stats["meanRGB"]!
            let counters = renderer.lastCounters!.contents().bindMemory(to: UInt32.self, capacity: 8)
            guard counters[3] == 0, counters[4] == 0 else {
                throw RenderFailure("Transmission GPU diagnostics")
            }
        }
        guard means["clear"]! > means["partial"]!, means["partial"]! > means["opaque"]! + 0.02 else {
            throw RenderFailure("透射图像差异异常：\(means)")
        }
        let report: [String: Any] = [
            "device": renderer.context.device.name,
            "render": renderer.model.resolution, "spp": 128, "depth": 8,
            "meanRGB": means, "numerics": values.map { [$0.x, $0.y, $0.z, $0.w] },
            "queueOverflow": 0, "nonFinite": 0,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("transmission.json"))
        print("Transmission validation passed: \(folder.path)")
    }
}
