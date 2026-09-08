import Foundation
import ImageIO
import CoreGraphics
import simd

enum SurfaceAssetTests {
    static func run() throws {
        func rejects(_ message: String, _ work: () throws -> Void) {
            do { try work(); preconditionFailure(message) } catch {}
        }
        precondition(
            MemoryLayout<PTVertex>.stride == 96 && MemoryLayout<PTMaterial>.stride == 320,
            "Vertex/material ABI")
        precondition(
            MemoryLayout<PTHit>.stride == 112 && MemoryLayout<PTTextureBinding>.stride == 48,
            "Hit/binding ABI")
        let vertices = [SIMD3<Float>(-1, -1, 0), [1, -1, 0], [1, 1, 0], [-1, 1, 0]].map {
            SceneMesh.Vertex(position: SIMD4($0, 1), normal: [0, 0, 1, 0], uv: .zero)
        }
        var mesh = SceneMesh()
        try mesh.appendPrimitive(vertices: vertices, indices: [0, 1, 2, 0, 2, 3], materialSlot: 0)
        precondition(mesh.vertices.count == 4, "Indexed primitive must retain shared vertices")
        precondition(mesh.primitives == [.init(indexRange: 0..<6, materialSlot: 0)], "Primitive range")
        try mesh.appendPrimitive(vertices: vertices, indices: [0, 1, 2], materialSlot: 1)
        precondition(
            mesh.primitives[1] == .init(indexRange: 6..<9, materialSlot: 1), "Second primitive range")
        try mesh.appendPrimitive(vertices: vertices, indices: [0, 1, 2], materialSlot: 1)
        precondition(
            mesh.primitives.count == 3, "Authored primitive boundaries must survive equal material slots")
        let count = mesh.vertices.count
        rejects("Invalid primitive accepted") {
            try mesh.appendPrimitive(vertices: vertices, indices: [0, 9, 1], materialSlot: 0)
        }
        precondition(mesh.vertices.count == count, "Invalid primitive must not mutate mesh")
        var changed = mesh
        changed.vertices[0].tangent = [0, 1, 0, -1]
        precondition(!changed.hasSameGeometry(as: mesh), "Attribute edit must invalidate GPU snapshot")

        let image = try SceneImage(
            width: 2, height: 2,
            pixels: [
                0, 0, 0, 255, 255, 255, 255, 255,
                255, 0, 0, 128, 0, 255, 0, 255,
            ])
        let colorMip = image.mipLevels(sRGB: true).last!
        let dataMip = image.mipLevels(sRGB: false).last!
        precondition(
            abs(Int(colorMip.pixels[0]) - 188) <= 1 && abs(Int(dataMip.pixels[0]) - 128) <= 1,
            "Color mips must average in linear light")
        precondition(colorMip.pixels[3] == dataMip.pixels[3], "Alpha must remain linear")
        let odd = try SceneImage(
            width: 3, height: 1, pixels: [0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255])
        precondition(
            odd.mipLevels(sRGB: false).last!.pixels[0] == 85, "Odd mip dimensions must retain edge texels")
        let opaquePixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let provider = CGDataProvider(data: Data(opaquePixels) as CFData)!
        let cg = CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        precondition(CGImageDestinationFinalize(destination), "PNG fixture encoding")
        let decoded = try SceneImage(encoded: encoded as Data)
        precondition(decoded.pixels == opaquePixels, "PNG decoding must preserve row order and channels")
        rejects("Invalid image accepted") { _ = try SceneImage(width: 1, height: 2, pixels: [0]) }
        rejects("Unsupported UV set accepted") {
            try TextureBinding(texture: SceneTexture.white.id, texCoord: 2).validate(samplers: [
                SceneSampler.nearest.id
            ])
        }
        rejects("Invalid sampler accepted") {
            try TextureBinding(texture: SceneTexture.white.id, sampler: SamplerID()).validate(samplers: [
                SceneSampler.nearest.id
            ])
        }
        var scene = SceneDescription()
        scene.materials = [SceneMaterial(), SceneMaterial()]
        _ = scene.addMesh(mesh, materials: [0, 1])
        scene.materials[0].normalTexture = .init(texture: SceneTexture.white.id, texCoord: 1)
        rejects("Missing UV set accepted") { try scene.validate() }
        print("Surface asset tests passed (primitives, attributes, image decode, semantic mips, bindings)")
    }
}
