import Foundation
import simd

struct FPSCamera: Equatable {
    var position: SIMD3<Float> = [0, 1.35 + sin(0.04) * 6.2, cos(0.04) * 6.2]
    var yaw: Float = 0
    var pitch: Float = 0.04
    var fieldOfView: Float = 38

    var forward: SIMD3<Float> {
        -SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
    }
    var right: SIMD3<Float> { [cos(yaw), 0, -sin(yaw)] }

    mutating func look(_ dx: Float, _ dy: Float) {
        yaw -= dx * 0.004
        pitch = min(1.55, max(-1.55, pitch + dy * 0.004))
    }

    /// Local horizontal movement stays level; Q/E move along world up. Normalize diagonals.
    mutating func move(_ input: SIMD3<Float>, distance: Float) {
        guard simd_length_squared(input) > 0 else { return }
        let direction =
            right * input.x + SIMD3<Float>(0, input.y, 0)
            + SIMD3<Float>(-sin(yaw), 0, -cos(yaw)) * input.z
        position += simd_normalize(direction) * distance
    }

    func fill(_ frame: inout PTFrame, aspect: Float) {
        let up = simd_cross(right, forward)
        let focal = tan(fieldOfView * .pi / 360)
        frame.eye = SIMD4(position, 0)
        frame.forward = SIMD4(forward, 0)
        frame.right = SIMD4(right * focal * aspect, 0)
        frame.up = SIMD4(up * focal, 0)
    }
}
