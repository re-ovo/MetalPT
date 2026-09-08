import Foundation
import ImageIO
import CoreGraphics

nonisolated struct SceneImage {
    var id = ImageID()
    let width: Int
    let height: Int
    /// RGBA8, straight alpha, row zero is v=0. Color-space interpretation belongs to the texture view.
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
            pixels.count == width * height * 4
        else { throw RenderFailure("无效 RGBA 图片尺寸或数据长度") }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(encoded data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
            decoded.width <= 16384, decoded.height <= 16384
        else {
            throw RenderFailure("图片解码失败或尺寸超限")
        }
        let image = decoded.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) ?? decoded
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw RenderFailure("图片像素转换失败") }
        for p in stride(from: 0, to: rgba.count, by: 4) where rgba[p + 3] > 0 {
            for c in 0..<3 {
                rgba[p + c] = UInt8(
                    min(255, (Int(rgba[p + c]) * 255 + Int(rgba[p + 3]) / 2) / Int(rgba[p + 3])))
            }
        }
        try self.init(width: image.width, height: image.height, pixels: rgba)
    }

    struct Level { let width, height: Int; let pixels: [UInt8] }
    func mipLevels(sRGB: Bool) -> [Level] {
        func decode(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        func encode(_ x: Float) -> Float { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
        var result = [Level(width: width, height: height, pixels: pixels)]
        while let source = result.last, source.width > 1 || source.height > 1 {
            let w = max(1, source.width / 2), h = max(1, source.height / 2)
            var output = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let xs = (x * source.width / w)..<((x + 1) * source.width / w)
                    let ys = (y * source.height / h)..<((y + 1) * source.height / h)
                    for c in 0..<4 {
                        var sum: Float = 0
                        for sy in ys {
                            for sx in xs {
                                let value = Float(source.pixels[(sy * source.width + sx) * 4 + c]) / 255
                                sum += sRGB && c < 3 ? decode(value) : value
                            }
                        }
                        var average = sum / Float(xs.count * ys.count)
                        if sRGB && c < 3 { average = encode(average) }
                        output[(y * w + x) * 4 + c] = UInt8(clamping: Int((average * 255).rounded()))
                    }
                }
            }
            result.append(Level(width: w, height: h, pixels: output))
        }
        return result
    }
}
