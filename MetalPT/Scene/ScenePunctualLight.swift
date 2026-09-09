import Foundation
import simd

/// World-space analytic lights. Intensity uses cd for point/spot and lux for directional lights.
nonisolated struct ScenePunctualLight: Identifiable {
    enum Kind: UInt32, CaseIterable, Identifiable {
        case point = 1, spot = 2, directional = 3
        var id: UInt32 { rawValue }
        var title: String {
            switch self {
            case .point: "点光源"
            case .spot: "聚光灯"
            case .directional: "平行光"
            }
        }
        var icon: String {
            switch self {
            case .point: "lightbulb"
            case .spot: "flashlight.on.fill"
            case .directional: "sun.max"
            }
        }
    }
    var id = NodeID()
    var name: String
    var kind: Kind
    var enabled = true
    var color: SIMD3<Float> = [1, 1, 1]
    var intensity: Float = 10
    var position: SIMD3<Float> = [0, 2, 1]
    /// Direction in which light travels, not direction towards the light.
    var direction: SIMD3<Float> = [0, -1, 0]
    var range: Float = 0  // zero means unbounded
    var innerAngle: Float = 0
    var outerAngle: Float = .pi / 4

    func validate() throws {
        guard color.min() >= 0, color.max() <= 1,
            [color, position, direction].allSatisfy({ v in v.x.isFinite && v.y.isFinite && v.z.isFinite }),
            intensity.isFinite, intensity >= 0, range.isFinite, range >= 0,
            simd_length(direction).isFinite, simd_length(direction) > 1e-8,
            innerAngle.isFinite, outerAngle.isFinite, innerAngle >= 0,
            innerAngle < outerAngle, outerAngle <= .pi / 2
        else {
            throw RenderFailure("灯光颜色、强度、方向、范围或锥角无效")
        }
    }

    func gpu() -> PTLight {
        PTLight(
            origin: SIMD4(position, 1), u: SIMD4(color * (enabled ? intensity : 0), 0),
            v: SIMD4(simd_normalize(direction), 0),
            normalArea: [cos(innerAngle), cos(outerAngle), range, 0],
            indices: [0, 0, kind.rawValue, 0])
    }
}
