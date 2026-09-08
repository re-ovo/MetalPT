import Foundation
import simd

struct OrbitCamera: Equatable {
    var target: SIMD3<Float> = [0, 1.35, 0]
    var yaw: Float = 0, pitch: Float = 0.04, distance: Float = 6.2
    mutating func orbit(_ dx: Float, _ dy: Float) {
        yaw -= dx * 0.006
        pitch = min(1.4, max(-1.4, pitch + dy * 0.006))
    }
    mutating func zoom(_ delta: Float) {
        distance = min(18, max(0.4, distance * exp(delta * 0.015)))
    }
    mutating func pan(_ dx: Float, _ dy: Float) {
        let right: SIMD3<Float> = [cos(yaw), 0, -sin(yaw)]
        target += (-right * dx + SIMD3<Float>(0, 1, 0) * dy) * distance * 0.0015
    }
    func fill(_ frame: inout PTFrame, aspect: Float) {
        let direction: SIMD3<Float> = [sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)]
        let eye = target + direction * distance
        let forward = -direction
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        let focal = tan(Float.pi * 38 / 360)
        frame.eye = SIMD4(eye, 0)
        frame.forward = SIMD4(forward, 0)
        frame.right = SIMD4(right * focal * aspect, 0)
        frame.up = SIMD4(up * focal, 0)
    }
}
