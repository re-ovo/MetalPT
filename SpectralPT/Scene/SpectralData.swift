import Foundation
import simd

/// Bundled CIE and metal optical constants, sampled at 1 nm.
struct SpectralData {
    let cie: [SIMD4<Float>]
    var gold: [SIMD4<Float>] = []

    init() throws {
        let cieURL = Bundle.main.url(forResource: "CIE_xyz_1931_2deg", withExtension: "csv")!
        cie = try String(contentsOf: cieURL, encoding: .utf8).split(whereSeparator: \.isNewline).map {

            row -> SIMD4<Float> in
            let n = row.split(separator: ",").compactMap {
                Float($0)
            }
            return [n[1], n[2], n[3], 0]
        }
        guard cie.count == 471 else {
            throw RenderFailure("CIE 数据不完整")
        }
        let goldURL = Bundle.main.url(forResource: "Au_Johnson", withExtension: "yml")!
        let rows = try String(contentsOf: goldURL, encoding: .utf8).split(whereSeparator: \.isNewline)
            .compactMap {
                row -> SIMD3<Float>? in
                let n = row.split(whereSeparator: \.isWhitespace).compactMap {
                    Float($0)
                }
                return n.count == 3 ? [n[0] * 1000, n[1], n[2]] : nil
            }
        guard rows.count > 10 else {
            throw RenderFailure("金属光学数据不完整")
        }
        for nm in 360...830 {
            let k = max(
                1,
                rows.firstIndex {
                    $0.x >= Float(nm)
                } ?? (rows.count - 1))
            let a = rows[k - 1]
            let b = rows[k]
            let t = (Float(nm) - a.x) / (b.x - a.x)
            gold.append([a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, 0, 0])
        }
    }
}
